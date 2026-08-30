[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

# Regression: global vs. project-scoped RAG must resolve to two genuinely
# distinct OpenWebUI Knowledge collections -- never the same collection, and
# never silently created twice for the same scope. Part 1 exercises the pure
# naming/validation contract (no network). Part 2 drives the real
# Get-RAGKnowledge function over a real loopback HTTP mock that tracks
# multiple named collections (unlike the single-fixed-collection mock in
# Test-KIStackRAGStatePersistence.ps1), proving the separation holds for an
# actual find-or-create round trip, not just for the name string in isolation.

Import-Module (Join-Path $PackageRoot 'KIStackRAG.psm1') -Force -DisableNameChecking

# --- Part 1: pure naming and source/scope-match contract -------------------
$globalConfig=[pscustomobject]@{project='global';knowledgeName='KI-Stack Controlled Knowledge'}
$projectConfig=[pscustomobject]@{project='customer-x';knowledgeName='KI-Stack Controlled Knowledge'}
$legacyConfigNoProjectField=[pscustomobject]@{knowledgeName='KI-Stack Controlled Knowledge'}

$checks.globalKeepsBaseName=[ordered]@{}
$globalName=Get-RAGKnowledgeName -Config $globalConfig
$checks.globalKeepsBaseName.matchesBaseName=($globalName-eq'KI-Stack Controlled Knowledge')
if(-not$checks.globalKeepsBaseName.matchesBaseName){$fail.Add("globalKeepsBaseName failed: got '$globalName'")}

$checks.projectGetsDedicatedName=[ordered]@{}
$projectName=Get-RAGKnowledgeName -Config $projectConfig
$checks.projectGetsDedicatedName.differsFromGlobal=($projectName-ne$globalName)
$checks.projectGetsDedicatedName.containsProjectLabel=($projectName-match[regex]::Escape('customer-x'))
if($checks.projectGetsDedicatedName.Values-contains$false){$fail.Add("projectGetsDedicatedName failed: got '$projectName'")}

$checks.missingProjectFieldDefaultsToGlobal=[ordered]@{}
$legacyName=Get-RAGKnowledgeName -Config $legacyConfigNoProjectField
$checks.missingProjectFieldDefaultsToGlobal.matchesGlobal=($legacyName-eq$globalName)
if(-not$checks.missingProjectFieldDefaultsToGlobal.matchesGlobal){$fail.Add("missingProjectFieldDefaultsToGlobal failed: got '$legacyName'")}

$checks.matchingSourcesPass=[ordered]@{}
$threwOnMatch=$false
try{
    $matchingSources=[pscustomobject]@{sources=@(
        [pscustomobject]@{source_id='s1';project='customer-x';enabled=$true}
        [pscustomobject]@{source_id='s2';project='customer-x';enabled=$false}
    )}
    Test-RAGSourcesMatchConfiguredProject -Sources $matchingSources -ConfiguredProject 'customer-x'
}catch{$threwOnMatch=$true}
$checks.matchingSourcesPass.noThrow=(-not$threwOnMatch)
if($threwOnMatch){$fail.Add('matchingSourcesPass unexpectedly threw')}

$checks.disabledSourceMismatchIgnored=[ordered]@{}
$threwOnDisabledMismatch=$false
try{
    $disabledMismatch=[pscustomobject]@{sources=@(
        [pscustomobject]@{source_id='s1';project='customer-x';enabled=$true}
        [pscustomobject]@{source_id='stale';project='customer-y';enabled=$false}
    )}
    Test-RAGSourcesMatchConfiguredProject -Sources $disabledMismatch -ConfiguredProject 'customer-x'
}catch{$threwOnDisabledMismatch=$true}
$checks.disabledSourceMismatchIgnored.noThrow=(-not$threwOnDisabledMismatch)
if($threwOnDisabledMismatch){$fail.Add('disabledSourceMismatchIgnored unexpectedly threw')}

$checks.enabledSourceMismatchBlocked=[ordered]@{}
$threwOnEnabledMismatch=$false;$mismatchMessage=''
try{
    $enabledMismatch=[pscustomobject]@{sources=@(
        [pscustomobject]@{source_id='foreign-src';project='customer-y';enabled=$true}
    )}
    Test-RAGSourcesMatchConfiguredProject -Sources $enabledMismatch -ConfiguredProject 'customer-x'
}catch{$threwOnEnabledMismatch=$true;$mismatchMessage=$_.Exception.Message}
$checks.enabledSourceMismatchBlocked.threw=$threwOnEnabledMismatch
$checks.enabledSourceMismatchBlocked.namesOffendingSource=($mismatchMessage-match'foreign-src')
if($checks.enabledSourceMismatchBlocked.Values-contains$false){$fail.Add("enabledSourceMismatchBlocked failed: threw=$threwOnEnabledMismatch message=$mismatchMessage")}

# --- Part 2: real find-or-create round trip against a multi-collection mock,
# proving global and project scopes resolve to different, independently
# created Knowledge collections and a repeated call for the same scope
# reuses (never duplicates) its own collection. ------------------------------
$mockServerScriptContent=@'
param([int]$Port,[int]$RequestCount)
Set-StrictMode -Version Latest
$collections=[Collections.Generic.List[object]]::new()
$tcp=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
$tcp.Start()
function Read-Req($stream){
    $ms=[IO.MemoryStream]::new();$buf=New-Object byte[] 8192;$headerText=$null
    while($null -eq $headerText){
        $n=$stream.Read($buf,0,$buf.Length);if($n -le 0){break}
        $ms.Write($buf,0,$n)
        $text=[Text.Encoding]::ASCII.GetString($ms.ToArray())
        $idx=$text.IndexOf("`r`n`r`n")
        if($idx -ge 0){$headerText=$text.Substring(0,$idx)}
    }
    $all=$ms.ToArray();$headerLen=[Text.Encoding]::ASCII.GetByteCount($headerText)+4
    $bodyLen=0
    foreach($line in ($headerText -split "`r`n")){if($line -match '(?i)^Content-Length:\s*(\d+)'){$bodyLen=[int]$Matches[1]}}
    while(($all.Length-$headerLen) -lt $bodyLen){$n=$stream.Read($buf,0,$buf.Length);if($n -le 0){break};$prev=$all;$all=New-Object byte[] ($prev.Length+$n);[Array]::Copy($prev,$all,$prev.Length);[Array]::Copy($buf,0,$all,$prev.Length,$n)}
    $requestLine=($headerText -split "`r`n")[0]
    $method=$requestLine.Split(' ')[0];$path=$requestLine.Split(' ')[1]
    $body=if($bodyLen -gt 0){[Text.Encoding]::UTF8.GetString($all,$headerLen,$bodyLen)}else{''}
    [pscustomobject]@{method=$method;path=$path;body=$body}
}
function Send-Json($stream,$code,$json){
    $bytes=[Text.Encoding]::UTF8.GetBytes($json)
    $status=if($code -eq 200){'200 OK'}else{'400 Bad Request'}
    $header="HTTP/1.1 $status`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
    $hb=[Text.Encoding]::ASCII.GetBytes($header)
    $stream.Write($hb,0,$hb.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
}
for($i=0;$i -lt $RequestCount;$i++){
    $client=$tcp.AcceptTcpClient();$stream=$client.GetStream()
    try{
        $req=Read-Req $stream
        if($req.method -eq 'GET' -and $req.path -eq '/api/v1/knowledge/'){
            $items=@($collections|ForEach-Object{[ordered]@{id=$_.id;name=$_.name}})
            Send-Json $stream 200 (([ordered]@{items=$items})|ConvertTo-Json -Depth 10 -Compress)
        } elseif($req.method -eq 'POST' -and $req.path -eq '/api/v1/knowledge/create'){
            $parsed=$req.body|ConvertFrom-Json
            $new=[pscustomobject]@{id=[guid]::NewGuid().ToString();name=[string]$parsed.name}
            $collections.Add($new)
            Send-Json $stream 200 (($new|ConvertTo-Json -Compress))
        } else {
            Send-Json $stream 400 '{"error":"unexpected path"}'
        }
    } finally { $client.Close() }
}
$tcp.Stop()
'@

function New-KIRAGScopeMockServer {
    param([int]$RequestCount)
    $root=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-RAGScope-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    $port=Get-Random -Minimum 41000 -Maximum 45000
    $script=Join-Path $root 'mock.ps1'
    Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value $mockServerScriptContent
    $proc=Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$script,'-Port',$port,'-RequestCount',$RequestCount) -PassThru
    Start-Sleep -Milliseconds 400
    [pscustomobject]@{Root=$root;Port=$port;Process=$proc}
}

$mock=New-KIRAGScopeMockServer -RequestCount 12
try{
    $endpoint="http://127.0.0.1:$($mock.Port)"
    $dummyToken=ConvertTo-SecureString 'fixture-token' -AsPlainText -Force
    $globalCfg=[pscustomobject]@{project='global';knowledgeName='Scope Test Knowledge';openWebUIEndpoint=$endpoint;knowledgeDescription='fixture'}
    $projectCfg=[pscustomobject]@{project='customer-x';knowledgeName='Scope Test Knowledge';openWebUIEndpoint=$endpoint;knowledgeDescription='fixture'}

    $globalKnowledge1=Get-RAGKnowledge -Config $globalCfg -ApiToken $dummyToken -Create
    $projectKnowledge1=Get-RAGKnowledge -Config $projectCfg -ApiToken $dummyToken -Create
    $globalKnowledge2=Get-RAGKnowledge -Config $globalCfg -ApiToken $dummyToken -Create
    $projectKnowledge2=Get-RAGKnowledge -Config $projectCfg -ApiToken $dummyToken -Create

    $checks.realRoundTripCreatesDistinctCollections=[ordered]@{
        globalAndProjectHaveDifferentIds=([string]$globalKnowledge1.id -ne [string]$projectKnowledge1.id)
        globalAndProjectHaveDifferentNames=([string]$globalKnowledge1.name -ne [string]$projectKnowledge1.name)
        repeatedGlobalLookupReusesId=([string]$globalKnowledge1.id -eq [string]$globalKnowledge2.id)
        repeatedProjectLookupReusesId=([string]$projectKnowledge1.id -eq [string]$projectKnowledge2.id)
    }
    if($checks.realRoundTripCreatesDistinctCollections.Values-contains$false){$fail.Add('realRoundTripCreatesDistinctCollections failed: '+($checks.realRoundTripCreatesDistinctCollections|ConvertTo-Json -Compress)+' | global='+($globalKnowledge1|ConvertTo-Json -Compress)+' project='+($projectKnowledge1|ConvertTo-Json -Compress))}
}
finally{
    if($mock.Process -and -not $mock.Process.HasExited){Stop-Process -Id $mock.Process.Id -Force -ErrorAction SilentlyContinue}
    if(Test-Path -LiteralPath $mock.Root){Remove-Item -LiteralPath $mock.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Part 3: New-KIStackRAGProjectScope.ps1 -- the only supported way to
# stand up a new project scope's config/sources pair. -----------------------
$scopeFixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-RAGScopeCreate-'+[guid]::NewGuid().ToString('N').Substring(0,8))
try{
    New-Item -ItemType Directory -Path (Join-Path $scopeFixtureRoot 'Config') -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'KIStackRAG.psm1') -Destination $scopeFixtureRoot -Force
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'New-KIStackRAGProjectScope.ps1') -Destination $scopeFixtureRoot -Force
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'Config/rag.config.json') -Destination (Join-Path $scopeFixtureRoot 'Config/rag.config.json') -Force
    $creatorScript=Join-Path $scopeFixtureRoot 'New-KIStackRAGProjectScope.ps1'
    $globalConfigPath=Join-Path $scopeFixtureRoot 'Config/rag.config.json'

    $created=& $creatorScript -ProjectName 'customer-x' -PackageRoot $scopeFixtureRoot -GlobalConfigPath $globalConfigPath | ConvertFrom-Json
    $checks.scopeCreatorProducesIsolatedPaths=[ordered]@{
        configCreated=(Test-Path -LiteralPath $created.configPath -PathType Leaf)
        sourcesCreated=(Test-Path -LiteralPath $created.sourcesPath -PathType Leaf)
        stateRootDiffersFromGlobal=($created.stateRoot -ne (Get-Content -LiteralPath $globalConfigPath -Raw|ConvertFrom-Json).stateRoot)
        sourceRootDiffersFromGlobal=($created.sourceRoot -ne (Get-Content -LiteralPath $globalConfigPath -Raw|ConvertFrom-Json).sourceRoot)
        knowledgeNameDiffersFromGlobal=($created.knowledgeName -ne (Get-Content -LiteralPath $globalConfigPath -Raw|ConvertFrom-Json).knowledgeName)
    }
    if($checks.scopeCreatorProducesIsolatedPaths.Values-contains$false){$fail.Add('scopeCreatorProducesIsolatedPaths failed: '+($checks.scopeCreatorProducesIsolatedPaths|ConvertTo-Json -Compress))}

    $createdSourcesContent=Get-Content -LiteralPath $created.sourcesPath -Raw|ConvertFrom-Json
    $checks.scopeCreatorStartsWithEmptyAllowList=[ordered]@{emptySources=(@($createdSourcesContent.sources).Count-eq0)}
    if(-not$checks.scopeCreatorStartsWithEmptyAllowList.emptySources){$fail.Add('scopeCreatorStartsWithEmptyAllowList failed')}

    $refusedWithoutForce=$false
    try{ & $creatorScript -ProjectName 'customer-x' -PackageRoot $scopeFixtureRoot -GlobalConfigPath $globalConfigPath | Out-Null }
    catch{ $refusedWithoutForce=$true }
    $checks.scopeCreatorRefusesExistingScopeWithoutForce=[ordered]@{threw=$refusedWithoutForce}
    if(-not$refusedWithoutForce){$fail.Add('scopeCreatorRefusesExistingScopeWithoutForce failed: second call without -Force did not throw')}

    $refusedReservedName=$false
    try{ & $creatorScript -ProjectName 'global' -PackageRoot $scopeFixtureRoot -GlobalConfigPath $globalConfigPath | Out-Null }
    catch{ $refusedReservedName=$true }
    $checks.scopeCreatorRefusesReservedGlobalName=[ordered]@{threw=$refusedReservedName}
    if(-not$refusedReservedName){$fail.Add('scopeCreatorRefusesReservedGlobalName failed: creating a scope named "global" did not throw')}
}
finally{
    if(Test-Path -LiteralPath $scopeFixtureRoot){Remove-Item -LiteralPath $scopeFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue}
}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'RAG-Scope-Separation-Regression fehlgeschlagen.'}

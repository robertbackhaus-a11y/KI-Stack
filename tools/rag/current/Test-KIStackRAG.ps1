#Requires -Version 7.0
[CmdletBinding()]param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$failures=[Collections.Generic.List[string]]::new()
foreach($path in @('VERSION','Config/rag.config.json','Config/sources.json','Contracts/source.schema.json','KIStackRAG.psm1','Invoke-KIStackRAG.ps1','README.md')){
    if(-not(Test-Path -LiteralPath (Join-Path $PackageRoot $path) -PathType Leaf)){$failures.Add("Fehlt: $path")}
}
$config=Get-Content -LiteralPath (Join-Path $PackageRoot 'Config/rag.config.json') -Raw|ConvertFrom-Json
if($config.version-ne(Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim()){$failures.Add('Versionsvertrag inkonsistent.')}
if($config.embeddingModel-notmatch'nomic'){$failures.Add('Nomic-Vertrag fehlt.')}
if($config.documentPrefix-ne'search_document: '){$failures.Add('Dokumentpräfix ist falsch.')}
if($config.queryPrefix-ne'search_query: '){$failures.Add('Querypräfix ist falsch.')}
if($config.chunkCharacters-le$config.chunkOverlapCharacters){$failures.Add('Chunkvertrag ist ungültig.')}
$moduleText=Get-Content -LiteralPath (Join-Path $PackageRoot 'KIStackRAG.psm1') -Raw
foreach($contract in @('/api/v1/knowledge/','/api/v1/knowledge/create','/api/v1/files/?process=true&process_in_background=false','files/batch/add','file/remove?delete_file=true','/api/v1/retrieval/embedding','/api/v1/retrieval/embedding/update')){
    if(-not$moduleText.Contains($contract)){$failures.Add("OpenWebUI-Vertrag fehlt: $contract")}
}
if($moduleText-match'(?i)api[_-]?key\s*=.*ConvertFrom-RAGSecureString'){$failures.Add('API-Key darf nicht persistiert werden.')}
$required=@('source_id','source_type','project','relative_path','file_name','file_sha256','document_version','section','chunk_index','imported_at','modified_at','content_language','visibility','parser_version')
foreach($field in $required){if(@($config.metadataFields)-notcontains$field){$failures.Add("Metadatenfeld fehlt: $field")}}

# --- Execute-preflight regressions (KI-Stack Complete Installer 2.5.0) -----
Import-Module (Join-Path $PackageRoot 'KIStackRAG.psm1') -Force -DisableNameChecking
$schemaPath=Join-Path $PackageRoot 'Contracts/source.schema.json'

# 1a. The real, shipped empty default allow-list must still pass.
try{
    $defaultSources=Get-Content -LiteralPath (Join-Path $PackageRoot 'Config/sources.json') -Raw|ConvertFrom-Json
    Test-RAGSourcesAgainstSchema -Sources $defaultSources -SchemaPath $schemaPath
}catch{$failures.Add("Gültige leere Default-Allowlist wurde abgelehnt: $($_.Exception.Message)")}

# 1b. A well-formed single source must pass (single-element JSON-array
# unwrap edge case in ConvertFrom-Json).
try{
    $validSingle=[pscustomobject]@{sources=@([pscustomobject]@{source_id='s1';source_type='directory';project='p';root=$PackageRoot;visibility='private';enabled=$true})}
    Test-RAGSourcesAgainstSchema -Sources $validSingle -SchemaPath $schemaPath
}catch{$failures.Add("Gültige einzelne Quelle wurde abgelehnt: $($_.Exception.Message)")}

# 1c. Missing required field -> clean, named error (not a raw StrictMode/property exception).
$missingFieldCaught=$false
try{
    $missingField=[pscustomobject]@{sources=@([pscustomobject]@{source_id='s1';source_type='directory';project='p';root=$PackageRoot;visibility='private'})}
    Test-RAGSourcesAgainstSchema -Sources $missingField -SchemaPath $schemaPath
}catch{
    $missingFieldCaught=$true
    if($_.Exception.Message-notmatch'(?i)enabled'){$failures.Add("Fehlermeldung für fehlendes Pflichtfeld nennt das Feld nicht: $($_.Exception.Message)")}
    if($_.Exception.Message-notmatch's1'){$failures.Add('Fehlermeldung für fehlendes Pflichtfeld benennt die betroffene Quelle nicht.')}
}
if(-not$missingFieldCaught){$failures.Add('Fehlendes Pflichtfeld wurde nicht erkannt.')}

# 1d. Unknown/additional property -> clean, named error (additionalProperties: false).
$extraPropertyCaught=$false
try{
    $extraProperty=[pscustomobject]@{sources=@([pscustomobject]@{source_id='s1';source_type='directory';project='p';root=$PackageRoot;visibility='private';enabled=$true;unexpected_field='x'})}
    Test-RAGSourcesAgainstSchema -Sources $extraProperty -SchemaPath $schemaPath
}catch{
    $extraPropertyCaught=$true
    if($_.Exception.Message-notmatch's1'){$failures.Add('Fehlermeldung für unbekanntes Property benennt die betroffene Quelle nicht.')}
}
if(-not$extraPropertyCaught){$failures.Add('Unbekanntes Property wurde nicht erkannt.')}

# 1e. Duplicate source_id detection (Get-RAGInventory) must still fire
# independently of schema validation.
$duplicateCaught=$false
try{
    $ragConfigForInventory=Get-Content -LiteralPath (Join-Path $PackageRoot 'Config/rag.config.json') -Raw|ConvertFrom-Json
    $duplicateSources=[pscustomobject]@{sources=@(
        [pscustomobject]@{source_id='dup';source_type='directory';project='p';root=$PackageRoot;visibility='private';enabled=$true}
        [pscustomobject]@{source_id='dup';source_type='directory';project='p';root=$PackageRoot;visibility='private';enabled=$true}
    )}
    Test-RAGSourcesAgainstSchema -Sources $duplicateSources -SchemaPath $schemaPath
    Get-RAGInventory $ragConfigForInventory $duplicateSources|Out-Null
}catch{
    $duplicateCaught=$true
    if($_.Exception.Message-notmatch'(?i)doppelt'){$failures.Add("Fehlermeldung für doppelte source_id ist unerwartet: $($_.Exception.Message)")}
}
if(-not$duplicateCaught){$failures.Add('Doppelte source_id wurde nicht erkannt.')}

# --- Embedding-model preflight (LM Studio) ----------------------------------
# Raw TcpListener mock of LM Studio's /models endpoint: responds based on
# whether a marker file exists, so the test can prove (a) an already-loaded
# model is not reloaded and (b) an absent model gets loaded via lms and then
# becomes visible.
$mockServerScriptContent=@'
param([int]$Port,[string]$MarkerFile,[string]$ModelId,[int]$RequestCount)
$tcp=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
$tcp.Start()
for($i=0;$i -lt $RequestCount;$i++){
    $client=$tcp.AcceptTcpClient()
    $stream=$client.GetStream()
    Start-Sleep -Milliseconds 50
    if($stream.DataAvailable){$buf=New-Object byte[] 4096;[void]$stream.Read($buf,0,$buf.Length)}
    $loaded=Test-Path -LiteralPath $MarkerFile
    $body=if($loaded){"{`"data`":[{`"id`":`"$ModelId`"}]}"}else{'{"data":[]}'}
    $bodyBytes=[Text.Encoding]::UTF8.GetBytes($body)
    $header="HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes=[Text.Encoding]::ASCII.GetBytes($header)
    $stream.Write($headerBytes,0,$headerBytes.Length)
    $stream.Write($bodyBytes,0,$bodyBytes.Length)
    $stream.Flush()
    Start-Sleep -Milliseconds 100
    $client.Close()
}
$tcp.Stop()
'@

$minimalWindowsPath=@("$env:SystemRoot\System32","$env:SystemRoot","$env:SystemRoot\System32\WindowsPowerShell\v1.0") -join ';'

function New-RAGEmbeddingFixture {
    param([bool]$LmsCreatesMarkerOnLoad)
    $root=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-RAGEmbedding-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    $port=Get-Random -Minimum 31000 -Maximum 35000
    $marker=Join-Path $root 'loaded.marker'
    $traceFile=Join-Path $root 'lms-called.trace'
    $mockScript=Join-Path $root 'mock-embedding-server.ps1'
    Set-Content -LiteralPath $mockScript -Encoding utf8NoBOM -Value $mockServerScriptContent
    $userProfile=Join-Path $root 'profile'
    $binDir=Join-Path $userProfile '.lmstudio/bin'
    New-Item -ItemType Directory -Path $binDir -Force|Out-Null
    $lmsPath=Join-Path $binDir 'lms.cmd'
    $lmsLines=@('@echo off',"echo called>>`"$traceFile`"")
    if($LmsCreatesMarkerOnLoad){$lmsLines+="echo loaded>`"$marker`""}
    $lmsLines+='exit /b 0'
    Set-Content -LiteralPath $lmsPath -Encoding ascii -Value $lmsLines
    [pscustomobject]@{Root=$root;Port=$port;Marker=$marker;TraceFile=$traceFile;MockScript=$mockScript;UserProfile=$userProfile}
}

function Start-RAGMockEmbeddingServer {
    param([Parameter(Mandatory)]$Fixture,[int]$RequestCount=8)
    $proc=Start-Process -FilePath 'powershell' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$Fixture.MockScript,'-Port',$Fixture.Port,'-MarkerFile',$Fixture.Marker,'-ModelId','text-embedding-nomic-embed-text-v1.5','-RequestCount',$RequestCount) -PassThru
    Start-Sleep -Milliseconds 300
    $proc
}

function Stop-RAGMockEmbeddingServer {
    # The mock listens for up to -RequestCount connections with no idle
    # timeout of its own; a scenario that only ever makes a few requests
    # would otherwise leave it running indefinitely.
    param([Parameter(Mandatory)]$Process)
    if ($null -ne $Process -and -not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue }
}

$previousUserProfile=$env:USERPROFILE
$previousPath=$env:PATH

# 2a. Model already loaded -> Assert-RAGEmbeddingModelReady returns without
# ever invoking lms (no unnecessary load).
$fixtureA=New-RAGEmbeddingFixture -LmsCreatesMarkerOnLoad $true
try{
    Set-Content -LiteralPath $fixtureA.Marker -Value 'loaded' -Encoding ascii
    $serverA=Start-RAGMockEmbeddingServer -Fixture $fixtureA
    $env:USERPROFILE=$fixtureA.UserProfile
    $env:PATH=$minimalWindowsPath
    $configA=[pscustomobject]@{embeddingBaseUrl="http://127.0.0.1:$($fixtureA.Port)";embeddingModel='text-embedding-nomic-embed-text-v1.5';targetRoot=$fixtureA.Root}
    Assert-RAGEmbeddingModelReady -Config $configA -LoadWaitMaxAttempts 3 -LoadWaitIntervalSeconds 1
    if(Test-Path -LiteralPath $fixtureA.TraceFile){$failures.Add('Bereits geladenes Modell wurde unnötig per lms neu geladen.')}
}catch{$failures.Add("Szenario 'Modell bereits geladen' schlug unerwartet fehl: $($_.Exception.Message)")}
finally{
    $env:USERPROFILE=$previousUserProfile;$env:PATH=$previousPath
    Stop-RAGMockEmbeddingServer -Process $serverA
    if(Test-Path -LiteralPath $fixtureA.Root){Remove-Item -LiteralPath $fixtureA.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# 2b. Model not loaded -> lms load is invoked -> becomes ready.
$fixtureB=New-RAGEmbeddingFixture -LmsCreatesMarkerOnLoad $true
try{
    $serverB=Start-RAGMockEmbeddingServer -Fixture $fixtureB
    $env:USERPROFILE=$fixtureB.UserProfile
    $env:PATH=$minimalWindowsPath
    $configB=[pscustomobject]@{embeddingBaseUrl="http://127.0.0.1:$($fixtureB.Port)";embeddingModel='text-embedding-nomic-embed-text-v1.5';targetRoot=$fixtureB.Root}
    Assert-RAGEmbeddingModelReady -Config $configB -LoadWaitMaxAttempts 5 -LoadWaitIntervalSeconds 1
    if(-not(Test-Path -LiteralPath $fixtureB.TraceFile)){$failures.Add('Nicht geladenes Modell führte nicht zum Aufruf von lms load.')}
}catch{$failures.Add("Szenario 'Modell wird geladen' schlug unerwartet fehl: $($_.Exception.Message)")}
finally{
    $env:USERPROFILE=$previousUserProfile;$env:PATH=$previousPath
    Stop-RAGMockEmbeddingServer -Process $serverB
    if(Test-Path -LiteralPath $fixtureB.Root){Remove-Item -LiteralPath $fixtureB.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# 2c. Model never becomes available -> clear, hard failure (not a hang, not
# a silent continue).
$fixtureC=New-RAGEmbeddingFixture -LmsCreatesMarkerOnLoad $false
try{
    $serverC=Start-RAGMockEmbeddingServer -Fixture $fixtureC
    $env:USERPROFILE=$fixtureC.UserProfile
    $env:PATH=$minimalWindowsPath
    $configC=[pscustomobject]@{embeddingBaseUrl="http://127.0.0.1:$($fixtureC.Port)";embeddingModel='text-embedding-nomic-embed-text-v1.5';targetRoot=$fixtureC.Root}
    $threw=$false
    try{Assert-RAGEmbeddingModelReady -Config $configC -LoadWaitMaxAttempts 2 -LoadWaitIntervalSeconds 1}catch{$threw=$true;if($_.Exception.Message-notmatch'(?i)nomic'){$failures.Add("Fehlermeldung bei dauerhaft fehlendem Modell nennt das Modell nicht: $($_.Exception.Message)")}}
    if(-not$threw){$failures.Add('Dauerhaft fehlendes Modell führte nicht zu einem harten Fehler.')}
}finally{
    $env:USERPROFILE=$previousUserProfile;$env:PATH=$previousPath
    Stop-RAGMockEmbeddingServer -Process $serverC
    if(Test-Path -LiteralPath $fixtureC.Root){Remove-Item -LiteralPath $fixtureC.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

$result=[pscustomobject]@{passed=($failures.Count-eq0);version=[string]$config.version;failures=@($failures);openWebUIContract='0.11.0';mutatesTarget=$false}
$result|ConvertTo-Json -Depth 20
if(-not$result.passed){exit 1}

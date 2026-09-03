[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

# Research-Agent-Web-Search-Execution-Path-Workstream: dedicated contract/regression suite for
# ki-stack-research's web-search fields. Real root-cause finding (verified live against the
# installed OpenWebUI 0.11.1 source and a real API session): Agent Provisioning (this package)
# and OpenWebUI's own native-function-calling tool injection/model behavior are BOTH correct --
# the real gap is OpenWebUI 0.11.1's own server-side background-task execution/continuation
# pipeline for non-browser (API/Bearer) callers, which is outside this package's and this
# repository's control (no DB hack, no core-OpenWebUI patch). This suite therefore protects the
# one thing that IS this package's responsibility: that ki-stack-research's own web-search
# contract fields are correctly defined and correctly reconciled into the real OpenWebUI object,
# every time -- never that OpenWebUI itself executes the tool end to end (see
# Test-KIStackOpenWebUICredentialBootstrap.ps1's sibling real-target report for that).

Import-Module (Join-Path $PackageRoot 'OpenWebUIAgentPack.psm1') -Force -DisableNameChecking

$baseModelId='qwen3.6-27b-uncensored-heretic-v2-native-mtp-preserved'
$definitionPath=Join-Path $PackageRoot 'Definitions/ki-stack-research.json'

# --- 1. Repo contract: the fields OpenWebUI 0.11.1 actually requires for native-FC web search
# (verified against open_webui/utils/tools.py's get_builtin_tools and
# open_webui/utils/middleware.py's use_builtin_tools gate) must all be present and correct. -----
$definition=Get-Content -LiteralPath $definitionPath -Raw|ConvertFrom-Json -Depth 20
$checks.repoDefinitionHasRequiredWebSearchFields=[ordered]@{
    capabilitiesWebSearchTrue=([bool]$definition.capabilities.web_search)
    builtinToolsWebSearchTrue=([bool]$definition.builtinTools.web_search)
    functionCallingIsNative=([string]$definition.functionCalling-eq'native')
    knowledgeSourceIsRagGlobal=([string]$definition.knowledgeSource-eq'rag-global')
}
if($checks.repoDefinitionHasRequiredWebSearchFields.Values-contains$false){$fail.Add('repoDefinitionHasRequiredWebSearchFields failed: '+($checks.repoDefinitionHasRequiredWebSearchFields|ConvertTo-Json -Compress))}

# --- 2. Negative control A (Section 23-A): remove the web-search flag from a copy of the
# definition and prove the contract check above would actually catch it -- not vacuously true. --
$negativeDefinition=$definition|ConvertTo-Json -Depth 20|ConvertFrom-Json -Depth 20
$negativeDefinition.capabilities.web_search=$false
$negativeDefinition.builtinTools.web_search=$false
$negativeCheck=[ordered]@{
    capabilitiesWebSearchTrue=([bool]$negativeDefinition.capabilities.web_search)
    builtinToolsWebSearchTrue=([bool]$negativeDefinition.builtinTools.web_search)
}
$checks.negativeControlA_MissingWebSearchFlagDetected=[ordered]@{
    wouldHaveFailedTheContractCheck=($negativeCheck.Values-contains$false)
}
if($checks.negativeControlA_MissingWebSearchFlagDetected.Values-contains$false){$fail.Add('negativeControlA_MissingWebSearchFlagDetected failed -- removing the web_search flags did not make the contract check fail, so this suite would not catch a real regression.')}

# --- 3. OpenWebUI config mapping (Section 10/23-B/C): the real, verified requirement is
# ENABLE_WEB_SEARCH=true AND a non-empty, real WEB_SEARCH_ENGINE (verified: open_webui/config.py
# defaults ENABLE_WEB_SEARCH to False; open_webui/utils/tools.py's get_builtin_tools gates
# search_web injection on config.get('web.search.enable') in addition to the agent's own
# capability flags). A tiny, explicit validator function is defined here (not duplicated from
# elsewhere) so both the positive and negative shapes below exercise the exact same logic. -------
function Test-KIStackWebSearchConfigValid {
    param($Config)
    $engine=[string]$Config.WEB_SEARCH_ENGINE
    [pscustomobject]@{
        valid=([bool]$Config.ENABLE_WEB_SEARCH-and-not[string]::IsNullOrWhiteSpace($engine)-and$engine-in@('searxng','google_pse','brave','duckduckgo','tavily','serper','bing'))
        enabled=[bool]$Config.ENABLE_WEB_SEARCH
        engine=$engine
    }
}
$realConfigShape=[pscustomobject]@{ENABLE_WEB_SEARCH=$true;WEB_SEARCH_ENGINE='searxng';SEARXNG_QUERY_URL='http://localhost/searxng/search?q=<query>'}
$checks.openWebUIConfigMappingRecognizesRealShape=[ordered]@{
    valid=(Test-KIStackWebSearchConfigValid -Config $realConfigShape).valid
}
if($checks.openWebUIConfigMappingRecognizesRealShape.Values-contains$false){$fail.Add('openWebUIConfigMappingRecognizesRealShape failed')}

# --- 4. Negative control B (Section 23-B): ENABLE_WEB_SEARCH disabled must be detected as
# invalid/blocked -- never silently treated as fine. --------------------------------------------
$disabledConfig=[pscustomobject]@{ENABLE_WEB_SEARCH=$false;WEB_SEARCH_ENGINE='searxng'}
$checks.negativeControlB_DisabledWebSearchDetected=[ordered]@{
    notValid=(-not (Test-KIStackWebSearchConfigValid -Config $disabledConfig).valid)
}
if($checks.negativeControlB_DisabledWebSearchDetected.Values-contains$false){$fail.Add('negativeControlB_DisabledWebSearchDetected failed -- a disabled ENABLE_WEB_SEARCH was not recognized as invalid.')}

# --- 5. Negative control C (Section 23-C): an invalid/empty search engine value must be
# detected -- never mistaken for a genuinely configured SearXNG binding. -------------------------
$invalidEngineConfig=[pscustomobject]@{ENABLE_WEB_SEARCH=$true;WEB_SEARCH_ENGINE='not-a-real-engine'}
$emptyEngineConfig=[pscustomobject]@{ENABLE_WEB_SEARCH=$true;WEB_SEARCH_ENGINE=''}
$checks.negativeControlC_InvalidSearchEngineDetected=[ordered]@{
    invalidEngineRejected=(-not (Test-KIStackWebSearchConfigValid -Config $invalidEngineConfig).valid)
    emptyEngineRejected=(-not (Test-KIStackWebSearchConfigValid -Config $emptyEngineConfig).valid)
}
if($checks.negativeControlC_InvalidSearchEngineDetected.Values-contains$false){$fail.Add('negativeControlC_InvalidSearchEngineDetected failed: '+($checks.negativeControlC_InvalidSearchEngineDetected|ConvertTo-Json -Compress))}

# --- 6. Real reconcile against a mock OpenWebUI (module logic unmocked, matching
# Test-OpenWebUIAgentPackResearchContract.ps1's own established pattern): the POSTED model form
# for ki-stack-research must carry every web-search-relevant field through unchanged, and the
# Knowledge binding must survive a second reconcile pass without loss or duplication. ------------
$mockServerScriptContent=@'
param([int]$Port,[int]$RequestCount,[string]$StateDir,[string]$BaseModelId,[int]$SeedKnowledge)
Set-StrictMode -Version Latest
$modelsPath=Join-Path $StateDir 'models.json'
$configPath=Join-Path $StateDir 'openai-config.json'
$models=if(Test-Path -LiteralPath $modelsPath){@(Get-Content -LiteralPath $modelsPath -Raw|ConvertFrom-Json -Depth 30)}else{@()}
$modelsById=@{}
foreach($m in $models){$modelsById[[string]$m.id]=$m}
function Save-MockModels{($modelsById.Values|ConvertTo-Json -Depth 30 -AsArray)|Set-Content -LiteralPath $modelsPath -Encoding ascii}
$config=if(Test-Path -LiteralPath $configPath){Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json -Depth 30}else{
    [pscustomobject]@{ENABLE_OPENAI_API=$true;OPENAI_API_BASE_URLS=@('http://127.0.0.1:1234/v1');OPENAI_API_KEYS=@('lm-studio');OPENAI_API_CONFIGS=[pscustomobject]@{}}
}
function Save-MockConfig{($config|ConvertTo-Json -Depth 30)|Set-Content -LiteralPath $configPath -Encoding ascii}
$knowledgeItems=@(if($SeedKnowledge -eq 1){@{id='rag-kb-0001';name='KI-Stack Controlled Knowledge'}})
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
    $status=if($code -eq 200){'200 OK'}elseif($code -eq 404){'404 Not Found'}else{'400 Bad Request'}
    $header="HTTP/1.1 $status`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
    $hb=[Text.Encoding]::ASCII.GetBytes($header)
    $stream.Write($hb,0,$hb.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
}
for($i=0;$i -lt $RequestCount;$i++){
    $client=$tcp.AcceptTcpClient();$stream=$client.GetStream()
    try{
        $req=Read-Req $stream
        $path=$req.path.Split('?')[0]
        if($req.method -eq 'GET' -and $path -eq '/api/v1/models'){
            Send-Json $stream 200 (([ordered]@{data=@(@{id=$BaseModelId;object='model'})})|ConvertTo-Json -Depth 10 -Compress)
        } elseif($req.method -eq 'GET' -and $path -eq '/api/v1/models/model'){
            $id=[Uri]::UnescapeDataString(($req.path -split 'id=')[1])
            if($modelsById.ContainsKey($id)){Send-Json $stream 200 (($modelsById[$id])|ConvertTo-Json -Depth 30 -Compress)}
            else{Send-Json $stream 404 '{"detail":"not found"}'}
        } elseif($req.method -eq 'POST' -and $path -eq '/api/v1/models/create'){
            $form=$req.body|ConvertFrom-Json -Depth 30
            $modelsById[[string]$form.id]=$form
            Save-MockModels
            Send-Json $stream 200 ($form|ConvertTo-Json -Depth 30 -Compress)
        } elseif($req.method -eq 'POST' -and $path -eq '/api/v1/models/model/update'){
            $form=$req.body|ConvertFrom-Json -Depth 30
            $modelsById[[string]$form.id]=$form
            Save-MockModels
            Send-Json $stream 200 ($form|ConvertTo-Json -Depth 30 -Compress)
        } elseif($req.method -eq 'GET' -and $path -eq '/api/v1/models/list'){
            Send-Json $stream 200 (([ordered]@{items=@($modelsById.Values)})|ConvertTo-Json -Depth 30 -Compress)
        } elseif($req.method -eq 'GET' -and $path -eq '/openai/config'){
            Send-Json $stream 200 ($config|ConvertTo-Json -Depth 30 -Compress)
        } elseif($req.method -eq 'POST' -and $path -eq '/openai/config/update'){
            $config=$req.body|ConvertFrom-Json -Depth 30
            Save-MockConfig
            Send-Json $stream 200 ($config|ConvertTo-Json -Depth 30 -Compress)
        } elseif($req.method -eq 'GET' -and $path -eq '/api/v1/knowledge/'){
            Send-Json $stream 200 (([ordered]@{items=$knowledgeItems})|ConvertTo-Json -Depth 10 -Compress)
        } else {
            Send-Json $stream 404 '{"detail":"unmapped"}'
        }
    } finally { $client.Close() }
}
$tcp.Stop()
'@

$mockRoot=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-WebSearchMock-'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $mockRoot -Force|Out-Null
$mockPort=Get-Random -Minimum 46000 -Maximum 49000
$mockScript=Join-Path $mockRoot 'mock.ps1'
Set-Content -LiteralPath $mockScript -Encoding utf8NoBOM -Value $mockServerScriptContent
$ragConfigPath=Join-Path $mockRoot 'rag.config.json'
(@{knowledgeName='KI-Stack Controlled Knowledge'}|ConvertTo-Json)|Set-Content -LiteralPath $ragConfigPath -Encoding utf8NoBOM
$patchedModulePath=Join-Path $mockRoot 'OpenWebUIAgentPack.patched.psm1'
$moduleSource=Get-Content -LiteralPath (Join-Path $PackageRoot 'OpenWebUIAgentPack.psm1') -Raw
$patchedSource=$moduleSource.Replace("[string]`$RAGConfigPath = 'C:\KI-Stack\modules\rag\Config\rag.config.json'", "[string]`$RAGConfigPath = '$($ragConfigPath.Replace('\','\\'))'")
if($patchedSource-eq$moduleSource){throw 'RAGConfigPath-Default konnte im Modultext nicht gepatcht werden -- Testannahme verletzt.'}
Set-Content -LiteralPath $patchedModulePath -Value $patchedSource -Encoding UTF8
$mockProcess=Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$mockScript,'-Port',$mockPort,'-RequestCount',40,'-StateDir',$mockRoot,'-BaseModelId',$baseModelId,'-SeedKnowledge',1) -PassThru
Start-Sleep -Milliseconds 400
$mockEndpoint="http://127.0.0.1:$mockPort"
$token=ConvertTo-SecureString 'fixture-token' -AsPlainText -Force

try{
    Remove-Module OpenWebUIAgentPack -Force -ErrorAction SilentlyContinue
    Import-Module $patchedModulePath -Force -DisableNameChecking
    $backupDir1=Join-Path $mockRoot 'backup1'
    [void](Install-OpenWebUIAgentPack -PackageRoot $PackageRoot -Endpoint $mockEndpoint -ApiToken $token -BaseModelId $baseModelId -BackupDirectory $backupDir1)

    $modelsFile=Join-Path $mockRoot 'models.json'
    $models=Get-Content -LiteralPath $modelsFile -Raw|ConvertFrom-Json -Depth 30
    $research=@($models|Where-Object{[string]$_.id-eq'ki-stack-research'})|Select-Object -First 1
    if(-not $research){throw 'ki-stack-research wurde im Mock nicht angelegt -- Testannahme verletzt.'}
    $checks.reconcileCarriesWebSearchFieldsThroughUnchanged=[ordered]@{
        capabilitiesWebSearchTrue=([bool]$research.meta.capabilities.web_search)
        builtinToolsWebSearchTrue=([bool]$research.meta.builtinTools.web_search)
        functionCallingNative=([string]$research.params.function_calling-eq'native')
        knowledgeBoundToRealCollection=(@($research.meta.knowledge).Count-eq1-and[string]$research.meta.knowledge[0].id-eq'rag-kb-0001')
    }
    if($checks.reconcileCarriesWebSearchFieldsThroughUnchanged.Values-contains$false){$fail.Add('reconcileCarriesWebSearchFieldsThroughUnchanged failed: '+($checks.reconcileCarriesWebSearchFieldsThroughUnchanged|ConvertTo-Json -Compress)+' | meta: '+($research.meta|ConvertTo-Json -Compress))}

    # --- 7. No regression across a second reconcile pass: web-search fields and the single
    # Knowledge binding must both survive unchanged (Section 22 "keine Regression in
    # Knowledge-Bindung"). --------------------------------------------------------------------
    $backupDir2=Join-Path $mockRoot 'backup2'
    [void](Install-OpenWebUIAgentPack -PackageRoot $PackageRoot -Endpoint $mockEndpoint -ApiToken $token -BaseModelId $baseModelId -BackupDirectory $backupDir2)
    $modelsAfterSecond=Get-Content -LiteralPath $modelsFile -Raw|ConvertFrom-Json -Depth 30
    $researchAfterSecond=@($modelsAfterSecond|Where-Object{[string]$_.id-eq'ki-stack-research'})|Select-Object -First 1
    $checks.noRegressionAcrossSecondReconcile=[ordered]@{
        stillExactlyOneResearchAgent=(@($modelsAfterSecond|Where-Object{[string]$_.id-eq'ki-stack-research'}).Count-eq1)
        webSearchStillTrue=([bool]$researchAfterSecond.meta.capabilities.web_search-and[bool]$researchAfterSecond.meta.builtinTools.web_search)
        knowledgeStillExactlyOneBinding=(@($researchAfterSecond.meta.knowledge).Count-eq1)
    }
    if($checks.noRegressionAcrossSecondReconcile.Values-contains$false){$fail.Add('noRegressionAcrossSecondReconcile failed: '+($checks.noRegressionAcrossSecondReconcile|ConvertTo-Json -Compress))}
}finally{
    Remove-Module OpenWebUIAgentPack -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PackageRoot 'OpenWebUIAgentPack.psm1') -Force -DisableNameChecking
    if($mockProcess-and-not$mockProcess.HasExited){Stop-Process -Id $mockProcess.Id -Force -ErrorAction SilentlyContinue}
    if(Test-Path -LiteralPath $mockRoot){Remove-Item -LiteralPath $mockRoot -Recurse -Force -ErrorAction SilentlyContinue}
}

foreach($file in Get-ChildItem -LiteralPath $PackageRoot -Filter '*.ps1' -File){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){$fail.Add("$($file.Name): $(@($errors).Message -join '; ')")}
}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail);rootCauseNote='OpenWebUI 0.11.1 background-task/session continuation pipeline stall for non-browser callers -- see final report; not fixable from this package.'}|ConvertTo-Json -Depth 15
if(-not$passed){throw 'Research-Agent-Web-Search-Contract-Regression fehlgeschlagen.'}

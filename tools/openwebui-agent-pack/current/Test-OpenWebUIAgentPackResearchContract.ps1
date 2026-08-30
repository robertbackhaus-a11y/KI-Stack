[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

# Regression suite for the ki-stack-research reference agent: drives the real
# Install-OpenWebUIAgentPack/Test-OpenWebUIAgentPack/Restore-OpenWebUIAgentPack functions
# (nothing on the Agent Pack side mocked) against a small, purpose-built HTTP mock of the
# OpenWebUI model/knowledge/openai-config endpoints, over a real loopback socket -- the
# same "mock only the remote backend, run the real module logic" pattern already
# established for RAG (Test-KIStackRAGStatePersistence.ps1) and the Agent Pack's own
# transaction/HTTP-failure tests (Test-AgentPackHttpFailures.ps1).

Import-Module (Join-Path $PackageRoot 'OpenWebUIAgentPack.psm1') -Force -DisableNameChecking

$baseModelId='qwen3.6-27b-uncensored-heretic-v2-native-mtp-preserved'

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
        } elseif($req.method -eq 'POST' -and $path -eq '/api/v1/models/model/delete'){
            $form=$req.body|ConvertFrom-Json -Depth 30
            [void]$modelsById.Remove([string]$form.id)
            Save-MockModels
            Send-Json $stream 200 '{"success":true}'
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

function New-AgentPackMockServer {
    param([int]$RequestCount,[int]$SeedKnowledge=0)
    $root=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-AgentPackMock-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    $port=Get-Random -Minimum 46000 -Maximum 49000
    $script=Join-Path $root 'mock.ps1'
    Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value $mockServerScriptContent
    $proc=Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$script,'-Port',$port,'-RequestCount',$RequestCount,'-StateDir',$root,'-BaseModelId',$baseModelId,'-SeedKnowledge',$SeedKnowledge) -PassThru
    Start-Sleep -Milliseconds 400
    [pscustomobject]@{Root=$root;Port=$port;Process=$proc;Endpoint="http://127.0.0.1:$port"}
}
function Stop-AgentPackMockServer { param($Mock) if($Mock.Process -and -not $Mock.Process.HasExited){Stop-Process -Id $Mock.Process.Id -Force -ErrorAction SilentlyContinue}; if(Test-Path -LiteralPath $Mock.Root){Remove-Item -LiteralPath $Mock.Root -Recurse -Force -ErrorAction SilentlyContinue} }

$token=ConvertTo-SecureString 'fixture-token' -AsPlainText -Force

# --- A. RAG knowledge reference resolution: found / not-found / RAG-config-absent -------
$mockA=New-AgentPackMockServer -RequestCount 6 -SeedKnowledge 1
try{
    $ragConfigPresent=Join-Path $mockA.Root 'rag.config.json'
    (@{knowledgeName='KI-Stack Controlled Knowledge'}|ConvertTo-Json)|Set-Content -LiteralPath $ragConfigPresent -Encoding utf8NoBOM
    $resolved=Get-AgentPackRAGKnowledgeReference -Endpoint $mockA.Endpoint -ApiToken $token -RAGConfigPath $ragConfigPresent
    $checks.knowledgeReferenceResolvedWhenPresent=[ordered]@{
        found=($null -ne $resolved)
        correctId=($null -ne $resolved -and [string]$resolved.id -eq 'rag-kb-0001')
        correctType=($null -ne $resolved -and [string]$resolved.type -eq 'collection')
    }
    if($checks.knowledgeReferenceResolvedWhenPresent.Values-contains$false){$fail.Add('knowledgeReferenceResolvedWhenPresent failed: '+($resolved|ConvertTo-Json -Compress))}

    $ragConfigMismatch=Join-Path $mockA.Root 'rag.config.mismatch.json'
    (@{knowledgeName='Some Other Collection'}|ConvertTo-Json)|Set-Content -LiteralPath $ragConfigMismatch -Encoding utf8NoBOM
    $unresolved=Get-AgentPackRAGKnowledgeReference -Endpoint $mockA.Endpoint -ApiToken $token -RAGConfigPath $ragConfigMismatch
    $checks.knowledgeReferenceNullWhenNameMismatch=[ordered]@{isNull=($null -eq $unresolved)}
    if(-not$checks.knowledgeReferenceNullWhenNameMismatch.isNull){$fail.Add('knowledgeReferenceNullWhenNameMismatch failed')}

    $missingRagConfigPath=Join-Path $mockA.Root 'does-not-exist.json'
    $noConfig=Get-AgentPackRAGKnowledgeReference -Endpoint $mockA.Endpoint -ApiToken $token -RAGConfigPath $missingRagConfigPath
    $checks.knowledgeReferenceNullWhenRAGNeverDeployed=[ordered]@{isNull=($null -eq $noConfig)}
    if(-not$checks.knowledgeReferenceNullWhenRAGNeverDeployed.isNull){$fail.Add('knowledgeReferenceNullWhenRAGNeverDeployed failed')}
}finally{ Stop-AgentPackMockServer -Mock $mockA }

# --- B. Full install (all 3 definitions incl. research), then idempotent re-install -----
$mockB=New-AgentPackMockServer -RequestCount 60 -SeedKnowledge 1
try{
    $ragConfigPathB=Join-Path $mockB.Root 'rag.config.json'
    (@{knowledgeName='KI-Stack Controlled Knowledge'}|ConvertTo-Json)|Set-Content -LiteralPath $ragConfigPathB -Encoding utf8NoBOM
    # Redirect the module's own default real-target RAG config path to the fixture for
    # this test only, via a text-patched copy -- the same "patch the source, run the real
    # function unmodified otherwise" approach already used by RAG's own OpenWebUI test
    # stubs, never a parallel reimplementation of Get-AgentPackRAGKnowledgeReference.
    $patchedModulePath=Join-Path $mockB.Root 'OpenWebUIAgentPack.patched.psm1'
    $moduleSource=Get-Content -LiteralPath (Join-Path $PackageRoot 'OpenWebUIAgentPack.psm1') -Raw
    $patchedSource=$moduleSource.Replace("[string]`$RAGConfigPath = 'C:\KI-Stack\modules\rag\Config\rag.config.json'", "[string]`$RAGConfigPath = '$($ragConfigPathB.Replace('\','\\'))'")
    if($patchedSource -eq $moduleSource){throw 'RAGConfigPath-Default konnte im Modultext nicht gepatcht werden -- Testannahme verletzt.'}
    Set-Content -LiteralPath $patchedModulePath -Value $patchedSource -Encoding UTF8
    Remove-Module OpenWebUIAgentPack -Force -ErrorAction SilentlyContinue
    Import-Module $patchedModulePath -Force -DisableNameChecking

    $backupDir1=Join-Path $mockB.Root 'backup1'
    $result1=Install-OpenWebUIAgentPack -PackageRoot $PackageRoot -Endpoint $mockB.Endpoint -ApiToken $token -BaseModelId $baseModelId -BackupDirectory $backupDir1
    $checks.firstInstallCreatesAllThree=[ordered]@{
        threeActions=(@($result1.actions).Count -eq 3)
        allCreated=(@($result1.actions|Where-Object action -ne 'created').Count -eq 0)
        researchKnowledgeBound=([bool](@($result1.actions|Where-Object id -eq 'ki-stack-research')[0].knowledgeBound))
    }
    if($checks.firstInstallCreatesAllThree.Values-contains$false){$fail.Add('firstInstallCreatesAllThree failed: '+($result1.actions|ConvertTo-Json -Compress))}

    $validate1=Test-OpenWebUIAgentPack -PackageRoot $PackageRoot -Endpoint $mockB.Endpoint -ApiToken $token -BaseModelId $baseModelId
    $checks.firstInstallReadbackPasses=[ordered]@{passed=$validate1.passed}
    if(-not$validate1.passed){$fail.Add('firstInstallReadbackPasses failed: '+($validate1.failures -join '; '))}

    # Reconcile: install again against the now-populated mock -- must update, not
    # duplicate, and the research profile's knowledge binding must remain exactly one
    # attachment (idempotent, matching Punkt 4's Integration/RAG reconcile lesson).
    $backupDir2=Join-Path $mockB.Root 'backup2'
    $result2=Install-OpenWebUIAgentPack -PackageRoot $PackageRoot -Endpoint $mockB.Endpoint -ApiToken $token -BaseModelId $baseModelId -BackupDirectory $backupDir2
    $checks.reconcileUpdatesNotDuplicates=[ordered]@{
        threeActions=(@($result2.actions).Count -eq 3)
        allUpdated=(@($result2.actions|Where-Object action -ne 'updated').Count -eq 0)
    }
    if($checks.reconcileUpdatesNotDuplicates.Values-contains$false){$fail.Add('reconcileUpdatesNotDuplicates failed: '+($result2.actions|ConvertTo-Json -Compress))}

    $validate2=Test-OpenWebUIAgentPack -PackageRoot $PackageRoot -Endpoint $mockB.Endpoint -ApiToken $token -BaseModelId $baseModelId
    $researchModel=Get-AgentPackManagedModel -Endpoint $mockB.Endpoint -ApiToken $token -Id 'ki-stack-research'
    $checks.reconcileNoDuplicateKnowledgeOrTools=[ordered]@{
        readbackPassed=$validate2.passed
        exactlyOneKnowledgeEntry=(@($researchModel.meta.knowledge).Count -eq 1)
        noToolIdsBound=(@($researchModel.meta.toolIds).Count -eq 0)
        forbiddenBuiltinToolsStillFalse=(-not [bool]$researchModel.meta.builtinTools.image_generation -and -not [bool]$researchModel.meta.builtinTools.subagents -and -not [bool]$researchModel.meta.builtinTools.files)
        allowedBuiltinToolsStillTrue=([bool]$researchModel.meta.builtinTools.knowledge -and [bool]$researchModel.meta.builtinTools.web_search -and [bool]$researchModel.meta.builtinTools.code_interpreter)
    }
    if($checks.reconcileNoDuplicateKnowledgeOrTools.Values-contains$false){$fail.Add('reconcileNoDuplicateKnowledgeOrTools failed: '+($checks.reconcileNoDuplicateKnowledgeOrTools|ConvertTo-Json -Compress))}

    $listed=Invoke-AgentPackApi -Endpoint $mockB.Endpoint -ApiToken $token -Path '/api/v1/models/list?page=1'
    $checks.noDuplicateModelEntries=[ordered]@{
        exactlyThreeManaged=(@($listed.items|Where-Object{[string]$_.id -like 'ki-stack-*'}).Count -eq 3)
    }
    if(-not$checks.noDuplicateModelEntries.exactlyThreeManaged){$fail.Add('noDuplicateModelEntries failed: '+(@($listed.items.id) -join ', '))}
}finally{
    Remove-Module OpenWebUIAgentPack -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PackageRoot 'OpenWebUIAgentPack.psm1') -Force -DisableNameChecking
    Stop-AgentPackMockServer -Mock $mockB
}

# --- D. Missing RAG knowledge: ki-stack-research must be skipped (never created empty),
# and the other two definitions must still complete normally and not be damaged. ---------
$mockD=New-AgentPackMockServer -RequestCount 40 -SeedKnowledge 0
try{
    $ragConfigPathD=Join-Path $mockD.Root 'rag.config.json'
    (@{knowledgeName='KI-Stack Controlled Knowledge'}|ConvertTo-Json)|Set-Content -LiteralPath $ragConfigPathD -Encoding utf8NoBOM
    $patchedModulePathD=Join-Path $mockD.Root 'OpenWebUIAgentPack.patched.psm1'
    $moduleSourceD=Get-Content -LiteralPath (Join-Path $PackageRoot 'OpenWebUIAgentPack.psm1') -Raw
    $patchedSourceD=$moduleSourceD.Replace("[string]`$RAGConfigPath = 'C:\KI-Stack\modules\rag\Config\rag.config.json'", "[string]`$RAGConfigPath = '$($ragConfigPathD.Replace('\','\\'))'")
    if($patchedSourceD -eq $moduleSourceD){throw 'RAGConfigPath-Default konnte im Modultext nicht gepatcht werden -- Testannahme verletzt.'}
    Set-Content -LiteralPath $patchedModulePathD -Value $patchedSourceD -Encoding UTF8
    Remove-Module OpenWebUIAgentPack -Force -ErrorAction SilentlyContinue
    Import-Module $patchedModulePathD -Force -DisableNameChecking

    $backupDirD=Join-Path $mockD.Root 'backup'
    $resultD=Install-OpenWebUIAgentPack -PackageRoot $PackageRoot -Endpoint $mockD.Endpoint -ApiToken $token -BaseModelId $baseModelId -BackupDirectory $backupDirD
    $researchAction=@($resultD.actions|Where-Object id -eq 'ki-stack-research')[0]
    $otherActions=@($resultD.actions|Where-Object id -ne 'ki-stack-research')
    $checks.missingKnowledgeSkipsResearchOnly=[ordered]@{
        researchSkipped=([string]$researchAction.action -eq 'skipped')
        researchReasonNamesKnowledge=([string]$researchAction.reason -match '(?i)knowledge')
        otherTwoStillProcessed=(@($otherActions).Count -eq 2 -and (@($otherActions|Where-Object{$_.action-ne'created'}).Count-eq0))
    }
    if($checks.missingKnowledgeSkipsResearchOnly.Values-contains$false){$fail.Add('missingKnowledgeSkipsResearchOnly failed: '+($resultD.actions|ConvertTo-Json -Compress))}

    $researchModelD=Get-AgentPackManagedModel -Endpoint $mockD.Endpoint -ApiToken $token -Id 'ki-stack-research'
    $checks.noDummyKnowledgeModelCreated=[ordered]@{ notCreated=($null -eq $researchModelD) }
    if(-not$checks.noDummyKnowledgeModelCreated.notCreated){$fail.Add('noDummyKnowledgeModelCreated failed: a model was created despite unresolved RAG knowledge')}

    $validateD=Test-OpenWebUIAgentPack -PackageRoot $PackageRoot -Endpoint $mockD.Endpoint -ApiToken $token -BaseModelId $baseModelId
    $checks.readbackTreatsSkipAsPassNotFailure=[ordered]@{
        passed=$validateD.passed
        reportsSkipped=(@($validateD.skipped) -contains 'ki-stack-research')
    }
    if($checks.readbackTreatsSkipAsPassNotFailure.Values-contains$false){$fail.Add('readbackTreatsSkipAsPassNotFailure failed: '+($validateD|ConvertTo-Json -Compress))}
}finally{
    Remove-Module OpenWebUIAgentPack -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PackageRoot 'OpenWebUIAgentPack.psm1') -Force -DisableNameChecking
    Stop-AgentPackMockServer -Mock $mockD
}

# --- E. Direct, HTTP-free New-AgentPackModelForm checks (definition/form contract) ------
$allDefinitions=Get-AgentPackDefinitions -PackageRoot $PackageRoot
$checks.uniqueDefinitionIds=[ordered]@{ allUnique=((@($allDefinitions.id)|Select-Object -Unique).Count -eq @($allDefinitions).Count) }
if(-not$checks.uniqueDefinitionIds.allUnique){$fail.Add('uniqueDefinitionIds failed: '+(@($allDefinitions.id) -join ', '))}

$researchDefinition=$allDefinitions|Where-Object id -eq 'ki-stack-research'
$sampleAttachment=[pscustomobject]@{type='collection';id='rag-kb-form-check';name='KI-Stack Controlled Knowledge'}
$formOnce=New-AgentPackModelForm -Definition $researchDefinition -BaseModelId $baseModelId -ExtensionToolIds @('ki_stack_generate_image','ki_stack_generate_video') -KnowledgeAttachments @($sampleAttachment)
$formTwice=New-AgentPackModelForm -Definition $researchDefinition -BaseModelId $baseModelId -ExtensionToolIds @('ki_stack_generate_image','ki_stack_generate_video') -KnowledgeAttachments @($sampleAttachment)

$checks.formCoreFields=[ordered]@{
    correctBaseModel=([string]$formOnce.base_model_id -eq $baseModelId)
    nameNonEmpty=(-not [string]::IsNullOrWhiteSpace([string]$formOnce.name))
    functionCallingNative=([string]$formOnce.params.function_calling -eq 'native')
    systemPromptNonEmpty=(-not [string]::IsNullOrWhiteSpace([string]$formOnce.params.system))
}
if($checks.formCoreFields.Values-contains$false){$fail.Add('formCoreFields failed: '+($formOnce|ConvertTo-Json -Compress))}

$checks.formKnowledgeAttachmentStructure=[ordered]@{
    exactlyOneAttachment=(@($formOnce.meta.knowledge).Count -eq 1)
    hasType=(-not [string]::IsNullOrWhiteSpace([string]$formOnce.meta.knowledge[0].type))
    hasId=(-not [string]::IsNullOrWhiteSpace([string]$formOnce.meta.knowledge[0].id))
    hasName=(-not [string]::IsNullOrWhiteSpace([string]$formOnce.meta.knowledge[0].name))
    typeIsCollection=([string]$formOnce.meta.knowledge[0].type -eq 'collection')
}
if($checks.formKnowledgeAttachmentStructure.Values-contains$false){$fail.Add('formKnowledgeAttachmentStructure failed: '+($formOnce.meta.knowledge|ConvertTo-Json -Compress))}

$checks.formNoExtensionToolsOrForbiddenCapabilities=[ordered]@{
    noToolIds=(@($formOnce.meta.toolIds).Count -eq 0)
    noSkillIds=(@($formOnce.meta.skillIds).Count -eq 0)
    noFunctionIds=(@($formOnce.meta.functionIds).Count -eq 0)
    imageGenerationDenied=(-not [bool]$formOnce.meta.capabilities.image_generation)
    memoryDenied=(-not [bool]$formOnce.meta.capabilities.memory)
    fileUploadDenied=(-not [bool]$formOnce.meta.capabilities.file_upload)
    terminalDenied=(-not [bool]$formOnce.meta.capabilities.terminal)
    codeInterpreterAllowed=([bool]$formOnce.meta.capabilities.code_interpreter)
    webSearchAllowed=([bool]$formOnce.meta.capabilities.web_search)
}
if($checks.formNoExtensionToolsOrForbiddenCapabilities.Values-contains$false){$fail.Add('formNoExtensionToolsOrForbiddenCapabilities failed: '+($formOnce.meta|ConvertTo-Json -Compress))}

$requiredPromptClauses=@(
    'Lokales Wissen','Websuche','Code Interpreter',
    'Erfinde niemals','getrennt','ausdruecklich','Schreibzugriff','Werkzeugaufrufe fort'
)
$missingPromptClauses=@($requiredPromptClauses|Where-Object{$formOnce.params.system -notmatch [regex]::Escape($_)})
$checks.promptContainsCoreRules=[ordered]@{ allPresent=(@($missingPromptClauses).Count -eq 0) }
if(-not$checks.promptContainsCoreRules.allPresent){$fail.Add('promptContainsCoreRules failed: missing='+($missingPromptClauses -join ', '))}

$checks.formGenerationIsDeterministic=[ordered]@{
    identicalJson=((($formOnce|ConvertTo-Json -Depth 20 -Compress))-eq(($formTwice|ConvertTo-Json -Depth 20 -Compress)))
}
if(-not$checks.formGenerationIsDeterministic.identicalJson){$fail.Add('formGenerationIsDeterministic failed: two calls with identical inputs produced different output')}

# --- C. Missing credential must not silently proceed anonymously -----------------------
$checks.missingCredentialRejected=[ordered]@{}
$threwOnNullToken=$false
try{ [void](Invoke-AgentPackApi -Endpoint 'http://127.0.0.1:1' -ApiToken $null -Path '/api/v1/models') }
catch{ $threwOnNullToken=$true }
$checks.missingCredentialRejected.threw=$threwOnNullToken
if(-not$threwOnNullToken){$fail.Add('missingCredentialRejected failed: a null ApiToken did not throw')}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'Agent-Pack-Research-Contract-Regression fehlgeschlagen.'}

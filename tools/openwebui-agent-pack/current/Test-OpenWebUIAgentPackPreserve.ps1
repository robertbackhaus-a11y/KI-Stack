[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

# Regression suite for the Agent-Pack reconcile field-ownership contract
# (Resolve-AgentPackReconcileForm / Merge-AgentPackObjectValueByKey). Root cause under
# test: OpenWebUI's real update_model_by_id() replaces `meta` wholesale rather than
# merging it, so a naive reconcile that sends New-AgentPackModelForm's output directly on
# Update silently destroys any live-only state a real admin added outside the package
# process (observed for real on ki-stack-it-technik/ki-stack-allgemein: extra
# meta.capabilities keys, a meta.builtinTools.knowledge=false toggle, a longer
# params.system). This suite seeds a mock OpenWebUI model with exactly that kind of live
# drift *before* the Agent Pack ever runs against it, then asserts the drift survives a
# reconcile untouched while package-managed fields are still correctly enforced/updated --
# and includes a negative control proving the suite actually fails under the old,
# pre-fix replace behavior.

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
    param([int]$RequestCount,[int]$SeedKnowledge=0,[object[]]$SeedModels=@())
    $root=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-AgentPackPreserveMock-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    if(@($SeedModels).Count -gt 0){
        (@($SeedModels)|ConvertTo-Json -Depth 30 -AsArray)|Set-Content -LiteralPath (Join-Path $root 'models.json') -Encoding ascii
    }
    $port=Get-Random -Minimum 46000 -Maximum 49000
    $script=Join-Path $root 'mock.ps1'
    Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value $mockServerScriptContent
    $proc=Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$script,'-Port',$port,'-RequestCount',$RequestCount,'-StateDir',$root,'-BaseModelId',$baseModelId,'-SeedKnowledge',$SeedKnowledge) -PassThru
    Start-Sleep -Milliseconds 400
    [pscustomobject]@{Root=$root;Port=$port;Process=$proc;Endpoint="http://127.0.0.1:$port"}
}
function Stop-AgentPackMockServer { param($Mock) if($Mock.Process -and -not $Mock.Process.HasExited){Stop-Process -Id $Mock.Process.Id -Force -ErrorAction SilentlyContinue}; if(Test-Path -LiteralPath $Mock.Root){Remove-Item -LiteralPath $Mock.Root -Recurse -Force -ErrorAction SilentlyContinue} }

$token=ConvertTo-SecureString 'fixture-token' -AsPlainText -Force

# Under the negative control, a key that the fix would normally preserve is genuinely
# ABSENT from the object (not merely $null-valued) -- StrictMode throws on `.Name` access
# for a truly missing PSCustomObject property, so every lookup below goes through this
# helper instead of bare dot-notation.
function Get-JsonPropertyOrNull {
    param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# A pre-existing it-technik model carrying exactly the kind of live-only drift really
# observed on the target: a richer meta.capabilities set, a builtinTools toggle the
# package definition has never declared, an entirely unknown meta key, a non-empty
# access_grants list, and (Fall D fixture) a stale name/system/base_model_id that the
# package *is* supposed to correct on reconcile.
$seedItTechnik = [ordered]@{
    id='ki-stack-it-technik'
    base_model_id='some-stale-base-model-no-longer-offered'
    name='KI & IT-Technik (stale live name)'
    meta=[ordered]@{
        description='stale description'
        capabilities=[ordered]@{ code_interpreter=$false; vision=$true; pdf_ocr=$true }
        knowledge=@()
        toolIds=@('some-stale-tool-id')
        skillIds=@()
        functionIds=@()
        managedBy='KI-STACK-OPENWEBUI-AGENT-PACK'
        agentPackVersion='1.8.9'
        builtinTools=[ordered]@{ knowledge=$false; custom_extra_category=$true }
        customAdminNote='Do not touch -- manually added via OpenWebUI UI'
        profile_image_url='/static/custom-admin-avatar.png'
    }
    params=[ordered]@{ system='STALE PROMPT -- must be replaced by reconcile'; function_calling='native' }
    access_grants=@(@{ group_id='it-team'; permission='read' })
    is_active=$true
}
# A pre-existing research model with a live builtinTools drift on a key the package DOES
# manage (knowledge, deliberately live-flipped to false) plus a foreign key the package
# has never declared -- exercises the Merge branch (not just the omitted-builtinTools
# branch exercised by it-technik above).
$seedResearch = [ordered]@{
    id='ki-stack-research'
    base_model_id=$baseModelId
    name='KI-Stack Research'
    meta=[ordered]@{
        description='x'
        capabilities=[ordered]@{ code_interpreter=$true; web_search=$true; image_generation=$false; memory=$false; file_upload=$false; terminal=$false }
        knowledge=@(@{type='collection';id='rag-kb-0001';name='KI-Stack Controlled Knowledge'})
        toolIds=@()
        skillIds=@()
        functionIds=@()
        managedBy='KI-STACK-OPENWEBUI-AGENT-PACK'
        agentPackVersion='1.8.9'
        builtinTools=[ordered]@{
            time=$false; user_input=$false; files=$false; knowledge=$false; chats=$false
            subagents=$false; memory=$false; web_search=$true; image_generation=$false
            code_interpreter=$true; notes=$false; custom_extra_category=$true
        }
    }
    params=[ordered]@{ system='x'; function_calling='native' }
    access_grants=@()
    is_active=$true
}

function Invoke-PreserveAssertions {
    param([Parameter(Mandatory)][string]$ModuleUnderTestPath,[Parameter(Mandatory)][string]$Label,[Parameter(Mandatory)][ref]$ChecksRef,[Collections.Generic.List[string]]$FailRef,[switch]$ExpectPreserveToWork)
    $mock=New-AgentPackMockServer -RequestCount 90 -SeedKnowledge 1 -SeedModels @($seedItTechnik,$seedResearch)
    try{
        $ragConfigPath=Join-Path $mock.Root 'rag.config.json'
        (@{knowledgeName='KI-Stack Controlled Knowledge'}|ConvertTo-Json)|Set-Content -LiteralPath $ragConfigPath -Encoding utf8NoBOM
        $moduleSource=Get-Content -LiteralPath $ModuleUnderTestPath -Raw
        $patchedSource=$moduleSource.Replace("[string]`$RAGConfigPath = 'C:\KI-Stack\modules\rag\Config\rag.config.json'", "[string]`$RAGConfigPath = '$($ragConfigPath.Replace('\','\\'))'")
        if($patchedSource -eq $moduleSource){throw 'RAGConfigPath-Default konnte im Modultext nicht gepatcht werden -- Testannahme verletzt.'}
        $patchedModulePath=Join-Path $mock.Root 'OpenWebUIAgentPack.patched.psm1'
        Set-Content -LiteralPath $patchedModulePath -Value $patchedSource -Encoding UTF8
        Remove-Module OpenWebUIAgentPack -Force -ErrorAction SilentlyContinue
        Import-Module $patchedModulePath -Force -DisableNameChecking

        $backupDir=Join-Path $mock.Root 'backup'
        $result=Install-OpenWebUIAgentPack -PackageRoot $PackageRoot -Endpoint $mock.Endpoint -ApiToken $token -BaseModelId $baseModelId -BackupDirectory $backupDir
        $itTechnikAfter=Get-AgentPackManagedModel -Endpoint $mock.Endpoint -ApiToken $token -Id 'ki-stack-it-technik'
        $researchAfter=Get-AgentPackManagedModel -Endpoint $mock.Endpoint -ApiToken $token -Id 'ki-stack-research'

        $refChecks = $ChecksRef.Value

        # Fall A: unmanaged meta.capabilities keys survive; the package-declared key
        # (code_interpreter) is reasserted to the package's own value regardless of the
        # stale live value ($false in the seed).
        $capOk = [ordered]@{
            visionPreserved = ([bool](Get-JsonPropertyOrNull -Object $itTechnikAfter.meta.capabilities -Name 'vision') -eq $true)
            pdfOcrPreserved = ([bool](Get-JsonPropertyOrNull -Object $itTechnikAfter.meta.capabilities -Name 'pdf_ocr') -eq $true)
            codeInterpreterReasserted = ([bool](Get-JsonPropertyOrNull -Object $itTechnikAfter.meta.capabilities -Name 'code_interpreter') -eq $true)
        }
        $refChecks["$Label.fallA_capabilitiesMerge"] = $capOk
        if($ExpectPreserveToWork){
            if($capOk.Values -contains $false){ $FailRef.Add("$Label/fallA_capabilitiesMerge failed: "+($itTechnikAfter.meta.capabilities|ConvertTo-Json -Compress)) }
        } else {
            if(-not ($capOk.Values -contains $false)){ $FailRef.Add("$Label/fallA_capabilitiesMerge did not fail under the disabled-preserve negative control (test does not actually detect the regression)") }
        }

        # Fall B: unmanaged meta.builtinTools key survives on a profile with NO declared
        # builtinTools (it-technik, whole dict preserved verbatim); on the research profile
        # (which DOES declare builtinTools), the package-declared 'knowledge' key is
        # reasserted to true even though live had it flipped to false, while the foreign
        # 'custom_extra_category' key survives untouched.
        $itTechnikBuiltinTools = Get-JsonPropertyOrNull -Object $itTechnikAfter.meta -Name 'builtinTools'
        $researchBuiltinTools = Get-JsonPropertyOrNull -Object $researchAfter.meta -Name 'builtinTools'
        $builtinOk = [ordered]@{
            itTechnikWholeDictPreserved = ([bool](Get-JsonPropertyOrNull -Object $itTechnikBuiltinTools -Name 'knowledge') -eq $false -and [bool](Get-JsonPropertyOrNull -Object $itTechnikBuiltinTools -Name 'custom_extra_category') -eq $true)
            researchKnowledgeReasserted = ([bool](Get-JsonPropertyOrNull -Object $researchBuiltinTools -Name 'knowledge') -eq $true)
            researchForeignKeyPreserved = ([bool](Get-JsonPropertyOrNull -Object $researchBuiltinTools -Name 'custom_extra_category') -eq $true)
        }
        $refChecks["$Label.fallB_builtinToolsMerge"] = $builtinOk
        if($ExpectPreserveToWork){
            if($builtinOk.Values -contains $false){ $FailRef.Add("$Label/fallB_builtinToolsMerge failed: it="+($itTechnikAfter.meta.builtinTools|ConvertTo-Json -Compress)+' research='+($researchAfter.meta.builtinTools|ConvertTo-Json -Compress)) }
        } else {
            if(-not ($builtinOk.Values -contains $false)){ $FailRef.Add("$Label/fallB_builtinToolsMerge did not fail under the disabled-preserve negative control") }
        }

        # Fall C: an entirely unknown meta key (customAdminNote) and profile_image_url
        # survive a reconcile even though the package has no concept of either.
        $unknownOk = [ordered]@{
            customAdminNoteSurvived = ([string](Get-JsonPropertyOrNull -Object $itTechnikAfter.meta -Name 'customAdminNote') -eq 'Do not touch -- manually added via OpenWebUI UI')
            profileImageUrlSurvived = ([string](Get-JsonPropertyOrNull -Object $itTechnikAfter.meta -Name 'profile_image_url') -eq '/static/custom-admin-avatar.png')
            accessGrantsSurvived = (@($itTechnikAfter.access_grants).Count -eq 1 -and [string]$itTechnikAfter.access_grants[0].group_id -eq 'it-team')
        }
        $refChecks["$Label.fallC_unknownMetaKeyAndAccessGrantsSurvive"] = $unknownOk
        if($ExpectPreserveToWork){
            if($unknownOk.Values -contains $false){ $FailRef.Add("$Label/fallC_unknownMetaKeyAndAccessGrantsSurvive failed: "+($itTechnikAfter|ConvertTo-Json -Compress -Depth 10)) }
        } else {
            if(-not ($unknownOk.Values -contains $false)){ $FailRef.Add("$Label/fallC_unknownMetaKeyAndAccessGrantsSurvive did not fail under the disabled-preserve negative control") }
        }

        # Fall D: package-managed fields ARE actively corrected on reconcile, regardless of
        # preserve/replace mode -- this must hold true in BOTH runs (it is not part of the
        # negative control's expected failure).
        $managedOk = [ordered]@{
            nameUpdated = ([string]$itTechnikAfter.name -eq 'KI & IT-Technik')
            baseModelIdUpdated = ([string]$itTechnikAfter.base_model_id -eq $baseModelId)
            systemPromptUpdated = (([string]$itTechnikAfter.params.system) -notmatch 'STALE PROMPT')
            agentPackVersionUpdated = ([string]$itTechnikAfter.meta.agentPackVersion -ne '1.8.9')
        }
        $refChecks["$Label.fallD_managedFieldsAreUpdated"] = $managedOk
        if($managedOk.Values -contains $false){ $FailRef.Add("$Label/fallD_managedFieldsAreUpdated failed: "+($itTechnikAfter|ConvertTo-Json -Compress -Depth 10)) }

        # Fall E: a brand-new model (no live state at all) gets exactly the fully-defined
        # package state -- the merge is a no-op on first create.
        $allgemeinAfter=Get-AgentPackManagedModel -Endpoint $mock.Endpoint -ApiToken $token -Id 'ki-stack-allgemein'
        $createOk=[ordered]@{
            existsAfterFirstInstall=($null -ne $allgemeinAfter)
            noForeignKeysInvented=(@($allgemeinAfter.meta.PSObject.Properties.Name) -notcontains 'customAdminNote')
            emptyAccessGrantsOnCreate=(@($allgemeinAfter.access_grants).Count -eq 0)
        }
        $refChecks["$Label.fallE_freshCreateIsFullPackageState"] = $createOk
        if($createOk.Values -contains $false){ $FailRef.Add("$Label/fallE_freshCreateIsFullPackageState failed: "+($allgemeinAfter|ConvertTo-Json -Compress -Depth 10)) }

        return [pscustomobject]@{ install=$result }
    } finally {
        Remove-Module OpenWebUIAgentPack -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $PackageRoot 'OpenWebUIAgentPack.psm1') -Force -DisableNameChecking
        Stop-AgentPackMockServer -Mock $mock
    }
}

# --- Positive run: the real, fixed module -----------------------------------------------
[void](Invoke-PreserveAssertions -ModuleUnderTestPath (Join-Path $PackageRoot 'OpenWebUIAgentPack.psm1') -Label 'fixed' -ChecksRef ([ref]$checks) -FailRef $fail -ExpectPreserveToWork)

# --- Negative control: patch Install-OpenWebUIAgentPack back to the pre-fix behavior
# (send the freshly generated form directly, bypassing Resolve-AgentPackReconcileForm) and
# confirm Fall A/B/C now genuinely fail -- proving this suite actually detects the
# regression it exists to prevent, not just a self-consistent tautology. Fall D/E are
# unaffected by this toggle (their assertions still hold under the old behavior too) and
# are intentionally not part of the failure check above.
$moduleSourceForNegativeControl=Get-Content -LiteralPath (Join-Path $PackageRoot 'OpenWebUIAgentPack.psm1') -Raw
$negativeControlSource=$moduleSourceForNegativeControl.Replace(
    '$reconcileForm = Resolve-AgentPackReconcileForm -GeneratedForm $form -CurrentModel $current -RequiresKnowledge $requiresKnowledge',
    '$reconcileForm = $form'
)
if($negativeControlSource -eq $moduleSourceForNegativeControl){ throw 'Negative-Control-Patch griff nicht -- Testannahme verletzt (Zeile im Modul nicht gefunden).' }
$negativeControlRoot=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-AgentPackPreserveNegControl-'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $negativeControlRoot -Force|Out-Null
$negativeControlModulePath=Join-Path $negativeControlRoot 'OpenWebUIAgentPack.psm1'
Set-Content -LiteralPath $negativeControlModulePath -Value $negativeControlSource -Encoding UTF8
try{
    [void](Invoke-PreserveAssertions -ModuleUnderTestPath $negativeControlModulePath -Label 'negativeControl' -ChecksRef ([ref]$checks) -FailRef $fail)
} finally {
    Remove-Item -LiteralPath $negativeControlRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'Agent-Pack-Preserve-Reconcile-Regression fehlgeschlagen.'}

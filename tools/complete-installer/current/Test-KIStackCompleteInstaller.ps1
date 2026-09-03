[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fail = [Collections.Generic.List[string]]::new()

$manifest = Get-Content -LiteralPath (Join-Path $PackageRoot 'MANIFEST.json') -Raw | ConvertFrom-Json
$components = Get-Content -LiteralPath (Join-Path $PackageRoot 'Contracts\COMPONENTS.json') -Raw | ConvertFrom-Json
$payloads = Get-Content -LiteralPath (Join-Path $PackageRoot 'Contracts\PAYLOADS.json') -Raw | ConvertFrom-Json
foreach($requiredTest in @('Test-KIStackInstallationContracts.ps1','Test-KIStackCompleteInstallerTarget.ps1','Test-KIStackExitCodePropagation.ps1','Test-KIStackBootstrapLogging.ps1','Test-KIStackRequiredPayloads.ps1','Test-RC12PendingComfyRollback.ps1','Test-RC13FailedStateRecovery.ps1','Test-KIStackOpenWebUIVisualPackCutover.ps1','Test-KIStackInstallerHeartbeat.ps1','Test-KIStackOpenWebUIManagedUpdate.ps1','Test-KIStackPayloadDeploymentHygiene.ps1','Test-KIStackReplayComponent.ps1','Test-KIStackUpdateAll.ps1','Test-KIStackUpdateIsolation.ps1','Test-KIStackPinnedReferenceReconciliation.ps1','Test-KIStackComfyUICompliance.ps1','Test-KIStackComfyUIOverlayProtection.ps1','Test-KIStackFailedTransactionComfyUIRecovery.ps1','Start-KIStack-Installer.cmd','Bootstrap-KIStackPowerShell7.ps1','Start-KIStack-Audit.cmd','Start-KIStack-DryRun.cmd')){
    if(-not(Test-Path -LiteralPath (Join-Path $PackageRoot $requiredTest) -PathType Leaf)){$fail.Add("Required test missing: $requiredTest")}
}
$executeStarter=Get-Content -LiteralPath (Join-Path $PackageRoot 'Start-KIStack-Installer.cmd') -Raw
foreach($marker in @('KI-Stack-Installer-output.txt','Start-KIStackCompleteInstaller.ps1','CompleteInstaller.psm1','INSTALLATION BEENDET. Exitcode 0.','INSTALLATION FEHLGESCHLAGEN. Exitcode %RC%.','pause')){
    if(-not$executeStarter.Contains($marker)){$fail.Add("Execute starter contract: $marker")}
}

if ($manifest.version -ne '2.13.0' -or $manifest.baseVersion -ne '2.12.0') { $fail.Add('Version contract') }
if ($payloads.modelPolicy.chatModels.Count -ne 1 -or $payloads.modelPolicy.chatModels[0] -ne 'qwen3.6-27b-uncensored-heretic-v2-native-mtp-preserved') { $fail.Add('Heretic chat-only contract') }
if ($payloads.modelPolicy.nomicRole -ne 'embedding-only' -or $payloads.modelPolicy.embeddingModels.Count -ne 1) { $fail.Add('Nomic embedding-only contract') }
if ([string]$payloads.modelContractAuthority.packagedArchive -ne 'Payload/ModelsWorkflows/KI-Stack-Visual-Models-Workflows-v2.0.3.zip') { $fail.Add('Authoritative model contract') }
if ($payloads.PSObject.Properties.Name -contains 'external' -or $payloads.PSObject.Properties.Name -contains 'lmStudioModel') { $fail.Add('Duplicate model contract') }
if (@($components.components | Where-Object id -eq 'openwebui-visual-pack').version -ne '2.0.5') { $fail.Add('Visual Pack component') }
if (@($components.components | Where-Object id -eq 'openwebui-agent-pack').version -ne '1.9.0') { $fail.Add('Agent Pack component') }
if ([int]@($components.components | Where-Object id -eq 'openwebui-visual-pack').order -ge [int]@($components.components | Where-Object id -eq 'openwebui-agent-pack').order) { $fail.Add('Visual Pack must deploy before Agent Pack') }
if (@($components.components | Where-Object id -eq 'models-workflows').version -ne '2.0.3') { $fail.Add('Visual Models component') }
$codexComponent=@($components.components|Where-Object id -eq 'codex-local')
$ragComponent=@($components.components|Where-Object id -eq 'rag')
if($codexComponent.Count-ne1-or$codexComponent.version-ne'0.2.1'-or-not[bool]$codexComponent.installable){$fail.Add('Codex Local component')}
if($ragComponent.Count-ne1-or$ragComponent.version-ne'0.4.0'-or-not[bool]$ragComponent.installable){$fail.Add('RAG component')}
if([int]$codexComponent.order-ge[int]$ragComponent.order){$fail.Add('Codex Local must deploy before RAG')}
$openTerminalComponent=@($components.components|Where-Object id -eq 'open-terminal')
if($openTerminalComponent.Count-ne1-or$openTerminalComponent.version-ne'0.1.0'-or-not[bool]$openTerminalComponent.installable){$fail.Add('Open Terminal component')}
if(@($openTerminalComponent.requires)-notcontains'python-git'){$fail.Add('Open Terminal must declare its real python-git/managed-uv prerequisite')}
if([int]$ragComponent.order-ge[int]$openTerminalComponent.order){$fail.Add('RAG must deploy before Open Terminal')}
$validationComponent = @($components.components | Where-Object id -eq 'validation-gate')
if ($validationComponent.version -ne '1.0.3' -or -not [bool]$validationComponent.installable) { $fail.Add('Validation Gate installable component') }
$installableWithoutProbe=@($components.components|Where-Object{$_.installable-and(-not($_.PSObject.Properties.Name-contains'probe')-or$null-eq$_.probe)})
if($installableWithoutProbe.Count){$fail.Add('Installable component without real probe')}
$invalidPinned=@($components.components|Where-Object{$_.id-in@('foundation-runtime','python-git','applications','cutover-runtime')-and[bool]$_.installable})
if($invalidPinned.Count){$fail.Add('Non-executable Cutover references marked installable')}

$requiredPayloadResult=& (Join-Path $PackageRoot 'Test-KIStackRequiredPayloads.ps1') -PackageRoot $PackageRoot
if(-not$requiredPayloadResult.passed){$fail.Add('Required payload assembly: '+($requiredPayloadResult.failures-join'; '))}
$payloadFixture=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-PayloadFixture-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path (Join-Path $payloadFixture 'Contracts') -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'Contracts/REQUIRED-PAYLOADS.json'),(Join-Path $PackageRoot 'Contracts/COMPONENTS.json') -Destination (Join-Path $payloadFixture 'Contracts')
    $payloadContract=Get-Content -LiteralPath (Join-Path $payloadFixture 'Contracts/REQUIRED-PAYLOADS.json') -Raw|ConvertFrom-Json
    foreach($entry in @($payloadContract.payloads|Where-Object required)){$directory=Join-Path $payloadFixture ('Payload/'+[string]$entry.key);New-Item -ItemType Directory -Path $directory -Force|Out-Null;[IO.File]::WriteAllBytes((Join-Path $directory ([string]$entry.file)),[byte[]](1))}
    Remove-Item -LiteralPath (Join-Path $payloadFixture 'Payload/ComfyUI/KI-Stack-ComfyUI-Execute-v1.2.4.zip') -Force
    $missingPayloadResult=& (Join-Path $PackageRoot 'Test-KIStackRequiredPayloads.ps1') -PackageRoot $payloadFixture
    if($missingPayloadResult.passed-or@($missingPayloadResult.failures|Where-Object{$_-match'ComfyUI'}).Count-ne1){$fail.Add('Missing required payload regression')}
}finally{if(Test-Path -LiteralPath $payloadFixture){Remove-Item -LiteralPath $payloadFixture -Recurse -Force}}

$visualZip = Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Payload\OpenWebUIVisualPack') -File -Filter '*.zip'
$modelsZip = Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Payload\ModelsWorkflows') -File -Filter '*.zip'
$agentZip = Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Payload\OpenWebUIAgentPack') -File -Filter '*.zip'
$integrationZip = Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Payload\Integration') -File -Filter '*.zip'
$codexZip = Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Payload\CodexLocal') -File -Filter '*.zip'
$ragZip = Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Payload\RAG') -File -Filter '*.zip'
$openTerminalZip = Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Payload\OpenTerminal') -File -Filter '*.zip'
if (@($visualZip).Count -ne 1 -or @($modelsZip).Count -ne 1 -or @($integrationZip).Count-ne1 -or @($codexZip).Count-ne1 -or @($ragZip).Count-ne1 -or @($openTerminalZip).Count-ne1) { $fail.Add('Payload archive count') }

Add-Type -AssemblyName System.IO.Compression.FileSystem
if(@($integrationZip).Count-eq1){
    $archive=[IO.Compression.ZipFile]::OpenRead($integrationZip[0].FullName)
    try{
        $names=@($archive.Entries.FullName)
        foreach($requiredRuntime in @('Runtime/RUNTIME-CONTRACT.json','Runtime/Start-KIStack-IntegratedStack.cmd','Runtime/Start-KIStack-OpenWebUI-WithSearch.cmd','Runtime/Start-KIStack-SearXNG.cmd','Runtime/Start-KIStack-SearXNG.ps1','Runtime/Stop-KIStack-IntegratedStack.cmd','Runtime/Stop-KIStack-SearXNG.cmd','Runtime/Stop-KIStack-SearXNG.ps1')){
            if($requiredRuntime-notin$names){$fail.Add("Integration runtime payload missing: $requiredRuntime")}
        }
    }finally{$archive.Dispose()}
}
if (@($visualZip).Count -eq 1) {
    $archive = [IO.Compression.ZipFile]::OpenRead($visualZip[0].FullName)
    try {
        $video = $archive.Entries | Where-Object FullName -match '/Tool/ki-stack-generate-video.py$' | Select-Object -First 1
        if (-not $video) { $fail.Add('Video adapter missing') }
        else {
            $reader = [IO.StreamReader]::new($video.Open())
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            if (-not $text.Contains('{"type": "files", "data": {"files": files}}')) { $fail.Add('Native files event') }
            if ($text.Contains('chat:message:files') -or $text.Contains('add_message_files_by_id_and_message_id')) { $fail.Add('Duplicate attachment path') }
            if (-not $text.Contains('/api/v1/files/{file_id}/content')) { $fail.Add('Persistent MP4 content route') }
        }
    } finally { $archive.Dispose() }
}

if (@($agentZip).Count -eq 1) {
    $archive = [IO.Compression.ZipFile]::OpenRead($agentZip[0].FullName)
    try {
        $entry = $archive.Entries | Where-Object FullName -eq 'OpenWebUIAgentPack.psm1' | Select-Object -First 1
        $reader = [IO.StreamReader]::new($entry.Open())
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if (-not $text.Contains("[string]`$_.id -eq 'qwen3.6-27b-uncensored-heretic-v2-native-mtp-preserved'")) { $fail.Add('Heretic-only agent binding') }
        foreach($visualContract in @('ki_stack_generate_image','ki_stack_generate_video','2.0.5')){
            if(-not$text.Contains($visualContract)){$fail.Add("Agent visual-tool contract: $visualContract")}
        }
        $legacyOwner = ('KI-STACK-OPENWEBUI-' + 'IMAGE-PACK')
        if ($text.Contains($legacyOwner)) { $fail.Add('Legacy extension ownership') }
    } finally { $archive.Dispose() }
}
$bootstrap=Get-Content -LiteralPath (Join-Path $PackageRoot 'Bootstrap-KIStackPowerShell7.ps1') -Raw
foreach($marker in @('Payload\CutoverRuntime','KIModuleRuntime.psm1','Install-KIModuleRuntime','Microsoft.PowerShell','Get-KIBootstrapPowerShell7','Start-Process -FilePath $pwsh')){
    if(-not$bootstrap.Contains($marker)){$fail.Add("PowerShell 7 Greenfield bootstrap: $marker")}
}

if (@($codexZip).Count -eq 1) {
    $archive=[IO.Compression.ZipFile]::OpenRead($codexZip[0].FullName)
    try{
        $entry=$archive.Entries|Where-Object FullName -match '/CodexLocal\.psm1$'|Select-Object -First 1
        if(-not$entry){$fail.Add('Codex Local module missing')}
        else{
            $reader=[IO.StreamReader]::new($entry.Open())
            try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()}
            foreach($marker in @('node_modules/npm/bin/npm-cli.js','node_modules/@openai/codex/bin/codex.js','Restore-KICodexBackup','secondRunReused',"psi.Environment['CODEX_HOME']",'Get-KICodexStarterScriptContent')){
                if(-not$text.Contains($marker)){$fail.Add("Managed Codex runtime contract: $marker")}
            }
            foreach($forbidden in @('npm-global/codex.cmd','runtime/npm.cmd','PathSeparator+$originalPath',"if([string]::IsNullOrWhiteSpace(`$env:CODEX_HOME)){Join-Path `$env:USERPROFILE '.codex'}")){
                if($text.Contains($forbidden)){$fail.Add("Global Codex runtime fallback: $forbidden")}
            }
        }
    }finally{$archive.Dispose()}
}

if (@($openTerminalZip).Count -eq 1) {
    $archive=[IO.Compression.ZipFile]::OpenRead($openTerminalZip[0].FullName)
    try{
        $entry=$archive.Entries|Where-Object FullName -match '/OpenTerminal\.psm1$'|Select-Object -First 1
        if(-not$entry){$fail.Add('Open Terminal module missing')}
        else{
            $reader=[IO.StreamReader]::new($entry.Open())
            try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()}
            foreach($marker in @('Resolve-KIOpenTerminalManagedUv','Assert-KIOpenTerminalManagedUv','Get-KIOpenTerminalStartArguments','Assert-KIOpenTerminalApiKey','ConvertFrom-SecureString','Test-KIOpenTerminalProcessIdentity','Restore-KIOpenTerminalBackup')){
                if(-not$text.Contains($marker)){$fail.Add("Managed Open Terminal contract: $marker")}
            }
            # Never a bare, unmanaged 'uvx' PATH lookup -- Resolve-KIOpenTerminalManagedUv's own
            # deterministic, TargetRoot-bound managed-uv resolution must be the only path.
            foreach($forbidden in @("Get-Command 'uvx'","Get-Command uvx")){
                if($text.Contains($forbidden)){$fail.Add("Unmanaged bare uvx PATH lookup: $forbidden")}
            }
        }
    }finally{$archive.Dispose()}
}

if (@($modelsZip).Count -eq 1) {
    $archive = [IO.Compression.ZipFile]::OpenRead($modelsZip[0].FullName)
    try {
        $modelEntry = $archive.Entries | Where-Object FullName -match '/Manifests/models\.manifest\.json$' | Select-Object -First 1
        if (-not $modelEntry) { $fail.Add('Authoritative model manifest missing') }
        else {
            $reader = [IO.StreamReader]::new($modelEntry.Open())
            try { $modelContract = $reader.ReadToEnd() | ConvertFrom-Json -Depth 100 } finally { $reader.Dispose() }
            if (@($modelContract.models).Count -ne 9 -or [long]($modelContract.models | Measure-Object sizeBytes -Sum).Sum -ne 54994650267) { $fail.Add('Visual model contract') }
            if (@($modelContract.lmStudio.files).Count -ne 3) { $fail.Add('LM Studio artifact contract') }
            $nomic=@($modelContract.lmStudio.files|Where-Object id -eq 'nomic-embed-text-v1.5')
            if($nomic.Count-ne1-or$nomic[0].modelId-ne'text-embedding-nomic-embed-text-v1.5'-or$nomic[0].role-ne'embedding-only'){$fail.Add('Nomic embedding contract')}
        }
        $workflows = @($archive.Entries | Where-Object FullName -match '/Workflows/[^/]+\.json$')
        if ($workflows.Count -ne 2) { $fail.Add('Workflow count') }
    } finally { $archive.Dispose() }
}

$orchestrator = Get-Content -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Raw
$publicEntries = @(
    'Invoke-KIStackComfyUI.ps1',
    'Invoke-KIStackIntegration.ps1',
    'Import-KIStackExternalModels.ps1',
    'Invoke-KIStackBuilderKernel.ps1'
)
if (@($publicEntries | Where-Object { -not $orchestrator.Contains($_) }).Count) {
    $fail.Add('Public component entry points')
}
if ($orchestrator.Contains("orchestratedBy='embedded validated component'")) {
    $fail.Add('False generic component completion')
}
foreach ($marker in @("elseif (`$step.id -eq 'validation-gate')",'Install-KIStack-ValidationGate.ps1',"orchestratedBy='public Validation Gate installer'",'Installierte Validation-Gate-Version stimmt nicht')) {
    if (-not $orchestrator.Contains($marker)) { $fail.Add("Validation Gate real deployment: $marker") }
}
foreach($marker in @("elseif (`$step.id -eq 'codex-local')","elseif (`$step.id -eq 'rag')",'Invoke-KIStackCodexLocal.ps1','Test-KIStackRAG.ps1','Install-KICompleteRAGModule','RAG_EMBEDDING_CONTENT_PREFIX=$documentPrefix','RAG_EMBEDDING_QUERY_PREFIX=$queryPrefix','$ragConfig.documentPrefix','$ragConfig.queryPrefix')){
    if(-not$orchestrator.Contains($marker)){$fail.Add("Local Intelligence integration: $marker")}
}
foreach($marker in @('Test-KICompleteCodexLocalCompliant','Resume-Readback erforderte erneutes Deployment','Payload ist mehrdeutig:')){
    if(-not$orchestrator.Contains($marker)){$fail.Add("Codex Resume/payload contract: $marker")}
}
foreach($marker in @('Test-KICompleteIntegrationCompliant')){
    if(-not$orchestrator.Contains($marker)){$fail.Add("Integration runtime compliance contract: $marker")}
}
foreach($marker in @("elseif (`$step.id -eq 'open-terminal')",'Invoke-KIStackOpenTerminal.ps1','Test-KICompleteOpenTerminalCompliant','Open-Terminal-Einstieg fehlt.','Open-Terminal-Validierung fehlgeschlagen.')){
    if(-not$orchestrator.Contains($marker)){$fail.Add("Open Terminal dispatcher integration: $marker")}
}
Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force
$planTarget = Join-Path ([IO.Path]::GetTempPath()) ('KIStack-Complete-Plan-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $planTarget 'state/complete-installer'),(Join-Path $planTarget 'Tools/PackageValidationGate/current') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $planTarget 'state/complete-installer/components.json'),'{"components":{"validation-gate":"1.0.3"}}',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $planTarget 'Tools/PackageValidationGate/current/VERSION'),'1.0.2',[Text.ASCIIEncoding]::new())
    $gatePlan = New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $planTarget
    $gateStep = @($gatePlan.steps | Where-Object id -eq 'validation-gate')
    if ($gateStep.plannedMode -ne 'Upgrade' -or $gateStep.initialState.installedVersion -ne '1.0.2' -or [bool]$gateStep.initialState.compliant) {
        $fail.Add('Probe regression 1: stored desired, real old')
    }

    [IO.File]::WriteAllText((Join-Path $planTarget 'state/complete-installer/components.json'),'{"components":{"validation-gate":"1.0.2"}}',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $planTarget 'Tools/PackageValidationGate/current/VERSION'),'1.0.3',[Text.ASCIIEncoding]::new())
    $gatePlan = New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $planTarget
    $gateStep = @($gatePlan.steps | Where-Object id -eq 'validation-gate')
    if ($gateStep.plannedMode -ne 'Skip' -or -not [bool]$gateStep.initialState.reconciliationNeeded) {
        $fail.Add('Probe regression 2: real desired, stored old')
    }

    [IO.File]::WriteAllText((Join-Path $planTarget 'state/complete-installer/components.json'),'{"components":{"validation-gate":"1.0.3"}}',[Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath (Join-Path $planTarget 'Tools/PackageValidationGate/current/VERSION') -Force
    $gatePlan = New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $planTarget
    $gateStep = @($gatePlan.steps | Where-Object id -eq 'validation-gate')
    if ($gateStep.plannedMode -ne 'Repair' -or $null -ne $gateStep.initialState.installedVersion) {
        $fail.Add('Probe regression 3: stored desired, real missing')
    }

    $rolledBack=$false
    try {
        Invoke-KICompleteVerifiedDeployment -ExpectedVersion '1.0.3' -Deploy { 'deployed' } -Readback { '1.0.2' } -Rollback { $script:rolledBack=$true } | Out-Null
        $fail.Add('Probe regression 4: stale readback did not fail')
    } catch {
        if ([string]$_.Exception.Data['KIStackRollbackStatus'] -ne 'Completed') { $fail.Add('Probe regression 4: rollback not completed') }
    }

    $successfulRollback=$false
    $verified=Invoke-KICompleteVerifiedDeployment -ExpectedVersion '1.0.3' -Deploy { 'deployed' } -Readback { '1.0.3' } -Rollback { $script:successfulRollback=$true }
    if (-not $verified.passed -or $verified.actualVersion -ne '1.0.3' -or $successfulRollback) {
        $fail.Add('Probe regression 5: successful readback')
    }
    $statePlan=[pscustomobject]@{steps=@([pscustomobject]@{id='validation-gate';version='1.0.3';initialState=[pscustomobject]@{compliant=$true}})}
    $null=Update-KICompleteComponentState -Plan $statePlan -TargetRoot $planTarget -CompleteVersion '2.10.0'
    $storedAfterSuccess=(Get-Content -LiteralPath (Join-Path $planTarget 'state/complete-installer/components.json') -Raw|ConvertFrom-Json).components.'validation-gate'
    if($storedAfterSuccess-ne'1.0.3'){$fail.Add('Probe regression 5: state after successful readback')}

    [IO.File]::WriteAllText((Join-Path $planTarget 'Tools/PackageValidationGate/current/VERSION'),'1.0.3',[Text.ASCIIEncoding]::new())
    $gatePlan = New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $planTarget
    $gateStep = @($gatePlan.steps | Where-Object id -eq 'validation-gate')
    if ($gateStep.plannedMode -ne 'Skip' -or -not [bool]$gateStep.initialState.compliant -or [bool]$gateStep.initialState.reconciliationNeeded) {
        $fail.Add('Probe regression 6: fully compliant')
    }

    [IO.File]::WriteAllText((Join-Path $planTarget 'state/complete-installer/components.json'),'{"components":{"validation-gate":"1.0.3","openwebui-image-pack":"1.9.0"}}',[Text.UTF8Encoding]::new($false))
    $orphanPlan=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $planTarget
    if(-not[bool]$orphanPlan.stateHasOrphans){$fail.Add('State regression 7: orphan not detected')}
    $orphanStatePlan=[pscustomobject]@{steps=@($orphanPlan.steps|Where-Object{$_.initialState.compliant})}
    $null=Update-KICompleteComponentState -Plan $orphanStatePlan -TargetRoot $planTarget -CompleteVersion '2.10.0'
    $reconciledState=Get-Content -LiteralPath (Join-Path $planTarget 'state/complete-installer/components.json') -Raw|ConvertFrom-Json
    if($reconciledState.components.PSObject.Properties.Name-contains'openwebui-image-pack'){$fail.Add('State regression 7: orphan retained')}

    $integrationComponent=@($components.components|Where-Object id -eq 'integration')
    $integrationVersion=[string]$integrationComponent.version
    $integrationRoot=Join-Path $planTarget 'modules/integration'
    $integrationRuntimeFiles=@(
        'Start-KIStack-IntegratedStack.cmd','Start-KIStack-OpenWebUI-WithSearch.cmd',
        'Start-KIStack-SearXNG.cmd','Start-KIStack-SearXNG.ps1',
        'Stop-KIStack-IntegratedStack.cmd','Stop-KIStack-SearXNG.cmd','Stop-KIStack-SearXNG.ps1'
    )
    New-Item -ItemType Directory -Path $integrationRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $integrationRoot 'installation.json'),(@{version=$integrationVersion}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $planTarget 'state/complete-installer/components.json'),('{"components":{"integration":"'+$integrationVersion+'"}}'),[Text.UTF8Encoding]::new($false))
    $integrationPlan=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $planTarget
    $integrationStep=@($integrationPlan.steps|Where-Object id -eq 'integration')
    if($integrationStep.plannedMode -eq 'Skip' -or [bool]$integrationStep.initialState.compliant){
        $fail.Add('Probe regression 8: integration marker present with matching version but runtime files missing must not be compliant')
    }

    foreach($name in $integrationRuntimeFiles){[IO.File]::WriteAllText((Join-Path $integrationRoot $name),'placeholder',[Text.UTF8Encoding]::new($false))}
    $integrationPlan=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $planTarget
    $integrationStep=@($integrationPlan.steps|Where-Object id -eq 'integration')
    if($integrationStep.plannedMode -ne 'Skip' -or -not [bool]$integrationStep.initialState.compliant){
        $fail.Add('Probe regression 9: integration marker and runtime files present must be compliant')
    }

    # --- Open Terminal: Greenfield / Upgrade / Skip / Repair, mirroring the Integration probe
    # regressions above exactly, real New-KICompletePlan calls against a fresh fixture TargetRoot
    # (no real install, no real uv/network dependency). --------------------------------------
    $openTerminalVersion=[string]$openTerminalComponent.version
    $openTerminalModuleRoot=Join-Path $planTarget 'modules/open-terminal'
    $openTerminalStateRoot=Join-Path $planTarget 'state/open-terminal'
    [IO.File]::WriteAllText((Join-Path $planTarget 'state/complete-installer/components.json'),'{"components":{}}',[Text.UTF8Encoding]::new($false))
    $greenfieldPlan=New-KICompletePlan -Mode Install -PackageRoot $PackageRoot -TargetRoot $planTarget
    $greenfieldStep=@($greenfieldPlan.steps|Where-Object id -eq 'open-terminal')
    if($greenfieldStep.Count-ne1){$fail.Add('Probe regression 10: Greenfield plan must contain Open Terminal')}
    elseif($greenfieldStep.plannedMode -ne 'Install' -or [bool]$greenfieldStep.initialState.compliant){
        $fail.Add('Probe regression 10: Greenfield Open Terminal must plan as Install')
    }

    # Marker present with a matching version, but the credential/workspace/starter contract is
    # incomplete -- must never be treated as compliant/Skip (mirrors Probe regression 8 above).
    New-Item -ItemType Directory -Path $openTerminalModuleRoot,$openTerminalStateRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $openTerminalModuleRoot 'installation.json'),(@{schemaVersion='1.0';version=$openTerminalVersion;host='127.0.0.1';port=8000}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $brokenPlan=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $planTarget
    $brokenStep=@($brokenPlan.steps|Where-Object id -eq 'open-terminal')
    if($brokenStep.plannedMode -eq 'Skip' -or [bool]$brokenStep.initialState.compliant){
        $fail.Add('Probe regression 11: Open Terminal marker present with matching version but starter/credential/workspace missing must not be compliant')
    }

    # Complete the real compliance contract for real (starter, stopper, credential, workspace) --
    # must now plan as Skip/compliant, exactly like a real Install-KIOpenTerminal would leave it.
    [IO.File]::WriteAllText((Join-Path $openTerminalModuleRoot 'Start-KIStack-OpenTerminal.cmd'),'@echo off',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $openTerminalModuleRoot 'Stop-KIStack-OpenTerminal.cmd'),'@echo off',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $openTerminalStateRoot 'credential.json'),'{"schemaVersion":"1.0"}',[Text.UTF8Encoding]::new($false))
    New-Item -ItemType Directory -Path (Join-Path $openTerminalStateRoot 'workspace') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $planTarget 'state/complete-installer/components.json'),('{"components":{"open-terminal":"'+$openTerminalVersion+'"}}'),[Text.UTF8Encoding]::new($false))
    $compliantPlan=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $planTarget
    $compliantStep=@($compliantPlan.steps|Where-Object id -eq 'open-terminal')
    if($compliantStep.plannedMode -ne 'Skip' -or -not [bool]$compliantStep.initialState.compliant){
        $fail.Add('Probe regression 12: Open Terminal with the real, complete contract must be compliant/Skip')
    }
    $directCompliance=Test-KICompleteOpenTerminalCompliant -TargetRoot $planTarget -ExpectedComponentVersion $openTerminalVersion
    if(-not[bool]$directCompliance){$fail.Add('Probe regression 12b: Test-KICompleteOpenTerminalCompliant must directly confirm the complete contract')}

    # Repair: the local state file believes Open Terminal is already installed, but the real
    # on-target marker is gone entirely (Get-KICompleteInstalledVersion's probe finds nothing) --
    # the same "stored desired, real missing" shape validation-gate's own Probe regression 3
    # above already establishes as the real, intentional definition of 'Repair'.
    Remove-Item -LiteralPath (Join-Path $openTerminalModuleRoot 'installation.json') -Force
    $repairPlan=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $planTarget
    $repairStep=@($repairPlan.steps|Where-Object id -eq 'open-terminal')
    if($repairStep.plannedMode -ne 'Repair' -or $null -ne $repairStep.initialState.installedVersion){
        $fail.Add('Probe regression 13: Open Terminal with stored state but a missing real marker must plan as Repair')
    }
}
finally {
    if (Test-Path -LiteralPath $planTarget) { Remove-Item -LiteralPath $planTarget -Recurse -Force }
}
if ($orchestrator -match '(?im)^\s*\$packageRoot\s*=\s*Split-Path\s+-Parent\s+\$module\.FullName') {
    $fail.Add('Agent payload overwrites complete PackageRoot')
}
foreach ($marker in @('failedPhase','finalizationRollback','InstallOperations')) {
    if (-not $orchestrator.Contains($marker)) { $fail.Add("Finalization evidence: $marker") }
}
foreach($marker in @('componentRollback','Restore-OpenWebUIAgentPack','component-marker.backup.json')){
    if(-not$orchestrator.Contains($marker)){$fail.Add("Component rollback evidence: $marker")}
}
if (-not $orchestrator.Contains("ContainsKey('executable')") -or -not $orchestrator.Contains("ContainsKey('arguments')")) {
    $fail.Add('StrictMode desktop shortcut optional keys')
}
$codeInterpreterSource = Get-Content -LiteralPath (Join-Path $PackageRoot 'Operations\Set-KIStackCodeInterpreter.ps1') -Raw
foreach ($marker in @("'ki_stack_generate_image','ki_stack_generate_video'","Restore-KIStackCodeInterpreter.ps1","KIStackRollbackStatus")) {
    if (-not $codeInterpreterSource.Contains($marker)) { $fail.Add("Code interpreter visual/rollback contract: $marker") }
}

$syntaxErrors = @()
foreach ($script in Get-ChildItem -LiteralPath $PackageRoot -Recurse -File | Where-Object Extension -in @('.ps1','.psm1')) {
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($script.FullName,[ref]$tokens,[ref]$errors) | Out-Null
    $syntaxErrors += $errors
}
if ($syntaxErrors.Count) { $fail.Add('PowerShell syntax') }

[pscustomobject]@{
    passed = ($fail.Count -eq 0)
    version = '2.13.0'
    checks = 28
    failures = $fail
} | ConvertTo-Json -Depth 10
if ($fail.Count) { throw ($fail -join '; ') }

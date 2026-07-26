[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fail = [Collections.Generic.List[string]]::new()

$manifest = Get-Content -LiteralPath (Join-Path $PackageRoot 'MANIFEST.json') -Raw | ConvertFrom-Json
$components = Get-Content -LiteralPath (Join-Path $PackageRoot 'Contracts\COMPONENTS.json') -Raw | ConvertFrom-Json
$payloads = Get-Content -LiteralPath (Join-Path $PackageRoot 'Contracts\PAYLOADS.json') -Raw | ConvertFrom-Json
foreach($requiredTest in @('Test-KIStackInstallationContracts.ps1','Test-KIStackCompleteInstallerTarget.ps1','Test-RC12PendingComfyRollback.ps1','Test-RC13FailedStateRecovery.ps1')){
    if(-not(Test-Path -LiteralPath (Join-Path $PackageRoot $requiredTest) -PathType Leaf)){$fail.Add("Required test missing: $requiredTest")}
}

if ($manifest.version -ne '2.3.0-rc17' -or $manifest.baseVersion -ne '2.2.9') { $fail.Add('Version contract') }
if ($payloads.modelPolicy.chatModels.Count -ne 1 -or $payloads.modelPolicy.chatModels[0] -ne 'qwen3.6-27b-uncensored-heretic-v2-native-mtp-preserved') { $fail.Add('Heretic chat-only contract') }
if ($payloads.modelPolicy.nomicRole -ne 'embedding-only' -or $payloads.modelPolicy.embeddingModels.Count -ne 1) { $fail.Add('Nomic embedding-only contract') }
if ([string]$payloads.modelContractAuthority.packagedArchive -ne 'Payload/ModelsWorkflows/KI-Stack-Visual-Models-Workflows-v2.0.2.zip') { $fail.Add('Authoritative model contract') }
if ($payloads.PSObject.Properties.Name -contains 'external' -or $payloads.PSObject.Properties.Name -contains 'lmStudioModel') { $fail.Add('Duplicate model contract') }
if (@($components.components | Where-Object id -eq 'openwebui-visual-pack').version -ne '2.0.5-rc3') { $fail.Add('Visual Pack component') }
if (@($components.components | Where-Object id -eq 'openwebui-agent-pack').version -ne '1.8.7') { $fail.Add('Agent Pack component') }
if ([int]@($components.components | Where-Object id -eq 'openwebui-visual-pack').order -ge [int]@($components.components | Where-Object id -eq 'openwebui-agent-pack').order) { $fail.Add('Visual Pack must deploy before Agent Pack') }
if (@($components.components | Where-Object id -eq 'models-workflows').version -ne '2.0.2') { $fail.Add('Visual Models component') }
$validationComponent = @($components.components | Where-Object id -eq 'validation-gate')
if ($validationComponent.version -ne '1.0.3' -or -not [bool]$validationComponent.installable) { $fail.Add('Validation Gate installable component') }
$installableWithoutProbe=@($components.components|Where-Object{$_.installable-and(-not($_.PSObject.Properties.Name-contains'probe')-or$null-eq$_.probe)})
if($installableWithoutProbe.Count){$fail.Add('Installable component without real probe')}
$invalidPinned=@($components.components|Where-Object{$_.id-in@('foundation-runtime','python-git','applications','cutover-runtime')-and[bool]$_.installable})
if($invalidPinned.Count){$fail.Add('Non-executable Cutover references marked installable')}

$visualZip = Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Payload\OpenWebUIVisualPack') -File -Filter '*.zip'
$modelsZip = Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Payload\ModelsWorkflows') -File -Filter '*.zip'
$agentZip = Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Payload\OpenWebUIAgentPack') -File -Filter '*.zip'
if (@($visualZip).Count -ne 1 -or @($modelsZip).Count -ne 1) { $fail.Add('Payload archive count') }

Add-Type -AssemblyName System.IO.Compression.FileSystem
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
        foreach($visualContract in @('ki_stack_generate_image','ki_stack_generate_video','2.0.5-rc3')){
            if(-not$text.Contains($visualContract)){$fail.Add("Agent visual-tool contract: $visualContract")}
        }
        $legacyOwner = ('KI-STACK-OPENWEBUI-' + 'IMAGE-PACK')
        if ($text.Contains($legacyOwner)) { $fail.Add('Legacy extension ownership') }
    } finally { $archive.Dispose() }
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
            if (@($modelContract.lmStudio.files).Count -ne 2) { $fail.Add('Heretic artifact contract') }
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
    $null=Update-KICompleteComponentState -Plan $statePlan -TargetRoot $planTarget -CompleteVersion '2.3.0-rc17'
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
    $null=Update-KICompleteComponentState -Plan $orphanStatePlan -TargetRoot $planTarget -CompleteVersion '2.3.0-rc17'
    $reconciledState=Get-Content -LiteralPath (Join-Path $planTarget 'state/complete-installer/components.json') -Raw|ConvertFrom-Json
    if($reconciledState.components.PSObject.Properties.Name-contains'openwebui-image-pack'){$fail.Add('State regression 7: orphan retained')}
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
    version = '2.3.0-rc17'
    checks = 22
    failures = $fail
} | ConvertTo-Json -Depth 10
if ($fail.Count) { throw ($fail -join '; ') }

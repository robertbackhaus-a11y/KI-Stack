[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Real, end-to-end Complete-Installer-Pfad regression for mcp-runtime's own dispatcher branch
# (Lifecycle/KIStackUpdateIsolation.psm1's `'mcp-runtime'` case) -- Payload deployment via the
# real Expand-KICompletePayload, the real Invoke-KIStackMcpRuntime.ps1 entry point via the real
# Invoke-KICompleteJsonScript, and a real induced-failure Rollback -- mirroring
# Test-KIStackOpenTerminalCompleteInstallerIntegration.ps1's own posture exactly (same template
# component, same isolation category, same Install/Upgrade/Repair/Rollback contract shape). Run
# against a REAL, already-built staged payload (Payload/McpRuntime/*.zip must exist -- build it
# first, e.g. via a one-off zip of tools/mcp-runtime/current using the same deterministic-archive
# logic New-KIStackCompleteInstallerArchive.ps1 itself uses). -SkipUvCheck mirrors the OpenTerminal
# test's own posture -- the managed-uv prerequisite is out of scope here; this test's own concern
# is the dispatcher/payload/backup contract.

Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force

$payloadDir = Join-Path $PackageRoot 'Payload/McpRuntime'
if (-not (Test-Path -LiteralPath $payloadDir -PathType Container)) {
    throw "MCP-Runtime-Payload fehlt unter '$payloadDir' -- dieser Test muss gegen ein real gebautes Staging-Paket laufen."
}

$fail = [Collections.Generic.List[string]]::new()
$checks = [ordered]@{}
$scratchBase = Join-Path ([IO.Path]::GetTempPath()) ('KIMR-CI-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $scratchBase -Force | Out-Null

try {
    $targetRoot = Join-Path $scratchBase 'target'
    New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
    $extract = Join-Path $scratchBase 'extract-1'
    $componentRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'McpRuntime' -Destination $extract
    $entry = Join-Path $componentRoot 'Invoke-KIStackMcpRuntime.ps1'
    $checks.payloadDeploymentExtractsRealEntryPoint = [ordered]@{
        entryExists = Test-Path -LiteralPath $entry -PathType Leaf
        moduleExists = Test-Path -LiteralPath (Join-Path $componentRoot 'McpRuntime.psm1') -PathType Leaf
    }
    if ($checks.payloadDeploymentExtractsRealEntryPoint.Values -contains $false) { $fail.Add('payloadDeploymentExtractsRealEntryPoint failed: ' + ($checks.payloadDeploymentExtractsRealEntryPoint | ConvertTo-Json -Compress)) }

    # --- Real Install via the real dispatcher entry point --------------------------------------
    $install1 = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Install'; TargetRoot = $targetRoot; SkipUvCheck = $true }
    $validate1 = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Validate'; TargetRoot = $targetRoot; SkipUvCheck = $true }
    $checks.realInstallViaDispatcherEntryPoint = [ordered]@{
        installPassed = [bool]$install1.passed
        installStatus = ([string]$install1.status -eq 'Installed')
        hasBackupPath = (-not [string]::IsNullOrWhiteSpace([string]$install1.backupPath))
        validatePassed = [bool]$validate1.passed
    }
    if ($checks.realInstallViaDispatcherEntryPoint.Values -contains $false) { $fail.Add('realInstallViaDispatcherEntryPoint failed: ' + ($checks.realInstallViaDispatcherEntryPoint | ConvertTo-Json -Compress)) }

    Import-Module (Join-Path $componentRoot 'McpRuntime.psm1') -Force
    $credentialBefore = Get-KIMcpRuntimeCredential -TargetRoot $targetRoot
    $keyBefore = ConvertFrom-KIMcpRuntimeSecureStringTransient -Value $credentialBefore.apiKey
    $paths = Get-KIMcpRuntimePaths -TargetRoot $targetRoot
    $userArtifact = Join-Path $paths.workspace 'user-created-file.txt'
    Set-Content -LiteralPath $userArtifact -Value 'kept across upgrade' -Encoding utf8NoBOM

    # --- Real Upgrade (same payload/version -- SkippedAlreadyCompliant expected) ----------------
    $upgrade1 = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Upgrade'; TargetRoot = $targetRoot; SkipUvCheck = $true }
    $credentialAfter = Get-KIMcpRuntimeCredential -TargetRoot $targetRoot
    $keyAfter = ConvertFrom-KIMcpRuntimeSecureStringTransient -Value $credentialAfter.apiKey
    $checks.persistentApiKeySurvivesUpgrade = [ordered]@{
        upgradePassed = [bool]$upgrade1.passed
        upgradeStatus = ([string]$upgrade1.status -eq 'SkippedAlreadyCompliant')
        sameKeyAfterUpgrade = ($keyBefore -ceq $keyAfter)
    }
    if ($checks.persistentApiKeySurvivesUpgrade.Values -contains $false) { $fail.Add('persistentApiKeySurvivesUpgrade failed: ' + ($checks.persistentApiKeySurvivesUpgrade | ConvertTo-Json -Compress)) }
    $keyBefore = $null; $keyAfter = $null

    $checks.workspaceAndStateSurviveUpgrade = [ordered]@{
        workspaceDirStillPresent = Test-Path -LiteralPath $paths.workspace -PathType Container
        userArtifactStillPresent = (Test-Path -LiteralPath $userArtifact -PathType Leaf) -and ((Get-Content -LiteralPath $userArtifact -Raw).Trim() -eq 'kept across upgrade')
        markerStillPresent = Test-Path -LiteralPath $paths.marker -PathType Leaf
        starterStillPresent = Test-Path -LiteralPath $paths.starter -PathType Leaf
        stopperStillPresent = Test-Path -LiteralPath $paths.stopper -PathType Leaf
    }
    if ($checks.workspaceAndStateSurviveUpgrade.Values -contains $false) { $fail.Add('workspaceAndStateSurviveUpgrade failed: ' + ($checks.workspaceAndStateSurviveUpgrade | ConvertTo-Json -Compress)) }

    # --- Real dispatcher-shaped Rollback, case A: a FRESH install rolled back must correctly
    # result in "nothing installed" again. -----------------------------------------------------
    $targetRoot2 = Join-Path $scratchBase 'target-rollback'
    New-Item -ItemType Directory -Path $targetRoot2 -Force | Out-Null
    $install2 = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Install'; TargetRoot = $targetRoot2; SkipUvCheck = $true }
    $paths2 = Get-KIMcpRuntimePaths -TargetRoot $targetRoot2
    $rollback2 = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Rollback'; TargetRoot = $targetRoot2; BackupPath = [string]$install2.backupPath }
    $checks.rollbackOfAFreshInstallCorrectlyUninstalls = [ordered]@{
        rollbackPassed = [bool]$rollback2.passed
        markerRemoved = (-not (Test-Path -LiteralPath $paths2.marker -PathType Leaf))
        starterRemoved = (-not (Test-Path -LiteralPath $paths2.starter -PathType Leaf))
        stopperRemoved = (-not (Test-Path -LiteralPath $paths2.stopper -PathType Leaf))
    }
    if ($checks.rollbackOfAFreshInstallCorrectlyUninstalls.Values -contains $false) { $fail.Add('rollbackOfAFreshInstallCorrectlyUninstalls failed: ' + ($checks.rollbackOfAFreshInstallCorrectlyUninstalls | ConvertTo-Json -Compress)) }

    # --- Real dispatcher-shaped Rollback, case B: a REAL Repair reconciliation on an ALREADY
    # installed target (starter deleted to force real non-compliance) takes its own backup with
    # existed=true for the marker that was genuinely already there -- rolling that specific
    # backup back must RESTORE the exact prior marker content, and correctly leave the starter
    # absent again (the backup reflects the moment immediately before Repair, not after). --------
    $targetRoot3 = Join-Path $scratchBase 'target-rollback-repair'
    New-Item -ItemType Directory -Path $targetRoot3 -Force | Out-Null
    Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Install'; TargetRoot = $targetRoot3; SkipUvCheck = $true } | Out-Null
    $paths3 = Get-KIMcpRuntimePaths -TargetRoot $targetRoot3
    $priorMarkerText = Get-Content -LiteralPath $paths3.marker -Raw
    Remove-Item -LiteralPath $paths3.starter -Force
    $repair3 = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Repair'; TargetRoot = $targetRoot3; SkipUvCheck = $true }
    Remove-Item -LiteralPath $paths3.marker -Force
    $rollback3 = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Rollback'; TargetRoot = $targetRoot3; BackupPath = [string]$repair3.backupPath }
    $checks.rollbackOfARealRepairRestoresPriorMarker = [ordered]@{
        repairPassed = [bool]$repair3.passed
        repairTookANewBackup = (-not [string]::IsNullOrWhiteSpace([string]$repair3.backupPath))
        rollbackPassed = [bool]$rollback3.passed
        markerRestoredWithPriorContent = (Test-Path -LiteralPath $paths3.marker -PathType Leaf) -and ((Get-Content -LiteralPath $paths3.marker -Raw) -eq $priorMarkerText)
        starterCorrectlyLeftAbsent = (-not (Test-Path -LiteralPath $paths3.starter -PathType Leaf))
    }
    if ($checks.rollbackOfARealRepairRestoresPriorMarker.Values -contains $false) { $fail.Add('rollbackOfARealRepairRestoresPriorMarker failed: ' + ($checks.rollbackOfARealRepairRestoresPriorMarker | ConvertTo-Json -Compress)) }

    $passed = $fail.Count -eq 0
    [pscustomobject]@{ passed = $passed; checks = $checks; failures = @($fail) } | ConvertTo-Json -Depth 12
    if (-not $passed) { throw 'MCP-Runtime-Complete-Installer-Integration-Regression fehlgeschlagen.' }
} finally {
    try { Remove-Item -LiteralPath $scratchBase -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

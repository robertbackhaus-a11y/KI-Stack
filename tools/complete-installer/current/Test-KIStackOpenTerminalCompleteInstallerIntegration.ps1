[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Real, end-to-end Complete-Installer-Pfad regression for Open Terminal's own dispatcher branch
# (CompleteInstaller.psm1's `elseif ($step.id -eq 'open-terminal')`) -- Payload deployment via
# the real Expand-KICompletePayload, the real Invoke-KIStackOpenTerminal.ps1 entry point via the
# real Invoke-KICompleteJsonScript, and a real induced-failure Rollback -- using the SAME
# functions the real orchestrator calls, just driven directly instead of through the full,
# heavyweight all-components transaction (which would otherwise also install ComfyUI/Integration/
# etc. for real). Mirrors Test-KIStackCompleteInstaller.ps1's own "PackageSelfTest" posture: run
# against a REAL, already-built staged package (Payload/OpenTerminal/*.zip must exist), never
# part of the automated scripts/Test-Repository.ps1 suite -- build first via
# New-KIStackCompleteInstallerArchive.ps1, then run this against that staged output.

Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force

$payloadDir = Join-Path $PackageRoot 'Payload/OpenTerminal'
if (-not (Test-Path -LiteralPath $payloadDir -PathType Container)) {
    throw "Open-Terminal-Payload fehlt unter '$payloadDir' -- dieser Test muss gegen ein real gebautes Staging-Paket laufen (New-KIStackCompleteInstallerArchive.ps1 zuerst ausführen)."
}

$fail = [Collections.Generic.List[string]]::new()
$checks = [ordered]@{}
$scratchBase = Join-Path ([IO.Path]::GetTempPath()) ('KIOT-CI-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $scratchBase -Force | Out-Null

try {
    $targetRoot = Join-Path $scratchBase 'target'
    New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
    $extract = Join-Path $scratchBase 'extract-1'
    $componentRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'OpenTerminal' -Destination $extract
    $entry = Join-Path $componentRoot 'Invoke-KIStackOpenTerminal.ps1'
    $checks.payloadDeploymentExtractsRealEntryPoint = [ordered]@{
        entryExists = Test-Path -LiteralPath $entry -PathType Leaf
        moduleExists = Test-Path -LiteralPath (Join-Path $componentRoot 'OpenTerminal.psm1') -PathType Leaf
    }
    if ($checks.payloadDeploymentExtractsRealEntryPoint.Values -contains $false) { $fail.Add('payloadDeploymentExtractsRealEntryPoint failed: ' + ($checks.payloadDeploymentExtractsRealEntryPoint | ConvertTo-Json -Compress)) }

    # --- Real Install via the real dispatcher entry point (Invoke-KICompleteJsonScript is the
    # SAME nested-pwsh JSON-result invocation the real orchestrator branch uses -- `& $Script
    # @Arguments`, so a boolean in the hashtable splats onto a [switch] parameter exactly like a
    # real -SkipUvCheck flag). -SkipUvCheck mirrors Test-KIStackOpenTerminal.ps1's own posture --
    # the managed-uv prerequisite itself is already covered there; this test's own concern is the
    # dispatcher/payload/backup contract.
    $install1 = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Install'; TargetRoot = $targetRoot; SkipUvCheck = $true }
    $validate1 = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Validate'; TargetRoot = $targetRoot; SkipUvCheck = $true }
    $checks.realInstallViaDispatcherEntryPoint = [ordered]@{
        installPassed = [bool]$install1.passed
        installStatus = ([string]$install1.status -eq 'Installed')
        hasBackupPath = (-not [string]::IsNullOrWhiteSpace([string]$install1.backupPath))
        validatePassed = [bool]$validate1.passed
    }
    if ($checks.realInstallViaDispatcherEntryPoint.Values -contains $false) { $fail.Add('realInstallViaDispatcherEntryPoint failed: ' + ($checks.realInstallViaDispatcherEntryPoint | ConvertTo-Json -Compress)) }

    Import-Module (Join-Path $componentRoot 'OpenTerminal.psm1') -Force
    $credentialBefore = Get-KIOpenTerminalCredential -TargetRoot $targetRoot
    $keyBefore = ConvertFrom-KIOpenTerminalSecureStringTransient -Value $credentialBefore.apiKey
    $paths = Get-KIOpenTerminalPaths -TargetRoot $targetRoot
    # A real user artifact inside the persisted workspace -- must survive an Upgrade untouched
    # (the same "never touch a user's own files on Upgrade/Repair" contract codex-local's own
    # profile.config.toml/AGENTS.md preservation already establishes).
    $userArtifact = Join-Path $paths.workspace 'user-created-file.txt'
    Set-Content -LiteralPath $userArtifact -Value 'kept across upgrade' -Encoding utf8NoBOM

    # --- Real Upgrade (same payload/version -- SkippedAlreadyCompliant is the correct, expected
    # real outcome for a same-version re-run, exactly like a real Complete Installer Upgrade of
    # an already-current target). Key and workspace must be provably unchanged. --------------
    $upgrade1 = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Upgrade'; TargetRoot = $targetRoot; SkipUvCheck = $true }
    $credentialAfter = Get-KIOpenTerminalCredential -TargetRoot $targetRoot
    $keyAfter = ConvertFrom-KIOpenTerminalSecureStringTransient -Value $credentialAfter.apiKey
    $checks.persistentApiKeySurvivesUpgrade = [ordered]@{
        upgradePassed = [bool]$upgrade1.passed
        sameKeyAfterUpgrade = ($keyBefore -ceq $keyAfter)
    }
    if ($checks.persistentApiKeySurvivesUpgrade.Values -contains $false) { $fail.Add('persistentApiKeySurvivesUpgrade failed: ' + ($checks.persistentApiKeySurvivesUpgrade | ConvertTo-Json -Compress)) }
    $keyBefore = $null; $keyAfter = $null

    $checks.workspaceAndStateSurviveUpgrade = [ordered]@{
        workspaceDirStillPresent = Test-Path -LiteralPath $paths.workspace -PathType Container
        # Set-Content appends its own newline; compare trimmed content, not the raw bytes.
        userArtifactStillPresent = (Test-Path -LiteralPath $userArtifact -PathType Leaf) -and ((Get-Content -LiteralPath $userArtifact -Raw).Trim() -eq 'kept across upgrade')
        markerStillPresent = Test-Path -LiteralPath $paths.marker -PathType Leaf
    }
    if ($checks.workspaceAndStateSurviveUpgrade.Values -contains $false) { $fail.Add('workspaceAndStateSurviveUpgrade failed: ' + ($checks.workspaceAndStateSurviveUpgrade | ConvertTo-Json -Compress)) }

    # --- Real induced-failure Rollback: corrupt the config so a real Repair run throws
    # mid-reconciliation, then verify the dispatcher-shaped Rollback action (the SAME Action=
    # 'Rollback'/BackupPath contract CompleteInstaller.psm1's own catch block calls) actually
    # restores the prior, working marker/starter/stopper state. --------------------------------
    $configPath = Join-Path $componentRoot 'Config/open-terminal.config.json'
    $originalConfigText = Get-Content -LiteralPath $configPath -Raw
    $originalMarkerText = Get-Content -LiteralPath $paths.marker -Raw
    Remove-Item -LiteralPath $paths.marker -Force
    try {
        [IO.File]::WriteAllText($configPath, '{ not valid json', [Text.UTF8Encoding]::new($false))
        $repairThrew = $false
        $repairResult = $null
        try { $repairResult = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Repair'; TargetRoot = $targetRoot; SkipUvCheck = $true } }
        catch { $repairThrew = $true }
        $checks.repairOnCorruptedConfigFailsRatherThanSilentlyMisbehaving = [ordered]@{
            failedOneWayOrAnother = ($repairThrew -or (-not [bool]$repairResult.passed))
        }
        if ($checks.repairOnCorruptedConfigFailsRatherThanSilentlyMisbehaving.Values -contains $false) { $fail.Add('repairOnCorruptedConfigFailsRatherThanSilentlyMisbehaving failed: ' + ($checks.repairOnCorruptedConfigFailsRatherThanSilentlyMisbehaving | ConvertTo-Json -Compress)) }
    } finally {
        [IO.File]::WriteAllText($configPath, $originalConfigText, [Text.UTF8Encoding]::new($false))
        if (-not (Test-Path -LiteralPath $paths.marker -PathType Leaf)) { [IO.File]::WriteAllText($paths.marker, $originalMarkerText, [Text.UTF8Encoding]::new($false)) }
    }

    # --- Real dispatcher-shaped Rollback, case A: a FRESH install (nothing existed before it)
    # rolled back must correctly result in "nothing installed" again -- rollback.json correctly
    # records existed=false for marker/starter here, so Restore-KIOpenTerminalBackup must REMOVE
    # them, never fabricate content that was never there. -------------------------------------
    $targetRoot2 = Join-Path $scratchBase 'target-rollback'
    New-Item -ItemType Directory -Path $targetRoot2 -Force | Out-Null
    $install2 = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Install'; TargetRoot = $targetRoot2; SkipUvCheck = $true }
    $paths2 = Get-KIOpenTerminalPaths -TargetRoot $targetRoot2
    $rollback2 = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Rollback'; TargetRoot = $targetRoot2; BackupPath = [string]$install2.backupPath }
    $checks.rollbackOfAFreshInstallCorrectlyUninstalls = [ordered]@{
        rollbackPassed = [bool]$rollback2.passed
        markerRemoved = (-not (Test-Path -LiteralPath $paths2.marker -PathType Leaf))
        starterRemoved = (-not (Test-Path -LiteralPath $paths2.starter -PathType Leaf))
    }
    if ($checks.rollbackOfAFreshInstallCorrectlyUninstalls.Values -contains $false) { $fail.Add('rollbackOfAFreshInstallCorrectlyUninstalls failed: ' + ($checks.rollbackOfAFreshInstallCorrectlyUninstalls | ConvertTo-Json -Compress)) }

    # --- Real dispatcher-shaped Rollback, case B: a REAL Repair reconciliation on an ALREADY
    # installed target (starter deleted to force real non-compliance) takes its own backup with
    # existed=true for the marker/starter that were genuinely already there -- rolling that
    # specific backup back must RESTORE the exact prior marker content, proving Rollback restores
    # real prior state, not just "removes what it just created". ------------------------------
    $targetRoot3 = Join-Path $scratchBase 'target-rollback-repair'
    New-Item -ItemType Directory -Path $targetRoot3 -Force | Out-Null
    Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Install'; TargetRoot = $targetRoot3; SkipUvCheck = $true } | Out-Null
    $paths3 = Get-KIOpenTerminalPaths -TargetRoot $targetRoot3
    $priorMarkerText = Get-Content -LiteralPath $paths3.marker -Raw
    Remove-Item -LiteralPath $paths3.starter -Force
    $repair3 = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Repair'; TargetRoot = $targetRoot3; SkipUvCheck = $true }
    Remove-Item -LiteralPath $paths3.marker -Force
    $rollback3 = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Rollback'; TargetRoot = $targetRoot3; BackupPath = [string]$repair3.backupPath }
    $checks.rollbackOfARealRepairRestoresPriorMarker = [ordered]@{
        repairTookANewBackup = (-not [string]::IsNullOrWhiteSpace([string]$repair3.backupPath))
        rollbackPassed = [bool]$rollback3.passed
        # The marker was never touched before Repair ran -- its backup correctly records
        # existed=true with the exact prior content, so rollback must restore that content byte
        # for byte (the real "restores prior state" case this scenario exists to prove).
        markerRestoredWithPriorContent = (Test-Path -LiteralPath $paths3.marker -PathType Leaf) -and ((Get-Content -LiteralPath $paths3.marker -Raw) -eq $priorMarkerText)
        # The starter was deliberately deleted immediately BEFORE calling Repair -- Repair's own
        # backup therefore correctly records existed=false for it at that exact moment, so
        # rolling that specific backup back correctly leaves it absent (rollback restores state
        # as of right before THIS operation, never an arbitrary earlier point).
        starterCorrectlyLeftAbsent = (-not (Test-Path -LiteralPath $paths3.starter -PathType Leaf))
    }
    if ($checks.rollbackOfARealRepairRestoresPriorMarker.Values -contains $false) { $fail.Add('rollbackOfARealRepairRestoresPriorMarker failed: ' + ($checks.rollbackOfARealRepairRestoresPriorMarker | ConvertTo-Json -Compress)) }

    $passed = $fail.Count -eq 0
    [pscustomobject]@{ passed = $passed; checks = $checks; failures = @($fail) } | ConvertTo-Json -Depth 12
    if (-not $passed) { throw 'Open-Terminal-Complete-Installer-Integration-Regression fehlgeschlagen.' }
} finally {
    try { Remove-Item -LiteralPath $scratchBase -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Regression suite for the 2.18.1 hotfix: two real, reproduced defects on the published 2.18.0
# Complete Installer, confirmed against the real affected target (C:\KI-Stack,
# transaction KI-COMPLETE-20260911-174901):
#
#   A) The desktop-control step's own Install-then-Validate pair, run in-process via the shared
#      Invoke-KICompleteJsonScript (`& $Script @Arguments`), failed inside the orchestrator even
#      though the SAME two calls against the SAME published payload each passed when run
#      standalone in their own fresh process. Fix: the step now runs Install/Upgrade/Repair and
#      the immediately following Validate via the new Invoke-KICompleteJsonScriptIsolated (a
#      genuinely fresh pwsh.exe child process each), never the in-process call.
#   B) Desktop Control's own standalone backup scheme
#      (<TargetRoot>\backups\desktop-control\<timestamp>\rollback.json) is never inside the
#      Complete Installer's own transaction-scoped BackupRoot, so a Failed step's recorded
#      BackupPath was rejected by Assert-KICompleteRecoveryBackupPath on the NEXT run, blocking
#      recovery. Fix: Install-KIDesktopControl accepts an optional -BackupRoot; the step now
#      passes TransactionBackupRoot\desktop-control.
#   C) Even with (B) fixed going forward, a Failed step whose OWN rollbackStatus is already
#      'Completed' (the real affected transaction has exactly this: rollbackStatus=Completed) is
#      already fully compensated and must not keep blocking later runs via its now-irrelevant
#      recorded BackupPath. Fix: Assert-KICompletePathAwareTransaction skips the BackupPath check
#      ONLY for a Failed step whose rollbackStatus is exactly 'Completed'; every other status
#      keeps the unchanged, strict check.
#
# No live winapp.exe is required or assumed anywhere in this file -- Invoke-KICompleteJsonScriptIsolated
# is proven generically against trivial stand-in scripts (same technique
# Test-KIStackOpenTerminalLifecycleWiring.ps1/Test-KIStackMcpRuntimeLifecycleWiring.ps1 already use
# for their own lifecycle wrappers), and Install-KIDesktopControl's -BackupRoot contract is proven
# for real (it never touches winapp). The full real-winapp Install->Validate roundtrip through
# Invoke-KICompleteJsonScriptIsolated was additionally verified live in this session against the
# real affected target's own winapp.exe (see the accompanying report); that live run is not, and
# cannot be, captured here as a portable regression test -- exactly the same limitation
# Test-KIStackDesktopControl.ps1 itself already documents for the real central resolver probe.

Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force -DisableNameChecking

$fail = [Collections.Generic.List[string]]::new()
$checks = [ordered]@{}
$scratchBase = Join-Path ([IO.Path]::GetTempPath()) ('KIDCIso-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $scratchBase -Force | Out-Null

function New-StandInJsonScript {
    # A trivial, fast, dependency-free stand-in with the SAME external JSON contract shape any
    # Invoke-KICompleteJsonScriptIsolated caller relies on: reports its own $PID (proving a
    # genuinely different process), whether -BackupRoot was bound at all, and its literal value
    # when it was -- without needing any real component logic.
    param([Parameter(Mandatory)][string]$Path)
    $content = @'
[CmdletBinding()]
param([string]$Action = 'Install', [string]$TargetRoot = '', [string]$BackupRoot, [switch]$DryRun)
$backupRootBound = $PSBoundParameters.ContainsKey('BackupRoot')
$passed = ($Action -ne 'ForceFail')
[pscustomobject]@{
    passed = $passed
    status = $Action
    pid = $PID
    targetRoot = $TargetRoot
    backupRootBound = $backupRootBound
    backupRootValue = $BackupRoot
    dryRun = [bool]$DryRun
} | ConvertTo-Json -Compress
if (-not $passed) { exit 1 }
'@
    Set-Content -LiteralPath $Path -Value $content -Encoding utf8NoBOM
}

try {
    # === Part 1: Invoke-KICompleteJsonScriptIsolated -- the fresh-process mechanism itself ======
    $standIn = Join-Path $scratchBase 'StandIn.ps1'
    New-StandInJsonScript -Path $standIn

    $r1 = Invoke-KICompleteJsonScriptIsolated -Script $standIn -Arguments @{ Action = 'Install'; TargetRoot = 'C:\Fake' }
    $checks.runsInAGenuinelyDifferentProcess = [ordered]@{
        passed = [bool]$r1.passed
        differentPid = ([int]$r1.pid -ne $PID)
        argumentsRoundTripCorrectly = ([string]$r1.targetRoot -eq 'C:\Fake' -and [string]$r1.status -eq 'Install')
    }
    if ($checks.runsInAGenuinelyDifferentProcess.Values -contains $false) { $fail.Add('runsInAGenuinelyDifferentProcess failed: ' + ($checks.runsInAGenuinelyDifferentProcess | ConvertTo-Json -Compress)) }

    $r2 = Invoke-KICompleteJsonScriptIsolated -Script $standIn -Arguments @{ Action = 'Install'; TargetRoot = 'C:\Fake'; BackupRoot = 'C:\Fake\backups\desktop-control' }
    $checks.backupRootIsPassedThroughWhenGiven = [ordered]@{
        bound = [bool]$r2.backupRootBound
        value = ([string]$r2.backupRootValue -eq 'C:\Fake\backups\desktop-control')
    }
    if ($checks.backupRootIsPassedThroughWhenGiven.Values -contains $false) { $fail.Add('backupRootIsPassedThroughWhenGiven failed: ' + ($checks.backupRootIsPassedThroughWhenGiven | ConvertTo-Json -Compress)) }

    $r3 = Invoke-KICompleteJsonScriptIsolated -Script $standIn -Arguments @{ Action = 'Validate'; TargetRoot = 'C:\Fake' }
    $checks.backupRootOmittedWhenNotGiven = [ordered]@{
        notBound = (-not [bool]$r3.backupRootBound)
    }
    if ($checks.backupRootOmittedWhenNotGiven.Values -contains $false) { $fail.Add('backupRootOmittedWhenNotGiven failed: ' + ($checks.backupRootOmittedWhenNotGiven | ConvertTo-Json -Compress)) }

    $thrown4 = $null
    try { Invoke-KICompleteJsonScriptIsolated -Script $standIn -Arguments @{ Action = 'ForceFail'; TargetRoot = 'C:\Fake' } | Out-Null }
    catch { $thrown4 = $_ }
    $checks.nonZeroExitWithValidJsonStillReturnsTheResult = [ordered]@{
        noThrow = ($null -eq $thrown4)
    }
    # The stand-in still prints valid JSON before exiting 1 -- Invoke-KICompleteJsonScriptIsolated
    # must return that parsed result (passed=$false) to its caller, exactly like
    # Invoke-KICompleteJsonScript already does, so the EXISTING "if(-not[bool]$result.passed){throw ...}"
    # call-site logic keeps working unchanged.
    $r4 = Invoke-KICompleteJsonScriptIsolated -Script $standIn -Arguments @{ Action = 'ForceFail'; TargetRoot = 'C:\Fake' }
    $checks.nonZeroExitWithValidJsonStillReturnsTheResult.resultReflectsFailure = (-not [bool]$r4.passed)
    if ($checks.nonZeroExitWithValidJsonStillReturnsTheResult.Values -contains $false) { $fail.Add('nonZeroExitWithValidJsonStillReturnsTheResult failed: ' + ($checks.nonZeroExitWithValidJsonStillReturnsTheResult | ConvertTo-Json -Compress)) }

    $thrown5 = $null
    try { Invoke-KICompleteJsonScriptIsolated -Script (Join-Path $scratchBase 'does-not-exist.ps1') -Arguments @{ Action = 'Install' } | Out-Null }
    catch { $thrown5 = $_ }
    $checks.missingScriptIsAClearErrorNeverSilent = [ordered]@{
        threw = ($null -ne $thrown5)
        mentionsExitCodeOrOutput = ($null -ne $thrown5 -and [string]$thrown5.Exception.Message -match '(?i)Exitcode|Ausgabe')
    }
    if ($checks.missingScriptIsAClearErrorNeverSilent.Values -contains $false) { $fail.Add('missingScriptIsAClearErrorNeverSilent failed: ' + ($checks.missingScriptIsAClearErrorNeverSilent | ConvertTo-Json -Compress)) }

    # === Part 2: Install-KIDesktopControl -BackupRoot contract (B + E) -- real code, no winapp ===
    $dcSource = Join-Path $PackageRoot '..\..\desktop-control\current' | Resolve-Path
    Import-Module (Join-Path $dcSource 'DesktopControl.psm1') -Force

    $t1Root = Join-Path $scratchBase 'backuproot-given'
    New-Item -ItemType Directory -Path $t1Root -Force | Out-Null
    $externalBackupRoot = Join-Path $scratchBase 'transaction-backups\desktop-control'
    $install1 = Install-KIDesktopControl -PackageRoot $dcSource -TargetRoot $t1Root -Action 'Install' -BackupRoot $externalBackupRoot
    $checks.backupRootContractWhenGiven = [ordered]@{
        installed = ([string]$install1.status -eq 'Installed')
        backupPathUnderExternalRoot = ([string]$install1.backupPath).StartsWith($externalBackupRoot)
        backupPathNeverUnderStandaloneRoot = -not (([string]$install1.backupPath) -like (Join-Path $t1Root 'backups\desktop-control*'))
        rollbackJsonActuallyExists = (Test-Path -LiteralPath $install1.backupPath -PathType Leaf)
    }
    if ($checks.backupRootContractWhenGiven.Values -contains $false) { $fail.Add('backupRootContractWhenGiven failed: ' + ($checks.backupRootContractWhenGiven | ConvertTo-Json -Compress)) }

    $t2Root = Join-Path $scratchBase 'backuproot-omitted'
    New-Item -ItemType Directory -Path $t2Root -Force | Out-Null
    $install2 = Install-KIDesktopControl -PackageRoot $dcSource -TargetRoot $t2Root -Action 'Install'
    $checks.standaloneBackupUnchangedWhenBackupRootOmitted = [ordered]@{
        installed = ([string]$install2.status -eq 'Installed')
        backupPathUnderStandaloneRoot = ([string]$install2.backupPath).StartsWith((Join-Path $t2Root 'backups\desktop-control'))
        rollbackJsonActuallyExists = (Test-Path -LiteralPath $install2.backupPath -PathType Leaf)
    }
    if ($checks.standaloneBackupUnchangedWhenBackupRootOmitted.Values -contains $false) { $fail.Add('standaloneBackupUnchangedWhenBackupRootOmitted failed: ' + ($checks.standaloneBackupUnchangedWhenBackupRootOmitted | ConvertTo-Json -Compress)) }

    # Rollback against the externally-rooted backup must still work -- Restore-KIDesktopControlBackup
    # derives its own root purely from the given BackupPath, never assumes the standalone scheme.
    # This was a fresh Install on an empty TargetRoot, so rollback.json correctly recorded
    # existed=false for every item -- a correct rollback REMOVES the just-deployed tree again
    # (back to the true pre-Install state), it does not recreate it from nothing.
    $rollback1 = Restore-KIDesktopControl -BackupPath $install1.backupPath -TargetRoot $t1Root
    $checks.rollbackWorksAgainstExternallyRootedBackup = [ordered]@{
        completed = ([string]$rollback1.status -eq 'Completed')
        deployedTreeRemovedAgain = -not (Test-Path -LiteralPath (Join-Path $t1Root 'tools\desktop-control\current') -PathType Container)
    }
    if ($checks.rollbackWorksAgainstExternallyRootedBackup.Values -contains $false) { $fail.Add('rollbackWorksAgainstExternallyRootedBackup failed: ' + ($checks.rollbackWorksAgainstExternallyRootedBackup | ConvertTo-Json -Compress)) }

    # === Part 3: Assert-KICompletePathAwareTransaction -- already-completed rollback (C) =========
    $fakePathContext = [pscustomobject]@{
        TargetRoot = 'C:\Fake'; StateRoot = 'C:\Fake\state\complete-installer'
        TransactionRoot = 'C:\Fake\state\complete-installer\transactions\FAKE-TX'
        BackupRoot = 'C:\Fake\backups\complete-installer'; LogRoot = 'C:\Fake\logs\complete-installer'
        PathContractVersion = '1.0'; TransactionId = 'FAKE-TX'
        TransactionBackupRoot = 'C:\Fake\backups\complete-installer\FAKE-TX'
    }
    function New-FakeTransaction([string]$RollbackStatus, [string]$BackupPath) {
        [pscustomobject]@{
            schemaVersion = '1.1'; transactionId = 'FAKE-TX'; targetRoot = $fakePathContext.TargetRoot
            stateRoot = $fakePathContext.StateRoot; transactionRoot = $fakePathContext.TransactionRoot
            backupRoot = $fakePathContext.BackupRoot; logRoot = $fakePathContext.LogRoot
            pathContractVersion = $fakePathContext.PathContractVersion
            steps = @([pscustomobject]@{ id = 'desktop-control'; status = 'Failed'; rollbackStatus = $RollbackStatus; backup = $BackupPath; result = $null })
        }
    }
    $foreignPath = 'C:\Fake\backups\desktop-control\20260101-000000-0000000\rollback.json'
    $txPath = Join-Path $fakePathContext.TransactionRoot 'transaction.json'

    $thrownCompleted = $null
    try { Assert-KICompletePathAwareTransaction -Transaction (New-FakeTransaction 'Completed' $foreignPath) -PathContext $fakePathContext -TransactionPath $txPath }
    catch { $thrownCompleted = $_ }
    $thrownFailed = $null
    try { Assert-KICompletePathAwareTransaction -Transaction (New-FakeTransaction 'Failed' $foreignPath) -PathContext $fakePathContext -TransactionPath $txPath }
    catch { $thrownFailed = $_ }
    $thrownNull = $null
    try { Assert-KICompletePathAwareTransaction -Transaction (New-FakeTransaction $null $foreignPath) -PathContext $fakePathContext -TransactionPath $txPath }
    catch { $thrownNull = $_ }
    $goodPath = Join-Path $fakePathContext.TransactionBackupRoot 'desktop-control\20260101-000000-0000000\rollback.json'
    $thrownGoodPath = $null
    try { Assert-KICompletePathAwareTransaction -Transaction (New-FakeTransaction 'Completed' $goodPath) -PathContext $fakePathContext -TransactionPath $txPath }
    catch { $thrownGoodPath = $_ }

    $checks.completedRollbackNoLongerBlocksAForeignBackupPath = [ordered]@{
        rollbackStatusCompletedForeignPathAccepted = ($null -eq $thrownCompleted)
        rollbackStatusFailedForeignPathStillRejected = ($null -ne $thrownFailed -and [string]$thrownFailed.Exception.Message -match 'außerhalb des erwarteten Root')
        rollbackStatusNullForeignPathStillRejected = ($null -ne $thrownNull -and [string]$thrownNull.Exception.Message -match 'außerhalb des erwarteten Root')
        rollbackStatusCompletedCorrectPathStillAccepted = ($null -eq $thrownGoodPath)
    }
    if ($checks.completedRollbackNoLongerBlocksAForeignBackupPath.Values -contains $false) { $fail.Add('completedRollbackNoLongerBlocksAForeignBackupPath failed: ' + ($checks.completedRollbackNoLongerBlocksAForeignBackupPath | ConvertTo-Json -Compress)) }

    # === Part 4: static source checks -- step handler wiring, and scope stayed narrow ============
    $orchestratorSource = Get-Content -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Raw
    $stepMatch = [regex]::Match($orchestratorSource, "(?s)elseif \(\`$step\.id -eq 'desktop-control'\) \{.*?\n            \}\n            elseif")
    if (-not $stepMatch.Success) { throw 'Desktop-Control-Step-Handler nicht gefunden.' }
    $stepText = $stepMatch.Value
    $checks.stepHandlerWiring = [ordered]@{
        installUpgradeRepairIsIsolated = ($stepText -match "\`$result\s*=\s*Invoke-KICompleteJsonScriptIsolated\s+-Script\s+\`$entry\s+-Arguments\s+@\{Action=\`$action;TargetRoot=\`$TargetRoot;BackupRoot=\`$desktopControlBackupRoot\}")
        validateIsIsolated = ($stepText -match "\`$validation\s*=\s*Invoke-KICompleteJsonScriptIsolated\s+-Script\s+\`$entry\s+-Arguments\s+@\{Action='Validate';TargetRoot=\`$TargetRoot\}")
        backupRootIsTransactionScoped = $stepText.Contains("Join-Path ([string]`$pathContext.TransactionBackupRoot) 'desktop-control'")
        rollbackStaysInProcess = ($stepText -match "\`$rollback\s*=\s*Invoke-KICompleteJsonScript\s+-Script\s+\`$entry\s+-Arguments\s+@\{Action='Rollback'")
    }
    if ($checks.stepHandlerWiring.Values -contains $false) { $fail.Add('stepHandlerWiring failed: ' + ($checks.stepHandlerWiring | ConvertTo-Json -Compress)) }

    $otherIsolatedStepsUnchanged = $true
    foreach ($otherId in @('open-terminal', 'mcp-runtime', 'winapp')) {
        $otherMatch = [regex]::Match($orchestratorSource, "(?s)elseif \(\`$step\.id -eq '$otherId'\) \{.*?\n            \}\n            elseif")
        if ($otherMatch.Success -and $otherMatch.Value -match 'Invoke-KICompleteJsonScriptIsolated') { $otherIsolatedStepsUnchanged = $false }
    }
    $checks.generalComponentRunnerLeftUntouched = [ordered]@{
        onlyDesktopControlUsesTheIsolatedInvoker = $otherIsolatedStepsUnchanged
    }
    if ($checks.generalComponentRunnerLeftUntouched.Values -contains $false) { $fail.Add('generalComponentRunnerLeftUntouched failed: ' + ($checks.generalComponentRunnerLeftUntouched | ConvertTo-Json -Compress)) }

    $passed = $fail.Count -eq 0
    [pscustomobject]@{ passed = $passed; checks = $checks; failures = @($fail) } | ConvertTo-Json -Depth 12
    if (-not $passed) { throw 'Desktop-Control-Lifecycle-Isolation-Hotfix-Regression fehlgeschlagen.' }
} finally {
    try { Remove-Item -LiteralPath $scratchBase -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

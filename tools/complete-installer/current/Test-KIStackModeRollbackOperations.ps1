[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Regression suite for Mode-Rollback-P1: -Mode Rollback/-Mode RollbackOperations has only ever
# called Restore-KICompleteOperations -- an Operations Restore (registry/autostart, Desktop
# shortcuts, Docker restart policy), never a full installation rollback. This suite proves the
# public CLI-mode dispatch itself: the new unambiguous name works, the old name remains a fully
# compatible deprecated alias, the returned/output object names its real scope explicitly, a
# missing operations-latest state fails closed with a clear, non-misleading error, the real
# Restore-KICompleteOperations function is genuinely invoked, and -- critically -- no other
# component/recovery/installation logic (preflight, plan, transaction) is ever reached by this
# mode. Runs entirely in-process against the real, unmodified CompleteInstaller.psm1: this mode
# never reaches the Administrator preflight gate at all, so unlike other fixture-based tests in
# this package, no source-patched copy of the module is needed here.

Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force -DisableNameChecking
$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-ModeRollbackOperations-'+[guid]::NewGuid().ToString('N'))

function New-KIRollbackFixturePackageRoot {
    # A minimal PackageRoot for the -PackageRoot argument actually passed to
    # Invoke-KIStackCompleteInstaller in this suite -- only what Get-KICompletePackageRoot and
    # the two unconditional Read-KICompleteJson calls (Config, Contracts/COMPONENTS.json) before
    # the Mode dispatch need. The module itself (CompleteInstaller.psm1) is still imported from
    # the real, complete source tree above, so its own Runtime/KIStackPathContext.psm1 import
    # resolves normally; this fixture never needs its own copy of that or of the module.
    param([Parameter(Mandatory)][string]$PackageStageRoot)
    New-Item -ItemType Directory -Path $PackageStageRoot,(Join-Path $PackageStageRoot 'Payload') -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $PackageStageRoot 'MANIFEST.json') -Value '{"schemaVersion":"1.0"}' -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $PackageStageRoot 'Contracts') -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $PackageStageRoot 'Contracts/COMPONENTS.json') -Value '{"schemaVersion":"1.0","components":[]}' -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $PackageStageRoot 'Config') -Force|Out-Null
    $config=[ordered]@{schemaVersion='1.0';version='2.13.0';targetRoot='';stateDirectory='';backupDirectory='';logDirectory='';openWebUIEndpoint='http://mock.invalid';timeouts=[ordered]@{processSeconds=60;healthSeconds=5};optionalComponents=[ordered]@{openWebUIBallistics=$false};healthEndpoints=@()}
    Set-Content -LiteralPath (Join-Path $PackageStageRoot 'Config/complete-installer.config.json') -Value ($config|ConvertTo-Json -Depth 10) -Encoding UTF8
    $PackageStageRoot
}

function New-KIRollbackFixtureTarget {
    # Runs the real Install-KICompleteOperations against a fresh, isolated TargetRoot/Desktop
    # fixture (never the real Desktop or C:\KI-Stack), producing a real operations-latest.json
    # pointer and operations.backup.json exactly as a real Install/Upgrade transaction would.
    param([Parameter(Mandatory)][string]$TargetRoot)
    New-Item -ItemType Directory -Path $TargetRoot -Force|Out-Null
    $fixtureDesktop=Join-Path $TargetRoot '__fixture-desktop'
    $transactionId='KI-COMPLETE-FIXTURE-'+[guid]::NewGuid().ToString('N').Substring(0,12)
    $pathContext=New-KICompletePathContext -TargetRoot $TargetRoot -PackageRoot $PackageRoot -TransactionId $transactionId -DesktopPath $fixtureDesktop -Mutating
    $operationsBackupRoot=Join-Path ([string]$pathContext.TransactionBackupRoot) 'operations'
    $installResult=Install-KICompleteOperations -TargetRoot $TargetRoot -BackupRoot $operationsBackupRoot -DesktopPath $fixtureDesktop -PathContext $pathContext
    [pscustomobject]@{targetRoot=$TargetRoot;desktop=$fixtureDesktop;pathContext=$pathContext;installResult=$installResult}
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force|Out-Null
    $rollbackPackageRoot=New-KIRollbackFixturePackageRoot -PackageStageRoot (Join-Path $fixtureRoot 'rollback-package')

    # === 1+3+5. New unambiguous mode works for real, and names its scope correctly. ===========
    $fixtureA=New-KIRollbackFixtureTarget -TargetRoot (Join-Path $fixtureRoot 'target-a')
    $desktopStartLinkA=Join-Path $fixtureA.desktop 'KI-Stack starten.lnk'
    $existedBeforeA=Test-Path -LiteralPath $desktopStartLinkA
    $rollbackOpsResult=Invoke-KIStackCompleteInstaller -Mode RollbackOperations -PackageRoot $rollbackPackageRoot -TargetRoot $fixtureA.targetRoot
    $existsAfterA=Test-Path -LiteralPath $desktopStartLinkA
    $checks.newModeWorksAndNamesScope=[ordered]@{
        operationIsOperationsRestore=([string]$rollbackOpsResult.operation-eq'OperationsRestore')
        scopeNamesRegistryAutostart=(@($rollbackOpsResult.scope)-join'|')-match'Registry/Autostart'
        scopeNamesDesktopShortcuts=(@($rollbackOpsResult.scope)-join'|')-match'Desktop'
        scopeNamesDockerRestartPolicy=(@($rollbackOpsResult.scope)-join'|')-match'Docker'
        notRestoredNamesRealComponents=([string]$rollbackOpsResult.notRestored-match'OpenWebUI'-and[string]$rollbackOpsResult.notRestored-match'ComfyUI'-and[string]$rollbackOpsResult.notRestored-match'Codex Local'-and[string]$rollbackOpsResult.notRestored-match'Knowledge')
        noDeprecatedAliasFieldOnNewMode=(-not($rollbackOpsResult.PSObject.Properties.Name-contains'deprecatedAliasUsed'))
        underlyingResultIsOperationsRestored=([string]$rollbackOpsResult.result.status-eq'OperationsRestored')
        desktopLinkWasRemovedByRestore=($existedBeforeA-and-not$existsAfterA)
    }
    if($checks.newModeWorksAndNamesScope.Values-contains$false){$fail.Add('newModeWorksAndNamesScope failed: '+($checks.newModeWorksAndNamesScope|ConvertTo-Json -Compress))}

    # === 2/B. The old 'Rollback' name remains a fully compatible, deprecated alias -- for 2.13
    # this means the HISTORICAL FLAT return shape (exactly what Restore-KICompleteOperations
    # itself returns, never wrapped) and the HISTORICAL exit-code contract, not the new
    # structured shape. Neither the return shape nor the "no backup -> restored=$false, exit 0"
    # behavior is a security boundary, so both are deliberately preserved for this deprecated
    # alias -- only a warning is added. Only 'RollbackOperations' gets the new contract.
    $fixtureB=New-KIRollbackFixtureTarget -TargetRoot (Join-Path $fixtureRoot 'target-b')
    # Invoke-KIStackCompleteInstaller has no [CmdletBinding()], so -WarningVariable/-WarningAction
    # are not supported as common parameters on it; capture the Warning stream (3) directly.
    $legacyOutput=Invoke-KIStackCompleteInstaller -Mode Rollback -PackageRoot $rollbackPackageRoot -TargetRoot $fixtureB.targetRoot 3>&1
    $legacyWarnings=@($legacyOutput|Where-Object{$_-is[Management.Automation.WarningRecord]})
    $legacyResult=@($legacyOutput|Where-Object{$_-isnot[Management.Automation.WarningRecord]})|Select-Object -Last 1
    $checks.legacyAliasKeepsHistoricalFlatShape=[ordered]@{
        deprecationWarningEmitted=(@(@($legacyWarnings)|Where-Object{[string]$_-match'veraltet'-or[string]$_-match'deprecated'})).Count-gt0
        resultIsHistoricalFlatShape=([string]$legacyResult.status-eq'OperationsRestored')
        resultHasNoWrapperFields=(-not($legacyResult.PSObject.Properties.Name-contains'operation')-and-not($legacyResult.PSObject.Properties.Name-contains'result')-and-not($legacyResult.PSObject.Properties.Name-contains'scope')-and-not($legacyResult.PSObject.Properties.Name-contains'notRestored'))
        restoredIsTrueDirectlyOnResult=([bool]$legacyResult.restored)
        backupPathPresentDirectlyOnResult=(-not[string]::IsNullOrWhiteSpace([string]$legacyResult.backupPath))
    }
    if($checks.legacyAliasKeepsHistoricalFlatShape.Values-contains$false){$fail.Add('legacyAliasKeepsHistoricalFlatShape failed: '+($checks.legacyAliasKeepsHistoricalFlatShape|ConvertTo-Json -Compress))}

    # === 4/A. No operations-latest state at all under RollbackOperations -> clean, fail-closed
    # error, never a false success and never phrased as if a full rollback had been attempted.
    $fixtureC=Join-Path $fixtureRoot 'target-c-never-installed';New-Item -ItemType Directory -Path $fixtureC -Force|Out-Null
    $threwC=$false;$messageC=''
    try { Invoke-KIStackCompleteInstaller -Mode RollbackOperations -PackageRoot $rollbackPackageRoot -TargetRoot $fixtureC | Out-Null }
    catch { $threwC=$true;$messageC=$_.Exception.Message }
    $checks.noOperationsLatestFailsClosed=[ordered]@{
        threw=$threwC
        messageNamesOperationsRestore=($messageC-match'Operations Restore')
        messageDoesNotClaimFullRollback=($messageC-notmatch'vollständige.{0,3}Installation'-or$messageC-match'kein vollständiger Installations-Rollback')
        messageExplicitlyDeniesFullRollback=($messageC-match'kein vollständiger Installations-Rollback')
    }
    if($checks.noOperationsLatestFailsClosed.Values-contains$false){$fail.Add('noOperationsLatestFailsClosed failed: threw='+$threwC+'; message='+$messageC)}

    # === D. No operations-latest state under the 'Rollback' alias -> deliberately DIFFERENT from
    # RollbackOperations: preserves the historical, non-throwing, restored=$false/exit-0 contract
    # (plus the deprecation warning), since this is not a security boundary and existing external
    # scripts may already depend on the alias never throwing here.
    $threwD=$false;$resultD=$null;$warningsD=@()
    try {
        $outputD=Invoke-KIStackCompleteInstaller -Mode Rollback -PackageRoot $rollbackPackageRoot -TargetRoot $fixtureC 3>&1
        $warningsD=@($outputD|Where-Object{$_-is[Management.Automation.WarningRecord]})
        $resultD=@($outputD|Where-Object{$_-isnot[Management.Automation.WarningRecord]})|Select-Object -Last 1
    } catch { $threwD=$true }
    $checks.legacyAliasNoBackupStaysNonThrowing=[ordered]@{
        didNotThrow=(-not $threwD)
        statusIsNoOperationsBackup=([string]$resultD.status-eq'NoOperationsBackup')
        restoredIsFalse=(-not [bool]$resultD.restored)
        deprecationWarningStillEmitted=(@(@($warningsD)|Where-Object{[string]$_-match'veraltet'-or[string]$_-match'deprecated'})).Count-gt0
    }
    if($checks.legacyAliasNoBackupStaysNonThrowing.Values-contains$false){$fail.Add('legacyAliasNoBackupStaysNonThrowing failed: '+($checks.legacyAliasNoBackupStaysNonThrowing|ConvertTo-Json -Compress))}

    # === C. Both modes perform the identical underlying Operations Restore against an equivalent
    # real backup state -- only the outer return shape and exit-code contract differ. ===========
    $fixtureE1=New-KIRollbackFixtureTarget -TargetRoot (Join-Path $fixtureRoot 'target-e-new')
    $fixtureE2=New-KIRollbackFixtureTarget -TargetRoot (Join-Path $fixtureRoot 'target-e-legacy')
    $desktopLinkE1=Join-Path $fixtureE1.desktop 'KI-Stack starten.lnk'
    $desktopLinkE2=Join-Path $fixtureE2.desktop 'KI-Stack starten.lnk'
    $existedBeforeE1=Test-Path -LiteralPath $desktopLinkE1
    $existedBeforeE2=Test-Path -LiteralPath $desktopLinkE2
    $newModeResultE=Invoke-KIStackCompleteInstaller -Mode RollbackOperations -PackageRoot $rollbackPackageRoot -TargetRoot $fixtureE1.targetRoot
    $legacyModeResultE=Invoke-KIStackCompleteInstaller -Mode Rollback -PackageRoot $rollbackPackageRoot -TargetRoot $fixtureE2.targetRoot -WarningAction SilentlyContinue 3>$null
    $checks.bothModesPerformIdenticalOperationsRestore=[ordered]@{
        newModeUnderlyingStatusRestored=([string]$newModeResultE.result.status-eq'OperationsRestored')
        legacyModeStatusRestored=([string]$legacyModeResultE.status-eq'OperationsRestored')
        newModeDesktopLinkRemoved=($existedBeforeE1-and-not(Test-Path -LiteralPath $desktopLinkE1))
        legacyModeDesktopLinkRemoved=($existedBeforeE2-and-not(Test-Path -LiteralPath $desktopLinkE2))
    }
    if($checks.bothModesPerformIdenticalOperationsRestore.Values-contains$false){$fail.Add('bothModesPerformIdenticalOperationsRestore failed: '+($checks.bothModesPerformIdenticalOperationsRestore|ConvertTo-Json -Compress))}

    # === 6. No other component/recovery/installation logic is ever reached by this mode. ======
    # A target with no operations-latest AND no prior transaction must show zero evidence of a
    # plan/transaction/preflight ever having run as a side effect of the Rollback dispatch itself
    # (case 4 above already proved the mode fails before doing anything else; this proves it
    # specifically never created transaction/plan state on its way to that failure, and that a
    # SUCCESSFUL Rollback -- fixture A above -- also never left any such state behind).
    $transactionsRootA=Join-Path ([string]$fixtureA.pathContext.StateRoot) 'transactions'
    $transactionsRootC=Join-Path $fixtureC 'state/complete-installer/transactions'
    $checks.noOtherInstallationLogicTriggered=[ordered]@{
        successfulRollbackCreatedNoNewTransaction=(-not (Test-Path -LiteralPath $transactionsRootA) -or (@(Get-ChildItem -LiteralPath $transactionsRootA -ErrorAction SilentlyContinue|Where-Object{ $_.Name -ne (Split-Path -Leaf $fixtureA.pathContext.TransactionRoot) })).Count -eq 0)
        failedRollbackCreatedNoTransactionAtAll=(-not (Test-Path -LiteralPath $transactionsRootC))
        failedRollbackCreatedNoComponentStateFile=(-not (Test-Path -LiteralPath (Join-Path $fixtureC 'state/complete-installer/components.json')))
    }
    if($checks.noOtherInstallationLogicTriggered.Values-contains$false){$fail.Add('noOtherInstallationLogicTriggered failed: '+($checks.noOtherInstallationLogicTriggered|ConvertTo-Json -Compress))}

    # === Negative control / structural: the ValidateSet and dispatch wiring are actually in the
    # real, current source -- and the old, unqualified single-line dispatch this P1 replaces is
    # genuinely gone, not just supplemented.
    $moduleSource=Get-Content -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Raw
    $wrapperSource=Get-Content -LiteralPath (Join-Path $PackageRoot 'Invoke-KIStackCompleteInstaller.ps1') -Raw
    $checks.publicContractWiring=[ordered]@{
        moduleValidateSetHasNewMode=($moduleSource-match "ValidateSet\([^)]*'RollbackOperations'")
        wrapperValidateSetHasNewMode=($wrapperSource-match "ValidateSet\([^)]*'RollbackOperations'")
        oldUnqualifiedDispatchGone=(-not $moduleSource.Contains("if (`$Mode -eq 'Rollback') { return Restore-KICompleteOperations"))
        moduleContainsFailClosedThrow=$moduleSource.Contains('Operations Restore fehlgeschlagen')
    }
    if($checks.publicContractWiring.Values-contains$false){$fail.Add('publicContractWiring failed: '+($checks.publicContractWiring|ConvertTo-Json -Compress))}
}
finally {
    if(Test-Path -LiteralPath $fixtureRoot){Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue}
}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 15
if(-not$passed){throw 'Mode-Rollback-P1-Regression fehlgeschlagen.'}

[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force

$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

# Real, explicitly requested verification (2.18.2 base/stabilization closeout): the OpenWebUI
# secret-key fix and the Applications 1.4.11->1.4.12 version bump already proved, once, that
# shipping changed generated content without also bumping the version that gates its redeployment
# leaves an existing target permanently reported compliant/Skip. This test proves the SAME real
# delivery/reconcile contract for the two remaining 2.18.2 base fixes:
#   - Open Terminal 0.1.0 -> 0.1.1 (the PID-tracking fix lives entirely in OpenTerminal.psm1's own
#     logic -- the package invoked for Start/Stop/Status is the one extracted at Install/Upgrade
#     time and referenced by a path baked into the deployed starter .cmd, so an existing,
#     already-compliant target never re-extracts a fixed copy without a version bump)
#   - Cutover Runtime 1.6.14 -> 1.6.15 (the ComfyUI stop-race fix lives inside
#     Modules/04-ComfyUI/KIModuleComfyUI.psm1, part of the shared foundation-runtime/python-git/
#     applications/cutover-runtime BuilderKernel bundle -- exactly the same bundle 'applications'
#     already belongs to)
# Both use real PathContext/installation.json/components.json fixtures, not FixtureState (which,
# for a 'pinned-runtime-reference' kind component like cutover-runtime, cannot represent stored
# state at all and would misleadingly always force Upgrade regardless of the installed/pin match).

$contract=Get-Content -LiteralPath (Join-Path $PackageRoot 'Contracts/COMPONENTS.json') -Raw|ConvertFrom-Json -Depth 30
$openTerminalComponent=@($contract.components|Where-Object id -eq 'open-terminal')[0]
$cutoverRuntimeComponent=@($contract.components|Where-Object id -eq 'cutover-runtime')[0]
$checks.pinsAreAtTheExpectedNewPatchVersions=[ordered]@{
    openTerminalPinned=[string]$openTerminalComponent.version
    openTerminalIsAtLeast011=([version]([string]$openTerminalComponent.version)) -ge ([version]'0.1.1')
    cutoverRuntimePinned=[string]$cutoverRuntimeComponent.version
    cutoverRuntimeIsAtLeast1615=([version]([string]$cutoverRuntimeComponent.version)) -ge ([version]'1.6.15')
}
if(-not[bool]$checks.pinsAreAtTheExpectedNewPatchVersions.openTerminalIsAtLeast011){$fail.Add('Open Terminal pin was not bumped to 0.1.1 or later: '+$checks.pinsAreAtTheExpectedNewPatchVersions.openTerminalPinned)}
if(-not[bool]$checks.pinsAreAtTheExpectedNewPatchVersions.cutoverRuntimeIsAtLeast1615){$fail.Add('Cutover Runtime pin was not bumped to 1.6.15 or later: '+$checks.pinsAreAtTheExpectedNewPatchVersions.cutoverRuntimePinned)}

function New-KIFixtureTargetRoot {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-OtCutoverPlan-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    $root
}
function Set-KICutoverMarker {
    param([Parameter(Mandatory)][string]$TargetRoot,[Parameter(Mandatory)][string]$Version)
    $markerDir=Join-Path $TargetRoot 'modules/cutover'
    New-Item -ItemType Directory -Path $markerDir -Force|Out-Null
    $marker=[pscustomobject][ordered]@{managedBy='KI-STACK-CUTOVER-MANAGED';schemaVersion='1.0';release=('KI-Stack-Cutover-Execute-v'+$Version);installedAt=(Get-Date).ToString('o')}
    Set-Content -LiteralPath (Join-Path $markerDir 'installation.json') -Encoding utf8 -Value ($marker|ConvertTo-Json)
}
function Set-KIComponentStoredState {
    param([Parameter(Mandatory)][object]$PathContext,[Parameter(Mandatory)][string]$ComponentId,[Parameter(Mandatory)][string]$Version)
    $statePath=Get-KICompleteComponentStatePath -PathContext $PathContext
    New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force|Out-Null
    $existing=if(Test-Path -LiteralPath $statePath){Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json -Depth 20}else{$null}
    $components=[ordered]@{}
    if($null-ne$existing-and$existing.PSObject.Properties['components']){foreach($p in $existing.components.PSObject.Properties){$components[$p.Name]=$p.Value}}
    $components[$ComponentId]=$Version
    $state=[ordered]@{schemaVersion='1.0';status='ValidatedExistingInstallation';completeInstallerVersion='TEST';validatedAtUtc=(Get-Date).ToString('o');components=$components;evidence=[ordered]@{stateReconciledFromRealProbes=$true;containsSecrets=$false}}
    Write-KICompleteJson $statePath $state
}
function Set-KIOpenTerminalFullyCompliantFixture {
    param([Parameter(Mandatory)][string]$TargetRoot,[Parameter(Mandatory)][string]$Version)
    $moduleRoot=Join-Path $TargetRoot 'modules/open-terminal'
    $stateRoot=Join-Path $TargetRoot 'state/open-terminal'
    New-Item -ItemType Directory -Path $moduleRoot,$stateRoot,(Join-Path $stateRoot 'workspace') -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $moduleRoot 'installation.json') -Encoding utf8 -Value (([pscustomobject][ordered]@{schemaVersion='1.0';version=$Version;host='127.0.0.1';port=8000})|ConvertTo-Json)
    Set-Content -LiteralPath (Join-Path $moduleRoot 'Start-KIStack-OpenTerminal.cmd') -Encoding ascii -Value '@echo off'
    Set-Content -LiteralPath (Join-Path $moduleRoot 'Stop-KIStack-OpenTerminal.cmd') -Encoding ascii -Value '@echo off'
    Set-Content -LiteralPath (Join-Path $stateRoot 'credential.json') -Encoding utf8 -Value '{"schemaVersion":"1.0","encryptedApiKey":"placeholder"}'
}

# =========================== Open Terminal (kind: component) ===============================
# 1. Outdated target (installed=0.1.0, everything else present) -> must plan Upgrade, never Skip.
$rootOtOutdated=New-KIFixtureTargetRoot
try{
    Set-KIOpenTerminalFullyCompliantFixture -TargetRoot $rootOtOutdated -Version '0.1.0'
    $planOtOutdated=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $rootOtOutdated
    $stepOtOutdated=@($planOtOutdated.steps|Where-Object id -eq 'open-terminal')[0]
    $checks.openTerminalOutdatedPlansUpgrade=[ordered]@{
        installedReadBack=$stepOtOutdated.initialState.installedVersion-eq'0.1.0'
        notCompliant=-not[bool]$stepOtOutdated.initialState.compliant
        plannedModeIsUpgrade=$stepOtOutdated.plannedMode-eq'Upgrade'
        plannedModeIsNotSkip=$stepOtOutdated.plannedMode-ne'Skip'
    }
    if($checks.openTerminalOutdatedPlansUpgrade.Values-contains$false){$fail.Add('Scenario OpenTerminalOutdatedPlansUpgrade failed: '+($stepOtOutdated|ConvertTo-Json -Compress))}
}finally{
    if(Test-Path -LiteralPath $rootOtOutdated){Remove-Item -LiteralPath $rootOtOutdated -Recurse -Force -ErrorAction SilentlyContinue}
}

# 2. Fully up-to-date target (installed=0.1.1, all required artifacts present) -> genuine Skip
# straight away -- open-terminal is kind='component' (not 'pinned-runtime-reference'), so it is
# never subject to the separate forcesReconciliationUpgrade state-catch-up requirement that
# pinned-runtime-reference components (cutover-runtime, below) are.
$rootOtUpToDate=New-KIFixtureTargetRoot
try{
    Set-KIOpenTerminalFullyCompliantFixture -TargetRoot $rootOtUpToDate -Version ([string]$openTerminalComponent.version)
    $planOtUpToDate=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $rootOtUpToDate
    $stepOtUpToDate=@($planOtUpToDate.steps|Where-Object id -eq 'open-terminal')[0]
    $checks.openTerminalUpToDateIsSkip=[ordered]@{
        compliant=[bool]$stepOtUpToDate.initialState.compliant
        plannedModeIsSkip=$stepOtUpToDate.plannedMode-eq'Skip'
        statusSkippedAlreadyCompliant=$stepOtUpToDate.status-eq'SkippedAlreadyCompliant'
    }
    if($checks.openTerminalUpToDateIsSkip.Values-contains$false){$fail.Add('Scenario OpenTerminalUpToDateIsSkip failed: '+($stepOtUpToDate|ConvertTo-Json -Compress))}
}finally{
    if(Test-Path -LiteralPath $rootOtUpToDate){Remove-Item -LiteralPath $rootOtUpToDate -Recurse -Force -ErrorAction SilentlyContinue}
}

# =========================== Cutover Runtime (kind: pinned-runtime-reference) ===============
# 3. Outdated target (live marker still says 1.6.14) -> must plan Upgrade, never Skip -- this is
# what actually re-triggers the whole shared BuilderKernel bundle (foundation-runtime/python-git/
# applications/cutover-runtime), which is what redeploys 04-ComfyUI's fixed stop-script content.
$rootCrOutdated=New-KIFixtureTargetRoot
try{
    Set-KICutoverMarker -TargetRoot $rootCrOutdated -Version '1.6.14'
    $planCrOutdated=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $rootCrOutdated
    $stepCrOutdated=@($planCrOutdated.steps|Where-Object id -eq 'cutover-runtime')[0]
    $checks.cutoverRuntimeOutdatedPlansUpgrade=[ordered]@{
        installedReadBack=$stepCrOutdated.initialState.installedVersion-eq'1.6.14'
        notCompliant=-not[bool]$stepCrOutdated.initialState.compliant
        plannedModeIsUpgrade=$stepCrOutdated.plannedMode-eq'Upgrade'
        plannedModeIsNotSkip=$stepCrOutdated.plannedMode-ne'Skip'
    }
    if($checks.cutoverRuntimeOutdatedPlansUpgrade.Values-contains$false){$fail.Add('Scenario CutoverRuntimeOutdatedPlansUpgrade failed: '+($stepCrOutdated|ConvertTo-Json -Compress))}

    $stepCrOutdatedRepair=@((New-KICompletePlan -Mode Repair -PackageRoot $PackageRoot -TargetRoot $rootCrOutdated).steps|Where-Object id -eq 'cutover-runtime')[0]
    $checks.cutoverRuntimeRepairModeAlsoReconciles=[ordered]@{plannedModeNotSkip=$stepCrOutdatedRepair.plannedMode-ne'Skip'}
    if($checks.cutoverRuntimeRepairModeAlsoReconciles.Values-contains$false){$fail.Add('Scenario CutoverRuntimeRepairModeAlsoReconciles failed: '+($stepCrOutdatedRepair|ConvertTo-Json -Compress))}
}finally{
    if(Test-Path -LiteralPath $rootCrOutdated){Remove-Item -LiteralPath $rootCrOutdated -Recurse -Force -ErrorAction SilentlyContinue}
}

# 4. Installed already matches the new pin (1.6.15) but no recorded/stored state exists yet ->
# compliant=true, but forcesReconciliationUpgrade (pinned-runtime-reference contract, pre-existing
# and unrelated to this fix) still schedules one more real dispatch until state catches up.
# 5. Once state catches up (exactly what Update-KICompleteComponentState does after a validated
# run), a fresh plan is a genuine Skip -- the real repeat-run-after-upgrade contract, not a
# FixtureState shortcut that cannot represent stored state at all.
$rootCrFresh=New-KIFixtureTargetRoot
try{
    Set-KICutoverMarker -TargetRoot $rootCrFresh -Version ([string]$cutoverRuntimeComponent.version)
    $planCrFresh=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $rootCrFresh
    $stepCrFresh=@($planCrFresh.steps|Where-Object id -eq 'cutover-runtime')[0]
    $checks.cutoverRuntimeMatchesPinBeforeStateCatchUp=[ordered]@{
        compliant=[bool]$stepCrFresh.initialState.compliant
        reconciliationNeeded=[bool]$stepCrFresh.initialState.reconciliationNeeded
    }
    if($checks.cutoverRuntimeMatchesPinBeforeStateCatchUp.Values-contains$false){$fail.Add('Scenario CutoverRuntimeMatchesPinBeforeStateCatchUp failed: '+($stepCrFresh|ConvertTo-Json -Compress))}

    $pathContext=New-KICompletePathContext -TargetRoot $rootCrFresh -PackageRoot $PackageRoot
    Set-KIComponentStoredState -PathContext $pathContext -ComponentId 'cutover-runtime' -Version ([string]$cutoverRuntimeComponent.version)
    $planCrReconciled=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $rootCrFresh -PathContext $pathContext
    $stepCrReconciled=@($planCrReconciled.steps|Where-Object id -eq 'cutover-runtime')[0]
    $checks.cutoverRuntimeRepeatRunAfterStateCatchUpIsSkip=[ordered]@{
        storedMatchesPin=$stepCrReconciled.initialState.storedVersion-eq[string]$cutoverRuntimeComponent.version
        reconciliationNoLongerNeeded=-not[bool]$stepCrReconciled.initialState.reconciliationNeeded
        plannedModeIsSkip=$stepCrReconciled.plannedMode-eq'Skip'
        statusSkippedAlreadyCompliant=$stepCrReconciled.status-eq'SkippedAlreadyCompliant'
    }
    if($checks.cutoverRuntimeRepeatRunAfterStateCatchUpIsSkip.Values-contains$false){$fail.Add('Scenario CutoverRuntimeRepeatRunAfterStateCatchUpIsSkip failed: '+($stepCrReconciled|ConvertTo-Json -Compress))}
}finally{
    if(Test-Path -LiteralPath $rootCrFresh){Remove-Item -LiteralPath $rootCrFresh -Recurse -Force -ErrorAction SilentlyContinue}
}

# 6. Static contract: the canonical sources (not any dist/_import copy) actually carry the bump,
# and the live-marker/version-file identities the compliance checks rely on are unchanged.
$otModuleSource=Get-Content -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Raw
$cutoverMarkerSource=Get-Content -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $PackageRoot)) 'cutover-runtime/current/Modules/08-Cutover/KIModuleCutover.psm1') -Raw
$openTerminalVersionFile=(Get-Content -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $PackageRoot)) 'open-terminal/current/VERSION') -Raw).Trim()
$cutoverRuntimeVersionFile=(Get-Content -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $PackageRoot)) 'cutover-runtime/current/VERSION') -Raw).Trim()
# The exact marker string advances every time ANY bundled BuilderKernel module (ComfyUI,
# Integration, ...) needs a fresh cutover-runtime dispatch delivered to an existing target, not
# just for the Open Terminal/ComfyUI fix this file was originally written for -- checked against
# the live VERSION file rather than a hardcoded numeral so this does not go stale again.
$checks.canonicalSourcesAndVersionFilesConsistent=[ordered]@{
    cutoverMarkerContainsNewRelease=$cutoverMarkerSource.Contains("release='KI-Stack-Cutover-Execute-v$cutoverRuntimeVersionFile'")
    cutoverMarkerNoLongerContainsOldRelease=-not $cutoverMarkerSource.Contains("release='KI-Stack-Cutover-Execute-v1.6.15'")
    openTerminalVersionFileMatchesPin=$openTerminalVersionFile-eq[string]$openTerminalComponent.version
    cutoverRuntimeVersionFileMatchesPin=$cutoverRuntimeVersionFile-eq[string]$cutoverRuntimeComponent.version
    openTerminalMarkerFieldNameUnchanged=[string]$openTerminalComponent.marker-eq'modules/open-terminal/installation.json'
}
if($checks.canonicalSourcesAndVersionFilesConsistent.Values-contains$false){$fail.Add('Scenario CanonicalSourcesAndVersionFilesConsistent failed: '+($checks.canonicalSourcesAndVersionFilesConsistent|ConvertTo-Json -Compress))}

$result=[pscustomobject]@{passed=($fail.Count-eq0);checks=$checks;failures=@($fail)}
$result|ConvertTo-Json -Depth 10
if(-not$result.passed){exit 1}

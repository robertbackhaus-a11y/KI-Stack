[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force

$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

# Real, explicitly requested verification (2.18.2 base/stabilization closeout): the WSL-Keeper fix
# (Runtime/Start-KIStack-SearXNG.ps1, Runtime/Stop-KIStack-SearXNG.ps1, and the BuilderKernel's own
# copy in Modules/07-Integration/KIModuleIntegration.psm1) is generated/deployed content, exactly
# like the Applications 1.4.11 and Open Terminal/Cutover Runtime 1.6.14 cases already proven this
# same release cycle: a target already at the unbumped pin is planned Skip and never receives the
# fix. This test proves the delivery/reconcile contract for the two components involved:
#   - Integration 1.5.11 -> 1.5.12 (kind='component', its own isolated Install-IntegrationRuntime
#     path -- Runtime/Start-KIStack-SearXNG.ps1 et al. are only redeployed when its own pinned
#     version changes)
#   - Cutover Runtime 1.6.15 -> 1.6.16 (kind='pinned-runtime-reference', part of the shared
#     foundation-runtime/python-git/applications/cutover-runtime BuilderKernel bundle -- the
#     BuilderKernel's own copy of the fix is only redelivered when a full kernel dispatch happens)
# Both use real PathContext/installation.json/components.json fixtures, not FixtureState.

$contract=Get-Content -LiteralPath (Join-Path $PackageRoot 'Contracts/COMPONENTS.json') -Raw|ConvertFrom-Json -Depth 30
$integrationComponent=@($contract.components|Where-Object id -eq 'integration')[0]
$cutoverRuntimeComponent=@($contract.components|Where-Object id -eq 'cutover-runtime')[0]
$checks.pinsAreAtTheExpectedNewPatchVersions=[ordered]@{
    integrationPinned=[string]$integrationComponent.version
    integrationIsAtLeast1512=([version]([string]$integrationComponent.version)) -ge ([version]'1.5.12')
    cutoverRuntimePinned=[string]$cutoverRuntimeComponent.version
    cutoverRuntimeIsAtLeast1616=([version]([string]$cutoverRuntimeComponent.version)) -ge ([version]'1.6.16')
}
if(-not[bool]$checks.pinsAreAtTheExpectedNewPatchVersions.integrationIsAtLeast1512){$fail.Add('Integration pin was not bumped to 1.5.12 or later: '+$checks.pinsAreAtTheExpectedNewPatchVersions.integrationPinned)}
if(-not[bool]$checks.pinsAreAtTheExpectedNewPatchVersions.cutoverRuntimeIsAtLeast1616){$fail.Add('Cutover Runtime pin was not bumped to 1.6.16 or later: '+$checks.pinsAreAtTheExpectedNewPatchVersions.cutoverRuntimePinned)}

function New-KIFixtureTargetRoot {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-IntegrationCutoverPlan-'+[guid]::NewGuid().ToString('N').Substring(0,8))
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
function Set-KIIntegrationFixture {
    param([Parameter(Mandatory)][string]$TargetRoot,[Parameter(Mandatory)][string]$Version)
    $moduleRoot=Join-Path $TargetRoot 'modules/integration'
    New-Item -ItemType Directory -Path $moduleRoot -Force|Out-Null
    $marker=[pscustomobject][ordered]@{schemaVersion='1.0';managedBy='KI-STACK-INTEGRATION-MANAGED';version=$Version;release=('KI-Stack-Integration-Execute-v'+$Version)}
    Set-Content -LiteralPath (Join-Path $moduleRoot 'installation.json') -Encoding utf8 -Value ($marker|ConvertTo-Json)
    foreach($f in @('Start-KIStack-IntegratedStack.cmd','Start-KIStack-OpenWebUI-WithSearch.cmd','Start-KIStack-SearXNG.cmd','Start-KIStack-SearXNG.ps1','Stop-KIStack-IntegratedStack.cmd','Stop-KIStack-SearXNG.cmd','Stop-KIStack-SearXNG.ps1')){
        Set-Content -LiteralPath (Join-Path $moduleRoot $f) -Encoding ascii -Value '@echo off'
    }
}

# =========================== Integration (kind: component) =================================
# 1. Outdated target (marker=1.5.11, everything else present) -> must plan Upgrade, never Skip.
# This does not depend on live WSL/Debian: Test-KICompleteIntegrationCompliant's version check
# fails before it ever reaches its systemd-enablement probe.
$rootIntOutdated=New-KIFixtureTargetRoot
try{
    Set-KIIntegrationFixture -TargetRoot $rootIntOutdated -Version '1.5.11'
    $planIntOutdated=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $rootIntOutdated
    $stepIntOutdated=@($planIntOutdated.steps|Where-Object id -eq 'integration')[0]
    $checks.integrationOutdatedPlansUpgrade=[ordered]@{
        installedReadBack=$stepIntOutdated.initialState.installedVersion-eq'1.5.11'
        notCompliant=-not[bool]$stepIntOutdated.initialState.compliant
        plannedModeIsUpgrade=$stepIntOutdated.plannedMode-eq'Upgrade'
        plannedModeIsNotSkip=$stepIntOutdated.plannedMode-ne'Skip'
    }
    if($checks.integrationOutdatedPlansUpgrade.Values-contains$false){$fail.Add('Scenario IntegrationOutdatedPlansUpgrade failed: '+($stepIntOutdated|ConvertTo-Json -Compress))}
}finally{
    if(Test-Path -LiteralPath $rootIntOutdated){Remove-Item -LiteralPath $rootIntOutdated -Recurse -Force -ErrorAction SilentlyContinue}
}

# 2. Fully up-to-date target (marker=new pin, all required artifacts present) -> genuine Skip.
# Test-KICompleteIntegrationCompliant's last gate is a real 'wsl.exe -d Debian -u root --
# systemctl is-enabled valkey-server nginx uwsgi ki-stack-searxng' probe (diag14): this half of
# the scenario is therefore only exercised for real when this host has a real Debian WSL instance
# with those units enabled, and is reported (not failed) as environment-limited otherwise --
# integration is kind='component', not 'pinned-runtime-reference', so unlike cutover-runtime below
# it is never subject to a separate forcesReconciliationUpgrade state-catch-up requirement.
$rootIntUpToDate=New-KIFixtureTargetRoot
try{
    Set-KIIntegrationFixture -TargetRoot $rootIntUpToDate -Version ([string]$integrationComponent.version)
    $planIntUpToDate=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $rootIntUpToDate
    $stepIntUpToDate=@($planIntUpToDate.steps|Where-Object id -eq 'integration')[0]
    $wslAvailable=$false
    try{
        $wslCmd=Get-Command wsl.exe -ErrorAction SilentlyContinue
        if($wslCmd){
            $core=@(& $wslCmd.Source -d Debian -u root -- systemctl is-enabled valkey-server nginx 2>&1)
            $wslAvailable=(@($core|Where-Object{$_-eq'enabled'}).Count-eq2)
        }
    }catch{}
    if($wslAvailable){
        $checks.integrationUpToDateIsSkip=[ordered]@{
            compliant=[bool]$stepIntUpToDate.initialState.compliant
            plannedModeIsSkip=$stepIntUpToDate.plannedMode-eq'Skip'
            statusSkippedAlreadyCompliant=$stepIntUpToDate.status-eq'SkippedAlreadyCompliant'
        }
        if($checks.integrationUpToDateIsSkip.Values-contains$false){$fail.Add('Scenario IntegrationUpToDateIsSkip failed: '+($stepIntUpToDate|ConvertTo-Json -Compress))}
    } else {
        $checks.integrationUpToDateIsSkip=[ordered]@{skipped=$true;reason='no real Debian WSL instance with valkey-server/nginx enabled on this host'}
        Write-Host 'KI_STACK_INTEGRATION_PLAN_SELFTEST|skipped=IntegrationUpToDateIsSkip (no real Debian WSL with required units enabled on this host)'
    }
}finally{
    if(Test-Path -LiteralPath $rootIntUpToDate){Remove-Item -LiteralPath $rootIntUpToDate -Recurse -Force -ErrorAction SilentlyContinue}
}

# =========================== Cutover Runtime (kind: pinned-runtime-reference) ===============
# 3. Outdated target (live marker still says 1.6.15) -> must plan Upgrade, never Skip -- this is
# what actually re-triggers the whole shared BuilderKernel bundle, which is what redeploys
# 07-Integration's fixed WSL-Keeper content.
$rootCrOutdated=New-KIFixtureTargetRoot
try{
    Set-KICutoverMarker -TargetRoot $rootCrOutdated -Version '1.6.15'
    $planCrOutdated=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $rootCrOutdated
    $stepCrOutdated=@($planCrOutdated.steps|Where-Object id -eq 'cutover-runtime')[0]
    $checks.cutoverRuntimeOutdatedPlansUpgrade=[ordered]@{
        installedReadBack=$stepCrOutdated.initialState.installedVersion-eq'1.6.15'
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

# 4. Installed already matches the new pin (1.6.16) but no recorded/stored state exists yet ->
# compliant=true, but forcesReconciliationUpgrade (pinned-runtime-reference contract, pre-existing
# and unrelated to this fix) still schedules one more real dispatch until state catches up.
# 5. Once state catches up, a fresh plan is a genuine Skip -- the real repeat-run-after-upgrade
# contract, not a FixtureState shortcut that cannot represent stored state at all.
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

# 6. Static contract: the canonical sources (not any dist/_import copy) actually carry the bump.
$cutoverMarkerSource=Get-Content -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $PackageRoot)) 'cutover-runtime/current/Modules/08-Cutover/KIModuleCutover.psm1') -Raw
$integrationModuleSource=Get-Content -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $PackageRoot)) 'cutover-runtime/current/Modules/07-Integration/KIModuleIntegration.psm1') -Raw
$integrationVersionFile=(Get-Content -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $PackageRoot)) 'integration/current/VERSION') -Raw).Trim()
$cutoverRuntimeVersionFile=(Get-Content -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $PackageRoot)) 'cutover-runtime/current/VERSION') -Raw).Trim()
$checks.canonicalSourcesAndVersionFilesConsistent=[ordered]@{
    cutoverMarkerContainsNewRelease=$cutoverMarkerSource.Contains("release='KI-Stack-Cutover-Execute-v$cutoverRuntimeVersionFile'")
    cutoverMarkerNoLongerContainsOldRelease=-not $cutoverMarkerSource.Contains("release='KI-Stack-Cutover-Execute-v1.6.15'")
    integrationModuleKeeperFixStillPresent=$integrationModuleSource.Contains("'-d',`$distribution,'--exec','/bin/sleep','infinity'")
    integrationVersionFileMatchesPin=$integrationVersionFile-eq[string]$integrationComponent.version
    cutoverRuntimeVersionFileMatchesPin=$cutoverRuntimeVersionFile-eq[string]$cutoverRuntimeComponent.version
    integrationMarkerFieldNameUnchanged=[string]$integrationComponent.marker-eq'modules/integration/installation.json'
}
if($checks.canonicalSourcesAndVersionFilesConsistent.Values-contains$false){$fail.Add('Scenario CanonicalSourcesAndVersionFilesConsistent failed: '+($checks.canonicalSourcesAndVersionFilesConsistent|ConvertTo-Json -Compress))}

$result=[pscustomobject]@{passed=($fail.Count-eq0);checks=$checks;failures=@($fail)}
$result|ConvertTo-Json -Depth 10
if(-not$result.passed){exit 1}

[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force

$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

# Real, reproduced defect: bumping the *content* Install-KIModuleApplications generates (the
# OpenWebUI secret-key fix) without also bumping the pinned 'applications' version in
# Contracts/COMPONENTS.json left New-KICompletePlan reporting an existing target (still recording
# the old release marker) as compliant/Skip forever -- the fix never reached any already-installed
# target. This proves the planning half of the fix using a real PathContext against a fixture
# TargetRoot (not FixtureState, which -- for a 'pinned-runtime-reference' kind component like
# 'applications' -- always forces plannedMode=Upgrade regardless of the installed/pin match, since
# it can never carry a stored/recorded state; see New-KICompletePlan's own forcesReconciliationUpgrade
# comment). A real installation.json (installed version) and a real components.json (recorded/
# stored version) are seeded directly so the genuine Skip path is exercised for real.

$contract=Get-Content -LiteralPath (Join-Path $PackageRoot 'Contracts/COMPONENTS.json') -Raw|ConvertFrom-Json -Depth 30
$applicationsComponent=@($contract.components|Where-Object id -eq 'applications')[0]
$checks.pinIsAtLeast1412=[ordered]@{
    pinned=[string]$applicationsComponent.version
    isNewPatch=([version]([string]$applicationsComponent.version)) -ge ([version]'1.4.12')
}
if(-not[bool]$checks.pinIsAtLeast1412.isNewPatch){$fail.Add('Contracts/COMPONENTS.json applications pin was not bumped to 1.4.12 or later: '+$checks.pinIsAtLeast1412.pinned)}

function New-KIFixtureTargetRoot {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-AppsPlan-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    $root
}
function Set-KIApplicationsMarker {
    param([Parameter(Mandatory)][string]$TargetRoot,[Parameter(Mandatory)][string]$Version)
    $markerDir=Join-Path $TargetRoot 'modules/applications'
    New-Item -ItemType Directory -Path $markerDir -Force|Out-Null
    $marker=[pscustomobject][ordered]@{managedBy='KI-STACK-APPLICATIONS-MANAGED';release=('KI-Stack-Applications-Execute-v'+$Version);installedAt=(Get-Date).ToString('o')}
    Set-Content -LiteralPath (Join-Path $markerDir 'installation.json') -Encoding utf8 -Value ($marker|ConvertTo-Json)
}
function Set-KIApplicationsStoredState {
    param([Parameter(Mandatory)][object]$PathContext,[Parameter(Mandatory)][string]$Version)
    $statePath=Get-KICompleteComponentStatePath -PathContext $PathContext
    New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force|Out-Null
    $state=[ordered]@{schemaVersion='1.0';status='ValidatedExistingInstallation';completeInstallerVersion='TEST';validatedAtUtc=(Get-Date).ToString('o');components=[ordered]@{applications=$Version};evidence=[ordered]@{stateReconciledFromRealProbes=$true;containsSecrets=$false}}
    Write-KICompleteJson $statePath $state
}

# 1. Outdated target (installed=1.4.11, no recorded state) -> must plan Upgrade, never Skip.
$rootOutdated=New-KIFixtureTargetRoot
try{
    Set-KIApplicationsMarker -TargetRoot $rootOutdated -Version '1.4.11'
    $planOutdated=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $rootOutdated
    $stepOutdated=@($planOutdated.steps|Where-Object id -eq 'applications')[0]
    $checks.outdatedTargetPlansUpgrade=[ordered]@{
        installedReadBack=$stepOutdated.initialState.installedVersion-eq'1.4.11'
        notCompliant=-not[bool]$stepOutdated.initialState.compliant
        plannedModeIsUpgrade=$stepOutdated.plannedMode-eq'Upgrade'
        plannedModeIsNotSkip=$stepOutdated.plannedMode-ne'Skip'
        statusPlanned=$stepOutdated.status-eq'Planned'
    }
    if($checks.outdatedTargetPlansUpgrade.Values-contains$false){$fail.Add('Scenario OutdatedTargetPlansUpgrade failed: '+($stepOutdated|ConvertTo-Json -Compress))}

    $stepOutdatedRepair=@((New-KICompletePlan -Mode Repair -PackageRoot $PackageRoot -TargetRoot $rootOutdated).steps|Where-Object id -eq 'applications')[0]
    $checks.repairModeAlsoReconciles=[ordered]@{plannedModeNotSkip=$stepOutdatedRepair.plannedMode-ne'Skip'}
    if($checks.repairModeAlsoReconciles.Values-contains$false){$fail.Add('Scenario RepairModeAlsoReconciles failed: '+($stepOutdatedRepair|ConvertTo-Json -Compress))}

    $foundationStep=@($planOutdated.steps|Where-Object id -eq 'foundation-runtime')[0]
    $checks.siblingBundledStepUnaffectedByApplicationsBump=[ordered]@{
        foundationInstalledIsNull=$null-eq$foundationStep.initialState.installedVersion
    }
    if($checks.siblingBundledStepUnaffectedByApplicationsBump.Values-contains$false){$fail.Add('Scenario SiblingBundledStepUnaffected failed: '+($foundationStep|ConvertTo-Json -Compress))}
}finally{
    if(Test-Path -LiteralPath $rootOutdated){Remove-Item -LiteralPath $rootOutdated -Recurse -Force -ErrorAction SilentlyContinue}
}

# 2. Installed already matches the new pin (1.4.12) but no recorded/stored state exists yet (the
# real-world state immediately after Install-KIModuleApplications has just run for the very first
# time at this version) -> compliant=true (installed matches pin), but the existing
# forcesReconciliationUpgrade contract for pinned-runtime-reference components still schedules one
# more real dispatch until the stored state catches up -- this is pre-existing, documented behavior
# for all four bundled components, not something this fix changes or should suppress.
$rootFreshlyUpgraded=New-KIFixtureTargetRoot
try{
    Set-KIApplicationsMarker -TargetRoot $rootFreshlyUpgraded -Version ([string]$applicationsComponent.version)
    $planFresh=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $rootFreshlyUpgraded
    $stepFresh=@($planFresh.steps|Where-Object id -eq 'applications')[0]
    $checks.installedMatchesPinBeforeStateCatchUp=[ordered]@{
        compliant=[bool]$stepFresh.initialState.compliant
        reconciliationNeeded=[bool]$stepFresh.initialState.reconciliationNeeded
    }
    if($checks.installedMatchesPinBeforeStateCatchUp.Values-contains$false){$fail.Add('Scenario InstalledMatchesPinBeforeStateCatchUp failed: '+($stepFresh|ConvertTo-Json -Compress))}

    # 3. Once the recorded/stored state also catches up to the new pin (exactly what
    # Update-KICompleteComponentState does after a validated run), a fresh plan must finally be a
    # genuine Skip -- proving the repeat-run-after-upgrade contract for real, not just via a
    # FixtureState shortcut that cannot represent stored state at all.
    $pathContext=New-KICompletePathContext -TargetRoot $rootFreshlyUpgraded -PackageRoot $PackageRoot
    Set-KIApplicationsStoredState -PathContext $pathContext -Version ([string]$applicationsComponent.version)
    $planReconciled=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $rootFreshlyUpgraded -PathContext $pathContext
    $stepReconciled=@($planReconciled.steps|Where-Object id -eq 'applications')[0]
    $checks.repeatRunAfterStateCatchUpIsSkip=[ordered]@{
        storedMatchesPin=$stepReconciled.initialState.storedVersion-eq[string]$applicationsComponent.version
        reconciliationNoLongerNeeded=-not[bool]$stepReconciled.initialState.reconciliationNeeded
        plannedModeIsSkip=$stepReconciled.plannedMode-eq'Skip'
        statusSkippedAlreadyCompliant=$stepReconciled.status-eq'SkippedAlreadyCompliant'
    }
    if($checks.repeatRunAfterStateCatchUpIsSkip.Values-contains$false){$fail.Add('Scenario RepeatRunAfterStateCatchUpIsSkip failed: '+($stepReconciled|ConvertTo-Json -Compress))}
}finally{
    if(Test-Path -LiteralPath $rootFreshlyUpgraded){Remove-Item -LiteralPath $rootFreshlyUpgraded -Recurse -Force -ErrorAction SilentlyContinue}
}

# 4. Static contract: the canonical module source (not any dist/_import copy) is what was actually
# bumped, and the marker field name New-KICompletePlan/Get-KICompleteInstalledVersion rely on is
# unchanged.
$applicationsModuleSourcePath=Join-Path (Split-Path -Parent (Split-Path -Parent $PackageRoot)) 'cutover-runtime/current/Modules/06-Applications/KIModuleApplications.psm1'
$applicationsModuleSource=Get-Content -LiteralPath $applicationsModuleSourcePath -Raw
$applicationsModuleManifest=Get-Content -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $PackageRoot)) 'cutover-runtime/current/Modules/06-Applications/module.json') -Raw|ConvertFrom-Json -Depth 10
$checks.canonicalModuleSourceBumped=[ordered]@{
    containsNewRelease=$applicationsModuleSource.Contains("release = 'KI-Stack-Applications-Execute-v1.4.12'")
    noLongerContainsOldRelease=-not $applicationsModuleSource.Contains("release = 'KI-Stack-Applications-Execute-v1.4.11'")
    moduleJsonVersionMatchesPin=[string]$applicationsModuleManifest.version-eq[string]$applicationsComponent.version
    markerFieldNameUnchanged=[string]$applicationsComponent.marker-eq'modules/applications/installation.json'
}
if($checks.canonicalModuleSourceBumped.Values-contains$false){$fail.Add('Scenario CanonicalModuleSourceBumped failed: '+($checks.canonicalModuleSourceBumped|ConvertTo-Json -Compress))}

$result=[pscustomobject]@{passed=($fail.Count-eq0);checks=$checks;failures=@($fail)}
$result|ConvertTo-Json -Depth 10
if(-not$result.passed){exit 1}

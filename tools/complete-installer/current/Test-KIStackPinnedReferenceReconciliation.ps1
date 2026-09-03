[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force

# Exercises the real (non-FixtureState) Get-KICompleteInstalledVersion path for
# pinned-runtime-reference/recovery-reference components -- -FixtureState would bypass the very
# $acceptedVersions fallback under test, so this builds a real, minimal fixture target instead.
function New-KIPinnedReferenceFixture {
    param(
        [Parameter(Mandatory)][string]$FixtureRoot,
        [Parameter(Mandatory)][string]$CutoverStoredVersion,
        [Parameter(Mandatory)][string]$ProductionRecoveryStoredVersion,
        [Parameter(Mandatory)][string]$ProbeComponentStoredVersion,
        [Parameter(Mandatory)][string]$ProbeComponentInstalledVersion
    )
    $installerRoot=Join-Path $FixtureRoot 'installer/complete'
    New-Item -ItemType Directory -Path (Join-Path $installerRoot 'Contracts') -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Destination $installerRoot -Force
    New-Item -ItemType Directory -Path (Join-Path $installerRoot 'Runtime') -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'Runtime/KIStackPathContext.psm1') -Destination (Join-Path $installerRoot 'Runtime') -Force

    # Minimal fixture contract: one pinned-runtime-reference and one recovery-reference component,
    # each pinned at the exact version the real, hardcoded $acceptedVersions snapshot in
    # CompleteInstaller.psm1 already carries for that id -- so "compliant" is reached the same way
    # a real target reaches it, without touching that snapshot itself -- plus one ordinary,
    # probe-based component (a deliberately generic id -- not 'comfyui'/'codex-local'/'integration'
    # etc., none of which are neutral anymore since they each gained their own real, additional
    # compliance hook in New-KICompletePlan) to prove existing behavior is unaffected.
    $components=[ordered]@{schemaVersion='1.0';components=@(
        [ordered]@{id='cutover-runtime';name='Cutover Runtime';version='1.6.10';order=10;source='Payload/CutoverRuntime';kind='pinned-runtime-reference';installable=$false}
        [ordered]@{id='production-recovery';name='Production Recovery';version='1.7.0-r7';order=20;source='Payload/ProductionRecovery';kind='recovery-reference';installable=$false}
        [ordered]@{id='generic-probe-component';name='Generic Probe Component';version='1.2.4';order=30;source='Payload/GenericProbeComponent';probe=[ordered]@{type='text';path='modules/generic-probe-component/VERSION'};kind='component';installable=$true}
    )}
    Set-Content -LiteralPath (Join-Path $installerRoot 'Contracts/COMPONENTS.json') -Value ($components|ConvertTo-Json -Depth 20) -Encoding UTF8

    # Activates the real $acceptedVersions fallback for the two non-installable components.
    New-Item -ItemType Directory -Path (Join-Path $FixtureRoot 'modules/production-recovery') -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $FixtureRoot 'modules/production-recovery/acceptance.json') -Value '{"passed":true,"recoveryRevision":"r7"}' -Encoding UTF8

    # The generic component's own real, independent probe file -- genuinely verified, not snapshot-derived.
    New-Item -ItemType Directory -Path (Join-Path $FixtureRoot 'modules/generic-probe-component') -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $FixtureRoot 'modules/generic-probe-component/VERSION') -Value $ProbeComponentInstalledVersion -Encoding UTF8

    # Stale state-tracking file: simulates "the pin already matches the accepted snapshot (or the
    # real probe), but components.json was recorded before that became true" for all three ids.
    New-Item -ItemType Directory -Path (Join-Path $FixtureRoot 'state/complete-installer') -Force|Out-Null
    $state=[ordered]@{components=[ordered]@{'cutover-runtime'=$CutoverStoredVersion;'production-recovery'=$ProductionRecoveryStoredVersion;'generic-probe-component'=$ProbeComponentStoredVersion}}
    Set-Content -LiteralPath (Join-Path $FixtureRoot 'state/complete-installer/components.json') -Value ($state|ConvertTo-Json -Depth 10) -Encoding UTF8

    [pscustomobject]@{installerRoot=$installerRoot;targetRoot=$FixtureRoot}
}

$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}
$fixtureRootBase=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-PinnedRefRecon-'+[guid]::NewGuid().ToString('N'))

try{
    New-Item -ItemType Directory -Path $fixtureRootBase -Force|Out-Null

    # 1. pinned-runtime-reference (cutover-runtime): accepted snapshot (1.6.10) already matches the
    #    pin, but the recorded state (1.6.9) does not -> reconciliationNeeded=true must now force
    #    plannedMode='Upgrade' (and a consistent, non-"SkippedAlreadyCompliant" status) instead of
    #    the vacuous Skip the old code produced.
    $fx1=New-KIPinnedReferenceFixture -FixtureRoot (Join-Path $fixtureRootBase 'pinnedref') -CutoverStoredVersion '1.6.9' -ProductionRecoveryStoredVersion '1.7.0-r7' -ProbeComponentStoredVersion '1.2.4' -ProbeComponentInstalledVersion '1.2.4'
    $plan1=New-KICompletePlan -Mode Upgrade -PackageRoot $fx1.installerRoot -TargetRoot $fx1.targetRoot
    $cutoverStep1=@($plan1.steps|Where-Object id -eq 'cutover-runtime')[0]
    $checks.pinnedRuntimeReferenceForcesUpgrade=[ordered]@{
        compliant=[bool]$cutoverStep1.initialState.compliant
        reconciliationNeeded=[bool]$cutoverStep1.initialState.reconciliationNeeded
        plannedModeUpgrade=$cutoverStep1.plannedMode-eq'Upgrade'
        statusPlanned=$cutoverStep1.status-eq'Planned'
    }
    if($checks.pinnedRuntimeReferenceForcesUpgrade.Values-contains$false){$fail.Add('Scenario PinnedRuntimeReferenceForcesUpgrade failed: '+($cutoverStep1|ConvertTo-Json -Compress))}

    # 2. recovery-reference (production-recovery): identical shape, same fix must apply.
    $fx2=New-KIPinnedReferenceFixture -FixtureRoot (Join-Path $fixtureRootBase 'recoveryref') -CutoverStoredVersion '1.6.10' -ProductionRecoveryStoredVersion '1.7.0-r6' -ProbeComponentStoredVersion '1.2.4' -ProbeComponentInstalledVersion '1.2.4'
    $plan2=New-KICompletePlan -Mode Upgrade -PackageRoot $fx2.installerRoot -TargetRoot $fx2.targetRoot
    $recoveryStep2=@($plan2.steps|Where-Object id -eq 'production-recovery')[0]
    $checks.recoveryReferenceForcesUpgrade=[ordered]@{
        compliant=[bool]$recoveryStep2.initialState.compliant
        reconciliationNeeded=[bool]$recoveryStep2.initialState.reconciliationNeeded
        plannedModeUpgrade=$recoveryStep2.plannedMode-eq'Upgrade'
        statusPlanned=$recoveryStep2.status-eq'Planned'
    }
    if($checks.recoveryReferenceForcesUpgrade.Values-contains$false){$fail.Add('Scenario RecoveryReferenceForcesUpgrade failed: '+($recoveryStep2|ConvertTo-Json -Compress))}

    # 3. Probe-based component (generic-probe-component): really, independently verified as
    #    compliant (real VERSION file matches the pin) but components.json is stale -> existing
    #    Skip + state-catch-up behavior must be completely unaffected by this fix.
    $fx3=New-KIPinnedReferenceFixture -FixtureRoot (Join-Path $fixtureRootBase 'probebased') -CutoverStoredVersion '1.6.10' -ProductionRecoveryStoredVersion '1.7.0-r7' -ProbeComponentStoredVersion '1.2.3' -ProbeComponentInstalledVersion '1.2.4'
    $plan3=New-KICompletePlan -Mode Upgrade -PackageRoot $fx3.installerRoot -TargetRoot $fx3.targetRoot
    $comfyStep3=@($plan3.steps|Where-Object id -eq 'generic-probe-component')[0]
    $checks.probeBasedComponentSkipUnaffected=[ordered]@{
        compliant=[bool]$comfyStep3.initialState.compliant
        reconciliationNeeded=[bool]$comfyStep3.initialState.reconciliationNeeded
        plannedModeSkip=$comfyStep3.plannedMode-eq'Skip'
        statusSkippedAlreadyCompliant=$comfyStep3.status-eq'SkippedAlreadyCompliant'
    }
    if($checks.probeBasedComponentSkipUnaffected.Values-contains$false){$fail.Add('Scenario ProbeBasedComponentSkipUnaffected failed: '+($comfyStep3|ConvertTo-Json -Compress))}

    # 4. Negative control: pinned-runtime-reference with matching stored version (no drift at all)
    #    must still resolve to plain Skip -- the fix must only fire when reconciliation is genuinely
    #    needed, not unconditionally for this component class.
    $fx4=New-KIPinnedReferenceFixture -FixtureRoot (Join-Path $fixtureRootBase 'nodrift') -CutoverStoredVersion '1.6.10' -ProductionRecoveryStoredVersion '1.7.0-r7' -ProbeComponentStoredVersion '1.2.4' -ProbeComponentInstalledVersion '1.2.4'
    $plan4=New-KICompletePlan -Mode Upgrade -PackageRoot $fx4.installerRoot -TargetRoot $fx4.targetRoot
    $cutoverStep4=@($plan4.steps|Where-Object id -eq 'cutover-runtime')[0]
    $checks.noDriftStillSkip=[ordered]@{
        reconciliationNeededFalse=-not[bool]$cutoverStep4.initialState.reconciliationNeeded
        plannedModeSkip=$cutoverStep4.plannedMode-eq'Skip'
        statusSkippedAlreadyCompliant=$cutoverStep4.status-eq'SkippedAlreadyCompliant'
    }
    if($checks.noDriftStillSkip.Values-contains$false){$fail.Add('Scenario NoDriftStillSkip failed: '+($cutoverStep4|ConvertTo-Json -Compress))}
}
finally{if(Test-Path $fixtureRootBase){Remove-Item -LiteralPath $fixtureRootBase -Recurse -Force -ErrorAction SilentlyContinue}}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'Pinned-Reference-Reconciliation-Regression fehlgeschlagen.'}

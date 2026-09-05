[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# SEEDED RESUME/REPAIR/ROLLBACK TEST -- explicitly NOT a full, real primary Complete-Installer
# run. A genuine `Invoke-KIStackCompleteInstaller -Mode Install/Upgrade/Repair` against ANY
# target (scratch or production) always plans 'cutover-runtime' (order 70, before open-terminal
# at 160 and mcp-runtime at 170) as needing reconciliation -- Get-KICompleteInstalledVersion's
# frozen acceptedVersions map pins it at '1.6.10' forever, by deliberate design (see that
# function's own comment: bumping it to match a newer pin previously caused a real, silent
# reconciliation-skip bug), while Contracts/COMPONENTS.json's real pin is '1.6.14'. Confirmed
# empirically against the REAL production target (2026-09-05, read-only Audit): 'cutover-runtime'
# shows installedVersion=1.6.10, compliant=false there too, exactly like a fresh scratch target.
# This forces the elevation-gated Invoke-KIStackBuilderKernel.ps1 child process to run on EVERY
# real Install/Upgrade/Repair call, regardless of TargetRoot or of anything mcp-runtime-specific.
# This session has no real elevation (two independent elevation attempts failed) and per explicit
# instruction, neither the admin-detection code nor the frozen acceptance map may be altered or
# bypassed to route around this.
#
# This script therefore drives the SAME building-block functions the primary step loop's own
# 'mcp-runtime' (and, for direct comparison, 'open-terminal') branches call --
# New-KICompletePlan, New-KICompletePathContext, Test-KICompleteMcpRuntimeCompliant,
# Expand-KICompletePayload, Invoke-KICompleteJsonScript -- in the exact same shape and sequence
# CompleteInstaller.psm1's own branch bodies use, continuing the flow exactly where a real run
# would be if it had gotten past cutover-runtime. It never calls Invoke-KIStackCompleteInstaller
# itself, never touches Test-KICompleteAdministrator, and never edits the acceptance map.
#
# Requires a real, already-built Payload/McpRuntime/*.zip and Payload/OpenTerminal/*.zip
# (Expand-KICompletePayload) -- like Test-KIStackOpenTerminalCompleteInstallerIntegration.ps1
# before it, this is therefore deliberately NOT part of scripts/Test-Repository.ps1's standard,
# no-build-artifacts-assumed suite. Confirmed the hard way: leaving a real Payload/ tree in
# place after building it for this test also let Test-KIStackUpdateIsolation.ps1's own drift
# check (which merely expects "Payload fehlt" as a fast, safe, expected outcome when no real
# package exists) actually attempt a real mcp-runtime install instead, which made a real,
# unbounded external network call and hung for 10+ minutes -- always remove Payload/ again after
# using it, never leave it in the working tree.

Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force

$fail = [Collections.Generic.List[string]]::new()
$checks = [ordered]@{}
$scratchBase = Join-Path ([IO.Path]::GetTempPath()) ('KIMR-SeededFlow-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $scratchBase -Force | Out-Null

function Invoke-KISeededMcpRuntimeStep {
    # Manually replicates CompleteInstaller.psm1's own `elseif ($step.id -eq 'mcp-runtime')` branch
    # body verbatim (same PathContext.PayloadRoot convention, same entry point, same Validate-
    # then-rollback-on-failure shape) -- never a parallel reimplementation.
    param([Parameter(Mandatory)][string]$TargetRoot,[Parameter(Mandatory)][object]$PathContext,[Parameter(Mandatory)][string]$PlannedMode)
    $extract = Join-Path ([string]$PathContext.PayloadRoot) 'McpRuntime'
    $componentRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'McpRuntime' -Destination $extract
    $entry = Join-Path $componentRoot 'Invoke-KIStackMcpRuntime.ps1'
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw 'MCP-Runtime-Einstieg fehlt.' }
    $action = if ($PlannedMode -eq 'Repair') { 'Repair' } elseif ($PlannedMode -eq 'Upgrade') { 'Upgrade' } else { 'Install' }
    $result = $null
    try {
        $result = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = $action; TargetRoot = $TargetRoot }
        if (-not [bool]$result.passed) { throw "MCP-Runtime-$action fehlgeschlagen." }
        $validation = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Validate'; TargetRoot = $TargetRoot }
        if (-not [bool]$validation.passed) { throw 'MCP-Runtime-Validierung fehlgeschlagen.' }
        [pscustomobject]@{ passed = $true; action = $action; install = $result; validation = $validation }
    } catch {
        $rollbackOutcome = $null
        if ($null -ne $result -and $result.PSObject.Properties['backupPath'] -and -not [string]::IsNullOrWhiteSpace([string]$result.backupPath)) {
            $rollback = Invoke-KICompleteJsonScript -Script $entry -Arguments @{ Action = 'Rollback'; TargetRoot = $TargetRoot; BackupPath = [string]$result.backupPath }
            $_.Exception.Data['KIStackRollbackStatus'] = if ([bool]$rollback.passed) { 'Completed' } else { 'Failed' }
            $_.Exception.Data['KIStackBackupPath'] = [string]$result.backupPath
            $rollbackOutcome = $rollback
        }
        [pscustomobject]@{ passed = $false; action = $action; error = $_.Exception.Message; rollback = $rollbackOutcome; rollbackStatus = $_.Exception.Data['KIStackRollbackStatus'] }
    }
}

try {
    # === Schritt 3/7 (Plan-Erzeugung, real) ==================================================
    $t1 = Join-Path $scratchBase 'target-plan'
    New-Item -ItemType Directory -Path $t1 -Force | Out-Null
    $plan1 = New-KICompletePlan -Mode Install -PackageRoot $PackageRoot -TargetRoot $t1
    $otPlan1 = @($plan1.steps | Where-Object id -eq 'open-terminal')
    $mcpPlan1 = @($plan1.steps | Where-Object id -eq 'mcp-runtime')
    $checks.freshPlanContainsBothSteps = [ordered]@{
        openTerminalPresent = ($otPlan1.Count -eq 1)
        openTerminalPlannedInstall = ($otPlan1[0].plannedMode -eq 'Install')
        mcpRuntimePresent = ($mcpPlan1.Count -eq 1)
        mcpRuntimePlannedInstall = ($mcpPlan1[0].plannedMode -eq 'Install')
    }
    if ($checks.freshPlanContainsBothSteps.Values -contains $false) { $fail.Add('freshPlanContainsBothSteps failed: ' + ($checks.freshPlanContainsBothSteps | ConvertTo-Json -Compress)) }

    # === Seeded Install (Schritt 7D-Fortsetzung, direkt bei mcp-runtime) =====================
    $t2 = Join-Path $scratchBase 'target-seeded'
    New-Item -ItemType Directory -Path $t2 -Force | Out-Null
    $pathContext2 = New-KICompletePathContext -TargetRoot $t2 -PackageRoot $PackageRoot -Mutating -TransactionId ('KI-SEEDED-' + [guid]::NewGuid().ToString('N').Substring(0,12))
    $mcpInstall = Invoke-KISeededMcpRuntimeStep -TargetRoot $t2 -PathContext $pathContext2 -PlannedMode 'Install'
    $checks.seededInstallSucceeds = [ordered]@{
        passed = [bool]$mcpInstall.passed
        actionWasInstall = ($mcpInstall.action -eq 'Install')
        hasBackupPath = (-not [string]::IsNullOrWhiteSpace([string]$mcpInstall.install.backupPath))
    }
    if ($checks.seededInstallSucceeds.Values -contains $false) { $fail.Add('seededInstallSucceeds failed: ' + ($checks.seededInstallSucceeds | ConvertTo-Json -Compress)) }

    # Open Terminal alongside, same target, same PathContext -- proves no interference between
    # the two primary-loop branches sharing one transaction/PathContext.
    $extractOt = Join-Path ([string]$pathContext2.PayloadRoot) 'OpenTerminal'
    $otRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'OpenTerminal' -Destination $extractOt
    $otEntry = Join-Path $otRoot 'Invoke-KIStackOpenTerminal.ps1'
    $otInstall = Invoke-KICompleteJsonScript -Script $otEntry -Arguments @{ Action = 'Install'; TargetRoot = $t2; SkipUvCheck = $true }
    $checks.openTerminalAlongsideMcpRuntimeNoInterference = [ordered]@{
        openTerminalInstallPassed = [bool]$otInstall.passed
        mcpRuntimeStillCompliant = (Test-KICompleteMcpRuntimeCompliant -TargetRoot $t2 -ExpectedComponentVersion ([string]$mcpPlan1[0].version))
    }
    if ($checks.openTerminalAlongsideMcpRuntimeNoInterference.Values -contains $false) { $fail.Add('openTerminalAlongsideMcpRuntimeNoInterference failed: ' + ($checks.openTerminalAlongsideMcpRuntimeNoInterference | ConvertTo-Json -Compress)) }

    # === Schritt 8: Resume-Recheck-Logik (real, isoliert auf Funktionsebene) ==================
    $mcpVersion = [string]$mcpPlan1[0].version
    $componentContract = Read-KICompleteJson (Join-Path $PackageRoot 'Contracts/COMPONENTS.json')
    $mcpComponent = @($componentContract.components | Where-Object id -eq 'mcp-runtime')[0]

    # Compliant case: the exact expression the resume-recheck block evaluates for 'mcp-runtime'.
    $resumeActualCompliant = Get-KICompleteInstalledVersion -Component $mcpComponent -TargetRoot $t2
    $resumeCompliantCompliant = ($resumeActualCompliant -eq $mcpVersion) -and (Test-KICompleteMcpRuntimeCompliant -TargetRoot $t2 -ExpectedComponentVersion $mcpVersion)
    $checks.resumeRecheckCompliantCaseSkips = [ordered]@{ resumeCompliant = [bool]$resumeCompliantCompliant }
    if (-not $resumeCompliantCompliant) { $fail.Add('resumeRecheckCompliantCaseSkips failed') }

    # Re-running New-KICompletePlan against the now-installed target must report Skip, not Install.
    $planAfterInstall = New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $t2
    $mcpStepAfterInstall = @($planAfterInstall.steps | Where-Object id -eq 'mcp-runtime')[0]
    $checks.planAfterInstallShowsSkip = [ordered]@{
        plannedModeIsSkip = ($mcpStepAfterInstall.plannedMode -eq 'Skip')
        compliant = [bool]$mcpStepAfterInstall.initialState.compliant
    }
    if ($checks.planAfterInstallShowsSkip.Values -contains $false) { $fail.Add('planAfterInstallShowsSkip failed: ' + ($checks.planAfterInstallShowsSkip | ConvertTo-Json -Compress)) }

    # Non-compliant case: break the starter file (a real artifact Test-KIMcpRuntime/
    # Test-KICompleteMcpRuntimeCompliant both check), matching the resume-recheck's own
    # "must be re-planned, not silently skipped" contract.
    $mcpPaths = @{ starter = Join-Path $t2 'modules/mcp-runtime/Start-KIStack-McpRuntime.cmd' }
    Remove-Item -LiteralPath $mcpPaths.starter -Force
    $resumeActualBroken = Get-KICompleteInstalledVersion -Component $mcpComponent -TargetRoot $t2
    $resumeCompliantBroken = ($resumeActualBroken -eq $mcpVersion) -and (Test-KICompleteMcpRuntimeCompliant -TargetRoot $t2 -ExpectedComponentVersion $mcpVersion)
    $checks.resumeRecheckBrokenCaseForcesReplan = [ordered]@{ notCompliant = (-not $resumeCompliantBroken) }
    if ($resumeCompliantBroken) { $fail.Add('resumeRecheckBrokenCaseForcesReplan failed: broken starter still reported compliant') }

    $planAfterBreak = New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $t2
    $mcpStepAfterBreak = @($planAfterBreak.steps | Where-Object id -eq 'mcp-runtime')[0]
    $checks.planAfterBreakReplans = [ordered]@{
        notSkip = ($mcpStepAfterBreak.plannedMode -ne 'Skip')
        notCompliant = (-not [bool]$mcpStepAfterBreak.initialState.compliant)
    }
    if ($checks.planAfterBreakReplans.Values -contains $false) { $fail.Add('planAfterBreakReplans failed: ' + ($checks.planAfterBreakReplans | ConvertTo-Json -Compress)) }

    # === Schritt 9: Repair (real, ueber denselben primaeren Branch-Code) ======================
    $mcpRepair = Invoke-KISeededMcpRuntimeStep -TargetRoot $t2 -PathContext $pathContext2 -PlannedMode $mcpStepAfterBreak.plannedMode
    $checks.repairRestoresCompliance = [ordered]@{
        repairPassed = [bool]$mcpRepair.passed
        starterRestored = (Test-Path -LiteralPath $mcpPaths.starter -PathType Leaf)
        nowCompliant = (Test-KICompleteMcpRuntimeCompliant -TargetRoot $t2 -ExpectedComponentVersion $mcpVersion)
        openTerminalUnaffected = (Test-KICompleteOpenTerminalCompliant -TargetRoot $t2 -ExpectedComponentVersion ([string]$otPlan1[0].version))
    }
    if ($checks.repairRestoresCompliance.Values -contains $false) { $fail.Add('repairRestoresCompliance failed: ' + ($checks.repairRestoresCompliance | ConvertTo-Json -Compress)) }

    # Second, distinct Repair shape: marker entirely absent but a stored state file remembers the
    # component (New-KICompletePlan's own 'Repair' plannedMode, distinct from the Upgrade/self-
    # healing path just exercised above).
    $t3 = Join-Path $scratchBase 'target-repair-planned'
    New-Item -ItemType Directory -Path $t3 -Force | Out-Null
    $pathContext3 = New-KICompletePathContext -TargetRoot $t3 -PackageRoot $PackageRoot -Mutating -TransactionId ('KI-SEEDED-' + [guid]::NewGuid().ToString('N').Substring(0,12))
    Invoke-KISeededMcpRuntimeStep -TargetRoot $t3 -PathContext $pathContext3 -PlannedMode 'Install' | Out-Null
    $stateStatePath = Get-KICompleteComponentStatePath -PathContext $pathContext3
    Write-KICompleteJson $stateStatePath ([ordered]@{ schemaVersion = '1.0'; status = 'ValidatedExistingInstallation'; completeInstallerVersion = '2.15.0'; validatedAtUtc = [DateTime]::UtcNow.ToString('o'); components = [ordered]@{ 'mcp-runtime' = $mcpVersion }; evidence = [ordered]@{ containsSecrets = $false } })
    Remove-Item -LiteralPath (Join-Path $t3 'modules/mcp-runtime/installation.json') -Force
    $planRepair = New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $t3 -PathContext $pathContext3
    $mcpStepRepairPlanned = @($planRepair.steps | Where-Object id -eq 'mcp-runtime')[0]
    $checks.plannedRepairModeWhenMarkerMissingButStored = [ordered]@{
        plannedModeIsRepair = ($mcpStepRepairPlanned.plannedMode -eq 'Repair')
        installedIsNull = ($null -eq $mcpStepRepairPlanned.initialState.installedVersion)
    }
    if ($checks.plannedRepairModeWhenMarkerMissingButStored.Values -contains $false) { $fail.Add('plannedRepairModeWhenMarkerMissingButStored failed: ' + ($checks.plannedRepairModeWhenMarkerMissingButStored | ConvertTo-Json -Compress)) }
    $mcpRepair2 = Invoke-KISeededMcpRuntimeStep -TargetRoot $t3 -PathContext $pathContext3 -PlannedMode $mcpStepRepairPlanned.plannedMode
    $checks.plannedRepairExecutesSuccessfully = [ordered]@{ passed = [bool]$mcpRepair2.passed; nowCompliant = (Test-KICompleteMcpRuntimeCompliant -TargetRoot $t3 -ExpectedComponentVersion $mcpVersion) }
    if ($checks.plannedRepairExecutesSuccessfully.Values -contains $false) { $fail.Add('plannedRepairExecutesSuccessfully failed: ' + ($checks.plannedRepairExecutesSuccessfully | ConvertTo-Json -Compress)) }

    # === Schritt 11: Failure Injection + Rollback (real, ueber denselben primaeren Branch-Code) ==
    $t4 = Join-Path $scratchBase 'target-failure-injection'
    New-Item -ItemType Directory -Path $t4 -Force | Out-Null
    $pathContext4 = New-KICompletePathContext -TargetRoot $t4 -PackageRoot $PackageRoot -Mutating -TransactionId ('KI-SEEDED-' + [guid]::NewGuid().ToString('N').Substring(0,12))
    $workspaceBlockPath = Join-Path $t4 'state/mcp-runtime/workspace'
    New-Item -ItemType Directory -Path (Split-Path -Parent $workspaceBlockPath) -Force | Out-Null
    Set-Content -LiteralPath $workspaceBlockPath -Value 'blocking file, not a directory' -Encoding utf8
    $mcpFailureResult = Invoke-KISeededMcpRuntimeStep -TargetRoot $t4 -PathContext $pathContext4 -PlannedMode 'Install'
    $checks.failureInjectionFailsCleanlyWithNoOrphans = [ordered]@{
        reportedFailed = (-not [bool]$mcpFailureResult.passed)
        noMarkerWritten = (-not (Test-Path -LiteralPath (Join-Path $t4 'modules/mcp-runtime/installation.json') -PathType Leaf))
        noStarterWritten = (-not (Test-Path -LiteralPath (Join-Path $t4 'modules/mcp-runtime/Start-KIStack-McpRuntime.cmd') -PathType Leaf))
        blockingFileUntouched = ((Get-Item -LiteralPath $workspaceBlockPath).PSIsContainer -eq $false)
    }
    if ($checks.failureInjectionFailsCleanlyWithNoOrphans.Values -contains $false) { $fail.Add('failureInjectionFailsCleanlyWithNoOrphans failed: ' + ($checks.failureInjectionFailsCleanlyWithNoOrphans | ConvertTo-Json -Compress)) }
    # No mcp-runtime process can exist in this scenario (Install never starts a process), so
    # "kein Waisenprozess" is trivially true here -- verified structurally instead: no pid file.
    $checks.noOrphanProcessArtifact = [ordered]@{ noPidFile = (-not (Test-Path -LiteralPath (Join-Path $t4 'state/mcp-runtime/mcp-runtime.pid') -PathType Leaf)) }
    if ($checks.noOrphanProcessArtifact.Values -contains $false) { $fail.Add('noOrphanProcessArtifact failed') }

    # === Schritt 10: Upgrade-Szenario (Plan-Ebene, real; End-to-End vor MCP-Step blockiert) =====
    $t5 = Join-Path $scratchBase 'target-upgrade-scenario'
    New-Item -ItemType Directory -Path $t5 -Force | Out-Null
    $pathContext5 = New-KICompletePathContext -TargetRoot $t5 -PackageRoot $PackageRoot -Mutating -TransactionId ('KI-SEEDED-' + [guid]::NewGuid().ToString('N').Substring(0,12))
    $extractOt5 = Join-Path ([string]$pathContext5.PayloadRoot) 'OpenTerminal'
    $otRoot5 = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'OpenTerminal' -Destination $extractOt5
    Invoke-KICompleteJsonScript -Script (Join-Path $otRoot5 'Invoke-KIStackOpenTerminal.ps1') -Arguments @{ Action = 'Install'; TargetRoot = $t5; SkipUvCheck = $true } | Out-Null
    # mcp-runtime deliberately left absent -- exactly the 2.15 upgrade scenario: an existing
    # target that already has Open Terminal but never had mcp-runtime.
    $upgradePlan = New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot $t5 -PathContext $pathContext5
    $otUpgradeStep = @($upgradePlan.steps | Where-Object id -eq 'open-terminal')[0]
    $mcpUpgradeStep = @($upgradePlan.steps | Where-Object id -eq 'mcp-runtime')[0]
    $checks.upgradeScenarioPlanMatchesExpectation = [ordered]@{
        openTerminalAlreadyCompliant = ($otUpgradeStep.plannedMode -eq 'Skip' -and [bool]$otUpgradeStep.initialState.compliant)
        mcpRuntimeNeedsInstall = ($mcpUpgradeStep.plannedMode -eq 'Install')
    }
    if ($checks.upgradeScenarioPlanMatchesExpectation.Values -contains $false) { $fail.Add('upgradeScenarioPlanMatchesExpectation failed: ' + ($checks.upgradeScenarioPlanMatchesExpectation | ConvertTo-Json -Compress)) }
    $mcpUpgradeExecute = Invoke-KISeededMcpRuntimeStep -TargetRoot $t5 -PathContext $pathContext5 -PlannedMode $mcpUpgradeStep.plannedMode
    $checks.upgradeScenarioMcpProvisionedOpenTerminalUntouched = [ordered]@{
        mcpInstalled = [bool]$mcpUpgradeExecute.passed
        openTerminalStillCompliant = (Test-KICompleteOpenTerminalCompliant -TargetRoot $t5 -ExpectedComponentVersion ([string]$otUpgradeStep.version))
    }
    if ($checks.upgradeScenarioMcpProvisionedOpenTerminalUntouched.Values -contains $false) { $fail.Add('upgradeScenarioMcpProvisionedOpenTerminalUntouched failed: ' + ($checks.upgradeScenarioMcpProvisionedOpenTerminalUntouched | ConvertTo-Json -Compress)) }

    $passed = $fail.Count -eq 0
    [pscustomobject]@{
        passed = $passed
        testKind = 'SeededResumeRepairRollbackTest -- NOT a full real primary Complete-Installer run (cutover-runtime blocks that end-to-end; see header comment)'
        checks = $checks
        failures = @($fail)
    } | ConvertTo-Json -Depth 12
    if (-not $passed) { throw 'MCP-Runtime-Seeded-Primary-Flow-Regression fehlgeschlagen.' }
} finally {
    try { Remove-Item -LiteralPath $scratchBase -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

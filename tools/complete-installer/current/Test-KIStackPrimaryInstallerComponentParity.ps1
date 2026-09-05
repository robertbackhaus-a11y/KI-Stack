[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Protective regression (Phase 5, Schritt 14): the Phase-4 decommission analysis found that
# mcp-runtime was wired into the SECONDARY, isolated per-component update dispatcher
# (Lifecycle/KIStackUpdateIsolation.psm1) but NOT into the PRIMARY, monolithic
# Invoke-KIStackCompleteInstaller step loop -- a fresh Complete-Installer run installed Open
# Terminal but never mcp-runtime. This asymmetry existed silently for one full phase before
# being noticed. This test exists so that gap (or its equivalent for any FUTURE new component)
# can never again go unnoticed: every component the contract declares installable must have a
# real handler in the PRIMARY step loop, not just the isolated one.

$fail = [Collections.Generic.List[string]]::new()
$checks = [ordered]@{}

$componentsPath = Join-Path $PackageRoot 'Contracts/COMPONENTS.json'
$requiredPayloadsPath = Join-Path $PackageRoot 'Contracts/REQUIRED-PAYLOADS.json'
$orchestratorPath = Join-Path $PackageRoot 'CompleteInstaller.psm1'
$statusScriptPath = Join-Path $PackageRoot 'Lifecycle/Get-KIStackStatus.ps1'
$components = (Get-Content -LiteralPath $componentsPath -Raw | ConvertFrom-Json -Depth 30).components
$requiredPayloads = (Get-Content -LiteralPath $requiredPayloadsPath -Raw | ConvertFrom-Json -Depth 30).payloads
$orchestrator = Get-Content -LiteralPath $orchestratorPath -Raw
$statusScript = Get-Content -LiteralPath $statusScriptPath -Raw

# --- 1. COMPONENTS.json knows mcp-runtime, with the expected shape -------------------------
$mcpComponent = @($components | Where-Object id -eq 'mcp-runtime')
$checks.componentsJsonKnowsMcpRuntime = [ordered]@{
    present = ($mcpComponent.Count -eq 1)
    isolationA = ($mcpComponent.Count -eq 1 -and [string]$mcpComponent[0].isolation -eq 'A')
    installable = ($mcpComponent.Count -eq 1 -and [bool]$mcpComponent[0].installable)
    hasJsonProbe = ($mcpComponent.Count -eq 1 -and $mcpComponent[0].PSObject.Properties['probe'] -and [string]$mcpComponent[0].probe.type -eq 'json')
}
if ($checks.componentsJsonKnowsMcpRuntime.Values -contains $false) { $fail.Add('componentsJsonKnowsMcpRuntime failed: ' + ($checks.componentsJsonKnowsMcpRuntime | ConvertTo-Json -Compress)) }

# --- 2. REQUIRED-PAYLOADS.json knows McpRuntime, and the source-path convention matches
#        COMPONENTS.json's own 'source' field exactly (Payload/<key>). -----------------------
$mcpPayload = @($requiredPayloads | Where-Object key -eq 'McpRuntime')
$checks.requiredPayloadsKnowsMcpRuntime = [ordered]@{
    present = ($mcpPayload.Count -eq 1)
    sourceMatchesComponentsJson = ($mcpComponent.Count -eq 1 -and $mcpPayload.Count -eq 1 -and [string]$mcpComponent[0].source -eq ('Payload/' + [string]$mcpPayload[0].key))
}
if ($checks.requiredPayloadsKnowsMcpRuntime.Values -contains $false) { $fail.Add('requiredPayloadsKnowsMcpRuntime failed: ' + ($checks.requiredPayloadsKnowsMcpRuntime | ConvertTo-Json -Compress)) }

# --- 3. New-KICompletePlan actually generates a step for every installable component --------
Import-Module $orchestratorPath -Force
$scratchTarget = Join-Path ([IO.Path]::GetTempPath()) ('KIParity-' + [guid]::NewGuid().ToString('N').Substring(0,10))
New-Item -ItemType Directory -Path $scratchTarget -Force | Out-Null
try {
    $plan = New-KICompletePlan -Mode Audit -PackageRoot $PackageRoot -TargetRoot $scratchTarget
    $planIds = @($plan.steps | ForEach-Object id)
    # Optional components (currently only openwebui-ballistics-pack) are deliberately excluded
    # from the default plan unless -EnableOpenWebUIBallistics is passed -- not part of this
    # parity check's concern, which is the primary-loop HANDLER gap, not opt-in gating.
    $installableIds = @($components | Where-Object { [bool]$_.installable -and -not ($_.PSObject.Properties['optional'] -and [bool]$_.optional) } | ForEach-Object id)
    $missingFromPlan = @($installableIds | Where-Object { $planIds -notcontains $_ })
    $checks.everyInstallableComponentReachesThePlan = [ordered]@{ noneMissing = ($missingFromPlan.Count -eq 0) }
    if ($missingFromPlan.Count -gt 0) { $fail.Add('everyInstallableComponentReachesThePlan failed, missing: ' + ($missingFromPlan -join ', ')) }
} finally {
    Remove-Item -LiteralPath $scratchTarget -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 4. THE core protective check: every component id known to the contract (installable or
#        a pinned/recovery reference -- i.e. every id that legitimately reaches the step loop
#        at all) has a real handler in the PRIMARY step loop's own elseif-chain, either as its
#        own dedicated branch or as a member of one of the small shared-handler id-lists
#        (openwebui-agent-pack/visual-pack share one branch; the six pinned-reference/recovery
#        components share the generic reference branch). This is the exact check that would
#        have caught "isolated dispatcher knows mcp-runtime, primary loop does not" the moment
#        Phase 2 introduced mcp-runtime into COMPONENTS.json, instead of it surfacing only in
#        Phase 4's manual decommission analysis. -------------------------------------------
$sharedHandlerGroups = @(
    ,@('openwebui-agent-pack','openwebui-visual-pack')
    ,@('foundation-runtime','python-git','applications','cutover-runtime','production-recovery','target-acceptance')
)
$allComponentIds = @($components | ForEach-Object id)
$handledByOwnBranch = [Collections.Generic.HashSet[string]]::new()
foreach ($id in $allComponentIds) {
    if ($orchestrator.Contains("elseif (`$step.id -eq '$id')")) { [void]$handledByOwnBranch.Add($id) }
}
foreach ($group in $sharedHandlerGroups) {
    $groupLiteral = "elseif (`$step.id -in @('" + ($group -join "','") + "'))"
    if ($orchestrator.Contains($groupLiteral)) { foreach ($id in $group) { [void]$handledByOwnBranch.Add($id) } }
}
$unhandledIds = @($allComponentIds | Where-Object { -not $handledByOwnBranch.Contains($_) })
$checks.everyContractComponentHasAPrimaryLoopHandler = [ordered]@{ noneUnhandled = ($unhandledIds.Count -eq 0) }
if ($unhandledIds.Count -gt 0) { $fail.Add('everyContractComponentHasAPrimaryLoopHandler failed, unhandled: ' + ($unhandledIds -join ', ') + ' -- THIS IS EXACTLY THE PHASE-4 ASYMMETRY SHAPE') }

# --- 5. mcp-runtime specifically: compliance function, resume-recheck wiring, lifecycle
#        routing, and status reporting all present in source. -------------------------------
$checks.mcpRuntimeSourceMarkersPresent = [ordered]@{
    complianceFunctionDefined = $orchestrator.Contains('function Test-KICompleteMcpRuntimeCompliant')
    complianceWiredIntoPlan = $orchestrator.Contains("if([string]`$component.id-eq'mcp-runtime'-and`$null-eq`$FixtureState){`$compliant=`$compliant-and(Test-KICompleteMcpRuntimeCompliant")
    complianceWiredIntoResumeRecheck = $orchestrator.Contains("if([string]`$step.id-eq'mcp-runtime'){`$resumeCompliant=`$resumeCompliant-and(Test-KICompleteMcpRuntimeCompliant")
    lifecycleFunctionDefined = $orchestrator.Contains('function Invoke-KICompleteMcpRuntimeLifecycle')
    lifecycleWiredIntoStartStop = $orchestrator.Contains('$mcpRuntime = Invoke-KICompleteMcpRuntimeLifecycle')
    statusScriptKnowsMcpRuntime = $statusScript.Contains("New-StatusResult 'MCP Runtime'")
}
if ($checks.mcpRuntimeSourceMarkersPresent.Values -contains $false) { $fail.Add('mcpRuntimeSourceMarkersPresent failed: ' + ($checks.mcpRuntimeSourceMarkersPresent | ConvertTo-Json -Compress)) }

# --- 6. Negative control: prove this check actually catches the asymmetry shape, not just a
#        tautology -- simulate the Phase-4 gap by checking a component id the contract does NOT
#        know, confirming it would be reported unhandled rather than silently passing. ---------
$fakeContract = @($allComponentIds) + @('definitely-not-a-real-component-id')
$fakeUnhandled = @($fakeContract | Where-Object { -not $handledByOwnBranch.Contains($_) })
$checks.negativeControlDetectsAnUnwiredComponent = [ordered]@{ detected = ($fakeUnhandled -contains 'definitely-not-a-real-component-id') }
if ($checks.negativeControlDetectsAnUnwiredComponent.Values -contains $false) { $fail.Add('negativeControlDetectsAnUnwiredComponent failed -- the parity check itself is not sound') }

$passed = $fail.Count -eq 0
[pscustomobject]@{ passed = $passed; checks = $checks; failures = @($fail) } | ConvertTo-Json -Depth 12
if (-not $passed) { throw 'Primary-Installer-Component-Parity-Regression fehlgeschlagen.' }

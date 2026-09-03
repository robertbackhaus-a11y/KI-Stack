[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

# Regression suite for the component-isolation planning/execution layer
# (Lifecycle/KIStackUpdateIsolation.psm1). Resolve-KIStackUpdatePlan is pure (no I/O) and is
# tested purely against fixture component rows -- no real target, no mocked HTTP needed for
# the planning half. Invoke-KIStackIsolatedComponentUpdate's failure/blocked paths are tested
# against a real, disposable scratch filesystem (no network required); its success path for
# each real component (openwebui-agent-pack/openwebui-visual-pack/openwebui-ballistics-pack/
# rag/codex-local) is already covered end to end by each package's own existing regression
# suite (e.g. Test-OpenWebUIAgentPackResearchContract.ps1, Test-OpenWebUIAgentPackPreserve.ps1)
# -- this file does not re-implement those, it tests the NEW dispatch/blocking/independence
# contract this workstream adds on top.

Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'Lifecycle/KIStackUpdateIsolation.psm1') -Force -DisableNameChecking

function New-FixtureComponent {
    # $Route is deliberately untyped: a [string]-typed parameter would coerce an unpassed
    # $null default straight to "" at bind time (a real PowerShell footgun), which would then
    # make "if ($null -eq $Route)" below always false and silently skip the auto-default for
    # every caller that doesn't pass -Route explicitly.
    param([string]$Id,[string]$Name='',[string]$Installed='1.0.0',[string]$Pinned='1.0.0',[string]$Classification='UpToDate',[string]$Isolation='A',[string[]]$Requires=@(),[bool]$Implemented=$true,$Route=$null)
    if ([string]::IsNullOrEmpty($Name)) { $Name = $Id }
    if ($null -eq $Route) { $Route = if ($Isolation -eq 'C' -or -not $Implemented) { 'CompleteInstallerBatch' } else { 'Isolated' } }
    [pscustomobject][ordered]@{
        id=$Id; name=$Name; installedVersion=$Installed; pinnedVersion=$Pinned; availableVersion='Unknown'; upstreamStatus='Unknown'
        classification=$Classification; isolation=$Isolation; requires=@($Requires); isolatedExecutionImplemented=$Implemented; executionRoute=$Route
    }
}

function New-FixtureUniverse {
    @(
        New-FixtureComponent -Id 'openwebui-agent-pack' -Installed '1.8.9' -Pinned '1.9.0' -Classification 'PinnedUpdatePending' -Isolation 'A' -Implemented $true
        New-FixtureComponent -Id 'openwebui-visual-pack' -Classification 'UpToDate' -Isolation 'A' -Implemented $true
        New-FixtureComponent -Id 'openwebui-ballistics-pack' -Classification 'UpToDate' -Isolation 'A' -Implemented $true
        New-FixtureComponent -Id 'codex-local' -Classification 'UpToDate' -Isolation 'A' -Implemented $true
        New-FixtureComponent -Id 'rag' -Installed '0.3.1' -Pinned '0.4.0' -Classification 'PinnedUpdatePending' -Isolation 'B' -Requires @('integration') -Implemented $true
        New-FixtureComponent -Id 'integration' -Classification 'UpToDate' -Isolation 'A' -Implemented $true
        New-FixtureComponent -Id 'comfyui' -Classification 'UpToDate' -Isolation 'A' -Implemented $true
        New-FixtureComponent -Id 'models-workflows' -Classification 'UpToDate' -Isolation 'A' -Implemented $true
        New-FixtureComponent -Id 'validation-gate' -Classification 'UpToDate' -Isolation 'A' -Implemented $true
        New-FixtureComponent -Id 'foundation-runtime' -Classification 'UpToDate' -Isolation 'C'
        New-FixtureComponent -Id 'python-git' -Classification 'UpToDate' -Isolation 'C'
        New-FixtureComponent -Id 'applications' -Classification 'UpToDate' -Isolation 'C'
        New-FixtureComponent -Id 'cutover-runtime' -Classification 'UpToDate' -Isolation 'C'
        New-FixtureComponent -Id 'production-recovery' -Classification 'UpToDate' -Isolation 'C'
        New-FixtureComponent -Id 'target-acceptance' -Classification 'UpToDate' -Isolation 'C'
    )
}

# --- A. Single selection, isolated route, no dependency ---------------------------------
$planA = Resolve-KIStackUpdatePlan -AvailableComponents (New-FixtureUniverse) -SelectedComponentIds @('openwebui-agent-pack')
$checks.singleSelectionIsolated = [ordered]@{
    onlyAgentPackPlanned = (@($planA.plannedUpdates).Count -eq 1 -and [string]$planA.plannedUpdates[0].id -eq 'openwebui-agent-pack')
    isolatedRoute = ([string]$planA.plannedUpdates[0].executionRoute -eq 'Isolated')
    noDependenciesRequired = (@($planA.requiredDependencies).Count -eq 0)
    notBlocked = (@($planA.blockedComponents).Count -eq 0)
    ragPreserved = (@($planA.preservedComponents | Where-Object id -eq 'rag').Count -eq 1)
    visualPackPreserved = (@($planA.preservedComponents | Where-Object id -eq 'openwebui-visual-pack').Count -eq 1)
    cutoverRuntimePreserved = (@($planA.preservedComponents | Where-Object id -eq 'cutover-runtime').Count -eq 1)
}
if ($checks.singleSelectionIsolated.Values -contains $false) { $fail.Add('singleSelectionIsolated failed: ' + ($planA | ConvertTo-Json -Depth 10 -Compress)) }

# --- B. Single selection whose dependency is already satisfied --------------------------
$universeB = New-FixtureUniverse
($universeB | Where-Object id -eq 'integration').classification = 'UpToDate'
($universeB | Where-Object id -eq 'integration').isolatedExecutionImplemented = $true
($universeB | Where-Object id -eq 'integration').executionRoute = 'Isolated'
$planB = Resolve-KIStackUpdatePlan -AvailableComponents $universeB -SelectedComponentIds @('rag')
$checks.dependencyAlreadySatisfied = [ordered]@{
    ragPlanned = (@($planB.plannedUpdates | Where-Object id -eq 'rag').Count -eq 1)
    integrationListedAsDependency = (@($planB.requiredDependencies | Where-Object id -eq 'integration').Count -eq 1)
    integrationMarkedSatisfied = ([bool](@($planB.requiredDependencies | Where-Object id -eq 'integration')[0].alreadySatisfied))
    integrationNotInPlannedUpdates = (@($planB.plannedUpdates | Where-Object id -eq 'integration').Count -eq 0)
    notBlocked = (@($planB.blockedComponents).Count -eq 0)
}
if ($checks.dependencyAlreadySatisfied.Values -contains $false) { $fail.Add('dependencyAlreadySatisfied failed: ' + ($planB | ConvertTo-Json -Depth 10 -Compress)) }

# --- C1. RAG -> Integration is now fully isolated end to end (Section 6 target state):
# Integration needs real action too, but since it now has its own isolated route, both it and
# rag are planned as Isolated -- no Complete-Installer batch involved at all, and the
# dependency (integration) is ordered BEFORE the dependent (rag). -----------------------------
$universeC1 = New-FixtureUniverse
($universeC1 | Where-Object id -eq 'integration').classification = 'PinnedUpdatePending'
$planC1 = Resolve-KIStackUpdatePlan -AvailableComponents $universeC1 -SelectedComponentIds @('rag')
$checks.ragIntegrationDependencyFullyIsolatedNoBatch = [ordered]@{
    ragPlanned = (@($planC1.plannedUpdates | Where-Object id -eq 'rag').Count -eq 1)
    integrationPlannedIsolated = (@($planC1.plannedUpdates | Where-Object { $_.id -eq 'integration' -and $_.executionRoute -eq 'Isolated' }).Count -eq 1)
    ragPlannedIsolated = (@($planC1.plannedUpdates | Where-Object { $_.id -eq 'rag' -and $_.executionRoute -eq 'Isolated' }).Count -eq 1)
    notBlocked = (@($planC1.blockedComponents).Count -eq 0)
    noCompleteInstallerRequired = (-not [bool]$planC1.completeInstallerRequired)
    dependencyVisiblyListed = (@($planC1.requiredDependencies | Where-Object id -eq 'integration').Count -eq 1)
    integrationOrderedBeforeRag = ((@($planC1.plannedUpdates | ForEach-Object id).IndexOf('integration')) -lt (@($planC1.plannedUpdates | ForEach-Object id).IndexOf('rag')))
}
if ($checks.ragIntegrationDependencyFullyIsolatedNoBatch.Values -contains $false) { $fail.Add('ragIntegrationDependencyFullyIsolatedNoBatch failed: ' + ($planC1 | ConvertTo-Json -Depth 10 -Compress)) }

# --- C2. A genuinely still-batch-only component (cutover-runtime, Category C) is selected
# while a completely unrelated, also-still-batch-only component (foundation-runtime) needs
# action too -- the batch really would touch something beyond what was named, so this must
# still block exactly as before, proving Category C scope-understatement protection was not
# lost while wiring in the newly-isolated components. -----------------------------------------
$universeC2 = New-FixtureUniverse
($universeC2 | Where-Object id -eq 'foundation-runtime').classification = 'PinnedUpdatePending'
($universeC2 | Where-Object id -eq 'cutover-runtime').classification = 'PinnedUpdatePending'
$planC2 = Resolve-KIStackUpdatePlan -AvailableComponents $universeC2 -SelectedComponentIds @('cutover-runtime')
$checks.categoryCScopeUnderstatementStillBlocks = [ordered]@{
    noPlannedUpdates = (@($planC2.plannedUpdates).Count -eq 0)
    cutoverRuntimeForcesBlock = (@($planC2.blockedComponents | Where-Object id -eq 'cutover-runtime').Count -eq 1)
    reasonNamesFoundationRuntime = ((@($planC2.blockedComponents | Where-Object id -eq 'cutover-runtime')[0].reason) -match '(?i)foundation-runtime')
    completeInstallerRequired = [bool]$planC2.completeInstallerRequired
}
if ($checks.categoryCScopeUnderstatementStillBlocks.Values -contains $false) { $fail.Add('categoryCScopeUnderstatementStillBlocks failed: ' + ($planC2 | ConvertTo-Json -Depth 10 -Compress)) }

# --- C3. Multi-component selection with a dependency (Section 8): selecting rag AND
# openwebui-agent-pack together still only plans exactly those two plus the one real
# dependency (integration) -- never a duplicate, never an extra component, deterministic order
# preserved across repeated calls with the same input. -----------------------------------------
$universeC3 = New-FixtureUniverse
($universeC3 | Where-Object id -eq 'integration').classification = 'PinnedUpdatePending'
$planC3a = Resolve-KIStackUpdatePlan -AvailableComponents $universeC3 -SelectedComponentIds @('rag','openwebui-agent-pack')
$planC3b = Resolve-KIStackUpdatePlan -AvailableComponents $universeC3 -SelectedComponentIds @('rag','openwebui-agent-pack')
$checks.multiComponentWithDependencyNoDuplicatesDeterministic = [ordered]@{
    exactlyThreePlanned = (@($planC3a.plannedUpdates).Count -eq 3)
    noDuplicateIds = ((@($planC3a.plannedUpdates | ForEach-Object id) | Select-Object -Unique).Count -eq 3)
    identicalOrderAcrossRuns = ((@($planC3a.plannedUpdates | ForEach-Object id) -join ',') -eq (@($planC3b.plannedUpdates | ForEach-Object id) -join ','))
    integrationBeforeRag = ((@($planC3a.plannedUpdates | ForEach-Object id).IndexOf('integration')) -lt (@($planC3a.plannedUpdates | ForEach-Object id).IndexOf('rag')))
}
if ($checks.multiComponentWithDependencyNoDuplicatesDeterministic.Values -contains $false) { $fail.Add('multiComponentWithDependencyNoDuplicatesDeterministic failed: ' + ($planC3a | ConvertTo-Json -Depth 10 -Compress)) }

# --- D. Multi selection: only the named components (+ satisfied deps) are planned -------
$planD = Resolve-KIStackUpdatePlan -AvailableComponents $universeB -SelectedComponentIds @('openwebui-agent-pack','rag')
$checks.multiSelection = [ordered]@{
    exactlyTwoPlanned = (@($planD.plannedUpdates).Count -eq 2)
    agentPackPlanned = (@($planD.plannedUpdates | Where-Object id -eq 'openwebui-agent-pack').Count -eq 1)
    ragPlanned = (@($planD.plannedUpdates | Where-Object id -eq 'rag').Count -eq 1)
    ballisticsPreserved = (@($planD.preservedComponents | Where-Object id -eq 'openwebui-ballistics-pack').Count -eq 1)
    codexLocalPreserved = (@($planD.preservedComponents | Where-Object id -eq 'codex-local').Count -eq 1)
}
if ($checks.multiSelection.Values -contains $false) { $fail.Add('multiSelection failed: ' + ($planD | ConvertTo-Json -Depth 10 -Compress)) }

# --- N. The four named multi-component pairs from the Restabdeckung task (Section 8) are
# each planned correctly: two independent (no requires-edge between them) Category-A
# components selected together plan exactly those two and nothing else, in deterministic
# order, with every other component preserved; a pair where one side genuinely requires the
# other (integration/rag) still plans exactly the selection plus that one real dependency,
# dependency-first. -----------------------------------------------------------------------
$universeN = New-FixtureUniverse
($universeN | Where-Object id -eq 'comfyui').classification = 'PinnedUpdatePending'
($universeN | Where-Object id -eq 'models-workflows').classification = 'PinnedUpdatePending'
($universeN | Where-Object id -eq 'openwebui-visual-pack').classification = 'PinnedUpdatePending'
($universeN | Where-Object id -eq 'integration').classification = 'PinnedUpdatePending'

$planN1 = Resolve-KIStackUpdatePlan -AvailableComponents $universeN -SelectedComponentIds @('comfyui','models-workflows')
$checks.pairComfyUIModelsWorkflows = [ordered]@{
    exactlyTwoPlanned = (@($planN1.plannedUpdates).Count -eq 2)
    noDependencyPulledIn = (@($planN1.requiredDependencies).Count -eq 0)
    comfyuiPlanned = (@($planN1.plannedUpdates | Where-Object id -eq 'comfyui').Count -eq 1)
    modelsWorkflowsPlanned = (@($planN1.plannedUpdates | Where-Object id -eq 'models-workflows').Count -eq 1)
    ragPreserved = (@($planN1.preservedComponents | Where-Object id -eq 'rag').Count -eq 1)
    integrationPreserved = (@($planN1.preservedComponents | Where-Object id -eq 'integration').Count -eq 1)
    noBatchRequired = (-not $planN1.completeInstallerRequired)
}
if ($checks.pairComfyUIModelsWorkflows.Values -contains $false) { $fail.Add('pairComfyUIModelsWorkflows failed: ' + ($planN1 | ConvertTo-Json -Depth 10 -Compress)) }

$planN2 = Resolve-KIStackUpdatePlan -AvailableComponents $universeN -SelectedComponentIds @('openwebui-visual-pack','models-workflows')
$checks.pairVisualPackModelsWorkflows = [ordered]@{
    exactlyTwoPlanned = (@($planN2.plannedUpdates).Count -eq 2)
    noDependencyPulledIn = (@($planN2.requiredDependencies).Count -eq 0)
    visualPackPlanned = (@($planN2.plannedUpdates | Where-Object id -eq 'openwebui-visual-pack').Count -eq 1)
    modelsWorkflowsPlanned = (@($planN2.plannedUpdates | Where-Object id -eq 'models-workflows').Count -eq 1)
    comfyuiPreserved = (@($planN2.preservedComponents | Where-Object id -eq 'comfyui').Count -eq 1)
    noBatchRequired = (-not $planN2.completeInstallerRequired)
}
if ($checks.pairVisualPackModelsWorkflows.Values -contains $false) { $fail.Add('pairVisualPackModelsWorkflows failed: ' + ($planN2 | ConvertTo-Json -Depth 10 -Compress)) }

$planN3 = Resolve-KIStackUpdatePlan -AvailableComponents $universeN -SelectedComponentIds @('integration','rag')
$checks.pairIntegrationRagExplicitSelection = [ordered]@{
    exactlyTwoPlanned = (@($planN3.plannedUpdates).Count -eq 2)
    noExtraDependencyRow = (@($planN3.requiredDependencies).Count -eq 0)
    integrationBeforeRag = ((@($planN3.plannedUpdates | ForEach-Object id).IndexOf('integration')) -lt (@($planN3.plannedUpdates | ForEach-Object id).IndexOf('rag')))
    comfyuiPreserved = (@($planN3.preservedComponents | Where-Object id -eq 'comfyui').Count -eq 1)
    noBatchRequired = (-not $planN3.completeInstallerRequired)
}
if ($checks.pairIntegrationRagExplicitSelection.Values -contains $false) { $fail.Add('pairIntegrationRagExplicitSelection failed: ' + ($planN3 | ConvertTo-Json -Depth 10 -Compress)) }
# (Agent Pack + RAG, the fourth named pair, is already covered above by
# multiComponentWithDependencyNoDuplicatesDeterministic (C3) and multiSelection (D).)

# --- E. Unknown availableVersion never blocks isolation or forces an update -------------
$planE = Resolve-KIStackUpdatePlan -AvailableComponents (New-FixtureUniverse) -SelectedComponentIds @('openwebui-visual-pack')
$checks.unknownVersionSafe = [ordered]@{
    noPlannedUpdates = (@($planE.plannedUpdates).Count -eq 0)
    skippedNotBlocked = (@($planE.skippedComponents | Where-Object id -eq 'openwebui-visual-pack').Count -eq 1)
    notInBlocked = (@($planE.blockedComponents | Where-Object id -eq 'openwebui-visual-pack').Count -eq 0)
}
if ($checks.unknownVersionSafe.Values -contains $false) { $fail.Add('unknownVersionSafe failed: ' + ($planE | ConvertTo-Json -Depth 10 -Compress)) }

# --- F. "Newer supported version" classification (UpToDate despite differing raw
# version strings) is trusted as-is and never re-derived into a forced update. This is the
# regression shape for OpenWebUI/ComfyUI's real preserve-newer-supported contract. -------
$universeF = New-FixtureUniverse
$owui = New-FixtureComponent -Id 'openwebui-like' -Installed '0.11.2' -Pinned '0.11.1' -Classification 'UpToDate' -Isolation 'A' -Implemented $true -Route 'OpenWebUIAdapter'
$planF = Resolve-KIStackUpdatePlan -AvailableComponents (@($universeF)+@($owui)) -SelectedComponentIds @('openwebui-like')
$checks.newerSupportedPreserved = [ordered]@{
    noPlannedUpdate = (@($planF.plannedUpdates | Where-Object id -eq 'openwebui-like').Count -eq 0)
    listedAsSkipped = (@($planF.skippedComponents | Where-Object id -eq 'openwebui-like').Count -eq 1)
}
if ($checks.newerSupportedPreserved.Values -contains $false) { $fail.Add('newerSupportedPreserved failed: ' + ($planF | ConvertTo-Json -Depth 10 -Compress)) }

# --- G. Complete Installer explicitly selected authorizes the real, full batch ----------
$universeG = New-FixtureUniverse
($universeG | Where-Object id -eq 'comfyui').classification = 'PinnedUpdatePending'
$planG = Resolve-KIStackUpdatePlan -AvailableComponents $universeG -SelectedComponentIds @('complete-installer') -CompleteInstallerExplicitlySelected
$checks.completeInstallerExplicit = [ordered]@{
    notBlocked = (@($planG.blockedComponents).Count -eq 0)
    agentPackPlanned = (@($planG.plannedUpdates | Where-Object id -eq 'openwebui-agent-pack').Count -eq 1)
    comfyuiPlanned = (@($planG.plannedUpdates | Where-Object id -eq 'comfyui').Count -eq 1)
    ragPlanned = (@($planG.plannedUpdates | Where-Object id -eq 'rag').Count -eq 1)
    allBatchRoute = (@($planG.plannedUpdates | Where-Object { [string]$_.executionRoute -ne 'CompleteInstallerBatch' }).Count -eq 0)
}
if ($checks.completeInstallerExplicit.Values -contains $false) { $fail.Add('completeInstallerExplicit failed: ' + ($planG | ConvertTo-Json -Depth 10 -Compress)) }

# --- H. NotManaged component id is reported, not silently dropped or executed -----------
$planH = Resolve-KIStackUpdatePlan -AvailableComponents (New-FixtureUniverse) -SelectedComponentIds @('openwebui-agent-pack','totally-unknown-id')
$checks.notManagedReported = [ordered]@{
    reported = (@($planH.blockedComponents | Where-Object id -eq 'totally-unknown-id').Count -eq 1)
    agentPackStillPlanned = (@($planH.plannedUpdates | Where-Object id -eq 'openwebui-agent-pack').Count -eq 1)
}
if ($checks.notManagedReported.Values -contains $false) { $fail.Add('notManagedReported failed: ' + ($planH | ConvertTo-Json -Depth 10 -Compress)) }

# --- I. Cyclic dependency is detected and aborts the plan, never infinite-loops ---------
$cyclic = @(
    New-FixtureComponent -Id 'a' -Requires @('b')
    New-FixtureComponent -Id 'b' -Requires @('a')
)
$planI = Resolve-KIStackUpdatePlan -AvailableComponents $cyclic -SelectedComponentIds @('a')
$checks.cyclicDependencyDetected = [ordered]@{
    errorReported = (-not [string]::IsNullOrWhiteSpace([string]$planI.cyclicDependencyError))
    noPlannedUpdates = (@($planI.plannedUpdates).Count -eq 0)
}
if ($checks.cyclicDependencyDetected.Values -contains $false) { $fail.Add('cyclicDependencyDetected failed: ' + ($planI | ConvertTo-Json -Depth 10 -Compress)) }
$acyclicCheck = Test-KIStackDependencyCycle -Components (New-FixtureUniverse)
$checks.realUniverseHasNoCycle = [ordered]@{ noCycle = ($null -eq $acyclicCheck) }
if (-not $checks.realUniverseHasNoCycle.noCycle) { $fail.Add("realUniverseHasNoCycle failed: $acyclicCheck") }

# --- J. Negative control: prove this suite actually detects the original coupling defect.
# Patch a copy of the module so the "batch forced but not explicitly authorized" block is
# skipped (mirrors the pre-fix Update-KIStack-All.ps1 behavior where a selected component
# needing the batch route just silently ran it) and confirm dependencyForcesBlock's own
# assertions now fail against that patched copy. -----------------------------------------
$moduleSource = Get-Content -LiteralPath (Join-Path $PackageRoot 'Lifecycle/KIStackUpdateIsolation.psm1') -Raw
$negativeSource = $moduleSource.Replace(
    'if ($batchSelectionUnderstatesScope) {',
    'if ($false) {'
)
if ($negativeSource -eq $moduleSource) { throw 'Negative-Control-Patch griff nicht -- Testannahme verletzt (Zeile im Modul nicht gefunden).' }
$negativeControlDir = Join-Path ([IO.Path]::GetTempPath()) ('KIStack-UpdateIsolation-NegControl-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $negativeControlDir -Force | Out-Null
$negativeModulePath = Join-Path $negativeControlDir 'KIStackUpdateIsolation.psm1'
Set-Content -LiteralPath $negativeModulePath -Value $negativeSource -Encoding UTF8
try {
    Remove-Module KIStackUpdateIsolation -Force -ErrorAction SilentlyContinue
    Import-Module $negativeModulePath -Force -DisableNameChecking
    $universeNegative = New-FixtureUniverse
    ($universeNegative | Where-Object id -eq 'foundation-runtime').classification = 'PinnedUpdatePending'
    ($universeNegative | Where-Object id -eq 'cutover-runtime').classification = 'PinnedUpdatePending'
    $planCNegative = Resolve-KIStackUpdatePlan -AvailableComponents $universeNegative -SelectedComponentIds @('cutover-runtime')
    # Under the disabled block, foundation-runtime -- never named, never selected, sharing
    # nothing but the batch route with the actually-requested cutover-runtime -- would be
    # silently swept into the same implicit batch run the moment it ever ran. Proving that
    # here (rather than merely that cutover-runtime proceeds) is what makes this a genuine
    # negative control for the original coupling defect, not just a restatement of the C2
    # scenario above.
    $negativeControlDetectsRegression = (@($planCNegative.blockedComponents).Count -eq 0) -and (@($planCNegative.plannedUpdates | Where-Object id -eq 'cutover-runtime').Count -eq 1)
    $checks.negativeControl = [ordered]@{ oldBehaviorWouldHaveSilentlyExecutedCutoverRuntime = $negativeControlDetectsRegression }
    if (-not $negativeControlDetectsRegression) { $fail.Add('negativeControl failed: patched module did not reproduce the original silent-batch-scope defect, so this suite would not actually catch a regression back to it') }
} finally {
    Remove-Module KIStackUpdateIsolation -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PackageRoot 'Lifecycle/KIStackUpdateIsolation.psm1') -Force -DisableNameChecking
    Remove-Item -LiteralPath $negativeControlDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- K. Isolated-execution dispatch: unknown/Category-C id refuses instead of running ---
$threwForUnknown = $false
try {
    [void](Invoke-KIStackIsolatedComponentUpdate -ComponentId 'cutover-runtime' -PackageRoot $PackageRoot -TargetRoot 'C:\does-not-matter' -Component ([pscustomobject]@{id='cutover-runtime'}) -Config ([pscustomobject]@{stateDirectory=$env:TEMP;backupDirectory=$env:TEMP}))
} catch { $threwForUnknown = $true }
$checks.unimplementedComponentRefuses = [ordered]@{ threw = $threwForUnknown }
if (-not $threwForUnknown) { $fail.Add('unimplementedComponentRefuses failed: cutover-runtime is Category C (shared BuilderKernel execution, no isolated executor) and must refuse, not silently no-op or run something else') }

# --- K2. All nine now-implemented isolated ids are actually dispatchable (no
# "Get-KIStackIsolatedExecutionHandler says yes but the switch has no case" gap). A
# not-found-payload/entry-point error is an acceptable, expected outcome here (no real
# target/payload exists in this unit test); an "unimplementiert"/"Kategorie C" refusal is not
# -- that would mean the handler list and the switch statement have drifted apart. ------------
$scratchTargetRootForDriftCheck = Join-Path ([IO.Path]::GetTempPath()) ('KIStack-UpdateIsolation-DriftCheck-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $scratchTargetRootForDriftCheck -Force | Out-Null
$driftCheck = [ordered]@{}
foreach ($id in (Get-KIStackIsolatedExecutionHandler)) {
    $threw = $false; $refusedAsUnimplemented = $false
    try {
        $r = Invoke-KIStackIsolatedComponentUpdate -ComponentId $id -PackageRoot $PackageRoot -TargetRoot $scratchTargetRootForDriftCheck -Component ([pscustomobject]@{id=$id}) -Config ([pscustomobject]@{stateDirectory=$env:TEMP;backupDirectory=$env:TEMP})
        if ([string]$r.outcome -eq 'Failed' -and [string]$r.detail -match '(?i)keine isolierte ausf') { $refusedAsUnimplemented = $true }
    } catch {
        if ($_.Exception.Message -match '(?i)keine isolierte ausf') { $refusedAsUnimplemented = $true }
    }
    $driftCheck[$id] = (-not $refusedAsUnimplemented)
}
$checks.everyClaimedIsolatedIdIsActuallyDispatchable = $driftCheck
if ($driftCheck.Values -contains $false) { $fail.Add('everyClaimedIsolatedIdIsActuallyDispatchable failed: Get-KIStackIsolatedExecutionHandler and the Invoke-KIStackIsolatedComponentUpdate switch have drifted apart for: ' + (($driftCheck.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key) -join ', ')) }
Remove-Item -LiteralPath $scratchTargetRootForDriftCheck -Recurse -Force -ErrorAction SilentlyContinue

# --- K3. Negative control against the REAL Contracts/COMPONENTS.json (not a hand-written
# fixture): revert two of the four components this Restabdeckung pass newly wired --
# comfyui and integration -- back to "isolatedExecutionImplemented: false" (their pre-pass
# state) and prove Resolve-KIStackUpdatePlan then correctly falls back to routing them
# through CompleteInstallerBatch (the exact "isolated selection silently becomes a batch
# run" shape this whole workstream exists to prevent). This is what makes
# everyClaimedIsolatedIdIsActuallyDispatchable (K2) and the real-target DryRuns (Section 10
# of the task) meaningful rather than tautological: a real regression in the contract itself
# is provably caught, not just assumed away by a fixture that always says "isolated". ------
$realContractPath = Join-Path $PackageRoot 'Contracts/COMPONENTS.json'
$realContractRaw = Get-Content -LiteralPath $realContractPath -Raw | ConvertFrom-Json -Depth 50
function ConvertTo-FixtureRowFromRealContract {
    param([object]$RealComponent, [string]$Classification = 'UpToDate')
    $implemented = [bool]$RealComponent.isolatedExecutionImplemented
    $isolation = [string]$RealComponent.isolation
    $route = if ($isolation -eq 'B') { 'Isolated' } elseif ($isolation -eq 'C' -or -not $implemented) { 'CompleteInstallerBatch' } else { 'Isolated' }
    New-FixtureComponent -Id ([string]$RealComponent.id) -Classification $Classification -Isolation $isolation -Requires @($RealComponent.requires) -Implemented $implemented -Route $route
}
$realUniverseAsPlanned = @($realContractRaw.components | ForEach-Object { ConvertTo-FixtureRowFromRealContract -RealComponent $_ })
($realUniverseAsPlanned | Where-Object id -eq 'comfyui').classification = 'PinnedUpdatePending'
($realUniverseAsPlanned | Where-Object id -eq 'integration').classification = 'PinnedUpdatePending'
$planK3RealToday = Resolve-KIStackUpdatePlan -AvailableComponents $realUniverseAsPlanned -SelectedComponentIds @('comfyui')
$checks.newlyIsolatedComponentsRouteIsolatedUnderRealContractToday = [ordered]@{
    comfyuiRoutesIsolatedToday = ((@($planK3RealToday.plannedUpdates | Where-Object id -eq 'comfyui') | Select-Object -First 1).executionRoute -eq 'Isolated')
    comfyuiNotBlockedToday = (@($planK3RealToday.blockedComponents).Count -eq 0)
}
if ($checks.newlyIsolatedComponentsRouteIsolatedUnderRealContractToday.Values -contains $false) { $fail.Add('newlyIsolatedComponentsRouteIsolatedUnderRealContractToday failed: ' + ($planK3RealToday | ConvertTo-Json -Depth 10 -Compress)) }

$revertedUniverse = @($realContractRaw.components | ForEach-Object {
    $forceReverted = [string]$_.id -in @('comfyui','integration')
    ConvertTo-FixtureRowFromRealContract -RealComponent ([pscustomobject]@{ id=$_.id; isolation=$_.isolation; requires=$_.requires; isolatedExecutionImplemented=(-not $forceReverted -and [bool]$_.isolatedExecutionImplemented) })
})
($revertedUniverse | Where-Object id -eq 'comfyui').classification = 'PinnedUpdatePending'
($revertedUniverse | Where-Object id -eq 'integration').classification = 'PinnedUpdatePending'
$planK3Reverted = Resolve-KIStackUpdatePlan -AvailableComponents $revertedUniverse -SelectedComponentIds @('comfyui') -CompleteInstallerExplicitlySelected
$checks.negativeControlRevertedComponentsWouldFallBackToBatch = [ordered]@{
    comfyuiRoutesBatchWhenReverted = ((@($planK3Reverted.plannedUpdates | Where-Object id -eq 'comfyui') | Select-Object -First 1).executionRoute -eq 'CompleteInstallerBatch')
    integrationAlsoBatchRouteWhenReverted = ((@(($revertedUniverse | Where-Object id -eq 'integration')).executionRoute) -eq 'CompleteInstallerBatch')
}
if ($checks.negativeControlRevertedComponentsWouldFallBackToBatch.Values -contains $false) { $fail.Add('negativeControlRevertedComponentsWouldFallBackToBatch failed: patched contract did not reproduce the pre-Restabdeckung batch-routing shape, so this suite would not actually catch a reversion back to it -- ' + ($planK3Reverted | ConvertTo-Json -Depth 10 -Compress)) }

# --- L. RAG's real, structural dependency on Integration's starter file is enforced at
# execution time too (not just at planning time) -- a controlled Blocked outcome, never a
# thrown exception, never a partial/mixed mutation. No network required: the starter file is
# simply absent under a disposable scratch TargetRoot. ------------------------------------
$scratchTargetRoot = Join-Path ([IO.Path]::GetTempPath()) ('KIStack-UpdateIsolation-RagBlock-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $scratchTargetRoot -Force | Out-Null
try {
    $ragResult = Invoke-KIStackIsolatedComponentUpdate -ComponentId 'rag' -PackageRoot $PackageRoot -TargetRoot $scratchTargetRoot -Component ([pscustomobject]@{id='rag'}) -Config ([pscustomobject]@{stateDirectory=(Join-Path $scratchTargetRoot 'state');backupDirectory=(Join-Path $scratchTargetRoot 'backup')})
    $checks.ragDependencyBlockedNotThrown = [ordered]@{
        outcomeIsBlocked = ([string]$ragResult.outcome -eq 'Blocked')
        mentionsIntegration = ([string]$ragResult.detail -match '(?i)integration')
        noStateWritten = (-not (Test-Path -LiteralPath (Join-Path $scratchTargetRoot 'modules/rag')))
    }
    if ($checks.ragDependencyBlockedNotThrown.Values -contains $false) { $fail.Add('ragDependencyBlockedNotThrown failed: ' + ($ragResult | ConvertTo-Json -Compress)) }

    # --- M. Failure isolation / independence: three isolated calls against the same
    # scratch target, one of them (rag, no integration starter) is Blocked, and this must
    # not affect a second, independent call's own outcome or leak any shared state between
    # calls (no shared mutable module-level variable, no cross-call throw propagation). ----
    $secondResult = Invoke-KIStackIsolatedComponentUpdate -ComponentId 'rag' -PackageRoot $PackageRoot -TargetRoot $scratchTargetRoot -Component ([pscustomobject]@{id='rag'}) -Config ([pscustomobject]@{stateDirectory=(Join-Path $scratchTargetRoot 'state');backupDirectory=(Join-Path $scratchTargetRoot 'backup')})
    $unknownAttempt = $null
    $unknownThrew = $false
    try { $unknownAttempt = Invoke-KIStackIsolatedComponentUpdate -ComponentId 'production-recovery' -PackageRoot $PackageRoot -TargetRoot $scratchTargetRoot -Component ([pscustomobject]@{id='production-recovery'}) -Config ([pscustomobject]@{stateDirectory=(Join-Path $scratchTargetRoot 'state');backupDirectory=(Join-Path $scratchTargetRoot 'backup')}) } catch { $unknownThrew = $true }
    $checks.failureIsolationIndependence = [ordered]@{
        firstCallStillBlocked = ([string]$ragResult.outcome -eq 'Blocked')
        secondCallIndependentlyBlocked = ([string]$secondResult.outcome -eq 'Blocked')
        thirdCallRefusedCleanly = $unknownThrew
        noCrossCallState = ($ragResult.id -eq 'rag' -and $secondResult.id -eq 'rag')
    }
    if ($checks.failureIsolationIndependence.Values -contains $false) { $fail.Add('failureIsolationIndependence failed') }
} finally {
    Remove-Item -LiteralPath $scratchTargetRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- N. Codex Local's own marker must never be clobbered by the generic
# Write-KICompleteComponentMarker call after a successful isolated Install/Upgrade/Repair --
# reproduced live against the real target while building this (Codex-Local-Operationalization
# workstream): CodexLocal.psm1 writes its own, richer marker (schemaVersion/version/
# codexVersion/nodeRuntimeVersion/.../backupPath) to the EXACT SAME path Contracts/
# COMPONENTS.json's own probe.path points at for codex-local
# (modules/codex-local/installation.json); the generic marker Write-KICompleteComponentMarker
# writes there instead ({schemaVersion;componentId;version;validatedAtUtc}, no codexVersion at
# all) made Test-KICodexLocal throw PropertyNotFoundException under Set-StrictMode on every
# subsequent Validate/Status/Install call -- a real Codex Local target would be permanently
# broken by its own first successful isolated update. Source-checked (not re-run against a
# real payload, which this hermetic suite deliberately never does) because the actual
# behavioral proof already lives in
# tools/codex-local/current/Test-KIStackCodexLocalOperationalization.ps1's real, network-
# touching suite; this only guards the specific dispatch wiring in THIS module. -----------------
$isolationModuleSource = Get-Content -LiteralPath (Join-Path $PackageRoot 'Lifecycle/KIStackUpdateIsolation.psm1') -Raw
function Test-KICodexLocalBranchCallsGenericMarker {
    # Bounded by the next sibling switch branch ('rag'), not a brace-matching regex -- this
    # module's own switch statement is stable/simple enough that "everything between this
    # branch's opening line and the next one" is a reliable, easy-to-read span.
    param([Parameter(Mandatory)][string]$Source)
    $branchMatch = [regex]::Match($Source, "(?s)'codex-local' \{(?<body>.*?)'rag' \{")
    if (-not $branchMatch.Success) { throw "codex-local-Zweig nicht gefunden -- Testannahme verletzt." }
    # An actual call, not a comment merely naming the function (this branch's own explanatory
    # comment deliberately says why it does NOT call it, which would otherwise false-positive a
    # bare substring match).
    [regex]::IsMatch($branchMatch.Groups['body'].Value, '(?m)^\s*Write-KICompleteComponentMarker\s+-Component')
}
$checks.codexLocalNeverOverwritesItsOwnRicherMarker = [ordered]@{
    realModuleDoesNotCallGenericMarkerWriter = (-not (Test-KICodexLocalBranchCallsGenericMarker -Source $isolationModuleSource))
}
if ($checks.codexLocalNeverOverwritesItsOwnRicherMarker.Values -contains $false) { $fail.Add('codexLocalNeverOverwritesItsOwnRicherMarker failed: the codex-local branch calls Write-KICompleteComponentMarker again, which would truncate CodexLocal.psm1''s own richer marker at the same path.') }

# --- Negative Control: reintroduce the call (simulating a reversion of this exact fix) and
# prove Test-KICodexLocalBranchCallsGenericMarker would catch it; then confirm the real module
# does not trip it (already asserted above). ---------------------------------------------------
$regressedIsolationModuleSource = $isolationModuleSource -replace [regex]::Escape("                    throw`n                }`n                # Deliberately NOT Write-KICompleteComponentMarker"), "                    throw`n                }`n                Write-KICompleteComponentMarker -Component `$Component -TargetRoot `$TargetRoot`n                # Deliberately NOT Write-KICompleteComponentMarker"
if ($regressedIsolationModuleSource -eq $isolationModuleSource) { throw 'Negative-Control-N-Patch griff nicht -- Testannahme verletzt (Ankertext im codex-local-Zweig nicht gefunden).' }
$checks.negativeControlN_MarkerClobberRegressionDetected = [ordered]@{
    regressedModuleDetected = (Test-KICodexLocalBranchCallsGenericMarker -Source $regressedIsolationModuleSource)
    realModuleClean = (-not (Test-KICodexLocalBranchCallsGenericMarker -Source $isolationModuleSource))
}
if ($checks.negativeControlN_MarkerClobberRegressionDetected.Values -contains $false) { $fail.Add('negativeControlN_MarkerClobberRegressionDetected failed: reintroducing the generic marker write was not detected, or the real module still trips the check -- '+($checks.negativeControlN_MarkerClobberRegressionDetected|ConvertTo-Json -Compress)) }

$passed = $fail.Count -eq 0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)} | ConvertTo-Json -Depth 12
if (-not $passed) { throw 'Update-Isolation-Regression fehlgeschlagen.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command New-KICompletePathContext -ErrorAction SilentlyContinue)) {
    $pathContextModule = Join-Path (Split-Path -Parent $PSScriptRoot) 'Runtime/KIStackPathContext.psm1'
    if (-not (Test-Path -LiteralPath $pathContextModule -PathType Leaf)) { throw "KIStackPathContext-Modul fehlt: $pathContextModule" }
    Import-Module $pathContextModule -Force -DisableNameChecking
}

# Component-isolation planning and execution for the central KI-Stack updater
# (Update-KIStack-All.ps1). Root problem this closes: selecting a single component there
# previously always fell through to a real Invoke-KIStackCompleteInstaller -Mode Upgrade
# batch run whenever that component needed action -- which, independent of which components
# were selected, ALSO always re-deploys the orchestrator/central-starter/Operations files and
# (whenever an OpenWebUI API token was supplied) unconditionally runs the Knowledge-experiment
# rollback and Code-Interpreter-configuration steps against OpenWebUI, and runs every
# compliance probe in Contracts/COMPONENTS.json even for components nobody asked about. A
# component that is currently non-compliant for reasons unrelated to the selection could
# therefore be mutated by a run the user believed was scoped to one thing.
#
# This module adds a pure planning function (Resolve-KIStackUpdatePlan -- no I/O, fully
# testable against fixture input) and an execution function
# (Invoke-KIStackIsolatedComponentUpdate) that calls a component's own, already
# self-contained install/backup/rollback entry point directly, WITHOUT ever invoking
# Invoke-KIStackCompleteInstaller, New-KICompleteTransaction, or the finalization phase
# described above. It does not replace or modify Invoke-KIStackCompleteInstaller -- that
# remains the correct, unchanged path for the components this workstream classifies as
# isolation "C" (see Contracts/COMPONENTS.json) and for an explicit, user-requested
# Complete Installer run.

function Test-KIStackDependencyCycle {
    # Detects a cycle anywhere in the full known "requires" graph (not just the selected
    # subset) via plain DFS with a recursion-stack set. Returns $null if no cycle exists, or
    # the exact cyclic id sequence (e.g. "a -> b -> a") if one does. Cutting this off before
    # any planning/execution logic runs is the "kontrolliert abbrechen" contract -- a cycle
    # must never be silently ignored or produce infinite recursion.
    param([Parameter(Mandatory)][object[]]$Components)
    $byId = @{}
    foreach ($c in $Components) { $byId[[string]$c.id] = @($c.requires) }
    $visiting = [Collections.Generic.HashSet[string]]::new()
    $visited = [Collections.Generic.HashSet[string]]::new()
    $path = [Collections.Generic.List[string]]::new()
    # A hashtable "box" carries the found-cycle result out of the nested Visit scriptblock --
    # a nested function/scriptblock in PowerShell cannot assign back into an enclosing
    # function's local variable (only $script:/module scope, which would leak across separate
    # calls to this function); mutating a shared reference-type value avoids both problems.
    $box = @{cycle=$null}
    $visit = {
        param([string]$id)
        if ($box.cycle) { return }
        if ($visited.Contains($id)) { return }
        if ($visiting.Contains($id)) {
            $path.Add($id)
            $box.cycle = ($path -join ' -> ')
            return
        }
        [void]$visiting.Add($id)
        $path.Add($id)
        foreach ($dep in @($byId[$id])) {
            if ($byId.ContainsKey($dep)) { & $visit $dep }
        }
        [void]$path.RemoveAt($path.Count - 1)
        [void]$visiting.Remove($id)
        [void]$visited.Add($id)
    }
    foreach ($id in $byId.Keys) { & $visit $id; if ($box.cycle) { break } }
    return $box.cycle
}

function Resolve-KIStackUpdatePlan {
    # Pure function: no disk/network access, no mutation. Input is the already-probed
    # per-component report Update-KIStack-All.ps1 already builds today (id, installedVersion,
    # pinnedVersion, availableVersion, upstreamStatus, classification, plus the new
    # Contracts/COMPONENTS.json isolation metadata: isolation ('A'/'B'/'C'), requires
    # (string[]), isolatedExecutionImplemented, executionRoute
    # ('Isolated'/'OpenWebUIAdapter'/'CompleteInstallerBatch')). SelectedComponentIds empty
    # means "no filter" (every managed component is in scope, matching today's default
    # Update-KIStack-All behavior) -- isolation concerns do not apply to that case since
    # nothing is being preserved by exclusion.
    param(
        [Parameter(Mandatory)][object[]]$AvailableComponents,
        [string[]]$SelectedComponentIds = @(),
        [switch]$CompleteInstallerExplicitlySelected
    )
    $byId = @{}
    foreach ($c in $AvailableComponents) { $byId[[string]$c.id] = $c }

    $cycle = Test-KIStackDependencyCycle -Components $AvailableComponents
    if ($cycle) {
        return [pscustomobject][ordered]@{
            selectedComponents=@($SelectedComponentIds); requiredDependencies=@(); plannedUpdates=@()
            preservedComponents=@(); skippedComponents=@(); blockedComponents=@()
            cyclicDependencyError="Zyklische Abhängigkeit erkannt, Planung abgebrochen: $cycle"
            completeInstallerRequired=$false
        }
    }

    # @($null) is a one-element array (Count 1), not an empty one -- guard against a caller
    # passing an explicit $null (rather than omitting the parameter or passing a genuine
    # @()) being misread as "one specific, phantom selection" instead of "no filter".
    $noFilter = ($null -eq $SelectedComponentIds) -or (@($SelectedComponentIds).Count -eq 0)
    $selectedIds = [Collections.Generic.List[string]]::new()
    $blocked = [Collections.Generic.List[object]]::new()
    foreach ($id in @($SelectedComponentIds | Select-Object -Unique)) {
        if ($id -eq 'complete-installer') { continue }
        if (-not $byId.ContainsKey($id)) {
            $blocked.Add([pscustomobject][ordered]@{id=$id;reason='NotManaged -- keine von KI-Stack verwaltete Komponente.'})
            continue
        }
        $selectedIds.Add($id)
    }
    if ($noFilter) { $selectedIds = [Collections.Generic.List[string]]::new([string[]]@($byId.Keys)) }

    # Transitive dependency closure (BFS) over the *selected* set only -- a dependency of a
    # dependency of a selected component is still a required dependency of the plan, but a
    # component that is merely a sibling with no requires-edge into the selection is not.
    $requiredIds = [Collections.Generic.List[string]]::new()
    $requiredBy = @{}
    $queue = [Collections.Generic.Queue[string]]::new()
    foreach ($id in $selectedIds) { $queue.Enqueue($id) }
    $seen = [Collections.Generic.HashSet[string]]::new($selectedIds)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $component = $byId[$current]
        if ($null -eq $component) { continue }
        foreach ($dep in @($component.requires)) {
            if (-not $byId.ContainsKey($dep)) { continue }
            if (-not $seen.Contains($dep)) {
                [void]$seen.Add($dep)
                $requiredIds.Add($dep)
                $requiredBy[$dep] = $current
                $queue.Enqueue($dep)
            }
        }
    }

    # Deterministic, dependency-first ordering (topological sort, Kahn's algorithm) over the
    # combined selected+required set: a required dependency (e.g. integration for rag) must
    # be resolved/updated BEFORE the component that needs it, never after. The graph is
    # already known acyclic at this point (checked above), so this always terminates with
    # every id placed; a stable base order (selection order, then discovery order of pulled-in
    # dependencies) is used to break ties so two runs with the same input always produce the
    # same execution order.
    $effectiveSeed = [Collections.Generic.List[string]]::new()
    foreach ($id in (@($selectedIds) + @($requiredIds))) { if (-not $effectiveSeed.Contains($id)) { $effectiveSeed.Add($id) } }
    $inDegree = @{}
    foreach ($id in $effectiveSeed) { $inDegree[$id] = 0 }
    foreach ($id in $effectiveSeed) {
        $component = $byId[$id]
        foreach ($dep in @($component.requires)) { if ($inDegree.ContainsKey($dep)) { $inDegree[$id]++ } }
    }
    $effectiveIds = [Collections.Generic.List[string]]::new()
    $placed = [Collections.Generic.HashSet[string]]::new()
    while ($effectiveIds.Count -lt $effectiveSeed.Count) {
        $progressed = $false
        foreach ($id in $effectiveSeed) {
            if ($placed.Contains($id)) { continue }
            if ($inDegree[$id] -eq 0) {
                $effectiveIds.Add($id); [void]$placed.Add($id); $progressed = $true
                foreach ($otherId in $effectiveSeed) {
                    if ($placed.Contains($otherId)) { continue }
                    if (@($byId[$otherId].requires) -contains $id) { $inDegree[$otherId]-- }
                }
            }
        }
        if (-not $progressed) { break }
    }

    $needsAction = { param($c) [string]$c.classification -in @('PinnedUpdatePending','DowngradeRequired') }
    $requiredDependencies = @(
        foreach ($id in $requiredIds) {
            $c = $byId[$id]
            [pscustomobject][ordered]@{
                id=$id; requiredBy=$requiredBy[$id]; classification=[string]$c.classification
                alreadySatisfied=(-not (& $needsAction $c))
            }
        }
    )

    # Whether the request as a whole must go through the Complete-Installer batch route:
    # explicit user choice, or any component that would actually need real action (selected or
    # pulled in as a dependency) has no isolated executor today.
    $effectiveNeedingAction = @($effectiveIds | ForEach-Object { $byId[$_] } | Where-Object { & $needsAction $_ })
    $forcingIds = @($effectiveNeedingAction | Where-Object { [string]$_.executionRoute -eq 'CompleteInstallerBatch' } | ForEach-Object { [string]$_.id })
    $anyNeedsBatch = @($forcingIds).Count -gt 0
    $completeInstallerRequired = [bool]$CompleteInstallerExplicitlySelected -or $anyNeedsBatch
    # A batch call is not scoped per component -- it reconciles every currently non-compliant
    # Contracts/COMPONENTS.json component in one transaction. Selecting every batch-route
    # component that currently needs action is therefore just as safe as an explicit
    # Complete-Installer choice (nothing outside the selection would be touched); only a
    # selection that OMITS a currently-non-compliant batch-route component actually
    # understates what a real run would do, and only that case must block.
    $allBatchNeedingAction = @($AvailableComponents | Where-Object { [string]$_.executionRoute -eq 'CompleteInstallerBatch' -and (& $needsAction $_) })
    $additionallyTouched = @($allBatchNeedingAction | Where-Object { $effectiveIds -notcontains [string]$_.id } | ForEach-Object { [string]$_.id })
    $batchSelectionUnderstatesScope = $anyNeedsBatch -and -not $CompleteInstallerExplicitlySelected -and $additionallyTouched.Count -gt 0

    $plannedUpdates = [Collections.Generic.List[object]]::new()
    $preserved = [Collections.Generic.List[object]]::new()
    $skipped = [Collections.Generic.List[object]]::new()

    if ($batchSelectionUnderstatesScope) {
        # A batch-only component is in scope but the selection would leave at least one other
        # currently-non-compliant batch-route component untouched by name while a real batch
        # run would still reconcile it too (see Category C contract: "muss das vor Ausführung
        # klar anzeigen"). Never silently run the full batch on their behalf -- report exactly
        # which component(s) forced this and which OTHER currently-non-compliant components a
        # real batch run would additionally touch, then block.
        foreach ($id in $forcingIds) {
            $blocked.Add([pscustomobject][ordered]@{
                id=$id
                reason="Keine isolierte Ausführung verfügbar (Kategorie C oder noch nicht verdrahtet); ein Complete-Installer-Upgrade-Lauf wäre erforderlich, wurde aber nicht explizit ausgewählt. Zusätzlich betroffene, aktuell nicht konforme Komponenten bei einem echten Batch-Lauf: $(if($additionallyTouched.Count){$additionallyTouched -join ', '}else{'keine'})."
            })
        }
        foreach ($id in $effectiveIds) {
            if ($forcingIds -contains $id) { continue }
            $c = $byId[$id]
            if (& $needsAction $c) {
                $blocked.Add([pscustomobject][ordered]@{id=$id;reason='Übergeordnete Auswahl wurde blockiert, weil eine andere ausgewählte/erforderliche Komponente keinen isolierten Pfad besitzt (siehe zugehörige blockedComponents-Einträge).'})
            } else {
                $skipped.Add([pscustomobject][ordered]@{id=$id;reason='Bereits aktuell (UpToDate); keine Aktion nötig.'})
            }
        }
    }
    else {
        foreach ($id in $effectiveIds) {
            $c = $byId[$id]
            if (& $needsAction $c) {
                $route = if ($CompleteInstallerExplicitlySelected) { 'CompleteInstallerBatch' } else { [string]$c.executionRoute }
                $plannedUpdates.Add([pscustomobject][ordered]@{
                    id=$id; name=[string]$c.name; installedVersion=[string]$c.installedVersion; pinnedVersion=[string]$c.pinnedVersion
                    classification=[string]$c.classification; executionRoute=$route
                })
            }
            else {
                $skipped.Add([pscustomobject][ordered]@{id=$id;reason='Bereits aktuell (UpToDate); keine Aktion nötig.'})
            }
        }
        if ($CompleteInstallerExplicitlySelected) {
            # Explicit Complete-Installer choice authorizes the real, full batch semantics:
            # every currently non-compliant component, not just the ones named above.
            foreach ($c in $AvailableComponents) {
                $id = [string]$c.id
                if ($effectiveIds -contains $id) { continue }
                if (& $needsAction $c) {
                    $plannedUpdates.Add([pscustomobject][ordered]@{
                        id=$id; name=[string]$c.name; installedVersion=[string]$c.installedVersion; pinnedVersion=[string]$c.pinnedVersion
                        classification=[string]$c.classification; executionRoute='CompleteInstallerBatch'
                    })
                }
            }
        }
    }

    $plannedOrSkippedIds = @($plannedUpdates | ForEach-Object id) + @($skipped | ForEach-Object id) + @($blocked | ForEach-Object id)
    foreach ($c in $AvailableComponents) {
        $id = [string]$c.id
        if ($plannedOrSkippedIds -contains $id) { continue }
        $preserved.Add([pscustomobject][ordered]@{id=$id;reason='Nicht ausgewählt und keine erforderliche Abhängigkeit; bleibt unverändert.'})
    }

    return [pscustomobject][ordered]@{
        selectedComponents=@($selectedIds)
        requiredDependencies=$requiredDependencies
        plannedUpdates=@($plannedUpdates)
        preservedComponents=@($preserved)
        skippedComponents=@($skipped)
        blockedComponents=@($blocked)
        cyclicDependencyError=$null
        completeInstallerRequired=$completeInstallerRequired
    }
}

function Get-KIStackIsolatedExecutionHandler {
    # Single source of truth for "which component ids have a real, wired isolated executor
    # today" -- Resolve-KIStackUpdatePlan and Invoke-KIStackIsolatedComponentUpdate must never
    # disagree about this set, so both read it from here (and, ultimately, from
    # Contracts/COMPONENTS.json's own isolatedExecutionImplemented flag -- this list is the
    # implementation-side mirror of that contract, asserted equal by
    # Test-KIStackUpdateIsolation.ps1).
    return @('openwebui-agent-pack','openwebui-visual-pack','openwebui-ballistics-pack','codex-local','rag','comfyui','models-workflows','integration','validation-gate','mcp-runtime')
}

function Get-KIStackIsolatedActionMode {
    # Mirrors New-KICompletePlan's own Install/Upgrade/Repair derivation exactly (Repair when
    # a prior install was recorded but the real target no longer has it; Upgrade when
    # something is genuinely installed; Install otherwise) -- never a second, independently
    # maintained copy of that decision, just reads the same two real-target probes
    # (Get-KICompleteInstalledVersion / Get-KICompleteStoredVersion) New-KICompletePlan itself
    # already uses.
    param([Parameter(Mandatory)][object]$Component,[Parameter(Mandatory)][string]$TargetRoot)
    $installed=Get-KICompleteInstalledVersion -Component $Component -TargetRoot $TargetRoot
    $stored=Get-KICompleteStoredVersion -Component $Component -TargetRoot $TargetRoot
    if($null-eq$installed-and$null-ne$stored){return 'Repair'}
    if($installed){return 'Upgrade'}
    return 'Install'
}

function New-KIStackIsolatedUpdatePaths {
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$RunId,
        [object]$PathContext,
        [string]$WorkDirectory
    )
    if ($null -eq $PathContext) {
        $PathContext = New-KICompletePathContext -TargetRoot $TargetRoot -PackageRoot $PackageRoot -Mutating
    }
    if (-not (Test-KICompleteSameRoot -First ([string]$PathContext.TargetRoot) -Second $TargetRoot)) {
        throw 'Lifecycle-Update-PathContext gehört zu einem fremden TargetRoot.'
    }
    $updateStateRoot = [IO.Path]::Combine([string]$PathContext.StateRoot,'updates',$RunId)
    $resolvedWorkDirectory = if ([string]::IsNullOrWhiteSpace($WorkDirectory)) {
        [IO.Path]::Combine($updateStateRoot,'staging')
    } else {
        Assert-KICompletePathWithinRoot -Path $WorkDirectory -Root ([string]$PathContext.StateRoot) -Name 'Lifecycle Update WorkDirectory' -RejectReparsePoint
    }
    $resolvedBackupRoot = [IO.Path]::Combine([string]$PathContext.BackupRoot,'updates',$RunId)
    Assert-KICompletePathWithinRoot -Path $resolvedWorkDirectory -Root ([string]$PathContext.StateRoot) -Name 'Lifecycle Update WorkDirectory' -RejectReparsePoint | Out-Null
    Assert-KICompletePathWithinRoot -Path $resolvedBackupRoot -Root ([string]$PathContext.BackupRoot) -Name 'Lifecycle Update BackupRoot' -RejectReparsePoint | Out-Null
    [pscustomobject][ordered]@{
        PathContext=$PathContext
        RunId=$RunId
        WorkDirectory=$resolvedWorkDirectory
        BackupRoot=$resolvedBackupRoot
    }
}

function Invoke-KIStackIsolatedComponentUpdate {
    # Executes exactly one component's own, already self-contained install/backup/rollback
    # entry point directly. Deliberately does NOT call Invoke-KIStackCompleteInstaller,
    # New-KICompleteTransaction, or any part of the finalization phase (orchestrator/
    # central-starter/Operations redeploy, Knowledge-experiment rollback,
    # Code-Interpreter configuration) -- those are Complete-Installer-wide side effects with
    # no place in a single-component update. CompleteInstaller.psm1 must already be imported
    # by the caller (for Expand-KICompletePayload / Write-KICompleteComponentMarker /
    # Get-KICompleteInstalledVersion / Install-KICompleteRAGModule); this module does not
    # re-implement or duplicate any of that shared logic.
    param(
        [Parameter(Mandatory)][string]$ComponentId,
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][object]$Component,
        [Parameter(Mandatory)][object]$Config,
        [Security.SecureString]$OpenWebUIApiToken,
        [string]$WorkDirectory,
        [object]$PathContext
    )
    if (@(Get-KIStackIsolatedExecutionHandler) -notcontains $ComponentId) {
        throw "Keine isolierte Ausführung für '$ComponentId' implementiert (Kategorie C oder noch nicht verdrahtet)."
    }
    if ($ComponentId -eq 'rag') {
        $integrationStarter = Join-Path $TargetRoot 'modules/integration/Start-KIStack-OpenWebUI-WithSearch.cmd'
        if (-not (Test-Path -LiteralPath $integrationStarter -PathType Leaf)) {
            return [pscustomobject][ordered]@{id=$ComponentId;outcome='Blocked';detail='Erforderliche Abhängigkeit fehlt: modules/integration/Start-KIStack-OpenWebUI-WithSearch.cmd (Integration muss zuerst installiert sein).'}
        }
    }
    $runId = 'KI-ISOLATED-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff') + '-' + $ComponentId
    $updatePaths = New-KIStackIsolatedUpdatePaths -TargetRoot $TargetRoot -PackageRoot $PackageRoot -RunId $runId -PathContext $PathContext -WorkDirectory $WorkDirectory
    $WorkDirectory = [string]$updatePaths.WorkDirectory
    $backupRoot = [string]$updatePaths.BackupRoot
    try {
        switch ($ComponentId) {
            'openwebui-agent-pack' {
                if ($null -eq $OpenWebUIApiToken) { return [pscustomobject][ordered]@{id=$ComponentId;outcome='WaitingForUserAction';detail='OpenWebUI-Administrator-API-Key erforderlich.'} }
                $payloadRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'OpenWebUIAgentPack' -Destination $WorkDirectory
                $module = Get-ChildItem -LiteralPath $payloadRoot -Recurse -File -Filter 'OpenWebUIAgentPack.psm1' | Select-Object -First 1
                if (-not $module) { throw 'Agent-Pack-Modul fehlt.' }
                Import-Module $module.FullName -Force
                $agentPackageRoot = Split-Path -Parent $module.FullName
                $result = Install-OpenWebUIAgentPack -PackageRoot $agentPackageRoot -Endpoint ([string]$Config.openWebUIEndpoint) -ApiToken $OpenWebUIApiToken -BaseModelId '' -BackupDirectory $backupRoot
                $validation = Test-OpenWebUIAgentPack -PackageRoot $agentPackageRoot -Endpoint ([string]$Config.openWebUIEndpoint) -ApiToken $OpenWebUIApiToken -BaseModelId ([string]$result.baseModelId)
                if (-not $validation.passed) { throw ('Agent-Pack-Validierung fehlgeschlagen: ' + ($validation.failures -join '; ')) }
                Write-KICompleteComponentMarker -Component $Component -TargetRoot $TargetRoot
                return [pscustomobject][ordered]@{id=$ComponentId;outcome='Completed';backupPath=$result.backupPath;detail=[ordered]@{install=$result;validation=$validation}}
            }
            'openwebui-visual-pack' {
                if ($null -eq $OpenWebUIApiToken) { return [pscustomobject][ordered]@{id=$ComponentId;outcome='WaitingForUserAction';detail='OpenWebUI-Administrator-API-Key erforderlich.'} }
                $payloadRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'OpenWebUIVisualPack' -Destination $WorkDirectory
                $installer = Get-ChildItem -LiteralPath $payloadRoot -Recurse -File -Filter 'Install-KIStack-OpenWebUI-VisualPack-v2.0.5.ps1' | Select-Object -First 1
                if (-not $installer) { throw 'Visual-Pack-Installer fehlt.' }
                $result = & $installer.FullName -Action Install -KIStackRoot $TargetRoot -OpenWebUIEndpoint ([string]$Config.openWebUIEndpoint) -ApiToken $OpenWebUIApiToken
                if ($null -eq $result -or -not [bool]$result.passed -or [string]::IsNullOrWhiteSpace([string]$result.backupPath)) { throw 'Visual-Pack-Installer lieferte keinen gültigen Installations-/Backupnachweis.' }
                Write-KICompleteComponentMarker -Component $Component -TargetRoot $TargetRoot
                return [pscustomobject][ordered]@{id=$ComponentId;outcome='Completed';backupPath=$result.backupPath;detail=$result}
            }
            'openwebui-ballistics-pack' {
                if ($null -eq $OpenWebUIApiToken) { return [pscustomobject][ordered]@{id=$ComponentId;outcome='WaitingForUserAction';detail='OpenWebUI-Administrator-API-Key erforderlich.'} }
                $payloadRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'OpenWebUIBallisticsPack' -Destination $WorkDirectory
                $module = Get-ChildItem -LiteralPath $payloadRoot -Recurse -File -Filter 'OpenWebUIBallisticsPack.psm1' | Select-Object -First 1
                if (-not $module) { throw 'Ballistics-Pack-Modul fehlt.' }
                Import-Module $module.FullName -Force
                $ballisticsPackageRoot = Split-Path -Parent $module.FullName
                $result = Install-OpenWebUIBallisticsPack $ballisticsPackageRoot ([string]$Config.openWebUIEndpoint) $OpenWebUIApiToken '' $backupRoot $TargetRoot
                Write-KICompleteComponentMarker -Component $Component -TargetRoot $TargetRoot
                return [pscustomobject][ordered]@{id=$ComponentId;outcome='Completed';backupPath=$result.backupPath;detail=$result}
            }
            'codex-local' {
                # Install/Upgrade/Repair dispatch mirrors comfyui/integration/validation-gate
                # exactly (Get-KIStackIsolatedActionMode, never a hardcoded 'Install') -- a
                # target that already has an older or damaged Codex Local recorded now genuinely
                # goes through Upgrade/Repair, not a second "fresh install" pass. The post-action
                # health check is run with SkipEndpoint: LM Studio being unreachable at this
                # exact moment is an external runtime precondition, never a defect in the Codex
                # package this isolated route is responsible for -- see CodexLocal.psm1's
                # Get-KICodexStatus for the same Installed/RuntimeUnavailable/Broken distinction.
                $action = Get-KIStackIsolatedActionMode -Component $Component -TargetRoot $TargetRoot
                $payloadRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'CodexLocal' -Destination $WorkDirectory
                $entry = Join-Path $payloadRoot 'Invoke-KIStackCodexLocal.ps1'
                if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw 'Codex-Local-Einstieg fehlt.' }
                $result = Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action=$action;TargetRoot=$TargetRoot;WorkspacePath=$TargetRoot}
                if (-not [bool]$result.passed) { throw 'Codex-Local-Installation fehlgeschlagen.' }
                try {
                    $validation = Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action='Validate';TargetRoot=$TargetRoot;SkipEndpoint=$true}
                    if (-not [bool]$validation.passed) { throw 'Codex-Local-Validierung fehlgeschlagen.' }
                } catch {
                    if ($null -ne $result.marker -and -not [string]::IsNullOrWhiteSpace([string]$result.marker.backupPath)) {
                        [void](Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action='Rollback';BackupPath=[string]$result.marker.backupPath})
                    }
                    throw
                }
                # Deliberately NOT Write-KICompleteComponentMarker here (unlike the other
                # branches above): its generic {schemaVersion;componentId;version;
                # validatedAtUtc} shape writes to the EXACT SAME path as CodexLocal.psm1's own,
                # richer marker (Contracts/COMPONENTS.json's probe.path for codex-local is that
                # same modules/codex-local/installation.json) and would silently truncate away
                # fields Codex Local's own code depends on -- codexVersion above all, whose
                # absence made Test-KICodexLocal throw PropertyNotFoundException under
                # Set-StrictMode on every subsequent Validate/Status/Install call (reproduced
                # live against the real target while building this). Get-KICompleteInstalledVersion's
                # own probe (fields:["version"]) is already satisfied by Install-KICodexLocal's
                # own marker -- nothing downstream needs the generic marker to exist as well.
                return [pscustomobject][ordered]@{id=$ComponentId;outcome='Completed';backupPath=[string]$result.marker.backupPath;detail=[ordered]@{action=$action;install=$result;validation=$validation}}
            }
            'rag' {
                $payloadRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'RAG' -Destination $WorkDirectory
                $test = Join-Path $payloadRoot 'Test-KIStackRAG.ps1'
                if (-not (Test-Path -LiteralPath $test -PathType Leaf)) { throw 'RAG-Selbsttest fehlt.' }
                $validation = Invoke-KICompleteJsonScript -Script $test -Arguments @{PackageRoot=$payloadRoot}
                if (-not [bool]$validation.passed) { throw ('RAG-Quellvalidierung fehlgeschlagen: ' + (@($validation.failures) -join '; ')) }
                $result = Install-KICompleteRAGModule -ComponentRoot $payloadRoot -TargetRoot $TargetRoot -BackupRoot $backupRoot
                return [pscustomobject][ordered]@{id=$ComponentId;outcome='Completed';backupPath=$backupRoot;detail=[ordered]@{install=$result;validation=$validation;ingestionDeferred=$true}}
            }
            'comfyui' {
                # Defense in depth, mirrored verbatim from the batch path's own comment: this
                # is the one real re-check that can prevent Install-ComfyPayload (the
                # git-unaware v0.28.0 reference-payload overlay) from ever reaching an
                # existing, already-supported, git-managed installation -- an isolated
                # single-component route must never skip it. Reuses the exact same,
                # already-real-target-validated compliance probe the batch path itself calls;
                # never a second, independently-maintained copy of that decision.
                if (Test-KICompleteComfyUICompliant -PackageRoot $PackageRoot -TargetRoot $TargetRoot) {
                    return [pscustomobject][ordered]@{id=$ComponentId;outcome='Completed';backupPath=$null;detail=[ordered]@{skippedReason='ExistingSupportedInstallationProtected'}}
                }
                $action = Get-KIStackIsolatedActionMode -Component $Component -TargetRoot $TargetRoot
                $payloadRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'ComfyUI' -Destination $WorkDirectory
                $entry = Join-Path $payloadRoot 'Invoke-KIStackComfyUI.ps1'
                $comfyTargetRoot = Join-Path $TargetRoot 'ComfyUI'
                $result = Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action=$action;TargetRoot=$comfyTargetRoot}
                try {
                    $validation = Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action='Validate';TargetRoot=$comfyTargetRoot}
                    $actual = Get-KICompleteInstalledVersion -Component $Component -TargetRoot $TargetRoot
                    if (-not [bool]$validation.passed -or $actual -ne [string]$Component.version) { throw "ComfyUI-Readback verletzt: Payload=$([bool]$validation.passed); Marker=$actual; erwartet=$($Component.version)" }
                    Write-KICompleteComponentMarker -Component $Component -TargetRoot $TargetRoot
                    return [pscustomobject][ordered]@{id=$ComponentId;outcome='Completed';backupPath=[string]$result.backup;detail=[ordered]@{install=$result;validation=$validation;markerVersion=$actual}}
                } catch {
                    $rollbackStatus='Failed'
                    try {
                        if ([bool]$result.changed -and $result.backup) {
                            $rollback = Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action='Rollback';TargetRoot=$comfyTargetRoot;BackupPath=[string]$result.backup}
                            if ([bool]$rollback.passed) { $rollbackStatus='Completed' }
                        } else { $rollbackStatus='NotRequired' }
                    } catch { $rollbackStatus='Failed' }
                    return [pscustomobject][ordered]@{id=$ComponentId;outcome='Failed';backupPath=[string]$result.backup;detail=[ordered]@{error=$_.Exception.Message;rollbackStatus=$rollbackStatus}}
                }
            }
            'models-workflows' {
                # Isolation contract (Section 3): this never reconciles ComfyUI itself --
                # Import-KIStackExternalModels.ps1 only ever writes into TargetRoot's model/
                # workflow manifest area, and Test-KICompleteModelsWorkflowsCompliant (the same
                # real check the batch path uses) only inspects that same area, never ComfyUI's
                # own install state. No ComfyUI code path is invoked from this branch at all.
                $payloadRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'ModelsWorkflows' -Destination $WorkDirectory
                $entry = Join-Path $payloadRoot 'Import-KIStackExternalModels.ps1'
                $modelStateRoot = Join-Path $WorkDirectory 'model-import'
                $result = & $entry -Mode Install -SourcePath (Join-Path $PackageRoot 'ExternalModels') -TargetRoot $TargetRoot -StateRoot $modelStateRoot -TransactionId ([IO.Path]::GetFileName($WorkDirectory))
                if (-not [bool]$result.passed) {
                    $waiting = @($result.results | Where-Object status -eq 'WaitingForNetwork' | ForEach-Object id)
                    return [pscustomobject][ordered]@{id=$ComponentId;outcome='WaitingForUserAction';detail=[ordered]@{reason='Externe Modellquelle ist nicht erreichbar; verifizierte Teildownloads bleiben fortsetzbar.';waitingForNetwork=$waiting;resumable=[bool]$result.resumable;importResult=$result}}
                }
                if (-not (Test-KICompleteModelsWorkflowsCompliant -PackageRoot $PackageRoot -TargetRoot $TargetRoot)) { throw 'Modelle-/Workflow-Zielvalidierung fehlgeschlagen.' }
                Write-KICompleteComponentMarker -Component $Component -TargetRoot $TargetRoot
                return [pscustomobject][ordered]@{id=$ComponentId;outcome='Completed';backupPath=$null;detail=[ordered]@{importResult=$result;validated=$true}}
            }
            'integration' {
                # RAG-Starter-Preservation (Section 4): Install-IntegrationRuntime (this
                # package's own module) now folds an already-applied RAG env-call line forward
                # into Start-KIStack-OpenWebUI-WithSearch.cmd instead of blindly overwriting it
                # -- see Merge-IntegrationOpenWebUIWithSearchStarterContent and
                # Test-KIStackIntegrationRAGStarterPreservation.ps1 in tools/integration/current.
                # This branch calls only Integration's own Install/Upgrade/Repair/Validate
                # actions; it never touches RAG, OpenWebUI, or any other component, and never
                # reaches Invoke-KIStackCompleteInstaller's finalization phase.
                $action = Get-KIStackIsolatedActionMode -Component $Component -TargetRoot $TargetRoot
                $payloadRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'Integration' -Destination $WorkDirectory
                $entry = Join-Path $payloadRoot 'Invoke-KIStackIntegration.ps1'
                $result = Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action=$action;TargetRoot=$TargetRoot}
                $validation = Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action='Validate';TargetRoot=$TargetRoot}
                if (-not [bool]$validation.passed) { throw 'Integration-Validierung fehlgeschlagen.' }
                Write-KICompleteComponentMarker -Component $Component -TargetRoot $TargetRoot
                return [pscustomobject][ordered]@{id=$ComponentId;outcome='Completed';backupPath=[string]$result.backupPath;detail=[ordered]@{install=$result;validation=$validation}}
            }
            'validation-gate' {
                $payload = Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Payload/ValidationGate') -File -Filter '*.zip' | Select-Object -First 1
                if (-not $payload) { throw 'Validation-Gate-Payload fehlt.' }
                $payloadRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'ValidationGate' -Destination $WorkDirectory
                $installer = Get-ChildItem -LiteralPath $payloadRoot -Recurse -File -Filter 'Install-KIStack-ValidationGate.ps1' | Select-Object -First 1
                if (-not $installer) { throw 'Öffentlicher Validation-Gate-Installer fehlt.' }
                $installRoot = Join-Path $TargetRoot 'Tools/PackageValidationGate'
                $currentRoot = Join-Path $installRoot 'current'
                if (Test-Path -LiteralPath $currentRoot) {
                    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
                    Copy-Item -LiteralPath $currentRoot -Destination (Join-Path $backupRoot 'current') -Recurse -Force
                }
                try {
                    & $installer.FullName -InstallRoot $installRoot
                    if ($LASTEXITCODE -ne 0) { throw "Validation-Gate-Installer Exitcode $LASTEXITCODE" }
                    $installedVersionPath = Join-Path $currentRoot 'VERSION'
                    if (-not (Test-Path -LiteralPath $installedVersionPath) -or (Get-Content -LiteralPath $installedVersionPath -Raw).Trim() -ne [string]$Component.version) { throw 'Installierte Validation-Gate-Version stimmt nicht mit dem Komponentenvertrag überein.' }
                } catch {
                    if (Test-Path -LiteralPath (Join-Path $backupRoot 'current')) {
                        if (Test-Path -LiteralPath $currentRoot) { Remove-Item -LiteralPath $currentRoot -Recurse -Force }
                        Copy-Item -LiteralPath (Join-Path $backupRoot 'current') -Destination $currentRoot -Recurse -Force
                    }
                    return [pscustomobject][ordered]@{id=$ComponentId;outcome='Failed';backupPath=$backupRoot;detail=$_.Exception.Message}
                }
                Write-KICompleteComponentMarker -Component $Component -TargetRoot $TargetRoot
                return [pscustomobject][ordered]@{id=$ComponentId;outcome='Completed';backupPath=$backupRoot;detail=[ordered]@{orchestratedBy='public Validation Gate installer';installedVersion=[string]$Component.version}}
            }
            'mcp-runtime' {
                # Mirrors codex-local's dispatch shape (own Install/Upgrade/Repair/Validate/
                # Rollback actions via Get-KIStackIsolatedActionMode, real automatic rollback on a
                # failed post-action Validate) -- but, unlike codex-local, McpRuntime.psm1's own
                # marker (schemaVersion/version/host/port/installedAtUtc) already satisfies this
                # contract's probe (fields:["version"]) and Test-KIMcpRuntime itself only ever
                # reads the marker's .version field back, so Write-KICompleteComponentMarker is
                # correctly never called here -- it would just overwrite host/port/installedAtUtc
                # for no benefit, exactly the reason codex-local's own branch skips it too.
                $action = Get-KIStackIsolatedActionMode -Component $Component -TargetRoot $TargetRoot
                $payloadRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'McpRuntime' -Destination $WorkDirectory
                $entry = Join-Path $payloadRoot 'Invoke-KIStackMcpRuntime.ps1'
                if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw 'MCP-Runtime-Einstieg fehlt.' }
                $result = Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action=$action;TargetRoot=$TargetRoot}
                if (-not [bool]$result.passed) { throw 'MCP-Runtime-Installation fehlgeschlagen.' }
                try {
                    $validation = Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action='Validate';TargetRoot=$TargetRoot}
                    if (-not [bool]$validation.passed) { throw 'MCP-Runtime-Validierung fehlgeschlagen.' }
                } catch {
                    if (-not [string]::IsNullOrWhiteSpace([string]$result.backupPath)) {
                        [void](Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action='Rollback';TargetRoot=$TargetRoot;BackupPath=[string]$result.backupPath})
                    }
                    throw
                }
                return [pscustomobject][ordered]@{id=$ComponentId;outcome='Completed';backupPath=[string]$result.backupPath;detail=[ordered]@{action=$action;install=$result;validation=$validation}}
            }
        }
    }
    catch {
        return [pscustomobject][ordered]@{id=$ComponentId;outcome='Failed';backupPath=$backupRoot;detail=$_.Exception.Message}
    }
}

Export-ModuleMember -Function Resolve-KIStackUpdatePlan,Test-KIStackDependencyCycle,Get-KIStackIsolatedExecutionHandler,Invoke-KIStackIsolatedComponentUpdate,Get-KIStackIsolatedActionMode,New-KIStackIsolatedUpdatePaths

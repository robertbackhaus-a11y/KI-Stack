Set-StrictMode -Version Latest

# KI-Stack Desktop Control -- productive policy/wrapper layer over `winapp ui` (Windows UI
# Automation), for KI-Stack 2.18.
#
# Architecture (docs: LOCAL-CONTROL-CONTRACT.md §18 hands GUI/UIA control to 2.18; the
# desktop-control spike scripts/Test-KIStackDesktopControlSpike.ps1 recommends exactly this
# shape):
#
#   Open WebUI / Agent
#     -> existing MCP Runtime (unchanged, server:mcp:ki-stack-mcp-runtime)
#     -> Desktop Control Wrapper (this component)
#         -> Policy / Validation           (DesktopControl.Policy.psm1)
#         -> central WinApp Resolver       (Vendor/WinApp.Resolver.psm1, from tools/winapp/current)
#         -> winapp ui                     (semantic UIA verbs only)
#         -> Windows UI Automation
#
# The wrapper ENFORCES, for every request:
#   Resolve -> Validate -> Act -> Re-observe -> Verify
#
# The LLM never runs winapp directly. Only the ten semantic UIA operations below are exposed;
# raw send-input / global keyboard injection / system hotkeys / coordinate clicks / arbitrary
# drag/touch/pen / raw winapp command execution are NOT part of the surface.
#
# Introduces no runtime, no port, no credential. State lives under
#   <TargetRoot>\state\desktop-control\  (logs\actions\<date>.jsonl audit trail + evidence\)
# mirroring the jsonl-under-state audit convention LOCAL-CONTROL-CONTRACT.md §17 already
# establishes for run_command -- not a second parallel log stack, the same shape.

# --- Config / paths -------------------------------------------------------------------------

function Get-KIDesktopControlConfig {
    param([string]$PackageRoot = $PSScriptRoot)
    Get-Content -LiteralPath (Join-Path $PackageRoot 'Config/desktop-control.config.json') -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 50
}

function Get-KIDesktopControlPaths {
    param([string]$TargetRoot = 'C:\KI-Stack', [object]$Config)
    if ($null -eq $Config) { $Config = Get-KIDesktopControlConfig }
    $root = [IO.Path]::GetFullPath($TargetRoot)
    [pscustomobject]@{
        targetRoot   = $root
        stateRoot    = [IO.Path]::Combine($root, 'state', 'desktop-control')
        auditRoot    = [IO.Path]::Combine($root, ($Config.audit.relativeRoot -replace '/', '\'))
        evidenceRoot = [IO.Path]::Combine($root, ($Config.evidence.relativeRoot -replace '/', '\'))
    }
}

function New-KIDesktopControlDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

# --- Central winapp resolution (production: central path only, no fallback) ------------------

function Resolve-KIDesktopControlWinApp {
    # Desktop Control resolves winapp EXCLUSIVELY through the central KI-Stack WinApp resolver
    # (tools/winapp/current/WinApp.Resolver.psm1, vendored verbatim as Vendor/WinApp.Resolver.psm1).
    # It NEVER passes -AllowDevelopmentFallback and NEVER consults Get-Command / where.exe /
    # PATH / WindowsApps / WinGet itself. If winapp is not centrally provisioned, this fails
    # closed with the resolver's own actionable error.
    param(
        [string]$PackageRoot = $PSScriptRoot,
        [string]$KIStackRoot = 'C:\KI-Stack',
        [object]$Config,
        # INTERNAL TEST SEAM ONLY (Test-KIStackDesktopControl.ps1 has no runnable winapp.exe).
        # Forwarded to the resolver's own documented -VersionProbeOverride seam. NEVER wired to
        # Invoke-KIStackDesktopControl.ps1 and never used by any real caller.
        [scriptblock]$Internal_VersionProbeOverride
    )
    if ($null -eq $Config) { $Config = Get-KIDesktopControlConfig -PackageRoot $PackageRoot }
    if ([bool]$Config.winappResolver.allowDevelopmentFallback) {
        throw 'desktop-control.config.json winappResolver.allowDevelopmentFallback ist true -- Produktion verbietet den Development-Fallback.'
    }
    $module = Join-Path $PackageRoot ([string]$Config.winappResolver.vendoredModule)
    Import-Module $module -Force -ErrorAction Stop
    $resolverArgs = @{ KIStackRoot = $KIStackRoot; ExpectedVersion = [string]$Config.winappResolver.expectedWinAppVersion }
    if ($null -ne $Internal_VersionProbeOverride) { $resolverArgs.VersionProbeOverride = $Internal_VersionProbeOverride }
    # The development/test fallback switch is deliberately NEVER added to $resolverArgs.
    $resolved = Resolve-KIStackWinApp @resolverArgs
    if ([string]$resolved.resolutionMethod -ne 'central-kistack-tools') {
        throw "WinApp-Resolver lieferte eine nicht-produktive Auflösungsmethode: '$($resolved.resolutionMethod)'."
    }
    $resolved
}

# --- winapp CLI invocation (JSON) ----------------------------------------------------------

function ConvertTo-KIDesktopControlPlainText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value -replace "`e\[[0-?]*[ -/]*[@-~]", '')
}

function New-KIDesktopControlWinAppInvoker {
    # Returns a scriptblock: & $invoker @('ui','list-windows',...) -> { success, exitCode, json,
    # stdout, stderr }. --json is always appended. This is the ONLY place winapp is executed.
    param([Parameter(Mandatory)][string]$ExecutablePath, [int]$TimeoutMs = 10000)
    {
        param([string[]]$WinAppArgs)
        $effective = [System.Collections.Generic.List[string]]::new()
        foreach ($a in $WinAppArgs) { $effective.Add([string]$a) | Out-Null }
        if ($effective -notcontains '--json') { $effective.Add('--json') | Out-Null }
        try {
            $raw = @(& $ExecutablePath @($effective.ToArray()) 2>&1)
            $exit = $LASTEXITCODE
            $global:LASTEXITCODE = 0
            $stdout = ConvertTo-KIDesktopControlPlainText (($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n")
            $stderr = ConvertTo-KIDesktopControlPlainText (($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n")
            $json = $null; $parseError = $null
            if (-not [string]::IsNullOrWhiteSpace($stdout)) {
                try { $json = $stdout | ConvertFrom-Json -Depth 100 } catch { $parseError = $_.Exception.Message }
            }
            [pscustomobject]@{ success = ($exit -eq 0 -and $null -ne $json); exitCode = $exit; json = $json; stdout = $stdout; stderr = $stderr; parseError = $parseError; args = @($effective) }
        } catch {
            [pscustomobject]@{ success = $false; exitCode = $null; json = $null; stdout = ''; stderr = $_.Exception.Message; parseError = $null; args = @($effective) }
        }
    }.GetNewClosure()
}

function Get-KIDesktopControlObjectValue {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($n in $Names) { $p = $Object.PSObject.Properties[$n]; if ($null -ne $p -and $null -ne $p.Value) { return $p.Value } }
    return $null
}

# --- Observation primitives (read-only) ---------------------------------------------------

function Get-KIDesktopControlWindows {
    param([Parameter(Mandatory)][scriptblock]$Invoker, [string]$Application)
    $args = @('ui', 'list-windows')
    if (-not [string]::IsNullOrWhiteSpace($Application)) { $args += @('-a', $Application) }
    $r = & $Invoker $args
    if ($null -eq $r.json) { return @() }
    $items = if ($r.json -is [System.Collections.IEnumerable] -and $r.json -isnot [string]) { @($r.json | ForEach-Object { $_ }) } else { @(Get-KIDesktopControlObjectValue $r.json @('windows', 'Windows', 'items')) }
    @($items | Where-Object {
        $hwnd = Get-KIDesktopControlObjectValue $_ @('hwnd', 'Hwnd', 'handle')
        $w = Get-KIDesktopControlObjectValue $_ @('width', 'Width'); $h = Get-KIDesktopControlObjectValue $_ @('height', 'Height')
        $null -ne $hwnd
    })
}

function Resolve-KIDesktopControlWindow {
    # Fresh, unambiguous window resolution. Returns { window, matchCount, all }. Never a cached
    # snapshot -- always calls list-windows now.
    param(
        [Parameter(Mandatory)][scriptblock]$Invoker,
        [string]$Application,
        [AllowNull()][object]$Hwnd,
        [string]$TitlePattern
    )
    $all = @(Get-KIDesktopControlWindows -Invoker $Invoker -Application $Application)
    $matches = @($all)
    if ($null -ne $Hwnd) {
        $matches = @($matches | Where-Object { [string](Get-KIDesktopControlObjectValue $_ @('hwnd', 'Hwnd', 'handle')) -eq [string]$Hwnd })
    }
    if (-not [string]::IsNullOrWhiteSpace($TitlePattern)) {
        $matches = @($matches | Where-Object { ([string](Get-KIDesktopControlObjectValue $_ @('title', 'Title'))) -match $TitlePattern })
    }
    [pscustomobject]@{ window = $(if ($matches.Count -eq 1) { $matches[0] } else { $null }); matchCount = $matches.Count; all = $all }
}

function Get-KIDesktopControlUiTree {
    param([Parameter(Mandatory)][scriptblock]$Invoker, [Parameter(Mandatory)][string]$Hwnd, [int]$Depth = 8)
    $r = & $Invoker @('ui', 'inspect', '-w', [string]$Hwnd, '--depth', [string]$Depth)
    if ($null -eq $r.json) { return $null }
    $windows = @(Get-KIDesktopControlObjectValue $r.json @('windows', 'Windows'))
    if ($windows.Count -gt 0) { return $windows[0] }
    return $r.json
}

function Get-KIDesktopControlTreeElements {
    param([AllowNull()][object]$Node)
    if ($null -eq $Node) { return @() }
    $found = [System.Collections.Generic.List[object]]::new()
    function Visit { param([object]$Item)
        if ($null -eq $Item) { return }
        $found.Add($Item) | Out-Null
        foreach ($child in @(Get-KIDesktopControlObjectValue $Item @('children', 'Children', 'elements', 'Elements'))) { Visit $child }
    }
    foreach ($root in @(Get-KIDesktopControlObjectValue $Node @('elements', 'Elements', 'children', 'Children'))) { Visit $root }
    if ($found.Count -eq 0 -and $null -ne (Get-KIDesktopControlObjectValue $Node @('controlType', 'ControlType', 'type', 'Type'))) { Visit $Node }
    @($found)
}

function Find-KIDesktopControlElements {
    # Identity-based match against the CURRENT tree. Returns all matches (caller enforces
    # uniqueness). Matches on automationId / name / controlType / className -- a bare selector is
    # accepted only as a last-resort transport key, never as the sole identity (see policy).
    param(
        [Parameter(Mandatory)][object]$Tree,
        [string]$AutomationId,
        [string]$Name,
        [string]$ControlType,
        [string]$ClassName,
        [string]$Selector
    )
    $elements = @(Get-KIDesktopControlTreeElements $Tree)
    $anyDurable = (-not [string]::IsNullOrWhiteSpace($AutomationId)) -or (-not [string]::IsNullOrWhiteSpace($Name)) -or (-not [string]::IsNullOrWhiteSpace($ControlType)) -or (-not [string]::IsNullOrWhiteSpace($ClassName))
    @($elements | Where-Object {
        $aid = [string](Get-KIDesktopControlObjectValue $_ @('automationId', 'AutomationId'))
        $nm = [string](Get-KIDesktopControlObjectValue $_ @('name', 'Name'))
        $ct = [string](Get-KIDesktopControlObjectValue $_ @('controlType', 'ControlType', 'type', 'Type'))
        $cn = [string](Get-KIDesktopControlObjectValue $_ @('className', 'ClassName'))
        $sel = [string](Get-KIDesktopControlObjectValue $_ @('selector', 'Selector', 'elementId', 'ElementId'))
        $m = $true
        if (-not [string]::IsNullOrWhiteSpace($AutomationId)) { $m = $m -and ($aid -eq $AutomationId) }
        if (-not [string]::IsNullOrWhiteSpace($Name)) { $m = $m -and ($nm -eq $Name) }
        if (-not [string]::IsNullOrWhiteSpace($ControlType)) { $m = $m -and ($ct -eq $ControlType) }
        if (-not [string]::IsNullOrWhiteSpace($ClassName)) { $m = $m -and ($cn -eq $ClassName) }
        if (-not $anyDurable -and -not [string]::IsNullOrWhiteSpace($Selector)) { $m = ($sel -eq $Selector) }
        $m
    })
}

function Get-KIDesktopControlElementProperties {
    param([Parameter(Mandatory)][scriptblock]$Invoker, [Parameter(Mandatory)][string]$Hwnd, [Parameter(Mandatory)][object]$Element)
    $selector = [string](Get-KIDesktopControlObjectValue $Element @('selector', 'Selector', 'automationId', 'AutomationId', 'elementId', 'ElementId'))
    if ([string]::IsNullOrWhiteSpace($selector)) { return $null }
    $r = & $Invoker @('ui', 'get-property', $selector, '-w', [string]$Hwnd)
    return $r.json
}

function Get-KIDesktopControlLiveProcess {
    # Test seam: overridable so the process-identity check can be exercised without a real PID.
    param([AllowNull()][object]$ProcessId, [scriptblock]$Override)
    if ($null -ne $Override) { return (& $Override $ProcessId) }
    if ($null -eq $ProcessId) { return $null }
    try { $p = Get-Process -Id ([int]$ProcessId) -ErrorAction Stop; return [pscustomobject]@{ id = $p.Id; name = $p.ProcessName } } catch { return $null }
}

# --- Evidence + audit -------------------------------------------------------------------

function Save-KIDesktopControlEvidence {
    param([Parameter(Mandatory)][scriptblock]$Invoker, [Parameter(Mandatory)][string]$Hwnd, [Parameter(Mandatory)][string]$EvidenceRoot, [string]$Label = 'observed')
    New-KIDesktopControlDirectory $EvidenceRoot
    $safe = ($Label -replace '[^A-Za-z0-9_.-]', '_')
    $path = Join-Path $EvidenceRoot ("{0}-{1}.png" -f $safe, (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
    $r = & $Invoker @('ui', 'screenshot', '-w', [string]$Hwnd, '-o', $path)
    [pscustomobject]@{ type = 'screenshot'; success = (Test-Path -LiteralPath $path -PathType Leaf); path = $path; note = $r.stderr }
}

function Write-KIDesktopControlAudit {
    # Append-only JSONL, one record per operation, under <TargetRoot>\state\desktop-control\
    # logs\actions\<yyyy-MM-dd>.jsonl -- the same jsonl-under-state audit shape
    # LOCAL-CONTROL-CONTRACT.md §17 uses for run_command. Returns the record path.
    param([Parameter(Mandatory)][object]$Record, [Parameter(Mandatory)][string]$AuditRoot)
    New-KIDesktopControlDirectory $AuditRoot
    $file = Join-Path $AuditRoot ((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd') + '.jsonl')
    $line = ($Record | ConvertTo-Json -Depth 30 -Compress)
    [IO.File]::AppendAllText($file, $line + "`n", [Text.UTF8Encoding]::new($false))
    $file
}

# --- Postconditions (independent verification of a mutating action) --------------------

function Test-KIDesktopControlPostcondition {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Condition, [int]$TimeoutMs = 10000, [int]$PollMs = 250)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $attempts = 0; $last = $null
    do {
        $attempts++
        try { $last = & $Condition } catch { $last = [pscustomobject]@{ proven = $false; detail = $_.Exception.Message } }
        $proven = if ($last -is [bool]) { $last } else { [bool](Get-KIDesktopControlObjectValue $last @('proven', 'Proven', 'success', 'Success')) }
        if ($proven) { return [pscustomobject]@{ proven = $true; attempts = $attempts; name = $Name; detail = (Get-KIDesktopControlObjectValue $last @('detail', 'Detail')) } }
        Start-Sleep -Milliseconds $PollMs
    } while ((Get-Date) -lt $deadline)
    [pscustomobject]@{ proven = $false; attempts = $attempts; name = $Name; detail = ("nicht bewiesen; letzte Beobachtung: " + (($last | Out-String).Trim())) }
}

# --- The orchestrator: Resolve -> Validate -> Act -> Re-observe -> Verify --------------

$script:KIDesktopControlOperations = @(
    'list_windows', 'inspect_window', 'find_element', 'get_properties', 'get_value',
    'screenshot', 'wait_for', 'set_value', 'invoke', 'focus', 'scroll_into_view', 'scroll'
)

function New-KIDesktopControlResult {
    param([string]$Operation, [string]$Class, [bool]$Success, [string]$Status, [hashtable]$Extra = @{})
    $r = [ordered]@{
        schemaVersion = '1.0'
        timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        operation = $Operation
        mode = $Class
        success = $Success
        status = $Status
    }
    foreach ($k in $Extra.Keys) { $r[$k] = $Extra[$k] }
    [pscustomobject]$r
}

function Invoke-KIDesktopControlOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [object]$Request = @{},
        [string]$PackageRoot = $PSScriptRoot,
        [string]$TargetRoot = 'C:\KI-Stack',
        [string]$KIStackRoot,
        [object]$Config,
        [object]$Policy,
        # INTERNAL TEST SEAMS ONLY -- never wired to Invoke-KIStackDesktopControl.ps1, never used
        # by any real caller. See Test-KIStackDesktopControl.ps1.
        [scriptblock]$Internal_WinAppInvokerOverride,
        [object]$Internal_ResolvedWinApp,
        [scriptblock]$Internal_VersionProbeOverride,
        [scriptblock]$Internal_LiveProcessOverride,
        [switch]$Internal_SkipAudit
    )
    if ($null -eq $Config) { $Config = Get-KIDesktopControlConfig -PackageRoot $PackageRoot }
    if ($null -eq $Policy) { $Policy = Get-KIDesktopControlPolicy -PackageRoot $PackageRoot }
    # TargetRoot-parametric: KI-Stack root follows TargetRoot unless given explicitly.
    if ([string]::IsNullOrWhiteSpace($KIStackRoot)) { $KIStackRoot = $TargetRoot }
    if ($Request -is [string]) { $Request = ($Request | ConvertFrom-Json -Depth 30) }
    if ($null -eq $Request) { $Request = [pscustomobject]@{} }
    $paths = Get-KIDesktopControlPaths -TargetRoot $TargetRoot -Config $Config

    $req = { param($n, $d = $null) $p = $Request.PSObject.Properties[$n]; if ($null -ne $p -and $null -ne $p.Value) { $p.Value } else { $d } }

    $audit = [ordered]@{
        timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        operation = $Operation
        targetHwnd = (& $req 'hwnd')
        process = $null
        windowTitle = $null
        elementIdentity = $null
        policyResult = $null
        actionResult = $null
        postconditionResult = $null
        winappExitCode = $null
        evidencePath = $null
        blockedReason = $null
    }
    $prop = { param($obj, [string]$n) if ($null -eq $obj) { return $null }; $p = $obj.PSObject.Properties[$n]; if ($null -ne $p) { $p.Value } else { $null } }
    $finish = {
        param([object]$Result)
        $audit.policyResult = & $prop $Result 'policy'
        $audit.actionResult = & $prop $Result 'action'
        $audit.postconditionResult = & $prop $Result 'postcondition'
        $audit.blockedReason = & $prop $Result 'blockedReason'
        $ev = & $prop $Result 'evidence'
        if ($null -ne $ev -and @($ev).Count -gt 0) { $audit.evidencePath = (& $prop (@($ev)[0]) 'path') }
        $act = & $prop $Result 'action'
        if ($null -ne $act) { $audit.winappExitCode = (& $prop $act 'exitCode') }
        if (-not $Internal_SkipAudit) {
            try { $recPath = Write-KIDesktopControlAudit -Record ([pscustomobject]$audit) -AuditRoot $paths.auditRoot } catch { $recPath = "audit-write-failed: $($_.Exception.Message)" }
        } else { $recPath = 'skipped' }
        $Result | Add-Member -NotePropertyName audit -NotePropertyValue ([pscustomobject]@{ recordPath = $recPath }) -Force
        $Result
    }

    # ---- classify ----
    $class = Get-KIDesktopControlOperationClass -Operation $Operation -Policy $Policy -Config $Config
    if ($class -eq 'rejected') {
        $reason = if ((@($Policy.actionClassification.neverExposed) -contains $Operation)) {
            "Operation '$Operation' ist bewusst nicht exponiert (rohe Eingabe / globale Tastatur / Koordinaten-Klick / Raw-winapp)."
        } else { "Unbekannte Operation '$Operation'. Erlaubt: $($script:KIDesktopControlOperations -join ', ')." }
        return & $finish (New-KIDesktopControlResult -Operation $Operation -Class 'rejected' -Success $false -Status 'OperationNotPermitted' -Extra @{ policy = [pscustomobject]@{ classification = 'rejected' }; blockedReason = $reason })
    }
    $rawCheck = Test-KIDesktopControlRawArguments -Request $Request -Policy $Policy
    if (-not $rawCheck.ok) {
        return & $finish (New-KIDesktopControlResult -Operation $Operation -Class $class -Success $false -Status 'RawArgumentsRejected' -Extra @{ policy = [pscustomobject]@{ classification = $class }; blockedReason = $rawCheck.reason })
    }
    if ($class -eq 'backend-capability-unverified') {
        return & $finish (New-KIDesktopControlResult -Operation $Operation -Class 'mutating' -Success $false -Status 'BackendCapabilityUnverified' -Extra @{
            policy = [pscustomobject]@{ classification = 'mutating' }
            blockedReason = "Operation '$Operation' ist als semantische UIA-Aktion vorgesehen, aber die winapp-Backend-Fähigkeit ist in diesem ersten produktiven Schritt noch nicht verifiziert -- fail closed, bis der reale winapp-scroll-Vertrag geprüft ist."
        })
    }

    # ---- RESOLVE ----
    $resolved = $Internal_ResolvedWinApp
    if ($null -eq $resolved) {
        try {
            $resolved = Resolve-KIDesktopControlWinApp -PackageRoot $PackageRoot -KIStackRoot $KIStackRoot -Config $Config -Internal_VersionProbeOverride $Internal_VersionProbeOverride
        } catch {
            return & $finish (New-KIDesktopControlResult -Operation $Operation -Class $class -Success $false -Status 'ResolverError' -Extra @{
                policy = [pscustomobject]@{ classification = $class }
                resolver = [pscustomobject]@{ resolved = $false; error = $_.Exception.Message }
                blockedReason = "WinApp konnte nicht über den zentralen Resolver aufgelöst werden: $($_.Exception.Message)"
            })
        }
    }
    $resolverInfo = [pscustomobject]@{ resolved = $true; executablePath = $resolved.executablePath; version = $resolved.version; resolutionMethod = $resolved.resolutionMethod }
    $invoker = if ($null -ne $Internal_WinAppInvokerOverride) { $Internal_WinAppInvokerOverride } else { New-KIDesktopControlWinAppInvoker -ExecutablePath $resolved.executablePath -TimeoutMs ([int]$Config.uia.operationTimeoutMs) }

    # ---- operation dispatch ----
    $depth = [int]$Config.uia.inspectDepth
    $needsWindow = $Operation -in @('inspect_window', 'find_element', 'get_properties', 'get_value', 'screenshot', 'wait_for', 'set_value', 'invoke', 'focus')
    $needsElement = $Operation -in @('find_element', 'get_properties', 'get_value', 'set_value', 'invoke', 'focus')

    # list_windows -- pure read
    if ($Operation -eq 'list_windows') {
        $windows = @(Get-KIDesktopControlWindows -Invoker $invoker -Application ([string](& $req 'application')))
        return & $finish (New-KIDesktopControlResult -Operation $Operation -Class 'read-only' -Success ($null -ne $windows) -Status 'OK' -Extra @{
            policy = [pscustomobject]@{ classification = 'read-only' }
            resolver = $resolverInfo
            result = [pscustomobject]@{ windowCount = $windows.Count; windows = $windows }
        })
    }

    # ---- VALIDATE: window ----
    $windowResolution = Resolve-KIDesktopControlWindow -Invoker $invoker -Application ([string](& $req 'application')) -Hwnd (& $req 'hwnd') -TitlePattern ([string](& $req 'titlePattern'))
    $window = $windowResolution.window
    $audit.windowTitle = if ($null -ne $window) { [string](Get-KIDesktopControlObjectValue $window @('title', 'Title')) } else { $null }
    $audit.process = if ($null -ne $window) { [string](Get-KIDesktopControlObjectValue $window @('processName', 'ProcessName')) } else { $null }
    if ($needsWindow -and $windowResolution.matchCount -ne 1) {
        $status = if ($windowResolution.matchCount -eq 0) { 'WindowNotFound' } else { 'WindowAmbiguous' }
        return & $finish (New-KIDesktopControlResult -Operation $Operation -Class $class -Success $false -Status $status -Extra @{
            policy = [pscustomobject]@{ classification = $class }
            resolver = $resolverInfo
            target = [pscustomobject]@{ windowMatchCount = $windowResolution.matchCount }
            blockedReason = "Erwartet genau ein Fenster, gefunden: $($windowResolution.matchCount) (fail closed)."
        })
    }
    $hwnd = if ($null -ne $window) { [string](Get-KIDesktopControlObjectValue $window @('hwnd', 'Hwnd', 'handle')) } else { $null }
    $windowPid = if ($null -ne $window) { Get-KIDesktopControlObjectValue $window @('pid', 'processId', 'ProcessId') } else { $null }
    $liveProc = Get-KIDesktopControlLiveProcess -ProcessId $windowPid -Override $Internal_LiveProcessOverride

    if ($needsWindow) {
        $winContract = Test-KIDesktopControlWindowContract -Policy $Policy -Window $window -MatchCount $windowResolution.matchCount `
            -ExpectedProcessName ([string](& $req 'expectedProcessName')) -ExpectedTitlePattern ([string](& $req 'titlePattern')) `
            -LiveProcessId $(if ($null -ne $liveProc) { [int]$liveProc.id } else { $null }) -LiveProcessName $(if ($null -ne $liveProc) { [string]$liveProc.name } else { $null })
        if (-not $winContract.ok) {
            return & $finish (New-KIDesktopControlResult -Operation $Operation -Class $class -Success $false -Status 'WindowContractFailed' -Extra @{
                policy = [pscustomobject]@{ classification = $class; windowContract = $winContract.checks }
                resolver = $resolverInfo
                target = [pscustomobject]@{ hwnd = $hwnd; title = $audit.windowTitle; process = $audit.process }
                blockedReason = "Window-Target-Contract nicht erfüllt: $($winContract.checks | ConvertTo-Json -Compress)"
            })
        }
        $stateGate = Test-KIDesktopControlWindowState -Policy $Policy -Window $window -Class $class
        if (-not $stateGate.ok) {
            return & $finish (New-KIDesktopControlResult -Operation $Operation -Class $class -Success $false -Status $stateGate.status -Extra @{
                policy = [pscustomobject]@{ classification = $class; windowState = $stateGate }
                resolver = $resolverInfo
                target = [pscustomobject]@{ hwnd = $hwnd; minimized = $stateGate.minimized }
                blockedReason = "Fenster ist nicht interagierbar (minimiert; kein automatisches Restore in diesem Schritt)."
            })
        }
    }

    # inspect_window
    if ($Operation -eq 'inspect_window') {
        $tree = Get-KIDesktopControlUiTree -Invoker $invoker -Hwnd $hwnd -Depth $depth
        $ok = $null -ne $tree
        return & $finish (New-KIDesktopControlResult -Operation $Operation -Class 'read-only' -Success $ok -Status $(if ($ok) { 'OK' } else { 'WinAppError' }) -Extra @{
            policy = [pscustomobject]@{ classification = 'read-only' }
            resolver = $resolverInfo
            target = [pscustomobject]@{ hwnd = $hwnd; title = $audit.windowTitle }
            result = [pscustomobject]@{ elementCount = @(Get-KIDesktopControlTreeElements $tree).Count; tree = $tree }
        })
    }

    # screenshot
    if ($Operation -eq 'screenshot') {
        $shot = Save-KIDesktopControlEvidence -Invoker $invoker -Hwnd $hwnd -EvidenceRoot $paths.evidenceRoot -Label ("screenshot-$hwnd")
        return & $finish (New-KIDesktopControlResult -Operation $Operation -Class 'read-only' -Success ([bool]$shot.success) -Status $(if ($shot.success) { 'OK' } else { 'WinAppError' }) -Extra @{
            policy = [pscustomobject]@{ classification = 'read-only' }
            resolver = $resolverInfo
            target = [pscustomobject]@{ hwnd = $hwnd; title = $audit.windowTitle }
            evidence = @($shot)
        })
    }

    # wait_for -- polls a fresh tree until an element identity appears (read-only)
    if ($Operation -eq 'wait_for') {
        $timeout = [int](& $req 'timeoutMs' ([int]$Config.uia.operationTimeoutMs))
        $poll = [int]$Config.uia.postconditionPollMs
        $identity = & $req 'element'
        $deadline = (Get-Date).AddMilliseconds($timeout); $appeared = $false; $count = 0
        do {
            $tree = Get-KIDesktopControlUiTree -Invoker $invoker -Hwnd $hwnd -Depth $depth
            $m = @(Find-KIDesktopControlElements -Tree $tree `
                    -AutomationId ([string](Get-KIDesktopControlObjectValue $identity @('automationId'))) `
                    -Name ([string](Get-KIDesktopControlObjectValue $identity @('name'))) `
                    -ControlType ([string](Get-KIDesktopControlObjectValue $identity @('controlType'))) `
                    -ClassName ([string](Get-KIDesktopControlObjectValue $identity @('className'))))
            $count = $m.Count
            if ($count -ge 1) { $appeared = $true; break }
            Start-Sleep -Milliseconds $poll
        } while ((Get-Date) -lt $deadline)
        return & $finish (New-KIDesktopControlResult -Operation $Operation -Class 'read-only' -Success $appeared -Status $(if ($appeared) { 'OK' } else { 'Timeout' }) -Extra @{
            policy = [pscustomobject]@{ classification = 'read-only' }
            resolver = $resolverInfo
            target = [pscustomobject]@{ hwnd = $hwnd; title = $audit.windowTitle }
            result = [pscustomobject]@{ appeared = $appeared; matchCount = $count }
        })
    }

    # ---- VALIDATE: element (find_element / get_properties / get_value / set_value / invoke / focus) ----
    $tree = Get-KIDesktopControlUiTree -Invoker $invoker -Hwnd $hwnd -Depth $depth
    $identity = & $req 'element'
    $matches = @(Find-KIDesktopControlElements -Tree $tree `
            -AutomationId ([string](Get-KIDesktopControlObjectValue $identity @('automationId'))) `
            -Name ([string](Get-KIDesktopControlObjectValue $identity @('name'))) `
            -ControlType ([string](Get-KIDesktopControlObjectValue $identity @('controlType'))) `
            -ClassName ([string](Get-KIDesktopControlObjectValue $identity @('className'))) `
            -Selector ([string](Get-KIDesktopControlObjectValue $identity @('selector'))))
    $audit.elementIdentity = if ($null -ne $identity) { ($identity | ConvertTo-Json -Depth 5 -Compress) } else { $null }

    if ($Operation -eq 'find_element') {
        return & $finish (New-KIDesktopControlResult -Operation $Operation -Class 'read-only' -Success ($matches.Count -ge 1) -Status $(if ($matches.Count -ge 1) { 'OK' } else { 'ElementNotFound' }) -Extra @{
            policy = [pscustomobject]@{ classification = 'read-only' }
            resolver = $resolverInfo
            target = [pscustomobject]@{ hwnd = $hwnd; title = $audit.windowTitle }
            result = [pscustomobject]@{ matchCount = $matches.Count; matches = $matches }
        })
    }

    if ($matches.Count -ne 1) {
        $status = if ($matches.Count -eq 0) { 'ElementNotFound' } else { 'ElementAmbiguous' }
        return & $finish (New-KIDesktopControlResult -Operation $Operation -Class $class -Success $false -Status $status -Extra @{
            policy = [pscustomobject]@{ classification = $class }
            resolver = $resolverInfo
            target = [pscustomobject]@{ hwnd = $hwnd; title = $audit.windowTitle; elementMatchCount = $matches.Count }
            blockedReason = "Erwartet genau ein Element, gefunden: $($matches.Count) (fail closed)."
        })
    }
    $element = $matches[0]
    $props = Get-KIDesktopControlElementProperties -Invoker $invoker -Hwnd $hwnd -Element $element
    $elemContract = Test-KIDesktopControlElementContract -Policy $Policy -Element $element -Properties $props -MatchCount $matches.Count -RequestedIdentity $identity -Mutating:($class -eq 'mutating')
    if (-not $elemContract.ok) {
        return & $finish (New-KIDesktopControlResult -Operation $Operation -Class $class -Success $false -Status 'ElementContractFailed' -Extra @{
            policy = [pscustomobject]@{ classification = $class; elementContract = $elemContract.checks }
            resolver = $resolverInfo
            target = [pscustomobject]@{ hwnd = $hwnd; title = $audit.windowTitle }
            blockedReason = "Element-Target-Contract nicht erfüllt: $($elemContract.checks | ConvertTo-Json -Compress)"
        })
    }

    # ---- SECRET GUARD (read AND write of a value) ----
    if ($Operation -in @('get_value', 'set_value')) {
        $secret = Test-KIDesktopControlSecretContext -Policy $Policy `
            -ProcessName ([string](Get-KIDesktopControlObjectValue $window @('processName', 'ProcessName'))) `
            -ControlType $elemContract.controlType `
            -Name ([string](Get-KIDesktopControlObjectValue $element @('name', 'Name'))) `
            -AutomationId ([string](Get-KIDesktopControlObjectValue $element @('automationId', 'AutomationId'))) `
            -ClassName ([string](Get-KIDesktopControlObjectValue $props @('className', 'ClassName'))) `
            -UiAProtectionFlag (Get-KIDesktopControlObjectValue $props @('isPassword', 'IsPassword'))
        if ($secret.block) {
            return & $finish (New-KIDesktopControlResult -Operation $Operation -Class $class -Success $false -Status 'SecretContextBlocked' -Extra @{
                policy = [pscustomobject]@{ classification = $class; secretContext = $secret }
                resolver = $resolverInfo
                target = [pscustomobject]@{ hwnd = $hwnd; title = $audit.windowTitle }
                blockedReason = $secret.reason
            })
        }
    }

    $selector = [string](Get-KIDesktopControlObjectValue $element @('selector', 'Selector', 'automationId', 'AutomationId', 'elementId', 'ElementId'))

    # get_properties / get_value -- read-only
    if ($Operation -eq 'get_properties') {
        return & $finish (New-KIDesktopControlResult -Operation $Operation -Class 'read-only' -Success ($null -ne $props) -Status $(if ($null -ne $props) { 'OK' } else { 'WinAppError' }) -Extra @{
            policy = [pscustomobject]@{ classification = 'read-only' }
            resolver = $resolverInfo
            target = [pscustomobject]@{ hwnd = $hwnd; title = $audit.windowTitle }
            result = [pscustomobject]@{ properties = $props }
        })
    }
    if ($Operation -eq 'get_value') {
        $r = & $invoker @('ui', 'get-value', $selector, '-w', $hwnd)
        return & $finish (New-KIDesktopControlResult -Operation $Operation -Class 'read-only' -Success ([bool]$r.success) -Status $(if ($r.success) { 'OK' } else { 'WinAppError' }) -Extra @{
            policy = [pscustomobject]@{ classification = 'read-only' }
            resolver = $resolverInfo
            target = [pscustomobject]@{ hwnd = $hwnd; title = $audit.windowTitle }
            action = [pscustomobject]@{ winappArgs = @($r.args); exitCode = $r.exitCode }
            result = [pscustomobject]@{ value = $r.json }
        })
    }

    # ---- MUTATING: set_value / invoke / focus -> Act -> Re-observe -> Verify ----
    $postTimeout = [int]$Config.uia.postconditionTimeoutMs
    $postPoll = [int]$Config.uia.postconditionPollMs
    $evidence = @()

    if ($Operation -eq 'set_value') {
        $value = [string](& $req 'value')
        $act = & $invoker @('ui', 'set-value', $selector, $value, '-w', $hwnd)
        $post = Test-KIDesktopControlPostcondition -Name 'set_value readback' -TimeoutMs $postTimeout -PollMs $postPoll -Condition {
            $rv = & $invoker @('ui', 'get-value', $selector, '-w', $hwnd)
            $observed = if ($null -ne $rv.json) { ConvertTo-KIDesktopControlPlainText ($rv.json | ConvertTo-Json -Depth 20) } else { '' }
            $norm = { param($x) ([string]$x).Trim() -replace '\s+', ' ' }
            [pscustomobject]@{ proven = (& $norm $observed) -match [regex]::Escape((& $norm $value)); detail = "readback='$observed'" }
        }
        if ([bool]$Config.evidence.captureOnMutation -or -not $post.proven) { $evidence = @(Save-KIDesktopControlEvidence -Invoker $invoker -Hwnd $hwnd -EvidenceRoot $paths.evidenceRoot -Label "set_value-$hwnd") }
        $success = [bool]$post.proven
        return & $finish (New-KIDesktopControlResult -Operation $Operation -Class 'mutating' -Success $success -Status $(if ($success) { 'OK' } else { 'PostconditionNotProven' }) -Extra @{
            policy = [pscustomobject]@{ classification = 'mutating'; secretContext = $secret }
            resolver = $resolverInfo
            target = [pscustomobject]@{ hwnd = $hwnd; title = $audit.windowTitle }
            action = [pscustomobject]@{ winappArgs = @($act.args); exitCode = $act.exitCode; cliSuccess = [bool]$act.success }
            postcondition = [pscustomobject]@{ required = $true; proven = [bool]$post.proven; method = 'independent get-value readback'; attempts = $post.attempts; detail = $post.detail }
            evidence = $evidence
            blockedReason = $(if ($success) { $null } else { 'set_value konnte nicht unabhängig per Readback verifiziert werden -- CLI-Exitcode allein ist kein Erfolgsnachweis.' })
        })
    }

    if ($Operation -eq 'invoke') {
        $beforeCount = @(Get-KIDesktopControlTreeElements $tree).Count
        $act = & $invoker @('ui', 'invoke', $selector, '-w', $hwnd)
        $expectPattern = [string](& $req 'expectTreeChange')
        $post = Test-KIDesktopControlPostcondition -Name 'invoke re-observe' -TimeoutMs $postTimeout -PollMs $postPoll -Condition {
            $t2 = Get-KIDesktopControlUiTree -Invoker $invoker -Hwnd $hwnd -Depth $depth
            if ($null -eq $t2) { return [pscustomobject]@{ proven = $false; detail = 'tree not re-observable' } }
            $afterCount = @(Get-KIDesktopControlTreeElements $t2).Count
            if (-not [string]::IsNullOrWhiteSpace($expectPattern)) {
                $hit = @(Find-KIDesktopControlElements -Tree $t2 -Name $expectPattern).Count -gt 0 -or (($t2 | ConvertTo-Json -Depth 20) -match $expectPattern)
                return [pscustomobject]@{ proven = $hit; detail = "expected '$expectPattern' present=$hit; elements $beforeCount->$afterCount" }
            }
            [pscustomobject]@{ proven = ($afterCount -ne $beforeCount); detail = "element count $beforeCount->$afterCount" }
        }
        if ([bool]$Config.evidence.captureOnMutation -or -not $post.proven) { $evidence = @(Save-KIDesktopControlEvidence -Invoker $invoker -Hwnd $hwnd -EvidenceRoot $paths.evidenceRoot -Label "invoke-$hwnd") }
        $success = [bool]$post.proven
        return & $finish (New-KIDesktopControlResult -Operation $Operation -Class 'mutating' -Success $success -Status $(if ($success) { 'OK' } else { 'PostconditionNotProven' }) -Extra @{
            policy = [pscustomobject]@{ classification = 'mutating' }
            resolver = $resolverInfo
            target = [pscustomobject]@{ hwnd = $hwnd; title = $audit.windowTitle }
            action = [pscustomobject]@{ winappArgs = @($act.args); exitCode = $act.exitCode; cliSuccess = [bool]$act.success }
            postcondition = [pscustomobject]@{ required = $true; proven = [bool]$post.proven; method = 'independent tree re-observation'; attempts = $post.attempts; detail = $post.detail }
            evidence = $evidence
            blockedReason = $(if ($success) { $null } else { 'invoke bewirkte keine unabhängig beobachtbare Zustandsänderung -- CLI-Exitcode allein ist kein Erfolgsnachweis.' })
        })
    }

    if ($Operation -eq 'focus') {
        $act = & $invoker @('ui', 'focus', $selector, '-w', $hwnd)
        $post = Test-KIDesktopControlPostcondition -Name 'focus verification' -TimeoutMs $postTimeout -PollMs $postPoll -Condition {
            $rf = & $invoker @('ui', 'get-focused', '-w', $hwnd)
            if ($null -eq $rf.json) { return [pscustomobject]@{ proven = $false; detail = 'get-focused not observable' } }
            $focusedText = ConvertTo-KIDesktopControlPlainText ($rf.json | ConvertTo-Json -Depth 20)
            $hit = (-not [string]::IsNullOrWhiteSpace($selector) -and $focusedText -match [regex]::Escape($selector))
            $aid = [string](Get-KIDesktopControlObjectValue $element @('automationId', 'AutomationId'))
            if (-not $hit -and -not [string]::IsNullOrWhiteSpace($aid)) { $hit = $focusedText -match [regex]::Escape($aid) }
            [pscustomobject]@{ proven = $hit; detail = "focused~='$focusedText'" }
        }
        if ([bool]$Config.evidence.captureOnMutation -or -not $post.proven) { $evidence = @(Save-KIDesktopControlEvidence -Invoker $invoker -Hwnd $hwnd -EvidenceRoot $paths.evidenceRoot -Label "focus-$hwnd") }
        $success = [bool]$post.proven
        return & $finish (New-KIDesktopControlResult -Operation $Operation -Class 'mutating' -Success $success -Status $(if ($success) { 'OK' } else { 'PostconditionNotProven' }) -Extra @{
            policy = [pscustomobject]@{ classification = 'mutating' }
            resolver = $resolverInfo
            target = [pscustomobject]@{ hwnd = $hwnd; title = $audit.windowTitle }
            action = [pscustomobject]@{ winappArgs = @($act.args); exitCode = $act.exitCode; cliSuccess = [bool]$act.success }
            postcondition = [pscustomobject]@{ required = $true; proven = [bool]$post.proven; method = 'independent get-focused check'; attempts = $post.attempts; detail = $post.detail }
            evidence = $evidence
            blockedReason = $(if ($success) { $null } else { 'focus konnte nicht unabhängig über get-focused bestätigt werden.' })
        })
    }

    return & $finish (New-KIDesktopControlResult -Operation $Operation -Class $class -Success $false -Status 'NotImplemented' -Extra @{
        policy = [pscustomobject]@{ classification = $class }
        blockedReason = "Operation '$Operation' hat keinen Ausführungspfad."
    })
}

# --- Central provisioning (Install / Upgrade / Repair reconcile) -----------------------

function Get-KIDesktopControlInstallPaths {
    # <KIStackRoot>\tools\desktop-control\  (parametric; standard install => C:\KI-Stack\tools\desktop-control\).
    # The component's own files live under current\; VERSION + installation.json sit one level
    # up as the Complete Installer probe/marker (mirrors tools/winapp).
    param([Parameter(Mandatory)][string]$TargetRoot)
    $root = [IO.Path]::GetFullPath($TargetRoot)
    $installRoot = [IO.Path]::Combine($root, 'tools', 'desktop-control')
    $packageRoot = [IO.Path]::Combine($installRoot, 'current')
    [pscustomobject]@{
        targetRoot   = $root
        installRoot  = $installRoot
        packageRoot  = $packageRoot
        versionStamp = [IO.Path]::Combine($installRoot, 'VERSION')
        marker       = [IO.Path]::Combine($installRoot, 'installation.json')
        checksums    = [IO.Path]::Combine($packageRoot, 'SHA256SUMS.txt')
    }
}

$script:KIDesktopControlRequiredDeployedFiles = @(
    'VERSION', 'MANIFEST.json', 'SHA256SUMS.txt',
    'DesktopControl.psm1', 'DesktopControl.Policy.psm1', 'Invoke-KIStackDesktopControl.ps1',
    'Vendor/WinApp.Resolver.psm1', 'Config/desktop-control.config.json', 'Config/desktop-control.policy.json'
)

function Test-KIDesktopControlChecksums {
    param([Parameter(Mandatory)][string]$PackageRoot, [Parameter(Mandatory)][string]$ChecksumFile)
    if (-not (Test-Path -LiteralPath $ChecksumFile -PathType Leaf)) { return $false }
    foreach ($line in Get-Content -LiteralPath $ChecksumFile) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') { return $false }
        $file = Join-Path $PackageRoot ($Matches[2].Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Matches[1].ToLowerInvariant()) { return $false }
    }
    return $true
}

function Get-KIDesktopControlDeployableFile {
    # Every file Install-KIDesktopControl actually copies into current\ -- the whole component
    # tree MINUS the Payload staging dir (which is never deployed). Returned as forward-slash
    # relative paths so a source tree and a deployed target can be compared key-for-key.
    param([Parameter(Mandatory)][string]$Root)
    $full = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return @() }
    @(Get-ChildItem -LiteralPath $full -Recurse -File -Force | ForEach-Object {
        ($_.FullName.Substring($full.Length).TrimStart('\', '/') -replace '\\', '/')
    } | Where-Object { $_ -ne 'Payload' -and $_ -notmatch '^Payload/' })
}

function Test-KIDesktopControlSourceParity {
    # The load-bearing drift check: every PRODUCTIVELY DEPLOYED file must be byte-identical
    # (SHA256) between the current source/payload tree and the deployed target. This is what
    # makes a changed payload at an UNCHANGED component VERSION correctly non-compliant --
    # Test-KIDesktopControlChecksums alone only proves the target is internally consistent with
    # the SHA256SUMS.txt that happens to sit next to it, never that the target still matches the
    # source we would deploy now.
    #   missing target file      -> not compliant
    #   changed file (hash drift) -> not compliant
    #   extra unexpected target file -> not compliant (a Repair must drop it)
    param([Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)][string]$TargetPackageRoot)
    $srcFiles = @(Get-KIDesktopControlDeployableFile -Root $SourceRoot)
    if ($srcFiles.Count -eq 0) { return [pscustomobject]@{ ok = $false; reason = 'source-root-empty-or-missing' } }
    $tgtFiles = @(Get-KIDesktopControlDeployableFile -Root $TargetPackageRoot)
    $hash = { param($p) (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
    foreach ($rel in $srcFiles) {
        $native = $rel -replace '/', '\'
        $tgt = Join-Path $TargetPackageRoot $native
        if (-not (Test-Path -LiteralPath $tgt -PathType Leaf)) { return [pscustomobject]@{ ok = $false; reason = "missing-in-target:$rel" } }
        if ((& $hash (Join-Path $SourceRoot $native)) -ne (& $hash $tgt)) { return [pscustomobject]@{ ok = $false; reason = "content-drift:$rel" } }
    }
    $extra = @($tgtFiles | Where-Object { $srcFiles -notcontains $_ })
    if ($extra.Count -gt 0) { return [pscustomobject]@{ ok = $false; reason = "unexpected-target-file:$($extra -join ',')" } }
    [pscustomobject]@{ ok = $true; reason = 'ok'; fileCount = $srcFiles.Count }
}

function Test-KIDesktopControlDeployed {
    # On-disk compliance of a *deployed* copy under <TargetRoot>\tools\desktop-control\. Used
    # for Install idempotency and for the Complete Installer's own re-verification. No GUI, no
    # winapp execution here -- the live resolver probe is a separate runtime concern.
    #
    # -SourceRoot (the current source/payload tree) is what turns "internally consistent" into
    # "still matches what we would deploy now": when given, EVERY productively deployed file is
    # compared Source <-> Target by SHA256, so a changed payload at an unchanged component
    # VERSION is reported non-compliant instead of being silently skipped. Callers that only
    # ask "is a self-contained deployment present" (the Complete Installer's planning probe,
    # older tests) omit it and keep the previous behaviour.
    param([Parameter(Mandatory)][string]$TargetRoot, [string]$ExpectedVersion = '0.1.0', [string]$SourceRoot)
    $p = Get-KIDesktopControlInstallPaths -TargetRoot $TargetRoot
    if (-not (Test-Path -LiteralPath $p.packageRoot -PathType Container)) { return [pscustomobject]@{ ok = $false; reason = 'package-root-missing'; paths = $p } }
    foreach ($stampPath in @($p.versionStamp, $p.marker)) {
        if (-not (Test-Path -LiteralPath $stampPath -PathType Leaf)) { return [pscustomobject]@{ ok = $false; reason = 'stamp-or-marker-missing'; paths = $p } }
    }
    try {
        if ((Get-Content -LiteralPath $p.versionStamp -Raw).Trim() -ne $ExpectedVersion) { return [pscustomobject]@{ ok = $false; reason = 'version-stamp-mismatch'; paths = $p } }
        $marker = Get-Content -LiteralPath $p.marker -Raw | ConvertFrom-Json -Depth 20
        if ([string]$marker.version -ne $ExpectedVersion) { return [pscustomobject]@{ ok = $false; reason = 'marker-version-mismatch'; paths = $p } }
    } catch { return [pscustomobject]@{ ok = $false; reason = 'marker-unreadable'; paths = $p } }
    foreach ($rel in $script:KIDesktopControlRequiredDeployedFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $p.packageRoot ($rel -replace '/', '\')) -PathType Leaf)) { return [pscustomobject]@{ ok = $false; reason = "required-file-missing:$rel"; paths = $p } }
    }
    if (-not (Test-KIDesktopControlChecksums -PackageRoot $p.packageRoot -ChecksumFile $p.checksums)) { return [pscustomobject]@{ ok = $false; reason = 'checksums-invalid'; paths = $p } }
    if (-not [string]::IsNullOrWhiteSpace($SourceRoot)) {
        $parity = Test-KIDesktopControlSourceParity -SourceRoot $SourceRoot -TargetPackageRoot $p.packageRoot
        if (-not [bool]$parity.ok) { return [pscustomobject]@{ ok = $false; reason = "source-parity:$($parity.reason)"; paths = $p } }
    }
    [pscustomobject]@{ ok = $true; reason = 'ok'; paths = $p }
}

function Copy-KIDesktopControlBackupItem {
    param([string]$Path, [string]$BackupRoot, [string]$Name)
    $entry = [ordered]@{ path = $Path; name = $Name; existed = (Test-Path -LiteralPath $Path); isDirectory = (Test-Path -LiteralPath $Path -PathType Container) }
    if ($entry.existed) { Copy-Item -LiteralPath $Path -Destination (Join-Path $BackupRoot $Name) -Recurse:$entry.isDirectory -Force }
    $entry
}

function Restore-KIDesktopControlBackup {
    param([Parameter(Mandatory)][string]$BackupPath)
    $backup = Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json -Depth 30
    $backupRoot = Split-Path -Parent $BackupPath
    foreach ($entry in @($backup.items)) {
        $path = [string]$entry.path
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        if ([bool]$entry.existed) {
            New-KIDesktopControlDirectory (Split-Path -Parent $path)
            Copy-Item -LiteralPath (Join-Path $backupRoot ([string]$entry.name)) -Destination $path -Recurse:([bool]$entry.isDirectory) -Force
        }
    }
    [pscustomobject]@{ passed = $true; status = 'Completed'; backupPath = $BackupPath }
}

function Install-KIDesktopControl {
    # Serves Install, Upgrade and Repair alike: deploys ONLY this component's own source
    # (wrapper + policy + config + dispatcher + vendored WinApp resolver + tests/docs) into
    # <TargetRoot>\tools\desktop-control\current\. Introduces no runtime, port, credential or
    # service. winapp stays a separate dependency -- verified at runtime through the central
    # WinApp resolver, never re-provisioned here. Idempotent: an intact, checksum-verified,
    # same-version deployment is a no-op (SkippedAlreadyCompliant).
    param(
        [string]$PackageRoot = $PSScriptRoot,
        [string]$TargetRoot,
        [ValidateSet('Install', 'Upgrade', 'Repair')][string]$Action = 'Install',
        # 2.18.1 hotfix: optional, externally-owned backup root. When set, the backup is created
        # EXCLUSIVELY under this root (a timestamped subfolder of it), never under the standalone
        # <TargetRoot>\backups\desktop-control\ scheme -- so a caller with its own transaction-
        # scoped recovery contract (the Complete Installer) gets a BackupPath its own recovery
        # logic accepts, instead of the always-standalone path a fresh, non-transactional run
        # still gets when this is omitted. Omitted => unchanged standalone behavior.
        [string]$BackupRoot,
        [switch]$DryRun
    )
    $config = Get-KIDesktopControlConfig -PackageRoot $PackageRoot
    if ([string]::IsNullOrWhiteSpace($TargetRoot)) { $TargetRoot = [string]$config.targetRoot }
    $expected = [string]$config.version
    $sourceVersion = (Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim()
    if ($sourceVersion -ne $expected) { throw "Quell-VERSION ($sourceVersion) und Config-Version ($expected) sind nicht deckungsgleich." }
    $p = Get-KIDesktopControlInstallPaths -TargetRoot $TargetRoot

    if ($DryRun) {
        return [pscustomobject]@{ passed = $true; status = 'DryRun'; action = $Action; plan = [pscustomobject]@{ installRoot = $p.installRoot; packageRoot = $p.packageRoot }; mutatesTarget = $false }
    }

    # Idempotency gate. -SourceRoot makes SkippedAlreadyCompliant require that the deployed
    # content still equals THIS payload, not merely that the target is self-consistent -- so a
    # changed payload at an unchanged VERSION (0.1.0 == 0.1.0) is reconciled, never ignored.
    $existing = Test-KIDesktopControlDeployed -TargetRoot $TargetRoot -ExpectedVersion $expected -SourceRoot $PackageRoot
    if ([bool]$existing.ok) {
        return [pscustomobject]@{ passed = $true; status = 'SkippedAlreadyCompliant'; action = $Action; marker = (Get-Content -LiteralPath $p.marker -Raw | ConvertFrom-Json -Depth 20); mutatesTarget = $false }
    }

    New-KIDesktopControlDirectory $p.installRoot
    $backupRootBase = if (-not [string]::IsNullOrWhiteSpace($BackupRoot)) { $BackupRoot } else { Join-Path $TargetRoot 'backups/desktop-control' }
    $backupRoot = Join-Path $backupRootBase ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff'))
    New-KIDesktopControlDirectory $backupRoot
    $items = @()
    foreach ($def in @(
        @{ path = $p.packageRoot; name = 'current' },
        @{ path = $p.versionStamp; name = 'VERSION' },
        @{ path = $p.marker; name = 'installation.json' }
    )) { $items += @(Copy-KIDesktopControlBackupItem -Path $def.path -BackupRoot $backupRoot -Name $def.name) }
    $backupPath = Join-Path $backupRoot 'rollback.json'
    ([ordered]@{ schemaVersion = '1.0'; createdAtUtc = [DateTime]::UtcNow.ToString('o'); targetRoot = $TargetRoot; items = $items }) | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $backupPath -Encoding utf8NoBOM

    try {
        # Clean re-deploy of current\ (a Repair must drop drifted/extra files).
        if (Test-Path -LiteralPath $p.packageRoot) { Remove-Item -LiteralPath $p.packageRoot -Recurse -Force }
        New-KIDesktopControlDirectory $p.packageRoot
        Get-ChildItem -LiteralPath $PackageRoot -Force | Where-Object { $_.Name -ne 'Payload' } |
            Copy-Item -Destination $p.packageRoot -Recurse -Force

        if (-not (Test-KIDesktopControlChecksums -PackageRoot $p.packageRoot -ChecksumFile $p.checksums)) {
            throw 'SHA256SUMS.txt der deployten Komponente stimmt nicht mit dem kopierten Inhalt überein (fail closed).'
        }
        foreach ($rel in $script:KIDesktopControlRequiredDeployedFiles) {
            if (-not (Test-Path -LiteralPath (Join-Path $p.packageRoot ($rel -replace '/', '\')) -PathType Leaf)) { throw "Pflichtdatei fehlt nach dem Deploy: $rel" }
        }

        Set-Content -LiteralPath $p.versionStamp -Value $expected -Encoding ascii -NoNewline
        $marker = [ordered]@{
            schemaVersion = '1.0'
            version = $expected
            tool = 'desktop-control'
            operationModel = 'Resolve -> Validate -> Act -> Re-observe -> Verify'
            winappDependency = [pscustomobject]@{ resolvedVia = 'central WinApp resolver'; expectedVersion = [string]$config.winappResolver.expectedWinAppVersion; provisionedByThisComponent = $false }
            deployedFileCount = @(Get-ChildItem -LiteralPath $p.packageRoot -Recurse -File).Count
            installedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        $marker | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $p.marker -Encoding utf8NoBOM

        $readback = Test-KIDesktopControlDeployed -TargetRoot $TargetRoot -ExpectedVersion $expected -SourceRoot $PackageRoot
        if (-not [bool]$readback.ok) { throw "Desktop-Control-Readback nach dem Deploy fehlgeschlagen: $($readback.reason)" }

        $status = switch ($Action) { 'Upgrade' { 'Upgraded' }; 'Repair' { 'Repaired' }; default { 'Installed' } }
        [pscustomobject]@{ passed = $true; status = $status; action = $Action; marker = $marker; backupPath = $backupPath; deployedFileCount = $marker.deployedFileCount; mutatesTarget = $true }
    } catch {
        $rollbackStatus = 'Failed'
        try { $rb = Restore-KIDesktopControlBackup -BackupPath $backupPath; $rollbackStatus = [string]$rb.status } catch {}
        if (-not (Test-Path -LiteralPath $p.marker -PathType Leaf) -and (Test-Path -LiteralPath $p.packageRoot)) {
            Remove-Item -LiteralPath $p.packageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        $_.Exception.Data['KIStackRollbackStatus'] = $rollbackStatus
        $_.Exception.Data['KIStackBackupPath'] = $backupPath
        throw
    }
}

function Restore-KIDesktopControl {
    param([Parameter(Mandatory)][string]$BackupPath, [string]$PackageRoot = $PSScriptRoot, [string]$TargetRoot = 'C:\KI-Stack')
    Restore-KIDesktopControlBackup -BackupPath $BackupPath
}

# --- Component compliance (Audit / Validate / Status) ----------------------------------

function Test-KIDesktopControl {
    # Static compliance: package files present, policy/config parse, the vendored WinApp
    # resolver matches its canonical source (repo-time check; skipped when the source tree is
    # not co-located, e.g. a deployed target), the dispatcher exposes no seams, AND the real
    # central WinApp resolver is reachable. Never opens a GUI (a single winapp --version probe
    # only). -SkipResolverProbe is an INTERNAL seam -- not on the operator/installer dispatcher.
    param(
        [string]$PackageRoot = $PSScriptRoot,
        [string]$TargetRoot = 'C:\KI-Stack',
        [string]$KIStackRoot,
        [switch]$SkipResolverProbe,
        [scriptblock]$Internal_VersionProbeOverride
    )
    $config = Get-KIDesktopControlConfig -PackageRoot $PackageRoot
    if ([string]::IsNullOrWhiteSpace($KIStackRoot)) { $KIStackRoot = $TargetRoot }
    $checks = [ordered]@{}
    $checks.versionFile = ((Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim() -eq [string]$config.version)
    $manifest = Get-Content -LiteralPath (Join-Path $PackageRoot 'MANIFEST.json') -Raw | ConvertFrom-Json
    $checks.manifestVersion = ([string]$manifest.version -eq [string]$config.version)
    $checks.introducesNoRuntimePortCredential = ((-not [bool]$manifest.introducesRuntime) -and (-not [bool]$manifest.introducesPort) -and (-not [bool]$manifest.introducesCredential))
    $policy = $null
    try { $policy = Get-KIDesktopControlPolicy -PackageRoot $PackageRoot; $checks.policyParses = $true } catch { $checks.policyParses = $false }
    $checks.developmentFallbackDisabled = (-not [bool]$config.winappResolver.allowDevelopmentFallback)

    $vendored = Join-Path $PackageRoot ([string]$config.winappResolver.vendoredModule)
    $canonical = Join-Path ([IO.Path]::GetFullPath((Join-Path $PackageRoot '..\..\..'))) ([string]$config.winappResolver.canonicalSource)
    $checks.vendoredResolverPresent = (Test-Path -LiteralPath $vendored -PathType Leaf)
    # Repo-time integrity check only: when the canonical source tree is not co-located (a
    # deployed target, or a payload extraction), this is 'not-applicable' -- the vendored copy
    # is the authoritative on-disk artifact there and is covered by SHA256SUMS.txt instead.
    if ($checks.vendoredResolverPresent -and (Test-Path -LiteralPath $canonical -PathType Leaf)) {
        $matches = ((Get-FileHash -LiteralPath $vendored -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $canonical -Algorithm SHA256).Hash)
        $checks.vendoredResolverMatchesCanonicalSource = $matches
        $checks.vendoredResolverCanonicalCheck = $(if ($matches) { 'matched' } else { 'MISMATCH' })
    } else {
        $checks.vendoredResolverMatchesCanonicalSource = $true
        $checks.vendoredResolverCanonicalCheck = 'not-applicable'
    }
    # The vendored resolver must never expose send-input etc.; the dispatcher must expose no
    # test/development seams -- including -SkipResolverProbe.
    $dispatcher = Get-Content -LiteralPath (Join-Path $PackageRoot 'Invoke-KIStackDesktopControl.ps1') -Raw
    $paramBlock = ($dispatcher -split '(?m)^\)\s*$', 2)[0]
    $checks.dispatcherExposesNoInternalSeams = (
        ($paramBlock -notmatch 'Internal_') -and ($paramBlock -notmatch 'AllowDevelopmentFallback') -and
        ($paramBlock -notmatch 'VersionProbeOverride') -and ($paramBlock -notmatch 'WinAppInvokerOverride') -and
        ($paramBlock -notmatch 'SkipResolverProbe') -and ($paramBlock -notmatch 'SkipVersionProbe') -and
        ($paramBlock -notmatch 'SourceManifestOverride') -and ($paramBlock -notmatch 'ArtifactFileOverride')
    )
    # The dispatcher's Operation ValidateSet must be exactly the known-good semantic set -- no
    # send_input / raw_winapp / coordinate-click operation may be selectable.
    $opValidateSet = if ($dispatcher -match "ValidateSet\(([^)]*)\)\]\s*\r?\n\s*\[string\]\`$Operation") { $Matches[1] } else { '<none>' }
    $forbiddenInSet = @('send_input', 'send_keys', 'global_hotkey', 'system_hotkey', 'mouse_click_coordinate', 'drag', 'touch', 'pen', 'raw_winapp')
    $checks.dispatcherOperationSetHasNoForbiddenSurface = (@($forbiddenInSet | Where-Object { $opValidateSet -match ("'" + [regex]::Escape($_) + "'") }).Count -eq 0) -and ($opValidateSet -ne '<none>')

    $resolverProbe = 'skipped'
    if (-not $SkipResolverProbe) {
        try {
            $r = Resolve-KIDesktopControlWinApp -PackageRoot $PackageRoot -KIStackRoot $KIStackRoot -Config $config -Internal_VersionProbeOverride $Internal_VersionProbeOverride
            $resolverProbe = "ok: $($r.executablePath)"
            $checks.centralResolverReachable = $true
        } catch {
            $resolverProbe = "unreachable: $($_.Exception.Message)"
            $checks.centralResolverReachable = $false
        }
    }

    $passed = @($checks.Values) -notcontains $false
    [pscustomobject]@{
        passed = $passed
        componentVersion = (Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim()
        expectedComponentVersion = [string]$config.version
        checks = [pscustomobject]$checks
        resolverProbe = $resolverProbe
        exposedOperations = @($script:KIDesktopControlOperations | Where-Object { $_ -notin @($config.operations.backendCapabilityUnverified) })
        mutatesTarget = $false
    }
}

function Get-KIDesktopControlStatus {
    param([string]$PackageRoot = $PSScriptRoot, [string]$TargetRoot = 'C:\KI-Stack', [string]$KIStackRoot, [switch]$SkipResolverProbe)
    $compliance = Test-KIDesktopControl -PackageRoot $PackageRoot -TargetRoot $TargetRoot -KIStackRoot $KIStackRoot -SkipResolverProbe:$SkipResolverProbe
    $paths = Get-KIDesktopControlPaths -TargetRoot $TargetRoot
    [pscustomobject][ordered]@{
        passed = $true
        state = $(if ($compliance.passed) { 'Ready' } else { 'Degraded' })
        auditRoot = $paths.auditRoot
        evidenceRoot = $paths.evidenceRoot
        resolverProbe = $compliance.resolverProbe
        compliance = $compliance.checks
        mutatesTarget = $false
    }
}

Export-ModuleMember -Function `
    Get-KIDesktopControlConfig, Get-KIDesktopControlPaths, Get-KIDesktopControlInstallPaths, Resolve-KIDesktopControlWinApp, `
    New-KIDesktopControlWinAppInvoker, ConvertTo-KIDesktopControlPlainText, Get-KIDesktopControlObjectValue, `
    Get-KIDesktopControlWindows, Resolve-KIDesktopControlWindow, Get-KIDesktopControlUiTree, `
    Get-KIDesktopControlTreeElements, Find-KIDesktopControlElements, Get-KIDesktopControlElementProperties, `
    Get-KIDesktopControlLiveProcess, Save-KIDesktopControlEvidence, Write-KIDesktopControlAudit, `
    Test-KIDesktopControlPostcondition, Invoke-KIDesktopControlOperation, `
    Test-KIDesktopControlChecksums, Get-KIDesktopControlDeployableFile, Test-KIDesktopControlSourceParity, `
    Test-KIDesktopControlDeployed, Install-KIDesktopControl, Restore-KIDesktopControl, `
    Test-KIDesktopControl, Get-KIDesktopControlStatus

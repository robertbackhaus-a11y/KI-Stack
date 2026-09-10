Set-StrictMode -Version Latest

# KI-Stack Desktop Control -- Policy / Validation layer.
#
# This module holds the PURE decision functions of the wrapper: operation classification,
# the Target Contract (window + element), the window-state gate, and the composite
# secret/credential guard. It performs no UI Automation and no winapp execution -- it is fed
# already-observed data (window metadata, element identity, element properties) by
# DesktopControl.psm1 and returns a structured allow/block verdict. Keeping it pure makes every
# rule directly unit-testable without a GUI (Test-KIStackDesktopControl.ps1).
#
# Design anchors (from the 2.18 desktop-control spike, scripts/Test-KIStackDesktopControlSpike.ps1
# and its "Architecture recommendation" section):
#   - HWND re-resolution + process/title checks before every action
#   - IsEnabled / IsOffscreen / ControlType checks
#   - IsPassword is NEVER the sole guard (the spike observed the Explorer address bar reporting
#     IsPassword=true falsely). The guard is composite (process + controlType + name +
#     automationId + className + IsPassword) and false-positive exceptions are narrow and
#     explicit, never a bare name allowlist like "Address" / "Breadcrumb".
#   - raw send-input / global keyboard injection / coordinate clicks are not part of the
#     exposed operation set at all.

function Get-KIDesktopControlPolicy {
    param([string]$PackageRoot = $PSScriptRoot)
    Get-Content -LiteralPath (Join-Path $PackageRoot 'Config/desktop-control.policy.json') -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 50
}

function Get-KIDCPropertyValue {
    # StrictMode-safe property read across differing winapp JSON casings/shapes.
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($n in $Names) {
        $p = $Object.PSObject.Properties[$n]
        if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    }
    return $null
}

function Get-KIDesktopControlOperationClass {
    # 'read-only' | 'mutating' | 'backend-capability-unverified' | 'rejected'
    param([Parameter(Mandatory)][string]$Operation, [Parameter(Mandatory)][object]$Policy, [object]$Config)
    $op = [string]$Operation
    $never = @($Policy.actionClassification.neverExposed)
    if ($never -contains $op) { return 'rejected' }
    if (@($Policy.actionClassification.readOnly) -contains $op) { return 'read-only' }
    if ($null -ne $Config -and @($Config.operations.backendCapabilityUnverified) -contains $op) { return 'backend-capability-unverified' }
    if (@($Policy.actionClassification.mutating) -contains $op) { return 'mutating' }
    if ([bool]$Policy.actionClassification.rejectUnknownOperation) { return 'rejected' }
    return 'rejected'
}

function Test-KIDesktopControlRawArguments {
    # Fail closed if a caller tries to smuggle raw winapp arguments / a raw command through the
    # request. The wrapper only ever builds winapp argument lists itself.
    param([Parameter(Mandatory)][object]$Request, [Parameter(Mandatory)][object]$Policy)
    if (-not [bool]$Policy.actionClassification.rejectRawWinAppArguments) { return [pscustomobject]@{ ok = $true; reason = $null } }
    foreach ($forbidden in @('rawArgs', 'rawArguments', 'winappArgs', 'winappArguments', 'command', 'commandLine', 'argv', 'raw')) {
        if ($Request.PSObject.Properties[$forbidden] -and $null -ne $Request.$forbidden -and -not [string]::IsNullOrWhiteSpace([string]$Request.$forbidden)) {
            return [pscustomobject]@{ ok = $false; reason = "Rohe winapp-Argumente/-Kommandos sind nicht erlaubt (Feld '$forbidden'). Nur semantische Operationen." }
        }
    }
    [pscustomobject]@{ ok = $true; reason = $null }
}

function Test-KIDesktopControlWindowContract {
    # The "Window" half of the Target Contract. $Window is the metadata object DesktopControl.psm1
    # just re-resolved from winapp (never a cached snapshot). $Matches is the count of windows
    # that matched the caller's window selector in that same fresh resolution.
    param(
        [Parameter(Mandatory)][object]$Policy,
        [AllowNull()][object]$Window,
        [int]$MatchCount = 0,
        [AllowNull()][string]$ExpectedProcessName,
        [AllowNull()][string]$ExpectedTitlePattern,
        [AllowNull()][int]$LiveProcessId,
        [AllowNull()][string]$LiveProcessName
    )
    $c = $Policy.targetContract.window
    $checks = [ordered]@{}
    $checks.windowResolved = ($null -ne $Window)
    $checks.uniqueHwnd = (-not [bool]$c.requireUniqueHwnd) -or ($MatchCount -eq 1)
    $hwnd = Get-KIDCPropertyValue $Window @('hwnd', 'Hwnd', 'handle')
    $checks.hwndPresent = ($null -ne $hwnd)
    $title = [string](Get-KIDCPropertyValue $Window @('title', 'Title'))
    $checks.titleContext = (-not [bool]$c.requireTitleContext) -or (-not [string]::IsNullOrWhiteSpace($title)) -or ([string]::IsNullOrWhiteSpace([string]$ExpectedTitlePattern))
    if (-not [string]::IsNullOrWhiteSpace([string]$ExpectedTitlePattern) -and -not [string]::IsNullOrWhiteSpace($title)) {
        $checks.titleContext = $checks.titleContext -and ($title -match [string]$ExpectedTitlePattern)
    }
    # Process identity: the window's reported pid must still resolve to a live process, and that
    # process name must match either the window's own reported process name or an explicitly
    # expected one -- mirrors the spike's Test-WinAppPreconditions 'process' check.
    if ([bool]$c.requireProcessIdentity) {
        $windowPid = Get-KIDCPropertyValue $Window @('pid', 'processId', 'ProcessId')
        $windowProcName = [string](Get-KIDCPropertyValue $Window @('processName', 'ProcessName'))
        $procOk = $false
        if ($null -ne $windowPid -and $null -ne $LiveProcessId -and [int]$windowPid -eq [int]$LiveProcessId -and -not [string]::IsNullOrWhiteSpace([string]$LiveProcessName)) {
            $expected = if (-not [string]::IsNullOrWhiteSpace([string]$ExpectedProcessName)) { [string]$ExpectedProcessName } elseif (-not [string]::IsNullOrWhiteSpace($windowProcName)) { $windowProcName } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($expected)) {
                $procOk = ([string]$LiveProcessName -match ('(?i)' + [regex]::Escape(($expected -replace '\.exe$', ''))))
            }
        }
        $checks.processIdentity = $procOk
    } else {
        $checks.processIdentity = $true
    }
    $ok = @($checks.Values) -notcontains $false
    [pscustomobject]@{ ok = $ok; checks = [pscustomobject]$checks }
}

function Test-KIDesktopControlWindowState {
    # Window-state gate for mutating actions. In this first productive step a minimized window
    # is NOT auto-restored (no proven state contract yet) -- it fails closed as
    # WindowNotInteractable. Background observation stays allowed.
    param([Parameter(Mandatory)][object]$Policy, [AllowNull()][object]$Window, [string]$Class = 'read-only')
    $isMinimized = $false
    if ($null -ne $Window) {
        $stateVal = Get-KIDCPropertyValue $Window @('windowState', 'WindowState', 'state', 'State')
        $isMin = Get-KIDCPropertyValue $Window @('isMinimized', 'IsMinimized', 'minimized')
        if ($null -ne $stateVal -and ([string]$stateVal -match '(?i)minimi[sz]ed')) { $isMinimized = $true }
        if ($null -ne $isMin -and [bool]$isMin) { $isMinimized = $true }
        $w = Get-KIDCPropertyValue $Window @('width', 'Width'); $h = Get-KIDCPropertyValue $Window @('height', 'Height')
        if ($null -ne $w -and $null -ne $h -and ([int]$w -le 1 -or [int]$h -le 1)) { $isMinimized = $true }
    }
    if ($Class -ne 'mutating') { return [pscustomobject]@{ ok = $true; minimized = $isMinimized; status = 'OK' } }
    if ($isMinimized -and [bool]$Policy.windowState.blockMutationWhenMinimized -and -not [bool]$Policy.windowState.autoRestoreMinimized) {
        return [pscustomobject]@{ ok = $false; minimized = $true; status = 'WindowNotInteractable' }
    }
    [pscustomobject]@{ ok = $true; minimized = $isMinimized; status = 'OK' }
}

function Test-KIDesktopControlElementContract {
    # The "Element" half of the Target Contract. $Element is the identity object matched in the
    # CURRENT (freshly re-inspected) tree; $Properties is the CURRENT ui get-property result;
    # $MatchCount is how many elements matched the caller's identity in that same fresh tree.
    #
    # -Mutating: the IsEnabled / IsOffscreen gates guard *actions* (task §5: "Jede mutierende
    # Aktion muss ... einen Target Contract erfüllen"). For a pure read they are recorded but do
    # not fail the contract -- a caller may legitimately inspect a disabled/offscreen element.
    # Element resolution, unambiguity, control type and identity match are always required.
    param(
        [Parameter(Mandatory)][object]$Policy,
        [AllowNull()][object]$Element,
        [AllowNull()][object]$Properties,
        [int]$MatchCount = 0,
        [AllowNull()][object]$RequestedIdentity,
        [switch]$Mutating
    )
    $c = $Policy.targetContract.element
    $checks = [ordered]@{}
    $checks.elementResolved = ($null -ne $Element)
    $checks.unambiguous = (-not [bool]$c.rejectAmbiguous) -or ($MatchCount -eq 1)

    $getVal = {
        param($obj, [string[]]$names)
        if ($null -eq $obj) { return $null }
        foreach ($n in $names) { $p = $obj.PSObject.Properties[$n]; if ($null -ne $p -and $null -ne $p.Value) { return $p.Value } }
        return $null
    }
    $controlType = [string](& $getVal $Properties @('controlType', 'ControlType', 'type', 'Type'))
    if ([string]::IsNullOrWhiteSpace($controlType)) { $controlType = [string](& $getVal $Element @('controlType', 'ControlType', 'type', 'Type')) }
    $checks.controlType = (-not [bool]$c.requireControlType) -or (-not [string]::IsNullOrWhiteSpace($controlType))

    $isEnabled = & $getVal $Properties @('isEnabled', 'IsEnabled')
    $checks.isEnabled = (-not $Mutating) -or (-not [bool]$c.requireIsEnabledNotFalse) -or ($isEnabled -ne $false)

    $isOffscreen = & $getVal $Properties @('isOffscreen', 'IsOffscreen')
    $checks.onScreen = (-not $Mutating) -or (-not [bool]$c.requireIsOffscreenNotTrue) -or ($isOffscreen -ne $true)

    # Identity match: whatever the caller supplied (automationId / name / className / controlType)
    # must still hold on the freshly-resolved element. A generated winapp selector ALONE is never
    # accepted as durable identity.
    #
    # Every durable-identity field is resolved through the SAME casing/alias set the other
    # helpers use (Find-KIDesktopControlElements, Get-KIDesktopControlObjectValue, and the
    # controlType check above). Real winapp elements report control type as `type`, not
    # `controlType` -- without the alias set here a request `controlType = "Document"` against an
    # element `type = "Document"` produced a false identityMatch=false. This does NOT loosen the
    # contract: each requested field is still compared for exact equality.
    $identityFieldAliases = [ordered]@{
        automationId = @('automationId', 'AutomationId')
        name         = @('name', 'Name')
        className    = @('className', 'ClassName')
        controlType  = @('controlType', 'ControlType', 'type', 'Type')
    }
    $identityOk = $true
    $usedDurableIdentity = $false
    if ($null -ne $RequestedIdentity) {
        foreach ($field in $identityFieldAliases.Keys) {
            $aliases = $identityFieldAliases[$field]
            $want = [string](& $getVal $RequestedIdentity $aliases)
            if ([string]::IsNullOrWhiteSpace($want)) { continue }
            $usedDurableIdentity = $true
            $have = [string](& $getVal $Element $aliases)
            if ([string]::IsNullOrWhiteSpace($have)) { $have = [string](& $getVal $Properties $aliases) }
            if ($have -ne $want) { $identityOk = $false }
        }
        $selectorOnly = -not $usedDurableIdentity -and -not [string]::IsNullOrWhiteSpace([string](& $getVal $RequestedIdentity @('selector')))
        if ($selectorOnly -and [bool]$c.rejectStaleSelectorOnlyIdentity) { $identityOk = $false; $checks.selectorOnlyIdentityRejected = $false }
    }
    $checks.identityMatch = (-not [bool]$c.requireIdentityMatch) -or $identityOk

    $ok = @($checks.Values) -notcontains $false
    [pscustomobject]@{
        ok = $ok
        checks = [pscustomobject]$checks
        controlType = $controlType
        isEnabled = $isEnabled
        isOffscreen = $isOffscreen
        usedDurableIdentity = $usedDurableIdentity
    }
}

function Test-KIDesktopControlFalsePositiveException {
    param([Parameter(Mandatory)][object]$Exception, [hashtable]$Context)
    $req = Get-KIDCPropertyValue $Exception @('require')
    $processNameEquals = Get-KIDCPropertyValue $req @('processNameEquals')
    $controlTypeIn = Get-KIDCPropertyValue $req @('controlTypeIn')
    $classNameMatches = Get-KIDCPropertyValue $req @('classNameMatches')
    $automationIdIn = Get-KIDCPropertyValue $req @('automationIdIn')
    $nameMatches = Get-KIDCPropertyValue $req @('nameMatches')
    if ($null -ne $processNameEquals -and ([string]$Context.processName -replace '\.exe$', '') -notmatch ('(?i)^' + [regex]::Escape([string]($processNameEquals -replace '\.exe$', '')) + '$')) { return $false }
    if ($null -ne $controlTypeIn -and @($controlTypeIn) -notcontains [string]$Context.controlType) { return $false }
    if ($null -ne $classNameMatches -and [string]$Context.className -notmatch [string]$classNameMatches) { return $false }
    if ($null -ne $automationIdIn -and @($automationIdIn) -notcontains [string]$Context.automationId) { return $false }
    if ($null -ne $nameMatches -and [string]$Context.name -notmatch [string]$nameMatches) { return $false }
    return $true
}

function Test-KIDesktopControlSecretContext {
    # Composite secret/credential guard. Returns { secret = $bool; block = $bool; signals = @();
    # exception = <id|null>; reason = <string> }.
    #
    # SECRET := IsPassword==true OR any positive signal matches
    #           (name / automationId / className / process name).
    # A SECRET element blocks BOTH get_value and set_value -- unless exactly one narrow
    # falsePositiveException fully matches, in which case it is allowed (and that decision is
    # recorded, with the exception id, in the audit record).
    param(
        [Parameter(Mandatory)][object]$Policy,
        [string]$ProcessName = '',
        [string]$ControlType = '',
        [string]$Name = '',
        [string]$AutomationId = '',
        [string]$ClassName = '',
        [AllowNull()][object]$UiAProtectionFlag = $null
    )
    $s = $Policy.secretContext.positiveSignals
    $signals = [System.Collections.Generic.List[string]]::new()

    if ($UiAProtectionFlag -eq $true) { $signals.Add('isPassword') | Out-Null }
    foreach ($p in @($s.namePatterns)) { if (-not [string]::IsNullOrWhiteSpace($Name) -and $Name -match $p) { $signals.Add("name~$p") | Out-Null } }
    foreach ($p in @($s.automationIdPatterns)) { if (-not [string]::IsNullOrWhiteSpace($AutomationId) -and $AutomationId -match $p) { $signals.Add("automationId~$p") | Out-Null } }
    foreach ($p in @($s.classNamePatterns)) { if (-not [string]::IsNullOrWhiteSpace($ClassName) -and $ClassName -match $p) { $signals.Add("className~$p") | Out-Null } }
    foreach ($p in @($s.processNamePatterns)) { if (-not [string]::IsNullOrWhiteSpace($ProcessName) -and $ProcessName -match $p) { $signals.Add("processName~$p") | Out-Null } }

    $secret = $signals.Count -gt 0
    if (-not $secret) {
        return [pscustomobject]@{ secret = $false; block = $false; signals = @(); exception = $null; reason = 'Kein Credential-/Secret-Kontext erkannt.' }
    }

    # Only IsPassword alone (no other signal) is eligible for a false-positive exception.
    $context = @{ processName = ($ProcessName -replace '\.exe$', ''); controlType = $ControlType; name = $Name; automationId = $AutomationId; className = $ClassName }
    $onlyIsPassword = @($signals | Where-Object { $_ -ne 'isPassword' }).Count -eq 0
    foreach ($ex in @($Policy.secretContext.falsePositiveExceptions)) {
        if (-not $onlyIsPassword) { continue }
        if ([bool](Get-KIDCPropertyValue (Get-KIDCPropertyValue $ex @('require')) @('nameMustNotMatchAnyPositiveSignal'))) {
            $nameHitsPositive = $false
            foreach ($p in @($s.namePatterns)) { if (-not [string]::IsNullOrWhiteSpace($Name) -and $Name -match $p) { $nameHitsPositive = $true } }
            if ($nameHitsPositive) { continue }
        }
        if (Test-KIDesktopControlFalsePositiveException -Exception $ex -Context $context) {
            return [pscustomobject]@{
                secret = $true; block = $false; signals = @($signals); exception = [string]$ex.id
                reason = "Nur IsPassword=true, ohne weiteres Signal; enge Ausnahme '$($ex.id)' greift ($($ex.reason))."
            }
        }
    }

    $block = [bool]$Policy.secretContext.blockReadAndWriteWhenSecret
    [pscustomobject]@{
        secret = $true; block = $block; signals = @($signals); exception = $null
        reason = "Credential-/Secret-Kontext erkannt (Signale: $($signals -join ', ')). READ und WRITE blockiert."
    }
}

Export-ModuleMember -Function `
    Get-KIDesktopControlPolicy, Get-KIDCPropertyValue, Get-KIDesktopControlOperationClass, Test-KIDesktopControlRawArguments, `
    Test-KIDesktopControlWindowContract, Test-KIDesktopControlWindowState, Test-KIDesktopControlElementContract, `
    Test-KIDesktopControlSecretContext, Test-KIDesktopControlFalsePositiveException

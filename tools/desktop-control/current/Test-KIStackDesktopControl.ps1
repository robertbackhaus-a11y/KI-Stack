[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Focused contract/unit suite for the Desktop Control wrapper (DesktopControl.psm1) and its
# policy layer (DesktopControl.Policy.psm1). NO GUI automation, NO application launch, NO
# global keyboard/mouse injection: every `winapp ui ...` call is served by an in-process fake
# invoker, and the live `winapp.exe --version` probe is injected. The real central WinApp
# resolver (Vendor/WinApp.Resolver.psm1) IS exercised against fake / hostile trees so
# "resolver is used, PATH/WindowsApps ignored" is proven for real.

Import-Module (Join-Path $PackageRoot 'DesktopControl.Policy.psm1') -Force
Import-Module (Join-Path $PackageRoot 'DesktopControl.psm1') -Force

$fail = [Collections.Generic.List[string]]::new()
$checks = [ordered]@{}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('KIDesktopControl-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null

$fastConfig = Get-KIDesktopControlConfig -PackageRoot $PackageRoot
$fastConfig.uia.postconditionTimeoutMs = 400
$fastConfig.uia.postconditionPollMs = 40
$fastConfig.uia.operationTimeoutMs = 400
$policy = Get-KIDesktopControlPolicy -PackageRoot $PackageRoot
$probe061 = { param($exe) 'winapp 0.6.1 (x64)' }
$fakeResolved = [pscustomobject]@{ resolved = $true; executablePath = (Join-Path $scratch 'winapp.exe'); version = '0.6.1'; reportedExecutableVersion = '0.6.1'; packageRoot = $scratch; installRoot = $scratch; resolutionMethod = 'central-kistack-tools' }
$liveNotepad = { param($id) [pscustomobject]@{ id = [int]$id; name = 'notepad' } }

function New-DCTestRoot { param([string]$Name) $r = Join-Path $scratch $Name; New-Item -ItemType Directory -Path $r -Force | Out-Null; $r }

# A full fake winapp provisioning tree so the REAL resolver resolves the central path.
function New-DCFakeWinAppTree {
    param([string]$Root)
    $pkg = Join-Path $Root 'tools\winapp\current'
    New-Item -ItemType Directory -Path $pkg -Force | Out-Null
    foreach ($f in 'winapp.exe', 'libSkiaSharp.dll', 'winapp.pdb') { Set-Content -LiteralPath (Join-Path $pkg $f) -Value "fake-$f" -Encoding ascii -NoNewline }
    Set-Content -LiteralPath (Join-Path $Root 'tools\winapp\VERSION') -Value '0.6.1' -Encoding ascii -NoNewline
    $sum = Join-Path $Root 'tools\winapp\SHA256SUMS.txt'
    $lines = Get-ChildItem -LiteralPath $pkg -Recurse -File | Sort-Object Name | ForEach-Object {
        "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) *$($_.Name)"
    }
    [IO.File]::WriteAllLines($sum, $lines, [Text.ASCIIEncoding]::new())
    Set-Content -LiteralPath (Join-Path $Root 'tools\winapp\installation.json') -Value '{"schemaVersion":"1.0","version":"0.6.1"}' -Encoding ascii
    $Root
}

# Flexible in-process winapp fake. $Scenario controls what each verb returns.
function New-DCFakeInvoker {
    param([hashtable]$Scenario)
    $s = $Scenario
    if (-not $s.ContainsKey('callLog')) { $s.callLog = [Collections.Generic.List[string]]::new() }
    if (-not $s.ContainsKey('value')) { $s.value = 'initial' }
    if (-not $s.ContainsKey('invoked')) { $s.invoked = $false }
    {
        param([string[]]$WinAppArgs)
        $a = ($WinAppArgs -join ' ')
        $s.callLog.Add($a) | Out-Null
        $mk = { param($o, $exit = 0) [pscustomobject]@{ success = ($exit -eq 0 -and $null -ne $o); exitCode = $exit; json = $o; stdout = ($o | ConvertTo-Json -Depth 20); stderr = ''; parseError = $null; args = $WinAppArgs } }

        if ($a -match 'ui list-windows') {
            $wins = if ($s.ContainsKey('windows')) { @($s.windows) } else { @([pscustomobject]@{ hwnd = 1001; title = 'Editor'; pid = 4242; processName = 'notepad'; width = 800; height = 600 }) }
            return & $mk ([pscustomobject]@{ windows = $wins })
        }
        if ($a -match 'ui inspect') {
            $els = if ($s.invoked -and $s.ContainsKey('elementsAfterInvoke')) { @($s.elementsAfterInvoke) }
                   elseif ($s.ContainsKey('elements')) { @($s.elements) }
                   else { @([pscustomobject]@{ automationId = 'TextBox1'; name = 'Body'; controlType = 'Edit'; className = 'Edit'; selector = 'sel-textbox1' }) }
            return & $mk ([pscustomobject]@{ windows = @([pscustomobject]@{ elements = $els }) })
        }
        if ($a -match 'ui get-property') {
            $p = if ($s.ContainsKey('properties')) { $s.properties } else { [pscustomobject]@{ controlType = 'Edit'; isEnabled = $true; isOffscreen = $false; isPassword = $false; className = 'Edit' } }
            return & $mk $p
        }
        if ($a -match 'ui get-value') { return & $mk ([pscustomobject]@{ value = $s.value }) }
        if ($a -match 'ui set-value') {
            if (-not $s.ContainsKey('setValueApplies') -or $s.setValueApplies) { $s.value = [string]$WinAppArgs[3] }
            return & $mk ([pscustomobject]@{ ok = $true })
        }
        if ($a -match 'ui invoke') { $s.invoked = $true; return & $mk ([pscustomobject]@{ ok = $true }) }
        if ($a -match 'ui focus') { $s.focusedSelector = [string]$WinAppArgs[2]; return & $mk ([pscustomobject]@{ ok = $true }) }
        if ($a -match 'ui get-focused') {
            $sel = if ($s.ContainsKey('focusedSelectorReport')) { $s.focusedSelectorReport } elseif ($s.ContainsKey('focusedSelector')) { $s.focusedSelector } else { '' }
            return & $mk ([pscustomobject]@{ focused = [pscustomobject]@{ selector = $sel } })
        }
        if ($a -match 'ui screenshot') {
            $idx = [Array]::IndexOf($WinAppArgs, '-o'); if ($idx -ge 0) { Set-Content -LiteralPath $WinAppArgs[$idx + 1] -Value 'PNG' -Encoding ascii }
            return & $mk ([pscustomobject]@{ ok = $true })
        }
        return & $mk ([pscustomobject]@{ ok = $true })
    }.GetNewClosure()
}

function Invoke-DCOp {
    param([string]$Operation, [hashtable]$Request = @{}, [hashtable]$Scenario = @{}, [scriptblock]$LiveProc = $null, [string]$TargetRoot = $scratch)
    $inv = New-DCFakeInvoker -Scenario $Scenario
    Invoke-KIDesktopControlOperation -Operation $Operation -Request ($Request | ConvertTo-Json -Depth 10) -PackageRoot $PackageRoot `
        -TargetRoot $TargetRoot -Config $fastConfig -Policy $policy -Internal_ResolvedWinApp $fakeResolved `
        -Internal_WinAppInvokerOverride $inv -Internal_LiveProcessOverride ($(if ($LiveProc) { $LiveProc } else { $liveNotepad })) -Internal_SkipAudit
}

try {
    # === 1: the central WinApp resolver is used (and its method is the production one) =======
    $rootOk = New-DCFakeWinAppTree (New-DCTestRoot 'winapp-ok')
    $resolved = Resolve-KIDesktopControlWinApp -PackageRoot $PackageRoot -KIStackRoot $rootOk -Internal_VersionProbeOverride $probe061
    # Non-comment code lines of the wrapper module only -- comments may legitimately mention the
    # forbidden mechanisms while explaining that they are forbidden.
    $moduleCode = ((Get-Content -LiteralPath (Join-Path $PackageRoot 'DesktopControl.psm1')) | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    $checks.centralResolverUsed = [ordered]@{
        resolves = ([bool]$resolved.resolved)
        methodIsCentral = ([string]$resolved.resolutionMethod -eq 'central-kistack-tools')
        executableUnderCentralTree = ([string]$resolved.executablePath -eq (Join-Path ([IO.Path]::GetFullPath($rootOk)) 'tools\winapp\current\winapp.exe'))
        codeNeverPassesDevFallback = ($moduleCode -notmatch '-AllowDevelopmentFallback' -and $moduleCode -notmatch 'AllowDevelopmentFallback\s*=')
        codeNeverCallsGetCommandWinapp = ($moduleCode -notmatch "Get-Command\s+['`"]?winapp")
        codeNeverInvokesWhereExe = ($moduleCode -notmatch '&\s*where\.exe' -and $moduleCode -notmatch 'where\.exe\s+winapp')
        codeNeverReadsWindowsAppsPath = ($moduleCode -notmatch 'Microsoft\\WindowsApps')
    }
    if ($checks.centralResolverUsed.Values -contains $false) { $fail.Add('centralResolverUsed: ' + ($checks.centralResolverUsed | ConvertTo-Json -Compress)) }

    # === 2: PATH / WindowsApps is ignored -- no central tree => fail closed, never a decoy ====
    $rootEmpty = New-DCTestRoot 'winapp-empty'
    $decoyLocalAppData = New-DCTestRoot 'decoyLAD'
    New-Item -ItemType Directory -Path (Join-Path $decoyLocalAppData 'Microsoft\WindowsApps') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $decoyLocalAppData 'Microsoft\WindowsApps\winapp.exe') -Value 'DECOY' -Encoding ascii -NoNewline
    $savedPath = $env:PATH; $savedLAD = $env:LOCALAPPDATA
    $pathIgnoredThrew = $false; $pathIgnoredMsg = ''
    try {
        $env:PATH = ''; $env:LOCALAPPDATA = $decoyLocalAppData
        try { Resolve-KIDesktopControlWinApp -PackageRoot $PackageRoot -KIStackRoot $rootEmpty -Internal_VersionProbeOverride $probe061 | Out-Null }
        catch { $pathIgnoredThrew = $true; $pathIgnoredMsg = [string]$_.Exception.Message }
    } finally { $env:PATH = $savedPath; $env:LOCALAPPDATA = $savedLAD }
    $checks.pathAndWindowsAppsIgnored = [ordered]@{
        threw = $pathIgnoredThrew
        mentionsCentralProvisioning = ($pathIgnoredMsg -match '(?i)nicht zentral provisioniert')
        neverReturnedDecoy = ($pathIgnoredMsg -notmatch 'DECOY|WindowsApps')
        configDisablesDevFallback = (-not [bool]$fastConfig.winappResolver.allowDevelopmentFallback)
    }
    if ($checks.pathAndWindowsAppsIgnored.Values -contains $false) { $fail.Add('pathAndWindowsAppsIgnored: ' + ($checks.pathAndWindowsAppsIgnored | ConvertTo-Json -Compress)) }

    # === 3: a unique window is required =====================================================
    $twoWindows = Invoke-DCOp -Operation 'get_value' -Request @{ application = 'notepad'; element = @{ automationId = 'TextBox1' } } -Scenario @{
        windows = @(
            [pscustomobject]@{ hwnd = 1001; title = 'Editor A'; pid = 4242; processName = 'notepad'; width = 800; height = 600 },
            [pscustomobject]@{ hwnd = 1002; title = 'Editor B'; pid = 4243; processName = 'notepad'; width = 800; height = 600 }
        )
    }
    $noWindow = Invoke-DCOp -Operation 'get_value' -Request @{ hwnd = 9999; element = @{ automationId = 'TextBox1' } } -Scenario @{ windows = @() }
    $checks.uniqueWindowRequired = [ordered]@{
        ambiguousBlocked = ([string]$twoWindows.status -eq 'WindowAmbiguous' -and -not $twoWindows.success)
        missingBlocked = ([string]$noWindow.status -eq 'WindowNotFound' -and -not $noWindow.success)
    }
    if ($checks.uniqueWindowRequired.Values -contains $false) { $fail.Add('uniqueWindowRequired: ' + ($checks.uniqueWindowRequired | ConvertTo-Json -Compress)) }

    # === 4: a unique element is required ====================================================
    $twoElements = Invoke-DCOp -Operation 'get_value' -Request @{ hwnd = 1001; element = @{ controlType = 'Edit' } } -Scenario @{
        elements = @(
            [pscustomobject]@{ automationId = 'A'; name = 'One'; controlType = 'Edit'; className = 'Edit'; selector = 'sel-a' },
            [pscustomobject]@{ automationId = 'B'; name = 'Two'; controlType = 'Edit'; className = 'Edit'; selector = 'sel-b' }
        )
    }
    $checks.uniqueElementRequired = [ordered]@{ ambiguousBlocked = ([string]$twoElements.status -eq 'ElementAmbiguous' -and -not $twoElements.success) }
    if ($checks.uniqueElementRequired.Values -contains $false) { $fail.Add('uniqueElementRequired: ' + ($checks.uniqueElementRequired | ConvertTo-Json -Compress)) }

    # === 5: disabled / offscreen elements block MUTATION (pure reads still allowed) ==========
    $disabled = Invoke-DCOp -Operation 'invoke' -Request @{ hwnd = 1001; element = @{ automationId = 'TextBox1' } } -Scenario @{ properties = [pscustomobject]@{ controlType = 'Button'; isEnabled = $false; isOffscreen = $false } }
    $offscreen = Invoke-DCOp -Operation 'invoke' -Request @{ hwnd = 1001; element = @{ automationId = 'TextBox1' } } -Scenario @{ properties = [pscustomobject]@{ controlType = 'Button'; isEnabled = $true; isOffscreen = $true } }
    $readDisabled = Invoke-DCOp -Operation 'get_properties' -Request @{ hwnd = 1001; element = @{ automationId = 'TextBox1' } } -Scenario @{ properties = [pscustomobject]@{ controlType = 'Button'; isEnabled = $false; isOffscreen = $false } }
    $checks.disabledOffscreenBlocked = [ordered]@{
        mutationOnDisabledBlocked = ([string]$disabled.status -eq 'ElementContractFailed' -and -not $disabled.success)
        mutationOnOffscreenBlocked = ([string]$offscreen.status -eq 'ElementContractFailed' -and -not $offscreen.success)
        readOnDisabledStillAllowed = ([bool]$readDisabled.success -and [string]$readDisabled.status -eq 'OK')
    }
    if ($checks.disabledOffscreenBlocked.Values -contains $false) { $fail.Add('disabledOffscreenBlocked: ' + ($checks.disabledOffscreenBlocked | ConvertTo-Json -Compress)) }

    # === 6: stale window/element is always re-resolved (never a passed snapshot) ============
    $scn6 = @{}
    $inv6 = New-DCFakeInvoker -Scenario $scn6
    $null = Invoke-KIDesktopControlOperation -Operation 'set_value' -Request (@{ hwnd = 1001; expectedProcessName = 'notepad'; element = @{ automationId = 'TextBox1' }; value = 'X' } | ConvertTo-Json) `
        -PackageRoot $PackageRoot -TargetRoot $scratch -Config $fastConfig -Policy $policy -Internal_ResolvedWinApp $fakeResolved -Internal_WinAppInvokerOverride $inv6 -Internal_LiveProcessOverride $liveNotepad -Internal_SkipAudit
    # Caller's identity says controlType 'Edit'; the freshly re-inspected element is now a
    # 'Button' -> it is NOT matched/acted on with the stale assumption (fail closed).
    $changedElement = Invoke-DCOp -Operation 'invoke' -Request @{ hwnd = 1001; element = @{ automationId = 'ExpectedId'; controlType = 'Edit' } } -Scenario @{
        elements = @([pscustomobject]@{ automationId = 'ExpectedId'; name = 'X'; controlType = 'Button'; className = 'Button'; selector = 'sel-x' })
    }
    $checks.staleReResolution = [ordered]@{
        listWindowsCalledFresh = (@($scn6.callLog | Where-Object { $_ -match 'ui list-windows' }).Count -ge 1)
        inspectCalledFresh = (@($scn6.callLog | Where-Object { $_ -match 'ui inspect' }).Count -ge 1)
        getPropertyCalledFresh = (@($scn6.callLog | Where-Object { $_ -match 'ui get-property' }).Count -ge 1)
        changedElementNotActedOn = ([string]$changedElement.status -in @('ElementNotFound', 'ElementContractFailed') -and -not $changedElement.success)
    }
    if ($checks.staleReResolution.Values -contains $false) { $fail.Add('staleReResolution: ' + ($checks.staleReResolution | ConvertTo-Json -Compress)) }

    # === 7: secret / credential policy blocks READ and WRITE ================================
    $secretGet = Invoke-DCOp -Operation 'get_value' -Request @{ hwnd = 1001; element = @{ automationId = 'pwd' } } -Scenario @{
        elements = @([pscustomobject]@{ automationId = 'pwd'; name = 'Password'; controlType = 'Edit'; className = 'PasswordBox'; selector = 'sel-pwd' })
        properties = [pscustomobject]@{ controlType = 'Edit'; isEnabled = $true; isOffscreen = $false; isPassword = $true; className = 'PasswordBox' }
    }
    $secretSet = Invoke-DCOp -Operation 'set_value' -Request @{ hwnd = 1001; element = @{ automationId = 'pwd' }; value = 'hunter2' } -Scenario @{
        elements = @([pscustomobject]@{ automationId = 'pwd'; name = 'Password'; controlType = 'Edit'; className = 'PasswordBox'; selector = 'sel-pwd' })
        properties = [pscustomobject]@{ controlType = 'Edit'; isEnabled = $true; isOffscreen = $false; isPassword = $true; className = 'PasswordBox' }
    }
    $processSignal = Test-KIDesktopControlSecretContext -Policy $policy -ProcessName 'keepassxc' -ControlType 'Edit' -Name 'Entry'
    $checks.secretPolicyBlocks = [ordered]@{
        readBlocked = ([string]$secretGet.status -eq 'SecretContextBlocked' -and -not $secretGet.success)
        writeBlocked = ([string]$secretSet.status -eq 'SecretContextBlocked' -and -not $secretSet.success)
        isPasswordNotSoleGuard = ([bool]$policy.secretContext.isPasswordAloneIsNotSufficientGuard)
        processNameSignalCounts = ([bool]$processSignal.block)
    }
    if ($checks.secretPolicyBlocks.Values -contains $false) { $fail.Add('secretPolicyBlocks: ' + ($checks.secretPolicyBlocks | ConvertTo-Json -Compress)) }

    # === 8: Explorer address-bar IsPassword false positive -- allowed ONLY via narrow exception
    $fpAllowed = Test-KIDesktopControlSecretContext -Policy $policy -ProcessName 'explorer' -ControlType 'Edit' -Name 'Address' -AutomationId '' -ClassName 'Address Band Root' -UiAProtectionFlag $true
    $fpDeniedWrongProc = Test-KIDesktopControlSecretContext -Policy $policy -ProcessName 'notepad' -ControlType 'Edit' -Name 'Address' -ClassName 'Address Band Root' -UiAProtectionFlag $true
    $fpDeniedRealSignal = Test-KIDesktopControlSecretContext -Policy $policy -ProcessName 'explorer' -ControlType 'Edit' -Name 'Password' -ClassName 'Address Band Root' -UiAProtectionFlag $true
    $checks.explorerAddressBarException = [ordered]@{
        allowedForExplorerAddressEdit = ($fpAllowed.secret -and -not $fpAllowed.block -and [string]$fpAllowed.exception -eq 'explorer-address-and-breadcrumb-edit')
        notAllowedForNonExplorer = ($fpDeniedWrongProc.block -and $null -eq $fpDeniedWrongProc.exception)
        notAllowedWhenNameLooksLikeSecret = ($fpDeniedRealSignal.block -and $null -eq $fpDeniedRealSignal.exception)
        noBareNameAllowlist = (-not (($policy | ConvertTo-Json -Depth 20) -match '"(Address|Breadcrumb)"\s*(,|\])'))
    }
    if ($checks.explorerAddressBarException.Values -contains $false) { $fail.Add('explorerAddressBarException: ' + ($checks.explorerAddressBarException | ConvertTo-Json -Compress)) }

    # === 9: set_value needs an independent readback ========================================
    $setProven = Invoke-DCOp -Operation 'set_value' -Request @{ hwnd = 1001; element = @{ automationId = 'TextBox1' }; value = 'KIStackDC' } -Scenario @{ setValueApplies = $true }
    $setUnproven = Invoke-DCOp -Operation 'set_value' -Request @{ hwnd = 1001; element = @{ automationId = 'TextBox1' }; value = 'KIStackDC' } -Scenario @{ setValueApplies = $false; value = 'unchanged' }
    $checks.setValueNeedsReadback = [ordered]@{
        provenSucceeds = ($setProven.success -and [string]$setProven.status -eq 'OK' -and [bool]$setProven.postcondition.proven)
        unprovenFailsDespiteExit0 = (-not $setUnproven.success -and [string]$setUnproven.status -eq 'PostconditionNotProven' -and [int]$setUnproven.action.exitCode -eq 0)
        unprovenCarriesEvidence = (@($setUnproven.evidence).Count -ge 1)
    }
    if ($checks.setValueNeedsReadback.Values -contains $false) { $fail.Add('setValueNeedsReadback: ' + ($checks.setValueNeedsReadback | ConvertTo-Json -Compress)) }

    # === 10: invoke needs re-observation / postcondition ==================================
    $invokeProven = Invoke-DCOp -Operation 'invoke' -Request @{ hwnd = 1001; element = @{ automationId = 'Btn' } } -Scenario @{
        elements = @([pscustomobject]@{ automationId = 'Btn'; name = 'Go'; controlType = 'Button'; className = 'Button'; selector = 'sel-btn' })
        elementsAfterInvoke = @(
            [pscustomobject]@{ automationId = 'Btn'; name = 'Go'; controlType = 'Button'; className = 'Button'; selector = 'sel-btn' },
            [pscustomobject]@{ automationId = 'New'; name = 'Appeared'; controlType = 'Text'; className = 'Static'; selector = 'sel-new' }
        )
    }
    $invokeUnproven = Invoke-DCOp -Operation 'invoke' -Request @{ hwnd = 1001; element = @{ automationId = 'Btn' } } -Scenario @{
        elements = @([pscustomobject]@{ automationId = 'Btn'; name = 'Go'; controlType = 'Button'; className = 'Button'; selector = 'sel-btn' })
    }
    $checks.invokeNeedsPostcondition = [ordered]@{
        provenSucceeds = ($invokeProven.success -and [bool]$invokeProven.postcondition.proven)
        unprovenFailsDespiteExit0 = (-not $invokeUnproven.success -and [string]$invokeUnproven.status -eq 'PostconditionNotProven' -and [int]$invokeUnproven.action.exitCode -eq 0)
    }
    if ($checks.invokeNeedsPostcondition.Values -contains $false) { $fail.Add('invokeNeedsPostcondition: ' + ($checks.invokeNeedsPostcondition | ConvertTo-Json -Compress)) }

    # === 11: a CLI exit 0 with no state change => success=false ===========================
    $checks.cliExitZeroIsNotSuccess = [ordered]@{
        setValue = (-not $setUnproven.success -and [int]$setUnproven.action.exitCode -eq 0 -and [bool]$setUnproven.action.cliSuccess)
        invoke = (-not $invokeUnproven.success -and [int]$invokeUnproven.action.exitCode -eq 0)
        blockedReasonExplains = ([string]$setUnproven.blockedReason -match '(?i)Exitcode allein')
    }
    if ($checks.cliExitZeroIsNotSuccess.Values -contains $false) { $fail.Add('cliExitZeroIsNotSuccess: ' + ($checks.cliExitZeroIsNotSuccess | ConvertTo-Json -Compress)) }

    # === 12: a bare selector is not sufficient identity ===================================
    $selectorOnly = Invoke-DCOp -Operation 'invoke' -Request @{ hwnd = 1001; element = @{ selector = 'sel-textbox1' } } -Scenario @{}
    $checks.selectorAloneInsufficient = [ordered]@{
        blocked = ([string]$selectorOnly.status -eq 'ElementContractFailed' -and -not $selectorOnly.success)
        policyRejectsStaleSelectorOnly = ([bool]$policy.targetContract.element.rejectStaleSelectorOnlyIdentity)
    }
    if ($checks.selectorAloneInsufficient.Values -contains $false) { $fail.Add('selectorAloneInsufficient: ' + ($checks.selectorAloneInsufficient | ConvertTo-Json -Compress)) }

    # === 13: a minimized / non-interactable window blocks mutation (observation still ok) ===
    $minWin = [pscustomobject]@{ hwnd = 1001; title = 'Editor'; pid = 4242; processName = 'notepad'; width = 0; height = 0; windowState = 'minimized' }
    $mutateMinimized = Invoke-DCOp -Operation 'set_value' -Request @{ hwnd = 1001; element = @{ automationId = 'TextBox1' }; value = 'x' } -Scenario @{ windows = @($minWin) }
    $observeMinimized = Invoke-DCOp -Operation 'inspect_window' -Request @{ hwnd = 1001 } -Scenario @{ windows = @($minWin) }
    $checks.minimizedWindowBlocksMutation = [ordered]@{
        mutationBlocked = ([string]$mutateMinimized.status -eq 'WindowNotInteractable' -and -not $mutateMinimized.success)
        noAutoRestore = (-not [bool]$policy.windowState.autoRestoreMinimized)
        observationStillAllowed = ([bool]$observeMinimized.success)
    }
    if ($checks.minimizedWindowBlocksMutation.Values -contains $false) { $fail.Add('minimizedWindowBlocksMutation: ' + ($checks.minimizedWindowBlocksMutation | ConvertTo-Json -Compress)) }

    # === 14: raw send-input / global keyboard is not exposed ===============================
    $sendInput = Invoke-DCOp -Operation 'send_input' -Request @{ hwnd = 1001 } -Scenario @{}
    $dispatcher = Get-Content -LiteralPath (Join-Path $PackageRoot 'Invoke-KIStackDesktopControl.ps1') -Raw
    $dispatcherValidateSet = if ($dispatcher -match "ValidateSet\(([^)]*)\)\]\s*\r?\n\s*\[string\]\`$Operation") { $Matches[1] } else { '' }
    $checks.rawSendInputNotExposed = [ordered]@{
        operationRejected = ([string]$sendInput.status -eq 'OperationNotPermitted' -and -not $sendInput.success)
        classificationRejected = ((Get-KIDesktopControlOperationClass -Operation 'send_input' -Policy $policy -Config $fastConfig) -eq 'rejected')
        notInDispatcherValidateSet = ($dispatcherValidateSet -notmatch 'send.input|send.keys' -and $dispatcher -notmatch "'send_input'")
        policyListsNeverExposed = (@($policy.actionClassification.neverExposed) -contains 'send_input')
    }
    if ($checks.rawSendInputNotExposed.Values -contains $false) { $fail.Add('rawSendInputNotExposed: ' + ($checks.rawSendInputNotExposed | ConvertTo-Json -Compress)) }

    # === 15: no arbitrary raw winapp command ==============================================
    $rawCmd = Invoke-DCOp -Operation 'get_value' -Request @{ hwnd = 1001; element = @{ automationId = 'TextBox1' }; command = 'ui screenshot -o C:\x.png' } -Scenario @{}
    $rawArgs = Invoke-DCOp -Operation 'invoke' -Request @{ hwnd = 1001; element = @{ automationId = 'TextBox1' }; winappArgs = @('ui', 'send-keys', 'x') } -Scenario @{}
    $rawOp = Invoke-DCOp -Operation 'raw_winapp' -Request @{} -Scenario @{}
    $checks.noArbitraryRawWinApp = [ordered]@{
        rawCommandFieldRejected = ([string]$rawCmd.status -eq 'RawArgumentsRejected' -and -not $rawCmd.success)
        rawArgsFieldRejected = ([string]$rawArgs.status -eq 'RawArgumentsRejected' -and -not $rawArgs.success)
        rawOperationRejected = ([string]$rawOp.status -eq 'OperationNotPermitted' -and -not $rawOp.success)
    }
    if ($checks.noArbitraryRawWinApp.Values -contains $false) { $fail.Add('noArbitraryRawWinApp: ' + ($checks.noArbitraryRawWinApp | ConvertTo-Json -Compress)) }

    # === 16: no new runtime / port / credential ==========================================
    $manifest = Get-Content -LiteralPath (Join-Path $PackageRoot 'MANIFEST.json') -Raw | ConvertFrom-Json
    # Non-comment code of the shipped modules + dispatcher only (not this test file, not comments).
    $shippedCode = @('DesktopControl.psm1', 'DesktopControl.Policy.psm1', 'Invoke-KIStackDesktopControl.ps1') | ForEach-Object {
        (Get-Content -LiteralPath (Join-Path $PackageRoot $_) | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }
    $shippedCode = $shippedCode -join "`n"
    $cfgRaw = Get-Content -LiteralPath (Join-Path $PackageRoot 'Config/desktop-control.config.json') -Raw
    $checks.noNewRuntimePortCredential = [ordered]@{
        manifestDeclaresNone = ((-not [bool]$manifest.introducesRuntime) -and (-not [bool]$manifest.introducesPort) -and (-not [bool]$manifest.introducesCredential))
        noHttpListenerOrServer = ($shippedCode -notmatch '(?i)HttpListener|System\.Net\.Sockets\.TcpListener|New-WebServiceProxy|\.Bind\(|-Port\s+\d')
        noCredentialFunctions = ($shippedCode -notmatch '(?i)(Save|New)-KI\w*Credential|ConvertFrom-SecureString|ConvertTo-SecureString|Protect(edData)?\b|CredentialCache')
        configHasNoPortOrKey = ($cfgRaw -notmatch '(?i)"port"\s*:|"apikey"|"credential"|"secret"')
    }
    if ($checks.noNewRuntimePortCredential.Values -contains $false) { $fail.Add('noNewRuntimePortCredential: ' + ($checks.noNewRuntimePortCredential | ConvertTo-Json -Compress)) }

    # === 17: Resolve -> Validate -> Act -> Re-observe -> Verify ordering + read-only success =
    $scn17 = @{ setValueApplies = $true }
    $inv17 = New-DCFakeInvoker -Scenario $scn17
    $null = Invoke-KIDesktopControlOperation -Operation 'set_value' -Request (@{ hwnd = 1001; expectedProcessName = 'notepad'; element = @{ automationId = 'TextBox1' }; value = 'ordered' } | ConvertTo-Json) `
        -PackageRoot $PackageRoot -TargetRoot $scratch -Config $fastConfig -Policy $policy -Internal_ResolvedWinApp $fakeResolved -Internal_WinAppInvokerOverride $inv17 -Internal_LiveProcessOverride $liveNotepad -Internal_SkipAudit
    $log = @($scn17.callLog)
    $iList = [Array]::FindIndex($log, [Predicate[string]] { param($x) $x -match 'ui list-windows' })
    $iInspect = [Array]::FindIndex($log, [Predicate[string]] { param($x) $x -match 'ui inspect' })
    $iSet = [Array]::FindIndex($log, [Predicate[string]] { param($x) $x -match 'ui set-value' })
    $iReadback = [Array]::FindLastIndex($log, [Predicate[string]] { param($x) $x -match 'ui get-value' })
    $listOnly = Invoke-DCOp -Operation 'list_windows' -Request @{} -Scenario @{}
    $checks.rvarvOrdering = [ordered]@{
        resolveBeforeValidate = ($iList -ge 0 -and $iInspect -gt $iList)
        validateBeforeAct = ($iInspect -ge 0 -and $iSet -gt $iInspect)
        actBeforeVerify = ($iSet -ge 0 -and $iReadback -gt $iSet)
        readOnlySucceedsWithoutPostcondition = ([bool]$listOnly.success -and [string]$listOnly.mode -eq 'read-only')
    }
    if ($checks.rvarvOrdering.Values -contains $false) { $fail.Add('rvarvOrdering: ' + ($checks.rvarvOrdering | ConvertTo-Json -Compress)) }

    # === 18: scroll / scroll_into_view fail closed (backend capability unverified) =========
    $scroll = Invoke-DCOp -Operation 'scroll' -Request @{ hwnd = 1001; element = @{ automationId = 'TextBox1' } } -Scenario @{}
    $checks.scrollFailsClosed = [ordered]@{
        notSuccess = (-not $scroll.success)
        statusIsBackendUnverified = ([string]$scroll.status -eq 'BackendCapabilityUnverified')
    }
    if ($checks.scrollFailsClosed.Values -contains $false) { $fail.Add('scrollFailsClosed: ' + ($checks.scrollFailsClosed | ConvertTo-Json -Compress)) }

    # === 19: audit record carries every required field ====================================
    $auditRoot = New-DCTestRoot 'audit'
    $scn19 = @{ setValueApplies = $true }
    $inv19 = New-DCFakeInvoker -Scenario $scn19
    $null = Invoke-KIDesktopControlOperation -Operation 'set_value' -Request (@{ hwnd = 1001; expectedProcessName = 'notepad'; element = @{ automationId = 'TextBox1' }; value = 'audited' } | ConvertTo-Json) `
        -PackageRoot $PackageRoot -TargetRoot $auditRoot -Config $fastConfig -Policy $policy -Internal_ResolvedWinApp $fakeResolved -Internal_WinAppInvokerOverride $inv19 -Internal_LiveProcessOverride $liveNotepad
    $auditFile = Get-ChildItem -LiteralPath (Join-Path $auditRoot 'state\desktop-control\logs\actions') -Filter '*.jsonl' | Select-Object -First 1
    $rec = (Get-Content -LiteralPath $auditFile.FullName | Select-Object -First 1) | ConvertFrom-Json
    $checks.auditRecordComplete = [ordered]@{
        fileIsJsonl = ($null -ne $auditFile -and $auditFile.Extension -eq '.jsonl')
        hasTimestamp = (-not [string]::IsNullOrWhiteSpace([string]$rec.timestampUtc))
        hasOperation = ([string]$rec.operation -eq 'set_value')
        hasTargetHwnd = ($null -ne $rec.targetHwnd)
        hasProcess = ([string]$rec.process -eq 'notepad')
        hasWindowTitle = (-not [string]::IsNullOrWhiteSpace([string]$rec.windowTitle))
        hasElementIdentity = (-not [string]::IsNullOrWhiteSpace([string]$rec.elementIdentity))
        hasPolicyResult = ($null -ne $rec.policyResult)
        hasActionResult = ($null -ne $rec.actionResult)
        hasPostconditionResult = ($null -ne $rec.postconditionResult)
        hasWinappExitCode = ($null -ne $rec.winappExitCode)
        hasEvidencePath = (-not [string]::IsNullOrWhiteSpace([string]$rec.evidencePath))
    }
    if ($checks.auditRecordComplete.Values -contains $false) { $fail.Add('auditRecordComplete: ' + ($checks.auditRecordComplete | ConvertTo-Json -Compress)) }

    # === 20: component self-check (static, no GUI) ========================================
    $selfCheck = Test-KIDesktopControl -PackageRoot $PackageRoot -TargetRoot $scratch -KIStackRoot $rootOk -Internal_VersionProbeOverride $probe061
    $checks.componentSelfCheck = [ordered]@{
        passed = ([bool]$selfCheck.passed)
        vendoredResolverMatchesSource = ([bool]$selfCheck.checks.vendoredResolverMatchesCanonicalSource)
        dispatcherExposesNoSeams = ([bool]$selfCheck.checks.dispatcherExposesNoInternalSeams)
        devFallbackDisabled = ([bool]$selfCheck.checks.developmentFallbackDisabled)
    }
    if ($checks.componentSelfCheck.Values -contains $false) { $fail.Add('componentSelfCheck: ' + ($checks.componentSelfCheck | ConvertTo-Json -Compress)) }

    # === 21: the OPERATOR/INSTALLER dispatcher exposes NO test/development seam ==============
    #        (SkipResolverProbe, AllowDevelopmentFallback, VersionProbeOverride, Internal_*, ...)
    #        and Audit/Validate/Status route to the real resolver probe (no -SkipResolverProbe).
    $dispatcherSrc = Get-Content -LiteralPath (Join-Path $PackageRoot 'Invoke-KIStackDesktopControl.ps1') -Raw
    $dispatcherParamBlock = ($dispatcherSrc -split '(?m)^\)\s*$', 2)[0]
    $forbiddenSeams = @('SkipResolverProbe', 'SkipVersionProbe', 'AllowDevelopmentFallback', 'VersionProbeOverride', 'WinAppInvokerOverride', 'ResolvedWinApp', 'LiveProcessOverride', 'SourceManifestOverride', 'ArtifactFileOverride', 'Internal_', 'SkipAudit')
    $seamHits = @($forbiddenSeams | Where-Object { $dispatcherParamBlock -match [regex]::Escape($_) })
    $auditValidateStatusRoutingClean = (
        ($dispatcherSrc -match "'Audit'\s*\{\s*Test-KIDesktopControl[^}]*\}") -and
        ($dispatcherSrc -notmatch "Test-KIDesktopControl[^}\r\n]*-SkipResolverProbe") -and
        ($dispatcherSrc -notmatch "Get-KIDesktopControlStatus[^}\r\n]*-SkipResolverProbe")
    )
    $checks.dispatcherHasNoSeams = [ordered]@{
        noForbiddenSeamInPublicParamBlock = ($seamHits.Count -eq 0)
        seamHits = ($seamHits -join ',')
        auditValidateStatusUseRealResolverProbe = $auditValidateStatusRoutingClean
        skipResolverProbeStillExistsAsInternalModuleSeam = (
            (Get-Command Test-KIDesktopControl).Parameters.ContainsKey('SkipResolverProbe') -and
            (Get-Command Get-KIDesktopControlStatus).Parameters.ContainsKey('SkipResolverProbe')
        )
    }
    $checks.dispatcherHasNoSeams.Remove('seamHits') | Out-Null
    if ($checks.dispatcherHasNoSeams.Values -contains $false) { $fail.Add('dispatcherHasNoSeams (hits=' + ($seamHits -join ',') + '): ' + ($checks.dispatcherHasNoSeams | ConvertTo-Json -Compress)) }

    # === 22: central provisioning -- Install to <TargetRoot>\tools\desktop-control\, idempotent
    $provRoot = New-DCTestRoot 'provision'
    $inst1 = Install-KIDesktopControl -PackageRoot $PackageRoot -TargetRoot $provRoot -Action 'Install'
    $installPaths = Get-KIDesktopControlInstallPaths -TargetRoot $provRoot
    $deployed = Test-KIDesktopControlDeployed -TargetRoot $provRoot -ExpectedVersion '0.1.0'
    $inst2 = Install-KIDesktopControl -PackageRoot $PackageRoot -TargetRoot $provRoot -Action 'Repair'
    # Corrupt one deployed file -> Repair must re-deploy and pass again.
    Add-Content -LiteralPath (Join-Path $installPaths.packageRoot 'MANIFEST.json') -Value 'corruption'
    $repaired = Install-KIDesktopControl -PackageRoot $PackageRoot -TargetRoot $provRoot -Action 'Repair'
    $altRoot = New-DCTestRoot 'provision-alt'
    $instAlt = Install-KIDesktopControl -PackageRoot $PackageRoot -TargetRoot $altRoot -Action 'Install'
    $checks.centralProvisioning = [ordered]@{
        installedUnderToolsDesktopControl = ([string]$inst1.status -eq 'Installed' -and $installPaths.installRoot -eq (Join-Path ([IO.Path]::GetFullPath($provRoot)) 'tools\desktop-control') -and (Test-Path -LiteralPath (Join-Path $provRoot 'tools\desktop-control\current\Invoke-KIStackDesktopControl.ps1') -PathType Leaf))
        probeStampWritten = ((Get-Content -LiteralPath (Join-Path $provRoot 'tools\desktop-control\VERSION') -Raw).Trim() -eq '0.1.0')
        markerWritten = (Test-Path -LiteralPath $installPaths.marker -PathType Leaf)
        deployedComplianceOk = ([bool]$deployed.ok)
        idempotentRepairIsNoOp = ([string]$inst2.status -eq 'SkippedAlreadyCompliant' -and -not [bool]$inst2.mutatesTarget)
        repairReDeploysAfterCorruption = ([string]$repaired.status -eq 'Repaired' -and [bool](Test-KIDesktopControlDeployed -TargetRoot $provRoot).ok)
        targetRootParametric = ($instAlt.status -eq 'Installed' -and (Get-KIDesktopControlInstallPaths -TargetRoot $altRoot).installRoot -ne $installPaths.installRoot)
        noRuntimePortCredentialService = (
            (-not (Test-Path -LiteralPath (Join-Path $provRoot 'state\desktop-control\credential.json'))) -and
            (-not (Test-Path -LiteralPath (Join-Path $provRoot 'modules\desktop-control'))) -and
            (-not [bool](Get-Content -LiteralPath $installPaths.marker -Raw | ConvertFrom-Json).winappDependency.provisionedByThisComponent) -and
            (-not (Get-Content -LiteralPath $installPaths.marker -Raw | ConvertFrom-Json).PSObject.Properties['port']) -and
            (-not (Get-Content -LiteralPath $installPaths.marker -Raw | ConvertFrom-Json).PSObject.Properties['credential'])
        )
        rollbackRestoresPreState = ([string](Restore-KIDesktopControl -BackupPath $inst1.backupPath -PackageRoot $PackageRoot -TargetRoot $provRoot).status -eq 'Completed' -and -not (Test-Path -LiteralPath $installPaths.packageRoot))
    }
    if ($checks.centralProvisioning.Values -contains $false) { $fail.Add('centralProvisioning: ' + ($checks.centralProvisioning | ConvertTo-Json -Compress)) }

    # === 23: Complete Installer contract wiring (static) ==================================
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PackageRoot '..\..\..'))
    $components = (Get-Content -LiteralPath (Join-Path $repoRoot 'tools\complete-installer\current\Contracts\COMPONENTS.json') -Raw | ConvertFrom-Json -Depth 30).components
    $reqPayloads = (Get-Content -LiteralPath (Join-Path $repoRoot 'tools\complete-installer\current\Contracts\REQUIRED-PAYLOADS.json') -Raw | ConvertFrom-Json -Depth 30).payloads
    $orchestrator = Get-Content -LiteralPath (Join-Path $repoRoot 'tools\complete-installer\current\CompleteInstaller.psm1') -Raw
    $dc = @($components | Where-Object id -eq 'desktop-control')
    $checks.completeInstallerWiring = [ordered]@{
        componentsJsonEntry = ($dc.Count -eq 1 -and [string]$dc[0].version -eq '0.1.0' -and [bool]$dc[0].installable -and [string]$dc[0].isolation -eq 'A' -and [string]$dc[0].source -eq 'Payload/DesktopControl')
        requiresWinapp = ($dc.Count -eq 1 -and @($dc[0].requires) -contains 'winapp')
        orderAfterWinapp = ($dc.Count -eq 1 -and [int]$dc[0].order -gt [int](@($components | Where-Object id -eq 'winapp')[0].order))
        textProbeOnVersionStamp = ($dc.Count -eq 1 -and [string]$dc[0].probe.type -eq 'text' -and [string]$dc[0].probe.path -eq 'tools/desktop-control/VERSION')
        requiredPayloadEntry = (@($reqPayloads | Where-Object key -eq 'DesktopControl').Count -eq 1)
        payloadSourceMatchesComponentSource = ($dc.Count -eq 1 -and [string]$dc[0].source -eq ('Payload/' + [string]@($reqPayloads | Where-Object key -eq 'DesktopControl')[0].key))
        complianceFunctionDefined = $orchestrator.Contains('function Test-KICompleteDesktopControlCompliant')
        complianceWiredIntoPlan = $orchestrator.Contains("if([string]`$component.id-eq'desktop-control'-and`$null-eq`$FixtureState){`$compliant=`$compliant-and(Test-KICompleteDesktopControlCompliant")
        complianceWiredIntoResumeRecheck = $orchestrator.Contains("if([string]`$step.id-eq'desktop-control'){`$resumeCompliant=`$resumeCompliant-and(Test-KICompleteDesktopControlCompliant")
        primaryStepLoopHandler = $orchestrator.Contains("elseif (`$step.id -eq 'desktop-control')")
        versionSourceTypeOwnFile = ($dc.Count -eq 1 -and [string]$dc[0].versionSourceType -eq 'own-version-file' -and [string]$dc[0].packageIdentity.path -eq 'tools/desktop-control/current/VERSION')
    }
    if ($checks.completeInstallerWiring.Values -contains $false) { $fail.Add('completeInstallerWiring: ' + ($checks.completeInstallerWiring | ConvertTo-Json -Compress)) }

    # === 24: identityMatch resolves controlType (+ automationId/name/className) through the
    #        same casing/alias set as the other helpers -- a real winapp element reports control
    #        type as `type`, not `controlType`. Contract must NOT loosen: a genuine mismatch
    #        still fails.
    $ecReq = [pscustomobject]@{ automationId = 'Text Area'; name = 'Text Area'; controlType = 'Document' }
    $ecElement = [pscustomobject]@{ type = 'Document'; automationId = 'Text Area'; name = 'Text Area' }
    $ecMatch = Test-KIDesktopControlElementContract -Policy $policy -Element $ecElement -Properties $ecElement -MatchCount 1 -RequestedIdentity $ecReq
    $ecMismatchReq = [pscustomobject]@{ automationId = 'Text Area'; name = 'Text Area'; controlType = 'Edit' }
    $ecMismatch = Test-KIDesktopControlElementContract -Policy $policy -Element $ecElement -Properties $ecElement -MatchCount 1 -RequestedIdentity $ecMismatchReq
    # PascalCase alias parity for automationId/name/className.
    $ecPascalReq = [pscustomobject]@{ automationId = 'X1'; name = 'Body'; className = 'Edit'; controlType = 'Document' }
    $ecPascalElement = [pscustomobject]@{ Type = 'Document'; AutomationId = 'X1'; Name = 'Body'; ClassName = 'Edit' }
    $ecPascal = Test-KIDesktopControlElementContract -Policy $policy -Element $ecPascalElement -Properties $ecPascalElement -MatchCount 1 -RequestedIdentity $ecPascalReq
    $checks.identityMatchAliasResolution = [ordered]@{
        documentTypeAliasMatches = ([bool]$ecMatch.checks.identityMatch -and [bool]$ecMatch.ok)
        genuineControlTypeMismatchStillFails = (-not [bool]$ecMismatch.checks.identityMatch -and -not [bool]$ecMismatch.ok)
        pascalCaseAliasesMatch = ([bool]$ecPascal.checks.identityMatch)
        usedDurableIdentityFlagSet = ([bool]$ecMatch.usedDurableIdentity)
    }
    if ($checks.identityMatchAliasResolution.Values -contains $false) { $fail.Add('identityMatchAliasResolution: ' + ($checks.identityMatchAliasResolution | ConvertTo-Json -Compress)) }

    # === 25: reconcile compliance is measured against the SOURCE payload, never merely against
    #        the target's own SHA256SUMS.txt. A changed payload at an unchanged component
    #        VERSION (0.1.0 == 0.1.0) must make the deployed target non-compliant, a Repair must
    #        redeploy the source state, and a second Repair with no further change is a NoOp.
    $regenSums = {
        param([string]$Root)
        $sumPath = Join-Path $Root 'SHA256SUMS.txt'
        $out = Get-Content -LiteralPath $sumPath | ForEach-Object {
            if ($_ -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
                $f = Join-Path $Root ($Matches[2].Replace('/', [IO.Path]::DirectorySeparatorChar))
                "$((Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant()) *$($Matches[2])"
            } else { $_ }
        }
        [IO.File]::WriteAllLines($sumPath, $out, [Text.UTF8Encoding]::new($false))
    }
    $srcCopy = New-DCTestRoot 'parity-src'
    Copy-Item -Path (Join-Path $PackageRoot '*') -Destination $srcCopy -Recurse -Force
    $parityRoot = New-DCTestRoot 'parity-tgt'
    $pInstall = Install-KIDesktopControl -PackageRoot $srcCopy -TargetRoot $parityRoot -Action 'Install'
    $pkgRoot = (Get-KIDesktopControlInstallPaths -TargetRoot $parityRoot).packageRoot

    # A: source and target identical => compliant, Repair is a NoOp.
    $aParity = Test-KIDesktopControlSourceParity -SourceRoot $srcCopy -TargetPackageRoot $pkgRoot
    $aRepair = Install-KIDesktopControl -PackageRoot $srcCopy -TargetRoot $parityRoot -Action 'Repair'

    # B: a deployed file is changed in place AND the target's own SHA256SUMS.txt is re-made
    #    self-consistent (an "old but internally consistent" deployment) => STILL non-compliant
    #    against the source, and Repair fixes it.
    Add-Content -LiteralPath (Join-Path $pkgRoot 'DesktopControl.Policy.psm1') -Value "`n# drifted in place, sums realigned"
    & $regenSums $pkgRoot
    $bTargetSumsSelfConsistent = Test-KIDesktopControlChecksums -PackageRoot $pkgRoot -ChecksumFile (Join-Path $pkgRoot 'SHA256SUMS.txt')
    $bDeployed = Test-KIDesktopControlDeployed -TargetRoot $parityRoot -ExpectedVersion '0.1.0' -SourceRoot $srcCopy
    $bRepair = Install-KIDesktopControl -PackageRoot $srcCopy -TargetRoot $parityRoot -Action 'Repair'
    $bParityAfter = Test-KIDesktopControlSourceParity -SourceRoot $srcCopy -TargetPackageRoot $pkgRoot

    # C: the SOURCE payload changes while the component VERSION stays 0.1.0 => the (still intact,
    #    still self-consistent) target is now non-compliant because it no longer matches source.
    Add-Content -LiteralPath (Join-Path $srcCopy 'DesktopControl.Policy.psm1') -Value "`n# source payload changed, same VERSION"
    & $regenSums $srcCopy
    $cVersionsEqual = ((Get-Content -LiteralPath (Join-Path $srcCopy 'VERSION') -Raw).Trim() -eq (Get-Content -LiteralPath (Join-Path $pkgRoot 'VERSION') -Raw).Trim())
    $cTargetStillSelfConsistent = Test-KIDesktopControlChecksums -PackageRoot $pkgRoot -ChecksumFile (Join-Path $pkgRoot 'SHA256SUMS.txt')
    $cDeployed = Test-KIDesktopControlDeployed -TargetRoot $parityRoot -ExpectedVersion '0.1.0' -SourceRoot $srcCopy

    # D: Repair rebuilds the target from the current source payload.
    $dRepair = Install-KIDesktopControl -PackageRoot $srcCopy -TargetRoot $parityRoot -Action 'Repair'
    $dParity = Test-KIDesktopControlSourceParity -SourceRoot $srcCopy -TargetPackageRoot $pkgRoot

    # E: a second Repair with nothing changed => SkippedAlreadyCompliant / mutatesTarget=false.
    $eRepair = Install-KIDesktopControl -PackageRoot $srcCopy -TargetRoot $parityRoot -Action 'Repair'

    # F: an extra, unexpected file under current\ => non-compliant; Repair drops it.
    Set-Content -LiteralPath (Join-Path $pkgRoot 'rogue-extra.txt') -Value 'x' -Encoding ascii -NoNewline
    $fDeployed = Test-KIDesktopControlDeployed -TargetRoot $parityRoot -ExpectedVersion '0.1.0' -SourceRoot $srcCopy
    $fRepair = Install-KIDesktopControl -PackageRoot $srcCopy -TargetRoot $parityRoot -Action 'Repair'
    $fDropped = -not (Test-Path -LiteralPath (Join-Path $pkgRoot 'rogue-extra.txt'))

    $checks.sourceParityReconcile = [ordered]@{
        a_identicalIsCompliant = ([bool]$aParity.ok -and [string]$aRepair.status -eq 'SkippedAlreadyCompliant' -and -not [bool]$aRepair.mutatesTarget)
        b_targetSelfConsistentButDriftedVsSource = ([bool]$bTargetSumsSelfConsistent -and -not [bool]$bDeployed.ok -and [string]$bDeployed.reason -match 'source-parity:content-drift')
        b_repairRedeploysAndIsClean = ([string]$bRepair.status -eq 'Repaired' -and [bool]$bRepair.mutatesTarget -and [bool]$bParityAfter.ok)
        c_sourceChangeAtSameVersionMakesTargetNoncompliant = ([bool]$cVersionsEqual -and [bool]$cTargetStillSelfConsistent -and -not [bool]$cDeployed.ok -and [string]$cDeployed.reason -match 'source-parity')
        d_repairRestoresSourceState = ([string]$dRepair.status -eq 'Repaired' -and [bool]$dRepair.mutatesTarget -and [bool]$dParity.ok)
        e_secondRepairIsNoOp = ([string]$eRepair.status -eq 'SkippedAlreadyCompliant' -and -not [bool]$eRepair.mutatesTarget)
        f_extraFileNoncompliantThenDropped = (-not [bool]$fDeployed.ok -and [string]$fDeployed.reason -match 'unexpected-target-file' -and [string]$fRepair.status -eq 'Repaired' -and $fDropped)
    }
    if ($checks.sourceParityReconcile.Values -contains $false) { $fail.Add('sourceParityReconcile: ' + ($checks.sourceParityReconcile | ConvertTo-Json -Compress)) }

    # === 26: -BackupRoot contract (2.18.1 hotfix) -- an externally-owned backup root is honored;
    #        omitting it keeps the exact prior standalone <TargetRoot>\backups\desktop-control
    #        behavior unchanged. =====================================================
    $brRoot = New-DCTestRoot 'backuproot-given'
    $externalBackupRoot = Join-Path $scratch 'external-backups\desktop-control'
    $brInstall = Install-KIDesktopControl -PackageRoot $PackageRoot -TargetRoot $brRoot -Action 'Install' -BackupRoot $externalBackupRoot
    $brStandaloneRoot = New-DCTestRoot 'backuproot-omitted'
    $brInstallStandalone = Install-KIDesktopControl -PackageRoot $PackageRoot -TargetRoot $brStandaloneRoot -Action 'Install'
    $checks.backupRootContract = [ordered]@{
        externalRootHonored = ([string]$brInstall.backupPath).StartsWith($externalBackupRoot)
        externalRollbackJsonExists = (Test-Path -LiteralPath $brInstall.backupPath -PathType Leaf)
        omittedKeepsStandaloneRoot = ([string]$brInstallStandalone.backupPath).StartsWith((Join-Path $brStandaloneRoot 'backups\desktop-control'))
    }
    if ($checks.backupRootContract.Values -contains $false) { $fail.Add('backupRootContract: ' + ($checks.backupRootContract | ConvertTo-Json -Compress)) }

    $passed = $fail.Count -eq 0
    [pscustomobject]@{ passed = $passed; checks = $checks; failures = @($fail) } | ConvertTo-Json -Depth 12
    if (-not $passed) { throw 'Desktop-Control-Regression fehlgeschlagen.' }
} finally {
    try { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

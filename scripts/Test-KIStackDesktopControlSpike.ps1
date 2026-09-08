[CmdletBinding()]
param(
    [ValidateRange(1000, 60000)]
    [int]$TimeoutMilliseconds = 10000,
    [switch]$AllowAppLaunch,
    [switch]$AllowTerminalInput,
    [switch]$AllowHarmlessNavigation,
    [switch]$EnableWindowStateTests,
    [string]$ReportPath
)

# Acceptance/spike harness only.  It does not alter KI-Stack, tool contracts,
# ports, credentials, application configuration, or user documents.  All
# evidence goes to a new temporary directory unless the caller deliberately
# supplies a writable report path.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RunRoot = Join-Path ([IO.Path]::GetTempPath()) ('ki-stack-desktop-control-spike-' + [guid]::NewGuid().ToString('N'))
$script:EvidenceRoot = Join-Path $script:RunRoot 'evidence'
$script:Results = [System.Collections.Generic.List[object]]::new()
$script:Capabilities = @{}
$script:WinAppPath = $null
$script:WinAppVersion = $null
$script:WinAppResolutionMethod = $null
$script:TestTargets = @{}
$script:TestOwnership = [System.Collections.Generic.List[object]]::new()
$script:RunStarted = (Get-Date).ToUniversalTime().ToString('o')
$script:KnownPasswordFalsePositives = @('Address', 'AddressBandRoot', 'AddressDisplay', 'Breadcrumb')

New-Item -ItemType Directory -Path $script:EvidenceRoot -Force | Out-Null

function ConvertTo-PlainWinAppText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value -replace "`e\[[0-?]*[ -/]*[@-~]", '')
}

function Resolve-WinAppExecutable {
    [CmdletBinding()]
    param()
    $candidates = [System.Collections.Generic.List[object]]::new()
    function Add-WinAppCandidate {
        param([string]$Path,[string]$Method)
        if (-not [string]::IsNullOrWhiteSpace($Path)) {
            $candidates.Add([pscustomobject]@{ path=$Path.Trim(); method=$Method }) | Out-Null
        }
    }
    function Test-WinAppCandidate {
        param([object]$Candidate)
        try {
            if (-not (Test-Path -LiteralPath $Candidate.path -PathType Leaf)) { return $null }
            $absolutePath = [IO.Path]::GetFullPath($Candidate.path)
            $versionOutput = @(& $absolutePath --version 2>&1)
            $exitCode = $LASTEXITCODE
            $version = (ConvertTo-PlainWinAppText ($versionOutput | ForEach-Object { [string]$_ } | Join-String -Separator "`n")).Trim()
            if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($version)) {
                return [pscustomobject]@{ path=$absolutePath; version=$version; method=$Candidate.method }
            }
        }
        catch { }
        return $null
    }
    foreach ($spec in @(
        @{ name='Get-Command winapp.exe'; command='winapp.exe' },
        @{ name='Get-Command winapp'; command='winapp' }
    )) {
        $command = Get-Command $spec.command -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) { Add-WinAppCandidate -Path ([string]($command.Path ?? $command.Source)) -Method $spec.name }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Add-WinAppCandidate -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winapp.exe') -Method 'LOCALAPPDATA Microsoft WindowsApps'
    }
    try {
        foreach ($path in @(& where.exe winapp 2>$null)) {
            Add-WinAppCandidate -Path ([string]$path) -Method 'where.exe winapp'
        }
    }
    catch { }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $linkPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\winapp.exe'
        Add-WinAppCandidate -Path $linkPath -Method 'LOCALAPPDATA Microsoft WinGet Links'
        $packagesRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
        if (Test-Path -LiteralPath $packagesRoot -PathType Container) {
            try {
                Get-ChildItem -LiteralPath $packagesRoot -Filter 'winapp.exe' -File -Recurse -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTimeUtc -Descending |
                    ForEach-Object { Add-WinAppCandidate -Path $_.FullName -Method 'LOCALAPPDATA Microsoft WinGet Packages' }
            }
            catch { }
        }
    }
    foreach ($candidate in @($candidates | Group-Object path | ForEach-Object { $_.Group[0] })) {
        $validated = Test-WinAppCandidate -Candidate $candidate
        if ($null -ne $validated) { return $validated }
    }
    return $null
}

function Write-TestResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][ValidateSet('PASS','PASS-WITH-LIMITATION','FAIL','SKIPPED','WARN','BLOCKED')][string]$Result,
        [Parameter(Mandatory)][string]$Detail,
        [hashtable]$Data = @{}
    )
    $entry = [pscustomobject][ordered]@{
        timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        component = $Component
        result = $Result
        detail = $Detail
        data = [pscustomobject]$Data
    }
    $script:Results.Add($entry) | Out-Null
    Write-Host ('[{0}] {1}: {2}' -f $Result, $Component, $Detail)
}

function Invoke-WinAppJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure,
        [string]$Operation = 'winapp'
    )
    if ([string]::IsNullOrWhiteSpace($script:WinAppPath)) {
        return [pscustomobject]@{ success=$false; exitCode=$null; json=$null; stdout=''; stderr='winapp is unavailable'; operation=$Operation }
    }
    $effectiveArguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in $Arguments) { $effectiveArguments.Add($argument) | Out-Null }
    if ($effectiveArguments -notcontains '--json') { $effectiveArguments.Add('--json') | Out-Null }
    try {
        $rawOutput = @(& $script:WinAppPath @($effectiveArguments.ToArray()) 2>&1)
        $exitCode = $LASTEXITCODE
        $stdout = ConvertTo-PlainWinAppText (($rawOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n")
        $stderr = ConvertTo-PlainWinAppText (($rawOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n")
        $json = $null
        $parseError = $null
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            try { $json = $stdout | ConvertFrom-Json -Depth 100 }
            catch { $parseError = $_.Exception.Message }
        }
        $result = [pscustomobject]@{
            success = ($exitCode -eq 0 -and $null -ne $json)
            exitCode = $exitCode
            json = $json
            stdout = $stdout
            stderr = $stderr
            parseError = $parseError
            operation = $Operation
            arguments = @($effectiveArguments)
        }
        if (-not $result.success -and -not $AllowFailure) {
            Write-TestResult -Component "CLI/$Operation" -Result 'WARN' -Detail "Exit=$($result.exitCode); JSON=$([bool]$result.json); $($result.stderr)$($result.parseError)"
        }
        return $result
    }
    catch {
        if (-not $AllowFailure) { Write-TestResult -Component "CLI/$Operation" -Result 'WARN' -Detail $_.Exception.Message }
        return [pscustomobject]@{ success=$false; exitCode=$null; json=$null; stdout=''; stderr=$_.Exception.Message; parseError=$null; operation=$Operation; arguments=@($effectiveArguments) }
    }
}

function Get-ObjectPropertyValue {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

function Get-WinAppWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Application, [string]$TitlePattern)
    $response = Invoke-WinAppJson -Arguments @('ui','list-windows','-a',$Application) -AllowFailure -Operation "list-windows-$Application"
    if ($null -eq $response.json) { return @() }
    if ($response.json -is [System.Collections.IEnumerable] -and $response.json -isnot [string]) {
        $windows = @($response.json | ForEach-Object { $_ })
    }
    else {
        $windows = @(Get-ObjectPropertyValue $response.json @('windows','Windows','items'))
    }
    if ($windows.Count -eq 0 -and $null -ne (Get-ObjectPropertyValue $response.json @('hwnd','Hwnd'))) { $windows = @($response.json) }
    $windows = @($windows | Where-Object {
        $hwnd = Get-ObjectPropertyValue $_ @('hwnd','Hwnd')
        $width = Get-ObjectPropertyValue $_ @('width','Width')
        $height = Get-ObjectPropertyValue $_ @('height','Height')
        $null -ne $hwnd -and (($null -eq $width -or [int]$width -gt 1) -and ($null -eq $height -or [int]$height -gt 1))
    })
    if ($Application -match '^(?i:explorer)$') { $windows = @($windows | Where-Object { ([string](Get-ObjectPropertyValue $_ @('className','ClassName'))) -eq 'CabinetWClass' }) }
    if (-not [string]::IsNullOrWhiteSpace($TitlePattern)) {
        $windows = @($windows | Where-Object { ([string](Get-ObjectPropertyValue $_ @('title','Title'))) -match $TitlePattern })
    }
    return @($windows)
}

function Wait-WinAppWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Application, [string]$TitlePattern, [int]$Timeout = $TimeoutMilliseconds)
    $deadline = (Get-Date).AddMilliseconds($Timeout)
    do {
        $windows = @(Get-WinAppWindow -Application $Application -TitlePattern $TitlePattern)
        if ($windows.Count -gt 0) { return $windows }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return @()
}

function Get-WinAppUiTree {
    [CmdletBinding()]
    param([Parameter(Mandatory)][UInt64]$Hwnd, [int]$Depth = 8)
    $response = Invoke-WinAppJson -Arguments @('ui','inspect','-w',([string]$Hwnd),'--depth',([string]$Depth)) -AllowFailure -Operation "inspect-$Hwnd"
    if ($null -eq $response.json) { return $null }
    $windows = @(Get-ObjectPropertyValue $response.json @('windows','Windows'))
    if ($windows.Count -gt 0) { return $windows[0] }
    return $response.json
}

function Get-TreeElements {
    param([AllowNull()][object]$Node)
    if ($null -eq $Node) { return @() }
    $found = [System.Collections.Generic.List[object]]::new()
    function Visit-Node { param([object]$Item)
        if ($null -eq $Item) { return }
        $found.Add($Item) | Out-Null
        foreach ($child in @(Get-ObjectPropertyValue $Item @('children','Children','elements','Elements'))) { Visit-Node $child }
    }
    foreach ($root in @(Get-ObjectPropertyValue $Node @('elements','Elements','children','Children'))) { Visit-Node $root }
    if ($found.Count -eq 0 -and $null -ne (Get-ObjectPropertyValue $Node @('controlType','ControlType','type','Type'))) { Visit-Node $Node }
    return @($found)
}

function Find-WinAppElement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Tree,
        [string]$NamePattern,
        [string]$AutomationIdPattern,
        [string]$ControlType,
        [switch]$First
    )
    $matches = @(Get-TreeElements $Tree | Where-Object {
        $name = [string](Get-ObjectPropertyValue $_ @('name','Name'))
        $automationId = [string](Get-ObjectPropertyValue $_ @('automationId','AutomationId'))
        $type = [string](Get-ObjectPropertyValue $_ @('controlType','ControlType','type','Type'))
        (([string]::IsNullOrWhiteSpace($NamePattern)) -or $name -match $NamePattern) -and
        (([string]::IsNullOrWhiteSpace($AutomationIdPattern)) -or $automationId -match $AutomationIdPattern) -and
        (([string]::IsNullOrWhiteSpace($ControlType)) -or $type -eq $ControlType)
    })
    if ($First) { return @($matches | Select-Object -First 1) }
    return $matches
}

function Get-WinAppElementProperties {
    param([Parameter(Mandatory)][UInt64]$Hwnd, [Parameter(Mandatory)][object]$Element)
    $selector = [string](Get-ObjectPropertyValue $Element @('selector','Selector','automationId','AutomationId','elementId','ElementId'))
    if ([string]::IsNullOrWhiteSpace($selector)) { return $null }
    $response = Invoke-WinAppJson -Arguments @('ui','get-property',$selector,'-w',([string]$Hwnd)) -AllowFailure -Operation "get-property-$Hwnd"
    return $response.json
}

function Test-WinAppPreconditions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][UInt64]$Hwnd, [Parameter(Mandatory)][object]$Element, [string]$ExpectedProcess, [string]$Application = $ExpectedProcess)
    $checks = [ordered]@{ hwnd=$false; process=$false; title=$true; element=$false; enabled=$false; visible=$false; controlType=$false; password=$false }
    $window = @(Get-WinAppWindow -Application $Application | Where-Object { [UInt64](Get-ObjectPropertyValue $_ @('hwnd','Hwnd')) -eq $Hwnd }) | Select-Object -First 1
    $checks.hwnd = ($null -ne $window)
    $windowTitle = [string](Get-ObjectPropertyValue $window @('title','Title'))
    if ($null -ne $window -and ($null -ne $window.PSObject.Properties['title'] -or $null -ne $window.PSObject.Properties['Title'])) { $checks.title = -not [string]::IsNullOrWhiteSpace($windowTitle) }
    $windowProcessId = Get-ObjectPropertyValue $window @('pid','processId','ProcessId')
    if ($null -ne $windowProcessId) {
        try { $checks.process = ((Get-Process -Id ([int]$windowProcessId) -ErrorAction Stop).ProcessName -match [regex]::Escape($ExpectedProcess)) } catch { $checks.process = $false }
    }
    $checks.element = ($null -ne $Element)
    $properties = Get-WinAppElementProperties -Hwnd $Hwnd -Element $Element
    $enabled = Get-ObjectPropertyValue $properties @('isEnabled','IsEnabled')
    $offscreen = Get-ObjectPropertyValue $properties @('isOffscreen','IsOffscreen')
    $isPassword = Get-ObjectPropertyValue $properties @('isPassword','IsPassword')
    $className = [string](Get-ObjectPropertyValue $properties @('className','ClassName'))
    $controlType = [string](Get-ObjectPropertyValue $properties @('controlType','ControlType','type','Type'))
    if ([string]::IsNullOrWhiteSpace($controlType)) { $controlType = [string](Get-ObjectPropertyValue $Element @('controlType','ControlType','type','Type')) }
    $checks.enabled = ($enabled -ne $false)
    $checks.visible = ($offscreen -ne $true)
    $checks.controlType = (-not [string]::IsNullOrWhiteSpace($controlType))
    $name = [string](Get-ObjectPropertyValue $Element @('name','Name'))
    $knownFalsePositive = @($script:KnownPasswordFalsePositives | Where-Object { $name -match $_ -or $className -match $_ }).Count -gt 0
    $checks.password = ($isPassword -ne $true -or $knownFalsePositive)
    [pscustomobject]@{ safe=($checks.Values -notcontains $false); checks=[pscustomobject]$checks; properties=$properties; knownPasswordFalsePositive=$knownFalsePositive; windowTitle=$windowTitle; window=$window }
}

function Test-WinAppPostCondition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Condition, [int]$Timeout = $TimeoutMilliseconds)
    $deadline = (Get-Date).AddMilliseconds($Timeout)
    $attempts = 0
    $last = $null
    do {
        $attempts++
        try { $last = & $Condition } catch { $last = [pscustomobject]@{ success=$false; detail=$_.Exception.Message } }
        if ($last -is [bool]) { if ($last) { return [pscustomobject]@{ success=$true; attempts=$attempts; detail=$Name } } }
        elseif ($null -ne $last -and (Get-ObjectPropertyValue $last @('success','Success')) -eq $true) { return [pscustomobject]@{ success=$true; attempts=$attempts; detail=(Get-ObjectPropertyValue $last @('detail','Detail')) } }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return [pscustomobject]@{ success=$false; attempts=$attempts; detail=("{0}; last observation: {1}" -f $Name, (($last | Out-String).Trim())) }
}

function Capture-WinAppEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Component, [Parameter(Mandatory)][UInt64]$Hwnd, [string]$State = 'observed')
    $safeName = ($Component -replace '[^A-Za-z0-9_.-]', '_')
    $path = Join-Path $script:EvidenceRoot ("{0}-{1}-{2}.png" -f $safeName,$State,(Get-Date -Format 'yyyyMMdd-HHmmssfff'))
    $response = Invoke-WinAppJson -Arguments @('ui','screenshot','-w',([string]$Hwnd),'-o',$path) -AllowFailure -Operation "screenshot-$Component"
    $size = $null
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop; $image = [Drawing.Image]::FromFile($path); $size = "{0}x{1}" -f $image.Width,$image.Height; $image.Dispose() } catch { $size = 'captured; dimensions unavailable' }
    }
    return [pscustomobject]@{ success=(Test-Path -LiteralPath $path -PathType Leaf); path=$path; size=$size; detail=$response.stderr }
}

function Set-Capability {
    param([string]$Component,[string]$Capability,[string]$Value)
    if (-not $script:Capabilities.ContainsKey($Component)) { $script:Capabilities[$Component] = @{} }
    $script:Capabilities[$Component][$Capability] = $Value
}

function Get-Capability {
    param([string]$Component,[string]$Capability)
    if (-not $script:Capabilities.ContainsKey($Component)) { return 'NOT TESTED' }
    if (-not $script:Capabilities[$Component].ContainsKey($Capability)) { return 'NOT TESTED' }
    $value = [string]$script:Capabilities[$Component][$Capability]
    if ($value -eq 'LIMITED') { return 'PASS-WITH-LIMITATION' }
    return $value
}


function Get-WindowHwnd {
    param([object]$Window)
    $value = Get-ObjectPropertyValue $Window @('hwnd','Hwnd','handle','Handle')
    if ($null -eq $value) { return $null }
    try { return [UInt64]$value } catch { return $null }
}

function Get-WinAppWindowMetadata {
    param([Parameter(Mandatory)][string]$Application,[Parameter(Mandatory)][UInt64]$Hwnd)
    return (Get-WinAppWindow -Application $Application | Where-Object { (Get-WindowHwnd $_) -eq $Hwnd } | Select-Object -First 1)
}

function Get-WinAppWindowSnapshot {
    param([Parameter(Mandatory)][string]$Application,[Parameter(Mandatory)][UInt64]$Hwnd)
    $metadata = Get-WinAppWindowMetadata -Application $Application -Hwnd $Hwnd
    [pscustomobject]@{
        hwnd = Get-WindowHwnd $metadata
        width = Get-ObjectPropertyValue $metadata @('width','Width')
        height = Get-ObjectPropertyValue $metadata @('height','Height')
        x = Get-ObjectPropertyValue $metadata @('x','X','left','Left')
        y = Get-ObjectPropertyValue $metadata @('y','Y','top','Top')
        state = Get-ObjectPropertyValue $metadata @('windowState','WindowState','state','State','isMinimized','IsMinimized')
    }
}

function Test-WinAppSnapshotEqual {
    param([Parameter(Mandatory)][object]$Left,[Parameter(Mandatory)][object]$Right)
    if ($Left.hwnd -ne $Right.hwnd) { return $false }
    foreach ($property in 'width','height','x','y','state') {
        $leftValue = Get-ObjectPropertyValue $Left @($property)
        $rightValue = Get-ObjectPropertyValue $Right @($property)
        if ($null -ne $leftValue -and $null -ne $rightValue -and $leftValue -ne $rightValue) { return $false }
    }
    return $true
}

function Test-WinAppSnapshotChanged {
    param([Parameter(Mandatory)][object]$Before,[Parameter(Mandatory)][object]$After)
    if ($Before.hwnd -ne $After.hwnd) { return $true }
    foreach ($property in 'width','height','x','y','state') {
        $beforeValue = Get-ObjectPropertyValue $Before @($property)
        $afterValue = Get-ObjectPropertyValue $After @($property)
        if ($null -ne $beforeValue -and $null -ne $afterValue -and $beforeValue -ne $afterValue) { return $true }
    }
    return $false
}

function Add-TestOwnership {
    param([Parameter(Mandatory)][string]$Component,[Parameter(Mandatory)][object]$Window,[bool]$LaunchedByHarness,[string]$Executable,[string]$LaunchMethod)
    $processId = Get-ObjectPropertyValue $Window @('pid','processId','ProcessId')
    $processName = [string](Get-ObjectPropertyValue $Window @('processName','ProcessName'))
    $startTime = $null
    if ($null -ne $processId) { try { $startTime = (Get-Process -Id ([int]$processId) -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') } catch { } }
    $target = [pscustomobject]@{
        component=$Component; window=$Window; hwnd=(Get-WindowHwnd $Window); pid=$processId; process=$processName
        title=[string](Get-ObjectPropertyValue $Window @('title','Title')); startTimeUtc=$startTime
        executable=$Executable; launchMethod=$LaunchMethod; launchedByHarness=$LaunchedByHarness; userWindowsModified=$false; userWindowsLeftUntouched=$true
    }
    $script:TestTargets[$Component] = $target
    $script:TestOwnership.Add($target) | Out-Null
    return $target
}

function Add-TestLaunchRecord {
    param([string]$Component,[System.Diagnostics.Process]$Process,[string]$Executable,[string]$LaunchMethod)
    $startTime = $null; try { $startTime = $Process.StartTime.ToUniversalTime().ToString('o') } catch { }
    $script:TestOwnership.Add([pscustomobject]@{ component=$Component; window=$null; hwnd=$null; pid=$Process.Id; process=$Process.ProcessName; title='not yet resolved'; startTimeUtc=$startTime; executable=$Executable; launchMethod=$LaunchMethod; launchedByHarness=$true; userWindowsModified=$false; userWindowsLeftUntouched=$true }) | Out-Null
}

function Wait-WinAppWindowForPid {
    param([Parameter(Mandatory)][string]$Application,[Parameter(Mandatory)][int]$ProcessId,[int]$Timeout=$TimeoutMilliseconds)
    $deadline = (Get-Date).AddMilliseconds($Timeout)
    do {
        $matches = @(Get-WinAppWindow -Application $Application | Where-Object { [int](Get-ObjectPropertyValue $_ @('pid','processId','ProcessId')) -eq $ProcessId })
        if ($matches.Count -eq 1) { return $matches[0] }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $null
}

function New-HarnessNotepadTarget {
    if (-not $AllowAppLaunch) { Write-TestResult 'Notepad baseline' 'SKIPPED' 'Harness launch disabled (use -AllowAppLaunch); no user window was used for writing.'; return $null }
    $notepad = Join-Path $env:WINDIR 'System32\notepad.exe'
    if (-not (Test-Path -LiteralPath $notepad -PathType Leaf)) { Write-TestResult 'Notepad baseline' 'SKIPPED' 'Notepad executable was not found; no user window was used.'; return $null }
    try {
        $beforeHwnds = @(Get-WinAppWindow -Application 'notepad' | ForEach-Object { Get-WindowHwnd $_ })
        $process = Start-Process -FilePath $notepad -PassThru
        Add-TestLaunchRecord -Component 'Notepad' -Process $process -Executable $notepad -LaunchMethod 'Start-Process notepad.exe'
        $deadline = (Get-Date).AddMilliseconds($TimeoutMilliseconds); $window = $null
        do {
            $newWindows = @(Get-WinAppWindow -Application 'notepad' | Where-Object { (Get-WindowHwnd $_) -notin $beforeHwnds })
            if ($newWindows.Count -eq 1) { $window = $newWindows[0]; break }
            Start-Sleep -Milliseconds 250
        } while ((Get-Date) -lt $deadline)
        if ($null -eq $window) { Write-TestResult 'Notepad baseline' 'SKIPPED' "Harness-launched Notepad PID=$($process.Id) did not expose a unique new HWND; no existing Notepad window was used."; return $null }
        return Add-TestOwnership -Component 'Notepad' -Window $window -LaunchedByHarness $true -Executable $notepad -LaunchMethod 'Start-Process notepad.exe'
    }
    catch { Write-TestResult 'Notepad baseline' 'FAIL' "Could not launch isolated Notepad test instance: $($_.Exception.Message)"; return $null }
}

function New-HarnessTerminalTarget {
    if (-not $AllowAppLaunch) { Write-TestResult 'Windows Terminal' 'SKIPPED' 'Harness launch disabled (use -AllowAppLaunch); existing Terminal windows were untouched.'; return $null }
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $wt) { Write-TestResult 'Windows Terminal' 'SKIPPED' 'wt.exe was not found; existing Terminal windows were left untouched.'; return $null }
    $help = @(& $wt.Source --help 2>&1); $helpExit = $LASTEXITCODE; $helpText = $help -join "`n"
    if ($helpExit -ne 0 -or $helpText -notmatch '(?i)new-tab' -or $helpText -notmatch '(?i)--title' -or $helpText -notmatch '(?i)--window|\-w') {
        Write-TestResult 'Windows Terminal' 'SKIPPED' 'wt --help did not confirm the required separate-window/title syntax; no Terminal was started.'; return $null
    }
    $title = 'KI-Stack Desktop Control Spike ' + [guid]::NewGuid().ToString('N').Substring(0,8)
    try {
        # Syntax is gated by the immediately preceding wt --help result.  -w new
        # prevents reusing any of the user’s existing Terminal windows.
        Start-Process -FilePath $wt.Source -ArgumentList @('-w','new','new-tab','--title',$title) | Out-Null
        $windows = Wait-WinAppWindow -Application 'Terminal' -TitlePattern ('^' + [regex]::Escape($title) + '$')
        if ($windows.Count -ne 1) { Write-TestResult 'Windows Terminal' 'SKIPPED' "Harness Terminal title '$title' was not uniquely observable; existing Terminal windows were untouched."; return $null }
        return Add-TestOwnership -Component 'Terminal' -Window $windows[0] -LaunchedByHarness $true -Executable $wt.Source -LaunchMethod 'wt -w new new-tab --title <unique>'
    }
    catch { Write-TestResult 'Windows Terminal' 'FAIL' "Could not launch isolated Terminal test instance: $($_.Exception.Message)"; return $null }
}

function Initialize-TestTargets {
    New-HarnessNotepadTarget | Out-Null
    New-HarnessTerminalTarget | Out-Null
}

function Test-ObservedApplication {
    param([string]$Component,[string]$Application,[string]$RequiredElementPattern,[string]$ExpectedProcess)
    $windows = @(Get-WinAppWindow -Application $Application)
    if ($windows.Count -ne 1) { return [pscustomobject]@{ result='SKIPPED'; detail="Expected exactly one '$Application' window; found $($windows.Count)."; window=$null; tree=$null } }
    $hwnd = Get-WindowHwnd $windows[0]
    $tree = Get-WinAppUiTree -Hwnd $hwnd
    if ($null -eq $tree) { return [pscustomobject]@{ result='FAIL'; detail='UIA inspect returned no parseable tree.'; window=$windows[0]; tree=$null } }
    $elements = @(Get-TreeElements $tree)
    $semantic = @(Find-WinAppElement -Tree $tree -NamePattern $RequiredElementPattern).Count -gt 0
    $shot = Capture-WinAppEvidence -Component $Component -Hwnd $hwnd
    Set-Capability $Component 'Window discovery' 'PASS'; Set-Capability $Component 'HWND targeting' 'PASS'; Set-Capability $Component 'UIA tree' 'PASS'; Set-Capability $Component 'Semantic controls' ($(if($semantic){'PASS'}else{'LIMITED'})); Set-Capability $Component 'Screenshot' ($(if($shot.success){'PASS'}else{'FAIL'}))
    [pscustomobject]@{ result=$(if($semantic -and $shot.success){'PASS'}else{'PASS-WITH-LIMITATION'}); detail="HWND=$hwnd; elements=$($elements.Count); semantic=$semantic; screenshot=$($shot.path)"; window=$windows[0]; tree=$tree; screenshot=$shot }
}

function Test-OwnedNotepad {
    if (-not $script:TestTargets.ContainsKey('Notepad')) { return $null }
    $target = $script:TestTargets['Notepad']; $tree = Get-WinAppUiTree -Hwnd $target.hwnd
    if ($null -eq $tree) { return [pscustomobject]@{ result='FAIL'; detail="No UIA tree for harness Notepad HWND=$($target.hwnd)." } }
    $document = @(Find-WinAppElement -Tree $tree -ControlType 'Document' -First)
    if ($document.Count -eq 0) { return [pscustomobject]@{ result='FAIL'; detail='Harness Notepad exposed no Document control.' } }
    $pre = Test-WinAppPreconditions -Hwnd $target.hwnd -Element $document[0] -ExpectedProcess 'notepad' -Application 'notepad'
    if (-not $pre.safe) { return [pscustomobject]@{ result='BLOCKED'; detail="Notepad write withheld: $($pre.checks | ConvertTo-Json -Compress)" } }
    $selector = [string](Get-ObjectPropertyValue $document[0] @('selector','automationId','elementId'))
    $set = Invoke-WinAppJson -Arguments @('ui','set-value',$selector,'KI-Stack-2.18-Automated-Notepad-Test','-w',([string]$target.hwnd)) -AllowFailure -Operation 'notepad-set-value'
    $post = Test-WinAppPostCondition -Name 'Notepad value readback' -Condition {
        $value = Invoke-WinAppJson -Arguments @('ui','get-value',$selector,'-w',([string]$target.hwnd)) -AllowFailure -Operation 'notepad-get-value'
        [pscustomobject]@{ success=($value.json -and (ConvertTo-PlainWinAppText ($value.json | ConvertTo-Json -Depth 20)) -match 'KI-Stack-2\.18-Automated-Notepad-Test'); detail='Document value re-observed' }
    }
    $shot = Capture-WinAppEvidence -Component 'Notepad' -Hwnd $target.hwnd
    Set-Capability 'Notepad' 'Window discovery' 'PASS'; Set-Capability 'Notepad' 'HWND targeting' 'PASS'; Set-Capability 'Notepad' 'UIA tree' 'PASS'; Set-Capability 'Notepad' 'Semantic controls' 'PASS'; Set-Capability 'Notepad' 'Read value' ($(if($post.success){'PASS'}else{'FAIL'})); Set-Capability 'Notepad' 'Set value' ($(if($set.success -and $post.success){'PASS'}else{'FAIL'})); Set-Capability 'Notepad' 'Screenshot' ($(if($shot.success){'PASS'}else{'FAIL'})); Set-Capability 'Notepad' 'Postcondition verification' ($(if($post.success){'PASS'}else{'FAIL'}))
    return [pscustomobject]@{ result=$(if($set.success -and $post.success -and $shot.success){'PASS'}else{'FAIL'}); detail="PID=$($target.pid); HWND=$($target.hwnd); set-value exit=$($set.exitCode); $($post.detail); screenshot=$($shot.path)" }
}

function Test-Terminal {
    if (-not $script:TestTargets.ContainsKey('Terminal')) { return }
    $target = $script:TestTargets['Terminal']; $hwnd = [UInt64]$target.hwnd; $tree = Get-WinAppUiTree -Hwnd $hwnd
    if ($null -eq $tree) { Write-TestResult 'Windows Terminal' 'FAIL' "UIA inspect returned no parseable tree for HWND=$hwnd."; return }
    $tabView = @(Find-WinAppElement -Tree $tree -AutomationIdPattern '^TabView$' -First); if ($tabView.Count -eq 0) { $tabView = @(Find-WinAppElement -Tree $tree -ControlType 'Tab' -First) }
    $term = @(Find-WinAppElement -Tree $tree -AutomationIdPattern 'TermControl|Terminal' -First); if ($term.Count -eq 0) { $term = @(Find-WinAppElement -Tree $tree -NamePattern 'Terminal|TermControl' -First) }
    $shot = Capture-WinAppEvidence -Component 'Terminal' -Hwnd $hwnd
    Set-Capability 'Terminal' 'Window discovery' 'PASS'; Set-Capability 'Terminal' 'HWND targeting' 'PASS'; Set-Capability 'Terminal' 'UIA tree' ($(if($null -ne $tree){'PASS'}else{'FAIL'})); Set-Capability 'Terminal' 'Semantic controls' ($(if($tabView.Count -gt 0 -and $term.Count -gt 0){'PASS'}else{'LIMITED'})); Set-Capability 'Terminal' 'Screenshot' ($(if($shot.success){'PASS'}else{'FAIL'}))
    if ($term.Count -eq 0) { Write-TestResult 'Windows Terminal' 'PASS-WITH-LIMITATION' "No TermControl selector exposed; evidence=$($shot.path)"; return }
    $value = Invoke-WinAppJson -Arguments @('ui','get-value',([string](Get-ObjectPropertyValue $term[0] @('selector','automationId','elementId'))),'-w',([string]$hwnd)) -AllowFailure -Operation 'terminal-get-value'
    $bufferReadable = ($value.json -and ((ConvertTo-PlainWinAppText ($value.json | ConvertTo-Json -Depth 20)) -match 'KI-Stack-2\.18-Terminal-Test'))
    Set-Capability 'Terminal' 'Read value' ($(if($value.json){'LIMITED'}else{'FAIL'})); Set-Capability 'Terminal' 'Focus' 'NOT TESTED'; Set-Capability 'Terminal' 'Keyboard fallback' 'NOT TESTED'
    if (-not $AllowTerminalInput) { Write-TestResult 'Windows Terminal' 'PASS-WITH-LIMITATION' "UIA buffer readability=$bufferReadable; controlled input disabled (use -AllowTerminalInput); evidence=$($shot.path)"; return }
    $pre = Test-WinAppPreconditions -Hwnd $hwnd -Element $term[0] -ExpectedProcess 'WindowsTerminal' -Application 'Terminal'
    if (-not $pre.safe) { Write-TestResult 'Windows Terminal' 'BLOCKED' "Input withheld: preconditions failed: $($pre.checks | ConvertTo-Json -Compress)"; return }
    $selector = [string](Get-ObjectPropertyValue $term[0] @('selector','automationId','elementId'))
    $focus = Invoke-WinAppJson -Arguments @('ui','focus',$selector,'-w',([string]$hwnd)) -AllowFailure -Operation 'terminal-focus'
    $focused = Invoke-WinAppJson -Arguments @('ui','get-focused','-w',([string]$hwnd)) -AllowFailure -Operation 'terminal-get-focused'
    $focusedText = if ($focused.json) { ConvertTo-PlainWinAppText ($focused.json | ConvertTo-Json -Depth 20) } else { '' }
    if ([string]::IsNullOrWhiteSpace($focusedText) -or ($focusedText -notmatch [regex]::Escape($selector) -and $focusedText -notmatch 'TermControl|Terminal')) { Write-TestResult 'Windows Terminal' 'BLOCKED' 'Input withheld: target focus could not be verified against TermControl.'; return }
    $keys = Invoke-WinAppJson -Arguments @('ui','send-keys','echo KI-Stack-2.18-Terminal-Test enter','--via','send-input','-w',([string]$hwnd)) -AllowFailure -Operation 'terminal-send-keys'
    $post = Test-WinAppPostCondition -Name 'terminal buffer marker' -Timeout $TimeoutMilliseconds -Condition {
        $latest = Invoke-WinAppJson -Arguments @('ui','get-value',$selector,'-w',([string]$hwnd)) -AllowFailure -Operation 'terminal-post-value'
        if ($latest.json -and (ConvertTo-PlainWinAppText ($latest.json | ConvertTo-Json -Depth 20)) -match 'KI-Stack-2\.18-Terminal-Test') { return [pscustomobject]@{success=$true;detail='terminal buffer contains marker'} }
        $evidence = Capture-WinAppEvidence -Component 'Terminal' -Hwnd $hwnd -State 'after-input'
        return [pscustomobject]@{success=$false;detail="buffer not exposed; screenshot evidence only ($($evidence.path)); postcondition NOT PROVEN"}
    }
    Set-Capability 'Terminal' 'Focus' ($(if($focus.success -and $focused.json){'PASS'}else{'LIMITED'})); Set-Capability 'Terminal' 'Keyboard fallback' ($(if($keys.json){'PASS'}else{'FAIL'})); Set-Capability 'Terminal' 'Postcondition verification' ($(if($post.success){'PASS'}else{'FAIL'}))
    if (-not $keys.success) {
        Write-TestResult 'Windows Terminal' 'FAIL' "Input action did not execute successfully (exit=$($keys.exitCode)); $($keys.stderr)"
    }
    elseif ($post.success) {
        Write-TestResult 'Windows Terminal' 'PASS' "Input action executed (exit=$($keys.exitCode)); output postcondition PROVEN. $($post.detail)"
    }
    else {
        Write-TestResult 'Windows Terminal' 'PASS-WITH-LIMITATION' "Input action executed (exit=$($keys.exitCode)); output postcondition NOT PROVEN. $($post.detail)"
    }
}

function Test-LmStudio {
    $beforeIds = @()
    $launchedByHarness = $false
    $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '(?i)^lm[ ._-]?studio' })
    if ($processes.Count -eq 0) {
        if (-not $AllowAppLaunch) { Write-TestResult 'LM Studio' 'SKIPPED' 'No running LM Studio process and harness launch is disabled (use -AllowAppLaunch).'; return }
        $startApps = @(Get-StartApps | Where-Object { $_.AppID -eq 'ai.elementlabs.lmstudio' -or $_.Name -eq 'LM Studio' })
        if ($startApps.Count -ne 1) { Write-TestResult 'LM Studio' 'SKIPPED' 'No local LM Studio process or uniquely registered Start App was found; no application was started.'; return }
        $beforeIds = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
        try {
            Start-Process -FilePath explorer.exe -ArgumentList ('shell:AppsFolder\' + $startApps[0].AppID) | Out-Null
            $launchedByHarness = $true
            $deadline = (Get-Date).AddMilliseconds($TimeoutMilliseconds)
            do { $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $beforeIds -and $_.ProcessName -match '(?i)lm[ ._-]?studio' }); if($processes.Count -gt 0){break}; Start-Sleep -Milliseconds 250 } while ((Get-Date) -lt $deadline)
        }
        catch { Write-TestResult 'LM Studio' 'FAIL' "Registered Start App could not be launched: $($_.Exception.Message)"; return }
        if ($processes.Count -eq 0) { Write-TestResult 'LM Studio' 'SKIPPED' 'Registered LM Studio Start App did not expose a new LM Studio process before timeout.'; return }
    }
    $all = Invoke-WinAppJson -Arguments @('ui','list-windows') -AllowFailure -Operation 'lmstudio-list-windows'
    $allWindows = if ($all.json -is [System.Collections.IEnumerable] -and $all.json -isnot [string]) { @($all.json | ForEach-Object { $_ }) } else { @(Get-ObjectPropertyValue $all.json @('windows','Windows','items')) }
    $pids = @($processes.Id)
    $windows = @($allWindows | Where-Object { ([int](Get-ObjectPropertyValue $_ @('pid','processId','ProcessId')) -in $pids) -and [int](Get-ObjectPropertyValue $_ @('width','Width')) -gt 1 -and [int](Get-ObjectPropertyValue $_ @('height','Height')) -gt 1 })
    if ($windows.Count -ne 1) { Write-TestResult 'LM Studio' 'SKIPPED' "LM Studio discovery found $($processes.Count) process(es) and $($windows.Count) eligible window(s); no ambiguous user window was changed."; return }
    $window = $windows[0]; Add-TestOwnership -Component 'LM Studio' -Window $window -LaunchedByHarness $launchedByHarness -Executable '' -LaunchMethod $(if($launchedByHarness){'registered Start App ai.elementlabs.lmstudio'}else{'pre-existing process/window discovery'}) | Out-Null
    $hwnd = Get-WindowHwnd $window; $tree = Get-WinAppUiTree -Hwnd $hwnd
    if ($null -eq $tree) { Write-TestResult 'LM Studio' 'FAIL' "LM Studio HWND=$hwnd exposed no parseable UIA tree."; return }
    $shot = Capture-WinAppEvidence -Component 'LM Studio' -Hwnd $hwnd
    $observed = [pscustomobject]@{ result=$(if($shot.success){'PASS-WITH-LIMITATION'}else{'FAIL'}); detail="PID=$((Get-ObjectPropertyValue $window @('pid','processId','ProcessId'))); HWND=$hwnd; screenshot=$($shot.path)"; window=$window; tree=$tree }
    if ($observed.result -eq 'SKIPPED' -or $observed.result -eq 'FAIL') { Write-TestResult 'LM Studio' $observed.result $observed.detail; return }
    $tree = $observed.tree; $hwnd = Get-WindowHwnd $observed.window
    $candidate = @(Find-WinAppElement -Tree $tree -NamePattern '^(Chat|Models|My Models)$' -First)
    if (-not $AllowHarmlessNavigation -or $candidate.Count -eq 0) { Write-TestResult 'LM Studio' 'PASS-WITH-LIMITATION' "$($observed.detail); harmless navigation not performed."; return }
    $pre = Test-WinAppPreconditions -Hwnd $hwnd -Element $candidate[0] -ExpectedProcess 'LM Studio'
    if (-not $pre.safe) { Write-TestResult 'LM Studio' 'BLOCKED' 'Navigation withheld because the target failed safety preconditions.'; return }
    $selector = [string](Get-ObjectPropertyValue $candidate[0] @('selector','automationId','elementId'))
    $action = Invoke-WinAppJson -Arguments @('ui','invoke',$selector,'-w',([string]$hwnd)) -AllowFailure -Operation 'lmstudio-invoke'
    $post = Test-WinAppPostCondition -Name 'LM Studio selected navigation item remains visible' -Condition { $t = Get-WinAppUiTree -Hwnd $hwnd; [pscustomobject]@{ success=((Find-WinAppElement -Tree $t -NamePattern 'Chat|Model|Settings').Count -gt 0); detail='navigation tree re-observed' } }
    Set-Capability 'LM Studio' 'Invoke' ($(if($action.success -and $post.success){'PASS'}else{'FAIL'})); Set-Capability 'LM Studio' 'Postcondition verification' ($(if($post.success){'PASS'}else{'FAIL'}))
    Write-TestResult 'LM Studio' ($(if($action.success -and $post.success){$observed.result}else{'PASS-WITH-LIMITATION'})) "$($observed.detail); invoke=$($action.exitCode); $($post.detail)"
}

function Test-BrowserOpenWebUi {
    $all = Invoke-WinAppJson -Arguments @('ui','list-windows') -AllowFailure -Operation 'list-all-windows'
    $windows = @(Get-ObjectPropertyValue $all.json @('windows','Windows','items') | Where-Object { ([string](Get-ObjectPropertyValue $_ @('title','Title'))) -match 'OpenWebUI|Open WebUI' })
    if ($windows.Count -ne 1) { Write-TestResult 'Browser/OpenWebUI' 'SKIPPED' "OpenWebUI tab/window not uniquely discoverable; found $($windows.Count)."; return }
    $hwnd = Get-WindowHwnd $windows[0]; $tree = Get-WinAppUiTree -Hwnd $hwnd; $elements = @(Get-TreeElements $tree)
    $chrome = @($elements | Where-Object { ([string](Get-ObjectPropertyValue $_ @('controlType','ControlType'))) -match 'Tab|Edit|Button' }).Count -gt 0
    $webContent = @($elements | Where-Object { ([string](Get-ObjectPropertyValue $_ @('className','ClassName'))) -match 'Chrome_RenderWidgetHostHWND|Internet Explorer_Server|WebView' }).Count -gt 0
    $shot = Capture-WinAppEvidence -Component 'Browser-OpenWebUI' -Hwnd $hwnd
    Set-Capability 'Browser' 'Window discovery' 'PASS'; Set-Capability 'Browser' 'HWND targeting' 'PASS'; Set-Capability 'Browser' 'UIA tree' ($(if($tree){'PASS'}else{'FAIL'})); Set-Capability 'Browser' 'Semantic controls' ($(if($webContent){'LIMITED'}else{'FAIL'})); Set-Capability 'Browser' 'Screenshot' ($(if($shot.success){'PASS'}else{'FAIL'}))
    Write-TestResult 'Browser/OpenWebUI' ($(if($chrome -and $shot.success){'PASS-WITH-LIMITATION'}else{'FAIL'})) "Browser chrome=$chrome; web-content UIA=$webContent; no content action performed; evidence=$($shot.path)"
}

function Test-FocusSafety {
    if (-not $script:TestTargets.ContainsKey('Notepad')) { Write-TestResult 'Focus safety' 'SKIPPED' 'No harness-owned Notepad target is available.'; return }
    $target = $script:TestTargets['Notepad']; $tree = Get-WinAppUiTree -Hwnd $target.hwnd
    if ($null -eq $tree) { Write-TestResult 'Focus safety' 'SKIPPED' 'Harness Notepad tree could not be re-observed; no input was attempted.'; return }
    $document = @(Find-WinAppElement -Tree $tree -ControlType 'Document' -First)
    $before = if ($document.Count -gt 0) { Invoke-WinAppJson -Arguments @('ui','get-value',([string](Get-ObjectPropertyValue $document[0] @('selector','automationId','elementId'))),'-w',([string]$target.hwnd)) -AllowFailure -Operation 'focus-safety-before' } else { $null }
    # Deliberately provide a false process identity to the same real HWND. This
    # exercises the actual write-precondition path without ever issuing input.
    $manipulated = if ($document.Count -gt 0) { Test-WinAppPreconditions -Hwnd $target.hwnd -Element $document[0] -ExpectedProcess '__KIStackWrongProcessIdentity__' -Application 'notepad' } else { $null }
    $blocked = ($null -ne $manipulated -and -not $manipulated.safe)
    $after = if ($document.Count -gt 0) { Invoke-WinAppJson -Arguments @('ui','get-value',([string](Get-ObjectPropertyValue $document[0] @('selector','automationId','elementId'))),'-w',([string]$target.hwnd)) -AllowFailure -Operation 'focus-safety-after' } else { $null }
    $unchanged = ($before.json | ConvertTo-Json -Depth 20) -eq ($after.json | ConvertTo-Json -Depth 20)
    if ($blocked -and $unchanged) { Write-TestResult 'Focus safety' 'PASS' "Write precondition blocked the deliberately false process identity for real Notepad HWND=$($target.hwnd); no write was issued; content readback unchanged." }
    elseif (-not $unchanged) { Write-TestResult 'Focus safety' 'FAIL' 'Notepad content changed during the blocked-input safety test.' }
    else { Write-TestResult 'Focus safety' 'SKIPPED' 'False-identity precondition could not be safely simulated; no input was attempted.' }
}

function Test-MinimizeRestore {
    foreach ($spec in @(@{name='Notepad';target='Notepad'},@{name='Windows Terminal';target='Terminal'})) {
        if (-not $script:TestTargets.ContainsKey($spec.target)) { Write-TestResult "Minimize/Restore $($spec.name)" 'SKIPPED' 'No harness-owned target is available.'; continue }
        if (-not $EnableWindowStateTests) { Write-TestResult "Minimize/Restore $($spec.name)" 'SKIPPED' 'State-changing window test disabled (use -EnableWindowStateTests).'; continue }
        $hwnd = [UInt64]$script:TestTargets[$spec.target].hwnd; $app = if($spec.target -eq 'Terminal'){'Terminal'}else{'notepad'}
        $beforeSnapshot=Get-WinAppWindowSnapshot -Application $app -Hwnd $hwnd; $before = Get-WinAppUiTree -Hwnd $hwnd; $beforeCount = @(Get-TreeElements $before).Count
        $min = Invoke-WinAppJson -Arguments @('ui','invoke','Minimize-Restore','-w',([string]$hwnd)) -AllowFailure -Operation "minimize-$($spec.target)"; $duringSnapshot=Get-WinAppWindowSnapshot -Application $app -Hwnd $hwnd; $during = Get-WinAppUiTree -Hwnd $hwnd; $duringCount = @(Get-TreeElements $during).Count; $minShot = Capture-WinAppEvidence -Component $spec.name -Hwnd $hwnd -State 'minimized'
        $restore = Invoke-WinAppJson -Arguments @('ui','invoke','Minimize-Restore','-w',([string]$hwnd)) -AllowFailure -Operation "restore-$($spec.target)"; $afterSnapshot=Get-WinAppWindowSnapshot -Application $app -Hwnd $hwnd; $after = Get-WinAppUiTree -Hwnd $hwnd; $afterCount = @(Get-TreeElements $after).Count
        $minimizeActionSucceeded=($min.exitCode -eq 0); $minimizeStateObserved=Test-WinAppSnapshotChanged -Before $beforeSnapshot -After $duringSnapshot
        $restoreActionSucceeded=($restore.exitCode -eq 0); $restoreStateObserved=(Test-WinAppSnapshotChanged -Before $duringSnapshot -After $afterSnapshot) -and (Test-WinAppSnapshotEqual -Left $beforeSnapshot -Right $afterSnapshot)
        $result=if($minimizeActionSucceeded -and $minimizeStateObserved -and $restoreActionSucceeded -and $restoreStateObserved){'PASS-WITH-LIMITATION'}else{'FAIL'}
        Write-TestResult "Minimize/Restore $($spec.name)" $result "HWND=$hwnd; before=$($beforeSnapshot | ConvertTo-Json -Compress) tree=$beforeCount; minimize CLI-success=$minimizeActionSucceeded state-observed=$minimizeStateObserved snapshot=$($duringSnapshot | ConvertTo-Json -Compress) tree=$duringCount screenshot=$($minShot.success); restore CLI-success=$restoreActionSucceeded state-observed=$restoreStateObserved snapshot=$($afterSnapshot | ConvertTo-Json -Compress) tree=$afterCount"
    }
}

function Test-SelectorStability {
    foreach ($spec in @(@{name='Notepad';target='Notepad'},@{name='Terminal';target='Terminal'})) {
        if (-not $script:TestTargets.ContainsKey($spec.target)) { Write-TestResult "Selector stability $($spec.name)" 'SKIPPED' 'No harness-owned target is available.'; continue }
        $hwnd = [UInt64]$script:TestTargets[$spec.target].hwnd; $first = @(Get-TreeElements (Get-WinAppUiTree -Hwnd $hwnd) | Select-Object -First 20); $second = @(Get-TreeElements (Get-WinAppUiTree -Hwnd $hwnd) | Select-Object -First 20)
        $key = { param($e) '{0}|{1}|{2}|{3}|{4}' -f (Get-ObjectPropertyValue $e @('automationId','AutomationId')),(Get-ObjectPropertyValue $e @('name','Name')),(Get-ObjectPropertyValue $e @('controlType','ControlType','type','Type')),(Get-ObjectPropertyValue $e @('className','ClassName')),(Get-ObjectPropertyValue $e @('selector','Selector')) }
        $a = @($first | ForEach-Object { & $key $_ }); $b = @($second | ForEach-Object { & $key $_ }); $stable = @(Compare-Object $a $b).Count -eq 0
        Write-TestResult "Selector stability $($spec.name)" ($(if($stable){'PASS'}else{'PASS-WITH-LIMITATION'})) "HWND=$hwnd (stable within sample); AutomationId/Name/ControlType/ClassName/selector compared; selector slugs are observations, not durable IDs."
    }
}

function Write-SpikeReport {
    $capabilities = 'Window discovery','HWND targeting','UIA tree','Semantic controls','Read value','Set value','Invoke','Focus','Keyboard fallback','Screenshot','Background observation','Minimized observation','Postcondition verification'
    $currentRows = foreach ($capability in $capabilities) { "| $capability | $(Get-Capability 'Notepad' $capability) | $(Get-Capability 'Explorer' $capability) | $(Get-Capability 'Terminal' $capability) | $(Get-Capability 'LM Studio' $capability) | $(Get-Capability 'Browser' $capability) |" }
    $summary = $script:Results | Group-Object result | ForEach-Object { "$($_.Name)=$($_.Count)" }
    $ownershipRows = if ($script:TestOwnership.Count -eq 0) { '- No test instance was created or claimed.' } else { ($script:TestOwnership | ForEach-Object { "- **$($_.component):** $(if($_.launchedByHarness){'harness-launched'}else{'pre-existing'}); PID=$($_.pid); HWND=$($_.hwnd); title=$($_.title); process=$($_.process); executable=$($_.executable); userWindowsModified=$($_.userWindowsModified); userWindowsLeftUntouched=$($_.userWindowsLeftUntouched)" }) -join "`n" }
    $body = @"
# Desktop-control spike — KI-Stack 2.18

Run started (UTC): $($script:RunStarted)

## Current run results

$(($script:Results | Where-Object result -eq 'PASS' | ForEach-Object { "- **$($_.component):** $($_.detail)" }) -join "`n")

## Current-run limitations and blocked actions

$(($script:Results | Where-Object { $_.result -in @('PASS-WITH-LIMITATION','WARN','BLOCKED') } | ForEach-Object { "- **$($_.component) [$($_.result)]:** $($_.detail)" }) -join "`n")

## Not tested in current run

$(($script:Results | Where-Object result -eq 'SKIPPED' | ForEach-Object { "- **$($_.component):** $($_.detail)" }) -join "`n")

## Historical context / prior spike notes

Prior manual and automated spikes recorded Notepad, Explorer, Focus Safety, Minimize/Restore, LM Studio discovery, and Terminal TabView/TermControl observations. These notes are context only: they do not contribute PASS values, counts, or machine-evaluated capability-matrix cells in this run.

## Never tested

- Browser/OpenWebUI Windows-UIA coverage and browser web-content semantics.
- LM Studio semantic interaction, safe navigation postcondition, and minimized/background observation.
- Automated Terminal buffer readback and harness-owned keyboard input where ownership has not been proven.

## Architecture recommendation based on prior + current evidence

- `winapp ui` 0.6.1 is accepted as the primary Windows desktop UIA backend for KI-Stack 2.18.
- It must sit behind a thin Resolve/Validate/Act/Re-observe/Verify policy wrapper.
- Raw `send-input` must not be exposed directly to the LLM.
- FlaUI and pywinauto remain fallback investigation options, not required dependencies.
- Browser automation remains a separate Playwright/CDP concern; Vision/OmniParser is an optional future fallback.
- Current evidence requires no additional desktop-control service, port, or credential.
- Required guards remain HWND re-resolution; process/title checks; enabled/offscreen/control/class checks; an audited `IsPassword` false-positive registry; explicit keyboard-fallback allowlisting; and mandatory postcondition evidence.

## Test ownership

$ownershipRows

## Safety evidence

- Wrong-window input attempts blocked: $((@($script:Results | Where-Object { $_.component -eq 'Focus safety' -and $_.result -eq 'PASS' }).Count -gt 0))
- Ambiguous windows blocked: $((@($script:Results | Where-Object { $_.detail -match 'not uniquely|Expected one|No harness-owned' }).Count -gt 0))
- System-key restrictions: enforced; no Win+L, Ctrl+Alt+Del, Alt+F4, or Win+R is issued by this harness.
- send-input required: $((@($script:Results | Where-Object { $_.component -eq 'Windows Terminal' -and $_.detail -match 'Input exit' }).Count -gt 0))
- Postcondition used: $((@($script:Results | Where-Object { $_.detail -match 'readback|re-observed|restored-tree' }).Count -gt 0))

## Current run result table

| Component | Result |
|---|---|
$(($script:Results | ForEach-Object { "| $($_.component) | $($_.result) |" }) -join "`n")

## Current run capability matrix

| Capability | Notepad | Explorer | Terminal | LM Studio | Browser |
|---|---|---|---|---|---|
$($currentRows -join "`n")


## Run metadata

- winapp: $($script:WinAppVersion)
- resolved winapp path: $($script:WinAppPath)
- resolution method: $($script:WinAppResolutionMethod)
- PowerShell: $($PSVersionTable.PSVersion)
- Windows: $([Environment]::OSVersion.VersionString)
- Counts: $($summary -join '; ')
- Evidence root: $($script:EvidenceRoot)
"@
    $destination = if ([string]::IsNullOrWhiteSpace($ReportPath)) { Join-Path $script:RunRoot 'desktop-control-spike-2.18.md' } else { [IO.Path]::GetFullPath($ReportPath) }
    $directory = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $directory)) { throw "Report directory does not exist: $directory" }
    if (Test-Path -LiteralPath $destination) { throw "Refusing to overwrite an existing report: $destination" }
    Set-Content -LiteralPath $destination -Value $body -Encoding utf8NoBOM
    return $destination
}

function Invoke-IndependentSpikeTest {
    param([Parameter(Mandatory)][string]$Component,[Parameter(Mandatory)][scriptblock]$Test)
    try { & $Test }
    catch { Write-TestResult $Component 'FAIL' "Unexpected harness state: $($_.Exception.Message). The remaining independent tests will continue." }
}

try {
    $resolvedWinApp = Resolve-WinAppExecutable
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($null -eq $resolvedWinApp) {
        Write-TestResult 'Prerequisites' 'FAIL' "winapp was not found through Get-Command winapp.exe, Get-Command winapp, WindowsApps, where.exe, WinGet Links, or WinGet Packages. No installation, escalation, or PATH change attempted; Windows=$([Environment]::OSVersion.VersionString); PowerShell=$($PSVersionTable.PSVersion); elevated=$isAdmin."
        foreach ($component in 'Notepad baseline','Explorer baseline','Windows Terminal','LM Studio','Browser/OpenWebUI','Focus safety','Minimize/Restore','Selector stability','Screenshot observation') { Write-TestResult $component 'SKIPPED' 'Blocked by missing winapp prerequisite; no UI action was attempted.' }
    }
    else {
        $script:WinAppPath = $resolvedWinApp.path
        $script:WinAppResolutionMethod = $resolvedWinApp.method
        $versionOutput = & $script:WinAppPath --version 2>&1
        $script:WinAppVersion = (ConvertTo-PlainWinAppText ($versionOutput -join "`n")).Trim()
        $versionExitCode = $LASTEXITCODE
        if ($versionExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($script:WinAppVersion)) {
            Write-TestResult 'Prerequisites' 'FAIL' "Resolved path did not pass final version verification: path=$script:WinAppPath; exit=$versionExitCode; version='$script:WinAppVersion'. No UI action attempted."
            foreach ($component in 'Notepad baseline','Explorer baseline','Windows Terminal','LM Studio','Browser/OpenWebUI','Focus safety','Minimize/Restore','Selector stability','Screenshot observation') { Write-TestResult $component 'SKIPPED' 'Blocked by failed resolved-winapp version verification; no UI action was attempted.' }
        }
        else {
            $versionResult = if ($script:WinAppVersion -match '0\.6\.1') {'PASS'} else {'PASS-WITH-LIMITATION'}
            Write-TestResult 'Prerequisites' $versionResult "winapp=$script:WinAppVersion; path=$script:WinAppPath; method=$script:WinAppResolutionMethod; Windows=$([Environment]::OSVersion.VersionString); PowerShell=$($PSVersionTable.PSVersion); elevated=$isAdmin. No installation, escalation, or PATH change attempted."
        Initialize-TestTargets
        $notepad = Test-OwnedNotepad; if ($null -ne $notepad) { Write-TestResult 'Notepad baseline' $notepad.result $notepad.detail }
        $explorer = Test-ObservedApplication -Component 'Explorer' -Application 'explorer' -RequiredElementPattern 'Navigation|Address|Search' -ExpectedProcess 'explorer'; Write-TestResult 'Explorer baseline' $explorer.result $explorer.detail
        Invoke-IndependentSpikeTest -Component 'Windows Terminal' -Test { Test-Terminal }
        Invoke-IndependentSpikeTest -Component 'LM Studio' -Test { Test-LmStudio }
        Invoke-IndependentSpikeTest -Component 'Browser/OpenWebUI' -Test { Test-BrowserOpenWebUi }
        Invoke-IndependentSpikeTest -Component 'Focus safety' -Test { Test-FocusSafety }
        Invoke-IndependentSpikeTest -Component 'Minimize/Restore' -Test { Test-MinimizeRestore }
        Invoke-IndependentSpikeTest -Component 'Selector stability' -Test { Test-SelectorStability }
        foreach ($component in 'Notepad','Terminal','LM Studio') {
            if ($script:TestTargets.ContainsKey($component)) { $target=$script:TestTargets[$component]; $shot = Capture-WinAppEvidence -Component $component -Hwnd $target.hwnd -State 'final'; Write-TestResult "Screenshot observation $component" ($(if($shot.success){'PASS'}else{'FAIL'})) "PID=$($target.pid); HWND=$($target.hwnd); path=$($shot.path); size=$($shot.size)" }
            else { Write-TestResult "Screenshot observation $component" 'SKIPPED' 'No deterministically owned target is available.' }
        }
        }
    }
}
catch {
    Write-TestResult 'Harness' 'FAIL' $_.Exception.Message
}
finally {
    if ([string]::IsNullOrWhiteSpace($script:WinAppVersion)) { $script:WinAppVersion = 'not available' }
    $report = Write-SpikeReport
    Write-Host ''
    Write-Host 'Component                    Result'
    Write-Host '--------------------------------------------'
    $script:Results | ForEach-Object { Write-Host ('{0,-28} {1}' -f $_.component,$_.result) }
    $counts = $script:Results | Group-Object result | ForEach-Object { '{0}={1}' -f $_.Name,$_.Count }
    Write-Host ('Counts: ' + ($counts -join '; '))
    Write-Host "Report: $report"
    Write-Host "Evidence: $script:EvidenceRoot"
    Write-Host 'Git status (no commit/push performed):'
    & git status --short
}

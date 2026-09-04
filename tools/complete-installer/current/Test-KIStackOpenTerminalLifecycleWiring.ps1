[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Regression suite for the additive Open-Terminal Start/Stop chaining in
# CompleteInstaller.psm1's Invoke-KICompleteLifecycle (used by the Complete Installer's own
# root Start-KIStack.cmd/Stop-KIStack.cmd, -Mode Start/Stop). Exercises
# Invoke-KICompleteOpenTerminalLifecycle directly and in isolation -- never the full,
# heavyweight Invoke-KICompleteLifecycle (which requires a real modules/cutover/*-KIStack.cmd on
# TargetRoot, out of scope here) -- proving the two real-world-critical properties: (1) a target
# that never installed Open Terminal (every target before this integration existed, and any
# target that simply never opted in) is completely unaffected -- no throw, no side effect; (2) a
# target that DID install Open Terminal has its own starter/stopper .cmd actually invoked.

Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force

$fail = [Collections.Generic.List[string]]::new()
$checks = [ordered]@{}
$scratchBase = Join-Path ([IO.Path]::GetTempPath()) ('KIOTLW-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $scratchBase -Force | Out-Null

try {
    # --- Not installed: no marker/starter at all -- must be a clean, non-throwing skip. -------
    $t1Root = Join-Path $scratchBase 'not-installed'
    New-Item -ItemType Directory -Path $t1Root -Force | Out-Null
    $startResult1 = Invoke-KICompleteOpenTerminalLifecycle -Action Start -TargetRoot $t1Root
    $stopResult1 = Invoke-KICompleteOpenTerminalLifecycle -Action Stop -TargetRoot $t1Root
    $checks.notInstalledIsACleanNonThrowingSkip = [ordered]@{
        startNotAttempted = (-not [bool]$startResult1.attempted)
        startStillReportsPassed = [bool]$startResult1.passed
        stopNotAttempted = (-not [bool]$stopResult1.attempted)
        stopStillReportsPassed = [bool]$stopResult1.passed
    }
    if ($checks.notInstalledIsACleanNonThrowingSkip.Values -contains $false) { $fail.Add('notInstalledIsACleanNonThrowingSkip failed: ' + ($checks.notInstalledIsACleanNonThrowingSkip | ConvertTo-Json -Compress)) }

    # --- Installed: the real starter/stopper .cmd (written by Install-KIOpenTerminal's exact
    # content generator) is actually invoked. A trivial "exit 0" / "exit 3" stand-in .cmd proves
    # the exit code is faithfully propagated, without needing a real uvx/Open-Terminal process. -
    $t2Root = Join-Path $scratchBase 'installed'
    $moduleRoot = Join-Path $t2Root 'modules/open-terminal'
    New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $moduleRoot 'Start-KIStack-OpenTerminal.cmd') -Encoding ascii -Value "@echo off`r`nexit /b 0`r`n"
    Set-Content -LiteralPath (Join-Path $moduleRoot 'Stop-KIStack-OpenTerminal.cmd') -Encoding ascii -Value "@echo off`r`nexit /b 0`r`n"
    $startResult2 = Invoke-KICompleteOpenTerminalLifecycle -Action Start -TargetRoot $t2Root
    $stopResult2 = Invoke-KICompleteOpenTerminalLifecycle -Action Stop -TargetRoot $t2Root
    $checks.installedStarterAndStopperAreActuallyInvoked = [ordered]@{
        startAttempted = [bool]$startResult2.attempted
        startPassed = [bool]$startResult2.passed
        stopAttempted = [bool]$stopResult2.attempted
        stopPassed = [bool]$stopResult2.passed
    }
    if ($checks.installedStarterAndStopperAreActuallyInvoked.Values -contains $false) { $fail.Add('installedStarterAndStopperAreActuallyInvoked failed: ' + ($checks.installedStarterAndStopperAreActuallyInvoked | ConvertTo-Json -Compress)) }

    # --- A failing starter is reported, never thrown -- must never break the caller's own
    # Invoke-KICompleteLifecycle contract (which only throws on the CORE cutover script's own
    # failure, never on Open Terminal's). ---------------------------------------------------
    $t3Root = Join-Path $scratchBase 'broken-starter'
    $moduleRoot3 = Join-Path $t3Root 'modules/open-terminal'
    New-Item -ItemType Directory -Path $moduleRoot3 -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $moduleRoot3 'Start-KIStack-OpenTerminal.cmd') -Encoding ascii -Value "@echo off`r`nexit /b 7`r`n"
    $thrown3 = $null
    $startResult3 = $null
    try { $startResult3 = Invoke-KICompleteOpenTerminalLifecycle -Action Start -TargetRoot $t3Root } catch { $thrown3 = $_ }
    $checks.failingStarterReportedNeverThrown = [ordered]@{
        neverThrows = ($null -eq $thrown3)
        reportsNotPassed = ($null -ne $startResult3 -and -not [bool]$startResult3.passed)
        exitCodeSurfaced = ($null -ne $startResult3 -and [int]$startResult3.exitCode -eq 7)
    }
    if ($checks.failingStarterReportedNeverThrown.Values -contains $false) { $fail.Add('failingStarterReportedNeverThrown failed: ' + ($checks.failingStarterReportedNeverThrown | ConvertTo-Json -Compress)) }

    $passed = $fail.Count -eq 0
    [pscustomobject]@{ passed = $passed; checks = $checks; failures = @($fail) } | ConvertTo-Json -Depth 12
    if (-not $passed) { throw 'Open-Terminal-Lifecycle-Wiring-Regression fehlgeschlagen.' }
} finally {
    try { Remove-Item -LiteralPath $scratchBase -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

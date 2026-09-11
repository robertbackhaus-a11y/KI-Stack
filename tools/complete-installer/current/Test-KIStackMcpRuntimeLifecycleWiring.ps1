[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Regression suite for the 2.18.0 lifecycle fix: MCP Runtime has been the primary terminal/
# host-control backend for MCP-enabled Open WebUI profiles since 2.15 (Open WebUI itself talks to
# the registered MCP endpoint), so the central Start-KIStack.cmd/Stop-KIStack.cmd contract
# (Invoke-KICompleteLifecycle, -Mode Start/Stop) must start MCP Runtime and prove it healthy
# BEFORE Open WebUI comes up, and must stop Open WebUI before MCP Runtime on the way down. This
# file exercises Invoke-KICompleteMcpRuntimeLifecycle in isolation (mirrors
# Test-KIStackOpenTerminalLifecycleWiring.ps1's own not-installed/installed/failing-starter
# checks exactly) AND, unlike that file, also drives the real Invoke-KICompleteLifecycle
# end-to-end against fake modules/cutover/*-KIStack.cmd + modules/mcp-runtime/*-KIStack-McpRuntime.cmd
# stand-ins -- trivial "append to a shared order log, exit N" scripts, never a real uv/python/MCP
# process -- to prove the ORDERING and the HARD GATE (Open WebUI must never start when MCP
# Runtime fails), which no existing test covers.
#
# No new health definition is introduced anywhere here: the starter .cmd's own exit code IS the
# existing, real health contract (Invoke-KIStackMcpRuntime.ps1 -Action Start -> Start-KIMcpRuntime
# -> Wait-KIMcpRuntimeHealthy -> a genuine MCP protocol initialize+list_tools handshake, never a
# bare port probe) -- this suite only proves Invoke-KICompleteLifecycle correctly reacts to that
# exit code, never re-implements the health check itself. The stronger, real-target MCP
# acceptance contract (server actually started, health actually proven, endpoint actually
# reachable, plus real tool calls and a real Open WebUI agent run) already exists as
# tools/mcp-runtime/current/Test-KIStackMcpRuntime.ps1's 13-point validation gate; this suite
# cites and checks for it rather than duplicating it (it needs a real target/LM Studio/Open WebUI
# and cannot run in this dev sandbox).

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PackageRoot '..\..\..'))
Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force

$fail = [Collections.Generic.List[string]]::new()
$checks = [ordered]@{}
$scratchBase = Join-Path ([IO.Path]::GetTempPath()) ('KIMcpLW-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $scratchBase -Force | Out-Null

function New-DCMcpFakeTarget {
    # Builds a fake TargetRoot with stand-in modules/cutover/*-KIStack.cmd (the core chain that
    # starts/stops SearXNG/ComfyUI/LM Studio/Open WebUI) and, optionally, stand-in
    # modules/mcp-runtime/*-KIStack-McpRuntime.cmd (the same starter/stopper
    # Install-KIMcpRuntime itself writes). Each stand-in appends its own tag to a shared,
    # timestamp-ordered log file and exits with the given code -- proving invocation, ORDER, and
    # exit-code propagation without any real process, uv, or MCP protocol.
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$LogPath,
        [switch]$InstallMcp,
        [int]$McpStartExit = 0,
        [int]$McpStopExit = 0,
        [int]$CutoverStartExit = 0,
        [int]$CutoverStopExit = 0
    )
    $cutoverRoot = Join-Path $Root 'modules/cutover'
    New-Item -ItemType Directory -Path $cutoverRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cutoverRoot 'Start-KIStack.cmd') -Encoding ascii -Value (
        "@echo off`r`necho CUTOVER-START>>`"$LogPath`"`r`nexit /b $CutoverStartExit`r`n"
    )
    Set-Content -LiteralPath (Join-Path $cutoverRoot 'Stop-KIStack.cmd') -Encoding ascii -Value (
        "@echo off`r`necho CUTOVER-STOP>>`"$LogPath`"`r`nexit /b $CutoverStopExit`r`n"
    )
    if ($InstallMcp) {
        $mcpRoot = Join-Path $Root 'modules/mcp-runtime'
        New-Item -ItemType Directory -Path $mcpRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mcpRoot 'Start-KIStack-McpRuntime.cmd') -Encoding ascii -Value (
            "@echo off`r`nif $McpStartExit==0 echo MCP-START>>`"$LogPath`"`r`nexit /b $McpStartExit`r`n"
        )
        Set-Content -LiteralPath (Join-Path $mcpRoot 'Stop-KIStack-McpRuntime.cmd') -Encoding ascii -Value (
            "@echo off`r`necho MCP-STOP>>`"$LogPath`"`r`nexit /b $McpStopExit`r`n"
        )
    }
}

try {
    # === Part 1: Invoke-KICompleteMcpRuntimeLifecycle in isolation (mirrors the Open-Terminal ===
    # === wiring test's own three scenarios exactly) ============================================
    $t1Root = Join-Path $scratchBase 'ot-style-not-installed'
    New-Item -ItemType Directory -Path $t1Root -Force | Out-Null
    $startResult1 = Invoke-KICompleteMcpRuntimeLifecycle -Action Start -TargetRoot $t1Root
    $stopResult1 = Invoke-KICompleteMcpRuntimeLifecycle -Action Stop -TargetRoot $t1Root
    $checks.notInstalledIsACleanNonThrowingSkip = [ordered]@{
        startNotAttempted = (-not [bool]$startResult1.attempted)
        startStillReportsPassed = [bool]$startResult1.passed
        stopNotAttempted = (-not [bool]$stopResult1.attempted)
        stopStillReportsPassed = [bool]$stopResult1.passed
    }
    if ($checks.notInstalledIsACleanNonThrowingSkip.Values -contains $false) { $fail.Add('notInstalledIsACleanNonThrowingSkip failed: ' + ($checks.notInstalledIsACleanNonThrowingSkip | ConvertTo-Json -Compress)) }

    $t2Root = Join-Path $scratchBase 'ot-style-installed'
    $moduleRoot2 = Join-Path $t2Root 'modules/mcp-runtime'
    New-Item -ItemType Directory -Path $moduleRoot2 -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $moduleRoot2 'Start-KIStack-McpRuntime.cmd') -Encoding ascii -Value "@echo off`r`nexit /b 0`r`n"
    Set-Content -LiteralPath (Join-Path $moduleRoot2 'Stop-KIStack-McpRuntime.cmd') -Encoding ascii -Value "@echo off`r`nexit /b 0`r`n"
    $startResult2 = Invoke-KICompleteMcpRuntimeLifecycle -Action Start -TargetRoot $t2Root
    $stopResult2 = Invoke-KICompleteMcpRuntimeLifecycle -Action Stop -TargetRoot $t2Root
    $checks.installedStarterAndStopperAreActuallyInvoked = [ordered]@{
        startAttempted = [bool]$startResult2.attempted
        startPassed = [bool]$startResult2.passed
        stopAttempted = [bool]$stopResult2.attempted
        stopPassed = [bool]$stopResult2.passed
    }
    if ($checks.installedStarterAndStopperAreActuallyInvoked.Values -contains $false) { $fail.Add('installedStarterAndStopperAreActuallyInvoked failed: ' + ($checks.installedStarterAndStopperAreActuallyInvoked | ConvertTo-Json -Compress)) }

    $t3Root = Join-Path $scratchBase 'ot-style-broken-starter'
    $moduleRoot3 = Join-Path $t3Root 'modules/mcp-runtime'
    New-Item -ItemType Directory -Path $moduleRoot3 -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $moduleRoot3 'Start-KIStack-McpRuntime.cmd') -Encoding ascii -Value "@echo off`r`nexit /b 1`r`n"
    $thrown3 = $null
    $startResult3 = $null
    try { $startResult3 = Invoke-KICompleteMcpRuntimeLifecycle -Action Start -TargetRoot $t3Root } catch { $thrown3 = $_ }
    $checks.failingStarterReportedNeverThrownByTheWrapperItself = [ordered]@{
        wrapperNeverThrows = ($null -eq $thrown3)
        reportsNotPassed = ($null -ne $startResult3 -and -not [bool]$startResult3.passed)
        exitCodeSurfaced = ($null -ne $startResult3 -and [int]$startResult3.exitCode -eq 1)
    }
    if ($checks.failingStarterReportedNeverThrownByTheWrapperItself.Values -contains $false) { $fail.Add('failingStarterReportedNeverThrownByTheWrapperItself failed: ' + ($checks.failingStarterReportedNeverThrownByTheWrapperItself | ConvertTo-Json -Compress)) }

    # === Part 2: Invoke-KICompleteLifecycle end-to-end -- ORDER and the HARD GATE ================
    # --- 2a: Start order -- MCP Runtime must run, and be logged, BEFORE the core cutover chain
    #         (which starts Open WebUI). ------------------------------------------------------
    $t4Root = Join-Path $scratchBase 'order-start-healthy'
    $t4Log = Join-Path $scratchBase 'order-start-healthy.log'
    New-DCMcpFakeTarget -Root $t4Root -LogPath $t4Log -InstallMcp
    $start4 = Invoke-KICompleteLifecycle -Action Start -TargetRoot $t4Root
    $lines4 = @(if (Test-Path -LiteralPath $t4Log) { Get-Content -LiteralPath $t4Log } else { @() })
    $checks.startOrderMcpBeforeOpenWebUI = [ordered]@{
        noThrow = $true
        mcpLoggedBeforeCutover = ([array]::IndexOf($lines4, 'MCP-START') -ge 0 -and [array]::IndexOf($lines4, 'CUTOVER-START') -gt [array]::IndexOf($lines4, 'MCP-START'))
        resultReportsMcpAttemptedAndPassed = ([bool]$start4.mcpRuntime.attempted -and [bool]$start4.mcpRuntime.passed)
    }
    if ($checks.startOrderMcpBeforeOpenWebUI.Values -contains $false) { $fail.Add('startOrderMcpBeforeOpenWebUI failed: lines=' + ($lines4 -join ',') + ' :: ' + ($checks.startOrderMcpBeforeOpenWebUI | ConvertTo-Json -Compress)) }

    # --- 2b: Open WebUI must NEVER start when MCP Runtime fails to start/become healthy -- a
    #         clear thrown error, never a silent partial start. ------------------------------
    $t5Root = Join-Path $scratchBase 'order-start-mcp-unhealthy'
    $t5Log = Join-Path $scratchBase 'order-start-mcp-unhealthy.log'
    New-DCMcpFakeTarget -Root $t5Root -LogPath $t5Log -InstallMcp -McpStartExit 1
    $thrown5 = $null
    try { Invoke-KICompleteLifecycle -Action Start -TargetRoot $t5Root | Out-Null } catch { $thrown5 = $_ }
    $lines5 = @(if (Test-Path -LiteralPath $t5Log) { Get-Content -LiteralPath $t5Log } else { @() })
    $checks.openWebUiNotStartedWhenMcpHealthFails = [ordered]@{
        clearErrorThrown = ($null -ne $thrown5)
        errorMentionsMcp = ($null -ne $thrown5 -and [string]$thrown5.Exception.Message -match '(?i)MCP')
        cutoverNeverInvoked = ($lines5 -notcontains 'CUTOVER-START')
    }
    if ($checks.openWebUiNotStartedWhenMcpHealthFails.Values -contains $false) { $fail.Add('openWebUiNotStartedWhenMcpHealthFails failed: lines=' + ($lines5 -join ',') + ' thrown=' + [bool]($null -ne $thrown5) + ' :: ' + ($checks.openWebUiNotStartedWhenMcpHealthFails | ConvertTo-Json -Compress)) }

    # --- 2c: Stop order -- Open WebUI (via the core cutover chain's own Stop-KIStack.cmd, which
    #         chains Stop-KIStack-Applications) goes first, MCP Runtime stops last. -------------
    $t6Root = Join-Path $scratchBase 'order-stop'
    $t6Log = Join-Path $scratchBase 'order-stop.log'
    New-DCMcpFakeTarget -Root $t6Root -LogPath $t6Log -InstallMcp
    $stop6 = Invoke-KICompleteLifecycle -Action Stop -TargetRoot $t6Root
    $lines6 = @(if (Test-Path -LiteralPath $t6Log) { Get-Content -LiteralPath $t6Log } else { @() })
    $checks.stopOrderOpenWebUiBeforeMcp = [ordered]@{
        noThrow = $true
        cutoverStopLoggedBeforeMcpStop = ([array]::IndexOf($lines6, 'CUTOVER-STOP') -ge 0 -and [array]::IndexOf($lines6, 'MCP-STOP') -gt [array]::IndexOf($lines6, 'CUTOVER-STOP'))
        resultReportsMcpStopAttemptedAndPassed = ([bool]$stop6.mcpRuntime.attempted -and [bool]$stop6.mcpRuntime.passed)
    }
    if ($checks.stopOrderOpenWebUiBeforeMcp.Values -contains $false) { $fail.Add('stopOrderOpenWebUiBeforeMcp failed: lines=' + ($lines6 -join ',') + ' :: ' + ($checks.stopOrderOpenWebUiBeforeMcp | ConvertTo-Json -Compress)) }

    # --- 2d: A target that never installed MCP Runtime is completely unaffected -- Start/Stop
    #         behave exactly as before this fix (no throw, cutover chain still runs). ----------
    $t7Root = Join-Path $scratchBase 'order-not-installed'
    $t7Log = Join-Path $scratchBase 'order-not-installed.log'
    New-DCMcpFakeTarget -Root $t7Root -LogPath $t7Log
    $start7 = Invoke-KICompleteLifecycle -Action Start -TargetRoot $t7Root
    $stop7 = Invoke-KICompleteLifecycle -Action Stop -TargetRoot $t7Root
    $lines7 = @(if (Test-Path -LiteralPath $t7Log) { Get-Content -LiteralPath $t7Log } else { @() })
    $checks.targetWithoutMcpRuntimeUnaffected = [ordered]@{
        startNotAttempted = (-not [bool]$start7.mcpRuntime.attempted)
        stopNotAttempted = (-not [bool]$stop7.mcpRuntime.attempted)
        cutoverStartStillRan = ($lines7 -contains 'CUTOVER-START')
        cutoverStopStillRan = ($lines7 -contains 'CUTOVER-STOP')
    }
    if ($checks.targetWithoutMcpRuntimeUnaffected.Values -contains $false) { $fail.Add('targetWithoutMcpRuntimeUnaffected failed: ' + ($checks.targetWithoutMcpRuntimeUnaffected | ConvertTo-Json -Compress)) }

    # --- 2e: Idempotency -- a starter/stopper that reports success on every call (mirrors
    #         Start-KIMcpRuntime's own AlreadyRunning / Stop-KIMcpRuntime's own AlreadyStopped
    #         contract, proven at the component level in McpRuntime.psm1 itself) never breaks
    #         repeated Start/Stop calls through the wrapper. --------------------------------
    $t8Root = Join-Path $scratchBase 'idempotent'
    $t8Log = Join-Path $scratchBase 'idempotent.log'
    New-DCMcpFakeTarget -Root $t8Root -LogPath $t8Log -InstallMcp
    $startA = Invoke-KICompleteLifecycle -Action Start -TargetRoot $t8Root
    $startB = Invoke-KICompleteLifecycle -Action Start -TargetRoot $t8Root
    $stopA = Invoke-KICompleteLifecycle -Action Stop -TargetRoot $t8Root
    $stopB = Invoke-KICompleteLifecycle -Action Stop -TargetRoot $t8Root
    $checks.repeatedStartStopStaysIdempotent = [ordered]@{
        firstStartPassed = [bool]$startA.mcpRuntime.passed
        secondStartPassed = [bool]$startB.mcpRuntime.passed
        firstStopPassed = [bool]$stopA.mcpRuntime.passed
        secondStopPassed = [bool]$stopB.mcpRuntime.passed
    }
    if ($checks.repeatedStartStopStaysIdempotent.Values -contains $false) { $fail.Add('repeatedStartStopStaysIdempotent failed: ' + ($checks.repeatedStartStopStaysIdempotent | ConvertTo-Json -Compress)) }

    # === Part 3: static checks for Health/Status, Acceptance, and no-new-port/credential/service =
    $orchestratorSource = Get-Content -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Raw
    $lifecycleFunctionMatch = [regex]::Match($orchestratorSource, '(?s)function Invoke-KICompleteLifecycle\s*\{.*?\n\}')
    if (-not $lifecycleFunctionMatch.Success) { throw 'Invoke-KICompleteLifecycle nicht gefunden.' }
    $lifecycleFunctionText = $lifecycleFunctionMatch.Value
    $checks.noNewPortCredentialOrService = [ordered]@{
        noHttpListenerOrTcpListener = ($lifecycleFunctionText -notmatch '(?i)HttpListener|TcpListener|\.Bind\(')
        noCredentialCreation = ($lifecycleFunctionText -notmatch '(?i)ConvertTo-SecureString|New-\w*Credential|Save-\w*Credential')
        noNewServiceOrScheduledTask = ($lifecycleFunctionText -notmatch '(?i)New-Service|Register-ScheduledTask|sc\.exe\s+create')
        usesOnlyTheExistingMcpPort = ($lifecycleFunctionText -notmatch '-?\bPort\s*[:=]\s*\d')
        reusesExistingStarterStopperWrappers = ($lifecycleFunctionText.Contains('Invoke-KICompleteMcpRuntimeLifecycle') -and -not $orchestratorSource.Contains('function Start-KICompleteMcpRuntimeProcess'))
    }
    if ($checks.noNewPortCredentialOrService.Values -contains $false) { $fail.Add('noNewPortCredentialOrService failed: ' + ($checks.noNewPortCredentialOrService | ConvertTo-Json -Compress)) }

    $statusScriptPath = Join-Path $PackageRoot 'Lifecycle/Get-KIStackStatus.ps1'
    $statusScript = Get-Content -LiteralPath $statusScriptPath -Raw
    $checks.mcpRuntimeInCentralHealthStatus = [ordered]@{
        statusEntryPresent = $statusScript.Contains("New-StatusResult 'MCP Runtime'")
        processIdentityChecked = $statusScript.Contains('$mcpRuntimeMarker') -and $statusScript.Contains('$mcpTrackedId')
        endpointHealthChecked = $statusScript.Contains('$mcpEndpoint') -and $statusScript.Contains('$mcpHealthy')
        neverLogsApiKey = ($statusScript -notmatch '(?i)apiKey\s*=.*mcpMarker' -and $statusScript -notmatch '(?i)Write-Host.*apiKey')
    }
    if ($checks.mcpRuntimeInCentralHealthStatus.Values -contains $false) { $fail.Add('mcpRuntimeInCentralHealthStatus failed: ' + ($checks.mcpRuntimeInCentralHealthStatus | ConvertTo-Json -Compress)) }

    $mcpAcceptancePath = Join-Path $repoRoot 'tools/mcp-runtime/current/Test-KIStackMcpRuntime.ps1'
    $mcpAcceptanceExists = Test-Path -LiteralPath $mcpAcceptancePath -PathType Leaf
    $mcpAcceptanceSource = if ($mcpAcceptanceExists) { Get-Content -LiteralPath $mcpAcceptancePath -Raw } else { '' }
    $checks.strongerMcpAcceptanceContractExistsAndIsReused = [ordered]@{
        acceptanceScriptExists = $mcpAcceptanceExists
        provesRuntimeStarted = $mcpAcceptanceSource.Contains("'MCP-Server startet/laeuft'") -and $mcpAcceptanceSource.Contains('Start-KIMcpRuntime')
        provesHealthSuccessful = $mcpAcceptanceSource.Contains("'Health Check (MCP initialize+list_tools)'") -and $mcpAcceptanceSource.Contains('Test-KIMcpRuntimeHealthy')
        provesEndpointReachable = $mcpAcceptanceSource.Contains('$health.reachable') -and $mcpAcceptanceSource.Contains('$health.uri')
        notDuplicatedHere = (-not $lifecycleFunctionText.Contains('mcp.client.streamable_http'))
    }
    if ($checks.strongerMcpAcceptanceContractExistsAndIsReused.Values -contains $false) { $fail.Add('strongerMcpAcceptanceContractExistsAndIsReused failed: ' + ($checks.strongerMcpAcceptanceContractExistsAndIsReused | ConvertTo-Json -Compress)) }

    $passed = $fail.Count -eq 0
    [pscustomobject]@{ passed = $passed; checks = $checks; failures = @($fail) } | ConvertTo-Json -Depth 12
    if (-not $passed) { throw 'MCP-Runtime-Lifecycle-Wiring-Regression fehlgeschlagen.' }
} finally {
    try { Remove-Item -LiteralPath $scratchBase -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

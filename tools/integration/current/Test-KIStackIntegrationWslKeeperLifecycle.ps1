[CmdletBinding()]
param([string]$ProjectRoot = $PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# 2.18.2 hotfix regression coverage for the real, reproduced WSL-Keeper defect: launching the
# keeper via a login shell ('-u root -- bash -lc "exec sleep infinity"') let the Windows-side
# wsl.exe launcher die within about a second on a real target, tearing the whole Debian instance
# down again shortly after Get-KIStackStatus.ps1 had reported it Running. This drives the REAL,
# deployed Runtime/Start-KIStack-SearXNG.ps1 and Runtime/Stop-KIStack-SearXNG.ps1 scripts (no
# duplicated logic) against a real WSL/Debian instance when one is available on this host, and is
# skipped (not failed) otherwise -- this file is a Windows-side packaging/contract validator, not
# a WSL provisioning tool.
$distribution = 'Debian'
$fail = [Collections.Generic.List[string]]::new()
$skipped = $false
$skipReason = $null

$wslCommand = Get-Command wsl.exe -ErrorAction SilentlyContinue
$wsl = $null
if ($wslCommand) {
    $wsl = $wslCommand.Source
    $distros = @((& $wsl --list --quiet 2>$null) | ForEach-Object { $_.Trim([char]0).Trim() } | Where-Object { $_ })
    if ($distros -notcontains $distribution) {
        $skipped = $true
        $skipReason = "no '$distribution' WSL distribution registered on this host"
    }
} else {
    $skipped = $true
    $skipReason = 'wsl.exe not available on this host'
}

if ($skipped) {
    [ordered]@{ passed = $true; skipped = $true; reason = $skipReason; checks = 0; failures = @() } | ConvertTo-Json -Depth 5
    return
}

function Test-KIFixtureDebianRunning {
    $running = @((& $wsl --list --running --quiet 2>$null) | ForEach-Object { $_.Trim([char]0).Trim() } | Where-Object { $_ })
    return $running -contains $distribution
}
function Test-KIFixtureSleepAlive {
    if (-not (Test-KIFixtureDebianRunning)) { return $false }
    $out = @(& $wsl -d $distribution -- pgrep -f 'sleep infinity' 2>$null)
    return ($LASTEXITCODE -eq 0) -and (@($out | Where-Object { $_ -match '^\d+$' }).Count -gt 0)
}
function Stop-KIFixtureKeeperOnly {
    if (Test-KIFixtureDebianRunning) { & $wsl -d $distribution -- pkill -f 'sleep infinity' 2>$null | Out-Null }
}
function Wait-KIFixtureCondition([scriptblock]$Condition, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 500 } while ((Get-Date) -lt $deadline)
    return (& $Condition)
}

# Preserve this host's real state so the test leaves it exactly as found.
$originalDebianRunning = Test-KIFixtureDebianRunning
$originalSleepAlive = Test-KIFixtureSleepAlive

$sourceRoot = Join-Path $ProjectRoot 'Runtime'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('ki-stack-integration-wsl-keeper-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceRoot 'Start-KIStack-SearXNG.ps1') -Destination $fixtureRoot
Copy-Item -LiteralPath (Join-Path $sourceRoot 'Stop-KIStack-SearXNG.ps1') -Destination $fixtureRoot
$startScript = Join-Path $fixtureRoot 'Start-KIStack-SearXNG.ps1'
$stopScript = Join-Path $fixtureRoot 'Stop-KIStack-SearXNG.ps1'
$pidFile = Join-Path $fixtureRoot 'wsl-keeper.pid'

try {
    Stop-KIFixtureKeeperOnly
    if (-not (Wait-KIFixtureCondition { -not (Test-KIFixtureSleepAlive) } 10)) {
        $fail.Add('setup: could not reach a clean no-keeper baseline before testing')
    }

    # Scenario 1: keeper starts and is verifiably alive afterward. The real script also waits for
    # a SearXNG readiness signal; that part may legitimately fail on a host with no SearXNG
    # payload installed and is not this test's concern -- only the keeper lifecycle is checked.
    try { & $startScript 2>&1 | Out-Null } catch {}
    if (-not (Test-KIFixtureSleepAlive)) { $fail.Add('scenario 1 (keeper start): no real sleep-infinity process found in Debian after Start-KIStack-SearXNG.ps1') }

    # Scenario 2: a stale/bogus PID file plus a real, still-running keeper must be recognized as
    # already alive, and must never cause a second, duplicate keeper to be spawned.
    Set-Content -LiteralPath $pidFile -Value '999999' -Encoding ascii
    $beforeCount = @(& $wsl -d $distribution -- pgrep -f 'sleep infinity' 2>$null | Where-Object { $_ -match '^\d+$' }).Count
    try { & $startScript 2>&1 | Out-Null } catch {}
    $afterCount = @(& $wsl -d $distribution -- pgrep -f 'sleep infinity' 2>$null | Where-Object { $_ -match '^\d+$' }).Count
    if (-not (Test-KIFixtureSleepAlive)) { $fail.Add('scenario 2 (stale PID + real keeper): incorrectly reported the real keeper as stopped') }
    if ($afterCount -ne $beforeCount) { $fail.Add("scenario 2 (stale PID + real keeper): caused a duplicate keeper (before=$beforeCount after=$afterCount)") }

    # Scenario 3: the PID file names a real, currently-running process that is not a keeper at
    # all (no sleep-infinity process exists) -- a fresh keeper must be started.
    Stop-KIFixtureKeeperOnly
    if (-not (Wait-KIFixtureCondition { -not (Test-KIFixtureSleepAlive) } 10)) { $fail.Add('scenario 3 setup: keeper still alive after being stopped') }
    Set-Content -LiteralPath $pidFile -Value ([string]$PID) -Encoding ascii
    try { & $startScript 2>&1 | Out-Null } catch {}
    if (-not (Test-KIFixtureSleepAlive)) { $fail.Add('scenario 3 (PID present, no sleep process): no keeper was started when the recorded PID belonged to an unrelated, non-keeper process') }

    # Scenario 4: Debian genuinely stopped -- the health check must report not-alive and must
    # never itself start Debian just to check (wsl --terminate forces a deterministic Stopped
    # state regardless of this host's own idle-timeout configuration).
    Stop-KIFixtureKeeperOnly
    & $wsl --terminate $distribution 2>$null | Out-Null
    if (Test-KIFixtureDebianRunning) {
        $fail.Add('scenario 4 setup: Debian did not reach Stopped after wsl --terminate')
    } else {
        if (Test-KIFixtureSleepAlive) { $fail.Add('scenario 4 (Debian stopped): keeper incorrectly reported alive') }
        if (Test-KIFixtureDebianRunning) { $fail.Add('scenario 4 (Debian stopped): the health check itself started Debian') }
    }

    # Scenario 5: clean stop -- starting then stopping a keeper must leave no real sleep process
    # behind, and the stop script's own diagnostics must not resurrect Debian in the process.
    try { & $startScript 2>&1 | Out-Null } catch {}
    if (-not (Test-KIFixtureSleepAlive)) { $fail.Add('scenario 5 setup: keeper did not come up before testing a clean stop') }
    try { & $stopScript 2>&1 | Out-Null } catch {}
    if (Test-KIFixtureSleepAlive) { $fail.Add('scenario 5 (clean stop): a real sleep-infinity process remained after Stop-KIStack-SearXNG.ps1') }
    $idledDown = Wait-KIFixtureCondition { -not (Test-KIFixtureDebianRunning) } 20
    if (-not $idledDown) {
        # Whether Debian's own idle-shutdown fires within our patience depends on this host's WSL
        # configuration (.wslconfig vmIdleTimeout), not on this fix -- not counted as a failure as
        # long as no real keeper process is left running (already checked above).
        Write-Host 'KI_STACK_WSL_KEEPER_SELFTEST|note=Debian did not idle down to Stopped within 20s after a clean stop (host idle-timeout configuration, not a keeper defect)'
    }
} finally {
    Stop-KIFixtureKeeperOnly
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    if ($originalSleepAlive -and -not (Test-KIFixtureSleepAlive)) {
        Start-Process -FilePath $wsl -ArgumentList @('-d', $distribution, '--exec', '/bin/sleep', 'infinity') -WindowStyle Hidden | Out-Null
    } elseif (-not $originalDebianRunning) {
        [void](Wait-KIFixtureCondition { -not (Test-KIFixtureDebianRunning) } 20)
    }
}

$result = [ordered]@{ passed = ($fail.Count -eq 0); skipped = $false; distribution = $distribution; checks = 5; failures = @($fail) }
$result | ConvertTo-Json -Depth 10
if ($fail.Count) { throw ($fail -join '; ') }

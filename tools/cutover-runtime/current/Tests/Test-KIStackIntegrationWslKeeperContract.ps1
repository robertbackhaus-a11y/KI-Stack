[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# 2.18.2 hotfix static contract: KIModuleIntegration.psm1's generated Start/Stop content is the
# BuilderKernel's own independent copy of the WSL-Keeper starter, deployed to
# <TargetRoot>/modules/integration alongside (and potentially after) the isolated Integration
# component's own copy in tools/integration/current/Runtime -- the identical dual-copy shape
# already documented for Get-KIIntegrationOpenWebUIWithSearchStarterContent in this same module.
# Test-KIStackIntegrationWslKeeperLifecycle.ps1 (tools/integration/current) exercises the real,
# live keeper lifecycle end to end against the isolated copy; this file proves the BuilderKernel's
# copy embeds the identical fixed pattern via static source inspection, since KIModuleIntegration's
# generator needs a full transaction/config context that cannot be fixtured as lightly.
$fail = [Collections.Generic.List[string]]::new()
$modulePath = Join-Path $ProjectRoot 'Modules/07-Integration/KIModuleIntegration.psm1'
$moduleText = Get-Content -LiteralPath $modulePath -Raw

$startMatch = [regex]::Match($moduleText, "(?s)\`$startPs=@'.*?'@")
if (-not $startMatch.Success) { $fail.Add('generated $startPs heredoc not found') }
$startContent = if ($startMatch.Success) { $startMatch.Value } else { '' }

$stopMatch = [regex]::Match($moduleText, "(?s)\`$stopPs=@'.*?'@")
if (-not $stopMatch.Success) { $fail.Add('generated $stopPs heredoc not found') }
$stopContent = if ($stopMatch.Success) { $stopMatch.Value } else { '' }

# The keeper launch itself must use --exec /bin/sleep infinity, with no bash -lc login-shell
# wrapper (the real, reproduced root cause: a login session torn down independently of the
# exec'ed sleep process, killing it and letting Debian fall back to Stopped).
if ($startContent -notmatch [regex]::Escape("Start-Process -FilePath `$wsl -ArgumentList @('-d',`$distribution,'--exec','/bin/sleep','infinity')")) {
    $fail.Add('keeper Start-Process no longer launches --exec /bin/sleep infinity directly')
}
if ($startContent -match "(?i)Start-Process[^\n]*bash[^\n]*-lc") {
    $fail.Add('REGRESSION: keeper Start-Process still wraps the launch in bash -lc (2.18.2 defect reintroduced)')
}

# The Windows PID file must be demoted to best-effort/informational only: the alive/not-alive
# decision must come from a real in-Debian process check, never from Get-Process on that PID.
if ($startContent -notmatch 'function Test-KIWslDebianRunning') { $fail.Add('Test-KIWslDebianRunning helper missing from generated start content') }
if ($startContent -notmatch 'function Test-KIWslKeeperProcessAlive') { $fail.Add('Test-KIWslKeeperProcessAlive helper missing from generated start content') }
if ($startContent -notmatch "pgrep\s+-f\s+'sleep infinity'") { $fail.Add('generated start content does not verify a real in-Debian sleep-infinity process via pgrep') }
if ($startContent -notmatch '--list\s+--running\s+--quiet') { $fail.Add('generated start content does not check whether Debian is an actually running distribution') }
# The only correctness-relevant use of the recorded PID must be opportunistic stale-file cleanup,
# never a gate on whether a keeper is considered alive.
$decisionGate = [regex]::Match($startContent, "(?s)if\(-not\(Test-KIWslKeeperProcessAlive\)\)\{.*?\n\}")
if (-not $decisionGate.Success) { $fail.Add('start content does not gate the keeper-launch decision on Test-KIWslKeeperProcessAlive') }

# Post-start verification: the script must not proceed to Linux service startup until the keeper
# is confirmed durably alive.
if ($startContent -notmatch '(?s)Start-Process[^\n]*\n\s*Set-Content[^\n]*\n\s*\$keeperDeadline') { $fail.Add('start content does not poll for real keeper aliveness immediately after launching it') }
if ($startContent -notmatch "throw 'WSL-Keeper \(sleep infinity in Debian\) konnte nicht gestartet werden") { $fail.Add('start content does not fail loudly when the keeper cannot be verified alive') }

# Stop path: the real in-Debian process must be killed directly; the Windows PID is best-effort.
if ($stopContent -notmatch "pkill\s+-f\s+'sleep infinity'") { $fail.Add('stop content does not kill the real in-Debian sleep-infinity process') }
if ($stopContent -notmatch '--list\s+--running\s+--quiet') { $fail.Add('stop content does not check whether Debian is running before acting') }

$failed = @($fail)
$result = [ordered]@{ passed = ($failed.Count -eq 0); checks = 10; failures = $failed }
$result | ConvertTo-Json -Depth 10
if ($failed.Count) { throw ($failed -join '; ') }

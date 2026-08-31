[CmdletBinding()]
param([string]$ModulePath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/08-Cutover/KIModuleCutover.psm1'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

# 2.13.0-Consolidation-Workstream, Nebenfund B (real, reproduced): Start-KIStack.ps1's generated
# Test-KIStack-Health.ps1 used to make exactly ONE immediate HTTP attempt per endpoint right
# after a flat 5s global startup grace period -- ComfyUI/OpenWebUI legitimately take longer than
# that, so a normal, successful startup could be reported as allReachable:false (a false
# negative), not a real failure. Fixed with a bounded per-endpoint poll/retry loop. This suite
# runs the REAL generated health-script content (via Get-KICutoverGeneratedContent, nothing
# reimplemented) against real, disposable TcpListener-based mock endpoints -- no live KI-Stack
# application startup needed to prove the fix.

Import-Module $ModulePath -Force -DisableNameChecking

function New-KIFixtureContext {
    param([array]$Endpoints,[string]$ReportRoot,[int]$HealthTimeoutSeconds=15)
    $cutoverConfig=[pscustomobject]@{
        moduleRoot=(Join-Path $ReportRoot 'modules/cutover')
        installationMarker=(Join-Path $ReportRoot 'modules/cutover/installation.json')
        reportRoot=(Join-Path $ReportRoot 'reports/cutover')
        healthReportPath=(Join-Path $ReportRoot 'reports/cutover/Health-latest.json')
        acceptanceReportPath=(Join-Path $ReportRoot 'reports/cutover/Acceptance-latest.json')
        healthTimeoutSeconds=$HealthTimeoutSeconds
        startupGraceSeconds=1
        requireLiveEndpointsDuringExecute=$false
        endpoints=$Endpoints
        startScripts=[pscustomobject]@{searxng='a';lmStudio='b';openWebUI='c';comfyUI='d'}
        stopScripts=[pscustomobject]@{applications='e';searxng='f';comfyUI='g'}
    }
    [pscustomobject]@{Config=[pscustomobject]@{cutover=$cutoverConfig;executeRelease=[pscustomobject]@{releaseId='fixture'}}}
}

function Start-KIDelayedMockEndpoint {
    # A background PowerShell job (not a separately spawned pwsh.exe -File process, which proved
    # unreliable to time-coordinate with this suite's own real-world process-launch overhead in
    # this environment) hosting a real TcpListener -- delays only the LISTENER bind (simulating
    # "not started yet"), not the response once bound, so the retry loop under test is exercised
    # against a real, if initially-absent, TCP endpoint.
    param([int]$Port,[int]$DelaySeconds)
    Start-Job -ScriptBlock {
        param($Port,$DelaySeconds)
        Start-Sleep -Seconds $DelaySeconds
        $tcp=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
        $tcp.Start()
        $client=$tcp.AcceptTcpClient()
        $stream=$client.GetStream()
        $bodyBytes=[Text.Encoding]::UTF8.GetBytes('{"status":"ok"}')
        $header="HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
        $headerBytes=[Text.Encoding]::ASCII.GetBytes($header)
        $stream.Write($headerBytes,0,$headerBytes.Length)
        $stream.Write($bodyBytes,0,$bodyBytes.Length)
        $stream.Flush()
        # Closing immediately after Flush() raced the client's own read in this environment
        # (reproduced live: "connection closed by remote host" even though the server-side job
        # completed normally) -- a short grace period before Close() is the same fix already
        # applied throughout this session's other raw-TcpListener test mocks.
        Start-Sleep -Milliseconds 300
        $client.Close()
        $tcp.Stop()
    } -ArgumentList $Port,$DelaySeconds
}

$suiteRoot=Join-Path ([IO.Path]::GetTempPath()) ('KICX-HealthRetry-'+[guid]::NewGuid().ToString('N').Substring(0,10))
New-Item -ItemType Directory -Path $suiteRoot -Force|Out-Null

try{
    # --- 1. Structural: the generated health script really contains a bounded retry loop, and
    # the default overall budget really comes from the config's own healthTimeoutSeconds (never
    # a single-shot check, never an unbounded loop). ---------------------------------------------
    $fixtureContext=New-KIFixtureContext -Endpoints @(@{name='X';kind='json';url='http://127.0.0.1:1/'}) -ReportRoot $suiteRoot
    $content=Get-KICutoverGeneratedContent -Context $fixtureContext
    $checks.generatedHealthScriptHasBoundedRetryLoop=[ordered]@{
        hasMaxWaitParam=$content.healthPs1.Contains('$MaxWaitSeconds=0')
        readsConfiguredHealthTimeout=$content.healthPs1.Contains('[int]$config.healthTimeoutSeconds')
        hasRetryLoop=$content.healthPs1.Contains('while($true){')
        hasBoundedExit=$content.healthPs1.Contains('$sw.Elapsed.TotalSeconds-ge$MaxWaitSeconds')
    }
    if($checks.generatedHealthScriptHasBoundedRetryLoop.Values-contains$false){$fail.Add('generatedHealthScriptHasBoundedRetryLoop failed: '+($checks.generatedHealthScriptHasBoundedRetryLoop|ConvertTo-Json -Compress))}

    # --- 2. Real behavior: a genuinely slow-but-successfully-starting endpoint (5s delay) is
    # correctly detected as reachable within a real, bounded retry budget -- the exact false-
    # negative this Nebenfund reported must no longer occur. -------------------------------------
    # DelaySeconds/MaxWaitSeconds are set with real margin for this environment's own real
    # pwsh.exe cold-start overhead (module auto-loading etc. can itself take several real
    # seconds before the mock's own Start-Sleep even begins) -- the point under test is the
    # retry loop's behavior, not a tight race against process-launch latency.
    $slowPort=Get-Random -Minimum 25000 -Maximum 30000
    $mockJob=Start-KIDelayedMockEndpoint -Port $slowPort -DelaySeconds 3
    $slowScript=Join-Path $suiteRoot 'health-slow.ps1'
    Set-Content -LiteralPath $slowScript -Value $content.healthPs1 -Encoding utf8NoBOM
    $slowScriptText=(Get-Content -LiteralPath $slowScript -Raw).Replace('http://127.0.0.1:1/',"http://127.0.0.1:$slowPort/x")
    Set-Content -LiteralPath $slowScript -Value $slowScriptText -Encoding utf8NoBOM
    $sw1=[Diagnostics.Stopwatch]::StartNew()
    $slowRaw=& pwsh -NoProfile -File $slowScript -TimeoutSeconds 5 -MaxWaitSeconds 15 -RetryIntervalSeconds 2 2>&1
    $slowExit=$LASTEXITCODE
    $sw1.Stop()
    $slowReport=($slowRaw-join "`n")|ConvertFrom-Json -Depth 15
    $checks.slowButRealStartupNeverFalseNegative=[ordered]@{
        allReachable=([bool]$slowReport.allReachable)
        exitCodeZero=($slowExit-eq0)
        tookMoreThanOneAttempt=([int]$slowReport.endpoints[0].attempts-gt1)
        boundedNotIndefinite=($sw1.Elapsed.TotalSeconds-lt20)
    }
    if($checks.slowButRealStartupNeverFalseNegative.Values-contains$false){$fail.Add('slowButRealStartupNeverFalseNegative failed: '+($checks.slowButRealStartupNeverFalseNegative|ConvertTo-Json -Compress)+' | report: '+($slowReport|ConvertTo-Json -Compress))}

    # --- 3. Negative control: a component that never comes up must still fail, with a clear,
    # bounded (never indefinite) timeout, non-zero exit code, and a diagnosable attempt count --
    # the fix must never turn a real, permanent failure into a false positive. -------------------
    $deadPort=Get-Random -Minimum 25000 -Maximum 30000
    $deadScript=Join-Path $suiteRoot 'health-dead.ps1'
    $deadScriptText=(Get-Content -LiteralPath $slowScript -Raw).Replace("http://127.0.0.1:$slowPort/x","http://127.0.0.1:$deadPort/x")
    Set-Content -LiteralPath $deadScript -Value $deadScriptText -Encoding utf8NoBOM
    $sw2=[Diagnostics.Stopwatch]::StartNew()
    $deadRaw=& pwsh -NoProfile -File $deadScript -TimeoutSeconds 2 -MaxWaitSeconds 6 -RetryIntervalSeconds 2 2>&1
    $deadExit=$LASTEXITCODE
    $sw2.Stop()
    $deadReport=($deadRaw-join "`n")|ConvertFrom-Json -Depth 15
    $checks.negativeControl_NeverStartingComponentStillFails=[ordered]@{
        notReachable=(-not [bool]$deadReport.allReachable)
        exitCodeNonZero=($deadExit-ne0)
        multipleAttemptsMade=([int]$deadReport.endpoints[0].attempts-gt1)
        boundedNotIndefinite=($sw2.Elapsed.TotalSeconds-lt15)
    }
    if($checks.negativeControl_NeverStartingComponentStillFails.Values-contains$false){$fail.Add('negativeControl_NeverStartingComponentStillFails failed: '+($checks.negativeControl_NeverStartingComponentStillFails|ConvertTo-Json -Compress)+' | report: '+($deadReport|ConvertTo-Json -Compress))}
}finally{
    if($mockJob){Stop-Job -Job $mockJob -ErrorAction SilentlyContinue;Remove-Job -Job $mockJob -Force -ErrorAction SilentlyContinue}
    if(Test-Path -LiteralPath $suiteRoot){Remove-Item -LiteralPath $suiteRoot -Recurse -Force -ErrorAction SilentlyContinue}
}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 12
if(-not$passed){throw 'Startup-Health-Retry-Regression fehlgeschlagen.'}

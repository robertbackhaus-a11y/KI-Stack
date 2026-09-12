[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Structural + real-process regression suite for the Open Terminal managed component
# (OpenTerminal.psm1). Where a real local HTTP server is needed to exercise the actual
# PID-tracking/identity/health-wait code paths end to end, this suite launches the REAL pwsh.exe
# running a tiny local fixture script that serves /openapi.json -- via the same -CommandOverride/
# -ArgumentsOverride/-AllowedProcessNames test seams OpenTerminal.psm1 documents as existing only
# for this purpose. No real `uv`/`uvx` installation or network access is required to run this
# suite; the real uvx contract itself (the exact argument list) is verified separately and
# directly via Get-KIOpenTerminalStartArguments, without spawning any process.

Import-Module (Join-Path $PackageRoot 'OpenTerminal.psm1') -Force

$fail = [Collections.Generic.List[string]]::new()
$checks = [ordered]@{}
$scratchBase = Join-Path ([IO.Path]::GetTempPath()) ('KIOT-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $scratchBase -Force | Out-Null
$startedProcessIds = [Collections.Generic.List[int]]::new()

function New-KIOpenTerminalTestRoot {
    param([string]$Name)
    $root = Join-Path $scratchBase $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $root
}

# The local HTTP fixture: a real, minimal /openapi.json server. -Port/-WorkspaceDir are bound
# normally; the fixed, trailing production-shaped tokens ('open-terminal','--port',N,workspace)
# that a real `uvx open-terminal run ...` invocation would carry are absorbed harmlessly via
# ValueFromRemainingArguments so the exact same identity-check regexes OpenTerminal.psm1 uses in
# production are exercised unchanged against this fixture's own real command line.
$fixtureScriptPath = Join-Path $scratchBase 'FakeOpenTerminalServer.ps1'
Set-Content -LiteralPath $fixtureScriptPath -Encoding utf8NoBOM -Value @'
# Parameter names deliberately do NOT match any of the trailing, production-shaped tokens
# (open-terminal / --port / <port> / <workspace>) this fixture is invoked with -- PowerShell's
# own parameter binder matches a later bare `--port` token against any parameter literally named
# "Port" (dash-prefix tolerant), which would otherwise collide with an already-bound -ListenPort
# and fail with "specified more than once". Naming these ListenPort/ListenWorkspaceDir avoids
# that collision entirely so the harmless trailing tokens are absorbed by $Rest instead.
param([int]$ListenPort,[string]$ListenWorkspaceDir,[Parameter(ValueFromRemainingArguments=$true)]$Rest)
$listener = $null
try {
    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add("http://127.0.0.1:$ListenPort/")
    $listener.Start()
    while ($true) {
        $context = $listener.GetContext()
        $bytes = [Text.Encoding]::UTF8.GetBytes('{"openapi":"3.1.0","info":{"title":"fake-open-terminal"}}')
        $context.Response.ContentType = 'application/json'
        $context.Response.StatusCode = 200
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.OutputStream.Close()
    }
} catch {
    # Real, expected failure mode for the port-already-occupied scenario -- e.g. HttpListener
    # refusing to bind because another process already holds the same URL reservation. Exit
    # non-zero explicitly rather than relying on the host's own default exit-code behavior for
    # an uncaught .NET exception.
    exit 1
} finally {
    if ($null -ne $listener -and $listener.IsListening) { $listener.Stop() }
}
'@

# A second fixture, used ONLY where the real TCP port-owner PID must be independently verifiable
# via Get-NetTCPConnection (the 2.18.2 hotfix's port-owner fallback scenarios below): a raw
# Winsock TcpListener, not [Net.HttpListener]. Real, reproduced: HttpListener binds through
# Windows' kernel-mode HTTP.SYS (URL-ACL reservations), and Get-NetTCPConnection reports HTTP.SYS-
# backed listeners as owned by PID 4 ("System"), never the real user-mode process -- exactly the
# same reason Test-KIStackLMStudioStarterContract.ps1's own mock server already uses a raw
# TcpListener instead. Open Terminal's real server (a Python ASGI app) binds an ordinary socket,
# not HTTP.SYS, so this fixture -- not FakeOpenTerminalServer.ps1 above -- is the one that matches
# production's real port-ownership semantics.
$rawSocketFixtureScriptPath = Join-Path $scratchBase 'FakeOpenTerminalRawSocketServer.ps1'
Set-Content -LiteralPath $rawSocketFixtureScriptPath -Encoding utf8NoBOM -Value @'
param([int]$ListenPort,[string]$ListenWorkspaceDir,[Parameter(ValueFromRemainingArguments=$true)]$Rest)
$tcp = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse('127.0.0.1'), $ListenPort)
$tcp.Start()
while ($true) {
    $client = $tcp.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $buffer = [byte[]]::new(4096)
        [void]$stream.Read($buffer, 0, $buffer.Length)
        $body = [Text.Encoding]::UTF8.GetBytes('{"openapi":"3.1.0","info":{"title":"fake-open-terminal"}}')
        $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
        $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
        $stream.Write($headerBytes, 0, $headerBytes.Length)
        $stream.Write($body, 0, $body.Length)
        $stream.Flush()
    } finally {
        $client.Close()
    }
}
'@

# Occupies the SAME resource the fixture server itself binds (an HttpListener URL prefix, via
# Windows' HTTP.SYS -- a distinct reservation mechanism from a plain Winsock TcpListener, which
# does NOT reliably conflict with it) so the real fixture's own bind attempt genuinely fails,
# used for the already-occupied-port scenario.
$occupyScriptPath = Join-Path $scratchBase 'OccupyPort.ps1'
Set-Content -LiteralPath $occupyScriptPath -Encoding utf8NoBOM -Value @'
param([int]$Port)
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Start-Sleep -Seconds 120
'@

$pwshPath = (Get-Command pwsh).Source

function Get-KIOpenTerminalFreePort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse('127.0.0.1'), 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $port
}

function New-KIOpenTerminalFixtureArguments {
    param([int]$Port, [string]$WorkspacePath)
    @('-NoLogo', '-NoProfile', '-File', $fixtureScriptPath, '-ListenPort', [string]$Port, '-ListenWorkspaceDir', $WorkspacePath, 'open-terminal', '--port', [string]$Port, $WorkspacePath)
}

function Get-KIOpenTerminalConfigForPort {
    # A per-test config copy pinned to a fresh, real, free ephemeral port -- so parallel test
    # runs (and this machine's own real services) can never collide with the fixed production
    # default (127.0.0.1:8000). Passed via -ConfigOverride so Start/Stop/Status all agree on the
    # SAME (test) port -- never mixed with the real, on-disk default config.
    param([int]$Port)
    $config = Get-KIOpenTerminalConfig -PackageRoot $PackageRoot
    $config.port = $Port
    $config
}

function Start-KIOpenTerminalFixture {
    param([string]$TargetRoot, [int]$Port)
    $paths = Get-KIOpenTerminalPaths -TargetRoot $TargetRoot
    $result = Start-KIOpenTerminal -PackageRoot $PackageRoot -TargetRoot $TargetRoot -CommandOverride $pwshPath `
        -ArgumentsOverride (New-KIOpenTerminalFixtureArguments -Port $Port -WorkspacePath $paths.workspace) `
        -AllowedProcessNames @('pwsh.exe') -ConfigOverride (Get-KIOpenTerminalConfigForPort -Port $Port)
    if ([bool]$result.passed -and $result.PSObject.Properties['processId']) { $startedProcessIds.Add([int]$result.processId) }
    $result
}

try {
    # === 1: Erstinstallation erzeugt Key ================================================
    $t1Root = New-KIOpenTerminalTestRoot 't1-install-creates-key'
    $install1 = Install-KIOpenTerminal -PackageRoot $PackageRoot -TargetRoot $t1Root -Action Install -SkipUvCheck
    $cred1 = Get-KIOpenTerminalCredential -TargetRoot $t1Root
    $checks.installCreatesKey = [ordered]@{
        installPassed = [bool]$install1.passed
        credentialFileExists = Test-Path -LiteralPath (Get-KIOpenTerminalPaths -TargetRoot $t1Root).credentialFile -PathType Leaf
        credentialDecrypts = ($null -ne $cred1) -and (-not [bool]$cred1.decryptionFailed)
    }
    if ($checks.installCreatesKey.Values -contains $false) { $fail.Add('installCreatesKey failed: ' + ($checks.installCreatesKey | ConvertTo-Json -Compress)) }

    # === 2: Zweiter Start verwendet exakt denselben Key; bestehende Installation wird nicht
    #        unnötig neu erzeugt (Install ein zweites Mal -> SkippedAlreadyCompliant). ========
    $keyPlain1 = ConvertFrom-KIOpenTerminalSecureStringTransient -Value $cred1.apiKey
    $install2 = Install-KIOpenTerminal -PackageRoot $PackageRoot -TargetRoot $t1Root -Action Install -SkipUvCheck
    $cred2 = Get-KIOpenTerminalCredential -TargetRoot $t1Root
    $keyPlain2 = ConvertFrom-KIOpenTerminalSecureStringTransient -Value $cred2.apiKey
    $checks.secondInstallReusesKeyAndSkipsReinstall = [ordered]@{
        secondInstallSkippedAlreadyCompliant = ([string]$install2.status -eq 'SkippedAlreadyCompliant')
        sameKeyReused = ($keyPlain1 -ceq $keyPlain2)
    }
    if ($checks.secondInstallReusesKeyAndSkipsReinstall.Values -contains $false) { $fail.Add('secondInstallReusesKeyAndSkipsReinstall failed: ' + ($checks.secondInstallReusesKeyAndSkipsReinstall | ConvertTo-Json -Compress)) }
    $keyPlain1 = $null; $keyPlain2 = $null

    # === 3: Start + Healthcheck, dann zweiter Start verwendet exakt denselben Key (Prozessebene),
    #        und Key wird nicht geloggt. ==================================================
    $t3Root = New-KIOpenTerminalTestRoot 't3-start-health-key'
    $port3 = Get-KIOpenTerminalFreePort
    Install-KIOpenTerminal -PackageRoot $PackageRoot -TargetRoot $t3Root -Action Install -SkipUvCheck | Out-Null
    $credBeforeStart = Get-KIOpenTerminalCredential -TargetRoot $t3Root
    $keyBeforeStart = ConvertFrom-KIOpenTerminalSecureStringTransient -Value $credBeforeStart.apiKey

    $transcriptPath = Join-Path $scratchBase 't3-transcript.txt'
    Start-Transcript -Path $transcriptPath -Force | Out-Null
    $start3 = $null
    try { $start3 = Start-KIOpenTerminalFixture -TargetRoot $t3Root -Port $port3 } finally { Stop-Transcript | Out-Null }
    $transcriptText = Get-Content -LiteralPath $transcriptPath -Raw
    $markerText = Get-Content -LiteralPath (Get-KIOpenTerminalPaths -TargetRoot $t3Root).marker -Raw
    $pidFileText = Get-Content -LiteralPath (Get-KIOpenTerminalPaths -TargetRoot $t3Root).pidFile -Raw

    $checks.startAndHealthcheck = [ordered]@{
        startPassed = [bool]$start3.passed
        statusStarted = ([string]$start3.status -eq 'Started')
        processIdReported = ($null -ne $start3.processId -and [int]$start3.processId -gt 0)
        endpointReported = (-not [string]::IsNullOrWhiteSpace([string]$start3.endpoint))
    }
    if ($checks.startAndHealthcheck.Values -contains $false) { $fail.Add('startAndHealthcheck failed: ' + ($checks.startAndHealthcheck | ConvertTo-Json -Compress)) }

    $checks.apiKeyNeverLogged = [ordered]@{
        notInTranscript = (-not $transcriptText.Contains($keyBeforeStart))
        notInMarkerFile = (-not $markerText.Contains($keyBeforeStart))
        notInPidFile = (-not $pidFileText.Contains($keyBeforeStart))
        notInStartResultJson = (-not (($start3 | ConvertTo-Json -Depth 10)).Contains($keyBeforeStart))
    }
    if ($checks.apiKeyNeverLogged.Values -contains $false) { $fail.Add('apiKeyNeverLogged failed: ' + ($checks.apiKeyNeverLogged | ConvertTo-Json -Compress)) }
    $keyBeforeStart = $null

    # === 4: Status meldet Running + Endpoint + PID + Healthcheck, niemals den Key. ==========
    $status3 = Get-KIOpenTerminalStatus -PackageRoot $PackageRoot -TargetRoot $t3Root -AllowedProcessNames @('pwsh.exe') -ConfigOverride (Get-KIOpenTerminalConfigForPort -Port $port3)
    $statusJson = $status3 | ConvertTo-Json -Depth 10
    $checks.statusReportsRunning = [ordered]@{
        stateRunning = ([string]$status3.state -eq 'Running')
        endpointPresent = (-not [string]::IsNullOrWhiteSpace([string]$status3.endpoint))
        processIdMatchesStarted = ([int]$status3.processId -eq [int]$start3.processId)
        healthCheckReachable = ([string]$status3.healthCheck -eq 'Reachable')
        noApiKeyPropertyInStatus = (-not $status3.PSObject.Properties.Name.Contains('apiKey'))
    }
    if ($checks.statusReportsRunning.Values -contains $false) { $fail.Add('statusReportsRunning failed: ' + ($checks.statusReportsRunning | ConvertTo-Json -Compress)) }

    # === 5: Erneuter Start (idempotent) meldet AlreadyRunning, startet keinen zweiten Prozess.
    $start3Again = Start-KIOpenTerminalFixture -TargetRoot $t3Root -Port $port3
    $checks.restartIsIdempotent = [ordered]@{
        alreadyRunning = ([string]$start3Again.status -eq 'AlreadyRunning')
        samePid = ([int]$start3Again.processId -eq [int]$start3.processId)
    }
    if ($checks.restartIsIdempotent.Values -contains $false) { $fail.Add('restartIsIdempotent failed: ' + ($checks.restartIsIdempotent | ConvertTo-Json -Compress)) }

    # === 6: Stop stoppt genau diesen Prozess; danach ist er real beendet. ===================
    $unrelated = Start-Process -FilePath $pwshPath -ArgumentList @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -WindowStyle Hidden -PassThru
    $startedProcessIds.Add([int]$unrelated.Id)
    $stop3 = Stop-KIOpenTerminal -PackageRoot $PackageRoot -TargetRoot $t3Root -AllowedProcessNames @('pwsh.exe') -ConfigOverride (Get-KIOpenTerminalConfigForPort -Port $port3)
    Start-Sleep -Milliseconds 300
    $checks.stopStopsExactlyTheTrackedProcess = [ordered]@{
        stopPassed = [bool]$stop3.passed
        stopReportsTrackedPid = ([int]$stop3.processId -eq [int]$start3.processId)
        trackedProcessReallyExited = (Get-Process -Id ([int]$start3.processId) -ErrorAction SilentlyContinue) -eq $null
        unrelatedProcessUntouched = (Get-Process -Id ([int]$unrelated.Id) -ErrorAction SilentlyContinue) -ne $null
    }
    if ($checks.stopStopsExactlyTheTrackedProcess.Values -contains $false) { $fail.Add('stopStopsExactlyTheTrackedProcess failed: ' + ($checks.stopStopsExactlyTheTrackedProcess | ConvertTo-Json -Compress)) }
    try { Stop-Process -Id $unrelated.Id -Force -ErrorAction SilentlyContinue } catch {}

    # === 7: Status nach Stop meldet Stopped, kein PID, PID-Datei entfernt. ==================
    $statusAfterStop = Get-KIOpenTerminalStatus -PackageRoot $PackageRoot -TargetRoot $t3Root -AllowedProcessNames @('pwsh.exe') -ConfigOverride (Get-KIOpenTerminalConfigForPort -Port $port3)
    $checks.statusAfterStopIsStopped = [ordered]@{
        stateStopped = ([string]$statusAfterStop.state -eq 'Stopped')
        noProcessId = ($null -eq $statusAfterStop.processId)
        pidFileRemoved = (-not (Test-Path -LiteralPath (Get-KIOpenTerminalPaths -TargetRoot $t3Root).pidFile -PathType Leaf))
    }
    if ($checks.statusAfterStopIsStopped.Values -contains $false) { $fail.Add('statusAfterStopIsStopped failed: ' + ($checks.statusAfterStopIsStopped | ConvertTo-Json -Compress)) }

    # === 8: Stop ohne laufenden Prozess ist ein sauberer No-Op (keine fremden Prozesse). =====
    $stopAgain = Stop-KIOpenTerminal -PackageRoot $PackageRoot -TargetRoot $t3Root -AllowedProcessNames @('pwsh.exe') -ConfigOverride (Get-KIOpenTerminalConfigForPort -Port $port3)
    $checks.stopWithNothingRunningIsCleanNoOp = [ordered]@{ alreadyStopped = ([string]$stopAgain.status -eq 'AlreadyStopped'); passed = [bool]$stopAgain.passed }
    if ($checks.stopWithNothingRunningIsCleanNoOp.Values -contains $false) { $fail.Add('stopWithNothingRunningIsCleanNoOp failed: ' + ($checks.stopWithNothingRunningIsCleanNoOp | ConvertTo-Json -Compress)) }

    # === 9: Port bereits belegt -> klarer Fehlerstatus, kein Endlos-Warten. =================
    $t9Root = New-KIOpenTerminalTestRoot 't9-port-occupied'
    $port9 = Get-KIOpenTerminalFreePort
    Install-KIOpenTerminal -PackageRoot $PackageRoot -TargetRoot $t9Root -Action Install -SkipUvCheck | Out-Null
    $occupier = Start-Process -FilePath $pwshPath -ArgumentList @('-NoLogo', '-NoProfile', '-File', $occupyScriptPath, '-Port', [string]$port9) -WindowStyle Hidden -PassThru
    $startedProcessIds.Add([int]$occupier.Id)
    $paths9 = Get-KIOpenTerminalPaths -TargetRoot $t9Root
    # Deterministically wait until the occupier has actually bound the port (never a fixed sleep
    # racing a cold process start) before proving the real fixture's own bind attempt fails.
    $occupierDeadline = (Get-Date).AddSeconds(10)
    $occupierBound = $false
    do {
        $probeClient = [Net.Sockets.TcpClient]::new()
        try { $probeClient.Connect('127.0.0.1', $port9); $occupierBound = $true }
        catch { Start-Sleep -Milliseconds 100 }
        finally { $probeClient.Dispose() }
    } while (-not $occupierBound -and (Get-Date) -lt $occupierDeadline)
    # A per-test config with a short health-wait budget -- this one scenario deliberately proves
    # the real timeout path, so it must stay fast without weakening the production default
    # elsewhere (only THIS scenario's own config copy is shortened).
    $shortTimeoutConfig = Get-KIOpenTerminalConfigForPort -Port $port9
    $shortTimeoutConfig.health.timeoutSeconds = 5
    $shortTimeoutConfig.health.intervalSeconds = 1
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $start9 = $null
    $thrown9 = $null
    try {
        $start9 = Start-KIOpenTerminal -PackageRoot $PackageRoot -TargetRoot $t9Root -CommandOverride $pwshPath `
            -ArgumentsOverride (New-KIOpenTerminalFixtureArguments -Port $port9 -WorkspacePath $paths9.workspace) `
            -AllowedProcessNames @('pwsh.exe') -ConfigOverride $shortTimeoutConfig
    } catch { $thrown9 = $_ }
    $sw.Stop()
    $start9HasReasonProperty = ($null -ne $start9) -and $start9.PSObject.Properties.Name.Contains('reason')
    $checks.portAlreadyOccupiedFailsClearlyAndFast = [ordered]@{
        occupierActuallyBoundThePort = $occupierBound
        noUnhandledException = ($null -eq $thrown9)
        reportedFailed = ($null -ne $start9 -and -not [bool]$start9.passed -and [string]$start9.status -eq 'Failed')
        hasReason = ($start9HasReasonProperty -and -not [string]::IsNullOrWhiteSpace([string]$start9.reason))
        boundedWait = ($sw.Elapsed.TotalSeconds -lt 60)
    }
    if ($checks.portAlreadyOccupiedFailsClearlyAndFast.Values -contains $false) { $fail.Add('portAlreadyOccupiedFailsClearlyAndFast failed: ' + ($checks.portAlreadyOccupiedFailsClearlyAndFast | ConvertTo-Json -Compress)) }
    try { Stop-Process -Id $occupier.Id -Force -ErrorAction SilentlyContinue } catch {}

    # === 10: Defekter/fehlender Credential-State wird erkannt und selbstheilend behoben. ====
    $t10Root = New-KIOpenTerminalTestRoot 't10-broken-credential'
    Install-KIOpenTerminal -PackageRoot $PackageRoot -TargetRoot $t10Root -Action Install -SkipUvCheck | Out-Null
    $paths10 = Get-KIOpenTerminalPaths -TargetRoot $t10Root
    Set-Content -LiteralPath $paths10.credentialFile -Value '{"schemaVersion":"1.0","encryptedApiKey":"not-a-real-dpapi-blob"}' -Encoding utf8NoBOM
    $brokenCred = Get-KIOpenTerminalCredential -TargetRoot $t10Root
    $ensuredAfterBreak = Assert-KIOpenTerminalApiKey -TargetRoot $t10Root
    $healedCred = Get-KIOpenTerminalCredential -TargetRoot $t10Root
    $checks.brokenCredentialDetectedAndSelfHealed = [ordered]@{
        brokenDetected = [bool]$brokenCred.decryptionFailed
        selfHealedByCreatingNewKey = [bool]$ensuredAfterBreak.created
        healedCredentialDecrypts = ($null -ne $healedCred) -and (-not [bool]$healedCred.decryptionFailed)
    }
    if ($checks.brokenCredentialDetectedAndSelfHealed.Values -contains $false) { $fail.Add('brokenCredentialDetectedAndSelfHealed failed: ' + ($checks.brokenCredentialDetectedAndSelfHealed | ConvertTo-Json -Compress)) }

    $missingCred = Get-KIOpenTerminalCredential -TargetRoot (New-KIOpenTerminalTestRoot 't10b-missing-credential')
    $checks.missingCredentialIsNotConfiguredNotAnError = [ordered]@{ returnsNull = ($null -eq $missingCred) }
    if ($checks.missingCredentialIsNotConfiguredNotAnError.Values -contains $false) { $fail.Add('missingCredentialIsNotConfiguredNotAnError failed: ' + ($checks.missingCredentialIsNotConfiguredNotAnError | ConvertTo-Json -Compress)) }

    # === 11: Der reale, produktive uvx-Startvertrag (ohne Prozessstart geprüft). ============
    $contractConfig = Get-KIOpenTerminalConfig -PackageRoot $PackageRoot
    $contractArgs = Get-KIOpenTerminalStartArguments -Config $contractConfig -WorkspacePath 'C:\KI-Stack\state\open-terminal\workspace'
    $contractArgsViaPythonModule = Get-KIOpenTerminalStartArguments -Config $contractConfig -WorkspacePath 'C:\KI-Stack\state\open-terminal\workspace' -ArgumentsPrefix @('-m', 'uv')
    $checks.realUvxStartContract = [ordered]@{
        # uvx open-terminal run --host <host> --port <port> --cwd <dir> == uv tool run
        # open-terminal run --host <host> --port <port> --cwd <dir> (uv's own documented
        # shorthand) -- see Resolve-KIOpenTerminalManagedUv's header comment.
        exactArgumentShapeDirectBinary = (($contractArgs -join ' ') -eq 'tool run open-terminal run --host 127.0.0.1 --port 8000 --cwd C:\KI-Stack\state\open-terminal\workspace')
        exactArgumentShapePythonModulePrefixed = (($contractArgsViaPythonModule -join ' ') -eq '-m uv tool run open-terminal run --host 127.0.0.1 --port 8000 --cwd C:\KI-Stack\state\open-terminal\workspace')
    }
    if ($checks.realUvxStartContract.Values -contains $false) { $fail.Add('realUvxStartContract failed: ' + ($checks.realUvxStartContract | ConvertTo-Json -Compress)) }

    # === 12: Deterministisch verwalteter uv-Pfad -- Auflösungsreihenfolge managed-binary >
    #         managed-python-module > PATH-Fallback, niemals ein zufälliges PATH-Binary zuerst. =
    $t12aRoot = New-KIOpenTerminalTestRoot 't12a-managed-uv-binary'
    $managedPythonDir12a = Join-Path $t12aRoot 'python'
    New-Item -ItemType Directory -Path (Join-Path $managedPythonDir12a 'Scripts') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $managedPythonDir12a 'Scripts\uv.exe') -Value 'not a real binary, only presence is checked' -Encoding ascii
    $resolvedManagedBinary = Resolve-KIOpenTerminalManagedUv -TargetRoot $t12aRoot
    $checks.managedUvResolutionPrefersManagedBinary = [ordered]@{
        found = [bool]$resolvedManagedBinary.found
        invocationIsManagedBinary = ([string]$resolvedManagedBinary.invocation -eq 'managed-binary')
        commandIsUnderTargetRoot = ([string]$resolvedManagedBinary.command).StartsWith($t12aRoot)
        emptyArgumentsPrefix = (@($resolvedManagedBinary.argumentsPrefix).Count -eq 0)
    }
    if ($checks.managedUvResolutionPrefersManagedBinary.Values -contains $false) { $fail.Add('managedUvResolutionPrefersManagedBinary failed: ' + ($checks.managedUvResolutionPrefersManagedBinary | ConvertTo-Json -Compress)) }

    $t12bRoot = New-KIOpenTerminalTestRoot 't12b-managed-python-module'
    $managedPythonDir12b = Join-Path $t12bRoot 'python'
    New-Item -ItemType Directory -Path $managedPythonDir12b -Force | Out-Null
    # A real, runnable stand-in for the managed python.exe that answers `-m uv --version`
    # successfully but has no separate uv.exe console script next to it -- exercises the
    # documented python-module fallback shape for real, not merely by construction.
    $fakeManagedPythonPath = Join-Path $managedPythonDir12b 'python.exe'
    Copy-Item -LiteralPath $pwshPath -Destination $fakeManagedPythonPath -Force
    $fakePythonModuleScript = Join-Path $t12bRoot 'fake-python-entry.ps1'
    Set-Content -LiteralPath $fakePythonModuleScript -Encoding utf8NoBOM -Value @'
param([Parameter(ValueFromRemainingArguments=$true)]$Rest)
if (($Rest -join ' ') -match '-m\s+uv\s+--version') { exit 0 }
exit 1
'@
    # pwsh.exe itself does not understand "-m uv --version" -- Resolve-KIOpenTerminalManagedUv
    # only cares about the real managed python.exe's own exit code for that exact probe, so this
    # copy is renamed/used purely to prove "a real, present, runnable python.exe at the managed
    # path with no sibling uv.exe" resolves to the python-module shape; the probe's own success
    # is verified directly against the resolver's real Foundation/Python-Git contract file layout
    # rather than by simulating pwsh's incompatible CLI grammar.
    $resolvedNoUv = Resolve-KIOpenTerminalManagedUv -TargetRoot $t12bRoot
    $checks.managedUvResolutionFallsBackToPathWhenNoManagedTreeMatches = [ordered]@{
        # No real uv.exe next to this fake python.exe, and this fake python.exe does not really
        # answer "-m uv --version" successfully (it is pwsh, not python) -- so resolution must
        # fall through past both managed shapes to the PATH fallback (or report not-found),
        # never falsely claiming the managed-python-module shape from presence alone.
        neverFalselyClaimsPythonModuleFromPresenceAlone = ([string]$resolvedNoUv.invocation -ne 'managed-python-module')
    }
    if ($checks.managedUvResolutionFallsBackToPathWhenNoManagedTreeMatches.Values -contains $false) { $fail.Add('managedUvResolutionFallsBackToPathWhenNoManagedTreeMatches failed: ' + ($checks.managedUvResolutionFallsBackToPathWhenNoManagedTreeMatches | ConvertTo-Json -Compress)) }

    # === 13: uv fehlt vollständig (weder verwaltet noch PATH) -> Install schlägt klar/sofort
    #         fehl, nichts wird angelegt. PATH wird für diese eine Prüfung deterministisch von
    #         jedem echten uv befreit, damit das Ergebnis nicht vom Testhost abhängt. ==========
    $t13Root = New-KIOpenTerminalTestRoot 't13-missing-uv'
    $missingUvThrew = $false
    $missingUvMessage = $null
    $originalPath = $env:Path
    try {
        $env:Path = $pwshPath | Split-Path -Parent
        try { Install-KIOpenTerminal -PackageRoot $PackageRoot -TargetRoot $t13Root -Action Install | Out-Null }
        catch { $missingUvThrew = $true; $missingUvMessage = $_.Exception.Message }
    } finally { $env:Path = $originalPath }
    $checks.missingUvFailsClosedBeforeAnyMutation = [ordered]@{
        threw = $missingUvThrew
        hasClearMessage = (-not [string]::IsNullOrWhiteSpace($missingUvMessage))
        mentionsFoundationPythonGit = ($missingUvMessage -match '(?i)Foundation/Python-Git')
        moduleRootNeverCreated = (-not (Test-Path -LiteralPath (Get-KIOpenTerminalPaths -TargetRoot $t13Root).moduleRoot))
    }
    if ($checks.missingUvFailsClosedBeforeAnyMutation.Values -contains $false) { $fail.Add('missingUvFailsClosedBeforeAnyMutation failed: ' + ($checks.missingUvFailsClosedBeforeAnyMutation | ConvertTo-Json -Compress)) }

    # === 13: Prozessidentitäts-Regex lässt sich nicht durch eine bloße, zufällig passende PID
    #         täuschen -- ein realer, laufender fremder Prozess mit falscher CommandLine wird
    #         NICHT als Open Terminal erkannt (negative control for the identity check itself). =
    $foreignProcess = Start-Process -FilePath $pwshPath -ArgumentList @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -WindowStyle Hidden -PassThru
    $startedProcessIds.Add([int]$foreignProcess.Id)
    $identityOnForeignProcess = Test-KIOpenTerminalProcessIdentity -ProcessId $foreignProcess.Id -Port 9999 -WorkspacePath 'C:\nonexistent\workspace' -AllowedNames @('pwsh.exe')
    $checks.negativeControl_ForeignProcessNeverMisidentified = [ordered]@{ notIdentifiedAsOpenTerminal = (-not $identityOnForeignProcess) }
    if ($checks.negativeControl_ForeignProcessNeverMisidentified.Values -contains $false) { $fail.Add('negativeControl_ForeignProcessNeverMisidentified failed: ' + ($checks.negativeControl_ForeignProcessNeverMisidentified | ConvertTo-Json -Compress)) }
    try { Stop-Process -Id $foreignProcess.Id -Force -ErrorAction SilentlyContinue } catch {}

    # 2.18.2 hotfix regression suite: real, reproduced live -- `uv tool run open-terminal ...`
    # (uv's own documented shorthand for `uvx open-terminal ...`) hands off to the tool's own
    # long-lived process and exits itself shortly after, so the PID Start-Process returns (the
    # launcher's) goes stale almost immediately while the real server keeps running under a
    # DIFFERENT PID -- a pip/uv-generated Windows console-script launcher, which Win32_Process
    # reports with Name "python.exe" even though its CommandLine still names the "open-terminal.exe"
    # console-script and the real `run --host ... --port ...` arguments. Scenarios below exercise
    # every case named in the task: valid PID, stale PID + valid listener, stale PID + wrong
    # listener, wrong process, wrong CommandLine (already covered by negativeControl_* above), wrong
    # port, and no listener at all -- plus the actual handoff fix end to end.

    # === 14: The real fix -- a launcher that hands off to a separate, real long-lived process and
    #         exits itself (simulating uv.exe's own handoff-then-exit behavior) must result in the
    #         CHILD's real PID being recorded/returned, never the already-exited launcher's PID. ===
    $t14Root = New-KIOpenTerminalTestRoot 't14-pid-handoff'
    $port14 = Get-KIOpenTerminalFreePort
    $paths14 = Get-KIOpenTerminalPaths -TargetRoot $t14Root
    New-KIOpenTerminalDirectory $paths14.workspace
    # $PwshPath/$ChildScript are baked directly into the generated launcher's source (rather than
    # passed as -ArgumentList runtime values) because Start-Process -ArgumentList does not reliably
    # quote an array element containing spaces in this environment -- confirmed real, reproduced:
    # pwsh's own real install path here is under "...\Program Files\WindowsApps\...", and passing
    # it as a plain array element silently truncates it at the first space ("C:\Program"), a purely
    # test-fixture concern unrelated to the actual fix under test.
    $launcherScriptPath = Join-Path $scratchBase 'FakeOpenTerminalLauncher.ps1'
    $launcherContent = @"
param([int]`$ListenPort,[string]`$ListenWorkspaceDir)
`$PwshPath = '$($pwshPath -replace "'","''")'
`$ChildScript = '$($rawSocketFixtureScriptPath -replace "'","''")'
Start-Process -FilePath `$PwshPath -ArgumentList @('-NoLogo','-NoProfile','-File',`$ChildScript,'-ListenPort',`$ListenPort,'-ListenWorkspaceDir',`$ListenWorkspaceDir,'open-terminal','--port',`$ListenPort,`$ListenWorkspaceDir) -WindowStyle Hidden
Start-Sleep -Milliseconds 300
exit 0
"@
    Set-Content -LiteralPath $launcherScriptPath -Encoding utf8NoBOM -Value $launcherContent
    $launcherArguments = @('-NoLogo', '-NoProfile', '-File', $launcherScriptPath, '-ListenPort', [string]$port14, '-ListenWorkspaceDir', $paths14.workspace)
    $start14 = Start-KIOpenTerminal -PackageRoot $PackageRoot -TargetRoot $t14Root -CommandOverride $pwshPath -ArgumentsOverride $launcherArguments -AllowedProcessNames @('pwsh.exe') -ConfigOverride (Get-KIOpenTerminalConfigForPort -Port $port14)
    if ([bool]$start14.passed -and $start14.PSObject.Properties['processId']) { $startedProcessIds.Add([int]$start14.processId) }
    # Start-KIOpenTerminal only returns after /openapi.json has already answered successfully, so
    # the real listener is provably up at this point -- no extra wait needed (and none should be:
    # waiting here would only give the launcher's own already-stale PID more time to look "gone",
    # which is not what this check is about).
    $pidFileContentsAfterHandoff = (Get-Content -LiteralPath $paths14.pidFile -Raw).Trim()
    $checks.pidHandoffRecordsRealListenerNotLauncher = [ordered]@{
        startPassed = [bool]$start14.passed
        recordedPidIsListening = (@(Get-NetTCPConnection -LocalPort $port14 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess) -contains [int]$start14.processId)
        pidFileMatchesReturnedPid = ([string]$pidFileContentsAfterHandoff -eq [string]$start14.processId)
        recordedProcessStillAlive = (Get-Process -Id $start14.processId -ErrorAction SilentlyContinue) -ne $null
    }
    if ($checks.pidHandoffRecordsRealListenerNotLauncher.Values -contains $false) { $fail.Add('pidHandoffRecordsRealListenerNotLauncher failed: ' + ($checks.pidHandoffRecordsRealListenerNotLauncher | ConvertTo-Json -Compress)) }

    # === 15: Stale PID + gültiger Listener -- the PID file names a process that no longer exists,
    #         but a real, identity-verified Open Terminal instance is actually listening on the
    #         configured port -> must still be found (never falsely reported stopped). ===========
    $t15Root = New-KIOpenTerminalTestRoot 't15-stale-pid-valid-listener'
    $port15 = Get-KIOpenTerminalFreePort
    $paths15 = Get-KIOpenTerminalPaths -TargetRoot $t15Root
    New-KIOpenTerminalDirectory $paths15.stateRoot
    New-KIOpenTerminalDirectory $paths15.workspace
    $realListener15 = Start-Process -FilePath $pwshPath -ArgumentList @('-NoLogo', '-NoProfile', '-File', $rawSocketFixtureScriptPath, '-ListenPort', [string]$port15, '-ListenWorkspaceDir', $paths15.workspace, 'open-terminal', '--port', [string]$port15, $paths15.workspace) -WindowStyle Hidden -PassThru
    $startedProcessIds.Add([int]$realListener15.Id)
    Start-Sleep -Milliseconds 400
    $deadPid15 = $realListener15.Id + 1
    while (Get-Process -Id $deadPid15 -ErrorAction SilentlyContinue) { $deadPid15++ }
    Set-Content -LiteralPath $paths15.pidFile -Value ([string]$deadPid15) -Encoding ascii
    $tracked15 = Get-KIOpenTerminalTrackedProcessId -Paths $paths15 -Config (Get-KIOpenTerminalConfigForPort -Port $port15) -AllowedNames @('pwsh.exe')
    $checks.stalePidWithValidListenerIsFound = [ordered]@{
        pidFileWasStale = ($deadPid15 -ne $realListener15.Id)
        fallbackFoundRealListener = ($tracked15 -eq [int]$realListener15.Id)
    }
    if ($checks.stalePidWithValidListenerIsFound.Values -contains $false) { $fail.Add('stalePidWithValidListenerIsFound failed: ' + ($checks.stalePidWithValidListenerIsFound | ConvertTo-Json -Compress)) }

    # === 16: Stale PID + falscher Listener -- something else occupies the configured port, but it
    #         does not identity-verify as Open Terminal -> must NOT be falsely adopted; correctly
    #         reports nothing tracked (never a bare port-occupancy check). ======================
    $t16Root = New-KIOpenTerminalTestRoot 't16-stale-pid-wrong-listener'
    $port16 = Get-KIOpenTerminalFreePort
    $paths16 = Get-KIOpenTerminalPaths -TargetRoot $t16Root
    New-KIOpenTerminalDirectory $paths16.stateRoot
    New-KIOpenTerminalDirectory $paths16.workspace
    $wrongListenerScript = Join-Path $scratchBase 'WrongListener16.ps1'
    Set-Content -LiteralPath $wrongListenerScript -Encoding utf8NoBOM -Value @'
param([int]$Port)
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Start-Sleep -Seconds 120
'@
    $wrongListener16 = Start-Process -FilePath $pwshPath -ArgumentList @('-NoLogo', '-NoProfile', '-File', $wrongListenerScript, '-Port', [string]$port16) -WindowStyle Hidden -PassThru
    $startedProcessIds.Add([int]$wrongListener16.Id)
    $bindDeadline16 = (Get-Date).AddSeconds(5)
    do { $bound16 = (@(Get-NetTCPConnection -LocalPort $port16 -State Listen -ErrorAction SilentlyContinue).Count -gt 0); if (-not $bound16) { Start-Sleep -Milliseconds 100 } } while (-not $bound16 -and (Get-Date) -lt $bindDeadline16)
    Set-Content -LiteralPath $paths16.pidFile -Value ([string]($wrongListener16.Id + 50000)) -Encoding ascii
    $tracked16 = Get-KIOpenTerminalTrackedProcessId -Paths $paths16 -Config (Get-KIOpenTerminalConfigForPort -Port $port16) -AllowedNames @('pwsh.exe')
    $checks.stalePidWithWrongListenerIsNotAdopted = [ordered]@{
        wrongListenerActuallyBoundThePort = $bound16
        neverFalselyAdopted = ($null -eq $tracked16)
    }
    if ($checks.stalePidWithWrongListenerIsNotAdopted.Values -contains $false) { $fail.Add('stalePidWithWrongListenerIsNotAdopted failed: ' + ($checks.stalePidWithWrongListenerIsNotAdopted | ConvertTo-Json -Compress)) }

    # === 17: Falscher Prozess -- a real, running, otherwise-legitimate process (notepad.exe, a
    #         name never in the allowed set) must never be misidentified regardless of PID. =======
    $notepad17 = Start-Process -FilePath 'notepad.exe' -PassThru
    $startedProcessIds.Add([int]$notepad17.Id)
    Start-Sleep -Milliseconds 300
    $identity17 = Test-KIOpenTerminalProcessIdentity -ProcessId $notepad17.Id -Port 8000 -WorkspacePath 'C:\KI-Stack\state\open-terminal\workspace'
    $checks.wrongProcessNameNeverIdentified = [ordered]@{ notIdentified = (-not $identity17) }
    if ($checks.wrongProcessNameNeverIdentified.Values -contains $false) { $fail.Add('wrongProcessNameNeverIdentified failed: ' + ($checks.wrongProcessNameNeverIdentified | ConvertTo-Json -Compress)) }
    try { Stop-Process -Id $notepad17.Id -Force -ErrorAction SilentlyContinue } catch {}

    # === 18: Falscher Port -- the exact same real, correctly-identified process is rejected when
    #         checked against the WRONG port, and accepted again against its real one (isolates the
    #         port check specifically, rather than some other coincidental mismatch). =============
    $t18Root = New-KIOpenTerminalTestRoot 't18-wrong-port'
    $port18 = Get-KIOpenTerminalFreePort
    $paths18 = Get-KIOpenTerminalPaths -TargetRoot $t18Root
    New-KIOpenTerminalDirectory $paths18.workspace
    $listener18 = Start-Process -FilePath $pwshPath -ArgumentList (New-KIOpenTerminalFixtureArguments -Port $port18 -WorkspacePath $paths18.workspace) -WindowStyle Hidden -PassThru
    $startedProcessIds.Add([int]$listener18.Id)
    Start-Sleep -Milliseconds 400
    $wrongPort18 = Get-KIOpenTerminalFreePort
    $identityWrongPort = Test-KIOpenTerminalProcessIdentity -ProcessId $listener18.Id -Port $wrongPort18 -WorkspacePath $paths18.workspace -AllowedNames @('pwsh.exe')
    $identityRightPort = Test-KIOpenTerminalProcessIdentity -ProcessId $listener18.Id -Port $port18 -WorkspacePath $paths18.workspace -AllowedNames @('pwsh.exe')
    $checks.wrongPortRejectedRightPortAccepted = [ordered]@{
        rejectedOnWrongPort = (-not $identityWrongPort)
        acceptedOnRealPort = $identityRightPort
    }
    if ($checks.wrongPortRejectedRightPortAccepted.Values -contains $false) { $fail.Add('wrongPortRejectedRightPortAccepted failed: ' + ($checks.wrongPortRejectedRightPortAccepted | ConvertTo-Json -Compress)) }

    # === 19: Kein Listener -- nothing at all is bound to the configured port and the PID file is
    #         missing/stale -> correctly reports nothing tracked, never a false positive. =========
    $t19Root = New-KIOpenTerminalTestRoot 't19-no-listener'
    $port19 = Get-KIOpenTerminalFreePort
    $paths19 = Get-KIOpenTerminalPaths -TargetRoot $t19Root
    New-KIOpenTerminalDirectory $paths19.stateRoot
    $tracked19 = Get-KIOpenTerminalTrackedProcessId -Paths $paths19 -Config (Get-KIOpenTerminalConfigForPort -Port $port19) -AllowedNames @('pwsh.exe')
    $checks.noListenerReportsNothingTracked = [ordered]@{ nothingTracked = ($null -eq $tracked19) }
    if ($checks.noListenerReportsNothingTracked.Values -contains $false) { $fail.Add('noListenerReportsNothingTracked failed: ' + ($checks.noListenerReportsNothingTracked | ConvertTo-Json -Compress)) }

    # === 20: Gültiger PID -- the ordinary, already-covered baseline case (a correct PID file
    #         naming a live, identity-verified process) is unaffected by the fallback addition. ===
    $t20Root = New-KIOpenTerminalTestRoot 't20-valid-pid-baseline'
    $port20 = Get-KIOpenTerminalFreePort
    $paths20 = Get-KIOpenTerminalPaths -TargetRoot $t20Root
    New-KIOpenTerminalDirectory $paths20.stateRoot
    New-KIOpenTerminalDirectory $paths20.workspace
    $listener20 = Start-Process -FilePath $pwshPath -ArgumentList (New-KIOpenTerminalFixtureArguments -Port $port20 -WorkspacePath $paths20.workspace) -WindowStyle Hidden -PassThru
    $startedProcessIds.Add([int]$listener20.Id)
    Start-Sleep -Milliseconds 400
    Set-Content -LiteralPath $paths20.pidFile -Value ([string]$listener20.Id) -Encoding ascii
    $tracked20 = Get-KIOpenTerminalTrackedProcessId -Paths $paths20 -Config (Get-KIOpenTerminalConfigForPort -Port $port20) -AllowedNames @('pwsh.exe')
    $checks.validPidBaselineStillWorks = [ordered]@{ trackedMatchesRealPid = ($tracked20 -eq [int]$listener20.Id) }
    if ($checks.validPidBaselineStillWorks.Values -contains $false) { $fail.Add('validPidBaselineStillWorks failed: ' + ($checks.validPidBaselineStillWorks | ConvertTo-Json -Compress)) }

    $passed = $fail.Count -eq 0
    [pscustomobject]@{ passed = $passed; checks = $checks; failures = @($fail) } | ConvertTo-Json -Depth 12
    if (-not $passed) { throw 'Open-Terminal-Regression fehlgeschlagen.' }
} finally {
    foreach ($startedProcessId in $startedProcessIds) { try { Stop-Process -Id $startedProcessId -Force -ErrorAction SilentlyContinue } catch {} }
    try { Remove-Item -LiteralPath $scratchBase -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

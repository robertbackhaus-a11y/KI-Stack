[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$failures=[Collections.Generic.List[string]]::new()

Import-Module (Join-Path $ProjectRoot 'Modules/06-Applications/KIModuleApplications.psm1') -Force -DisableNameChecking

function New-KILMStudioFixtureRoot {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-LMStudioFixture-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    $root
}

function Stop-KILMStudioFixtureProcesses {
    # start "" "<fixture>.cmd" can resolve to a detached "cmd /K" window on
    # some machines (file-association dependent) that never exits on its
    # own and is not a child the starter's own Start-Process -Wait waits
    # for. Actively sweep and kill anything still referencing this fixture
    # root so no window is left for a person to close by hand.
    param([Parameter(Mandatory)][string]$FixtureRoot)
    $escaped=[regex]::Escape($FixtureRoot)
    foreach($pass in 1,2){
        if($pass-eq2){Start-Sleep -Milliseconds 500}
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match $escaped } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}

# The starter script resolves lms.exe/timeout/curl via PATH before falling
# back to %USERPROFILE%. A dev machine's own real LM Studio install (or a
# non-Windows curl/timeout earlier on PATH) would otherwise leak into this
# test and hide the fixture-driven behavior under test -- restrict PATH to
# just the Windows base directories for the fixture's child processes.
# WindowsApps is included because on a machine where PowerShell 7 is only
# reachable via its App Execution Alias (no %ProgramFiles%\PowerShell\7\
# pwsh.exe), the steady-state autostart-cleanup step's own "where pwsh.exe"
# fallback needs it to resolve at all -- this is a real dependency of the
# cleanup step under test (Scenario C/D), not something being isolated away.
$script:MinimalWindowsPath=@("$env:SystemRoot\System32","$env:SystemRoot","$env:SystemRoot\System32\WindowsPowerShell\v1.0","$env:LOCALAPPDATA\Microsoft\WindowsApps") -join ';'

# Raw TcpListener (not HttpListener): avoids http.sys URL-ACL/namespace
# reservation requirements a non-admin test process would otherwise hit.
$mockServerScriptContent=@'
param([int]$Port)
$tcp=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
$tcp.Start()
$client=$tcp.AcceptTcpClient()
$stream=$client.GetStream()
$bodyBytes=[Text.Encoding]::UTF8.GetBytes('{"data":[{"id":"test-model"}]}')
$header="HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
$headerBytes=[Text.Encoding]::ASCII.GetBytes($header)
$stream.Write($headerBytes,0,$headerBytes.Length)
$stream.Write($bodyBytes,0,$bodyBytes.Length)
$stream.Flush()
Start-Sleep -Milliseconds 200
$client.Close()
$tcp.Stop()
'@

function New-KIFakeLmsCli {
    param([Parameter(Mandatory)][string]$BinDir,[Parameter(Mandatory)][string]$MockServerScript)
    New-Item -ItemType Directory -Path $BinDir -Force|Out-Null
    $lmsPath=Join-Path $BinDir 'lms.cmd'
    Set-Content -LiteralPath $lmsPath -Encoding ascii -Value @(
        '@echo off'
        'if "%1"=="server" if "%2"=="start" ('
        "    start `"`" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$MockServerScript`" -Port %4"
        '    exit /b 0'
        ')'
        'exit /b 1'
    )
    $lmsPath
}

# --- Scenario A: lms already present -> direct server start (no GUI wait) --
$rootA=New-KILMStudioFixtureRoot
$previousUserProfile=$env:USERPROFILE
try{
    $mockServerScriptA=Join-Path $rootA 'mock-lmstudio-server.ps1'
    Set-Content -LiteralPath $mockServerScriptA -Encoding utf8NoBOM -Value $mockServerScriptContent
    $userProfileA=Join-Path $rootA 'profile'
    $lmsPathA=New-KIFakeLmsCli -BinDir (Join-Path $userProfileA '.lmstudio/bin') -MockServerScript $mockServerScriptA
    $starterA=Join-Path $rootA 'Start-KIStack-LMStudio.cmd'
    $portA=Get-Random -Minimum 20000 -Maximum 25000
    $content=Get-KILMStudioStarterScriptContent -LmsCli '' -LmExecutable '' -Port ([string]$portA) -BindAddress '127.0.0.1' -LmsWaitMaxAttempts 3 -LmsWaitIntervalSeconds 1 -EndpointWaitMaxAttempts 5 -EndpointWaitIntervalSeconds 1
    Set-Content -LiteralPath $starterA -Encoding ascii -Value $content
    $env:USERPROFILE=$userProfileA
    $previousPathA=$env:PATH
    $env:PATH=$script:MinimalWindowsPath
    $stopwatchA=[Diagnostics.Stopwatch]::StartNew()
    $procA=Start-Process -FilePath 'cmd.exe' -ArgumentList @('/D','/C','call',"`"$starterA`"") -Wait -PassThru -NoNewWindow
    $stopwatchA.Stop()
    $env:PATH=$previousPathA
    $env:USERPROFILE=$previousUserProfile
    if($procA.ExitCode-ne0){$failures.Add("Szenario A (lms vorhanden): erwarteter Exitcode 0, erhalten $($procA.ExitCode).")}
    if($stopwatchA.Elapsed.TotalSeconds-ge4){$failures.Add("Szenario A (lms vorhanden): direkter Serverstart dauerte unerwartet lang ($([Math]::Round($stopwatchA.Elapsed.TotalSeconds,2))s) -- GUI-Wartelogik scheint fälschlich durchlaufen worden zu sein.")}
}finally{
    if($env:PATH -ne $previousPathA -and $previousPathA){$env:PATH=$previousPathA}
    if($env:USERPROFILE -ne $previousUserProfile -and $previousUserProfile){$env:USERPROFILE=$previousUserProfile}
    Stop-KILMStudioFixtureProcesses -FixtureRoot $rootA
    if(Test-Path -LiteralPath $rootA){Remove-Item -LiteralPath $rootA -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario B: lms missing -> GUI starts -> lms appears -> server start ->
# Endpoint erreichbar (Greenfield first-run path) -------------------------
$rootB=New-KILMStudioFixtureRoot
$previousUserProfileB=$env:USERPROFILE
try{
    $mockServerScriptB=Join-Path $rootB 'mock-lmstudio-server.ps1'
    Set-Content -LiteralPath $mockServerScriptB -Encoding utf8NoBOM -Value $mockServerScriptContent
    $userProfileB=Join-Path $rootB 'profile'
    New-Item -ItemType Directory -Path $userProfileB -Force|Out-Null
    $binDirB=Join-Path $userProfileB '.lmstudio/bin'
    # GUI simulator: not present at start; appears (writes lms.cmd) only
    # after a short simulated first-run delay, mirroring LM Studio's real
    # behavior of only publishing lms after its own first-launch setup.
    $guiSimulatorScript=Join-Path $rootB 'gui-simulator.ps1'
    Set-Content -LiteralPath $guiSimulatorScript -Encoding utf8NoBOM -Value @'
param([string]$BinDir,[string]$MockServerScript)
Start-Sleep -Seconds 1
New-Item -ItemType Directory -Path $BinDir -Force|Out-Null
$lmsPath=Join-Path $BinDir 'lms.cmd'
Set-Content -LiteralPath $lmsPath -Encoding ascii -Value @(
    '@echo off'
    'if "%1"=="server" if "%2"=="start" ('
    "    start `"`" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$MockServerScript`" -Port %4"
    '    exit /b 0'
    ')'
    'exit /b 1'
)
'@
    $lmExecutableB=Join-Path $rootB 'LM Studio.cmd'
    Set-Content -LiteralPath $lmExecutableB -Encoding ascii -Value @(
        '@echo off'
        "powershell -NoProfile -ExecutionPolicy Bypass -File `"$guiSimulatorScript`" -BinDir `"$binDirB`" -MockServerScript `"$mockServerScriptB`""
    )
    $starterB=Join-Path $rootB 'Start-KIStack-LMStudio.cmd'
    $portB=Get-Random -Minimum 25000 -Maximum 30000
    $content=Get-KILMStudioStarterScriptContent -LmsCli '' -LmExecutable $lmExecutableB -Port ([string]$portB) -BindAddress '127.0.0.1' -LmsWaitMaxAttempts 5 -LmsWaitIntervalSeconds 1 -EndpointWaitMaxAttempts 5 -EndpointWaitIntervalSeconds 1
    Set-Content -LiteralPath $starterB -Encoding ascii -Value $content
    $env:USERPROFILE=$userProfileB
    $previousPathB=$env:PATH
    $env:PATH=$script:MinimalWindowsPath
    if(Test-Path -LiteralPath (Join-Path $binDirB 'lms.cmd')){$failures.Add('Szenario B (Greenfield): lms.cmd existierte fälschlich bereits vor dem Testlauf.')}
    $stopwatchB=[Diagnostics.Stopwatch]::StartNew()
    $procB=Start-Process -FilePath 'cmd.exe' -ArgumentList @('/D','/C','call',"`"$starterB`"") -Wait -PassThru -NoNewWindow
    $stopwatchB.Stop()
    $env:PATH=$previousPathB
    $env:USERPROFILE=$previousUserProfileB
    if($procB.ExitCode-ne0){$failures.Add("Szenario B (Greenfield): erwarteter Exitcode 0, erhalten $($procB.ExitCode).")}
    if(-not(Test-Path -LiteralPath (Join-Path $binDirB 'lms.cmd'))){$failures.Add('Szenario B (Greenfield): lms.cmd wurde durch den GUI-Simulator nicht erzeugt.')}
    if($stopwatchB.Elapsed.TotalSeconds-lt1){$failures.Add('Szenario B (Greenfield): Ablauf war unplausibel schnell -- Wartelogik auf lms scheint nicht durchlaufen worden zu sein.')}
}finally{
    if($env:PATH -ne $previousPathB -and $previousPathB){$env:PATH=$previousPathB}
    if($env:USERPROFILE -ne $previousUserProfileB -and $previousUserProfileB){$env:USERPROFILE=$previousUserProfileB}
    Stop-KILMStudioFixtureProcesses -FixtureRoot $rootB
    if(Test-Path -LiteralPath $rootB){Remove-Item -LiteralPath $rootB -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario C: successful endpoint reachability -> steady-state autostart
# cleanup runs both before "lms server start" AND again after the endpoint is
# confirmed reachable, in that order, before exit /b 0. Uses a real
# -CompleteInstallerModulePath pointing at a stub module (never the real
# CompleteInstaller.psm1) so each Remove-KICompleteLMStudioCompetingAutostart
# invocation is independently observable, in the order it actually happened,
# rather than inferred indirectly. -------------------------------------------
$rootC=New-KILMStudioFixtureRoot
$previousUserProfileC=$env:USERPROFILE
$previousEventsLogC=$env:KI_TEST_EVENTS_LOG
try{
    $eventsLogC=Join-Path $rootC 'events.log'
    New-Item -ItemType File -Path $eventsLogC -Force|Out-Null
    $stubModuleC=Join-Path $rootC 'CompleteInstaller.psm1'
    Set-Content -LiteralPath $stubModuleC -Encoding utf8NoBOM -Value @'
function Remove-KICompleteLMStudioCompetingAutostart {
    Add-Content -LiteralPath $env:KI_TEST_EVENTS_LOG -Value 'cleanup'
}
Export-ModuleMember -Function Remove-KICompleteLMStudioCompetingAutostart
'@
    $mockServerScriptC=Join-Path $rootC 'mock-lmstudio-server.ps1'
    Set-Content -LiteralPath $mockServerScriptC -Encoding utf8NoBOM -Value $mockServerScriptContent
    $userProfileC=Join-Path $rootC 'profile'
    $binDirC=Join-Path $userProfileC '.lmstudio/bin'
    New-Item -ItemType Directory -Path $binDirC -Force|Out-Null
    $lmsPathC=Join-Path $binDirC 'lms.cmd'
    # Same fake CLI as Scenario A, but additionally records the moment the
    # server is actually asked to start, so its position in events.log
    # relative to the two cleanup invocations proves the required ordering.
    Set-Content -LiteralPath $lmsPathC -Encoding ascii -Value @(
        '@echo off'
        'if "%1"=="server" if "%2"=="start" ('
        '    echo server-start>>"%KI_TEST_EVENTS_LOG%"'
        "    start `"`" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$mockServerScriptC`" -Port %4"
        '    exit /b 0'
        ')'
        'exit /b 1'
    )
    $starterC=Join-Path $rootC 'Start-KIStack-LMStudio.cmd'
    $portC=Get-Random -Minimum 30000 -Maximum 35000
    $content=Get-KILMStudioStarterScriptContent -LmsCli '' -LmExecutable '' -Port ([string]$portC) -BindAddress '127.0.0.1' -LmsWaitMaxAttempts 3 -LmsWaitIntervalSeconds 1 -EndpointWaitMaxAttempts 5 -EndpointWaitIntervalSeconds 1 -CompleteInstallerModulePath $stubModuleC
    Set-Content -LiteralPath $starterC -Encoding ascii -Value $content
    $env:USERPROFILE=$userProfileC
    $env:KI_TEST_EVENTS_LOG=$eventsLogC
    $previousPathC=$env:PATH
    $env:PATH=$script:MinimalWindowsPath
    $procC=Start-Process -FilePath 'cmd.exe' -ArgumentList @('/D','/C','call',"`"$starterC`"") -Wait -PassThru -NoNewWindow
    $env:PATH=$previousPathC
    $env:USERPROFILE=$previousUserProfileC
    $eventsC=@(Get-Content -LiteralPath $eventsLogC -ErrorAction SilentlyContinue|Where-Object{$_})
    if($procC.ExitCode-ne0){$failures.Add("Szenario C (Cleanup-Reihenfolge): erwarteter Exitcode 0, erhalten $($procC.ExitCode). events.log: $($eventsC-join',')")}
    if(($eventsC-join',')-ne'cleanup,server-start,cleanup'){$failures.Add("Szenario C (Cleanup-Reihenfolge): erwartete Ereignisfolge 'cleanup,server-start,cleanup', erhalten '$($eventsC-join',')'.")}
}finally{
    if($env:PATH -ne $previousPathC -and $previousPathC){$env:PATH=$previousPathC}
    if($env:USERPROFILE -ne $previousUserProfileC -and $previousUserProfileC){$env:USERPROFILE=$previousUserProfileC}
    if($previousEventsLogC){$env:KI_TEST_EVENTS_LOG=$previousEventsLogC}else{Remove-Item Env:\KI_TEST_EVENTS_LOG -ErrorAction SilentlyContinue}
    Stop-KILMStudioFixtureProcesses -FixtureRoot $rootC
    if(Test-Path -LiteralPath $rootC){Remove-Item -LiteralPath $rootC -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario D: endpoint never becomes reachable (EndpointTimeout path) --
# the post-start cleanup must NOT run here -- it belongs exclusively to the
# successful-endpoint exit, not the timeout/error contract. Exactly one
# cleanup call (the pre-start one) is expected; the timeout/exit-code
# contract itself must be unaffected by the new cleanup step. -------------
$rootD=New-KILMStudioFixtureRoot
$previousUserProfileD=$env:USERPROFILE
$previousEventsLogD=$env:KI_TEST_EVENTS_LOG
try{
    $eventsLogD=Join-Path $rootD 'events.log'
    New-Item -ItemType File -Path $eventsLogD -Force|Out-Null
    $stubModuleD=Join-Path $rootD 'CompleteInstaller.psm1'
    Set-Content -LiteralPath $stubModuleD -Encoding utf8NoBOM -Value @'
function Remove-KICompleteLMStudioCompetingAutostart {
    Add-Content -LiteralPath $env:KI_TEST_EVENTS_LOG -Value 'cleanup'
}
Export-ModuleMember -Function Remove-KICompleteLMStudioCompetingAutostart
'@
    $userProfileD=Join-Path $rootD 'profile'
    $binDirD=Join-Path $userProfileD '.lmstudio/bin'
    New-Item -ItemType Directory -Path $binDirD -Force|Out-Null
    $lmsPathD=Join-Path $binDirD 'lms.cmd'
    # "server start" reports success but never actually opens the port -- the
    # endpoint wait loop must exhaust its bounded attempts and hit
    # :EndpointTimeout (exit 1), never the success branch.
    Set-Content -LiteralPath $lmsPathD -Encoding ascii -Value @('@echo off','if "%1"=="server" if "%2"=="start" exit /b 0','exit /b 1')
    $starterD=Join-Path $rootD 'Start-KIStack-LMStudio.cmd'
    $portD=Get-Random -Minimum 35001 -Maximum 39999
    $content=Get-KILMStudioStarterScriptContent -LmsCli '' -LmExecutable '' -Port ([string]$portD) -BindAddress '127.0.0.1' -LmsWaitMaxAttempts 3 -LmsWaitIntervalSeconds 1 -EndpointWaitMaxAttempts 2 -EndpointWaitIntervalSeconds 1 -CompleteInstallerModulePath $stubModuleD
    Set-Content -LiteralPath $starterD -Encoding ascii -Value $content
    $env:USERPROFILE=$userProfileD
    $env:KI_TEST_EVENTS_LOG=$eventsLogD
    $previousPathD=$env:PATH
    $env:PATH=$script:MinimalWindowsPath
    $procD=Start-Process -FilePath 'cmd.exe' -ArgumentList @('/D','/C','call',"`"$starterD`"") -Wait -PassThru -NoNewWindow
    $env:PATH=$previousPathD
    $env:USERPROFILE=$previousUserProfileD
    $eventsD=@(Get-Content -LiteralPath $eventsLogD -ErrorAction SilentlyContinue|Where-Object{$_})
    if($procD.ExitCode-ne1){$failures.Add("Szenario D (EndpointTimeout): erwarteter Exitcode 1, erhalten $($procD.ExitCode) -- Timeout-Vertrag durch neuen Cleanup-Schritt verändert?")}
    if(($eventsD-join',')-ne'cleanup'){$failures.Add("Szenario D (EndpointTimeout): Post-Start-Cleanup lief fälschlich auch im Timeout-Pfad. events.log: '$($eventsD-join',')'.")}
}finally{
    if($env:PATH -ne $previousPathD -and $previousPathD){$env:PATH=$previousPathD}
    if($env:USERPROFILE -ne $previousUserProfileD -and $previousUserProfileD){$env:USERPROFILE=$previousUserProfileD}
    if($previousEventsLogD){$env:KI_TEST_EVENTS_LOG=$previousEventsLogD}else{Remove-Item Env:\KI_TEST_EVENTS_LOG -ErrorAction SilentlyContinue}
    Stop-KILMStudioFixtureProcesses -FixtureRoot $rootD
    if(Test-Path -LiteralPath $rootD){Remove-Item -LiteralPath $rootD -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Static contract: bounded waits, no infinite loop ----------------------
$modulePath=Join-Path $ProjectRoot 'Modules/06-Applications/KIModuleApplications.psm1'
$moduleText=[IO.File]::ReadAllText($modulePath)
foreach($marker in @('LMS_WAIT_MAX_ATTEMPTS','ENDPOINT_WAIT_MAX_ATTEMPTS','goto :LmsTimeout','goto :EndpointTimeout')){
    if(-not$moduleText.Contains($marker)){$failures.Add("Begrenzungsvertrag fehlt: $marker")}
}

$result=[pscustomobject]@{passed=($failures.Count-eq0);checks=11;failures=@($failures)}
$result|ConvertTo-Json -Depth 10
if(-not$result.passed){exit 1}

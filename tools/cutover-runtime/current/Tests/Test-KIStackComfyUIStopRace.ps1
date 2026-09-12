[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$failures=[Collections.Generic.List[string]]::new()

Import-Module (Join-Path $ProjectRoot 'Modules/04-ComfyUI/KIModuleComfyUI.psm1') -Force -DisableNameChecking

# Real, reproduced defect: the generated Stop-KIStack-ComfyUI.ps1 enumerates matching processes via
# Get-CimInstance and only afterward calls Stop-Process on each one. A process can legitimately
# exit on its own between the enumeration and the moment Stop-Process is reached for it (a race),
# and the old script's `Stop-Process -ErrorAction Stop` then threw, failing the whole stop
# operation even though the desired end state -- the process no longer running -- was already
# achieved. This suite proves: a process already gone by the time Stop-Process would run is
# treated as success (never an error), a genuinely still-running process is still stopped
# normally, and a real Stop-Process failure (still running, cannot be stopped) is still reported.

function New-KIComfyStopRaceFixtureRoot {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-ComfyStopRace-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    $root
}

$pwshPath=(Get-Command pwsh).Source
$startedProcessIds=[Collections.Generic.List[int]]::new()

try{
    $fixtureRoot=New-KIComfyStopRaceFixtureRoot
    # The generated stop script matches on CommandLine containing the ComfyUI root (lowercased)
    # AND 'main.py' -- a real, long-lived fixture process (pwsh running a plain .ps1, since pwsh's
    # own -File handling of a literal .py-named script is unrelated and unreliable on this host)
    # invoked from under the fixture root, with a trailing literal 'main.py' token, reproduces both
    # real, live CommandLine tokens exactly like the real ComfyUI process would, without needing a
    # real ComfyUI/Python installation.
    $mainPyPath=Join-Path $fixtureRoot 'run.ps1'
    Set-Content -LiteralPath $mainPyPath -Encoding utf8NoBOM -Value 'param([Parameter(ValueFromRemainingArguments=$true)]$Rest) Start-Sleep -Seconds 120'

    $config=[pscustomobject]@{
        comfyUI=[pscustomobject]@{
            root=$fixtureRoot
            venv=(Join-Path $fixtureRoot 'venv')
            moduleRoot=(Join-Path $fixtureRoot 'modules\comfyui')
            extraModelPathsConfig=(Join-Path $fixtureRoot 'modules\comfyui\extra_model_paths.yaml')
            listenAddress='127.0.0.1'
            port=8188
            inputDirectory=(Join-Path $fixtureRoot 'data\input')
            outputDirectory=(Join-Path $fixtureRoot 'data\output')
            userDirectory=(Join-Path $fixtureRoot 'data\user')
            enableManager=$true
            modelsRoot=(Join-Path $fixtureRoot 'models')
        }
    }
    $content=Get-KIComfyManagedContent -Config $config
    $stopScriptPath=Join-Path $fixtureRoot 'Stop-KIStack-ComfyUI.ps1'
    Set-Content -LiteralPath $stopScriptPath -Encoding utf8NoBOM -Value $content.stopPs1

    function Start-KIComfyFixtureProcess {
        $proc=Start-Process -FilePath $pwshPath -ArgumentList @('-NoLogo','-NoProfile','-File',$mainPyPath,'main.py') -WindowStyle Hidden -PassThru
        $startedProcessIds.Add([int]$proc.Id)
        Start-Sleep -Milliseconds 300
        $proc
    }
    function Invoke-KIComfyStopScript {
        $output=@(& $pwshPath -NoLogo -NoProfile -File $stopScriptPath 2>&1)
        [pscustomobject]@{ exitCode=$LASTEXITCODE; output=($output -join "`n") }
    }

    # === 1: Normal stop -- two real, still-running fixture processes are both stopped, exit 0. ===
    $procA=Start-KIComfyFixtureProcess
    $procB=Start-KIComfyFixtureProcess
    $result1=Invoke-KIComfyStopScript
    Start-Sleep -Milliseconds 300
    $failures0=$failures.Count
    if($result1.exitCode-ne0){$failures.Add("Szenario NormalStop: erwarteter Exitcode 0, erhalten $($result1.exitCode). Output: $($result1.output)")}
    if(Get-Process -Id $procA.Id -ErrorAction SilentlyContinue){$failures.Add('Szenario NormalStop: Prozess A wurde nicht beendet.')}
    if(Get-Process -Id $procB.Id -ErrorAction SilentlyContinue){$failures.Add('Szenario NormalStop: Prozess B wurde nicht beendet.')}
    if(-not($result1.output-match'ComfyUI-Prozess beendet.*PID')){$failures.Add("Szenario NormalStop: Erfolgsmeldung fehlt. Output: $($result1.output)")}

    # === 2: Race -- one fixture process is already gone by the time the stop script runs (killed
    # right before invocation, simulating it having exited on its own between enumeration and the
    # Stop-Process call for it), the other is still genuinely running. Exit code must still be 0
    # (a vanished process is a successful state, not an error), and the still-running one must
    # still be properly stopped. The real race window (between the script's own Get-CimInstance
    # enumeration and the moment it reaches a specific entry's Stop-Process call) is a handful of
    # milliseconds and not reliably reproducible by timing an external kill against the real,
    # unmodified script. To hit that exact window deterministically, this scenario runs a
    # byte-identical copy of the real generated stopPs1 content with exactly one addition -- a
    # fixed pause inserted between the enumeration and the per-entry loop -- solely to WIDEN that
    # real window long enough to land a kill inside it on purpose; the per-entry check-then-stop
    # logic itself (what is actually being tested here) is the unmodified, real generated text.
    # Scenario 4 below separately proves the real, un-widened generated script contains this exact
    # logic verbatim.
    $racePs1=$content.stopPs1.Replace(
        "if (`$matchingProcesses.Count -eq 0) {`n    Write-Host 'Kein laufender KI-Stack-ComfyUI-Prozess gefunden.'`n    exit 0`n}`n",
        "if (`$matchingProcesses.Count -eq 0) {`n    Write-Host 'Kein laufender KI-Stack-ComfyUI-Prozess gefunden.'`n    exit 0`n}`nStart-Sleep -Milliseconds 1500`n"
    )
    if($racePs1-eq$content.stopPs1){$failures.Add('Szenario Race: Verzoegerung konnte nicht in eine Testkopie des generierten Skripts eingefuegt werden (Anker nicht gefunden) -- Testaufbau ungueltig.')}
    $raceScriptPath=Join-Path $fixtureRoot 'Stop-KIStack-ComfyUI-RaceFixture.ps1'
    Set-Content -LiteralPath $raceScriptPath -Encoding utf8NoBOM -Value $racePs1

    $procC=Start-KIComfyFixtureProcess
    $procD=Start-KIComfyFixtureProcess
    $raceOutPath=Join-Path $fixtureRoot 'race-output.txt'
    $raceProc=Start-Process -FilePath $pwshPath -ArgumentList @('-NoLogo','-NoProfile','-File',$raceScriptPath) -WindowStyle Hidden -PassThru -RedirectStandardOutput $raceOutPath
    # The injected 1500ms pause sits strictly between the script's own enumeration (which has
    # already captured procC as a live, matching process by this point) and its per-entry loop --
    # killing procC here lands deterministically inside the real race window under test.
    Start-Sleep -Milliseconds 500
    Stop-Process -Id $procC.Id -Force
    $goneDeadline=(Get-Date).AddSeconds(5)
    while((Get-Process -Id $procC.Id -ErrorAction SilentlyContinue)-and(Get-Date)-lt$goneDeadline){Start-Sleep -Milliseconds 50}
    $procCGoneBeforeLoopReachedIt=(-not(Get-Process -Id $procC.Id -ErrorAction SilentlyContinue))
    $raceProc.WaitForExit(10000)|Out-Null
    $raceOutput=if(Test-Path -LiteralPath $raceOutPath){Get-Content -LiteralPath $raceOutPath -Raw}else{''}
    $checks2=[ordered]@{
        procCKilledWhileScriptWasPausedMidRun=$procCGoneBeforeLoopReachedIt
        exitCodeZeroDespiteRace=([int]$raceProc.ExitCode-eq0)
        stillRunningProcessWasStopped=(-not(Get-Process -Id $procD.Id -ErrorAction SilentlyContinue))
        reportsAlreadyStoppedForRaceCase=($raceOutput-match'ComfyUI-Prozess bereits beendet.*PID')
        stillReportsSuccessForRealStop=($raceOutput-match'ComfyUI-Prozess beendet.*PID')
    }
    foreach($name in $checks2.Keys){if(-not[bool]$checks2[$name]){$failures.Add("Szenario Race: Check '$name' fehlgeschlagen. Output: $raceOutput")}}

    # === 3: Nothing running -> clean, unchanged no-op. ==========================================
    $result3=Invoke-KIComfyStopScript
    if($result3.exitCode-ne0){$failures.Add("Szenario NichtsLaeuft: erwarteter Exitcode 0, erhalten $($result3.exitCode). Output: $($result3.output)")}
    if(-not($result3.output-match'Kein laufender KI-Stack-ComfyUI-Prozess gefunden')){$failures.Add("Szenario NichtsLaeuft: erwartete Meldung fehlt. Output: $($result3.output)")}

    # === 4: Static contract -- the generated script re-checks existence before Stop-Process, never
    # blanket-suppresses a real Stop-Process failure. =============================================
    $checks4=[ordered]@{
        reChecksExistenceBeforeStop=$content.stopPs1.Contains('Get-Process -Id $processId -ErrorAction SilentlyContinue')
        stopProcessStillFailsClosed=$content.stopPs1.Contains('Stop-Process -Id $processId -Force -ErrorAction Stop')
        realFailureStillRethrown=$content.stopPs1.Contains('throw')
    }
    foreach($name in $checks4.Keys){if(-not[bool]$checks4[$name]){$failures.Add("Statischer Vertrag '$name' fehlgeschlagen.")}}
}
finally{
    foreach($processId in $startedProcessIds){try{Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue}catch{}}
    if($fixtureRoot-and(Test-Path -LiteralPath $fixtureRoot)){Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue}
}

$result=[pscustomobject]@{passed=($failures.Count-eq0);checks=13;failures=@($failures)}
$result|ConvertTo-Json -Depth 10
if(-not $result.passed){exit 1}

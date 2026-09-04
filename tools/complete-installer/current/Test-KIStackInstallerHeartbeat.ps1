[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force

$fail=[Collections.Generic.List[string]]::new()

# 1. Short step: a heartbeat check made immediately after the step starts must not print anything
#    (no unnecessary heartbeat noise for fast steps). Zero sleep -- purely rate-limit logic.
$shortHeartbeat=New-KICompleteStepHeartbeat -StepLabel 'Kurzer Schritt' -IntervalSeconds 20
$shortOutput=(& { Write-KICompleteStepStatus -Heartbeat $shortHeartbeat -Status Running -Message 'Start'; Write-KICompleteStepHeartbeatIfDue -Heartbeat $shortHeartbeat -Status Running -Message 'Tick' } 6>&1|Out-String)
$shortStartLines=@([regex]::Matches($shortOutput,'Running - Start')).Count
$shortHeartbeatLines=@([regex]::Matches($shortOutput,'Tick, Laufzeit')).Count
if($shortStartLines-ne1){$fail.Add("Short step: expected exactly one start announcement, found $shortStartLines")}
if($shortHeartbeatLines-ne0){$fail.Add("Short step: expected no heartbeat tick, found $shortHeartbeatLines")}

# 2. Long step: once IntervalSeconds has genuinely elapsed, the next check must print a heartbeat
#    with elapsed runtime. A small real sleep proves the real-time gate, not a simulated one.
$longHeartbeat=New-KICompleteStepHeartbeat -StepLabel 'Langer Schritt' -IntervalSeconds 1
$longOutput=(& {
    Write-KICompleteStepStatus -Heartbeat $longHeartbeat -Status Running -Message 'Start'
    Write-KICompleteStepHeartbeatIfDue -Heartbeat $longHeartbeat -Status Running -Message 'Tick-zu-frueh'
    Start-Sleep -Milliseconds 1200
    Write-KICompleteStepHeartbeatIfDue -Heartbeat $longHeartbeat -Status Running -Message 'Tick-faellig'
} 6>&1|Out-String)
$tooEarlyLines=@([regex]::Matches($longOutput,'Tick-zu-frueh')).Count
$dueLines=@([regex]::Matches($longOutput,'Tick-faellig, Laufzeit \d{2}:\d{2}')).Count
if($tooEarlyLines-ne0){$fail.Add("Long step: heartbeat fired before interval elapsed ($tooEarlyLines times)")}
if($dueLines-ne1){$fail.Add("Long step: expected exactly one due heartbeat with runtime, found $dueLines")}

# 3. WaitingForUserAction is its own distinct, one-shot status (no elapsed-runtime suffix).
$waitingHeartbeat=New-KICompleteStepHeartbeat -StepLabel 'Visual Integration'
$waitingOutput=(& { Write-KICompleteStepStatus -Heartbeat $waitingHeartbeat -Status WaitingForUserAction -Message 'API-Key erforderlich' } 6>&1|Out-String)
if(-not($waitingOutput-match'WaitingForUserAction - API-Key erforderlich')){$fail.Add('WaitingForUserAction status line missing or malformed')}
if($waitingOutput-match'Laufzeit'){$fail.Add('WaitingForUserAction must not carry an elapsed-runtime suffix')}

# 4. Completed is printed exactly once and distinct from Running/Waiting.
$completedHeartbeat=New-KICompleteStepHeartbeat -StepLabel 'ComfyUI'
$completedOutput=(& { Write-KICompleteStepStatus -Heartbeat $completedHeartbeat -Status Completed -Message 'ComfyUI erreichbar' } 6>&1|Out-String)
$completedLines=@([regex]::Matches($completedOutput,'Completed - ComfyUI erreichbar')).Count
if($completedLines-ne1){$fail.Add("Completed status must appear exactly once, found $completedLines")}

# 5. Failed is printed exactly once and carries the failure message.
$failedHeartbeat=New-KICompleteStepHeartbeat -StepLabel 'Visual Integration'
$failedOutput=(& { Write-KICompleteStepStatus -Heartbeat $failedHeartbeat -Status Failed -Message 'ComfyUI nicht erreichbar' } 6>&1|Out-String)
$failedLines=@([regex]::Matches($failedOutput,'Failed - ComfyUI nicht erreichbar')).Count
if($failedLines-ne1){$fail.Add("Failed status must appear exactly once, found $failedLines")}

# 6. Real integration: the main step loop and its failure handler actually call the central
#    helper at step-start, step-completion/WaitingForUserAction, and step-failure -- proving this
#    is wired into the existing orchestrator rather than only unit-tested in isolation.
$failCountBeforeWiringCheck=$fail.Count
$orchestratorSource=Get-Content -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Raw
foreach($marker in @(
    'function New-KICompleteStepHeartbeat',
    'function Write-KICompleteStepStatus',
    'function Write-KICompleteStepHeartbeatIfDue',
    '$currentStepHeartbeat=New-KICompleteStepHeartbeat -StepLabel $step.name',
    "Write-KICompleteStepStatus -Heartbeat `$currentStepHeartbeat -Status Running",
    "Write-KICompleteStepStatus -Heartbeat `$currentStepHeartbeat -Status WaitingForUserAction",
    "Write-KICompleteStepStatus -Heartbeat `$currentStepHeartbeat -Status Completed",
    "Write-KICompleteStepStatus -Heartbeat `$failureHeartbeat -Status Failed"
)){
    if(-not$orchestratorSource.Contains($marker)){$fail.Add("Orchestrator integration marker missing: $marker")}
}
# Snapshot taken immediately after this section's own checks -- not at the very end of the
# script -- so later sections' own failures can never be misattributed to this one.
$orchestratorWiredResult=($fail.Count-eq$failCountBeforeWiringCheck)

$startScript=Get-Content -LiteralPath (Join-Path $PackageRoot 'Start-KIStackCompleteInstaller.ps1') -Raw
foreach($marker in @(
    'New-KICompleteStepHeartbeat -StepLabel ''OpenWebUI Erreichbarkeit''',
    'Write-KICompleteStepHeartbeatIfDue -Heartbeat $openWebUIHeartbeat -Status Waiting'
)){
    if(-not$startScript.Contains($marker)){$fail.Add("Readiness-loop integration marker missing: $marker")}
}

# 7. Elevation-launcher visibility fix (the reported bug): Start-KICompleteElevated must relay
#    the elevated child's live output via Watch-KICompleteElevatedProcess -- never the old,
#    silent "Start-Process -Verb RunAs -Wait" that leaves the calling (visible) console blind
#    until the whole elevated run finishes. Both markers checked as literal source text so this
#    regresses loudly if either the wiring is removed or the old blind-wait shape reappears.
$failCountBeforeElevationWiringCheck=$fail.Count
foreach($marker in @(
    'function Watch-KICompleteElevatedProcess',
    'function Split-KICompleteBufferedLines'
)){
    if(-not$orchestratorSource.Contains($marker)){$fail.Add("Elevation live-view wiring marker missing: $marker")}
}
if(-not$startScript.Contains('Watch-KICompleteElevatedProcess -Process $process -TranscriptPath')){$fail.Add('Elevation live-view wiring marker missing: Watch-KICompleteElevatedProcess -Process $process -TranscriptPath')}
if($startScript-match'Start-Process\s+-FilePath\s+\(Get-KIPowerShell7\)\s+-ArgumentList\s+\$arguments\s+-Verb\s+RunAs\s+-Wait\s+-PassThru'){
    $fail.Add('Old blind-wait elevation shape (Start-Process -Verb RunAs -Wait, no live relay) is still present')
}
if(-not($startScript-match'Start-Process\s+-FilePath\s+\(Get-KIPowerShell7\)\s+-ArgumentList\s+\$arguments\s+-Verb\s+RunAs\s+-PassThru')){
    $fail.Add('Expected non-blocking elevation launch (Start-Process ... -Verb RunAs -PassThru, no -Wait) not found')
}
# Snapshot taken immediately after this section's own checks -- see the identical reasoning on
# $orchestratorWiredResult above.
$elevationLiveViewWiredResult=($fail.Count-eq$failCountBeforeElevationWiringCheck)

# 8. Real, live-process proof: a real background pwsh process (standing in for the elevated
#    child -- UAC itself cannot be exercised in an automated test) runs the REAL heartbeat
#    functions against a REAL Start-Transcript file while Watch-KICompleteElevatedProcess tails
#    it. Proves, with real wall-clock timestamps (not just "output eventually appeared"), that
#    lines surface as they are written rather than only once the process exits, and that every
#    required status keyword surfaces live, with no duplicates, and the real exit code (0, 31,
#    and an arbitrary failure code) is picked up correctly afterward.
function Test-KICompleteLiveTailScenario {
    param([Parameter(Mandatory)][scriptblock]$WriterBody,[Parameter(Mandatory)][int]$ExpectedExitCode)
    $scratch=Join-Path ([IO.Path]::GetTempPath()) ('KIHB-'+[guid]::NewGuid().ToString('N').Substring(0,10))
    New-Item -ItemType Directory -Path $scratch -Force|Out-Null
    try{
        $transcriptPath=Join-Path $scratch 'fake.transcript.txt'
        $writerScript=Join-Path $scratch 'writer.ps1'
        Set-Content -LiteralPath $writerScript -Encoding utf8NoBOM -Value (
            "param([string]`$TranscriptPath)`r`n"+
            "Import-Module '$($PackageRoot.Replace("'","''"))\CompleteInstaller.psm1' -Force`r`n"+
            "Start-Transcript -LiteralPath `$TranscriptPath -Force | Out-Null`r`n"+
            $WriterBody.ToString()+"`r`n"+
            "Stop-Transcript | Out-Null`r`n"
        )
        $pwshPath=(Get-Command pwsh).Source
        $captured=[Collections.Generic.List[object]]::new()
        $sw=[Diagnostics.Stopwatch]::StartNew()
        $proc=Start-Process -FilePath $pwshPath -ArgumentList @('-NoLogo','-NoProfile','-File',$writerScript,'-TranscriptPath',$transcriptPath) -PassThru -WindowStyle Hidden
        $emit={param($line) $script:captured.Add([pscustomobject]@{elapsedMs=$sw.ElapsedMilliseconds;line=$line})}.GetNewClosure()
        Watch-KICompleteElevatedProcess -Process $proc -TranscriptPath $transcriptPath -EmitLine $emit
        [pscustomobject]@{
            exitCode=$proc.ExitCode
            captured=@($captured)
            transcriptLineCount=@(Get-Content -LiteralPath $transcriptPath -ErrorAction SilentlyContinue).Count
            expectedExitCodeMatched=($proc.ExitCode-eq$ExpectedExitCode)
        }
    }finally{
        try{Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue}catch{}
    }
}

$completedScenario=Test-KICompleteLiveTailScenario -ExpectedExitCode 0 -WriterBody {
    $hb=New-KICompleteStepHeartbeat -StepLabel 'Fake Step' -IntervalSeconds 1
    Write-KICompleteStepStatus -Heartbeat $hb -Status Running -Message 'Start'
    Start-Sleep -Milliseconds 700
    Write-KICompleteStepHeartbeatIfDue -Heartbeat $hb -Status Waiting -Message 'Tick-zu-frueh'
    Start-Sleep -Milliseconds 700
    Write-KICompleteStepHeartbeatIfDue -Heartbeat $hb -Status Waiting -Message 'Tick-faellig'
    Write-KICompleteStepStatus -Heartbeat $hb -Status Completed -Message 'Fertig'
    exit 0
}
$completedLinesJoined=($completedScenario.captured|ForEach-Object line)-join "`n"
$firstStatusMs=@($completedScenario.captured|Where-Object{$_.line-match'Running - Start'}|Select-Object -First 1).elapsedMs
$lastStatusMs=@($completedScenario.captured|Where-Object{$_.line-match'Completed - Fertig'}|Select-Object -First 1).elapsedMs
$checks_liveCompleted=[ordered]@{
    runningAppeared=($completedLinesJoined-match'Running - Start')
    tooEarlyTickNeverAppeared=($completedLinesJoined-notmatch'Tick-zu-frueh')
    periodicHeartbeatAppeared=($completedLinesJoined-match'Tick-faellig, Laufzeit')
    completedAppearedExactlyOnce=(@([regex]::Matches($completedLinesJoined,'Completed - Fertig')).Count-eq1)
    exitCodeZero=$completedScenario.expectedExitCodeMatched
    noDuplicateLines=(@($completedScenario.captured|Group-Object line|Where-Object{$_.Count-gt1-and$_.Name-notmatch'^\*+$'}).Count-eq0)
    transcriptFileFullyWritten=($completedScenario.transcriptLineCount-gt0)
    # The real proof of "live", not "buffered until the end": Running must have surfaced well
    # before Completed did, tracking the writer's own real Start-Sleep calls (>=1000ms apart),
    # never both appearing within a few ms of each other the way a buffered-until-exit relay
    # would produce.
    surfacedLiveNotBuffered=($null-ne$firstStatusMs-and$null-ne$lastStatusMs-and($lastStatusMs-$firstStatusMs)-ge900)
}
foreach($key in $checks_liveCompleted.Keys){if(-not$checks_liveCompleted[$key]){$fail.Add("Live-tail Completed-scenario check failed: $key")}}

$failedScenario=Test-KICompleteLiveTailScenario -ExpectedExitCode 5 -WriterBody {
    $hb=New-KICompleteStepHeartbeat -StepLabel 'Fake Step'
    Write-KICompleteStepStatus -Heartbeat $hb -Status Running -Message 'Start'
    Start-Sleep -Milliseconds 300
    Write-KICompleteStepStatus -Heartbeat $hb -Status Failed -Message 'Kaputt'
    exit 5
}
$failedLinesJoined=($failedScenario.captured|ForEach-Object line)-join "`n"
$checks_liveFailed=[ordered]@{
    failedAppearedExactlyOnce=(@([regex]::Matches($failedLinesJoined,'Failed - Kaputt')).Count-eq1)
    exitCodeMatchesRealFailure=$failedScenario.expectedExitCodeMatched
}
foreach($key in $checks_liveFailed.Keys){if(-not$checks_liveFailed[$key]){$fail.Add("Live-tail Failed-scenario check failed: $key")}}

$waitingForUserActionScenario=Test-KICompleteLiveTailScenario -ExpectedExitCode 0 -WriterBody {
    $hb=New-KICompleteStepHeartbeat -StepLabel 'Visual Integration'
    Write-KICompleteStepStatus -Heartbeat $hb -Status WaitingForUserAction -Message 'API-Key erforderlich'
    exit 0
}
$waitingLinesJoined=($waitingForUserActionScenario.captured|ForEach-Object line)-join "`n"
$checks_liveWaitingForUserAction=[ordered]@{
    waitingForUserActionAppeared=($waitingLinesJoined-match'WaitingForUserAction - API-Key erforderlich')
    exitCodeZero=$waitingForUserActionScenario.expectedExitCodeMatched
}
foreach($key in $checks_liveWaitingForUserAction.Keys){if(-not$checks_liveWaitingForUserAction[$key]){$fail.Add("Live-tail WaitingForUserAction-scenario check failed: $key")}}

$rebootScenario=Test-KICompleteLiveTailScenario -ExpectedExitCode 31 -WriterBody {
    $hb=New-KICompleteStepHeartbeat -StepLabel 'Fake Step'
    Write-KICompleteStepStatus -Heartbeat $hb -Status Completed -Message 'Neustart erforderlich'
    exit 31
}
$checks_liveReboot=[ordered]@{ exitCode31Preserved=$rebootScenario.expectedExitCodeMatched }
foreach($key in $checks_liveReboot.Keys){if(-not$checks_liveReboot[$key]){$fail.Add("Live-tail Reboot-scenario check failed: $key")}}

# 9. Split-KICompleteBufferedLines: pure-function edge cases -- a line split exactly across two
#    reads must never be emitted torn (the real, direct proof of "keine Race Conditions").
$splitCase1=Split-KICompleteBufferedLines -Buffer '' -Chunk "Running - Star"
$splitCase2=Split-KICompleteBufferedLines -Buffer $splitCase1.remainder -Chunk "t`r`nCompleted - Done`r`n"
$checks_splitBuffering=[ordered]@{
    # The torn word "Star" (no trailing newline yet) must never be emitted as a line by itself --
    # exactly the real "keine Race Conditions" guarantee this function exists to provide.
    firstChunkNoLineYetTornWordWithheld=(@($splitCase1.lines).Count-eq0-and$splitCase1.remainder-eq'Running - Star')
    secondChunkCompletesTornLine=(@($splitCase2.lines).Count-eq2-and$splitCase2.lines[0]-eq'Running - Start'-and$splitCase2.lines[1]-eq'Completed - Done')
    trailingCompleteNewlineLeavesEmptyRemainder=($splitCase2.remainder-eq'')
}
foreach($key in $checks_splitBuffering.Keys){if(-not$checks_splitBuffering[$key]){$fail.Add("Split-KICompleteBufferedLines check failed: $key")}}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=[ordered]@{
    shortStepNoHeartbeat=($shortStartLines-eq1-and$shortHeartbeatLines-eq0)
    longStepHeartbeatEmitted=($tooEarlyLines-eq0-and$dueLines-eq1)
    waitingForUserActionDistinct=($waitingOutput-match'WaitingForUserAction - API-Key erforderlich'-and$waitingOutput-notmatch'Laufzeit')
    completedExactlyOnce=($completedLines-eq1)
    failedExactlyOnce=($failedLines-eq1)
    orchestratorWired=$orchestratorWiredResult
    elevationLiveViewWired=$elevationLiveViewWiredResult
    liveTailCompletedScenario=$checks_liveCompleted
    liveTailFailedScenario=$checks_liveFailed
    liveTailWaitingForUserActionScenario=$checks_liveWaitingForUserAction
    liveTailRebootScenario=$checks_liveReboot
    splitBuffering=$checks_splitBuffering
};failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'Installer-Heartbeat-Regression fehlgeschlagen.'}

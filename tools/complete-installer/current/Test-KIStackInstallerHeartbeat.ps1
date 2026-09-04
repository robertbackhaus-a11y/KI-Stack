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
            # Captured as raw content here, before the scratch directory (and the transcript
            # file with it) is removed in `finally` below -- proves the real, on-disk artifact
            # still has everything the live filter suppressed, without the caller needing its
            # own now-deleted path.
            transcriptRawContent=(Get-Content -LiteralPath $transcriptPath -Raw -ErrorAction SilentlyContinue)
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
# Measured against the periodic heartbeat, not Completed -- the writer body sleeps a real
# ~1400ms total BEFORE the periodic tick fires, but emits Completed immediately afterward with
# no further sleep, so Running-to-Completed alone would not reliably prove live delivery.
$firstStatusMs=@($completedScenario.captured|Where-Object{$_.line-match'Running - Start'}|Select-Object -First 1).elapsedMs
$lastStatusMs=@($completedScenario.captured|Where-Object{$_.line-match'Tick-faellig, Laufzeit'}|Select-Object -First 1).elapsedMs
$checks_liveCompleted=[ordered]@{
    runningAppeared=($completedLinesJoined-match'Running - Start')
    tooEarlyTickNeverAppeared=($completedLinesJoined-notmatch'Tick-zu-frueh')
    periodicHeartbeatAppeared=($completedLinesJoined-match'Tick-faellig, Laufzeit')
    completedAppearedExactlyOnce=(@([regex]::Matches($completedLinesJoined,'Completed - Fertig')).Count-eq1)
    exitCodeZero=$completedScenario.expectedExitCodeMatched
    noDuplicateLines=(@($completedScenario.captured|Group-Object line|Where-Object{$_.Count-gt1-and$_.Name-notmatch'^\*+$'}).Count-eq0)
    transcriptFileFullyWritten=($completedScenario.transcriptLineCount-gt0)
    # The real proof of "live", not "buffered until the end": Running must have surfaced well
    # before the periodic heartbeat did, tracking the writer's own real Start-Sleep calls.
    # PowerShell's own transcript writer applies some internal buffering of its own (observed
    # directly: a real ~1400ms writer-side gap between these two lines shows up as a somewhat
    # smaller, but still real and clearly non-zero, gap once relayed through Start-Transcript's
    # own file writes) -- 300ms is comfortably above what a genuinely buffered-until-process-exit
    # relay could ever produce (which clusters every line within single-digit ms of each other,
    # right at process exit), while staying robust to that real, orthogonal buffering behavior.
    surfacedLiveNotBuffered=($null-ne$firstStatusMs-and$null-ne$lastStatusMs-and($lastStatusMs-$firstStatusMs)-ge300)
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

# 10. Live-view noise filter: PowerShell's real transcript header/footer and a real, genuinely
#     caught-and-handled "PS>TerminatingError(...)" line (a real failed probe, exactly the
#     already-caught readiness/retry shape this installer's own OpenWebUI/ComfyUI wait loops
#     produce) must never reach the live view -- while the real Step-label/Running/Completed
#     lines around them do, AND the raw transcript FILE on disk still has every single one of
#     those suppressed lines in full (the filter only ever affects the live relay, never the
#     artifact itself).
$noiseScenario=Test-KICompleteLiveTailScenario -ExpectedExitCode 0 -WriterBody {
    $hb=New-KICompleteStepHeartbeat -StepLabel 'Filter Test Step'
    Write-KICompleteStepStatus -Heartbeat $hb -Status Running -Message 'Start'
    try{Get-Content -LiteralPath 'C:\this-file-does-not-exist-xyz.txt' -ErrorAction Stop}catch{}
    Write-KICompleteStepStatus -Heartbeat $hb -Status Completed -Message 'Fertig'
    exit 0
}
$noiseLinesJoined=($noiseScenario.captured|ForEach-Object line)-join "`n"
$noiseTranscriptRaw=$noiseScenario.transcriptRawContent
$checks_liveNoiseFilter=[ordered]@{
    stepLabelAnnouncementVisible=($noiseLinesJoined-match'\[Filter Test Step\]')
    runningVisible=($noiseLinesJoined-match'Running - Start')
    completedVisible=($noiseLinesJoined-match'Completed - Fertig')
    transcriptHeaderBannerHidden=($noiseLinesJoined-notmatch'PowerShell transcript start')
    transcriptFooterBannerHidden=($noiseLinesJoined-notmatch'PowerShell transcript end')
    transcriptSeparatorRulesHidden=(-not(@($noiseScenario.captured|Where-Object{$_.line.Trim()-match'^\*{10,}$'}).Count))
    metadataFieldsHidden=($noiseLinesJoined-notmatch'PSVersion:'-and$noiseLinesJoined-notmatch'Username:'-and$noiseLinesJoined-notmatch'Host Application:')
    terminatingErrorNoiseHidden=($noiseLinesJoined-notmatch'PS>TerminatingError')
    # The suppressed content must still be fully, really present in the actual transcript file --
    # never removed from the real artifact, only from the live relay.
    rawTranscriptStillHasHeader=($null-ne$noiseTranscriptRaw-and$noiseTranscriptRaw.Contains('PowerShell transcript start'))
    rawTranscriptStillHasFooter=($null-ne$noiseTranscriptRaw-and$noiseTranscriptRaw.Contains('PowerShell transcript end'))
    rawTranscriptStillHasTerminatingError=($null-ne$noiseTranscriptRaw-and$noiseTranscriptRaw.Contains('PS>TerminatingError'))
}
foreach($key in $checks_liveNoiseFilter.Keys){if(-not$checks_liveNoiseFilter[$key]){$fail.Add("Live-view noise filter check failed: $key")}}

# 11. A real failure occurring ALONGSIDE the same kind of internal, already-caught noise must
#     still surface Failed live, exactly once -- the filter must never combine with a real error
#     path to hide it (the actual "keine Fehler verschlucken" proof, not just the filter's own
#     unit behavior in isolation).
$noisyFailureScenario=Test-KICompleteLiveTailScenario -ExpectedExitCode 9 -WriterBody {
    $hb=New-KICompleteStepHeartbeat -StepLabel 'Fake Step'
    Write-KICompleteStepStatus -Heartbeat $hb -Status Running -Message 'Start'
    try{Get-Content -LiteralPath 'C:\this-file-does-not-exist-xyz.txt' -ErrorAction Stop}catch{}
    Write-KICompleteStepStatus -Heartbeat $hb -Status Failed -Message 'Echter Fehler'
    exit 9
}
$noisyFailureLinesJoined=($noisyFailureScenario.captured|ForEach-Object line)-join "`n"
$checks_liveNoisyFailure=[ordered]@{
    realFailedStillVisibleAmidNoise=(@([regex]::Matches($noisyFailureLinesJoined,'Failed - Echter Fehler')).Count-eq1)
    terminatingErrorNoiseStillHidden=($noisyFailureLinesJoined-notmatch'PS>TerminatingError')
    exitCodeMatchesRealFailure=$noisyFailureScenario.expectedExitCodeMatched
}
foreach($key in $checks_liveNoisyFailure.Keys){if(-not$checks_liveNoisyFailure[$key]){$fail.Add("Live-view noisy-failure check failed: $key")}}

# 12. Test-KICompleteTranscriptNoiseLine as a pure predicate -- direct proof the deny-list is
#     exact (only the documented known-noise shapes match) and never matches an arbitrary,
#     unanticipated real message (the actual "kann keinen echten Fehler verschlucken" guarantee,
#     stated as a property of the filter function itself rather than only observed indirectly).
$checks_noisePredicate=[ordered]@{
    matchesSeparatorRule=(Test-KICompleteTranscriptNoiseLine '**********************')
    matchesTranscriptStart=(Test-KICompleteTranscriptNoiseLine 'PowerShell transcript start')
    matchesTranscriptEnd=(Test-KICompleteTranscriptNoiseLine 'PowerShell transcript end')
    matchesUsernameField=(Test-KICompleteTranscriptNoiseLine 'Username: NXK-01\okami')
    matchesTerminatingError=(Test-KICompleteTranscriptNoiseLine 'PS>TerminatingError(Get-Content): "some real message"')
    neverMatchesRealRunningLine=(-not(Test-KICompleteTranscriptNoiseLine '[10:00:00] Running - Start'))
    neverMatchesRealFailedLine=(-not(Test-KICompleteTranscriptNoiseLine '[10:00:00] Failed - Echter, unerwarteter Fehler'))
    neverMatchesStepAnnouncement=(-not(Test-KICompleteTranscriptNoiseLine '[Irgendein Schritt]'))
    neverMatchesArbitraryUserMessage=(-not(Test-KICompleteTranscriptNoiseLine 'Windows-Neustart erforderlich. Danach Resume-KIStack-Installer.cmd ABC123 ausfuehren.'))
    neverMatchesEmptyLine=(-not(Test-KICompleteTranscriptNoiseLine ''))
}
foreach($key in $checks_noisePredicate.Keys){if(-not$checks_noisePredicate[$key]){$fail.Add("Test-KICompleteTranscriptNoiseLine predicate check failed: $key")}}

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

# 13. No duplicate final JSON in the normal launcher path: the same copy-and-patch technique
#     Test-KIStackExitCodePropagation.ps1 already establishes (skip the elevation branch, and
#     substitute a fixture $result instead of a real Invoke-KIStackCompleteInstaller run) is
#     reused here to run the REAL, unmodified completion-path code (the human-readable summary
#     replacing the old Write-Output $json) and capture its REAL stdout -- proving the full JSON
#     never appears on stdout at all anymore (Start-KIStack-Installer.cmd's own final "type
#     %LOG%" is therefore the only place it is shown), while KI-Stack-Installer-output.txt
#     itself still receives the exact, complete, unabridged JSON record unchanged.
$dupJsonTemp=Join-Path ([IO.Path]::GetTempPath()) ('KIHB-nodup-'+[guid]::NewGuid().ToString('N').Substring(0,10))
New-Item -ItemType Directory -Path $dupJsonTemp -Force|Out-Null
try{
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Destination $dupJsonTemp
    New-Item -ItemType Directory -Path (Join-Path $dupJsonTemp 'Runtime') -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'Runtime/KIStackPathContext.psm1') -Destination (Join-Path $dupJsonTemp 'Runtime')
    $dupJsonSource=Get-Content -LiteralPath (Join-Path $PackageRoot 'Start-KIStackCompleteInstaller.ps1') -Raw
    $dupJsonSource=$dupJsonSource.Replace('if(-not(Test-KICompleteAdministrator)){','if($false){')
    $dupJsonSource=$dupJsonSource.Replace('$plan=New-KICompletePlan -Mode Upgrade -PackageRoot $PSScriptRoot -TargetRoot ''C:\KI-Stack'' -ReplayComponent $ReplayComponent','$plan=[pscustomobject]@{steps=@()}')
    $dupJsonSource=$dupJsonSource.Replace(
        '$result=Invoke-KIStackCompleteInstaller -Mode Upgrade -PackageRoot $PSScriptRoot -TargetRoot ''C:\KI-Stack'' -TransactionId $TransactionId -Resume:$Resume -OpenWebUIApiToken $apiToken -ReplayComponent $ReplayComponent',
        '$result=[pscustomobject]@{schemaVersion=''1.1'';status=''Completed'';transactionId=''TEST-NODUP'';steps=@([pscustomobject]@{id=''fake-a'';status=''Completed''},[pscustomobject]@{id=''fake-b'';status=''SkippedAlreadyCompliant''})}'
    )
    $dupJsonScript=Join-Path $dupJsonTemp 'patched.ps1'
    [IO.File]::WriteAllText($dupJsonScript,$dupJsonSource,[Text.UTF8Encoding]::new($false))
    $dupJsonLog=Join-Path $dupJsonTemp 'output.log'
    $dupJsonStdout=(& (Get-Command pwsh.exe).Source -NoLogo -NoProfile -File $dupJsonScript -Elevated -LogPath $dupJsonLog 2>$null)-join "`n"
    $dupJsonLogContent=Get-Content -LiteralPath $dupJsonLog -Raw -ErrorAction SilentlyContinue
    $checks_noDuplicateFinalJson=[ordered]@{
        # The exact JSON key:value text ConvertTo-Json would produce for the fixture -- must
        # appear in the log FILE, never on stdout.
        stdoutNeverContainsFullJsonRecord=(-not$dupJsonStdout.Contains('"transactionId": "TEST-NODUP"'))
        stdoutNeverContainsSchemaVersionField=(-not$dupJsonStdout.Contains('"schemaVersion"'))
        humanReadableSummaryAppearsOnStdout=($dupJsonStdout-match'Ergebnis: Completed \(TransactionId: TEST-NODUP\)')
        humanReadableSummaryAppearsExactlyOnce=(@([regex]::Matches($dupJsonStdout,'Ergebnis: Completed')).Count-eq1)
        componentSummaryLineAppears=($dupJsonStdout-match'Komponenten: 2 von 2 abgeschlossen')
        logFileStillHasCompleteJsonRecord=($null-ne$dupJsonLogContent-and$dupJsonLogContent.Contains('"transactionId": "TEST-NODUP"')-and$dupJsonLogContent.Contains('"schemaVersion"'))
        exitCodeStillZero=($LASTEXITCODE-eq0)
    }
    foreach($key in $checks_noDuplicateFinalJson.Keys){if(-not$checks_noDuplicateFinalJson[$key]){$fail.Add("No-duplicate-final-JSON check failed: $key")}}
}finally{
    if(Test-Path -LiteralPath $dupJsonTemp){Remove-Item -LiteralPath $dupJsonTemp -Recurse -Force -ErrorAction SilentlyContinue}
}

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
    liveViewNoiseFilter=$checks_liveNoiseFilter
    liveViewNoisyFailure=$checks_liveNoisyFailure
    noisePredicate=$checks_noisePredicate
    splitBuffering=$checks_splitBuffering
    noDuplicateFinalJson=$checks_noDuplicateFinalJson
};failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'Installer-Heartbeat-Regression fehlgeschlagen.'}

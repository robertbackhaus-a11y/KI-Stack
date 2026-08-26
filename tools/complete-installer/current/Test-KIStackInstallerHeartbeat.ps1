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

$startScript=Get-Content -LiteralPath (Join-Path $PackageRoot 'Start-KIStackCompleteInstaller.ps1') -Raw
foreach($marker in @(
    'New-KICompleteStepHeartbeat -StepLabel ''OpenWebUI Erreichbarkeit''',
    'Write-KICompleteStepHeartbeatIfDue -Heartbeat $openWebUIHeartbeat -Status Waiting'
)){
    if(-not$startScript.Contains($marker)){$fail.Add("Readiness-loop integration marker missing: $marker")}
}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=[ordered]@{
    shortStepNoHeartbeat=($shortStartLines-eq1-and$shortHeartbeatLines-eq0)
    longStepHeartbeatEmitted=($tooEarlyLines-eq0-and$dueLines-eq1)
    waitingForUserActionDistinct=($waitingOutput-match'WaitingForUserAction - API-Key erforderlich'-and$waitingOutput-notmatch'Laufzeit')
    completedExactlyOnce=($completedLines-eq1)
    failedExactlyOnce=($failedLines-eq1)
    orchestratorWired=($fail.Count-eq$failCountBeforeWiringCheck)
};failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'Installer-Heartbeat-Regression fehlgeschlagen.'}

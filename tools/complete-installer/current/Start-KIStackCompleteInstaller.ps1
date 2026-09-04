[CmdletBinding()]
param(
    [switch]$Resume,
    [string]$TransactionId,
    [switch]$Elevated,
    [switch]$LoggingProbe,
    [string]$LogPath,
    [string[]]$ReplayComponent=@()
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Text.UTF8Encoding]::new($false)

function Test-KICompleteAdministrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-KIPowerShell7 {
    $fixed=Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if(Test-Path -LiteralPath $fixed -PathType Leaf){return $fixed}
    $resolved=@(Get-Command pwsh.exe -CommandType Application -ErrorAction Stop|Select-Object -First 1)[0]
    if($resolved.Version.Major-lt7){throw 'PowerShell 7 wurde nicht gefunden.'}
    $resolved.Source
}

function Start-KICompleteElevated {
    param([string]$ScriptPath,[switch]$Resume,[string]$TransactionId,[switch]$LoggingProbe,[string]$LogPath,[string[]]$ReplayComponent=@())
    $arguments=[Collections.Generic.List[string]]::new()
    foreach($item in @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$ScriptPath,'-Elevated','-LogPath',$LogPath)){$arguments.Add($item)}
    if($Resume){$arguments.Add('-Resume')}
    if($LoggingProbe){$arguments.Add('-LoggingProbe')}
    if($TransactionId){$arguments.Add('-TransactionId');$arguments.Add($TransactionId)}
    if($ReplayComponent.Count){$arguments.Add('-ReplayComponent');foreach($id in $ReplayComponent){$arguments.Add($id)}}
    $process=Start-Process -FilePath (Get-KIPowerShell7) -ArgumentList $arguments -Verb RunAs -PassThru -ErrorAction Stop
    try {
        Watch-KICompleteElevatedProcess -Process $process -TranscriptPath ($LogPath + '.transcript.txt')
    } catch {
        # The live-view mechanism itself must never turn a successful elevated run into a
        # reported failure -- fall back to the exact prior behavior (blind wait) and still exit
        # with the elevated process's own real exit code.
        if (-not $process.HasExited) { $process.WaitForExit() }
    }
    exit $process.ExitCode
}

if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw 'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}
if([string]::IsNullOrWhiteSpace($LogPath)){$LogPath=Join-Path $PSScriptRoot 'KI-Stack-Installer-output.txt'}
$LogPath=[IO.Path]::GetFullPath($LogPath)
$logParent=Split-Path -Parent $LogPath
if(-not(Test-Path -LiteralPath $logParent)){New-Item -ItemType Directory -Path $logParent -Force|Out-Null}
# Imported here, before the elevation check below, so Start-KICompleteElevated's own call to
# Watch-KICompleteElevatedProcess (both now live in CompleteInstaller.psm1, alongside the
# heartbeat functions whose output it relays) is available regardless of which branch runs.
Import-Module (Join-Path $PSScriptRoot 'CompleteInstaller.psm1') -Force

if(-not(Test-KICompleteAdministrator)){
    if($Elevated){throw 'Die UAC-Elevation wurde abgebrochen oder war nicht wirksam.'}
    Start-KICompleteElevated -ScriptPath $PSCommandPath -Resume:$Resume -TransactionId $TransactionId -LoggingProbe:$LoggingProbe -LogPath $LogPath -ReplayComponent $ReplayComponent
}
if($Resume-and[string]::IsNullOrWhiteSpace($TransactionId)){throw 'Resume erfordert eine TransactionId.'}

$stderrPath=$LogPath+'.stderr.txt'
$transcriptPath=$LogPath+'.transcript.txt'
$exitPath=$LogPath+'.exitcode.txt'
$transcriptStarted=$false
$exitCode=1
$result=$null
try{
    foreach($path in @($LogPath,$stderrPath,$exitPath)){[IO.File]::WriteAllText($path,'',[Text.UTF8Encoding]::new($false))}
    Start-Transcript -LiteralPath $transcriptPath -Force|Out-Null
    $transcriptStarted=$true
    if($LoggingProbe){
        $json=([ordered]@{passed=$true;mode='LoggingProbe';elevated=(Test-KICompleteAdministrator);mutatesTarget=$false}|ConvertTo-Json)
        [IO.File]::WriteAllText($LogPath,$json+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
        Write-Output $json
        $exitCode=0
        return
    }
    $plan=New-KICompletePlan -Mode Upgrade -PackageRoot $PSScriptRoot -TargetRoot 'C:\KI-Stack' -ReplayComponent $ReplayComponent
    $needsOpenWebUI=@($plan.steps|Where-Object{$_.id-in@('openwebui-agent-pack','openwebui-visual-pack')-and$_.plannedMode-ne'Skip'})
    $needsVisualPackCutover=@($needsOpenWebUI|Where-Object{$_.id-eq'openwebui-visual-pack'}).Count-gt0
    $apiToken=$null
    # OpenWebUI-Credential-Bootstrap-Workstream (Section 24): a normal Upgrade run must reuse an
    # already-bootstrapped, valid credential silently -- never prompt interactively just because
    # one already exists. Purely additive: on a target with no stored credential at all (the
    # existing, already-tested Greenfield/no-bootstrap-yet case), Test-KIStackOpenWebUICredential
    # returns NotConfigured and every line below this falls through to the original, unchanged
    # wait-for-OpenWebUI + one-time interactive-prompt path exactly as before.
    try{
        Import-Module (Join-Path $PSScriptRoot 'Lifecycle/KIStackOpenWebUICredential.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $storedCredentialStatus=Test-KIStackOpenWebUICredential -TargetRoot 'C:\KI-Stack'
        if([string]$storedCredentialStatus.status-eq'Valid'){
            $storedCredential=Get-KIStackOpenWebUICredential -TargetRoot 'C:\KI-Stack'
            if($null-ne$storedCredential-and-not[bool]$storedCredential.decryptionFailed){$apiToken=$storedCredential.apiKey}
        }
    }catch{}
    try{
        if($needsOpenWebUI.Count){
            $config=$null
            $openWebUIWaitMaxAttempts=15
            $openWebUIWaitIntervalSeconds=2
            $openWebUIHeartbeat=New-KICompleteStepHeartbeat -StepLabel 'OpenWebUI Erreichbarkeit'
            Write-KICompleteStepStatus -Heartbeat $openWebUIHeartbeat -Status Waiting -Message 'OpenWebUI Health-Endpoint wird geprüft'
            for($openWebUIAttempt=1;$openWebUIAttempt-le$openWebUIWaitMaxAttempts;$openWebUIAttempt++){
                try{
                    $config=Invoke-WebRequest -Uri 'http://127.0.0.1:8080/api/config' -UseBasicParsing -TimeoutSec 5
                    if($config.StatusCode-lt200-or$config.StatusCode-ge400){throw 'OpenWebUI nicht bereit'}
                    break
                }catch{
                    $config=$null
                    if($openWebUIAttempt-lt$openWebUIWaitMaxAttempts){
                        Write-KICompleteStepHeartbeatIfDue -Heartbeat $openWebUIHeartbeat -Status Waiting -Message 'OpenWebUI Health-Endpoint noch nicht erreichbar'
                        Start-Sleep -Seconds $openWebUIWaitIntervalSeconds
                    }
                }
            }
            if($null-eq$config){
                Write-KICompleteStepStatus -Heartbeat $openWebUIHeartbeat -Status Failed -Message 'OpenWebUI nicht erreichbar'
                throw "OpenWebUI ist unter http://127.0.0.1:8080 nach $openWebUIWaitMaxAttempts Versuchen (je $openWebUIWaitIntervalSeconds s) nicht erreichbar."
            }
            Write-KICompleteStepStatus -Heartbeat $openWebUIHeartbeat -Status Completed -Message 'OpenWebUI erreichbar'
            if($needsVisualPackCutover){
                $comfyHeartbeat=New-KICompleteStepHeartbeat -StepLabel 'ComfyUI Erreichbarkeit'
                try{
                    $comfy=Invoke-WebRequest -Uri 'http://127.0.0.1:8188/system_stats' -UseBasicParsing -TimeoutSec 5
                    if($comfy.StatusCode-lt200-or$comfy.StatusCode-ge400){throw 'ComfyUI nicht bereit'}
                }catch{
                    Write-KICompleteStepStatus -Heartbeat $comfyHeartbeat -Status Failed -Message 'ComfyUI nicht erreichbar'
                    throw 'ComfyUI ist unter http://127.0.0.1:8188 nicht erreichbar; der Visual-Pack-Cutover benötigt einen laufenden ComfyUI-Dienst.'
                }
            }
            if($null-eq$apiToken){
                # Reached only when no already-bootstrapped, valid credential resolved above --
                # the original, unchanged one-time manual/interactive path.
                if($needsVisualPackCutover){
                    Write-Host ''
                    Write-Host '=== OpenWebUI Visual-Pack-Cutover: einmaliger Erstanmelde-/API-Key-Schritt ===' -ForegroundColor Cyan
                    Write-Host '1. OpenWebUI oeffnet sich jetzt im Standardbrowser (http://127.0.0.1:8080).' -ForegroundColor Cyan
                    Write-Host '2. Ersten Benutzer als Administrator anlegen, falls noch keiner existiert - sonst anmelden.' -ForegroundColor Cyan
                    Write-Host '3. Zu Einstellungen -> Konto -> API-Keys wechseln und einen neuen API-Key erzeugen.' -ForegroundColor Cyan
                    Write-Host '4. Zu diesem Fenster zurueckkehren.' -ForegroundColor Cyan
                    Write-Host ''
                    try{Start-Process 'http://127.0.0.1:8080'}catch{Write-Host "OpenWebUI konnte nicht automatisch im Browser geoeffnet werden: $($_.Exception.Message)" -ForegroundColor Yellow}
                    Read-Host 'Enter druecken, sobald der API-Key erzeugt wurde und bereitsteht'
                }
                $enteredApiToken=Read-Host 'Temporären OpenWebUI-Administrator-API-Key eingeben' -AsSecureString
                if($enteredApiToken.Length-gt0){
                    $apiToken=$enteredApiToken
                }else{
                    Write-Host 'Kein API-Key eingegeben; Transaktion wird ohne API-Schlüssel als WaitingForUserAction fortgesetzt.' -ForegroundColor Yellow
                }
            }else{
                Write-Host 'Bereits bootstrapptes, gültiges OpenWebUI-Credential gefunden -- kein interaktiver Prompt nötig (siehe Initialize-KIStackOpenWebUICredential.ps1 für Rotation/Re-Bootstrap).' -ForegroundColor DarkGray
            }
        }
        $result=Invoke-KIStackCompleteInstaller -Mode Upgrade -PackageRoot $PSScriptRoot -TargetRoot 'C:\KI-Stack' -TransactionId $TransactionId -Resume:$Resume -OpenWebUIApiToken $apiToken -ReplayComponent $ReplayComponent
        $json=$result|ConvertTo-Json -Depth 100
        [IO.File]::WriteAllText($LogPath,$json+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
        Write-Output $json
        if($needsVisualPackCutover){
            $visualStep=@($result.steps|Where-Object{$_.id-eq'openwebui-visual-pack'-and$_.status-eq'Completed'}|Select-Object -First 1)
            if($visualStep.Count){
                Write-Host ''
                Write-Host '=== Visual-Pack-Cutover: abschliessender manueller Funktionstest ===' -ForegroundColor Cyan
                Write-Host 'ki_stack_generate_image und ki_stack_generate_video wurden installiert und sind an beide vorgesehenen Profile gebunden.' -ForegroundColor Cyan
                Write-Host 'Bitte in OpenWebUI genau einen echten Bildtest und genau einen echten Videotest durchfuehren.' -ForegroundColor Cyan
                Read-Host 'Enter druecken, sobald beide Tests erfolgreich abgeschlossen wurden'
            }
        }
        $exitCode=if([string]$result.status-eq'WaitingForRestart'){31}else{0}
        if($exitCode-eq31){Write-Host "Windows-Neustart erforderlich. Danach Resume-KIStack-Installer.cmd $($result.transactionId) ausführen." -ForegroundColor Yellow}
    }finally{
        $apiToken=$null
        [GC]::Collect()
        if($needsOpenWebUI.Count){Write-Host 'Temporären OpenWebUI-API-Key in OpenWebUI widerrufen.' -ForegroundColor Yellow}
    }
}catch{
    $message=$_.Exception.ToString()
    [IO.File]::WriteAllText($stderrPath,$message+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    if(-not(Test-Path -LiteralPath $LogPath)-or(Get-Item -LiteralPath $LogPath).Length-eq0){
        [IO.File]::WriteAllText($LogPath,("FAILED: "+$_.Exception.Message+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    }
    $exitCode=1
    if($_.Exception.Data.Contains('KIStackExitCode')){
        $innerExitCode=[int]$_.Exception.Data['KIStackExitCode']
        if($innerExitCode-ge1-and$innerExitCode-le255){$exitCode=$innerExitCode}
    }
    Write-Error -ErrorRecord $_ -ErrorAction Continue
}finally{
    if($transcriptStarted){Stop-Transcript|Out-Null}
    if((Test-Path -LiteralPath $stderrPath -PathType Leaf)-and(Get-Item -LiteralPath $stderrPath).Length-eq0){
        [IO.File]::WriteAllText($stderrPath,"No stderr output.`r`n",[Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText($exitPath,[string]$exitCode+[Environment]::NewLine,[Text.Encoding]::ASCII)
}
exit $exitCode

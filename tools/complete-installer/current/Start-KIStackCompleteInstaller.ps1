[CmdletBinding()]
param(
    [switch]$Resume,
    [string]$TransactionId,
    [switch]$Elevated,
    [switch]$LoggingProbe,
    [string]$LogPath
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
    param([string]$ScriptPath,[switch]$Resume,[string]$TransactionId,[switch]$LoggingProbe,[string]$LogPath)
    $arguments=[Collections.Generic.List[string]]::new()
    foreach($item in @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$ScriptPath,'-Elevated','-LogPath',$LogPath)){$arguments.Add($item)}
    if($Resume){$arguments.Add('-Resume')}
    if($LoggingProbe){$arguments.Add('-LoggingProbe')}
    if($TransactionId){$arguments.Add('-TransactionId');$arguments.Add($TransactionId)}
    $process=Start-Process -FilePath (Get-KIPowerShell7) -ArgumentList $arguments -Verb RunAs -Wait -PassThru -ErrorAction Stop
    exit $process.ExitCode
}

if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw 'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}
if([string]::IsNullOrWhiteSpace($LogPath)){$LogPath=Join-Path $PSScriptRoot 'KI-Stack-Installer-output.txt'}
$LogPath=[IO.Path]::GetFullPath($LogPath)
$logParent=Split-Path -Parent $LogPath
if(-not(Test-Path -LiteralPath $logParent)){New-Item -ItemType Directory -Path $logParent -Force|Out-Null}

if(-not(Test-KICompleteAdministrator)){
    if($Elevated){throw 'Die UAC-Elevation wurde abgebrochen oder war nicht wirksam.'}
    Start-KICompleteElevated -ScriptPath $PSCommandPath -Resume:$Resume -TransactionId $TransactionId -LoggingProbe:$LoggingProbe -LogPath $LogPath
}
if($Resume-and[string]::IsNullOrWhiteSpace($TransactionId)){throw 'Resume erfordert eine TransactionId.'}

$stderrPath=$LogPath+'.stderr.txt'
$transcriptPath=$LogPath+'.transcript.txt'
$exitPath=$LogPath+'.exitcode.txt'
$transcriptStarted=$false
$exitCode=1
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
    Import-Module (Join-Path $PSScriptRoot 'CompleteInstaller.psm1') -Force
    $plan=New-KICompletePlan -Mode Upgrade -PackageRoot $PSScriptRoot -TargetRoot 'C:\KI-Stack'
    $needsOpenWebUI=@($plan.steps|Where-Object{$_.id-in@('openwebui-agent-pack','openwebui-visual-pack')-and$_.plannedMode-ne'Skip'})
    $apiToken=$null
    try{
        if($needsOpenWebUI.Count){
            $config=$null
            try{
                $config=Invoke-WebRequest -Uri 'http://127.0.0.1:8080/api/config' -UseBasicParsing -TimeoutSec 5
                if($config.StatusCode-lt200-or$config.StatusCode-ge400){throw 'OpenWebUI nicht bereit'}
            }catch{
                Write-Host 'OpenWebUI-Erstanmeldung oder Dienst nicht bereit; Transaktion wird ohne API-Schlüssel als WaitingForUserAction fortgesetzt.' -ForegroundColor Yellow
            }
            if($null-ne$config){$apiToken=Read-Host 'Temporären OpenWebUI-Administrator-API-Key eingeben' -AsSecureString}
        }
        $result=Invoke-KIStackCompleteInstaller -Mode Upgrade -PackageRoot $PSScriptRoot -TargetRoot 'C:\KI-Stack' -TransactionId $TransactionId -Resume:$Resume -OpenWebUIApiToken $apiToken
        $json=$result|ConvertTo-Json -Depth 100
        [IO.File]::WriteAllText($LogPath,$json+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
        Write-Output $json
        $exitCode=0
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
    Write-Error -ErrorRecord $_
    $exitCode=1
}finally{
    if($transcriptStarted){Stop-Transcript|Out-Null}
    if((Test-Path -LiteralPath $stderrPath -PathType Leaf)-and(Get-Item -LiteralPath $stderrPath).Length-eq0){
        [IO.File]::WriteAllText($stderrPath,"No stderr output.`r`n",[Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText($exitPath,[string]$exitCode+[Environment]::NewLine,[Text.Encoding]::ASCII)
}
exit $exitCode

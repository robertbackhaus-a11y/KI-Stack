[CmdletBinding()]
param(
    [switch]$Resume,
    [string]$TransactionId,
    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-KICompleteAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-KICompleteElevated {
    param([string]$ScriptPath,[switch]$Resume,[string]$TransactionId)
    $pwsh = if(Test-Path "$env:ProgramFiles\PowerShell\7\pwsh.exe"){"$env:ProgramFiles\PowerShell\7\pwsh.exe"}else{(Get-Command pwsh.exe -ErrorAction Stop).Source}
    $arguments = [Collections.Generic.List[string]]::new()
    foreach($item in @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$ScriptPath,'-Elevated')){$arguments.Add($item)}
    if($Resume){$arguments.Add('-Resume')}
    if($TransactionId){$arguments.Add('-TransactionId');$arguments.Add($TransactionId)}
    $process = Start-Process -FilePath $pwsh -ArgumentList $arguments -Verb RunAs -Wait -PassThru -ErrorAction Stop
    exit $process.ExitCode
}

if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw 'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}
if(-not(Test-KICompleteAdministrator)){
    if($Elevated){throw 'Die UAC-Elevation wurde abgebrochen oder war nicht wirksam.'}
    Start-KICompleteElevated -ScriptPath $PSCommandPath -Resume:$Resume -TransactionId $TransactionId
}
if($Resume-and[string]::IsNullOrWhiteSpace($TransactionId)){throw 'Resume erfordert eine TransactionId.'}

Import-Module (Join-Path $PSScriptRoot 'CompleteInstaller.psm1') -Force
$plan=New-KICompletePlan -Mode Upgrade -PackageRoot $PSScriptRoot -TargetRoot 'C:\KI-Stack'
$needsOpenWebUI=@($plan.steps|Where-Object{$_.id-in@('openwebui-agent-pack','openwebui-image-pack')-and$_.plannedMode-ne'Skip'})
$apiToken=$null
try {
    if($needsOpenWebUI.Count){
        $config=$null
        try{$config=Invoke-WebRequest -Uri 'http://127.0.0.1:8080/api/config' -UseBasicParsing -TimeoutSec 5;if($config.StatusCode-lt200-or$config.StatusCode-ge400){throw 'OpenWebUI nicht bereit'}}catch{
            Write-Host 'OpenWebUI-Erstanmeldung oder Dienst nicht bereit; Transaktion wird ohne API-Schlüssel als WaitingForUserAction fortgesetzt.' -ForegroundColor Yellow
        }
        if($null-ne$config){$apiToken=Read-Host 'Temporären OpenWebUI-Administrator-API-Key eingeben' -AsSecureString}
    }
    Invoke-KIStackCompleteInstaller -Mode Upgrade -PackageRoot $PSScriptRoot -TargetRoot 'C:\KI-Stack' -TransactionId $TransactionId -Resume:$Resume -OpenWebUIApiToken $apiToken | ConvertTo-Json -Depth 100
}
finally {
    $apiToken=$null
    [GC]::Collect()
    if($needsOpenWebUI.Count){Write-Host 'Temporären OpenWebUI-API-Key in OpenWebUI widerrufen.' -ForegroundColor Yellow}
}

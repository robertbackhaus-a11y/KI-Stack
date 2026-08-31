#Requires -Version 7.0
[CmdletBinding()]
param([string]$Endpoint='',[string]$TargetRoot='C:\KI-Stack',[int]$TimeoutSec=10)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}
Import-Module (Join-Path $PSScriptRoot 'Lifecycle/KIStackOpenWebUICredential.psm1') -Force -DisableNameChecking
$result=Test-KIStackOpenWebUICredential -Endpoint $Endpoint -TargetRoot $TargetRoot -TimeoutSec $TimeoutSec
$result|ConvertTo-Json -Depth 10
if([string]$result.status-ne'Valid'){exit 1}

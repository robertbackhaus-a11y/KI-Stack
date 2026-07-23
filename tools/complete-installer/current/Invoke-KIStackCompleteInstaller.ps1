[CmdletBinding()]
param([ValidateSet('Audit','Install','Upgrade','Repair','Validate','Rollback','Start','Stop')][string]$Mode='Audit',[string]$TargetRoot='C:\KI-Stack',[string]$TransactionId,[switch]$Resume,[switch]$DryRun,[switch]$EnableOpenWebUIBallistics,[Security.SecureString]$OpenWebUIApiToken)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7){throw 'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}
Import-Module (Join-Path $PSScriptRoot 'CompleteInstaller.psm1') -Force
Invoke-KIStackCompleteInstaller -Mode $Mode -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -TransactionId $TransactionId -Resume:$Resume -DryRun:$DryRun -EnableOpenWebUIBallistics:$EnableOpenWebUIBallistics -OpenWebUIApiToken $OpenWebUIApiToken | ConvertTo-Json -Depth 100

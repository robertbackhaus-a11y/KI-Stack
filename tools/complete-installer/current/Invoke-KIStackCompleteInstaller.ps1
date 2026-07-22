[CmdletBinding()]
param([ValidateSet('Audit','Install','Upgrade','Repair','Validate','Rollback','Start','Stop')][string]$Mode='Audit',[string]$TargetRoot='C:\KI-Stack',[string]$TransactionId,[switch]$Resume,[switch]$DryRun)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'CompleteInstaller.psm1') -Force
Invoke-KIStackCompleteInstaller -Mode $Mode -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -TransactionId $TransactionId -Resume:$Resume -DryRun:$DryRun | ConvertTo-Json -Depth 100

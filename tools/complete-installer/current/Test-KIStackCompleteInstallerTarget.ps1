[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot,[string]$TargetRoot='C:\KI-Stack')
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}
Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force
$audit=Invoke-KIStackCompleteInstaller -Mode Audit -PackageRoot $PackageRoot -TargetRoot $TargetRoot
$validate=Invoke-KIStackCompleteInstaller -Mode Validate -PackageRoot $PackageRoot -TargetRoot $TargetRoot
[pscustomobject]@{version='2.1.3';passed=([bool]$validate.health.passed-and[bool]$validate.operations.passed);auditReadOnly=(-not$audit.mutatesTarget);existingInstallation=$true;health=$validate.health;operations=$validate.operations;status='TargetValidated'}|ConvertTo-Json -Depth 30

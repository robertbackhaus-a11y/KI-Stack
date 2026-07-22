[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot,[string]$TargetRoot='C:\KI-Stack')
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force
$audit=Invoke-KIStackCompleteInstaller -Mode Audit -PackageRoot $PackageRoot -TargetRoot $TargetRoot
$validate=Invoke-KIStackCompleteInstaller -Mode Validate -PackageRoot $PackageRoot -TargetRoot $TargetRoot
[pscustomobject]@{version='2.1.1';passed=([bool]$validate.health.passed);auditReadOnly=(-not$audit.mutatesTarget);existingInstallation=$true;health=$validate.health;status='TargetSystemValidatedExistingInstallation'}|ConvertTo-Json -Depth 30

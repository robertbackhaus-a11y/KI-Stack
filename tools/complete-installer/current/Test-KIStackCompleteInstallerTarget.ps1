[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot,[string]$TargetRoot='C:\KI-Stack')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}
Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force
$audit=Invoke-KIStackCompleteInstaller -Mode Audit -PackageRoot $PackageRoot -TargetRoot $TargetRoot
$validate=Invoke-KIStackCompleteInstaller -Mode Validate -PackageRoot $PackageRoot -TargetRoot $TargetRoot
[pscustomobject]@{
    version='2.3.0-rc16'
    passed=([bool]$validate.health.passed-and[bool]$validate.operations.passed)
    auditReadOnly=(-not$audit.mutatesTarget)
    existingInstallation=$true
    health=$validate.health
    operations=$validate.operations
    status=$(if([bool]$validate.health.passed-and[bool]$validate.operations.passed){'TargetValidated'}else{'Failed'})
}|ConvertTo-Json -Depth 30
if(-not[bool]$validate.health.passed-or-not[bool]$validate.operations.passed){exit 1}

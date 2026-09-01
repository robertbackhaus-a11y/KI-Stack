[CmdletBinding()]param([ValidateSet('Audit','DryRun','Install','Upgrade','Repair','Validate','Rollback')][string]$Action='Audit',[string]$TargetRoot='C:\KI-Stack',[string]$BackupPath='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'IntegrationPackage.psm1') -Force
$result = if ($Action -eq 'DryRun') {
    [pscustomobject]@{version='1.5.11';action=$Action;runtimeGitDependency=$false;mutatesTarget=$false;runtimeChain=@('wsl keeper','valkey-server','uwsgi','nginx')}
} elseif ($Action -in @('Audit','Validate')) { Test-IntegrationTarget -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot } elseif($Action-eq'Rollback'){if(-not$BackupPath){throw'BackupPath required'};Restore-IntegrationState $BackupPath}else { Install-IntegrationPayload -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot }
$result | ConvertTo-Json -Depth 20

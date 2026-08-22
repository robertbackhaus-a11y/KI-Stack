[CmdletBinding()]param([ValidateSet('Audit','DryRun','Install','Upgrade','Repair','Validate','Rollback')][string]$Action='Audit',[string]$BackupPath='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'IntegrationPackage.psm1') -Force
$result = if ($Action -eq 'DryRun') {
    [pscustomobject]@{version='1.5.11';action=$Action;runtimeGitDependency=$false;mutatesTarget=$false;runtimeChain=@('wsl keeper','valkey-server','uwsgi','nginx')}
} elseif ($Action -in @('Audit','Validate')) { Test-IntegrationTarget } elseif($Action-eq'Rollback'){if(-not$BackupPath){throw'BackupPath required'};Restore-IntegrationState $BackupPath}else { Install-IntegrationPayload $PSScriptRoot }
$result | ConvertTo-Json -Depth 20

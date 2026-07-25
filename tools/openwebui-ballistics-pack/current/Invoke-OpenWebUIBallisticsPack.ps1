[CmdletBinding()]
param([ValidateSet('DryRun','Execute','Validate','Rollback')][string]$Mode='DryRun',[string]$Endpoint='http://localhost:8080',[Security.SecureString]$ApiToken,[string]$BaseModelId,[string]$BackupPath,[string]$BackupDirectory=(Join-Path $env:TEMP ('KI-Stack-Ballistics-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))))
$ErrorActionPreference='Stop';Import-Module (Join-Path $PSScriptRoot 'OpenWebUIBallisticsPack.psm1') -Force
try {
 if($Mode-eq'DryRun'){$payload=Test-BallisticsPayloads $PSScriptRoot;[pscustomobject]@{version='1.0.0';mode='DryRun';payloads=$payload;profileId='ki-stack-18bravo';toolId='ki_stack_ballistics_calculator';mutatesTarget=$false};exit $(if($payload.passed){0}else{1})}
 if($null-eq$ApiToken){$ApiToken=Read-Host 'Temporären OpenWebUI-Administrator-API-Key eingeben' -AsSecureString}
 if($Mode-eq'Execute'){Install-OpenWebUIBallisticsPack $PSScriptRoot $Endpoint $ApiToken $BaseModelId $BackupDirectory}
 elseif($Mode-eq'Validate'){Test-OpenWebUIBallisticsPack $Endpoint $ApiToken}
 else {if(-not$BackupPath){throw'Rollback erfordert BackupPath.'};Restore-OpenWebUIBallisticsPack $Endpoint $ApiToken $BackupPath}
} finally {$ApiToken=$null;[GC]::Collect()}

[CmdletBinding()]
param([ValidateSet('DryRun','Execute','Validate','Rollback')][string]$Action='DryRun',[string]$Endpoint='http://127.0.0.1:8080',[Security.SecureString]$ApiToken,[string]$BackupPath='')
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop';Import-Module (Join-Path $PSScriptRoot 'OpenWebUIImagePack.psm1') -Force
if($Action-eq'DryRun'){@{version='1.9.1';action='DryRun';managedTool='ki-stack-generate-image';openWebUIToolId='ki_stack_generate_image';managedProfiles=@('ki-stack-it-technik','ki-stack-allgemein');workflow='FLUX2-Klein-9B-OpenWebUI-API-FLAT';modelsDownloaded=$false;mutatesTarget=$false}|ConvertTo-Json -Depth 10;return}
if($null-eq $ApiToken){$ApiToken=Read-Host 'Temporären OpenWebUI API-Key eingeben' -AsSecureString}
try{switch($Action){
 'Execute'{$dir=Join-Path 'C:\KI-Stack\backups\openwebui-image-pack' ('OWUI-IMAGE-PACK-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff'));$r=Install-OpenWebUIImagePack $PSScriptRoot $Endpoint $ApiToken $dir;$v=Test-OpenWebUIImagePack $Endpoint $ApiToken;if(-not$v.passed){throw($v.failures-join'; ')};@{version='1.9.1';action='Execute';passed=$true;backupPath=$r.backupPath;toolAction=$r.toolAction}|ConvertTo-Json}
 'Validate'{$v=Test-OpenWebUIImagePack $Endpoint $ApiToken;$v|ConvertTo-Json;if(-not$v.passed){throw($v.failures-join'; ')}}
 'Rollback'{if([string]::IsNullOrWhiteSpace($BackupPath)){throw'Rollback erfordert BackupPath.'};Restore-OpenWebUIImagePack $Endpoint $ApiToken $BackupPath;@{version='1.9.1';action='Rollback';passed=$true}|ConvertTo-Json}
}}finally{$ApiToken=$null;[GC]::Collect()}

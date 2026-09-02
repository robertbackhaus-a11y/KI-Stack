[CmdletBinding()]
param([ValidateSet('Audit','DryRun','Install','Upgrade','Repair','Validate','Rollback')][string]$Action='Audit',[string]$TargetRoot='C:\KI-Stack\ComfyUI',[string]$BackupPath='',[string]$BackupRoot='C:\KI-Stack\backups\comfyui-1.2.4')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ComfyUIPackage.psm1') -Force
$result = switch ($Action) {
    'Audit' { Test-ComfyTarget $PSScriptRoot $TargetRoot }
    'DryRun' { [pscustomobject]@{version='1.2.4';action=$Action;runtimeGitDependency=$false;mutatesTarget=$false;target=$TargetRoot} }
    'Validate' { Test-ComfyTarget $PSScriptRoot $TargetRoot }
    'Rollback' { if (-not $BackupPath) { throw 'BackupPath required' }; Restore-ComfyPayload $BackupPath $TargetRoot }
    default { Install-ComfyPayload $PSScriptRoot $TargetRoot $BackupRoot }
}
$result | ConvertTo-Json -Depth 20

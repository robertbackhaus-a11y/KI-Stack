#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Audit','Install','Upgrade','Repair','Validate','Status','ArtifactValidate','Acceptance','Rollback')][string]$Action='Audit',
    [string]$TargetRoot='C:\KI-Stack',
    [string]$WorkspacePath,
    [string]$BackupPath,
    [string]$NodeArchivePath,
    [string]$TestRoot,
    [switch]$KeepTestRoot,
    [switch]$DryRun,
    # SkipEndpoint applies to Audit/Validate: a post-Upgrade/Repair/Install health check must
    # never fail merely because LM Studio (an external runtime prerequisite, not part of this
    # package's own payload) is not reachable at that exact moment -- see Get-KICodexStatus/
    # CodexLocal.psm1 for the Installed vs. RuntimeUnavailable vs. Broken distinction this
    # exists to preserve. Never required for pure package validation.
    [switch]$SkipEndpoint
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexLocal.psm1') -Force
$result=switch($Action){
    'Audit' {Test-KICodexLocal -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -SkipEndpoint:$SkipEndpoint}
    'Validate' {Test-KICodexLocal -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -SkipEndpoint:$SkipEndpoint}
    'Status' {Get-KICodexStatus -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot}
    'Install' {Install-KICodexLocal -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -WorkspacePath $WorkspacePath -Action 'Install' -DryRun:$DryRun -SuppliedNodeArchive $NodeArchivePath}
    'Upgrade' {Install-KICodexLocal -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -WorkspacePath $WorkspacePath -Action 'Upgrade' -DryRun:$DryRun -SuppliedNodeArchive $NodeArchivePath}
    'Repair' {Install-KICodexLocal -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -WorkspacePath $WorkspacePath -Action 'Repair' -DryRun:$DryRun -SuppliedNodeArchive $NodeArchivePath}
    'ArtifactValidate' {Test-KICodexArtifact -PackageRoot $PSScriptRoot -NodeArchivePath $NodeArchivePath -TestRoot $TestRoot -KeepTestRoot:$KeepTestRoot}
    'Acceptance' {Invoke-KICodexAnalysisAcceptance -PackageRoot $PSScriptRoot -WorkspacePath $WorkspacePath}
    'Rollback' {Restore-KICodexLocal -BackupPath $BackupPath -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot}
}
$result|ConvertTo-Json -Depth 100
if(-not[bool]$result.passed){exit 1}

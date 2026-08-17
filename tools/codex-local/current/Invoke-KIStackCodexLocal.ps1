#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Audit','Install','Validate','ArtifactValidate','Acceptance','Rollback')][string]$Action='Audit',
    [string]$TargetRoot='C:\KI-Stack',
    [string]$WorkspacePath,
    [string]$BackupPath,
    [string]$NodeArchivePath,
    [string]$TestRoot,
    [switch]$KeepTestRoot,
    [switch]$DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexLocal.psm1') -Force
$result=switch($Action){
    'Audit' {Test-KICodexLocal -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot}
    'Validate' {Test-KICodexLocal -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot}
    'Install' {Install-KICodexLocal -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -WorkspacePath $WorkspacePath -DryRun:$DryRun -SuppliedNodeArchive $NodeArchivePath}
    'ArtifactValidate' {Test-KICodexArtifact -PackageRoot $PSScriptRoot -NodeArchivePath $NodeArchivePath -TestRoot $TestRoot -KeepTestRoot:$KeepTestRoot}
    'Acceptance' {Invoke-KICodexAnalysisAcceptance -PackageRoot $PSScriptRoot -WorkspacePath $WorkspacePath}
    'Rollback' {Restore-KICodexLocal -BackupPath $BackupPath -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot}
}
$result|ConvertTo-Json -Depth 100
if(-not[bool]$result.passed){exit 1}

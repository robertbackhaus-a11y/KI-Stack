#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Install', 'Upgrade', 'Repair', 'Validate', 'Status', 'Start', 'Stop', 'Rollback', 'Register', 'Unregister', 'RegistrationStatus', 'Uninstall')][string]$Action = 'Audit',
    [string]$TargetRoot = 'C:\KI-Stack',
    [string]$BackupPath,
    # Optional, transaction-bound backup root for Install/Upgrade/Repair (mirrors Desktop
    # Control's own 2.18.1 hotfix, Invoke-KIStackDesktopControl.ps1's -BackupRoot). When set,
    # Install-KIMcpRuntime creates its backup exclusively under this root instead of its own
    # standalone <TargetRoot>\backups\mcp-runtime\<timestamp> scheme -- so a caller that owns its
    # own recovery contract (the Complete Installer's transaction-scoped BackupRoot) gets a
    # BackupPath its own recovery logic actually accepts. Omitted => unchanged standalone behavior.
    [string]$BackupRoot,
    [string]$OpenWebUIEndpoint,
    [switch]$DryRun,
    [switch]$SkipUvCheck
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'McpRuntime.psm1') -Force
$result = switch ($Action) {
    'Audit' { Test-KIMcpRuntime -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -SkipUvCheck:$SkipUvCheck }
    'Validate' { Test-KIMcpRuntime -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -SkipUvCheck:$SkipUvCheck }
    'Status' { Get-KIMcpRuntimeStatus -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot }
    'Install' { Install-KIMcpRuntime -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -Action 'Install' -BackupRoot $BackupRoot -DryRun:$DryRun -SkipUvCheck:$SkipUvCheck }
    'Upgrade' { Install-KIMcpRuntime -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -Action 'Upgrade' -BackupRoot $BackupRoot -DryRun:$DryRun -SkipUvCheck:$SkipUvCheck }
    'Repair' { Install-KIMcpRuntime -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -Action 'Repair' -BackupRoot $BackupRoot -DryRun:$DryRun -SkipUvCheck:$SkipUvCheck }
    'Start' { Start-KIMcpRuntime -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot }
    'Stop' { Stop-KIMcpRuntime -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot }
    'Rollback' { Restore-KIMcpRuntime -BackupPath $BackupPath -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot }
    'Register' { Register-KIMcpRuntimeOpenWebUI -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -OpenWebUIEndpoint $OpenWebUIEndpoint }
    'Unregister' { Unregister-KIMcpRuntimeOpenWebUI -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -OpenWebUIEndpoint $OpenWebUIEndpoint }
    'RegistrationStatus' { Test-KIMcpRuntimeOpenWebUIRegistration -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -OpenWebUIEndpoint $OpenWebUIEndpoint }
    'Uninstall' { Uninstall-KIMcpRuntime -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot }
}
$result | ConvertTo-Json -Depth 50
if (-not [bool]$result.passed) { exit 1 }

#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Install', 'Upgrade', 'Repair', 'Validate', 'Status', 'Start', 'Stop', 'Rollback', 'Register', 'Unregister', 'RegistrationStatus', 'Uninstall')][string]$Action = 'Audit',
    [string]$TargetRoot = 'C:\KI-Stack',
    [string]$BackupPath,
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
    'Install' { Install-KIMcpRuntime -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -Action 'Install' -DryRun:$DryRun -SkipUvCheck:$SkipUvCheck }
    'Upgrade' { Install-KIMcpRuntime -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -Action 'Upgrade' -DryRun:$DryRun -SkipUvCheck:$SkipUvCheck }
    'Repair' { Install-KIMcpRuntime -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -Action 'Repair' -DryRun:$DryRun -SkipUvCheck:$SkipUvCheck }
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

#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Install', 'Upgrade', 'Repair', 'Validate', 'Status', 'Start', 'Stop', 'Rollback')][string]$Action = 'Audit',
    [string]$TargetRoot = 'C:\KI-Stack',
    [string]$BackupPath,
    [switch]$DryRun,
    [switch]$SkipUvCheck
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OpenTerminal.psm1') -Force
$result = switch ($Action) {
    'Audit' { Test-KIOpenTerminal -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -SkipUvCheck:$SkipUvCheck }
    'Validate' { Test-KIOpenTerminal -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -SkipUvCheck:$SkipUvCheck }
    'Status' { Get-KIOpenTerminalStatus -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot }
    'Install' { Install-KIOpenTerminal -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -Action 'Install' -DryRun:$DryRun -SkipUvCheck:$SkipUvCheck }
    'Upgrade' { Install-KIOpenTerminal -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -Action 'Upgrade' -DryRun:$DryRun -SkipUvCheck:$SkipUvCheck }
    'Repair' { Install-KIOpenTerminal -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -Action 'Repair' -DryRun:$DryRun -SkipUvCheck:$SkipUvCheck }
    'Start' { Start-KIOpenTerminal -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot }
    'Stop' { Stop-KIOpenTerminal -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot }
    'Rollback' { Restore-KIOpenTerminal -BackupPath $BackupPath -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot }
}
$result | ConvertTo-Json -Depth 50
if (-not [bool]$result.passed) { exit 1 }

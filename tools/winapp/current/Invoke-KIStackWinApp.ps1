#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Install', 'Upgrade', 'Repair', 'Validate', 'Status', 'Resolve', 'Rollback')][string]$Action = 'Audit',
    [string]$TargetRoot = 'C:\KI-Stack',
    [string]$BackupPath,
    [switch]$DryRun
)
# Operator / Complete-Installer entry point. Deliberately exposes NO test/development seams:
# no -SkipVersionProbe, -SkipChecksumVerification, -AllowDevelopmentFallback,
# -ArtifactFileOverride, -SourceManifestOverride or -VersionProbeOverride. Every real run
# downloads from the pinned URL, verifies size+SHA256, extracts the full package and runs
# `winapp.exe --version`. Those seams live only on the module functions and are used only by
# tools/winapp/current/Test-KIStackWinApp.ps1.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WinApp.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WinApp.Resolver.psm1') -Force
$result = switch ($Action) {
    'Audit' { Test-KIWinApp -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot }
    'Validate' { Test-KIWinApp -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot }
    'Status' { Get-KIWinAppStatus -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot }
    'Install' { Install-KIWinApp -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -Action 'Install' -DryRun:$DryRun }
    'Upgrade' { Install-KIWinApp -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -Action 'Upgrade' -DryRun:$DryRun }
    'Repair' { Install-KIWinApp -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -Action 'Repair' -DryRun:$DryRun }
    'Resolve' { Resolve-KIStackWinApp -KIStackRoot $TargetRoot }
    'Rollback' { Restore-KIWinApp -BackupPath $BackupPath -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot }
}
$result | ConvertTo-Json -Depth 50
$ok = ($null -ne $result) -and (
    ($result.PSObject.Properties['passed'] -and [bool]$result.passed) -or
    ($result.PSObject.Properties['resolved'] -and [bool]$result.resolved)
)
if (-not $ok) { exit 1 }

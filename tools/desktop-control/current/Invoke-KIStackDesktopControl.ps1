#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Lifecycle')]
param(
    # Component lifecycle / self-check + Complete-Installer isolated-execution entry point.
    [Parameter(ParameterSetName = 'Lifecycle')]
    [ValidateSet('Audit', 'Validate', 'Status', 'Install', 'Upgrade', 'Repair', 'Rollback')][string]$Action = 'Audit',

    # A single semantic UIA operation. This is the surface a Desktop-Control tool would call.
    [Parameter(ParameterSetName = 'Operation', Mandatory)]
    [ValidateSet('list_windows', 'inspect_window', 'find_element', 'get_properties', 'get_value', 'screenshot', 'wait_for', 'set_value', 'invoke', 'focus', 'scroll_into_view', 'scroll')]
    [string]$Operation,

    # Operation parameters as one JSON object: { application, hwnd, titlePattern, expectedProcessName,
    # element: { automationId, name, controlType, className, selector }, value, timeoutMs, expectTreeChange }.
    [Parameter(ParameterSetName = 'Operation')][string]$RequestJson = '{}',

    [string]$TargetRoot = 'C:\KI-Stack',
    [string]$KIStackRoot,
    [Parameter(ParameterSetName = 'Lifecycle')][string]$BackupPath,
    # Optional, transaction-bound backup root for Install/Upgrade/Repair (2.18.1 hotfix). When set,
    # Install-KIDesktopControl creates its backup exclusively under this root instead of its own
    # standalone <TargetRoot>\backups\desktop-control\<timestamp> scheme -- so a caller that owns
    # its own recovery contract (the Complete Installer's transaction-scoped BackupRoot) gets a
    # BackupPath its own recovery logic actually accepts. Omitted => unchanged standalone behavior.
    [Parameter(ParameterSetName = 'Lifecycle')][string]$BackupRoot,
    [Parameter(ParameterSetName = 'Lifecycle')][switch]$DryRun
)
# Operator / Complete-Installer entry point. Exposes ONLY the semantic operation set plus the
# component lifecycle. It deliberately carries NO test/development seams: no -SkipResolverProbe,
# -AllowDevelopmentFallback, -VersionProbeOverride, -WinAppInvokerOverride, -Internal_* or
# -SourceManifestOverride/-ArtifactFileOverride, and NO raw-winapp / send-input /
# coordinate-click operation. Audit/Validate/Status ALWAYS probe the real central WinApp
# resolver. The LLM never runs winapp directly. A resolver skip exists only as an internal
# module seam used by tools/desktop-control/current/Test-KIStackDesktopControl.ps1.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DesktopControl.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DesktopControl.Policy.psm1') -Force

# TargetRoot-parametric: when the KI-Stack root is not given explicitly it follows TargetRoot,
# never a hardcoded C:\KI-Stack in an internal function.
if ([string]::IsNullOrWhiteSpace($KIStackRoot)) { $KIStackRoot = $TargetRoot }

if ($PSCmdlet.ParameterSetName -eq 'Operation') {
    $result = Invoke-KIDesktopControlOperation -Operation $Operation -Request $RequestJson -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -KIStackRoot $KIStackRoot
} else {
    $result = switch ($Action) {
        'Audit' { Test-KIDesktopControl -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -KIStackRoot $KIStackRoot }
        'Validate' { Test-KIDesktopControl -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -KIStackRoot $KIStackRoot }
        'Status' { Get-KIDesktopControlStatus -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -KIStackRoot $KIStackRoot }
        'Install' { Install-KIDesktopControl -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -Action 'Install' -BackupRoot $BackupRoot -DryRun:$DryRun }
        'Upgrade' { Install-KIDesktopControl -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -Action 'Upgrade' -BackupRoot $BackupRoot -DryRun:$DryRun }
        'Repair' { Install-KIDesktopControl -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -Action 'Repair' -BackupRoot $BackupRoot -DryRun:$DryRun }
        'Rollback' { Restore-KIDesktopControl -BackupPath $BackupPath -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot }
    }
}

$result | ConvertTo-Json -Depth 60
$ok = ($null -ne $result) -and (
    ($result.PSObject.Properties['passed'] -and [bool]$result.passed) -or
    ($result.PSObject.Properties['success'] -and [bool]$result.success)
)
if (-not $ok) { exit 1 }

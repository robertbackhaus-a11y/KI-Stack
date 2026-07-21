[CmdletBinding()]
param(
    [Parameter()]
    [string]$InstallRoot = 'C:\KI-Stack\Tools\PackageValidationGate'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $pwsh = (Get-Process -Id $PID).Path
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwsh
    $psi.WorkingDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $psi.UseShellExecute = $true
    $psi.Verb = 'runas'
    foreach ($argument in @('-NoProfile','-ExecutionPolicy','Bypass','-File',$MyInvocation.MyCommand.Path,'-InstallRoot',$InstallRoot)) {
        $null = $psi.ArgumentList.Add([string]$argument)
    }
    $process = [System.Diagnostics.Process]::Start($psi)
    $process.WaitForExit()
    exit $process.ExitCode
}

$source = Split-Path -Parent $MyInvocation.MyCommand.Path
$version = (Get-Content -LiteralPath (Join-Path $source 'VERSION') -Raw).Trim()
$versionTarget = Join-Path $InstallRoot $version
$currentTarget = Join-Path $InstallRoot 'current'
$tempTarget = "$versionTarget.partial.$([guid]::NewGuid().ToString('N'))"

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
Copy-Item -LiteralPath $source -Destination $tempTarget -Recurse -Force

$manifest = Join-Path $tempTarget 'SHA256SUMS.txt'
$expected = @{}
foreach ($line in Get-Content -LiteralPath $manifest) {
    if ($line -match '^([0-9a-fA-F]{64})\s+\*(.+)$') { $expected[$Matches[2]] = $Matches[1].ToLowerInvariant() }
}
$failures = [System.Collections.Generic.List[string]]::new()
foreach ($rel in $expected.Keys) {
    $path = Join-Path $tempTarget $rel
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $failures.Add("missing: $rel"); continue }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected[$rel]) { $failures.Add("hash: $rel") }
}
if ($failures.Count -gt 0) {
    Remove-Item -LiteralPath $tempTarget -Recurse -Force -ErrorAction SilentlyContinue
    throw "Installationsintegrität fehlgeschlagen: $($failures -join ' | ')"
}

if (Test-Path -LiteralPath $versionTarget) { Remove-Item -LiteralPath $versionTarget -Recurse -Force }
Move-Item -LiteralPath $tempTarget -Destination $versionTarget
if (Test-Path -LiteralPath $currentTarget) { Remove-Item -LiteralPath $currentTarget -Recurse -Force }
Copy-Item -LiteralPath $versionTarget -Destination $currentTarget -Recurse -Force

Write-Host "Validation Gate installiert: $currentTarget"
Write-Host "Version: $version"
exit 0

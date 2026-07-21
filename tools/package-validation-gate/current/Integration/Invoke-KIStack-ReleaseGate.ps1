[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$FinalZipPath,

    [Parameter()]
    [string]$GateRoot = 'C:\KI-Stack\Tools\PackageValidationGate\current',

    [Parameter()]
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $GateRoot -PathType Container)) {
    throw "Installiertes Validation Gate nicht gefunden: $GateRoot"
}
Import-Module (Join-Path $GateRoot 'Core\KIStack.ValidationGate.Core.psm1') -Force
$entry = Join-Path $GateRoot 'Invoke-KIStack-PackageValidationGate.ps1'
if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
    throw "Validation-Gate-Einstieg fehlt: $entry"
}
$zipFull = (Resolve-Path -LiteralPath $FinalZipPath).Path
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Split-Path -Parent $zipFull
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$outputFull = (Resolve-Path -LiteralPath $OutputDirectory).Path

$pwsh = Resolve-KIStackPwsh7
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("KIStack-ReleaseGate-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
    $stdout = Join-Path $temp 'stdout.txt'
    $stderr = Join-Path $temp 'stderr.txt'
    $result = Invoke-KIStackProcess -FilePath $pwsh -ArgumentList @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$entry,
        '-PackagePath',$zipFull,'-OutputDirectory',$outputFull
    ) -WorkingDirectory $GateRoot -StdOutPath $stdout -StdErrPath $stderr -TimeoutSeconds 3600
    if ($result.ExitCode -ne 0) {
        throw "Release Gate hat das Paket abgewiesen. Exitcode=$($result.ExitCode); STDOUT=$($result.StdOut); STDERR=$($result.StdErr)"
    }
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

$baseName = [System.IO.Path]::GetFileNameWithoutExtension($zipFull)
$reportPath = Join-Path $outputFull "$baseName.VALIDATION-REPORT.json"
if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
    throw "Release-Gate-Bericht fehlt: $reportPath"
}
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 100
if ($report.status -ne 'NATIVE_PACKAGE_VALIDATION_PASSED') {
    throw "Paketstatus reicht nicht für eine Freigabe: $($report.status)"
}
Write-Host "Release Gate bestanden: $reportPath"
return

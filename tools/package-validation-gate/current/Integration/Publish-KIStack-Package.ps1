[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [Parameter(Mandatory)][string]$FinalZipPath,
    [Parameter()][string]$GateRoot = 'C:\KI-Stack\Tools\PackageValidationGate\current'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $PackageRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $root 'Validation\VALIDATION-CONTRACT.json') -PathType Leaf)) {
    throw 'Validation/VALIDATION-CONTRACT.json fehlt.'
}
if (-not (Test-Path -LiteralPath (Join-Path $root 'VERSION') -PathType Leaf)) {
    throw 'VERSION fehlt.'
}
if (-not (Test-Path -LiteralPath $GateRoot -PathType Container)) {
    throw "Validation Gate fehlt: $GateRoot"
}

$manifestPath = Join-Path $root 'SHA256SUMS.txt'
$manifestLines = [System.Collections.Generic.List[string]]::new()
Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.FullName -ne $manifestPath } | Sort-Object FullName | ForEach-Object {
    $rel = [System.IO.Path]::GetRelativePath($root, $_.FullName).Replace('\','/')
    $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifestLines.Add("$hash *$rel")
}
[System.IO.File]::WriteAllText($manifestPath, (($manifestLines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))

$finalFull = [System.IO.Path]::GetFullPath($FinalZipPath)
$outputDir = Split-Path -Parent $finalFull
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$staging = Join-Path $outputDir ('.validation-staging-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging -Force | Out-Null
$stagedZip = Join-Path $staging ([System.IO.Path]::GetFileName($finalFull))

try {
    Compress-Archive -LiteralPath $root -DestinationPath $stagedZip -CompressionLevel Optimal
    $digest = (Get-FileHash -LiteralPath $stagedZip -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText("$stagedZip.sha256", "$digest *$([System.IO.Path]::GetFileName($stagedZip))`n", [System.Text.UTF8Encoding]::new($false))

    $releaseGate = Join-Path $GateRoot 'Integration\Invoke-KIStack-ReleaseGate.ps1'
    & $releaseGate -FinalZipPath $stagedZip -GateRoot $GateRoot -OutputDirectory $staging

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($stagedZip)
    foreach ($destination in @(
        $finalFull,
        "$finalFull.sha256",
        (Join-Path $outputDir "$baseName.VALIDATION-REPORT.json"),
        (Join-Path $outputDir "$baseName.VALIDATION-REPORT.md"),
        (Join-Path $outputDir "$baseName.STATIC-VALIDATION.json")
    )) {
        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
    }
    Move-Item -LiteralPath $stagedZip -Destination $finalFull
    Move-Item -LiteralPath "$stagedZip.sha256" -Destination "$finalFull.sha256"
    foreach ($suffix in @('VALIDATION-REPORT.json','VALIDATION-REPORT.md','STATIC-VALIDATION.json')) {
        $sourceReport = Join-Path $staging "$baseName.$suffix"
        if (-not (Test-Path -LiteralPath $sourceReport -PathType Leaf)) { throw "Gate-Bericht fehlt: $sourceReport" }
        Move-Item -LiteralPath $sourceReport -Destination (Join-Path $outputDir "$baseName.$suffix")
    }
    Write-Host "Paket veröffentlicht: $finalFull"
    exit 0
}
catch {
    $rejectedDir = Join-Path $outputDir ('Rejected-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    if (Test-Path -LiteralPath $staging) { Move-Item -LiteralPath $staging -Destination $rejectedDir -Force }
    throw "Paket wurde nicht veröffentlicht: $($_.Exception.Message). Diagnose: $rejectedDir"
}
finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
}

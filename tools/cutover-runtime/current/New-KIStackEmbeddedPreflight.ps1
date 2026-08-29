[CmdletBinding()]
param(
    [string]$ProjectRoot = $PSScriptRoot,
    [string]$DestinationPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$sourceRoot = Join-Path $ProjectRoot 'Embedded\Preflight\Source'
if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
    $DestinationPath = Join-Path $ProjectRoot 'State\Generated\Preflight-Continuation-v1.6.13.zip'
}
$DestinationPath = [IO.Path]::GetFullPath($DestinationPath)

$required = @(
    'install-plan.source.json',
    'preflight-report.json',
    'versions.lock.json'
)
foreach ($relative in $required) {
    $path = Join-Path $sourceRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Getrackte Preflight-Quelle fehlt: $relative"
    }
    Get-Content -LiteralPath $path -Raw |
        ConvertFrom-Json -Depth 100 -ErrorAction Stop |
        Out-Null
}

$destinationDirectory = Split-Path -Parent $DestinationPath
New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
$temporaryPath = Join-Path $destinationDirectory (
    '.{0}.{1}.partial' -f [IO.Path]::GetFileName($DestinationPath),[guid]::NewGuid().ToString('N')
)

Add-Type -AssemblyName System.IO.Compression
$epoch = [DateTimeOffset]::Parse('2000-01-01T00:00:00Z')
$stream = [IO.File]::Open($temporaryPath,[IO.FileMode]::CreateNew)
try {
    $archive = [IO.Compression.ZipArchive]::new(
        $stream,
        [IO.Compression.ZipArchiveMode]::Create,
        $false
    )
    try {
        foreach ($relative in $required | Sort-Object) {
            $entry = $archive.CreateEntry(
                $relative.Replace('\','/'),
                [IO.Compression.CompressionLevel]::Optimal
            )
            $entry.LastWriteTime = $epoch
            $input = [IO.File]::OpenRead((Join-Path $sourceRoot $relative))
            $output = $entry.Open()
            try {
                $input.CopyTo($output)
            }
            finally {
                $output.Dispose()
                $input.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}
finally {
    $stream.Dispose()
}

try {
    [IO.File]::Move($temporaryPath,$DestinationPath,$true)
}
finally {
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
}

[pscustomobject][ordered]@{
    path = $DestinationPath
    sizeBytes = (Get-Item -LiteralPath $DestinationPath).Length
    sha256 = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    generatedFromTrackedSource = $true
}

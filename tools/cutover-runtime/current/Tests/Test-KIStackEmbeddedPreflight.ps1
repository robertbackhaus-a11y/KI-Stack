[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) (
    'KIStack-Cutover-Preflight-' + [guid]::NewGuid().ToString('N')
)
try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $generator = Join-Path $ProjectRoot 'New-KIStackEmbeddedPreflight.ps1'
    $firstPath = Join-Path $fixture 'greenfield.zip'
    $first = & $generator -ProjectRoot $ProjectRoot -DestinationPath $firstPath
    if (-not $first.generatedFromTrackedSource -or -not (Test-Path -LiteralPath $first.path)) {
        throw 'Greenfield preflight generation failed.'
    }
    $secondPath = Join-Path $fixture 'independent.zip'
    $second = & $generator -ProjectRoot $ProjectRoot -DestinationPath $secondPath
    if ($first.sha256 -ne $second.sha256 -or $first.sizeBytes -ne $second.sizeBytes) {
        throw 'Preflight generation is not deterministic.'
    }

    [IO.File]::WriteAllText($firstPath,'stale runtime state',[Text.UTF8Encoding]::new($false))
    $replaced = & $generator -ProjectRoot $ProjectRoot -DestinationPath $firstPath
    if ($replaced.sha256 -ne $second.sha256) {
        throw 'Upgrade replacement did not restore the source-derived preflight.'
    }

    Add-Type -AssemblyName System.IO.Compression
    $archive = [IO.Compression.ZipFile]::OpenRead($firstPath)
    try {
        $names = @($archive.Entries.FullName | Sort-Object)
    }
    finally {
        $archive.Dispose()
    }
    $expected = @(
        'install-plan.source.json',
        'preflight-report.json',
        'versions.lock.json'
    ) | Sort-Object
    if (@(Compare-Object $expected $names).Count -ne 0) {
        throw 'Generated preflight contents differ from the tracked source contract.'
    }
    [pscustomobject]@{
        passed=$true
        tests=4
        cases=@(
            'greenfield-generation',
            'deterministic-independent-generation',
            'upgrade-replaces-stale-runtime-state',
            'resume-source-contract-complete-no-historical-state-required'
        )
        sha256=$second.sha256
        sizeBytes=$second.sizeBytes
    } | ConvertTo-Json -Depth 10
}
finally {
    if (Test-Path -LiteralPath $fixture) {
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}

[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) '_import\openwebui-agent-pack-v1.8.7'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$source = [IO.Path]::GetFullPath($PSScriptRoot)
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$zip = Join-Path $output 'KI-Stack-OpenWebUI-Agent-Pack-v1.8.7.zip'
$sidecar = "$zip.sha256"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Add-Type -AssemblyName System.IO.Compression
$stream = [IO.File]::Open($zip,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    $archive = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try {
        $files = Get-ChildItem -LiteralPath $source -Recurse -File | Sort-Object { [IO.Path]::GetRelativePath($source,$_.FullName).Replace('\','/') }
        foreach ($file in $files) {
            $relative = [IO.Path]::GetRelativePath($source,$file.FullName).Replace('\','/')
            $entry = $archive.CreateEntry($relative,[IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(2026,1,1,0,0,0,[TimeSpan]::Zero)
            $entryStream = $entry.Open()
            try {
                $input = [IO.File]::OpenRead($file.FullName)
                try { $input.CopyTo($entryStream) } finally { $input.Dispose() }
            }
            finally { $entryStream.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}
finally { $stream.Dispose() }
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $sidecar -Value "$hash *$(Split-Path -Leaf $zip)" -Encoding ASCII
[ordered]@{ zip=$zip; sha256=$hash; sidecar=$sidecar } | ConvertTo-Json

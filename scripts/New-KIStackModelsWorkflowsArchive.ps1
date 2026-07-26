[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repositoryRoot 'tools\models-workflows\current'
$version = (Get-Content -LiteralPath (Join-Path $source 'VERSION') -Raw).Trim()
$name = "KI-Stack-Visual-Models-Workflows-v$version"
$zip = Join-Path $OutputDirectory ($name + '.zip')
$sumPath = Join-Path $source 'SHA256SUMS.txt'

$lines = Get-ChildItem -LiteralPath $source -Recurse -File |
    Where-Object { $_.FullName -ne $sumPath } |
    Sort-Object { [IO.Path]::GetRelativePath($source,$_.FullName).Replace('\','/') } |
    ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($source,$_.FullName).Replace('\','/')
        "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) *$relative"
    }
[IO.File]::WriteAllLines($sumPath,$lines,[Text.ASCIIEncoding]::new())

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Add-Type -AssemblyName System.IO.Compression
$stream = [IO.File]::Open($zip,[IO.FileMode]::CreateNew)
try {
    $archive = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File |
            Sort-Object { [IO.Path]::GetRelativePath($source,$_.FullName).Replace('\','/') }) {
            $relative = [IO.Path]::GetRelativePath($source,$file.FullName).Replace('\','/')
            $entry = $archive.CreateEntry("$name/$relative",[IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::Parse('2000-01-01T00:00:00Z')
            $input = [IO.File]::OpenRead($file.FullName)
            $output = $entry.Open()
            try { $input.CopyTo($output) }
            finally { $output.Dispose(); $input.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}
finally { $stream.Dispose() }
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($zip + '.sha256',"$hash *$([IO.Path]::GetFileName($zip))`r`n",[Text.ASCIIEncoding]::new())
[pscustomobject]@{ zip=$zip; sizeBytes=(Get-Item -LiteralPath $zip).Length; sha256=$hash; source=$source }

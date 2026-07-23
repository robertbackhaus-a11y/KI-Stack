[CmdletBinding()]param([string]$OutputDirectory=(Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) '_import\openwebui-image-pack-v1.9.2'))
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop';$source=[IO.Path]::GetFullPath($PSScriptRoot);$output=[IO.Path]::GetFullPath($OutputDirectory);New-Item -ItemType Directory $output -Force|Out-Null
$zip=Join-Path $output 'KI-Stack-OpenWebUI-Image-Pack-v1.9.2.zip';$sidecar="$zip.sha256";if(Test-Path $zip){Remove-Item $zip -Force}
Add-Type -AssemblyName System.IO.Compression;$stream=[IO.File]::Open($zip,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{$archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true);try{Get-ChildItem $source -Recurse -File|Sort-Object{[IO.Path]::GetRelativePath($source,$_.FullName).Replace('\','/')}|ForEach-Object{$relative=[IO.Path]::GetRelativePath($source,$_.FullName).Replace('\','/');$entry=$archive.CreateEntry($relative,[IO.Compression.CompressionLevel]::Optimal);$entry.LastWriteTime=[DateTimeOffset]::new(2026,1,1,0,0,0,[TimeSpan]::Zero);$es=$entry.Open();try{$input=[IO.File]::OpenRead($_.FullName);try{$input.CopyTo($es)}finally{$input.Dispose()}}finally{$es.Dispose()}}}finally{$archive.Dispose()}}finally{$stream.Dispose()}
$hash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant();Set-Content $sidecar "$hash *$(Split-Path -Leaf $zip)" -Encoding ASCII
$repositoryRoot=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$sbom=Join-Path $output 'KI-Stack-OpenWebUI-Image-Pack-v1.9.2.spdx.json'
& (Join-Path $repositoryRoot 'scripts\New-KIStackSpdxSbom.ps1') -PackageName 'KI-Stack OpenWebUI Image Pack' -PackageVersion '1.9.2' -ZipPath $zip -OutputPath $sbom -ModelsManifestPath (Join-Path $repositoryRoot 'package\Manifests\models.manifest.json')|Out-Null
@{zip=$zip;sha256=$hash;sidecar=$sidecar;sbom=$sbom}|ConvertTo-Json

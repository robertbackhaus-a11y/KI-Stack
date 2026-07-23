[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][hashtable]$PayloadFiles)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
$stage=Join-Path $OutputDirectory 'KI-Stack-Complete-Installer-v2.2.6'
if(Test-Path $stage){Remove-Item $stage -Recurse -Force}
New-Item $stage -ItemType Directory -Force|Out-Null
Get-ChildItem $PSScriptRoot -Force|Where-Object{$_.Name-ne'SHA256SUMS.txt'}|Copy-Item -Destination $stage -Recurse
$repositoryRoot=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$documentationRoot=Join-Path $repositoryRoot 'docs'
$documentationStage=Join-Path $stage 'Documentation'
New-Item $documentationStage -ItemType Directory -Force|Out-Null
foreach($relative in @('en/KI-Stack-Technical-Documentation.md','de/KI-Stack-Technische-Dokumentation.md','en/KI-Stack-Operations-and-User-Guide.md','de/KI-Stack-Betriebs-und-Benutzerhandbuch.md')){
    Copy-Item -LiteralPath (Join-Path $documentationRoot $relative) -Destination (Join-Path $documentationStage (Split-Path $relative -Leaf))
}
foreach($name in @('LICENSE','NOTICE','THIRD_PARTY_NOTICES.md','MODEL_LICENSES.md')){Copy-Item -LiteralPath (Join-Path $repositoryRoot $name) -Destination (Join-Path $stage $name)}
$payloadRoot=Join-Path $stage 'Payload';New-Item $payloadRoot -ItemType Directory -Force|Out-Null
foreach($name in ($PayloadFiles.Keys|Sort-Object)){$source=[string]$PayloadFiles[$name];if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw"Payload fehlt: $name"};$dest=Join-Path $payloadRoot $name;New-Item $dest -ItemType Directory -Force|Out-Null;Copy-Item -LiteralPath $source -Destination $dest}
$files=Get-ChildItem $stage -Recurse -File|Sort-Object{[IO.Path]::GetRelativePath($stage,$_.FullName).Replace('\','/')}
$lines=$files|ForEach-Object{$rel=[IO.Path]::GetRelativePath($stage,$_.FullName).Replace('\','/');"$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) *$rel"}
Set-Content (Join-Path $stage 'SHA256SUMS.txt') $lines -Encoding ASCII
New-Item $OutputDirectory -ItemType Directory -Force|Out-Null
$zip=Join-Path $OutputDirectory 'KI-Stack-Complete-Installer-v2.2.6.zip';if(Test-Path $zip){Remove-Item $zip -Force}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$epoch=[DateTimeOffset]::Parse('2000-01-01T00:00:00Z')
$stream=[IO.File]::Open($zip,[IO.FileMode]::CreateNew)
try{$archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false);try{foreach($file in Get-ChildItem $stage -Recurse -File|Sort-Object FullName){$rel=[IO.Path]::GetRelativePath((Split-Path $stage -Parent),$file.FullName).Replace('\','/');$entry=$archive.CreateEntry($rel,[IO.Compression.CompressionLevel]::Optimal);$entry.LastWriteTime=$epoch;$input=[IO.File]::OpenRead($file.FullName);$output=$entry.Open();try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}}}finally{$archive.Dispose()}}finally{$stream.Dispose()}
$hash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant();Set-Content "$zip.sha256" "$hash *$(Split-Path -Leaf $zip)" -Encoding ASCII
$sbom=Join-Path $OutputDirectory 'KI-Stack-Complete-Installer-v2.2.6.spdx.json'
& (Join-Path $repositoryRoot 'scripts\New-KIStackSpdxSbom.ps1') -PackageName 'KI-Stack Complete Installer' -PackageVersion '2.2.6' -ZipPath $zip -OutputPath $sbom -ModelsManifestPath (Join-Path $repositoryRoot 'package\Manifests\models.manifest.json') -ComponentsPath (Join-Path $PSScriptRoot 'Contracts\COMPONENTS.json')|Out-Null
[pscustomobject]@{zip=$zip;sizeBytes=(Get-Item $zip).Length;sha256=$hash;sbom=$sbom;payloads=$PayloadFiles.Keys|Sort-Object}

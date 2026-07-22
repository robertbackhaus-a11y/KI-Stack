[CmdletBinding()]
param(
    [string]$OutputDirectory=(Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) '_import\comfyui-v1.2.2'),
    [string]$PayloadDirectory=(Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) '_import\git-free-payloads')
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$contract=Get-Content (Join-Path $PSScriptRoot 'Payload/PAYLOAD-CONTRACT.json') -Raw|ConvertFrom-Json
$payload=Join-Path $PayloadDirectory $contract.fileName
$manifest=Join-Path $PayloadDirectory 'COMFYUI-CONTENT-MANIFEST.json'
if (-not(Test-Path $payload) -or (Get-Item $payload).Length-ne$contract.sizeBytes -or (Get-FileHash $payload -Algorithm SHA256).Hash.ToLowerInvariant()-ne$contract.sha256){throw'ComfyUI payload contract mismatch'}
if(-not(Test-Path $manifest)){throw'ComfyUI content manifest missing'}
$stage=Join-Path $env:TEMP ('comfy-package-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $stage|Out-Null
try{
    Get-ChildItem $PSScriptRoot -Force|Where-Object{$_.Name-ne'SHA256SUMS.txt'}|Copy-Item -Destination $stage -Recurse
    New-Item -ItemType Directory (Join-Path $stage 'Payload') -Force|Out-Null
    Copy-Item $payload (Join-Path $stage 'Payload') -Force;Copy-Item $manifest (Join-Path $stage 'Payload/CONTENT-MANIFEST.json') -Force
    $lines=Get-ChildItem $stage -Recurse -File|Sort-Object{[IO.Path]::GetRelativePath($stage,$_.FullName).Replace('\','/')}|ForEach-Object{$relative=[IO.Path]::GetRelativePath($stage,$_.FullName).Replace('\','/');"$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) *$relative"}
    Set-Content (Join-Path $stage 'SHA256SUMS.txt') $lines -Encoding ASCII
    New-Item -ItemType Directory $OutputDirectory -Force|Out-Null;$zip=Join-Path $OutputDirectory 'KI-Stack-ComfyUI-Execute-v1.2.2.zip';if(Test-Path $zip){Remove-Item $zip -Force}
    Add-Type -AssemblyName System.IO.Compression;$stream=[IO.File]::Open($zip,[IO.FileMode]::CreateNew)
    try{$archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true);try{foreach($file in(Get-ChildItem $stage -Recurse -File|Sort-Object{[IO.Path]::GetRelativePath($stage,$_.FullName).Replace('\','/')})){$relative=[IO.Path]::GetRelativePath($stage,$file.FullName).Replace('\','/');$entry=$archive.CreateEntry($relative,[IO.Compression.CompressionLevel]::Optimal);$entry.LastWriteTime=[DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero);$entryStream=$entry.Open();try{$input=[IO.File]::OpenRead($file.FullName);try{$input.CopyTo($entryStream)}finally{$input.Dispose()}}finally{$entryStream.Dispose()}}}finally{$archive.Dispose()}}finally{$stream.Dispose()}
    $hash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant();Set-Content "$zip.sha256" "$hash *$(Split-Path -Leaf $zip)" -Encoding ASCII
    [ordered]@{zip=$zip;sha256=$hash;sidecar="$zip.sha256"}|ConvertTo-Json
}finally{Remove-Item $stage -Recurse -Force}

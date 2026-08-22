[CmdletBinding()]
param(
    [string]$OutputDirectory=(Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) '_import\integration-v1.5.11'),
    [string]$CacheDirectory=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$stage=Join-Path $env:TEMP ('integration-package-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $stage|Out-Null
try{
    Get-ChildItem $PSScriptRoot -Force|Where-Object{$_.Name-ne'SHA256SUMS.txt'}|Copy-Item -Destination $stage -Recurse
    Get-ChildItem $stage -Recurse -File -Filter '*.zip' -ErrorAction SilentlyContinue|Remove-Item -Force
    $importArgs=@{ContractPath=(Join-Path $stage 'Payload/PAYLOAD-CONTRACT.json');OutputDirectory=(Join-Path $stage 'Payload');StateDirectory=(Join-Path $stage '.download-state')}
    if($CacheDirectory){$importArgs.CacheDirectory=$CacheDirectory}
    $import=& (Join-Path $repositoryRoot 'scripts/Import-KIStackBuildPayload.ps1') @importArgs
    if(-not$import.passed){throw "Integration build payload: $($import.status)"}
    Remove-Item (Join-Path $stage '.download-state') -Recurse -Force -ErrorAction SilentlyContinue
    $lines=Get-ChildItem $stage -Recurse -File|Sort-Object{[IO.Path]::GetRelativePath($stage,$_.FullName).Replace('\','/')}|ForEach-Object{$relative=[IO.Path]::GetRelativePath($stage,$_.FullName).Replace('\','/');"$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) *$relative"};Set-Content (Join-Path $stage 'SHA256SUMS.txt') $lines -Encoding ASCII
    New-Item -ItemType Directory $OutputDirectory -Force|Out-Null;$zip=Join-Path $OutputDirectory 'KI-Stack-Integration-Execute-v1.5.11.zip';if(Test-Path $zip){Remove-Item $zip -Force}
    Add-Type -AssemblyName System.IO.Compression;$stream=[IO.File]::Open($zip,[IO.FileMode]::CreateNew)
    try{$archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true);try{foreach($file in(Get-ChildItem $stage -Recurse -File|Sort-Object{[IO.Path]::GetRelativePath($stage,$_.FullName).Replace('\','/')})){$relative=[IO.Path]::GetRelativePath($stage,$file.FullName).Replace('\','/');$entry=$archive.CreateEntry($relative,[IO.Compression.CompressionLevel]::Optimal);$entry.LastWriteTime=[DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero);$entryStream=$entry.Open();try{$input=[IO.File]::OpenRead($file.FullName);try{$input.CopyTo($entryStream)}finally{$input.Dispose()}}finally{$entryStream.Dispose()}}}finally{$archive.Dispose()}}finally{$stream.Dispose()}
    $hash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant();Set-Content "$zip.sha256" "$hash *$(Split-Path -Leaf $zip)" -Encoding ASCII
    [ordered]@{zip=$zip;sha256=$hash;sidecar="$zip.sha256"}|ConvertTo-Json
}finally{Remove-Item $stage -Recurse -Force}

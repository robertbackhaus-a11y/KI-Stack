[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$source=Join-Path $repositoryRoot 'package'
$stage=Join-Path $OutputDirectory 'KI-Stack-Models-Workflows-Execute-v1.4.0'
if(Test-Path $stage){Remove-Item $stage -Recurse -Force}
New-Item $stage -ItemType Directory -Force|Out-Null
Get-ChildItem $source -Force|Where-Object{$_.Name -notin @('State')}|Copy-Item -Destination $stage -Recurse
foreach($relative in @('Modules/08-Cutover','Start-KIStack-Cutover-DryRun.cmd','Start-KIStack-Cutover-Execute.cmd','Start-KIStack-Cutover.ps1')){
    $path=Join-Path $stage $relative;if(Test-Path $path){Remove-Item $path -Recurse -Force}
}
Set-Content (Join-Path $stage 'VERSION') '1.4.0' -Encoding ASCII
@{schemaVersion='1.0';packageId='KI-STACK-MODELS-WORKFLOWS';name='KI-Stack Models / Workflows';version='1.4.0';status='TargetSystemValidated';workflows=@(@{file='KI-Stack-FLUX2-Text-to-Image-v1.3.8.json';sha256='331b7a5a14b284d7d130d60bdcd0168f0ddc3169a164d2adfbc4e49b8cd4ab58'},@{file='FLUX2-Klein-9B-OpenWebUI-API-FLAT.json';sha256='697ea261e1c62a8e32d775ee9cba5c5c5c3548c6bd082a63a84c71f53c3123a5'},@{file='KREA-Realism-Official-Template.json';sha256='622441f15389e31498dc74829f7fe54c9c830f7c8d42d170f9baad59c04c08a6'},@{file='PONY-SDXL-Control-QuickTest-v2.json';sha256='650631dc3b76ba389767fd99afb2ea9f63d1011bb912c216cfa1eabfeb5dd07a'},@{file='WAN2.2-5B-Official.json';sha256='797b2f1c91b5bc537d11201ae025ea481129021cdf54045ce5f02774ebf8bec9'});externalModelBytes=47356936991;containsModels=$false;offline=$false;containsSecrets=$false;containsPersonalPaths=$false}|ConvertTo-Json -Depth 20|Set-Content (Join-Path $stage 'MANIFEST.json') -Encoding UTF8
@{schemaVersion='1.0';package='KI-Stack Models / Workflows';version='1.4.0';status='TargetSystemValidated';deterministicArchive=$true;offline=$false;containsModels=$false;externalModelBytes=47356936991;containsSecrets=$false;containsPersonalPaths=$false}|ConvertTo-Json -Compress|Set-Content (Join-Path $stage 'BUILD-REPORT.json') -Encoding UTF8
@{schemaVersion='1.0';package='KI-Stack Models / Workflows';version='1.4.0';status='TargetSystemValidated';validatedAtUtc='2026-07-23T12:00:00Z';results=@{previousFlux2AcceptancePreserved=$true;newCanonicalWorkflowLoadTests=3;newCanonicalWorkflowFunctionalRuns=3;requiredModelsReused=8;modelsDownloaded=$false;apiWorkflowUnchanged=$true};containsRawTargetReport=$false;containsRenderedImages=$false;containsModels=$false;containsPersonalPaths=$false}|ConvertTo-Json -Depth 20 -Compress|Set-Content (Join-Path $stage 'VALIDATION-REPORT.json') -Encoding UTF8
$files=Get-ChildItem $stage -Recurse -File|Where-Object Name -ne 'SHA256SUMS.txt'|Sort-Object{[IO.Path]::GetRelativePath($stage,$_.FullName).Replace('\','/')}
$lines=$files|ForEach-Object{$rel=[IO.Path]::GetRelativePath($stage,$_.FullName).Replace('\','/');"$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) *$rel"}
Set-Content (Join-Path $stage 'SHA256SUMS.txt') $lines -Encoding ASCII
$zip=Join-Path $OutputDirectory 'KI-Stack-Models-Workflows-Execute-v1.4.0.zip';if(Test-Path $zip){Remove-Item $zip -Force}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$epoch=[DateTimeOffset]::Parse('2000-01-01T00:00:00Z');$stream=[IO.File]::Open($zip,[IO.FileMode]::CreateNew)
try{$archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false);try{foreach($file in Get-ChildItem $stage -Recurse -File|Sort-Object FullName){$rel=[IO.Path]::GetRelativePath((Split-Path $stage -Parent),$file.FullName).Replace('\','/');$entry=$archive.CreateEntry($rel,[IO.Compression.CompressionLevel]::Optimal);$entry.LastWriteTime=$epoch;$input=[IO.File]::OpenRead($file.FullName);$output=$entry.Open();try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}}}finally{$archive.Dispose()}}finally{$stream.Dispose()}
$hash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant();Set-Content "$zip.sha256" "$hash *$(Split-Path -Leaf $zip)" -Encoding ASCII
[pscustomobject]@{zip=$zip;sizeBytes=(Get-Item $zip).Length;sha256=$hash}

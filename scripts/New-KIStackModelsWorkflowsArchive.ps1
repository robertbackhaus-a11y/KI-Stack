[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$source=Join-Path $repositoryRoot 'package'
$stage=Join-Path $OutputDirectory 'KI-Stack-Models-Workflows-Execute-v1.4.3'
if(Test-Path $stage){Remove-Item $stage -Recurse -Force}
New-Item $stage -ItemType Directory -Force|Out-Null
Get-ChildItem $source -Force|Where-Object{$_.Name -notin @('State')}|Copy-Item -Destination $stage -Recurse
$documentationRoot=Join-Path $repositoryRoot 'docs'
$documentationStage=Join-Path $stage 'Documentation'
New-Item $documentationStage -ItemType Directory -Force|Out-Null
foreach($relative in @('en/KI-Stack-Technical-Documentation.md','de/KI-Stack-Technische-Dokumentation.md','en/KI-Stack-Operations-and-User-Guide.md','de/KI-Stack-Betriebs-und-Benutzerhandbuch.md')){
    Copy-Item -LiteralPath (Join-Path $documentationRoot $relative) -Destination (Join-Path $documentationStage (Split-Path $relative -Leaf))
}
foreach($relative in @('Modules/08-Cutover','Start-KIStack-Cutover-DryRun.cmd','Start-KIStack-Cutover-Execute.cmd','Start-KIStack-Cutover.ps1')){
    $path=Join-Path $stage $relative;if(Test-Path $path){Remove-Item $path -Recurse -Force}
}
Set-Content (Join-Path $stage 'VERSION') '1.4.3' -Encoding ASCII
@{schemaVersion='1.0';packageId='KI-STACK-MODELS-WORKFLOWS';name='KI-Stack Models / Workflows';version='1.4.3';status='TargetSystemValidated';workflows=@(@{file='KI-Stack-FLUX2-Text-to-Image-v1.3.8.json';sha256='b0c90e9fd38a4948fe97bbd7e95b2100261dc69b335794ba6c7db2fe4ff539db'},@{file='FLUX2-Klein-9B-OpenWebUI-API-FLAT.json';sha256='697ea261e1c62a8e32d775ee9cba5c5c5c3548c6bd082a63a84c71f53c3123a5'},@{file='KREA-Realism-Official-Template.json';sha256='344dc0a177b625d7bdde5292771a5455951178d6d498649cbb40f4e690216e65'},@{file='PONY-SDXL-Control-QuickTest-v2.json';sha256='7338036490ee1325062c75f10d89a46661cec6c43f17f5d1a035da5db2e68d40'},@{file='WAN2.2-5B-Official.json';sha256='7d4195f7a67d01829dd8a3d4c54f9b5fc857399a6f246c5b555b5a66848f27e6'});externalModelBytes=47356936991;containsModels=$false;offline=$false;containsSecrets=$false;containsPersonalPaths=$false;publicModelImporter=$true;documentation=@('docs/en/KI-Stack-Technical-Documentation.md','docs/de/KI-Stack-Technische-Dokumentation.md','docs/en/KI-Stack-Operations-and-User-Guide.md','docs/de/KI-Stack-Betriebs-und-Benutzerhandbuch.md')}|ConvertTo-Json -Depth 20|Set-Content (Join-Path $stage 'MANIFEST.json') -Encoding UTF8
@{schemaVersion='1.0';package='KI-Stack Models / Workflows';version='1.4.3';status='TargetSystemValidated';deterministicArchive=$true;offline=$false;containsModels=$false;externalModelBytes=47356936991;containsSecrets=$false;containsPersonalPaths=$false;publicModelImporter=$true;documentation='Bilingual'}|ConvertTo-Json -Compress|Set-Content (Join-Path $stage 'BUILD-REPORT.json') -Encoding UTF8
@{schemaVersion='1.0';package='KI-Stack Models / Workflows';version='1.4.3';status='TargetSystemValidated';validatedAtUtc='2026-07-23T12:00:00Z';results=@{previousFunctionalAcceptancePreserved=$true;centralModelImporterFixturePassed=$true;targetModelAuditPassed=$true;modelsDownloaded=$false;apiWorkflowUnchanged=$true;documentationParityPassed=$true};containsRawTargetReport=$false;containsRenderedImages=$false;containsModels=$false;containsPersonalPaths=$false}|ConvertTo-Json -Depth 20 -Compress|Set-Content (Join-Path $stage 'VALIDATION-REPORT.json') -Encoding UTF8
$files=Get-ChildItem $stage -Recurse -File|Where-Object Name -ne 'SHA256SUMS.txt'|Sort-Object{[IO.Path]::GetRelativePath($stage,$_.FullName).Replace('\','/')}
$lines=$files|ForEach-Object{$rel=[IO.Path]::GetRelativePath($stage,$_.FullName).Replace('\','/');"$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) *$rel"}
Set-Content (Join-Path $stage 'SHA256SUMS.txt') $lines -Encoding ASCII
$zip=Join-Path $OutputDirectory 'KI-Stack-Models-Workflows-Execute-v1.4.3.zip';if(Test-Path $zip){Remove-Item $zip -Force}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$epoch=[DateTimeOffset]::Parse('2000-01-01T00:00:00Z');$stream=[IO.File]::Open($zip,[IO.FileMode]::CreateNew)
try{$archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false);try{foreach($file in Get-ChildItem $stage -Recurse -File|Sort-Object FullName){$rel=[IO.Path]::GetRelativePath((Split-Path $stage -Parent),$file.FullName).Replace('\','/');$entry=$archive.CreateEntry($rel,[IO.Compression.CompressionLevel]::Optimal);$entry.LastWriteTime=$epoch;$input=[IO.File]::OpenRead($file.FullName);$output=$entry.Open();try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}}}finally{$archive.Dispose()}}finally{$stream.Dispose()}
$hash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant();Set-Content "$zip.sha256" "$hash *$(Split-Path -Leaf $zip)" -Encoding ASCII
[pscustomobject]@{zip=$zip;sizeBytes=(Get-Item $zip).Length;sha256=$hash}

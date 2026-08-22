[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ContractPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$CacheDirectory,
    [string]$StateDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'KIStack-BuildPayload-State'),
    [switch]$DisableNetwork,
    [switch]$AllowUnanchoredOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$epoch=[DateTimeOffset]::Parse('2000-01-01T00:00:00Z')
$contractPathResolved=(Resolve-Path $ContractPath).Path
$contractDirectory=Split-Path -Parent $contractPathResolved
$contract=Get-Content -LiteralPath $contractPathResolved -Raw|ConvertFrom-Json -Depth 100

function Test-FileAnchor([string]$Path,[long]$Size,[string]$Sha256){
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
    (Get-Item -LiteralPath $Path).Length -eq $Size -and
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Sha256
}

function Receive-ResumableFile([string]$Uri,[string]$Path,[long]$ExpectedSize){
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force|Out-Null
    $existing=if(Test-Path -LiteralPath $Path){(Get-Item -LiteralPath $Path).Length}else{0L}
    if($existing-gt$ExpectedSize){Remove-Item -LiteralPath $Path -Force;$existing=0L}
    $client=[Net.Http.HttpClient]::new()
    $client.Timeout=[TimeSpan]::FromMinutes(30)
    $request=$null;$response=$null
    try{
        $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$Uri)
        if($existing-gt0){$request.Headers.Range=[Net.Http.Headers.RangeHeaderValue]::new($existing,$null)}
        $response=$client.Send($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        if(-not$response.IsSuccessStatusCode){throw "HTTP $([int]$response.StatusCode): $Uri"}
        $append=$existing-gt0-and[int]$response.StatusCode-eq206
        if($existing-gt0-and-not$append){$existing=0L}
        $mode=if($append){[IO.FileMode]::Append}else{[IO.FileMode]::Create}
        $input=$response.Content.ReadAsStream()
        $output=[IO.File]::Open($Path,$mode,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}
        [pscustomobject]@{resumed=$append;resumedFromBytes=$existing}
    }finally{
        if($response){$response.Dispose()};if($request){$request.Dispose()};$client.Dispose()
    }
}

function New-DeterministicZip([string]$SourceRoot,[string]$Destination){
    Add-Type -AssemblyName System.IO.Compression
    $stream=[IO.File]::Open($Destination,[IO.FileMode]::Create)
    try{
        $archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
        try{
            foreach($file in Get-ChildItem -LiteralPath $SourceRoot -Recurse -File|Sort-Object{[IO.Path]::GetRelativePath($SourceRoot,$_.FullName).Replace('\','/')}){
                $relative=[IO.Path]::GetRelativePath($SourceRoot,$file.FullName).Replace('\','/')
                $entry=$archive.CreateEntry($relative,[IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime=$epoch
                $input=[IO.File]::OpenRead($file.FullName);$output=$entry.Open()
                try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}
            }
        }finally{$archive.Dispose()}
    }finally{$stream.Dispose()}
}

$upstream=$contract.upstream
$urlIsImmutableTransport = (
    [string]$upstream.url -match '^https://' -or
    [string]$upstream.url -match '^http://127\.0\.0\.1:\d+/'
)
$revision = [string]$upstream.revision
$urlIsLocalFixture = [string]$upstream.url -match '^http://127\.0\.0\.1:\d+/'
$revisionIsPinned = (
    $revision -match '^[0-9a-f]{40}$' -and
    ($urlIsLocalFixture -or [string]$upstream.url -match [regex]::Escape($revision))
)
if(-not$urlIsImmutableTransport -or -not$revisionIsPinned -or
   [string]$upstream.url -match '/(?:main|latest)(?:/|\?|$)' -or
   [string]$upstream.sha256-notmatch'^[0-9a-f]{64}$' -or [long]$upstream.sizeBytes-le0){
    throw 'Upstream archive contract is incomplete.'
}
$cacheCandidate=if($CacheDirectory){Join-Path $CacheDirectory ([string]$upstream.fileName)}else{''}
$archiveSource=$null;$downloadEvidence=$null
if($cacheCandidate-and(Test-Path -LiteralPath $cacheCandidate -PathType Leaf)){
    if(-not(Test-FileAnchor -Path $cacheCandidate -Size ([long]$upstream.sizeBytes) -Sha256 ([string]$upstream.sha256))){throw "ChecksumMismatch: invalid optional cache: $cacheCandidate"}
    $archiveSource=$cacheCandidate
}
if(-not$archiveSource){
    $partial=Join-Path $StateDirectory ([string]$upstream.fileName+'.partial')
    if($DisableNetwork){
        [pscustomobject]@{passed=$false;status='WaitingForNetwork';resumable=$true;partialPath=$partial}
        return
    }
    try{$downloadEvidence=Receive-ResumableFile ([string]$upstream.url) $partial ([long]$upstream.sizeBytes)}
    catch{
        [pscustomobject]@{passed=$false;status='WaitingForNetwork';resumable=$true;partialPath=$partial;message=$_.Exception.Message}
        return
    }
    if((Get-Item -LiteralPath $partial).Length-ne[long]$upstream.sizeBytes){throw 'SizeMismatch: downloaded upstream archive.'}
    if(-not(Test-FileAnchor -Path $partial -Size ([long]$upstream.sizeBytes) -Sha256 ([string]$upstream.sha256))){throw 'ChecksumMismatch: downloaded upstream archive.'}
    $archiveSource=$partial
}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-BuildPayload-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try{
    $extract=Join-Path $temp 'extract'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($archiveSource,$extract)
    $directories=@(Get-ChildItem -LiteralPath $extract -Directory);$files=@(Get-ChildItem -LiteralPath $extract -File)
    if($directories.Count-ne1-or$files.Count){throw 'Upstream archive must contain exactly one root directory.'}
    $sourceRoot=$directories[0].FullName
    $manifestPath=Join-Path $contractDirectory ([string]$contract.contentManifest)
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json -Depth 100
    $overlayRoot=if($contract.PSObject.Properties.Name-contains'overlay' -and $contract.overlay){Join-Path $contractDirectory ([string]$contract.overlay)}else{''}
    $stage=Join-Path $temp 'stage';New-Item -ItemType Directory -Path $stage|Out-Null
    foreach($entry in @($manifest.files)){
        $relative=[string]$entry.path
        $overlayPath=if($overlayRoot){Join-Path $overlayRoot $relative}else{''}
        $source=if($overlayPath-and(Test-Path -LiteralPath $overlayPath -PathType Leaf)){$overlayPath}else{Join-Path $sourceRoot $relative}
        if(-not(Test-FileAnchor -Path $source -Size ([long]$entry.sizeBytes) -Sha256 ([string]$entry.sha256))){throw "ContentManifestMismatch: $relative"}
        $target=Join-Path $stage $relative;New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force|Out-Null
        Copy-Item -LiteralPath $source -Destination $target
    }
    New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null
    $outputPath=Join-Path $OutputDirectory ([string]$contract.output.fileName)
    New-DeterministicZip $stage $outputPath
    $outputSize=(Get-Item -LiteralPath $outputPath).Length
    $outputSha=(Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if(-not$AllowUnanchoredOutput){
        if($outputSize-ne[long]$contract.output.sizeBytes){throw 'SizeMismatch: generated payload archive.'}
        if($outputSha-ne[string]$contract.output.sha256){throw 'ChecksumMismatch: generated payload archive.'}
    }
    [pscustomobject]@{
        passed=$true;status='Completed';output=$outputPath;sizeBytes=$outputSize;sha256=$outputSha
        source=$(if($cacheCandidate-eq$archiveSource){'cache'}else{'download'})
        resumed=$(if($downloadEvidence){[bool]$downloadEvidence.resumed}else{$false})
    }
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction Ignore}}

[CmdletBinding()]
param([string]$PackageRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('KIStack-RC12-Download-' + [guid]::NewGuid().ToString('N'))
$server = $null
try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $artifact = Join-Path $fixture 'artifact.bin'
    $bytes = [byte[]](0..255)
    [IO.File]::WriteAllBytes($artifact,$bytes)
    $sha = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
    $port = Get-Random -Minimum 30000 -Maximum 45000
    $ready = Join-Path $fixture 'ready'
    $serverScript = Join-Path $PSScriptRoot 'TestRangeServer.ps1'
    $server = Start-Process -FilePath (Get-Command pwsh.exe).Source -ArgumentList @(
        '-NoLogo','-NoProfile','-File',('"{0}"' -f $serverScript),
        '-Port',$port,'-ArtifactPath',('"{0}"' -f $artifact),'-ReadyPath',('"{0}"' -f $ready)
    ) -PassThru -WindowStyle Hidden
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $ready)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Range fixture server did not start.' }
        Start-Sleep -Milliseconds 50
    }
    function New-Manifest([string]$Uri,[string]$ExpectedSha=$sha,[long]$ExpectedSize=$bytes.Length) {
        $path = Join-Path $fixture ('manifest-' + [guid]::NewGuid().ToString('N') + '.json')
        [ordered]@{
            schemaVersion='fixture'
            models=@([ordered]@{id='fixture';fileName='artifact.bin';sizeBytes=$ExpectedSize;sha256=$ExpectedSha;relativeTargetPath='models/fixture/artifact.bin';sources=@($Uri)})
            lmStudio=[ordered]@{relativeTargetDirectory='fixture';files=@()}
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
        $path
    }
    function Invoke-Import([string]$Manifest,[string]$Case,[switch]$DisableNetwork) {
        $caseRoot=Join-Path $fixture $Case
        $args=@{Mode='Install';ManifestPath=$Manifest;SourcePath=(Join-Path $caseRoot 'cache');TargetRoot=(Join-Path $caseRoot 'target');LmStudioTargetRoot=(Join-Path $caseRoot 'lm');StateRoot=(Join-Path $caseRoot 'state');TransactionId=$Case}
        if($DisableNetwork){$args.DisableNetwork=$true}
        & (Join-Path $PackageRoot 'Import-KIStackExternalModels.ps1') @args
    }

    $normal = New-Manifest "http://127.0.0.1:$port/artifact"
    $cacheRoot = Join-Path $fixture 'cache-reuse\cache'
    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    Copy-Item $artifact (Join-Path $cacheRoot 'artifact.bin')
    $legacy=Join-Path $fixture 'cache-reuse\target\models\fixture\unmanaged-legacy-artifact.gguf'
    New-Item -ItemType Directory -Path (Split-Path -Parent $legacy) -Force|Out-Null
    [IO.File]::WriteAllBytes($legacy,[byte[]]@(9,8,7,6))
    $legacyHash=(Get-FileHash -LiteralPath $legacy -Algorithm SHA256).Hash
    $cache = Invoke-Import $normal 'cache-reuse' -DisableNetwork
    if (-not $cache.passed -or $cache.results[0].source -ne 'cache') { throw 'Valid optional cache was not reused.' }
    if(-not(Test-Path -LiteralPath $legacy)-or(Get-FileHash -LiteralPath $legacy -Algorithm SHA256).Hash-ne$legacyHash){throw 'Unmanaged legacy file was modified or deleted.'}

    $interrupt = New-Manifest "http://127.0.0.1:$port/interrupt"
    $interrupted = Invoke-Import $interrupt 'resume'
    $partialPath=Join-Path $fixture 'resume\state\downloads\fixture.partial'
    if($interrupted.passed-or$interrupted.status-ne'WaitingForNetwork'-or-not(Test-Path $partialPath)-or(Get-Item $partialPath).Length-le0){throw 'Interrupted download was not retained as resumable.'}
    $resume = Invoke-Import $interrupt 'resume'
    if (-not $resume.passed -or -not $resume.results[0].resumed -or $resume.results[0].resumedFromBytes -le 0) { throw 'Interrupted download was not resumed.' }

    foreach($case in @(
        @{name='wrong-size';manifest=(New-Manifest "http://127.0.0.1:$port/short")},
        @{name='wrong-hash';manifest=(New-Manifest "http://127.0.0.1:$port/bad-hash")}
    )){
        $failed=$false
        try { $null=Invoke-Import $case.manifest $case.name } catch { $failed=$_.Exception.Message -like 'ChecksumMismatch:*' -or$_.Exception.Message-like'SizeMismatch:*' }
        if(-not$failed){throw "$($case.name) did not fail with an integrity error."}
    }

    $offlineManifest = New-Manifest 'http://127.0.0.1:1/unreachable'
    $offline = Invoke-Import $offlineManifest 'offline'
    if ($offline.passed -or $offline.status -ne 'WaitingForNetwork' -or -not $offline.resumable) { throw 'Unreachable source did not return resumable WaitingForNetwork.' }

    $reusedRoot=Join-Path $fixture 'target-reuse\target\models\fixture'
    New-Item -ItemType Directory -Path $reusedRoot -Force | Out-Null
    Copy-Item $artifact (Join-Path $reusedRoot 'artifact.bin')
    $reused=Invoke-Import $normal 'target-reuse' -DisableNetwork
    if(-not$reused.passed -or $reused.results[0].status-ne'Reused'){throw 'Valid installed artifact was not reused.'}

    [pscustomobject]@{
        passed=$true;tests=8
        cases=@('optional-cache-reuse','legacy-file-preserved','download-interruption-retained','range-resume','wrong-size-failed','wrong-hash-failed','offline-resumable','installed-target-reuse')
    } | ConvertTo-Json -Depth 5
}
finally {
    if($server -and -not$server.HasExited){Stop-Process -Id $server.Id -Force}
    if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}

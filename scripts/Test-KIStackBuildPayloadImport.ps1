[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) (
    'KIStack-Build-Payload-Import-' + [guid]::NewGuid().ToString('N')
)
$server = $null

function Write-Contract {
    param(
        [string]$Path,
        [string]$Url,
        [long]$ArchiveSize,
        [string]$ArchiveSha,
        [long]$OutputSize,
        [string]$OutputSha
    )
    [ordered]@{
        schemaVersion='fixture'
        upstream=[ordered]@{
            revision='0000000000000000000000000000000000000000'
            url=$Url
            fileName='upstream.zip'
            sizeBytes=$ArchiveSize
            sha256=$ArchiveSha
        }
        contentManifest='CONTENT-MANIFEST.json'
        output=[ordered]@{
            fileName='generated.zip'
            sizeBytes=$OutputSize
            sha256=$OutputSha
        }
        cacheOptional=$true
        resumeSupported=$true
        manualPreloadRequired=$false
    } | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-Importer {
    param(
        [string]$Case,
        [string]$ContractPath,
        [string]$CacheDirectory,
        [switch]$DisableNetwork,
        [switch]$AllowUnanchoredOutput
    )
    $caseRoot = Join-Path $fixture $Case
    $arguments = @{
        ContractPath=$ContractPath
        OutputDirectory=(Join-Path $caseRoot 'output')
        StateDirectory=(Join-Path $caseRoot 'state')
    }
    if ($CacheDirectory) { $arguments.CacheDirectory=$CacheDirectory }
    if ($DisableNetwork) { $arguments.DisableNetwork=$true }
    if ($AllowUnanchoredOutput) { $arguments.AllowUnanchoredOutput=$true }
    & (Join-Path $RepositoryRoot 'scripts\Import-KIStackBuildPayload.ps1') @arguments
}

New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    $upstreamRoot = Join-Path $fixture 'upstream\fixture-revision'
    New-Item -ItemType Directory -Path $upstreamRoot -Force | Out-Null
    $contentPath = Join-Path $upstreamRoot 'payload.txt'
    [IO.File]::WriteAllText($contentPath,'tracked fixture payload',[Text.UTF8Encoding]::new($false))
    $contentSize = (Get-Item -LiteralPath $contentPath).Length
    $contentSha = (Get-FileHash -LiteralPath $contentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [ordered]@{
        schemaVersion='fixture'
        files=@([ordered]@{path='payload.txt';sizeBytes=$contentSize;sha256=$contentSha})
    } | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $fixture 'CONTENT-MANIFEST.json') -Encoding UTF8

    $archive = Join-Path $fixture 'upstream.zip'
    Compress-Archive -LiteralPath $upstreamRoot -DestinationPath $archive
    $archiveSize = (Get-Item -LiteralPath $archive).Length
    $archiveSha = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $port = Get-Random -Minimum 30000 -Maximum 45000
    $ready = Join-Path $fixture 'server.ready'
    $serverScript = Join-Path $RepositoryRoot 'tools\models-workflows\current\Tests\TestRangeServer.ps1'
    $server = Start-Process -FilePath (Get-Command pwsh.exe).Source -ArgumentList @(
        '-NoLogo','-NoProfile','-File',
        ('"{0}"' -f $serverScript),
        '-Port',$port,'-ArtifactPath',('"{0}"' -f $archive),'-ReadyPath',('"{0}"' -f $ready)
    ) -PassThru -WindowStyle Hidden
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $ready)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Range fixture server did not start.' }
        Start-Sleep -Milliseconds 50
    }

    $contract = Join-Path $fixture 'PAYLOAD-CONTRACT.json'
    $baseUrl = "http://127.0.0.1:$port"
    Write-Contract $contract "$baseUrl/artifact" $archiveSize $archiveSha 1 ('0' * 64)
    $probe = Invoke-Importer 'anchor-probe' $contract '' -AllowUnanchoredOutput
    Write-Contract $contract "$baseUrl/artifact" $archiveSize $archiveSha $probe.sizeBytes $probe.sha256

    $cache = Join-Path $fixture 'cache'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    Copy-Item -LiteralPath $archive -Destination (Join-Path $cache 'upstream.zip')
    $cacheResult = Invoke-Importer 'cache' $contract $cache -DisableNetwork
    if (-not $cacheResult.passed -or $cacheResult.source -ne 'cache') {
        throw 'Valid optional cache was not reused.'
    }

    Write-Contract $contract "$baseUrl/interrupt" $archiveSize $archiveSha $probe.sizeBytes $probe.sha256
    $interrupted = Invoke-Importer 'resume' $contract ''
    $partial = Join-Path $fixture 'resume\state\upstream.zip.partial'
    if ($interrupted.passed -or $interrupted.status -ne 'WaitingForNetwork' -or
        -not (Test-Path -LiteralPath $partial) -or (Get-Item $partial).Length -le 0) {
        throw 'Interrupted download was not retained with resumable state.'
    }
    $resumed = Invoke-Importer 'resume' $contract ''
    if (-not $resumed.passed -or -not $resumed.resumed) {
        throw 'Range resume did not complete.'
    }

    foreach ($integrityCase in @(
        @{name='wrong-size';url="$baseUrl/short";message='SizeMismatch:*'},
        @{name='wrong-hash';url="$baseUrl/bad-hash";message='ChecksumMismatch:*'}
    )) {
        Write-Contract $contract $integrityCase.url $archiveSize $archiveSha $probe.sizeBytes $probe.sha256
        $failedCorrectly = $false
        try { $null = Invoke-Importer $integrityCase.name $contract '' }
        catch { $failedCorrectly = $_.Exception.Message -like $integrityCase.message }
        if (-not $failedCorrectly) { throw "$($integrityCase.name) did not fail correctly." }
    }

    Write-Contract $contract 'http://127.0.0.1:1/unreachable' $archiveSize $archiveSha $probe.sizeBytes $probe.sha256
    $offline = Invoke-Importer 'offline' $contract ''
    if ($offline.passed -or $offline.status -ne 'WaitingForNetwork' -or -not $offline.resumable) {
        throw 'Network failure was not reported as resumable WaitingForNetwork.'
    }

    Write-Contract $contract "$baseUrl/artifact" $archiveSize $archiveSha $probe.sizeBytes $probe.sha256
    $first = Invoke-Importer 'deterministic-a' $contract ''
    $second = Invoke-Importer 'deterministic-b' $contract ''
    if ($first.sha256 -ne $second.sha256 -or $first.sizeBytes -ne $second.sizeBytes) {
        throw 'Generated payload archive is not deterministic.'
    }

    [pscustomobject]@{
        passed=$true
        tests=7
        cases=@(
            'optional-cache-reuse',
            'download-interruption-retained',
            'range-resume',
            'wrong-size-failed',
            'wrong-hash-failed',
            'offline-resumable',
            'deterministic-output'
        )
    } | ConvertTo-Json -Depth 10
}
finally {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    if (Test-Path -LiteralPath $fixture) {
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}

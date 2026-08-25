[CmdletBinding()]
param(
    [ValidateSet('Audit','Install')][string]$Mode = 'Audit',
    [string]$SourcePath = (Join-Path $PSScriptRoot 'ExternalModels'),
    [string]$TargetRoot = 'C:\KI-Stack',
    [string]$LmStudioTargetRoot = (Join-Path $env:USERPROFILE '.lmstudio'),
    [string]$StateRoot,
    [string]$TransactionId,
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'Manifests\models.manifest.json'),
    [switch]$Resume,
    [switch]$Rollback,
    [switch]$Audit,
    [switch]$DisableNetwork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Audit) { $Mode = 'Audit' }
if ($Rollback) { throw 'This payload never replaces a verified model and therefore has no destructive model rollback action.' }
if ([string]::IsNullOrWhiteSpace($TransactionId)) { $TransactionId = 'model-import-' + [guid]::NewGuid().ToString('N') }
if ([string]::IsNullOrWhiteSpace($StateRoot)) { $StateRoot = Join-Path $TargetRoot 'state\models-workflows' }
$downloadRoot = Join-Path $StateRoot 'downloads'
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -Depth 30
$results = [Collections.Generic.List[object]]::new()

function Test-Artifact {
    param([string]$Path,[long]$SizeBytes,[string]$Sha256)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -ne $SizeBytes) { return $false }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Sha256.ToLowerInvariant()
}

function Receive-Artifact {
    param([string]$Uri,[string]$PartialPath,[long]$ExpectedSize)
    New-Item -ItemType Directory -Path (Split-Path -Parent $PartialPath) -Force | Out-Null
    $existing = if (Test-Path -LiteralPath $PartialPath) { (Get-Item -LiteralPath $PartialPath).Length } else { 0L }
    if ($existing -gt $ExpectedSize) {
        Remove-Item -LiteralPath $PartialPath -Force
        $existing = 0L
    }
    if ((Test-Path -LiteralPath $PartialPath -PathType Leaf) -and $existing -eq $ExpectedSize) {
        return [pscustomobject]@{ resumed=$false; resumedFromBytes=0L }
    }
    $handler = [Net.Http.HttpClientHandler]::new()
    $client = [Net.Http.HttpClient]::new($handler)
    $request = $null
    $response = $null
    $client.Timeout = [TimeSpan]::FromDays(2)
    try {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$Uri)
        if ($existing -gt 0) { $request.Headers.Range = [Net.Http.Headers.RangeHeaderValue]::new($existing,$null) }
        $response = $client.Send($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        if (-not $response.IsSuccessStatusCode) { throw "Download source returned HTTP $([int]$response.StatusCode): $Uri" }
        $append = $existing -gt 0 -and [int]$response.StatusCode -eq 206
        if ($existing -gt 0 -and -not $append) { $existing = 0L }
        $expectedTransfer = $ExpectedSize - $existing
        $declaredLength = $response.Content.Headers.ContentLength
        if ($null -ne $declaredLength -and [long]$declaredLength -ne $expectedTransfer) {
            throw "SizeMismatch: source declared $declaredLength bytes, expected ${expectedTransfer}: $Uri"
        }
        $mode = if ($append) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
        $input = $response.Content.ReadAsStream()
        $output = [IO.File]::Open($PartialPath,$mode,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
        $finalLength=(Get-Item -LiteralPath $PartialPath).Length
        if($finalLength-lt$ExpectedSize){throw "IncompleteDownload: retained $finalLength of $ExpectedSize bytes for resume: $Uri"}
        if($finalLength-gt$ExpectedSize){throw "SizeMismatch: downloaded $finalLength bytes, expected ${ExpectedSize}: $Uri"}
        [pscustomobject]@{ resumed=$append; resumedFromBytes=$existing }
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        $client.Dispose()
        $handler.Dispose()
    }
}

function Install-Artifact {
    param(
        [Parameter(Mandatory)]$Contract,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$CacheSource
    )
    $sha = [string]$Contract.sha256
    if ([string]::IsNullOrWhiteSpace($sha)) { throw "Missing SHA256 contract: $($Contract.fileName)" }
    if (Test-Artifact $Target ([long]$Contract.sizeBytes) $sha) {
        return [pscustomobject]@{id=$Contract.id;status='Reused';target=$Target;source='target';resumed=$false}
    }
    $verifiedSource = $null
    if (Test-Path -LiteralPath $CacheSource -PathType Leaf) {
        if (-not (Test-Artifact $CacheSource ([long]$Contract.sizeBytes) $sha)) {
            throw "ChecksumMismatch: optional cache/preload is invalid: $CacheSource"
        }
        $verifiedSource = $CacheSource
    }
    if ($Mode -eq 'Audit') {
        $status = if ($verifiedSource) { 'VerifiedCache' } else { 'DownloadRequired' }
        return [pscustomobject]@{id=$Contract.id;status=$status;target=$Target;source=$verifiedSource;resumed=$false}
    }
    $downloadEvidence = $null
    if (-not $verifiedSource) {
        if ($DisableNetwork) {
            return [pscustomobject]@{id=$Contract.id;status='WaitingForNetwork';target=$Target;source=$null;resumable=$true;message='Network access is disabled and no verified cache/preload is available.'}
        }
        $urls = @($Contract.sources)
        if ($urls.Count -eq 0) { throw "Missing versioned download source: $($Contract.fileName)" }
        $partial = Join-Path $downloadRoot ($Contract.id + '.partial')
        $errors = [Collections.Generic.List[string]]::new()
        foreach ($url in $urls) {
            try {
                $downloadEvidence = Receive-Artifact -Uri ([string]$url) -PartialPath $partial -ExpectedSize ([long]$Contract.sizeBytes)
                if (-not (Test-Artifact $partial ([long]$Contract.sizeBytes) $sha)) {
                    throw "ChecksumMismatch: downloaded artifact is invalid: $($Contract.fileName)"
                }
                $verifiedSource = $partial
                break
            }
            catch {
                if ($_.Exception.Message -like 'ChecksumMismatch:*' -or $_.Exception.Message -like 'SizeMismatch:*') { throw }
                $errors.Add($_.Exception.Message)
            }
        }
        if (-not $verifiedSource) {
            return [pscustomobject]@{id=$Contract.id;status='WaitingForNetwork';target=$Target;source=$null;resumable=$true;partialPath=$partial;message=($errors -join ' | ')}
        }
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Target) -Force | Out-Null
    $targetPartial = $Target + '.partial'
    Copy-Item -LiteralPath $verifiedSource -Destination $targetPartial -Force
    if (-not (Test-Artifact $targetPartial ([long]$Contract.sizeBytes) $sha)) {
        throw "ChecksumMismatch: staged target readback failed: $($Contract.fileName)"
    }
    Move-Item -LiteralPath $targetPartial -Destination $Target -Force
    if (-not (Test-Artifact $Target ([long]$Contract.sizeBytes) $sha)) {
        throw "ChecksumMismatch: installed target readback failed: $($Contract.fileName)"
    }
    [pscustomobject]@{
        id=$Contract.id;status='Installed';target=$Target
        source=$(if($CacheSource -eq $verifiedSource){'cache'}else{'download'})
        resumed=$(if($downloadEvidence){[bool]$downloadEvidence.resumed}else{$false})
        resumedFromBytes=$(if($downloadEvidence){[long]$downloadEvidence.resumedFromBytes}else{0L})
    }
}

New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
foreach ($model in @($manifest.models)) {
    $cache = Join-Path $SourcePath ([string]$model.fileName)
    $target = Join-Path $TargetRoot ([string]$model.relativeTargetPath)
    $results.Add((Install-Artifact -Contract $model -Target $target -CacheSource $cache))
}
foreach ($file in @($manifest.lmStudio.files)) {
    $cache = Join-Path (Join-Path $SourcePath 'LMStudio') ([string]$file.fileName)
    $target = Join-Path $LmStudioTargetRoot ([string]$file.relativeTargetPath)
    if (-not ($file.PSObject.Properties.Name -contains 'id')) { $file | Add-Member id ([string]$file.fileName) }
    $results.Add((Install-Artifact -Contract $file -Target $target -CacheSource $cache))
}

$waiting = @($results | Where-Object status -eq 'WaitingForNetwork')
$passed = $waiting.Count -eq 0
if ($Mode -eq 'Install' -and $passed) {
    $workflowTarget = Join-Path $TargetRoot 'data\comfyui\user\default\workflows\KI-Stack'
    New-Item -ItemType Directory -Path $workflowTarget -Force | Out-Null
    $workflowBackup = Join-Path $StateRoot 'workflow-backup'
    $internalApiPrompts = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Workflows') -File -Filter '*.json' | ForEach-Object Name)
    foreach ($existing in Get-ChildItem -LiteralPath $workflowTarget -File -Filter '*.json' -ErrorAction SilentlyContinue) {
        New-Item -ItemType Directory -Path $workflowBackup -Force | Out-Null
        Move-Item -LiteralPath $existing.FullName -Destination (Join-Path $workflowBackup $existing.Name) -Force
    }
    $markerPath = Join-Path $TargetRoot 'modules\models-workflows\installation.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $markerPath) -Force | Out-Null
    [pscustomobject][ordered]@{
        schemaVersion='1.0';managedBy='KI-STACK-VISUAL-MODELS-WORKFLOWS';version='2.0.3'
        release='KI-Stack-Visual-Models-Workflows-v2.0.3';installedAtUtc=[DateTime]::UtcNow.ToString('o')
        transactionId=$TransactionId;workflows=@();internalApiPrompts=$internalApiPrompts;workflowBackup=$workflowBackup;models=@($results)
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $markerPath -Encoding UTF8
}

[pscustomobject]@{
    version='2.0.3';transactionId=$TransactionId;mode=$Mode;passed=$passed
    status=$(if($passed){if($Mode -eq 'Audit'){'CompliantOrReady'}else{'Completed'}}else{'WaitingForNetwork'})
    resumable=($waiting.Count -gt 0);mutatesTarget=($Mode -eq 'Install' -and $passed);results=$results
}

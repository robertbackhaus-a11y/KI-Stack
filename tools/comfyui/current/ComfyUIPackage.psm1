Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-ComfyJson {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
}

function Test-ComfyPayload {
    param([Parameter(Mandatory)][string]$PackageRoot)
    $contract = Read-ComfyJson (Join-Path $PackageRoot 'Payload/PAYLOAD-CONTRACT.json')
    $path = Join-Path $PackageRoot ('Payload/' + $contract.fileName)
    $errors = @()
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $errors += 'payload missing' }
    else {
        if ((Get-Item $path).Length -ne $contract.sizeBytes) { $errors += 'size mismatch' }
        if ((Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $contract.sha256) { $errors += 'SHA256 mismatch' }
    }
    [pscustomobject]@{ passed=($errors.Count -eq 0); errors=$errors; contract=$contract; path=$path }
}

function Expand-ComfyPayload {
    param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$Destination)
    $test = Test-ComfyPayload $PackageRoot
    if (-not $test.passed) { throw ($test.errors -join '; ') }
    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    Expand-Archive -LiteralPath $test.path -DestinationPath $Destination
    $manifest = Read-ComfyJson (Join-Path $PackageRoot 'Payload/CONTENT-MANIFEST.json')
    $errors = @()
    foreach ($file in $manifest.files) {
        $path = Join-Path $Destination $file.path
        if (-not (Test-Path $path) -or (Get-Item $path).Length -ne $file.sizeBytes -or (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.sha256) { $errors += $file.path }
    }
    if ($errors.Count) { throw ('extracted payload mismatch: ' + ($errors -join ', ')) }
    $manifest
}

function Test-ComfyTarget {
    param([Parameter(Mandatory)][string]$PackageRoot,[string]$TargetRoot='C:\KI-Stack\ComfyUI')
    $manifest = Read-ComfyJson (Join-Path $PackageRoot 'Payload/CONTENT-MANIFEST.json')
    $bad = @()
    foreach ($file in $manifest.files) {
        $path = Join-Path $TargetRoot $file.path
        if (-not (Test-Path $path) -or (Get-Item $path).Length -ne $file.sizeBytes -or (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.sha256) { $bad += $file.path }
    }
    [pscustomobject]@{ passed=($bad.Count -eq 0); managedFiles=$manifest.fileCount; mismatches=$bad; runtimeGitDependency=$false }
}

function Install-ComfyPayload {
    param([Parameter(Mandatory)][string]$PackageRoot,[string]$TargetRoot='C:\KI-Stack\ComfyUI',[string]$BackupRoot='C:\KI-Stack\backups\comfyui-1.2.2')
    $audit = Test-ComfyTarget $PackageRoot $TargetRoot
    $moduleRoot = Join-Path (Split-Path $TargetRoot -Parent) 'modules/comfyui'
    $marker = Join-Path $moduleRoot 'installation.json'
    if ($audit.passed) {
        $current = if (Test-Path $marker) { Read-ComfyJson $marker } else { $null }
        if ($current -and [string]$current.release -eq 'KI-Stack-ComfyUI-Execute-v1.2.2') { return [pscustomobject]@{passed=$true;changed=$false;status='SkippedAlreadyCompliant';backup=$null} }
        $backup = Join-Path $BackupRoot ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory $backup -Force | Out-Null
        if (Test-Path $marker) { Copy-Item $marker (Join-Path $backup 'installation.json') -Force }
        New-Item -ItemType Directory $moduleRoot -Force | Out-Null
        [ordered]@{schemaVersion='1.0';managedBy='KI-STACK-COMFYUI-MANAGED';version='1.2.2';release='KI-Stack-ComfyUI-Execute-v1.2.2';installedAt=[DateTime]::UtcNow.ToString('o');payloadId='KI-STACK-COMFYUI-SOURCE-V0.28.0';payloadSha256='da0efd7c587e672128fd764cad8265fd83b0b085176c46c7b9d7e1e69ebe3813';migration='content-verified-no-reinstall';runtimeGitDependency=$false} | ConvertTo-Json -Depth 10 | Set-Content $marker -Encoding UTF8
        return [pscustomobject]@{passed=$true;changed=$true;status='Completed';backup=$backup;files=0;markerMigrated=$true}
    }
    $temp = Join-Path $env:TEMP ('ki-comfy-' + [guid]::NewGuid().ToString('N'))
    $manifest = Expand-ComfyPayload $PackageRoot $temp
    $backup = Join-Path $BackupRoot ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    $state = @()
    try {
        foreach ($file in $manifest.files) {
            $source = Join-Path $temp $file.path; $target = Join-Path $TargetRoot $file.path
            if ((Test-Path $target) -and (Get-Item $target).Length -eq $file.sizeBytes -and (Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant() -eq $file.sha256) { continue }
            $record = [ordered]@{path=$file.path;existed=(Test-Path $target)}
            if ($record.existed) {
                $backupPath = Join-Path $backup $file.path
                New-Item -ItemType Directory (Split-Path $backupPath -Parent) -Force | Out-Null
                Copy-Item $target $backupPath -Force
            }
            New-Item -ItemType Directory (Split-Path $target -Parent) -Force | Out-Null
            Copy-Item $source $target -Force
            $state += $record
        }
        New-Item -ItemType Directory $backup -Force | Out-Null
        $state | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $backup 'rollback.json') -Encoding UTF8
        [pscustomobject]@{passed=$true;changed=$true;status='Completed';backup=$backup;files=$state.Count}
    }
    finally { Remove-Item $temp -Recurse -Force }
}

function Restore-ComfyPayload {
    param([Parameter(Mandatory)][string]$Backup,[string]$TargetRoot='C:\KI-Stack\ComfyUI')
    $state = Get-Content (Join-Path $Backup 'rollback.json') -Raw | ConvertFrom-Json
    foreach ($record in @($state)) {
        $target = Join-Path $TargetRoot $record.path
        if ($record.existed) { Copy-Item (Join-Path $Backup $record.path) $target -Force }
        elseif (Test-Path $target) { Remove-Item $target -Force }
    }
    [pscustomobject]@{passed=$true;status='RolledBack'}
}

Export-ModuleMember -Function *

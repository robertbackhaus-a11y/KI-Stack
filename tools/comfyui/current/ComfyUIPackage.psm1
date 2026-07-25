Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-ComfyJson {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
}

function Test-ComfyPayload {
    param([Parameter(Mandatory)][string]$PackageRoot)
    $contract = Read-ComfyJson (Join-Path $PackageRoot 'Payload/PAYLOAD-CONTRACT.json')
    $path = Join-Path $PackageRoot ('Payload/' + $contract.output.fileName)
    $errors = @()
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $errors += 'payload missing' }
    else {
        if ((Get-Item $path).Length -ne $contract.output.sizeBytes) { $errors += 'size mismatch' }
        if ((Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $contract.output.sha256) { $errors += 'SHA256 mismatch' }
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

function Write-ComfyMarker {
    param(
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][object]$PayloadTest
    )
    New-Item -ItemType Directory (Split-Path $Marker -Parent) -Force | Out-Null
    $temporaryMarker = $Marker + '.new'
    [ordered]@{
        schemaVersion='1.0'
        managedBy='KI-STACK-COMFYUI-MANAGED'
        version='1.2.4'
        release='KI-Stack-ComfyUI-Execute-v1.2.4'
        installedAt=[DateTime]::UtcNow.ToString('o')
        payloadId='KI-STACK-COMFYUI-SOURCE-V0.28.0'
        payloadSha256=[string]$PayloadTest.contract.output.sha256
        migration='content-and-marker-verified'
        runtimeGitDependency=$false
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporaryMarker -Encoding UTF8
    Move-Item -LiteralPath $temporaryMarker -Destination $Marker -Force
}

function Test-ComfyMarker {
    param(
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][object]$PayloadTest
    )
    if (-not (Test-Path -LiteralPath $Marker -PathType Leaf)) { return $false }
    $current = Read-ComfyJson $Marker
    [string]$current.version -eq '1.2.4' -and
        [string]$current.release -eq 'KI-Stack-ComfyUI-Execute-v1.2.4' -and
        [string]$current.payloadSha256 -eq [string]$PayloadTest.contract.output.sha256
}

function Install-ComfyPayload {
    param([Parameter(Mandatory)][string]$PackageRoot,[string]$TargetRoot='C:\KI-Stack\ComfyUI',[string]$BackupRoot='C:\KI-Stack\backups\comfyui-1.2.4')
    $test = Test-ComfyPayload $PackageRoot
    if (-not $test.passed) { throw ($test.errors -join '; ') }
    $audit = Test-ComfyTarget $PackageRoot $TargetRoot
    $moduleRoot = Join-Path (Split-Path $TargetRoot -Parent) 'modules/comfyui'
    $marker = Join-Path $moduleRoot 'installation.json'
    $backup = Join-Path $BackupRoot ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    $state = @()
    $changesStarted = $false
    $temp = $null
    try {
        if ($audit.passed -and (Test-ComfyMarker -Marker $marker -PayloadTest $test)) {
            return [pscustomobject]@{passed=$true;changed=$false;status='SkippedAlreadyCompliant';backup=$null;rollbackStatus='NotRequired'}
        }

        New-Item -ItemType Directory $backup -Force | Out-Null
        $markerState = [ordered]@{existed=(Test-Path -LiteralPath $marker);path='installation.json'}
        if ($markerState.existed) { Copy-Item -LiteralPath $marker -Destination (Join-Path $backup 'installation.json') -Force }
        $markerState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $backup 'marker.rollback.json') -Encoding UTF8

        if (-not $audit.passed) {
            $temp = Join-Path $env:TEMP ('ki-comfy-' + [guid]::NewGuid().ToString('N'))
            $manifest = Expand-ComfyPayload $PackageRoot $temp
            foreach ($file in $manifest.files) {
                $source = Join-Path $temp $file.path; $target = Join-Path $TargetRoot $file.path
                if ((Test-Path $target) -and (Get-Item $target).Length -eq $file.sizeBytes -and (Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant() -eq $file.sha256) { continue }
                $record = [ordered]@{path=$file.path;existed=(Test-Path $target)}
                if ($record.existed) {
                    $backupPath = Join-Path $backup $file.path
                    New-Item -ItemType Directory (Split-Path $backupPath -Parent) -Force | Out-Null
                    Copy-Item $target $backupPath -Force
                }
                $state += $record
                $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $backup 'rollback.json') -Encoding UTF8
                $changesStarted = $true
                New-Item -ItemType Directory (Split-Path $target -Parent) -Force | Out-Null
                Copy-Item $source $target -Force
            }
        }

        $changesStarted = $true
        Write-ComfyMarker -Marker $marker -PayloadTest $test
        $targetReadback = Test-ComfyTarget $PackageRoot $TargetRoot
        if (-not $targetReadback.passed -or -not (Test-ComfyMarker -Marker $marker -PayloadTest $test)) {
            throw 'ComfyUI-Payload- oder Marker-Readback fehlgeschlagen.'
        }
        [pscustomobject]@{passed=$true;changed=$true;status='Completed';backup=$backup;files=$state.Count;markerMigrated=$audit.passed;rollbackStatus='NotRequired'}
    }
    catch {
        if ($changesStarted) {
            $rollbackStatus = 'Failed'
            try {
                Restore-ComfyPayload -Backup $backup -TargetRoot $TargetRoot | Out-Null
                $rollbackStatus = 'Completed'
            }
            catch { $rollbackStatus = 'Failed' }
            $_.Exception.Data['KIStackRollbackStatus'] = $rollbackStatus
            $_.Exception.Data['KIStackBackupPath'] = $backup
        }
        throw
    }
    finally { if ($temp -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Recurse -Force } }
}

function Restore-ComfyPayload {
    param([Parameter(Mandatory)][string]$Backup,[string]$TargetRoot='C:\KI-Stack\ComfyUI')
    $rollbackPath = Join-Path $Backup 'rollback.json'
    $state = if (Test-Path -LiteralPath $rollbackPath) { @(Get-Content $rollbackPath -Raw | ConvertFrom-Json) } else { @() }
    foreach ($record in @($state)) {
        if ([IO.Path]::IsPathRooted([string]$record.path) -or [string]$record.path -match '(^|[\\/])\.\.([\\/]|$)') { throw "Unsicherer Rollbackpfad: $($record.path)" }
        $target = Join-Path $TargetRoot $record.path
        if ($record.existed) {
            $backupFile = Join-Path $Backup $record.path
            if (-not (Test-Path -LiteralPath $backupFile -PathType Leaf)) { throw "Rollbackdatei fehlt: $($record.path)" }
            New-Item -ItemType Directory (Split-Path $target -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $backupFile -Destination $target -Force
            if ((Get-FileHash -LiteralPath $backupFile -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) { throw "Rollback-Readback fehlgeschlagen: $($record.path)" }
        }
        elseif (Test-Path $target) { Remove-Item $target -Force }
    }
    $markerStatePath = Join-Path $Backup 'marker.rollback.json'
    $marker = Join-Path (Split-Path $TargetRoot -Parent) 'modules/comfyui/installation.json'
    if (Test-Path -LiteralPath $markerStatePath) {
        $markerState = Read-ComfyJson $markerStatePath
        if ([bool]$markerState.existed) {
            $markerBackup = Join-Path $Backup 'installation.json'
            if (-not (Test-Path -LiteralPath $markerBackup -PathType Leaf)) { throw 'Rollback-Marker fehlt.' }
            New-Item -ItemType Directory (Split-Path $marker -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $markerBackup -Destination $marker -Force
        }
        elseif (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
    }
    elseif (Test-Path -LiteralPath (Join-Path $Backup 'installation.json') -PathType Leaf) {
        New-Item -ItemType Directory (Split-Path $marker -Parent) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $Backup 'installation.json') -Destination $marker -Force
    }
    [pscustomobject]@{passed=$true;status='RolledBack';records=@($state).Count;readbackPassed=$true}
}

Export-ModuleMember -Function *

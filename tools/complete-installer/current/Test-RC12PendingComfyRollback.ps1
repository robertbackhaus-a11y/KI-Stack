[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('KIStack-RC12-Comfy-Rollback-' + [guid]::NewGuid().ToString('N'))
$target = Join-Path $fixture 'target'
$transactionId = 'KI-COMPLETE-RC12-PARTIAL-FIXTURE'
$state = Join-Path $target 'state/complete-installer'
$transactionBase = Join-Path $state 'transactions'
$backupBase = Join-Path $target "backups/complete-installer/$transactionId"
$backup = Join-Path $backupBase 'comfyui/fixture'
$package = Join-Path $fixture 'package'
$payloadDirectory = Join-Path $package 'Payload/ComfyUI'

try {
    New-Item -ItemType Directory -Path $state,$backup,$payloadDirectory,(Join-Path $target 'ComfyUI'),(Join-Path $target 'modules/comfyui') -Force | Out-Null
    $componentArchive = Join-Path $payloadDirectory 'KI-Stack-ComfyUI-Execute-v1.2.4.zip'
    $packagedComponent = Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Payload/ComfyUI') -File -Filter 'KI-Stack-ComfyUI-Execute-v1.2.4.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($packagedComponent) {
        Copy-Item -LiteralPath $packagedComponent.FullName -Destination $componentArchive
    }
    else {
        $componentSource = [IO.Path]::GetFullPath((Join-Path $PackageRoot '../../comfyui/current'))
        if (-not (Test-Path -LiteralPath $componentSource -PathType Container)) { throw 'ComfyUI-Fixturequelle fehlt.' }
        Compress-Archive -Path (Join-Path $componentSource '*') -DestinationPath $componentArchive
    }

    $records = @()
    foreach ($index in 1..684) {
        $relative = ('fixture/file-{0:D4}.txt' -f $index)
        $targetFile = Join-Path (Join-Path $target 'ComfyUI') $relative
        $backupFile = Join-Path $backup $relative
        New-Item -ItemType Directory -Path (Split-Path $targetFile -Parent),(Split-Path $backupFile -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($targetFile,"rc12-$index",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($backupFile,"original-$index",[Text.UTF8Encoding]::new($false))
        $records += [ordered]@{path=$relative;existed=$true}
    }
    $records | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backup 'rollback.json') -Encoding UTF8
    $marker = [ordered]@{schemaVersion='1.0';version='1.2.2';release='KI-Stack-ComfyUI-Execute-v1.2.2'}
    $marker | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target 'modules/comfyui/installation.json') -Encoding UTF8
    $marker | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backup 'installation.json') -Encoding UTF8
    [ordered]@{schemaVersion='1.0';completeInstallerVersion='2.3.0-rc11';components=[ordered]@{comfyui='1.2.2'}} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $state 'components.json') -Encoding UTF8

    $transactionDirectory = Join-Path $transactionBase $transactionId
    New-Item -ItemType Directory -Path $transactionDirectory -Force | Out-Null
    [ordered]@{
        schemaVersion='1.1';transactionId=$transactionId;status='Failed';mode='Upgrade'
        targetRoot=[IO.Path]::GetFullPath($target);stateRoot=[IO.Path]::GetFullPath($state);transactionRoot=[IO.Path]::GetFullPath($transactionDirectory)
        backupRoot=[IO.Path]::GetFullPath((Join-Path $target 'backups/complete-installer'));logRoot=[IO.Path]::GetFullPath((Join-Path $target 'logs/complete-installer'));pathContractVersion='1.0'
        steps=@([ordered]@{
            id='comfyui';version='1.2.3';status='Failed';rollbackStatus=$null
            result=[ordered]@{install=[ordered]@{changed=$true;backup=$backup;files=684}}
        })
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $transactionDirectory 'transaction.json') -Encoding UTF8

    Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force
    $context=New-KICompletePathContext -TargetRoot $target -PackageRoot $package -Mutating
    $recovery = Invoke-KICompletePendingComponentRollback -PackageRoot $package -TargetRoot $target -PathContext $context
    if (-not $recovery.passed -or $recovery.status -ne 'PendingRollbackCompleted') { throw 'RC12-Teilinstallation wurde nicht erkannt.' }
    $updated = Get-Content -LiteralPath (Join-Path $transactionDirectory 'transaction.json') -Raw | ConvertFrom-Json
    if ([string]$updated.steps[0].rollbackStatus -ne 'Completed' -or [int]$updated.recovery.records -ne 684) { throw 'Rollbackstatus oder Datensatzzahl ist falsch.' }
    $owner=Get-Content -LiteralPath (Join-Path $backup 'recovery-owner.json') -Raw|ConvertFrom-Json
    if([string]$owner.transactionId-ne$transactionId-or[string]$owner.componentId-ne'comfyui'-or-not(Test-KICompleteSameRoot -First ([string]$owner.targetRoot) -Second $target)){throw 'Recovery-Backup-Owner-Metadaten sind nicht rootgebunden.'}
    foreach ($index in 1..684) {
        $path = Join-Path (Join-Path $target 'ComfyUI') ('fixture/file-{0:D4}.txt' -f $index)
        if ((Get-Content -LiteralPath $path -Raw) -ne "original-$index") { throw "Rollback-Readback fehlgeschlagen: $index" }
    }
    $stored = (Get-Content -LiteralPath (Join-Path $state 'components.json') -Raw | ConvertFrom-Json).components.comfyui
    $real = (Get-Content -LiteralPath (Join-Path $target 'modules/comfyui/installation.json') -Raw | ConvertFrom-Json).version
    if ($stored -ne '1.2.2' -or $real -ne '1.2.2') { throw 'Ausgangsstand wurde vor der Neuinstallation verändert.' }

    [pscustomobject]@{
        passed=$true
        fixture='RC12 partial ComfyUI deployment'
        exchangedFiles=684
        markerBeforeAndAfterRollback='1.2.2'
        componentsBeforeAndAfterRollback='1.2.2'
        rollbackStatus='Completed'
        installationMayBegin=$true
    } | ConvertTo-Json -Depth 10
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}

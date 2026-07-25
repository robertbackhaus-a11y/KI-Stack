[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('KIStack-RC12-Comfy-Rollback-' + [guid]::NewGuid().ToString('N'))
$target = Join-Path $fixture 'target'
$state = Join-Path $target 'state/complete-installer'
$backup = Join-Path $target 'backups/comfyui-1.2.3/fixture'
$package = Join-Path $fixture 'package'
$payloadDirectory = Join-Path $package 'Payload/ComfyUI'
$transactionId = 'KI-COMPLETE-RC12-PARTIAL-FIXTURE'

try {
    New-Item -ItemType Directory -Path $state,$backup,$payloadDirectory,(Join-Path $target 'ComfyUI'),(Join-Path $target 'modules/comfyui') -Force | Out-Null
    $componentSource = [IO.Path]::GetFullPath((Join-Path $PackageRoot '../../comfyui/current'))
    $componentArchive = Join-Path $payloadDirectory 'KI-Stack-ComfyUI-Execute-v1.2.4.zip'
    Compress-Archive -Path (Join-Path $componentSource '*') -DestinationPath $componentArchive

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

    $transactionDirectory = Join-Path $state $transactionId
    New-Item -ItemType Directory -Path $transactionDirectory -Force | Out-Null
    [ordered]@{
        schemaVersion='1.0';transactionId=$transactionId;status='Failed';mode='Upgrade'
        steps=@([ordered]@{
            id='comfyui';version='1.2.3';status='Failed';rollbackStatus=$null
            result=[ordered]@{install=[ordered]@{changed=$true;backup=$backup;files=684}}
        })
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $transactionDirectory 'transaction.json') -Encoding UTF8

    Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force
    $recovery = Invoke-KICompletePendingComponentRollback -PackageRoot $package -TargetRoot $target -StateDirectory $state
    if (-not $recovery.passed -or $recovery.status -ne 'PendingRollbackCompleted') { throw 'RC12-Teilinstallation wurde nicht erkannt.' }
    $updated = Get-Content -LiteralPath (Join-Path $transactionDirectory 'transaction.json') -Raw | ConvertFrom-Json
    if ([string]$updated.steps[0].rollbackStatus -ne 'Completed' -or [int]$updated.recovery.records -ne 684) { throw 'Rollbackstatus oder Datensatzzahl ist falsch.' }
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

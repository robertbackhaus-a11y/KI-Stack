[CmdletBinding()]
param(
    [ValidateSet('DryRun','Execute','Validate','Rollback')][string]$Action = 'DryRun',
    [string]$Endpoint = 'http://127.0.0.1:8080',
    [string]$BaseModelId = '',
    [Security.SecureString]$ApiToken,
    [string]$BackupPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$packageRoot = $PSScriptRoot
Import-Module (Join-Path $packageRoot 'OpenWebUIAgentPack.psm1') -Force

if ($Action -eq 'DryRun') {
    $definitions = Get-ChildItem -LiteralPath (Join-Path $packageRoot 'Definitions') -File -Filter '*.json' |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 30 }
    [ordered]@{
        version = '1.8.1'
        action = 'DryRun'
        endpoint = $Endpoint
        baseModelResolution = if ([string]::IsNullOrWhiteSpace($BaseModelId)) { 'runtime-required-when-not-unique' } else { 'explicit-runtime-parameter' }
        managedIds = @($definitions.id)
        plannedOperations = @('read offered models','resolve exact base model','backup affected IDs','create or update affected IDs','API readback')
        mutatesTarget = $false
    } | ConvertTo-Json -Depth 10
    return
}

if ($null -eq $ApiToken) {
    $ApiToken = Read-Host 'Temporären OpenWebUI API-Key eingeben' -AsSecureString
}

try {
    switch ($Action) {
        'Execute' {
            $transactionId = 'OWUI-AGENT-PACK-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff')
            $backupDirectory = Join-Path 'C:\KI-Stack\backups\openwebui-agent-pack' $transactionId
            $result = Install-OpenWebUIAgentPack -PackageRoot $packageRoot -Endpoint $Endpoint -ApiToken $ApiToken -BaseModelId $BaseModelId -BackupDirectory $backupDirectory
            $validation = Test-OpenWebUIAgentPack -PackageRoot $packageRoot -Endpoint $Endpoint -ApiToken $ApiToken -BaseModelId ([string]$result.baseModelId)
            if (-not $validation.passed) { throw ('Readback fehlgeschlagen: ' + ($validation.failures -join '; ')) }
            [ordered]@{ version='1.8.1'; action='Execute'; passed=$true; baseModelId=$result.baseModelId; backupPath=$result.backupPath; operations=$result.actions } | ConvertTo-Json -Depth 10
        }
        'Validate' {
            if ([string]::IsNullOrWhiteSpace($BaseModelId)) { throw 'Validate erfordert BaseModelId.' }
            $validation = Test-OpenWebUIAgentPack -PackageRoot $packageRoot -Endpoint $Endpoint -ApiToken $ApiToken -BaseModelId $BaseModelId
            $validation | ConvertTo-Json -Depth 10
            if (-not $validation.passed) { throw ('Validierung fehlgeschlagen: ' + ($validation.failures -join '; ')) }
        }
        'Rollback' {
            if ([string]::IsNullOrWhiteSpace($BackupPath)) { throw 'Rollback erfordert BackupPath.' }
            Restore-OpenWebUIAgentPack -Endpoint $Endpoint -ApiToken $ApiToken -BackupPath $BackupPath
            [ordered]@{ version='1.8.1'; action='Rollback'; passed=$true; backupPath=$BackupPath } | ConvertTo-Json
        }
    }
}
finally {
    $ApiToken = $null
    [GC]::Collect()
}

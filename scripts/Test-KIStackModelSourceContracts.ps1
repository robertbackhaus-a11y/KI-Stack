[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $RootPath 'package\Manifests\models.manifest.json'
$payloadPath = Join-Path $RootPath 'tools\complete-installer\current\Contracts\PAYLOADS.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 100
$payloads = Get-Content -LiteralPath $payloadPath -Raw | ConvertFrom-Json -Depth 100
$manual = @($manifest.models | Where-Object { [bool]$_.manualExternal })
$errors = [System.Collections.Generic.List[string]]::new()

if ($manual.Count -ne 7) { $errors.Add("Expected seven manual external models, found $($manual.Count).") }
foreach ($model in $manual) {
    foreach ($field in 'fileName','sizeBytes','sha256','publisher','informationSource','sourceKind','relativeTargetPath') {
        if (-not $model.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$model.$field)) { $errors.Add("$($model.id): missing $field.") }
    }
    if ($null -ne $model.source -or $null -ne $model.installationSource) { $errors.Add("$($model.id): manual model must not have an installation source.") }
    if ([string]$model.sourceKind -ne 'manual-external-information-only') { $errors.Add("$($model.id): invalid source kind.") }
    if ([string]$model.informationSource -match '(?i)/resolve/main/') { $errors.Add("$($model.id): mutable resolve/main is not allowed as an information source.") }
    if ([string]$model.sha256 -notmatch '^[0-9a-f]{64}$' -or [int64]$model.sizeBytes -le 0) { $errors.Add("$($model.id): invalid integrity anchor.") }
    $payload = @($payloads.external | Where-Object { $_.id -eq $model.id })
    if ($payload.Count -ne 1 -or [string]$payload[0].informationSource -ne [string]$model.informationSource -or $null -ne $payload[0].installationSource -or [string]$payload[0].sha256 -ne [string]$model.sha256 -or [int64]$payload[0].sizeBytes -ne [int64]$model.sizeBytes) { $errors.Add("$($model.id): complete-installer contract differs.") }
}

$pony = @($manifest.models | Where-Object { $_.id -eq 'pony-v6-xl' })
if ($pony.Count -ne 1 -or [bool]$pony[0].manualExternal -or [string]$pony[0].source -ne 'https://civitai.com/api/download/models/290640' -or [string]$pony[0].sourceKind -ne 'automatic-external-payload') { $errors.Add('Pony automatic external contract differs.') }

$lmStudioModel = $manifest.lmStudioModel
$payloadLmStudioModel = $payloads.lmStudioModel
if ($null -eq $lmStudioModel -or $null -eq $payloadLmStudioModel) {
    $errors.Add('LM Studio model contract is missing.')
} else {
    foreach ($field in 'id','publisher','informationSource','sourceKind','relativeTargetDirectory','expectedLmStudioModelId','license') {
        if (-not $lmStudioModel.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$lmStudioModel.$field)) { $errors.Add("LM Studio contract: missing $field.") }
        if ([string]$payloadLmStudioModel.$field -ne [string]$lmStudioModel.$field) { $errors.Add("LM Studio contract: payload differs for $field.") }
    }
    if ($null -ne $lmStudioModel.installationSource -or [string]$lmStudioModel.sourceKind -ne 'manual-external-information-only' -or -not [bool]$lmStudioModel.manualExternal) { $errors.Add('LM Studio model must remain manual external information only.') }
    if ([string]$lmStudioModel.informationSource -match '(?i)/resolve/main/') { $errors.Add('LM Studio information source must not use mutable resolve/main.') }
    if (@($lmStudioModel.files).Count -ne 2 -or @($payloadLmStudioModel.files).Count -ne 2) { $errors.Add('LM Studio contract must contain exactly two files.') }
    foreach ($file in @($lmStudioModel.files)) {
        foreach ($field in 'id','fileName','sizeBytes','sha256','role','quantization') { if (-not $file.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$file.$field)) { $errors.Add("LM Studio file $($file.id): missing $field.") } }
        if ([string]$file.sha256 -notmatch '^[0-9a-f]{64}$' -or [int64]$file.sizeBytes -le 0) { $errors.Add("LM Studio file $($file.id): invalid integrity anchor.") }
        $payloadFile = @($payloadLmStudioModel.files | Where-Object { $_.id -eq $file.id })
        if ($payloadFile.Count -ne 1 -or [string]$payloadFile[0].fileName -ne [string]$file.fileName -or [int64]$payloadFile[0].sizeBytes -ne [int64]$file.sizeBytes -or [string]$payloadFile[0].sha256 -ne [string]$file.sha256) { $errors.Add("LM Studio file $($file.id): complete-installer contract differs.") }
    }
}

[pscustomobject]@{
    passed = ($errors.Count -eq 0)
    manualExternalModels = $manual.Count
    automaticExternalModel = 'pony-v6-xl'
    lmStudioManualExternalFiles = @($lmStudioModel.files).Count
    errors = @($errors)
} | ConvertTo-Json -Depth 10

if ($errors.Count) { exit 1 }

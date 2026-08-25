[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath (Join-Path $PackageRoot 'Manifests\models.manifest.json') -Raw | ConvertFrom-Json
if (@($manifest.models).Count -ne 9) { throw 'Exactly nine visual model contracts are required.' }
$names = @($manifest.models.fileName)
foreach ($required in @(
    'z_image_turbo_bf16.safetensors',
    'Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf',
    'wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors',
    'wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors',
    'Wan2.2_LightX2V_high_n54vv.safetensors',
    'Wan2.2_LightX2V_low_n54vv.safetensors'
)) { if ($required -notin $names) { throw "Missing model contract: $required" } }
foreach($model in @($manifest.models)){
    if([string]$model.sha256 -notmatch '^[0-9a-f]{64}$'){throw "Missing SHA256: $($model.fileName)"}
    if([long]$model.sizeBytes -le 0){throw "Invalid size: $($model.fileName)"}
    if(@($model.sources).Count -lt 1){throw "Missing versioned source: $($model.fileName)"}
    foreach($source in @($model.sources)){
        if([string]$source -notmatch '^https://huggingface\.co/.+/resolve/[0-9a-f]{40}/'){throw "Source is not revision-bound: $source"}
    }
}
foreach($file in @($manifest.lmStudio.files)){
    if([string]$file.sha256 -notmatch '^[0-9a-f]{64}$' -or @($file.sources).Count -lt 1){throw "Incomplete LM Studio download contract: $($file.fileName)"}
}
$downloadTest = & (Join-Path $PackageRoot 'Tests\Test-KIStackModelDownloadContract.ps1') -PackageRoot $PackageRoot | ConvertFrom-Json
if(-not[bool]$downloadTest.passed){throw 'Greenfield download regression failed.'}
$workflows = @(Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Workflows') -File -Filter '*.json')
if ($workflows.Count -ne 2) { throw 'Exactly two internal API prompts are required.' }
foreach($workflow in $workflows){
    $prompt=Get-Content -LiteralPath $workflow.FullName -Raw|ConvertFrom-Json -Depth 100
    if($prompt.PSObject.Properties.Name -contains 'nodes'){throw "API prompt must not be published as a UI workflow: $($workflow.Name)"}
}
$packageManifest=Get-Content -LiteralPath (Join-Path $PackageRoot 'MANIFEST.json') -Raw|ConvertFrom-Json
if(@($packageManifest.publishedUiWorkflows).Count-ne0){throw 'Models / Workflows must not publish API prompts as UI workflows.'}
if(@($packageManifest.internalApiPrompts).Count-ne2){throw 'Internal API prompt manifest is incomplete.'}
$importerSource=Get-Content -LiteralPath (Join-Path $PackageRoot 'Import-KIStackExternalModels.ps1') -Raw
if($importerSource -match 'Copy-Item\s+-Destination\s+\$workflowTarget'){throw 'Internal API prompts are still copied into the UI workflow browser.'}
if($importerSource -notmatch 'workflows=@\(\);internalApiPrompts=\$internalApiPrompts'){throw 'Installed marker does not distinguish UI workflows from internal API prompts.'}
Write-Host 'VISUAL MODELS / WORKFLOWS TEST PASSED (including 11 Greenfield download regressions).'

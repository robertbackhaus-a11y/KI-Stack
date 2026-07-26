[CmdletBinding()]
param([string]$RootPath = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath (Join-Path $RootPath 'tools\models-workflows\current\Manifests\models.manifest.json') -Raw | ConvertFrom-Json -Depth 100
$payloads = Get-Content -LiteralPath (Join-Path $RootPath 'tools\complete-installer\current\Contracts\PAYLOADS.json') -Raw | ConvertFrom-Json -Depth 100
$errors = [Collections.Generic.List[string]]::new()
$models=@($manifest.models)
if([string]$payloads.modelContractAuthority.sourcePath-ne'tools/models-workflows/current/Manifests/models.manifest.json' -or
   [string]$payloads.modelContractAuthority.packagedArchive-ne'Payload/ModelsWorkflows/KI-Stack-Visual-Models-Workflows-v2.0.2.zip' -or
   [string]$payloads.modelContractAuthority.schemaVersion-ne[string]$manifest.schemaVersion){
    $errors.Add('Complete Installer does not point uniquely to the authoritative Models/Workflows manifest.')
}
if($payloads.PSObject.Properties.Name-contains'external' -or $payloads.PSObject.Properties.Name-contains'lmStudioModel'){
    $errors.Add('Competing model download contract remains in PAYLOADS.json.')
}
if($models.Count-ne9){$errors.Add("Expected nine visual models, found $($models.Count).")}
if([long]($models|Measure-Object sizeBytes -Sum).Sum-ne54994650267){$errors.Add('Visual model byte total differs.')}
foreach($model in $models){
    foreach($field in 'id','fileName','sizeBytes','sha256','relativeTargetPath','sources'){
        if(-not$model.PSObject.Properties[$field]){$errors.Add("$($model.id): missing $field.")}
    }
    if([string]$model.sha256-notmatch'^[0-9a-f]{64}$'-or[long]$model.sizeBytes-le0){$errors.Add("$($model.id): invalid integrity anchor.")}
    if(@($model.sources).Count-lt1-or@($model.sources|Where-Object{[string]$_-notmatch'^https://huggingface\.co/.+/resolve/[0-9a-f]{40}/'}).Count){$errors.Add("$($model.id): source is absent or not revision-bound.")}
}
$qwen=@($models|Where-Object { $_.id -eq 'z-image-qwen3-4b' })
if($qwen.Count-ne1-or$qwen.fileName-ne'Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf'-or$qwen.sha256-ne'be7b7285f6b80daef5b15affbe96d6626c308ef53dae878568b36664099c71d0'){$errors.Add('Public Qwen manufacturer contract differs.')}
foreach($file in @($manifest.lmStudio.files)){
    if([string]$file.sha256-notmatch'^[0-9a-f]{64}$'-or@($file.sources).Count-lt1-or@($file.sources|Where-Object{[string]$_-notmatch'^https://huggingface\.co/.+/resolve/[0-9a-f]{40}/'}).Count){$errors.Add("LM Studio file $($file.id): incomplete versioned download contract.")}
}
[pscustomobject]@{passed=($errors.Count-eq0);visualModels=$models.Count;automaticArtifacts=$models.Count+@($manifest.lmStudio.files).Count;manualPreloadsRequired=0;errors=@($errors)}|ConvertTo-Json -Depth 10
if($errors.Count){exit 1}

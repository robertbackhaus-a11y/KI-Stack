[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-ComfyUIValidation-'+[guid]::NewGuid().ToString('N'))
$oldState=$env:KI_TEST_COMFY_ENVIRONMENT_STATE
try {
    $root=Join-Path $temp 'ComfyUI'
    $venv=Join-Path $temp 'venv'
    $moduleRoot=Join-Path $temp 'module'
    $modelsRoot=Join-Path $temp 'models'
    $modelDirectories=@(
        'checkpoints','text_encoders','clip','clip_vision','configs','controlnet',
        'diffusion_models','unet','embeddings','loras','upscale_models','vae',
        'audio_encoders','model_patches'
    )|ForEach-Object { Join-Path $modelsRoot $_ }
    $requiredDirectories=@(
        $root,(Join-Path $root '.git'),(Join-Path $venv 'Scripts'),$moduleRoot,$modelsRoot,
        (Join-Path $temp 'custom_nodes'),(Join-Path $temp 'input'),(Join-Path $temp 'output'),
        (Join-Path $temp 'user')
    )+@($modelDirectories)
    $requiredDirectories|ForEach-Object { New-Item -ItemType Directory -Path $_ -Force|Out-Null }
    @(
        (Join-Path $root 'main.py'),(Join-Path $root 'requirements.txt'),
        (Join-Path $venv 'Scripts/python.exe'),(Join-Path $temp 'extra_model_paths.yaml'),
        (Join-Path $moduleRoot 'Start-KIStack-ComfyUI.cmd'),
        (Join-Path $moduleRoot 'Stop-KIStack-ComfyUI.cmd'),
        (Join-Path $moduleRoot 'Stop-KIStack-ComfyUI.ps1')
    )|ForEach-Object { New-Item -ItemType File -Path $_ -Force|Out-Null }

    $config=[pscustomobject]@{comfyUI=[pscustomobject]@{
        root=$root;venv=$venv;moduleRoot=$moduleRoot;modelsRoot=$modelsRoot
        customNodesRoot=(Join-Path $temp 'custom_nodes');extraModelPathsConfig=(Join-Path $temp 'extra_model_paths.yaml')
        inputDirectory=(Join-Path $temp 'input');outputDirectory=(Join-Path $temp 'output');userDirectory=(Join-Path $temp 'user')
        repository='https://github.com/comfyanonymous/ComfyUI.git';ref='v0.28.0';listenAddress='127.0.0.1';port=8188
        torch=[pscustomobject]@{requireCuda=$true;minimumComputeCapabilityMajor=12;expectedDeviceNamePattern='RTX 5090'}
    }}
    $context=[pscustomobject]@{Config=$config;Mode='Execute'}
    $modulePath=Join-Path $ProjectRoot 'Modules/04-ComfyUI/KIModuleComfyUI.psm1'
    $module=Import-Module $modulePath -Force -PassThru
    & $module {
        function script:Get-KIComfyGitCommand { 'git.exe' }
        function script:Get-KIComfyRepositoryState {
            [pscustomobject]@{valid=$true;normalizedOrigin='https://github.com/comfy-org/comfyui';exactTag='v0.28.0';dirty=$false}
        }
        function script:Get-KIComfyEnvironmentState {
            $env:KI_TEST_COMFY_ENVIRONMENT_STATE|ConvertFrom-Json -Depth 20
        }
    }

    $statePath=Join-Path $moduleRoot 'installation.json'
    [IO.File]::WriteAllText($statePath,('{"managedBy":"KI-STACK-COMFYUI-MANAGED","tag":"v0.28.0","cudaAvailable":false}'),[Text.UTF8Encoding]::new($false))
    $env:KI_TEST_COMFY_ENVIRONMENT_STATE='{"valid":true,"pythonVersion":"3.12.10","torchVersion":"2.13+cu130","torchCudaVersion":"13.0","comfyImport":true,"cudaAvailable":false,"deviceName":null,"computeCapability":[null],"error":null}'
    $withoutGpu=Validate-KIModuleComfyUI -Context $context

    [IO.File]::WriteAllText($statePath,('{"managedBy":"KI-STACK-COMFYUI-MANAGED","tag":"v0.28.0","cudaAvailable":true}'),[Text.UTF8Encoding]::new($false))
    $env:KI_TEST_COMFY_ENVIRONMENT_STATE='{"valid":true,"pythonVersion":"3.12.10","torchVersion":"2.13+cu130","torchCudaVersion":"13.0","comfyImport":true,"cudaAvailable":true,"deviceName":"NVIDIA GeForce RTX 5090","computeCapability":[12,0],"error":null}'
    $withGpu=Validate-KIModuleComfyUI -Context $context

    $passed=([bool]$withoutGpu.success)-and(-not[bool]$withoutGpu.data.gpuReady)-and@($withoutGpu.data.gpuIssues).Count-ge1-and([bool]$withGpu.success)-and([bool]$withGpu.data.gpuReady)-and@($withGpu.data.gpuIssues).Count-eq0
    [pscustomobject]@{passed=$passed;caseA=[ordered]@{installationValid=[bool]$withoutGpu.success;gpuReady=[bool]$withoutGpu.data.gpuReady;formatError=$false};caseB=[ordered]@{installationValid=[bool]$withGpu.success;gpuReady=[bool]$withGpu.data.gpuReady};targetSystemAccessed=$false}|ConvertTo-Json -Depth 10
    if(-not $passed){throw 'ComfyUI-Validierungsregression fehlgeschlagen.'}
} finally {
    Remove-Module KIModuleComfyUI -Force -ErrorAction SilentlyContinue
    $env:KI_TEST_COMFY_ENVIRONMENT_STATE=$oldState
    if(Test-Path $temp){Remove-Item $temp -Recurse -Force}
}

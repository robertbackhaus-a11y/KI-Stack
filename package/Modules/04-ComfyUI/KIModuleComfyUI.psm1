Set-StrictMode -Version Latest

function Get-KIComfyProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}

function Get-KIComfyPythonCommand {
    $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($pythonCommand) { return $pythonCommand }
    return Get-Command python -ErrorAction SilentlyContinue
}

function Get-KIComfyGitCommand {
    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($gitCommand) { return $gitCommand }
    return Get-Command git -ErrorAction SilentlyContinue
}

function ConvertTo-KIComfyNormalizedRepositoryUrl {
    param([Parameter(Mandatory)][string]$Url)

    $normalized = $Url.Trim().Replace('\\','/').TrimEnd('/').ToLowerInvariant()
    if ($normalized.EndsWith('.git')) {
        $normalized = $normalized.Substring(0, $normalized.Length - 4)
    }
    $normalized = $normalized.Replace(
        'github.com/comfyanonymous/comfyui',
        'github.com/comfy-org/comfyui'
    )
    return $normalized
}

function Get-KIComfyRollbackStatePath {
    param([Parameter(Mandatory)][object]$Context)

    $stateDirectory = Join-Path ([string]$Context.TransactionDirectory) 'module-state'
    if (-not (Test-Path -LiteralPath $stateDirectory)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }
    return Join-Path $stateDirectory 'KIModuleComfyUI.rollback.json'
}

function Write-KIComfyRollbackState {
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][object]$State
    )

    $path = Get-KIComfyRollbackStatePath -Context $Context
    $temporaryPath = '{0}.tmp' -f $path
    $State.updatedAt = (Get-Date).ToString('o')
    $State | ConvertTo-Json -Depth 50 |
        Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $path -Force
}

function Read-KIComfyRollbackState {
    param([Parameter(Mandatory)][object]$Context)

    $path = Get-KIComfyRollbackStatePath -Context $Context
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $path -Raw -ErrorAction Stop |
        ConvertFrom-Json -Depth 50 -ErrorAction Stop
}

function Invoke-KIComfyNativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Description,
        [string]$WorkingDirectory
    )

    $locationChanged = $false
    try {
        if ($WorkingDirectory) {
            Push-Location -LiteralPath $WorkingDirectory
            $locationChanged = $true
        }

        Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Description)
        & $FilePath @Arguments 2>&1 | ForEach-Object { Write-Host ([string]$_) }
        $nativeExitCode = [int]$LASTEXITCODE
        if ($nativeExitCode -ne 0) {
            throw ('{0} Exitcode: {1}' -f $Description, $nativeExitCode)
        }
    }
    finally {
        if ($locationChanged) { Pop-Location }
    }
}

function Get-KIComfyRepositoryState {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][object]$GitCommand
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return [pscustomobject][ordered]@{
            exists = $false
            valid = $false
            origin = $null
            normalizedOrigin = $null
            head = $null
            exactTag = $null
            dirty = $false
            missingPaths = @($Root)
        }
    }

    $requiredPaths = @(
        (Join-Path $Root '.git'),
        (Join-Path $Root 'main.py'),
        (Join-Path $Root 'requirements.txt')
    )
    $missingPaths = @(
        $requiredPaths | Where-Object { -not (Test-Path -LiteralPath $_) }
    )

    $originOutput = @(& $GitCommand.Source -C $Root remote get-url origin 2>$null)
    $originExitCode = [int]$LASTEXITCODE
    $headOutput = @(& $GitCommand.Source -C $Root rev-parse HEAD 2>$null)
    $headExitCode = [int]$LASTEXITCODE
    $tagOutput = @(& $GitCommand.Source -C $Root describe --tags --exact-match 2>$null)
    $tagExitCode = [int]$LASTEXITCODE
    $statusOutput = @(& $GitCommand.Source -C $Root status --porcelain 2>$null)
    $statusExitCode = [int]$LASTEXITCODE

    $origin = if ($originExitCode -eq 0) {
        [string]($originOutput | Select-Object -Last 1)
    } else { $null }
    $head = if ($headExitCode -eq 0) {
        [string]($headOutput | Select-Object -Last 1)
    } else { $null }
    $exactTag = if ($tagExitCode -eq 0) {
        [string]($tagOutput | Select-Object -Last 1)
    } else { $null }

    return [pscustomobject][ordered]@{
        exists = $true
        valid = (
            $missingPaths.Count -eq 0 -and
            $originExitCode -eq 0 -and
            $headExitCode -eq 0 -and
            $statusExitCode -eq 0
        )
        origin = $origin
        normalizedOrigin = if ($origin) {
            ConvertTo-KIComfyNormalizedRepositoryUrl -Url $origin
        } else { $null }
        head = $head
        exactTag = $exactTag
        dirty = (@($statusOutput).Count -gt 0)
        missingPaths = $missingPaths
    }
}

function Get-KIComfyEnvironmentState {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$VenvPython
    )

    if (-not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            valid = $false
            error = "Venv-Python fehlt: $VenvPython"
            pythonVersion = $null
            torchVersion = $null
            torchCudaVersion = $null
            cudaAvailable = $false
            deviceName = $null
            computeCapability = $null
            comfyImport = $false
        }
    }

    $probe = @'
import json
import sys
result = {
    "pythonVersion": sys.version.split()[0],
    "torchVersion": None,
    "torchCudaVersion": None,
    "cudaAvailable": False,
    "deviceName": None,
    "computeCapability": None,
    "comfyImport": False,
    "error": None,
}
try:
    import torch
    result["torchVersion"] = str(torch.__version__)
    result["torchCudaVersion"] = str(torch.version.cuda) if torch.version.cuda else None
    result["cudaAvailable"] = bool(torch.cuda.is_available())
    if result["cudaAvailable"]:
        result["deviceName"] = str(torch.cuda.get_device_name(0))
        capability = torch.cuda.get_device_capability(0)
        result["computeCapability"] = [int(capability[0]), int(capability[1])]
    import comfy
    result["comfyImport"] = True
except Exception as exc:
    result["error"] = f"{type(exc).__name__}: {exc}"
print(json.dumps(result, ensure_ascii=False))
'@

    $probeOutput = @()
    $probeExitCode = 1
    Push-Location -LiteralPath $Root
    try {
        $probeOutput = @(& $VenvPython -c $probe 2>&1)
        $probeExitCode = [int]$LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    $jsonLine = @(
        $probeOutput |
        ForEach-Object { [string]$_ } |
        Where-Object { $_.TrimStart().StartsWith('{') }
    ) | Select-Object -Last 1

    if ($probeExitCode -ne 0 -or -not $jsonLine) {
        return [pscustomobject][ordered]@{
            valid = $false
            error = ('Umgebungsprüfung fehlgeschlagen. Exitcode {0}. Ausgabe: {1}' -f
                $probeExitCode,
                ((@($probeOutput) | ForEach-Object { [string]$_ }) -join ' | ')
            )
            pythonVersion = $null
            torchVersion = $null
            torchCudaVersion = $null
            cudaAvailable = $false
            deviceName = $null
            computeCapability = $null
            comfyImport = $false
        }
    }

    $parsed = $jsonLine | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    return [pscustomobject][ordered]@{
        valid = (-not [string]$parsed.error -and [bool]$parsed.comfyImport)
        error = $parsed.error
        pythonVersion = $parsed.pythonVersion
        torchVersion = $parsed.torchVersion
        torchCudaVersion = $parsed.torchCudaVersion
        cudaAvailable = [bool]$parsed.cudaAvailable
        deviceName = $parsed.deviceName
        computeCapability = @($parsed.computeCapability)
        comfyImport = [bool]$parsed.comfyImport
    }
}

function New-KIComfyManagedFile {
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][object]$RollbackState,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][ValidateSet('ASCII','UTF8')][string]$Encoding
    )

    $existing = Test-Path -LiteralPath $Path -PathType Leaf
    $previousContentBase64 = $null
    if ($existing) {
        $existingText = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if (-not $existingText.Contains('KI-STACK-COMFYUI-MANAGED')) {
            throw "Nicht verwaltete Datei wird nicht überschrieben: $Path"
        }
        $previousContentBase64 = [Convert]::ToBase64String(
            [IO.File]::ReadAllBytes($Path)
        )
    }

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $RollbackState.createdDirectories = @($RollbackState.createdDirectories) + @($parent)
    }

    $RollbackState.managedFiles = @($RollbackState.managedFiles) + @(
        [pscustomobject][ordered]@{
            path = $Path
            existedBefore = $existing
            previousContentBase64 = $previousContentBase64
        }
    )
    Write-KIComfyRollbackState -Context $Context -State $RollbackState

    if ($Encoding -eq 'ASCII') {
        [IO.File]::WriteAllText($Path, $Content, [Text.Encoding]::ASCII)
    }
    else {
        [IO.File]::WriteAllText(
            $Path,
            $Content,
            [Text.UTF8Encoding]::new($false)
        )
    }
}

function Get-KIComfyManagedContent {
    param([Parameter(Mandatory)][object]$Config)

    $root = [string]$Config.comfyUI.root
    $venvPython = Join-Path ([string]$Config.comfyUI.venv) 'Scripts\python.exe'
    $moduleRoot = [string]$Config.comfyUI.moduleRoot
    $modelConfig = [string]$Config.comfyUI.extraModelPathsConfig
    $listenAddress = [string]$Config.comfyUI.listenAddress
    $port = [int]$Config.comfyUI.port
    $inputDirectory = [string]$Config.comfyUI.inputDirectory
    $outputDirectory = [string]$Config.comfyUI.outputDirectory
    $userDirectory = [string]$Config.comfyUI.userDirectory
    $enableManagerArgument = if ([bool]$Config.comfyUI.enableManager) {
        ' --enable-manager'
    } else { '' }

    $extraModelPaths = @"
# KI-STACK-COMFYUI-MANAGED
ki_stack:
  base_path: $([string]$Config.comfyUI.modelsRoot)
  is_default: true
  checkpoints: checkpoints
  text_encoders: |
    text_encoders
    clip
  clip_vision: clip_vision
  configs: configs
  controlnet: controlnet
  diffusion_models: |
    diffusion_models
    unet
  embeddings: embeddings
  loras: loras
  upscale_models: upscale_models
  vae: vae
  audio_encoders: audio_encoders
  model_patches: model_patches
"@

    $startCmd = @"
@echo off
rem KI-STACK-COMFYUI-MANAGED
setlocal EnableExtensions DisableDelayedExpansion
set "COMFY_ROOT=$root"
set "COMFY_PYTHON=$venvPython"
set "MODEL_CONFIG=$modelConfig"
set "PYTHONNOUSERSITE=1"
set "PIP_DISABLE_PIP_VERSION_CHECK=1"

if not exist "%COMFY_PYTHON%" (
  echo FEHLER: ComfyUI-Python fehlt: %COMFY_PYTHON%
  pause
  exit /b 1
)
if not exist "%COMFY_ROOT%\main.py" (
  echo FEHLER: ComfyUI main.py fehlt: %COMFY_ROOT%\main.py
  pause
  exit /b 1
)

pushd "%COMFY_ROOT%"
"%COMFY_PYTHON%" "%COMFY_ROOT%\main.py" --listen "$listenAddress" --port $port --extra-model-paths-config "%MODEL_CONFIG%" --input-directory "$inputDirectory" --output-directory "$outputDirectory" --user-directory "$userDirectory"$enableManagerArgument
set "EXITCODE=%ERRORLEVEL%"
popd
echo.
echo ComfyUI wurde beendet. Exitcode: %EXITCODE%
pause
exit /b %EXITCODE%
"@

    $stopPs1 = @"
# KI-STACK-COMFYUI-MANAGED
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$rootNeedle = '$($root.Replace("'","''"))'.ToLowerInvariant()
`$mainNeedle = 'main.py'
`$matchingProcesses = @(
    Get-CimInstance Win32_Process -ErrorAction Stop |
    Where-Object {
        `$commandLine = [string]`$_.CommandLine
        `$commandLine -and
        `$commandLine.ToLowerInvariant().Contains(`$rootNeedle) -and
        `$commandLine.ToLowerInvariant().Contains(`$mainNeedle)
    }
)
if (`$matchingProcesses.Count -eq 0) {
    Write-Host 'Kein laufender KI-Stack-ComfyUI-Prozess gefunden.'
    exit 0
}
foreach (`$processEntry in `$matchingProcesses) {
    Stop-Process -Id ([int]`$processEntry.ProcessId) -Force -ErrorAction Stop
    Write-Host ('ComfyUI-Prozess beendet: PID {0}' -f `$processEntry.ProcessId)
}
"@

    $stopCmd = @"
@echo off
rem KI-STACK-COMFYUI-MANAGED
setlocal EnableExtensions DisableDelayedExpansion
set "PWSH="
if defined ProgramW6432 if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined PWSH if defined ProgramFiles if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH set "PWSH=%%~fI"
if not defined PWSH (
  echo FEHLER: PowerShell 7 wurde nicht gefunden.
  pause
  exit /b 1
)
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$moduleRoot\Stop-KIStack-ComfyUI.ps1"
set "EXITCODE=%ERRORLEVEL%"
pause
exit /b %EXITCODE%
"@

    return [pscustomobject][ordered]@{
        extraModelPaths = $extraModelPaths
        startCmd = $startCmd
        stopPs1 = $stopPs1
        stopCmd = $stopCmd
    }
}

function Test-KIModuleComfyUI {
    param([Parameter(Mandatory)][object]$Context)

    $gitCommand = Get-KIComfyGitCommand
    $pythonCommand = Get-KIComfyPythonCommand
    $issues = [System.Collections.Generic.List[string]]::new()

    if (-not $gitCommand) { [void]$issues.Add('Git ist nicht verfügbar.') }
    if (-not $pythonCommand) { [void]$issues.Add('Python ist nicht verfügbar.') }
    if (-not [bool]$Context.Config.defaults.allowNetworkDownloads) {
        [void]$issues.Add('Netzwerkdownloads sind für diese Releasekonfiguration deaktiviert.')
    }
    if ([string]$Context.Config.comfyUI.refType -ne 'tag') {
        [void]$issues.Add('ComfyUI muss für Execute auf einen Tag festgelegt sein.')
    }
    if (-not [string]$Context.Config.comfyUI.ref) {
        [void]$issues.Add('ComfyUI-Ref fehlt.')
    }
    if ([int]$Context.Config.comfyUI.port -lt 1 -or [int]$Context.Config.comfyUI.port -gt 65535) {
        [void]$issues.Add('ComfyUI-Port ist ungültig.')
    }
    if (
        [string]$Context.Config.comfyUI.torch.extraIndexUrl -notlike
        'https://download.pytorch.org/*'
    ) {
        [void]$issues.Add('PyTorch-Index ist nicht der offizielle download.pytorch.org-Index.')
    }

    return [pscustomobject][ordered]@{
        success = ($issues.Count -eq 0)
        skipped = $false
        message = if ($issues.Count -eq 0) {
            'ComfyUI-Voraussetzungen und Freigabeparameter sind gültig.'
        } else {
            'ComfyUI-Voraussetzungen oder Freigabeparameter sind ungültig.'
        }
        data = [pscustomobject][ordered]@{
            gitAvailable = ($null -ne $gitCommand)
            pythonAvailable = ($null -ne $pythonCommand)
            issues = @($issues)
        }
    }
}

function Install-KIModuleComfyUI {
    param([Parameter(Mandatory)][object]$Context)

    $root = [string]$Context.Config.comfyUI.root
    $venv = [string]$Context.Config.comfyUI.venv
    $venvPython = Join-Path $venv 'Scripts\python.exe'
    $moduleRoot = [string]$Context.Config.comfyUI.moduleRoot
    $modelConfig = [string]$Context.Config.comfyUI.extraModelPathsConfig
    $dataDirectories = @(
        [string]$Context.Config.comfyUI.inputDirectory,
        [string]$Context.Config.comfyUI.outputDirectory,
        [string]$Context.Config.comfyUI.userDirectory,
        [string]$Context.Config.comfyUI.modelsRoot,
        [string]$Context.Config.comfyUI.customNodesRoot
    )
    $modelDirectories = @(
        'checkpoints','text_encoders','clip','clip_vision','configs','controlnet',
        'diffusion_models','unet','embeddings','loras','upscale_models','vae',
        'audio_encoders','model_patches'
    ) | ForEach-Object { Join-Path ([string]$Context.Config.comfyUI.modelsRoot) $_ }

    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $false
            message = 'Dry-Run: ComfyUI v0.28.0, CUDA-PyTorch und Start-/Stop-Artefakte wurden geplant.'
            data = [pscustomobject][ordered]@{
                repository = [string]$Context.Config.comfyUI.repository
                ref = [string]$Context.Config.comfyUI.ref
                refType = [string]$Context.Config.comfyUI.refType
                root = $root
                venv = $venv
                torchExtraIndexUrl = [string]$Context.Config.comfyUI.torch.extraIndexUrl
                launchUrl = ('http://{0}:{1}' -f
                    [string]$Context.Config.comfyUI.listenAddress,
                    [int]$Context.Config.comfyUI.port
                )
                wouldCreate = @($dataDirectories + $modelDirectories + @($moduleRoot))
                rollbackStatePath = $null
            }
        }
    }

    if (-not [bool]$Context.Config.defaults.allowNetworkDownloads) {
        throw 'ComfyUI Execute benötigt freigegebene Netzwerkdownloads.'
    }

    $gitCommand = Get-KIComfyGitCommand
    $pythonCommand = Get-KIComfyPythonCommand
    if (-not $gitCommand) { throw 'Git ist trotz abgeschlossenem PythonGit-Modul nicht verfügbar.' }
    if (-not $pythonCommand) { throw 'Python ist trotz abgeschlossenem PythonGit-Modul nicht verfügbar.' }

    $rollbackState = [pscustomobject][ordered]@{
        schemaVersion = '1.0'
        transactionId = [string]$Context.Transaction.transactionId
        createdAt = (Get-Date).ToString('o')
        updatedAt = (Get-Date).ToString('o')
        rootExistedBefore = (Test-Path -LiteralPath $root -PathType Container)
        rootCreatedByTransaction = $false
        venvExistedBefore = (Test-Path -LiteralPath $venv -PathType Container)
        venvCreatedByTransaction = $false
        createdDirectories = @()
        managedFiles = @()
        rollbackCompletedAt = $null
        rollbackIssues = @()
    }
    Write-KIComfyRollbackState -Context $Context -State $rollbackState

    $expectedRepository = ConvertTo-KIComfyNormalizedRepositoryUrl `
        -Url ([string]$Context.Config.comfyUI.repository)
    $expectedRef = [string]$Context.Config.comfyUI.ref

    if (-not [bool]$rollbackState.rootExistedBefore) {
        $rollbackState.rootCreatedByTransaction = $true
        Write-KIComfyRollbackState -Context $Context -State $rollbackState

        $cloneArguments = @(
            'clone',
            '--branch', $expectedRef,
            '--depth', ([string][int]$Context.Config.comfyUI.cloneDepth),
            '--single-branch',
            [string]$Context.Config.comfyUI.repository,
            $root
        )
        Invoke-KIComfyNativeCommand -FilePath $gitCommand.Source `
            -Arguments $cloneArguments `
            -Description 'ComfyUI-Repository wird geklont.'
    }

    $repositoryState = Get-KIComfyRepositoryState -Root $root -GitCommand $gitCommand
    if (-not [bool]$repositoryState.valid) {
        throw ('ComfyUI-Repository ist unvollständig. Fehlend: {0}' -f
            (@($repositoryState.missingPaths) -join ', ')
        )
    }
    if ([string]$repositoryState.normalizedOrigin -ne $expectedRepository) {
        throw ('ComfyUI-Origin stimmt nicht: {0}' -f [string]$repositoryState.origin)
    }
    if ([string]$repositoryState.exactTag -ne $expectedRef) {
        throw ('ComfyUI ist nicht exakt auf dem freigegebenen Tag {0}. Gefunden: {1}' -f
            $expectedRef,
            [string]$repositoryState.exactTag
        )
    }
    if ([bool]$repositoryState.dirty) {
        throw 'Das ComfyUI-Repository enthält lokale Änderungen und wird nicht verändert.'
    }

    if (-not [bool]$rollbackState.venvExistedBefore) {
        $rollbackState.venvCreatedByTransaction = $true
        Write-KIComfyRollbackState -Context $Context -State $rollbackState

        Invoke-KIComfyNativeCommand -FilePath $pythonCommand.Source `
            -Arguments @('-m','venv',$venv) `
            -Description 'ComfyUI-Virtual-Environment wird erstellt.'

        if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
            throw "ComfyUI-Venv-Python wurde nicht erzeugt: $venvPython"
        }

        $packageCache = [string]$Context.Config.pythonEnvironment.packageCache
        $previousPipCache = $env:PIP_CACHE_DIR
        try {
            $env:PIP_CACHE_DIR = $packageCache

            if ([bool]$Context.Config.comfyUI.pipUpgrade) {
                Invoke-KIComfyNativeCommand -FilePath $venvPython `
                    -Arguments @('-m','pip','install','--upgrade','pip') `
                    -Description 'pip im ComfyUI-Venv wird aktualisiert.'
            }

            $torchArguments = @('-m','pip','install','--upgrade') +
                @($Context.Config.comfyUI.torch.packages) +
                @(
                    '--extra-index-url',
                    [string]$Context.Config.comfyUI.torch.extraIndexUrl
                )
            Invoke-KIComfyNativeCommand -FilePath $venvPython `
                -Arguments $torchArguments `
                -Description 'PyTorch mit NVIDIA CUDA 13.0 wird installiert.'

            Invoke-KIComfyNativeCommand -FilePath $venvPython `
                -Arguments @(
                    '-m','pip','install','-r',(Join-Path $root 'requirements.txt')
                ) `
                -Description 'ComfyUI-Abhängigkeiten werden installiert.'

            $managerRequirements = Join-Path $root 'manager_requirements.txt'
            if (
                [bool]$Context.Config.comfyUI.enableManager -and
                [bool]$Context.Config.comfyUI.installManagerRequirements -and
                (Test-Path -LiteralPath $managerRequirements -PathType Leaf)
            ) {
                Invoke-KIComfyNativeCommand -FilePath $venvPython `
                    -Arguments @('-m','pip','install','-r',$managerRequirements) `
                    -Description 'ComfyUI-Manager-Abhängigkeiten werden installiert.'
            }
        }
        finally {
            $env:PIP_CACHE_DIR = $previousPipCache
        }
    }

    $environmentState = Get-KIComfyEnvironmentState -Root $root -VenvPython $venvPython
    if (-not [bool]$environmentState.valid) {
        throw ('ComfyUI-Pythonumgebung ist ungültig: {0}' -f [string]$environmentState.error)
    }

    foreach ($directory in @($dataDirectories + $modelDirectories + @($moduleRoot))) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $rollbackState.createdDirectories = @($rollbackState.createdDirectories) + @($directory)
            Write-KIComfyRollbackState -Context $Context -State $rollbackState
        }
    }

    $managedContent = Get-KIComfyManagedContent -Config $Context.Config
    New-KIComfyManagedFile -Context $Context -RollbackState $rollbackState `
        -Path $modelConfig -Content ([string]$managedContent.extraModelPaths) -Encoding UTF8
    New-KIComfyManagedFile -Context $Context -RollbackState $rollbackState `
        -Path (Join-Path $moduleRoot 'Start-KIStack-ComfyUI.cmd') `
        -Content ([string]$managedContent.startCmd) -Encoding ASCII
    New-KIComfyManagedFile -Context $Context -RollbackState $rollbackState `
        -Path (Join-Path $moduleRoot 'Stop-KIStack-ComfyUI.ps1') `
        -Content ([string]$managedContent.stopPs1) -Encoding UTF8
    New-KIComfyManagedFile -Context $Context -RollbackState $rollbackState `
        -Path (Join-Path $moduleRoot 'Stop-KIStack-ComfyUI.cmd') `
        -Content ([string]$managedContent.stopCmd) -Encoding ASCII

    $installationStatePath = Join-Path $moduleRoot 'installation.json'
    $installationState = [pscustomobject][ordered]@{
        managedBy = 'KI-STACK-COMFYUI-MANAGED'
        schemaVersion = '1.0'
        installedAt = (Get-Date).ToString('o')
        transactionId = [string]$Context.Transaction.transactionId
        release = 'KI-Stack-ComfyUI-Execute-v1.2.1'
        repository = [string]$repositoryState.origin
        tag = [string]$repositoryState.exactTag
        commit = [string]$repositoryState.head
        pythonVersion = [string]$environmentState.pythonVersion
        torchVersion = [string]$environmentState.torchVersion
        torchCudaVersion = [string]$environmentState.torchCudaVersion
        cudaAvailable = [bool]$environmentState.cudaAvailable
        deviceName = [string]$environmentState.deviceName
        computeCapability = @($environmentState.computeCapability)
        url = ('http://{0}:{1}' -f
            [string]$Context.Config.comfyUI.listenAddress,
            [int]$Context.Config.comfyUI.port
        )
    }
    $installationJson = $installationState | ConvertTo-Json -Depth 20
    New-KIComfyManagedFile -Context $Context -RollbackState $rollbackState `
        -Path $installationStatePath `
        -Content ($installationJson + "`n") `
        -Encoding UTF8

    return [pscustomobject][ordered]@{
        success = $true
        skipped = $false
        message = 'ComfyUI v0.28.0 und die CUDA-fähige Pythonumgebung wurden eingerichtet.'
        data = [pscustomobject][ordered]@{
            rootCreatedByTransaction = [bool]$rollbackState.rootCreatedByTransaction
            venvCreatedByTransaction = [bool]$rollbackState.venvCreatedByTransaction
            createdDirectories = @($rollbackState.createdDirectories)
            managedFiles = @($rollbackState.managedFiles)
            rollbackStatePath = (Get-KIComfyRollbackStatePath -Context $Context)
            repositoryState = $repositoryState
            environmentState = $environmentState
            installationStatePath = $installationStatePath
        }
    }
}

function Validate-KIModuleComfyUI {
    param([Parameter(Mandatory)][object]$Context)

    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $false
            message = 'Dry-Run: Der ComfyUI-Zielzustand ist vollständig planbar.'
            data = $null
        }
    }

    $gitCommand = Get-KIComfyGitCommand
    if (-not $gitCommand) { throw 'Git ist für die ComfyUI-Validierung nicht verfügbar.' }

    $root = [string]$Context.Config.comfyUI.root
    $venvPython = Join-Path ([string]$Context.Config.comfyUI.venv) 'Scripts\python.exe'
    $moduleRoot = [string]$Context.Config.comfyUI.moduleRoot
    $installationStatePath = Join-Path $moduleRoot 'installation.json'
    $validationModelDirectories = @(
        'checkpoints','text_encoders','clip','clip_vision','configs','controlnet',
        'diffusion_models','unet','embeddings','loras','upscale_models','vae',
        'audio_encoders','model_patches'
    ) | ForEach-Object {
        Join-Path ([string]$Context.Config.comfyUI.modelsRoot) $_
    }
    $requiredPaths = @(
        $root,
        (Join-Path $root '.git'),
        (Join-Path $root 'main.py'),
        (Join-Path $root 'requirements.txt'),
        ([string]$Context.Config.comfyUI.customNodesRoot),
        $venvPython,
        ([string]$Context.Config.comfyUI.extraModelPathsConfig),
        (Join-Path $moduleRoot 'Start-KIStack-ComfyUI.cmd'),
        (Join-Path $moduleRoot 'Stop-KIStack-ComfyUI.cmd'),
        (Join-Path $moduleRoot 'Stop-KIStack-ComfyUI.ps1'),
        $installationStatePath,
        ([string]$Context.Config.comfyUI.modelsRoot),
        ([string]$Context.Config.comfyUI.inputDirectory),
        ([string]$Context.Config.comfyUI.outputDirectory),
        ([string]$Context.Config.comfyUI.userDirectory)
    ) + @($validationModelDirectories)
    $missingPaths = @(
        $requiredPaths | Where-Object { -not (Test-Path -LiteralPath $_) }
    )

    $repositoryState = Get-KIComfyRepositoryState -Root $root -GitCommand $gitCommand
    $expectedRepository = ConvertTo-KIComfyNormalizedRepositoryUrl `
        -Url ([string]$Context.Config.comfyUI.repository)
    $environmentState = Get-KIComfyEnvironmentState -Root $root -VenvPython $venvPython
    $issues = [System.Collections.Generic.List[string]]::new()
    $installationState = $null
    if (Test-Path -LiteralPath $installationStatePath -PathType Leaf) {
        try {
            $installationState = Get-Content -LiteralPath $installationStatePath -Raw `
                -ErrorAction Stop | ConvertFrom-Json -Depth 30 -ErrorAction Stop
        }
        catch {
            [void]$issues.Add('installation.json ist kein gültiges JSON: {0}' -f
                $_.Exception.Message
            )
        }
    }

    if ($missingPaths.Count -gt 0) {
        [void]$issues.Add('Fehlende Pfade: {0}' -f ($missingPaths -join ', '))
    }
    if (-not [bool]$repositoryState.valid) {
        [void]$issues.Add('Repositoryzustand ist ungültig.')
    }
    if ([string]$repositoryState.normalizedOrigin -ne $expectedRepository) {
        [void]$issues.Add('Repository-Origin stimmt nicht mit der Freigabe überein.')
    }
    if ([string]$repositoryState.exactTag -ne [string]$Context.Config.comfyUI.ref) {
        [void]$issues.Add('Repository ist nicht auf dem freigegebenen Tag.')
    }
    if ([bool]$repositoryState.dirty) {
        [void]$issues.Add('Repository enthält lokale Änderungen.')
    }
    if (-not [bool]$environmentState.valid) {
        [void]$issues.Add('ComfyUI-Import oder PyTorch-Prüfung ist fehlgeschlagen: {0}' -f
            [string]$environmentState.error
        )
    }
    if (
        [bool]$Context.Config.comfyUI.torch.requireCuda -and
        -not [bool]$environmentState.cudaAvailable
    ) {
        [void]$issues.Add('PyTorch erkennt keine CUDA-fähige NVIDIA-GPU.')
    }

    $computeCapability = @($environmentState.computeCapability)
    if (
        [bool]$Context.Config.comfyUI.torch.requireCuda -and
        $computeCapability.Count -gt 0 -and
        [int]$computeCapability[0] -lt
            [int]$Context.Config.comfyUI.torch.minimumComputeCapabilityMajor
    ) {
        [void]$issues.Add('GPU-Compute-Capability liegt unter der Freigabegrenze.')
    }

    $devicePattern = [string]$Context.Config.comfyUI.torch.expectedDeviceNamePattern
    if (
        $devicePattern -and
        [string]$environmentState.deviceName -notmatch [regex]::Escape($devicePattern)
    ) {
        [void]$issues.Add(
            'Erwartete GPU wurde nicht erkannt. Erwartet: {0}; erkannt: {1}' -f
            $devicePattern,
            [string]$environmentState.deviceName
        )
    }
    if ($null -ne $installationState) {
        if ([string]$installationState.managedBy -ne 'KI-STACK-COMFYUI-MANAGED') {
            [void]$issues.Add('installation.json besitzt keine gültige KI-Stack-Verwaltungskennung.')
        }
        if ([string]$installationState.tag -ne [string]$Context.Config.comfyUI.ref) {
            [void]$issues.Add('installation.json enthält nicht den freigegebenen ComfyUI-Tag.')
        }
        if (-not [bool]$installationState.cudaAvailable) {
            [void]$issues.Add('installation.json bestätigt keine CUDA-Verfügbarkeit.')
        }
    }

    return [pscustomobject][ordered]@{
        success = ($issues.Count -eq 0)
        skipped = $false
        message = if ($issues.Count -eq 0) {
            'ComfyUI, v0.28.0, PyTorch CUDA und RTX 5090 wurden vollständig validiert.'
        } else {
            'Der ComfyUI-Zielzustand ist unvollständig.'
        }
        data = [pscustomobject][ordered]@{
            issues = @($issues)
            missingPaths = $missingPaths
            repositoryState = $repositoryState
            environmentState = $environmentState
            url = ('http://{0}:{1}' -f
                [string]$Context.Config.comfyUI.listenAddress,
                [int]$Context.Config.comfyUI.port
            )
        }
    }
}

function Rollback-KIModuleComfyUI {
    param([Parameter(Mandatory)][object]$Context)

    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $true
            message = 'Dry-Run: Kein ComfyUI-Rollback erforderlich.'
            data = $null
        }
    }

    $rollbackState = Read-KIComfyRollbackState -Context $Context
    if ($null -eq $rollbackState) {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $true
            message = 'Keine transaktionsgebundenen ComfyUI-Rollbackdaten vorhanden.'
            data = $null
        }
    }

    $issues = [System.Collections.Generic.List[string]]::new()
    $restoredFiles = [System.Collections.Generic.List[string]]::new()
    $removedPaths = [System.Collections.Generic.List[string]]::new()

    foreach ($fileState in (@($rollbackState.managedFiles) | Sort-Object path -Descending)) {
        try {
            $path = [string]$fileState.path
            if ([bool]$fileState.existedBefore) {
                $bytes = [Convert]::FromBase64String(
                    [string]$fileState.previousContentBase64
                )
                [IO.File]::WriteAllBytes($path, $bytes)
                [void]$restoredFiles.Add($path)
            }
            elseif (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force
                [void]$removedPaths.Add($path)
            }
        }
        catch {
            [void]$issues.Add('Datei-Rollback fehlgeschlagen: {0}: {1}' -f
                [string]$fileState.path,
                $_.Exception.Message
            )
        }
    }

    if ([bool]$rollbackState.venvCreatedByTransaction) {
        try {
            $venv = [string]$Context.Config.comfyUI.venv
            if (Test-Path -LiteralPath $venv) {
                Remove-Item -LiteralPath $venv -Recurse -Force
                [void]$removedPaths.Add($venv)
            }
        }
        catch {
            [void]$issues.Add('ComfyUI-Venv konnte nicht entfernt werden: {0}' -f
                $_.Exception.Message
            )
        }
    }

    if ([bool]$rollbackState.rootCreatedByTransaction) {
        try {
            $root = [string]$Context.Config.comfyUI.root
            if (Test-Path -LiteralPath $root) {
                Remove-Item -LiteralPath $root -Recurse -Force
                [void]$removedPaths.Add($root)
            }
        }
        catch {
            [void]$issues.Add('ComfyUI-Repository konnte nicht entfernt werden: {0}' -f
                $_.Exception.Message
            )
        }
    }

    foreach ($directory in (@($rollbackState.createdDirectories) | Sort-Object Length -Descending)) {
        try {
            if (Test-Path -LiteralPath $directory -PathType Container) {
                $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)
                if ($children.Count -eq 0) {
                    Remove-Item -LiteralPath $directory -Force
                    [void]$removedPaths.Add([string]$directory)
                }
            }
        }
        catch {
            [void]$issues.Add('Leeres Verzeichnis konnte nicht entfernt werden: {0}: {1}' -f
                [string]$directory,
                $_.Exception.Message
            )
        }
    }

    $rollbackState.rollbackCompletedAt = (Get-Date).ToString('o')
    $rollbackState.rollbackIssues = @($issues)
    Write-KIComfyRollbackState -Context $Context -State $rollbackState

    return [pscustomobject][ordered]@{
        success = ($issues.Count -eq 0)
        skipped = $false
        message = if ($issues.Count -eq 0) {
            'Alle durch die Transaktion erzeugten ComfyUI-Artefakte wurden zurückgesetzt.'
        } else {
            'Der ComfyUI-Rollback wurde mit Problemen abgeschlossen.'
        }
        data = [pscustomobject][ordered]@{
            restoredFiles = @($restoredFiles)
            removedPaths = @($removedPaths)
            issues = @($issues)
            rollbackStatePath = (Get-KIComfyRollbackStatePath -Context $Context)
        }
    }
}

Export-ModuleMember -Function *

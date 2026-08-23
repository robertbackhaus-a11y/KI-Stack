Set-StrictMode -Version Latest

function Get-KIApplicationsRollbackStatePath {
    param([Parameter(Mandatory)][object]$Context)
    $directory = Join-Path ([string]$Context.TransactionDirectory) 'module-state'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    return Join-Path $directory 'KIModuleApplications.rollback.json'
}

function Write-KIApplicationsRollbackState {
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][object]$State
    )
    $path = Get-KIApplicationsRollbackStatePath -Context $Context
    $temporaryPath = $path + '.tmp'
    $State.updatedAt = (Get-Date).ToString('o')
    $State | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $path -Force
}

function Read-KIApplicationsRollbackState {
    param([Parameter(Mandatory)][object]$Context)
    $path = Get-KIApplicationsRollbackStatePath -Context $Context
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $path -Raw -ErrorAction Stop |
        ConvertFrom-Json -Depth 100 -ErrorAction Stop
}

function Invoke-KIApplicationCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int]$TimeoutSeconds = 120,
        [AllowNull()][object]$Context = $null,
        [string]$Operation = 'ExternalCommand'
    )
    if ($TimeoutSeconds -le 0) { throw 'TimeoutSeconds muss größer als 0 sein.' }
    Write-KIApplicationsProgress -Context $Context -Step 'WaitStarted' -Data ([ordered]@{
        target=$Operation;timeoutSeconds=$TimeoutSeconds
    })
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $ArgumentList) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Prozess konnte nicht gestartet werden: $FilePath" }
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch {}
            try { $process.WaitForExit() } catch {}
            $message = ('Timeout bei {0} nach {1} Sekunden.' -f $Operation,$TimeoutSeconds)
            Write-KIApplicationsProgress -Context $Context -Step 'WaitTimedOut' -Level 'Error' -Data ([ordered]@{
                target=$Operation;timeoutSeconds=$TimeoutSeconds;message=$message
            })
            throw $message
        }
        $output = [Collections.Generic.List[string]]::new()
        foreach ($line in @((($standardOutput.GetAwaiter().GetResult()) -split "`r?`n"))) {
            if (-not [string]::IsNullOrEmpty($line)) { [void]$output.Add($line) }
        }
        foreach ($line in @((($standardError.GetAwaiter().GetResult()) -split "`r?`n"))) {
            if (-not [string]::IsNullOrEmpty($line)) { [void]$output.Add($line) }
        }
        Write-KIApplicationsProgress -Context $Context -Step 'WaitCompleted' -Data ([ordered]@{
            target=$Operation;timeoutSeconds=$TimeoutSeconds;exitCode=$process.ExitCode
        })
        return [pscustomobject][ordered]@{
            exitCode = $process.ExitCode
            output = @($output)
        }
    }
    catch {
        if ($_.Exception.Message -notlike 'Timeout bei *') {
            Write-KIApplicationsProgress -Context $Context -Step 'WaitFailed' -Level 'Error' -Data ([ordered]@{
                target=$Operation;timeoutSeconds=$TimeoutSeconds;message=$_.Exception.Message
            })
        }
        throw
    }
    finally {
        $process.Dispose()
    }
}

function Write-KIApplicationsProgress {
    param(
        [AllowNull()][object]$Context,
        [Parameter(Mandatory)][string]$Step,
        [ValidateSet('Info','Warning','Error')][string]$Level = 'Info',
        [AllowNull()][object]$Data = $null
    )
    $logPath = [string](Get-KIOptionalPropertyValue -Object $Context -Name 'LogPath')
    if ([string]::IsNullOrWhiteSpace($logPath)) { return }
    $entry = [pscustomobject][ordered]@{
        timestamp=(Get-Date).ToString('o');level=$Level;component='KIModuleApplications'
        message=$Step;data=$Data
    }
    Add-Content -LiteralPath $logPath -Value ($entry|ConvertTo-Json -Depth 20 -Compress) -Encoding UTF8
}

function Get-KIOptionalPropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Object -or $null -eq $Object.PSObject) { return $null }
    if ($Object.PSObject.Properties.Name -notcontains $Name) { return $null }
    return $Object.PSObject.Properties[$Name].Value
}

function Get-KIApplicationsDiagnosticPath {
    param([Parameter(Mandatory)][object]$Context)
    $directory = Join-Path ([string]$Context.TransactionDirectory) 'module-state'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    return Join-Path $directory 'KIModuleApplications.diagnostic.json'
}

function Write-KIApplicationsDiagnostic {
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][string]$Step,
        [AllowNull()][object]$Data = $null
    )
    $entry = [pscustomobject][ordered]@{
        schemaVersion = '1.0'
        updatedAt = (Get-Date).ToString('o')
        transactionId = [string]$Context.Transaction.transactionId
        step = $Step
        data = $Data
    }
    $path = Get-KIApplicationsDiagnosticPath -Context $Context
    $temporaryPath = $path + '.tmp'
    $entry | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $path -Force
}

function Resolve-KIApplicationPython {
    param([AllowNull()][object]$Context = $null)
    $candidatePaths = [System.Collections.Generic.List[string]]::new()
    foreach ($command in @(Get-Command python.exe -All -ErrorAction SilentlyContinue)) {
        $source = [string](Get-KIOptionalPropertyValue -Object $command -Name 'Source')
        if (-not [string]::IsNullOrWhiteSpace($source)) { [void]$candidatePaths.Add($source) }
    }
    foreach ($template in @(
        '%LOCALAPPDATA%\Programs\Python\Python312\python.exe',
        '%LOCALAPPDATA%\Programs\Python\Python311\python.exe',
        '%ProgramFiles%\Python312\python.exe',
        '%ProgramFiles%\Python311\python.exe'
    )) {
        $expanded = [Environment]::ExpandEnvironmentVariables($template)
        if (-not [string]::IsNullOrWhiteSpace($expanded)) { [void]$candidatePaths.Add($expanded) }
    }

    $tested = [System.Collections.Generic.List[object]]::new()
    foreach ($candidatePath in @($candidatePaths | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) { continue }
        $normalizedCandidatePath = $candidatePath.Replace('/','\')
        if ($normalizedCandidatePath -match '(?i)\\Microsoft\\WindowsApps\\') { continue }
        $versionResult = Invoke-KIApplicationCommand -FilePath $candidatePath -ArgumentList @(
            '-c', 'import sys; print(".".join(map(str,sys.version_info[:3]))); raise SystemExit(0 if (3,11) <= sys.version_info[:2] < (3,13) else 1)'
        ) -TimeoutSeconds 30 -Context $Context -Operation 'PythonVersionProbe'
        $versionText = (($versionResult.output -join '').Trim())
        [void]$tested.Add([pscustomobject][ordered]@{
            path = $candidatePath
            version = $versionText
            compatible = ($versionResult.exitCode -eq 0)
            exitCode = $versionResult.exitCode
        })
        if ($versionResult.exitCode -eq 0) {
            return [pscustomobject][ordered]@{
                path = [string](Resolve-Path -LiteralPath $candidatePath).Path
                version = $versionText
                compatible = $true
                tested = @($tested)
            }
        }
    }
    return [pscustomobject][ordered]@{
        path = $null
        version = $null
        compatible = $false
        tested = @($tested)
    }
}

function Get-KILMStudioState {
    param([Parameter(Mandatory)][object]$Context)
    $packageId = [string]$Context.Config.applications.lmStudio.packageId
    $wingetCommand = Get-Command winget.exe -ErrorAction SilentlyContinue
    $wingetInstalled = $false
    $wingetOutput = @()
    if ($wingetCommand) {
        $listResult = Invoke-KIApplicationCommand -FilePath $wingetCommand.Source -ArgumentList @(
            'list','--id',$packageId,'--exact','--source','winget','--disable-interactivity'
        ) -TimeoutSeconds 120 -Context $Context -Operation 'LMStudioWingetInventory'
        $wingetOutput = @($listResult.output)
        $combinedOutput = $wingetOutput -join [Environment]::NewLine
        $wingetInstalled = ($listResult.exitCode -eq 0 -and $combinedOutput.Contains($packageId))
    }

    $candidatePaths = [System.Collections.Generic.List[string]]::new()
    foreach ($candidateTemplate in @(
        '%LOCALAPPDATA%\Programs\LM Studio\LM Studio.exe',
        '%LOCALAPPDATA%\LM Studio\LM Studio.exe',
        '%ProgramFiles%\LM Studio\LM Studio.exe',
        '%ProgramFiles(x86)%\LM Studio\LM Studio.exe'
    )) {
        $candidatePath = [Environment]::ExpandEnvironmentVariables($candidateTemplate)
        if (-not [string]::IsNullOrWhiteSpace($candidatePath)) {
            [void]$candidatePaths.Add($candidatePath)
        }
    }

    foreach ($registryPath in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        foreach ($entry in @(Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue)) {
            $displayName = [string](Get-KIOptionalPropertyValue -Object $entry -Name 'DisplayName')
            if ([string]::IsNullOrWhiteSpace($displayName) -or $displayName -notlike 'LM Studio*') { continue }
            $displayIcon = [string](Get-KIOptionalPropertyValue -Object $entry -Name 'DisplayIcon')
            $installLocation = [string](Get-KIOptionalPropertyValue -Object $entry -Name 'InstallLocation')
            foreach ($rawValue in @($displayIcon,$installLocation)) {
                if ([string]::IsNullOrWhiteSpace($rawValue)) { continue }
                $cleanValue = $rawValue.Trim().Trim('"')
                $iconMatch = [regex]::Match($cleanValue, '^(.*?\.exe)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($iconMatch.Success) {
                    [void]$candidatePaths.Add($iconMatch.Groups[1].Value)
                }
                elseif (Test-Path -LiteralPath $cleanValue -PathType Container) {
                    [void]$candidatePaths.Add((Join-Path $cleanValue 'LM Studio.exe'))
                }
            }
        }
    }

    $executablePath = $null
    foreach ($candidatePath in @($candidatePaths | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            $executablePath = [string](Resolve-Path -LiteralPath $candidatePath).Path
            break
        }
    }

    $lmsPath = $null
    foreach ($commandName in @('lms.exe','lms.cmd','lms')) {
        $lmsCommand = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($lmsCommand -and -not [string]::IsNullOrWhiteSpace([string]$lmsCommand.Source)) {
            $lmsPath = [string]$lmsCommand.Source
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($lmsPath)) {
        foreach ($candidateTemplate in @(
            '%USERPROFILE%\.lmstudio\bin\lms.exe',
            '%USERPROFILE%\.lmstudio\bin\lms.cmd'
        )) {
            $candidatePath = [Environment]::ExpandEnvironmentVariables($candidateTemplate)
            if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
                $lmsPath = $candidatePath
                break
            }
        }
    }

    return [pscustomobject][ordered]@{
        installed = ($wingetInstalled -or -not [string]::IsNullOrWhiteSpace($executablePath))
        wingetInstalled = $wingetInstalled
        wingetAvailable = ($null -ne $wingetCommand)
        executablePath = $executablePath
        lmsPath = $lmsPath
        wingetOutput = $wingetOutput
    }
}

function Get-KIOpenWebUIVersion {
    param([Parameter(Mandatory)][object]$Context)
    $venvPython = Join-Path ([string]$Context.Config.applications.openWebUI.venv) 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) { return $null }
    $versionResult = Invoke-KIApplicationCommand -FilePath $venvPython -ArgumentList @(
        '-c', "import importlib.metadata as metadata; print(metadata.version('open-webui'))"
    ) -TimeoutSeconds 30 -Context $Context -Operation 'OpenWebUIVersionProbe'
    if ($versionResult.exitCode -ne 0) { return $null }
    return (($versionResult.output -join '').Trim())
}

function Write-KIUtf8NoBomCrLf {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    $normalizedContent = $Content.Replace("`r`n","`n").Replace("`r","`n").Replace("`n","`r`n")
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($Path,$normalizedContent,$encoding)
}

function Install-KIApplicationFile {
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][object]$RollbackState,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $RollbackState.createdDirectories = @($RollbackState.createdDirectories) + @($parent)
    }
    $existedBefore = Test-Path -LiteralPath $Path -PathType Leaf
    $previousContentBase64 = if ($existedBefore) {
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
    } else { $null }
    $RollbackState.files = @($RollbackState.files) + @(
        [pscustomobject][ordered]@{
            path = $Path
            existedBefore = $existedBefore
            previousContentBase64 = $previousContentBase64
        }
    )
    Write-KIApplicationsRollbackState -Context $Context -State $RollbackState
    Write-KIUtf8NoBomCrLf -Path $Path -Content $Content
}

function Test-KIApplicationEndpoint {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Context = $null,
        [int]$TimeoutSeconds = 3
    )
    Write-KIApplicationsProgress -Context $Context -Step 'ReadinessWaitStarted' -Data ([ordered]@{
        target=$Name;uri=$Uri;timeoutSeconds=$TimeoutSeconds;required=$false
    })
    try {
        $response = Invoke-WebRequest -Uri $Uri -Method Get -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
        $reachable = ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 500)
        Write-KIApplicationsProgress -Context $Context -Step 'ReadinessWaitCompleted' -Data ([ordered]@{
            target=$Name;timeoutSeconds=$TimeoutSeconds;reachable=$reachable;required=$false
        })
        return $reachable
    }
    catch {
        Write-KIApplicationsProgress -Context $Context -Step 'ReadinessNotRequired' -Level 'Warning' -Data ([ordered]@{
            target=$Name;timeoutSeconds=$TimeoutSeconds;reachable=$false;classification='InstalledNotStarted';message=$_.Exception.Message
        })
        return $false
    }
}

function Test-KIModuleApplications {
    param([Parameter(Mandatory)][object]$Context)
    try {
        Write-KIApplicationsDiagnostic -Context $Context -Step 'PrerequisiteTestStarted'
        $pythonState = Resolve-KIApplicationPython -Context $Context
        $wingetCommand = Get-Command winget.exe -ErrorAction SilentlyContinue
        $lmState = Get-KILMStudioState -Context $Context
        $success = ([bool]$pythonState.compatible -and ($lmState.installed -or $null -ne $wingetCommand))
        $data = [pscustomobject][ordered]@{
            pythonAvailable = (-not [string]::IsNullOrWhiteSpace([string]$pythonState.path))
            pythonCompatible = [bool]$pythonState.compatible
            pythonVersion = $pythonState.version
            pythonPath = $pythonState.path
            pythonCandidates = @($pythonState.tested)
            wingetAvailable = ($null -ne $wingetCommand)
            lmStudioInstalled = [bool]$lmState.installed
            lmStudioExecutable = $lmState.executablePath
            lmsPath = $lmState.lmsPath
        }
        Write-KIApplicationsDiagnostic -Context $Context -Step 'PrerequisiteTestCompleted' -Data $data
        return [pscustomobject][ordered]@{
            success = $success
            skipped = $false
            message = if ($success) {
                'LM Studio/Open WebUI-Voraussetzungen geprüft.'
            } else {
                'Voraussetzungen fehlen: kompatibles Python 3.11/3.12 und LM Studio oder winget werden benötigt.'
            }
            data = $data
        }
    }
    catch {
        try { Write-KIApplicationsDiagnostic -Context $Context -Step 'PrerequisiteTestFailed' -Data $_.Exception.Message } catch {}
        return [pscustomobject][ordered]@{success=$false;skipped=$false;message=$_.Exception.Message;data=$null}
    }
}
function Get-KILMStudioStarterScriptContent {
    # Extracted from Install-KIModuleApplications so the generated batch
    # contract is directly testable without running a full winget-based
    # install. Behavior/content is unchanged from what was inline before.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$LmsCli,
        [Parameter(Mandatory)][AllowEmptyString()][string]$LmExecutable,
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)][string]$BindAddress,
        [int]$LmsWaitMaxAttempts=30,
        [int]$LmsWaitIntervalSeconds=3,
        [int]$EndpointWaitMaxAttempts=15,
        [int]$EndpointWaitIntervalSeconds=2
    )
    $lmStudioTemplate = @'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
title KI-Stack LM Studio
set "LMS_CLI=__LMS_CLI__"
set "LMSTUDIO_EXE=__LMSTUDIO_EXE__"
if not defined LMS_CLI for /f "delims=" %%I in ('where lms.exe 2^>nul') do if not defined LMS_CLI set "LMS_CLI=%%~fI"
if not defined LMS_CLI for /f "delims=" %%I in ('where lms.cmd 2^>nul') do if not defined LMS_CLI set "LMS_CLI=%%~fI"
if not defined LMS_CLI if exist "%USERPROFILE%\.lmstudio\bin\lms.exe" set "LMS_CLI=%USERPROFILE%\.lmstudio\bin\lms.exe"
if not defined LMS_CLI if exist "%USERPROFILE%\.lmstudio\bin\lms.cmd" set "LMS_CLI=%USERPROFILE%\.lmstudio\bin\lms.cmd"
if defined LMS_CLI if exist "%LMS_CLI%" goto :StartServer
if not defined LMSTUDIO_EXE goto :NoLmStudio
if not exist "%LMSTUDIO_EXE%" goto :NoLmStudio
start "" "%LMSTUDIO_EXE%"
echo LM Studio wurde gestartet (erster Start). Warte auf lms-CLI ...
set "LMS_WAIT_ATTEMPTS=0"
:WaitForLms
if exist "%USERPROFILE%\.lmstudio\bin\lms.exe" set "LMS_CLI=%USERPROFILE%\.lmstudio\bin\lms.exe"
if not defined LMS_CLI if exist "%USERPROFILE%\.lmstudio\bin\lms.cmd" set "LMS_CLI=%USERPROFILE%\.lmstudio\bin\lms.cmd"
if defined LMS_CLI if exist "%LMS_CLI%" goto :StartServer
set /a LMS_WAIT_ATTEMPTS+=1
if %LMS_WAIT_ATTEMPTS% GEQ __LMS_WAIT_MAX_ATTEMPTS__ goto :LmsTimeout
powershell -NoProfile -NonInteractive -Command "Start-Sleep -Seconds __LMS_WAIT_INTERVAL_SECONDS__"
goto :WaitForLms
:StartServer
call "%LMS_CLI%" server start --port __PORT__ --bind __BIND_ADDRESS__
set "LMS_ENDPOINT_ATTEMPTS=0"
:WaitForEndpoint
"%SystemRoot%\System32\curl.exe" --max-time 3 --silent --show-error --fail "http://__BIND_ADDRESS__:__PORT__/v1/models" >nul 2>&1
if not errorlevel 1 (
    echo LM-Studio-Server ist erreichbar auf __BIND_ADDRESS__:__PORT__.
    exit /b 0
)
set /a LMS_ENDPOINT_ATTEMPTS+=1
if %LMS_ENDPOINT_ATTEMPTS% GEQ __ENDPOINT_WAIT_MAX_ATTEMPTS__ goto :EndpointTimeout
powershell -NoProfile -NonInteractive -Command "Start-Sleep -Seconds __ENDPOINT_WAIT_INTERVAL_SECONDS__"
goto :WaitForEndpoint
:EndpointTimeout
echo LM-Studio-Server wurde gestartet, ist aber innerhalb des Wartefensters nicht erreichbar geworden.
exit /b 1
:LmsTimeout
echo LM Studio wurde gestartet, aber lms wurde innerhalb des Wartefensters nicht verfuegbar.
exit /b 1
:NoLmStudio
echo LM Studio ist installiert, aber weder lms noch die Programmdatei wurden aufgelöst.
echo LM Studio einmal manuell starten und danach dieses Skript erneut ausführen.
pause
exit /b 1
'@
    $lmStudioContent = $lmStudioTemplate
    $lmStudioContent = $lmStudioContent.Replace('__LMS_CLI__',$LmsCli)
    $lmStudioContent = $lmStudioContent.Replace('__LMSTUDIO_EXE__',$LmExecutable)
    $lmStudioContent = $lmStudioContent.Replace('__PORT__',$Port)
    $lmStudioContent = $lmStudioContent.Replace('__BIND_ADDRESS__',$BindAddress)
    # Bounded, non-infinite waits for the Greenfield first-run path: default
    # up to 90s for the lms CLI to appear after LM Studio's very first GUI
    # start (it is only written to %USERPROFILE%\.lmstudio\bin after that
    # first start completes its own setup), then up to 30s for the server it
    # starts to actually accept connections.
    $lmStudioContent = $lmStudioContent.Replace('__LMS_WAIT_MAX_ATTEMPTS__',[string]$LmsWaitMaxAttempts)
    $lmStudioContent = $lmStudioContent.Replace('__LMS_WAIT_INTERVAL_SECONDS__',[string]$LmsWaitIntervalSeconds)
    $lmStudioContent = $lmStudioContent.Replace('__ENDPOINT_WAIT_MAX_ATTEMPTS__',[string]$EndpointWaitMaxAttempts)
    $lmStudioContent = $lmStudioContent.Replace('__ENDPOINT_WAIT_INTERVAL_SECONDS__',[string]$EndpointWaitIntervalSeconds)
    $lmStudioContent
}
function Install-KIModuleApplications {
    param([Parameter(Mandatory)][object]$Context)
    $applicationConfig = $Context.Config.applications
    $lmConfig = $applicationConfig.lmStudio
    $webConfig = $applicationConfig.openWebUI
    $moduleRoot = [string]$applicationConfig.moduleRoot
    $venvRoot = [string]$webConfig.venv
    $dataRoot = [string]$webConfig.dataRoot
    $venvPython = Join-Path $venvRoot 'Scripts\python.exe'
    $targetVersion = [string]$webConfig.version
    $pythonState = Resolve-KIApplicationPython -Context $Context
    if (-not [bool]$pythonState.compatible -or [string]::IsNullOrWhiteSpace([string]$pythonState.path)) {
        throw ('Kein kompatibles Python 3.11/3.12 gefunden. Geprüfte Kandidaten: {0}' -f ((@($pythonState.tested) | ConvertTo-Json -Depth 20 -Compress)))
    }
    $pythonPath = [string]$pythonState.path
    Write-KIApplicationsDiagnostic -Context $Context -Step 'InstallStarted' -Data ([pscustomobject][ordered]@{
        pythonPath = $pythonPath
        pythonVersion = $pythonState.version
        targetOpenWebUIVersion = $targetVersion
    })

    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $false
            message = 'Dry-Run: LM Studio und Open WebUI wurden vollständig geplant.'
            data = [pscustomobject][ordered]@{
                lmStudioPackageId = [string]$lmConfig.packageId
                lmStudioServerUrl = [string]$lmConfig.serverUrl
                openWebUIPackage = ('{0}=={1}' -f [string]$webConfig.packageName,$targetVersion)
                openWebUIVenv = $venvRoot
                openWebUIDataRoot = $dataRoot
                moduleRoot = $moduleRoot
                createdByTransaction = @()
            }
        }
    }

    $rollbackState = [pscustomobject][ordered]@{
        schemaVersion = '1.0'
        transactionId = [string]$Context.Transaction.transactionId
        createdAt = (Get-Date).ToString('o')
        updatedAt = (Get-Date).ToString('o')
        lmStudioInstalledByTransaction = $false
        openWebUIVenvCreatedByTransaction = $false
        openWebUIPreviousVersion = $null
        openWebUIVersionChanged = $false
        createdDirectories = @()
        files = @()
        rollbackCompletedAt = $null
        rollbackIssues = @()
    }
    Write-KIApplicationsRollbackState -Context $Context -State $rollbackState

    foreach ($directory in @($moduleRoot,$dataRoot,(Split-Path -Parent $venvRoot))) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $rollbackState.createdDirectories = @($rollbackState.createdDirectories) + @($directory)
            Write-KIApplicationsRollbackState -Context $Context -State $rollbackState
        }
    }

    Write-KIApplicationsProgress -Context $Context -Step 'LMStudioPhaseStarted'
    $lmStateBefore = Get-KILMStudioState -Context $Context
    if ([bool]$lmConfig.enabled -and -not [bool]$lmStateBefore.installed) {
        if (-not [bool]$lmConfig.allowWingetInstall -or -not [bool]$lmStateBefore.wingetAvailable) {
            throw 'LM Studio fehlt und darf nicht über winget installiert werden.'
        }
        $wingetCommand = Get-Command winget.exe -ErrorAction Stop
        $installResult = Invoke-KIApplicationCommand -FilePath $wingetCommand.Source -ArgumentList @(
            'install','--id',[string]$lmConfig.packageId,'--exact','--source','winget','--silent',
            '--accept-package-agreements','--accept-source-agreements','--disable-interactivity'
        ) -TimeoutSeconds 1800 -Context $Context -Operation 'LMStudioWingetInstall'
        foreach ($outputLine in @($installResult.output)) { Write-Host $outputLine }
        $lmStateAfterInstall = Get-KILMStudioState -Context $Context
        if (-not [bool]$lmStateAfterInstall.installed) {
            throw ('LM Studio ist nach winget nicht nachweisbar. Exitcode: {0}; Ausgabe: {1}' -f $installResult.exitCode,(@($installResult.output | Select-Object -Last 25) -join ' | '))
        }
        $rollbackState.lmStudioInstalledByTransaction = $true
        Write-KIApplicationsRollbackState -Context $Context -State $rollbackState
    }
    Write-KIApplicationsProgress -Context $Context -Step 'LMStudioPhaseCompleted' -Data ([ordered]@{
        installed=$true;installedByTransaction=[bool]$rollbackState.lmStudioInstalledByTransaction
    })

    Write-KIApplicationsProgress -Context $Context -Step 'OpenWebUIPhaseStarted' -Data ([ordered]@{targetVersion=$targetVersion})
    $venvExistedBefore = Test-Path -LiteralPath $venvPython -PathType Leaf
    $previousVersion = Get-KIOpenWebUIVersion -Context $Context
    $rollbackState.openWebUIPreviousVersion = $previousVersion
    if (-not $venvExistedBefore) {
        Write-KIApplicationsDiagnostic -Context $Context -Step 'CreateOpenWebUIVenv' -Data $venvRoot
        $venvResult = Invoke-KIApplicationCommand -FilePath $pythonPath -ArgumentList @('-m','venv',$venvRoot) -TimeoutSeconds 300 -Context $Context -Operation 'OpenWebUIVenvCreate'
        if ($venvResult.exitCode -ne 0 -or -not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
            throw ('Open-WebUI-Venv konnte nicht erstellt werden. Python: {0}; Exitcode: {1}; Ausgabe: {2}' -f $pythonPath,$venvResult.exitCode,(@($venvResult.output | Select-Object -Last 25) -join ' | '))
        }
        $rollbackState.openWebUIVenvCreatedByTransaction = $true
        Write-KIApplicationsRollbackState -Context $Context -State $rollbackState
    }

    if ([bool]$webConfig.pipUpgrade) {
        $pipUpgradeResult = Invoke-KIApplicationCommand -FilePath $venvPython -ArgumentList @(
            '-m','pip','install','--upgrade','--disable-pip-version-check','--no-input','pip'
        ) -TimeoutSeconds 1800 -Context $Context -Operation 'OpenWebUIPipUpgrade'
        foreach ($outputLine in @($pipUpgradeResult.output)) { Write-Host $outputLine }
        if ($pipUpgradeResult.exitCode -ne 0) { throw ('pip-Upgrade im Open-WebUI-Venv ist fehlgeschlagen. Exitcode: {0}; Ausgabe: {1}' -f $pipUpgradeResult.exitCode,(@($pipUpgradeResult.output | Select-Object -Last 25) -join ' | ')) }
    }

    $currentVersion = Get-KIOpenWebUIVersion -Context $Context
    if ($currentVersion -ne $targetVersion) {
        $packageSpec = ('{0}=={1}' -f [string]$webConfig.packageName,$targetVersion)
        $installWebResult = Invoke-KIApplicationCommand -FilePath $venvPython -ArgumentList @(
            '-m','pip','install','--upgrade','--prefer-binary','--disable-pip-version-check','--no-input',$packageSpec
        ) -TimeoutSeconds 1800 -Context $Context -Operation 'OpenWebUIPackageInstall'
        foreach ($outputLine in @($installWebResult.output)) { Write-Host $outputLine }
        $installedVersion = Get-KIOpenWebUIVersion -Context $Context
        if ($installWebResult.exitCode -ne 0 -or $installedVersion -ne $targetVersion) {
            throw ('Open WebUI {0} konnte nicht validiert werden. Exitcode: {1}; erkannte Version: {2}; Ausgabe: {3}' -f $targetVersion,$installWebResult.exitCode,$installedVersion,(@($installWebResult.output | Select-Object -Last 25) -join ' | '))
        }
        $rollbackState.openWebUIVersionChanged = $true
        Write-KIApplicationsRollbackState -Context $Context -State $rollbackState
    }

    $lmState = Get-KILMStudioState -Context $Context
    $lmExecutable = if ($lmState.executablePath) { [string]$lmState.executablePath } else { '' }
    $lmsCli = if ($lmState.lmsPath) { [string]$lmState.lmsPath } else { '' }

    $openWebUITemplate = @'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
title KI-Stack Open WebUI
set "DATA_DIR=__DATA_ROOT__"
set "ENABLE_OLLAMA_API=False"
set "ENABLE_OPENAI_API=True"
set "OPENAI_API_BASE_URL=__OPENAI_BASE_URL__"
set "OPENAI_API_KEY=__OPENAI_KEY__"
set "SCARF_NO_ANALYTICS=true"
set "DO_NOT_TRACK=true"
set "ANONYMIZED_TELEMETRY=false"
set "PYTHONNOUSERSITE=1"
"__VENV_PYTHON__" -c "from open_webui import app; app()" serve --host __BIND_ADDRESS__ --port __PORT__
set "EC=%ERRORLEVEL%"
echo.
echo Open WebUI wurde beendet. Exitcode: %EC%
pause
exit /b %EC%
'@
    $openWebUIContent = $openWebUITemplate
    $openWebUIContent = $openWebUIContent.Replace('__DATA_ROOT__',$dataRoot)
    $openWebUIContent = $openWebUIContent.Replace('__OPENAI_BASE_URL__',[string]$webConfig.openAIBaseUrl)
    $openWebUIContent = $openWebUIContent.Replace('__OPENAI_KEY__',[string]$webConfig.openAIKey)
    $openWebUIContent = $openWebUIContent.Replace('__VENV_PYTHON__',$venvPython)
    $openWebUIContent = $openWebUIContent.Replace('__BIND_ADDRESS__',[string]$webConfig.bindAddress)
    $openWebUIContent = $openWebUIContent.Replace('__PORT__',[string]$webConfig.port)

    $lmStudioContent = Get-KILMStudioStarterScriptContent -LmsCli $lmsCli -LmExecutable $lmExecutable -Port ([string]$lmConfig.port) -BindAddress ([string]$lmConfig.bindAddress)

    $allTemplate = @'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
start "KI-Stack LM Studio" cmd.exe /D /C call "__LM_SCRIPT__"
timeout /t 3 /nobreak >nul
start "KI-Stack Open WebUI" cmd.exe /D /K call "__WEB_SCRIPT__"
exit /b 0
'@
    $lmScriptPath = Join-Path $moduleRoot 'Start-KIStack-LMStudio.cmd'
    $webScriptPath = Join-Path $moduleRoot 'Start-KIStack-OpenWebUI.cmd'
    $allScriptPath = Join-Path $moduleRoot 'Start-KIStack-Applications.cmd'
    $stopPsPath = Join-Path $moduleRoot 'Stop-KIStack-Applications.ps1'
    $stopCmdPath = Join-Path $moduleRoot 'Stop-KIStack-Applications.cmd'
    $allContent = $allTemplate.Replace('__LM_SCRIPT__',$lmScriptPath).Replace('__WEB_SCRIPT__',$webScriptPath)

    $stopPsTemplate = @'
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$lmsCli = '__LMS_CLI__'
if (-not [string]::IsNullOrWhiteSpace($lmsCli) -and (Test-Path -LiteralPath $lmsCli -PathType Leaf)) {
    & $lmsCli server stop 2>$null | Out-Null
}
$venvToken = '__VENV_TOKEN__'.ToLowerInvariant()
$matchingProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $commandLine = [string]$_.CommandLine
    -not [string]::IsNullOrWhiteSpace($commandLine) -and
    $commandLine.ToLowerInvariant().Contains($venvToken) -and
    $commandLine.ToLowerInvariant().Contains('open_webui')
})
foreach ($processEntry in $matchingProcesses) {
    Stop-Process -Id ([int]$processEntry.ProcessId) -Force -ErrorAction SilentlyContinue
}
Write-Host ('Open-WebUI-Prozesse beendet: {0}' -f $matchingProcesses.Count)
'@
    $stopPsContent = $stopPsTemplate.Replace('__LMS_CLI__',$lmsCli.Replace("'","''")).Replace('__VENV_TOKEN__',$venvRoot.Replace("'","''"))
    $stopCmdContent = @'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "PWSH="
if defined ProgramW6432 if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined PWSH if defined ProgramFiles if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH set "PWSH=%%~fI"
if not defined PWSH exit /b 1
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Stop-KIStack-Applications.ps1"
exit /b %ERRORLEVEL%
'@

    Install-KIApplicationFile -Context $Context -RollbackState $rollbackState -Path $lmScriptPath -Content $lmStudioContent
    Install-KIApplicationFile -Context $Context -RollbackState $rollbackState -Path $webScriptPath -Content $openWebUIContent
    Install-KIApplicationFile -Context $Context -RollbackState $rollbackState -Path $allScriptPath -Content $allContent
    Install-KIApplicationFile -Context $Context -RollbackState $rollbackState -Path $stopPsPath -Content $stopPsContent
    Install-KIApplicationFile -Context $Context -RollbackState $rollbackState -Path $stopCmdPath -Content $stopCmdContent

    $marker = [pscustomobject][ordered]@{
        managedBy = 'KI-STACK-APPLICATIONS-MANAGED'
        release = 'KI-Stack-Applications-Execute-v1.4.11'
        installedAt = (Get-Date).ToString('o')
        transactionId = [string]$Context.Transaction.transactionId
        lmStudio = [pscustomobject][ordered]@{
            packageId = [string]$lmConfig.packageId
            executablePath = $lmState.executablePath
            lmsPath = $lmState.lmsPath
            serverUrl = [string]$lmConfig.serverUrl
        }
        openWebUI = [pscustomobject][ordered]@{
            version = $targetVersion
            venv = $venvRoot
            dataRoot = $dataRoot
            url = [string]$webConfig.url
        }
    }
    $markerContent = $marker | ConvertTo-Json -Depth 20
    Install-KIApplicationFile -Context $Context -RollbackState $rollbackState -Path ([string]$applicationConfig.installationMarker) -Content $markerContent
    $finalOpenWebUIVersion = Get-KIOpenWebUIVersion -Context $Context
    Write-KIApplicationsProgress -Context $Context -Step 'OpenWebUIPhaseCompleted' -Data ([ordered]@{
        version=$finalOpenWebUIVersion;serviceStarted=$false;readinessRequired=$false
    })

    return [pscustomobject][ordered]@{
        success = $true
        skipped = $false
        message = 'LM Studio und Open WebUI wurden installiert und verwaltete Starter wurden erzeugt.'
        data = [pscustomobject][ordered]@{
            lmStudioInstalled = [bool]$lmState.installed
            lmStudioExecutable = $lmState.executablePath
            lmsPath = $lmState.lmsPath
            openWebUIVersion = $finalOpenWebUIVersion
            applicationStarter = $allScriptPath
            rollbackStatePath = (Get-KIApplicationsRollbackStatePath -Context $Context)
            diagnosticPath = (Get-KIApplicationsDiagnosticPath -Context $Context)
            pythonPath = $pythonPath
        }
    }
}

function Validate-KIModuleApplications {
    param([Parameter(Mandatory)][object]$Context)
    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{success=$true;skipped=$false;message='Dry-Run: Anwendungszielzustand ist planbar.';data=$null}
    }
    $issues = [System.Collections.Generic.List[string]]::new()
    $applicationConfig = $Context.Config.applications
    $lmState = Get-KILMStudioState -Context $Context
    if ([bool]$applicationConfig.lmStudio.enabled -and -not [bool]$lmState.installed) {
        [void]$issues.Add('LM Studio ist nicht installiert oder nicht nachweisbar.')
    }
    $actualWebVersion = Get-KIOpenWebUIVersion -Context $Context
    if ($actualWebVersion -ne [string]$applicationConfig.openWebUI.version) {
        [void]$issues.Add(('Open WebUI hat Version {0}; erwartet wird {1}.' -f $actualWebVersion,[string]$applicationConfig.openWebUI.version))
    }
    foreach ($requiredPath in @(
        [string]$applicationConfig.installationMarker,
        (Join-Path ([string]$applicationConfig.moduleRoot) 'Start-KIStack-LMStudio.cmd'),
        (Join-Path ([string]$applicationConfig.moduleRoot) 'Start-KIStack-OpenWebUI.cmd'),
        (Join-Path ([string]$applicationConfig.moduleRoot) 'Start-KIStack-Applications.cmd'),
        (Join-Path ([string]$applicationConfig.moduleRoot) 'Stop-KIStack-Applications.ps1'),
        (Join-Path ([string]$applicationConfig.moduleRoot) 'Stop-KIStack-Applications.cmd')
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            [void]$issues.Add("Verwaltete Anwendungsdatei fehlt: $requiredPath")
        }
    }
    if (Test-Path -LiteralPath ([string]$applicationConfig.installationMarker) -PathType Leaf) {
        try {
            $marker = Get-Content -LiteralPath ([string]$applicationConfig.installationMarker) -Raw | ConvertFrom-Json -Depth 50
            if ([string]$marker.managedBy -ne 'KI-STACK-APPLICATIONS-MANAGED') {
                [void]$issues.Add('Anwendungsmarker ist nicht als KI-Stack-Datei gekennzeichnet.')
            }
        }
        catch { [void]$issues.Add('Anwendungsmarker ist kein gültiges JSON.') }
    }
    $lmStudioReachable = Test-KIApplicationEndpoint -Uri ([string]$applicationConfig.lmStudio.serverUrl + '/v1/models') -Name 'LMStudio' -Context $Context
    $openWebUIReachable = Test-KIApplicationEndpoint -Uri ([string]$applicationConfig.openWebUI.url) -Name 'OpenWebUI' -Context $Context
    return [pscustomobject][ordered]@{
        success = ($issues.Count -eq 0)
        skipped = $false
        message = if ($issues.Count -eq 0) {'LM Studio und Open WebUI wurden vollständig validiert.'} else {$issues -join ' | '}
        data = [pscustomobject][ordered]@{
            issues = @($issues)
            lmStudioInstalled = [bool]$lmState.installed
            lmsAvailable = (-not [string]::IsNullOrWhiteSpace([string]$lmState.lmsPath))
            openWebUIVersion = $actualWebVersion
            lmStudioServerReachable = $lmStudioReachable
            openWebUIReachable = $openWebUIReachable
        }
    }
}

function Rollback-KIModuleApplications {
    param([Parameter(Mandatory)][object]$Context)
    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{success=$true;skipped=$true;message='Dry-Run: Kein Anwendungs-Rollback erforderlich.';data=$null}
    }
    $state = Read-KIApplicationsRollbackState -Context $Context
    if (-not $state) {
        return [pscustomobject][ordered]@{success=$true;skipped=$true;message='Kein Anwendungs-Rollbackjournal vorhanden.';data=$null}
    }
    $issues = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @($state.files) | Sort-Object { ([string]$_.path).Length } -Descending) {
        try {
            if ([bool]$entry.existedBefore) {
                [IO.File]::WriteAllBytes([string]$entry.path,[Convert]::FromBase64String([string]$entry.previousContentBase64))
            }
            elseif (Test-Path -LiteralPath ([string]$entry.path) -PathType Leaf) {
                Remove-Item -LiteralPath ([string]$entry.path) -Force
            }
        }
        catch { [void]$issues.Add($_.Exception.Message) }
    }

    try {
        if ([bool]$state.openWebUIVenvCreatedByTransaction) {
            $venvPath = [string]$Context.Config.applications.openWebUI.venv
            if (Test-Path -LiteralPath $venvPath -PathType Container) {
                Remove-Item -LiteralPath $venvPath -Recurse -Force
            }
        }
        elseif ([bool]$state.openWebUIVersionChanged -and -not [string]::IsNullOrWhiteSpace([string]$state.openWebUIPreviousVersion)) {
            $venvPython = Join-Path ([string]$Context.Config.applications.openWebUI.venv) 'Scripts\python.exe'
            $previousSpec = ('open-webui=={0}' -f [string]$state.openWebUIPreviousVersion)
            $restoreResult = Invoke-KIApplicationCommand -FilePath $venvPython -ArgumentList @(
                '-m','pip','install','--upgrade','--disable-pip-version-check','--no-input',$previousSpec
            ) -TimeoutSeconds 1800 -Context $Context -Operation 'OpenWebUIRollback'
            if ($restoreResult.exitCode -ne 0) { [void]$issues.Add('Vorherige Open-WebUI-Version konnte nicht wiederhergestellt werden.') }
        }
    }
    catch { [void]$issues.Add($_.Exception.Message) }

    if ([bool]$state.lmStudioInstalledByTransaction -and [bool]$Context.Config.executeRelease.allowWingetUninstallDuringRollback) {
        try {
            $wingetCommand = Get-Command winget.exe -ErrorAction Stop
            $uninstallResult = Invoke-KIApplicationCommand -FilePath $wingetCommand.Source -ArgumentList @(
                'uninstall','--id',[string]$Context.Config.applications.lmStudio.packageId,'--exact','--source','winget','--silent','--disable-interactivity'
            ) -TimeoutSeconds 1800 -Context $Context -Operation 'LMStudioWingetRollback'
            $lmStateAfterRollback = Get-KILMStudioState -Context $Context
            if ([bool]$lmStateAfterRollback.installed) {
                [void]$issues.Add(('LM Studio blieb nach Rollback installiert. winget-Exitcode: {0}' -f $uninstallResult.exitCode))
            }
        }
        catch { [void]$issues.Add($_.Exception.Message) }
    }

    foreach ($directory in @($state.createdDirectories) | Sort-Object { ([string]$_).Length } -Descending) {
        try {
            if (Test-Path -LiteralPath ([string]$directory) -PathType Container) {
                if (@(Get-ChildItem -LiteralPath ([string]$directory) -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                    Remove-Item -LiteralPath ([string]$directory) -Force
                }
            }
        }
        catch { [void]$issues.Add($_.Exception.Message) }
    }

    $state.rollbackCompletedAt = (Get-Date).ToString('o')
    $state.rollbackIssues = @($issues)
    Write-KIApplicationsRollbackState -Context $Context -State $state
    return [pscustomobject][ordered]@{
        success = ($issues.Count -eq 0)
        skipped = $false
        message = if ($issues.Count -eq 0) {'Anwendungs-Rollback abgeschlossen.'} else {'Anwendungs-Rollback mit Fehlern abgeschlossen.'}
        data = [pscustomobject][ordered]@{issues=@($issues)}
    }
}

Export-ModuleMember -Function *

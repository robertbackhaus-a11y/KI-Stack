Set-StrictMode -Version Latest

function Get-KIPythonGitProperty {
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

function Update-KIPythonGitProcessPath {
    $pathSegments = [System.Collections.Generic.List[string]]::new()
    $seenSegments = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($pathValue in @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine'),
        [Environment]::GetEnvironmentVariable('Path', 'User'),
        $env:Path
    )) {
        if (-not $pathValue) { continue }

        foreach ($segment in ([string]$pathValue -split [regex]::Escape(
            [string][IO.Path]::PathSeparator
        ))) {
            $trimmedSegment = $segment.Trim()
            if ($trimmedSegment -and $seenSegments.Add($trimmedSegment)) {
                [void]$pathSegments.Add($trimmedSegment)
            }
        }
    }

    $env:Path = ($pathSegments -join [IO.Path]::PathSeparator)
}

function Get-KIPythonCommand {
    $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue

    if ($pythonCommand) {
        return $pythonCommand
    }

    return Get-Command python -ErrorAction SilentlyContinue
}

function Get-KIGitCommand {
    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue

    if ($gitCommand) {
        return $gitCommand
    }

    return Get-Command git -ErrorAction SilentlyContinue
}

function Test-KIUvAvailable {
    param(
        [Parameter(Mandatory)]
        [object]$PythonCommand
    )

    $uvCommand = Get-Command uv.exe -ErrorAction SilentlyContinue
    if (-not $uvCommand) {
        $uvCommand = Get-Command uv -ErrorAction SilentlyContinue
    }

    if ($uvCommand) {
        return [pscustomobject][ordered]@{
            available = $true
            invocation = 'command'
            command = [string]$uvCommand.Source
        }
    }

    $null = & $PythonCommand.Source -m uv --version 2>$null
    if ($LASTEXITCODE -eq 0) {
        return [pscustomobject][ordered]@{
            available = $true
            invocation = 'python-module'
            command = ('{0} -m uv' -f [string]$PythonCommand.Source)
        }
    }

    return [pscustomobject][ordered]@{
        available = $false
        invocation = $null
        command = $null
    }
}

function Get-KIPythonGitState {
    Update-KIPythonGitProcessPath

    $pythonCommand = Get-KIPythonCommand
    $gitCommand = Get-KIGitCommand

    $uvState = if ($pythonCommand) {
        Test-KIUvAvailable -PythonCommand $pythonCommand
    }
    else {
        [pscustomobject][ordered]@{
            available = $false
            invocation = $null
            command = $null
        }
    }

    return [pscustomobject][ordered]@{
        pythonAvailable = ($null -ne $pythonCommand)
        pythonCommand = if ($pythonCommand) { [string]$pythonCommand.Source } else { $null }
        gitAvailable = ($null -ne $gitCommand)
        gitCommand = if ($gitCommand) { [string]$gitCommand.Source } else { $null }
        uvAvailable = [bool]$uvState.available
        uvInvocation = $uvState.invocation
        uvCommand = $uvState.command
    }
}

function Get-KIPythonGitRollbackStatePath {
    param([Parameter(Mandatory)][object]$Context)

    $stateDirectory = Join-Path ([string]$Context.TransactionDirectory) 'module-state'
    if (-not (Test-Path -LiteralPath $stateDirectory)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    return Join-Path $stateDirectory 'KIModulePythonGit.rollback.json'
}

function Write-KIPythonGitRollbackState {
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][object]$State
    )

    $statePath = Get-KIPythonGitRollbackStatePath -Context $Context
    $temporaryPath = '{0}.tmp' -f $statePath
    $State | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $statePath -Force
}

function Read-KIPythonGitRollbackState {
    param([Parameter(Mandatory)][object]$Context)

    $statePath = Get-KIPythonGitRollbackStatePath -Context $Context
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop |
        ConvertFrom-Json -Depth 30 -ErrorAction Stop
}

function Test-KIModulePythonGit {
    param([Parameter(Mandatory)][object]$Context)

    $state = Get-KIPythonGitState

    return [pscustomobject][ordered]@{
        success = (
            [bool]$state.pythonAvailable -and
            [bool]$state.gitAvailable
        )
        skipped = $false
        message = 'Python- und Git-Umgebung geprüft.'
        data = $state
    }
}

function Install-KIModulePythonGit {
    param([Parameter(Mandatory)][object]$Context)

    $targets = @(
        [string]$Context.Config.pythonEnvironment.root
        [string]$Context.Config.pythonEnvironment.venvRoot
        [string]$Context.Config.pythonEnvironment.packageCache
        [string]$Context.Config.gitEnvironment.repositoryRoot
    )

    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $false
            message = 'Dry-Run: Python- und Git-Umgebung wurde geplant.'
            data = [pscustomobject][ordered]@{
                wouldCreate = $targets
                wouldBootstrapUv = [bool]$Context.Config.pythonEnvironment.bootstrapUv
                wouldUpgradePip = [bool]$Context.Config.pythonEnvironment.pipUpgrade
                wouldEnableGitLongPaths = [bool]$Context.Config.gitEnvironment.longPaths
                createdByTransaction = @()
                changedGitLongPaths = $false
                uvInstalledByTransaction = $false
                rollbackStatePath = $null
            }
        }
    }

    Update-KIPythonGitProcessPath

    $pythonCommand = Get-KIPythonCommand
    if (-not $pythonCommand) {
        throw 'Python ist trotz abgeschlossenem Runtime-Modul nicht verfügbar.'
    }

    $gitCommand = Get-KIGitCommand
    if (-not $gitCommand) {
        throw 'Git ist trotz abgeschlossenem Runtime-Modul nicht verfügbar.'
    }

    $rollbackState = [pscustomobject][ordered]@{
        schemaVersion = '1.0'
        transactionId = [string]$Context.Transaction.transactionId
        createdAt = (Get-Date).ToString('o')
        updatedAt = (Get-Date).ToString('o')
        createdByTransaction = @()
        gitLongPathsExistedBefore = $false
        gitLongPathsValueBefore = $null
        changedGitLongPaths = $false
        uvAvailableBefore = $false
        uvInstalledByTransaction = $false
        rollbackCompletedAt = $null
        rollbackIssues = @()
    }
    Write-KIPythonGitRollbackState -Context $Context -State $rollbackState

    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            $rollbackState.createdByTransaction = @(
                $rollbackState.createdByTransaction
            ) + @($target)
            $rollbackState.updatedAt = (Get-Date).ToString('o')
            Write-KIPythonGitRollbackState -Context $Context -State $rollbackState
        }
    }

    if ([bool]$Context.Config.gitEnvironment.longPaths) {
        $existingLongPathsOutput = @(
            & $gitCommand.Source config --system --get core.longpaths 2>$null
        )
        $gitReadExitCode = $LASTEXITCODE

        if ($gitReadExitCode -eq 0) {
            $rollbackState.gitLongPathsExistedBefore = $true
            $rollbackState.gitLongPathsValueBefore = [string](
                $existingLongPathsOutput | Select-Object -Last 1
            )
        }
        elseif ($gitReadExitCode -eq 1) {
            $rollbackState.gitLongPathsExistedBefore = $false
            $rollbackState.gitLongPathsValueBefore = $null
        }
        else {
            throw "Git core.longpaths konnte nicht gelesen werden. Exitcode: $gitReadExitCode"
        }

        $rollbackState.updatedAt = (Get-Date).ToString('o')
        Write-KIPythonGitRollbackState -Context $Context -State $rollbackState

        $existingLongPaths = [string]$rollbackState.gitLongPathsValueBefore
        if ($existingLongPaths.Trim().ToLowerInvariant() -ne 'true') {
            & $gitCommand.Source config --system core.longpaths true
            if ($LASTEXITCODE -ne 0) {
                throw 'Git longpaths konnte nicht aktiviert werden.'
            }

            $rollbackState.changedGitLongPaths = $true
            $rollbackState.updatedAt = (Get-Date).ToString('o')
            Write-KIPythonGitRollbackState -Context $Context -State $rollbackState
        }
    }

    if ([bool]$Context.Config.pythonEnvironment.pipUpgrade) {
        & $pythonCommand.Source -m pip install --upgrade pip
        if ($LASTEXITCODE -ne 0) {
            throw 'pip konnte nicht aktualisiert werden.'
        }
    }

    $uvStateBefore = Test-KIUvAvailable -PythonCommand $pythonCommand
    $rollbackState.uvAvailableBefore = [bool]$uvStateBefore.available
    $rollbackState.updatedAt = (Get-Date).ToString('o')
    Write-KIPythonGitRollbackState -Context $Context -State $rollbackState

    if (
        [bool]$Context.Config.pythonEnvironment.bootstrapUv -and
        -not [bool]$uvStateBefore.available
    ) {
        try {
            & $pythonCommand.Source -m pip install --upgrade uv
            if ($LASTEXITCODE -ne 0) {
                throw 'uv konnte nicht installiert werden.'
            }

            $rollbackState.uvInstalledByTransaction = $true
            $rollbackState.updatedAt = (Get-Date).ToString('o')
            Write-KIPythonGitRollbackState -Context $Context -State $rollbackState
            Update-KIPythonGitProcessPath
        }
        catch {
            $uvStateAfterFailure = Test-KIUvAvailable -PythonCommand $pythonCommand
            if ([bool]$uvStateAfterFailure.available) {
                $rollbackState.uvInstalledByTransaction = $true
                $rollbackState.updatedAt = (Get-Date).ToString('o')
                Write-KIPythonGitRollbackState -Context $Context -State $rollbackState
            }
            throw
        }
    }

    $finalState = Get-KIPythonGitState
    if (-not [bool]$finalState.uvAvailable) {
        throw 'uv ist nach der Installation weder als Befehl noch als Python-Modul verfügbar.'
    }

    $rollbackStatePath = Get-KIPythonGitRollbackStatePath -Context $Context

    return [pscustomobject][ordered]@{
        success = $true
        skipped = $false
        message = 'Python- und Git-Umgebung wurde eingerichtet.'
        data = [pscustomobject][ordered]@{
            createdByTransaction = @($rollbackState.createdByTransaction)
            changedGitLongPaths = [bool]$rollbackState.changedGitLongPaths
            gitLongPathsExistedBefore = [bool]$rollbackState.gitLongPathsExistedBefore
            gitLongPathsValueBefore = $rollbackState.gitLongPathsValueBefore
            uvInstalledByTransaction = [bool]$rollbackState.uvInstalledByTransaction
            rollbackStatePath = $rollbackStatePath
            finalState = $finalState
        }
    }
}

function Validate-KIModulePythonGit {
    param([Parameter(Mandatory)][object]$Context)

    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $false
            message = 'Dry-Run: Python- und Git-Zielzustand ist planbar.'
            data = $null
        }
    }

    $state = Get-KIPythonGitState
    $missingCommands = [System.Collections.Generic.List[string]]::new()

    if (-not [bool]$state.pythonAvailable) {
        [void]$missingCommands.Add('python.exe')
    }

    if (-not [bool]$state.gitAvailable) {
        [void]$missingCommands.Add('git.exe')
    }

    if (-not [bool]$state.uvAvailable) {
        [void]$missingCommands.Add('uv')
    }

    $requiredDirectories = @(
        [string]$Context.Config.pythonEnvironment.root
        [string]$Context.Config.pythonEnvironment.venvRoot
        [string]$Context.Config.pythonEnvironment.packageCache
        [string]$Context.Config.gitEnvironment.repositoryRoot
    )

    $missingDirectories = @(
        $requiredDirectories |
        Where-Object { -not (Test-Path -LiteralPath $_) }
    )

    $configurationIssues = [System.Collections.Generic.List[string]]::new()
    if ([bool]$Context.Config.gitEnvironment.longPaths -and [bool]$state.gitAvailable) {
        $gitCommand = Get-KIGitCommand
        $longPathsOutput = @(
            & $gitCommand.Source config --system --get core.longpaths 2>$null
        )
        $longPathsExitCode = $LASTEXITCODE
        $longPathsValue = [string]($longPathsOutput | Select-Object -Last 1)

        if (
            $longPathsExitCode -ne 0 -or
            $longPathsValue.Trim().ToLowerInvariant() -ne 'true'
        ) {
            [void]$configurationIssues.Add('Git core.longpaths ist nicht true.')
        }
    }

    $success = (
        $missingCommands.Count -eq 0 -and
        $missingDirectories.Count -eq 0 -and
        $configurationIssues.Count -eq 0
    )

    return [pscustomobject][ordered]@{
        success = $success
        skipped = $false
        message = if ($success) {
            'Python, Git, uv, Git longpaths und die Zielverzeichnisse sind verfügbar.'
        }
        else {
            'Python-/Git-Zielzustand ist unvollständig.'
        }
        data = [pscustomobject][ordered]@{
            state = $state
            missingCommands = @($missingCommands)
            missingDirectories = @($missingDirectories)
            configurationIssues = @($configurationIssues)
        }
    }
}

function Rollback-KIModulePythonGit {
    param([Parameter(Mandatory)][object]$Context)

    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $true
            message = 'Dry-Run: Kein Python-/Git-Rollback erforderlich.'
            data = $null
        }
    }

    $moduleData = if ($null -ne $Context.ModuleResult) {
        Get-KIPythonGitProperty -Object $Context.ModuleResult -Name 'data'
    }
    else {
        $null
    }

    $rollbackState = Read-KIPythonGitRollbackState -Context $Context
    if ($null -eq $rollbackState) {
        $rollbackState = [pscustomobject][ordered]@{
            createdByTransaction = @(
                Get-KIPythonGitProperty -Object $moduleData `
                    -Name 'createdByTransaction' -Default @()
            )
            changedGitLongPaths = [bool](
                Get-KIPythonGitProperty -Object $moduleData `
                    -Name 'changedGitLongPaths' -Default $false
            )
            gitLongPathsExistedBefore = [bool](
                Get-KIPythonGitProperty -Object $moduleData `
                    -Name 'gitLongPathsExistedBefore' -Default $false
            )
            gitLongPathsValueBefore = (
                Get-KIPythonGitProperty -Object $moduleData `
                    -Name 'gitLongPathsValueBefore'
            )
            uvInstalledByTransaction = [bool](
                Get-KIPythonGitProperty -Object $moduleData `
                    -Name 'uvInstalledByTransaction' -Default $false
            )
        }
    }

    $pythonCommand = Get-KIPythonCommand
    $rollbackIssues = [System.Collections.Generic.List[string]]::new()

    if ([bool]$rollbackState.uvInstalledByTransaction) {
        if ($pythonCommand) {
            & $pythonCommand.Source -m pip uninstall --yes uv
            if ($LASTEXITCODE -ne 0) {
                [void]$rollbackIssues.Add('uv konnte nicht deinstalliert werden.')
            }
        }
        else {
            [void]$rollbackIssues.Add('Python fehlt; uv konnte nicht deinstalliert werden.')
        }
    }

    if ([bool]$rollbackState.changedGitLongPaths) {
        $gitCommand = Get-KIGitCommand
        if ($gitCommand) {
            if ([bool]$rollbackState.gitLongPathsExistedBefore) {
                & $gitCommand.Source config --system core.longpaths `
                    ([string]$rollbackState.gitLongPathsValueBefore)
                if ($LASTEXITCODE -ne 0) {
                    [void]$rollbackIssues.Add(
                        'Der vorherige Wert von Git core.longpaths konnte nicht wiederhergestellt werden.'
                    )
                }
            }
            else {
                & $gitCommand.Source config --system --unset core.longpaths 2>$null
                $unsetExitCode = $LASTEXITCODE

                $null = & $gitCommand.Source config --system --get core.longpaths 2>$null
                $verifyExitCode = $LASTEXITCODE
                if ($unsetExitCode -ne 0 -and $verifyExitCode -eq 0) {
                    [void]$rollbackIssues.Add(
                        'Git core.longpaths konnte nicht entfernt werden.'
                    )
                }
            }
        }
        else {
            [void]$rollbackIssues.Add('Git fehlt; core.longpaths konnte nicht zurückgesetzt werden.')
        }
    }

    $created = @(
        Get-KIPythonGitProperty -Object $rollbackState `
            -Name 'createdByTransaction' -Default @()
    ) | Where-Object { $_ }

    $removed = [System.Collections.Generic.List[string]]::new()

    foreach ($target in ($created | Sort-Object Length -Descending)) {
        if (Test-Path -LiteralPath $target) {
            $children = @(
                Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue
            )

            if ($children.Count -eq 0) {
                Remove-Item -LiteralPath $target -Force
                [void]$removed.Add($target)
            }
        }
    }

    $success = ($rollbackIssues.Count -eq 0)

    try {
        $rollbackState | Add-Member -NotePropertyName rollbackCompletedAt `
            -NotePropertyValue (Get-Date).ToString('o') -Force
        $rollbackState | Add-Member -NotePropertyName rollbackIssues `
            -NotePropertyValue @($rollbackIssues) -Force
        $rollbackState | Add-Member -NotePropertyName updatedAt `
            -NotePropertyValue (Get-Date).ToString('o') -Force
        Write-KIPythonGitRollbackState -Context $Context -State $rollbackState
    }
    catch {
        [void]$rollbackIssues.Add(
            "Rollback-Journal konnte nicht aktualisiert werden: $($_.Exception.Message)"
        )
        $success = $false
    }

    return [pscustomobject][ordered]@{
        success = $success
        skipped = $false
        message = if ($success) {
            'Python-/Git-Änderungen wurden zurückgerollt.'
        }
        else {
            'Python-/Git-Rollback war nicht vollständig erfolgreich.'
        }
        data = [pscustomobject][ordered]@{
            removed = @($removed)
            issues = @($rollbackIssues)
            rollbackStatePath = (Get-KIPythonGitRollbackStatePath -Context $Context)
        }
    }
}

Export-ModuleMember -Function *

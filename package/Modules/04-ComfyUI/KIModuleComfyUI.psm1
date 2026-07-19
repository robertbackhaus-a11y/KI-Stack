Set-StrictMode -Version Latest

function Test-KIModuleComfyUI {
    param([Parameter(Mandatory)][object]$Context)

    $gitAvailable = $null -ne (Get-Command git.exe -ErrorAction SilentlyContinue)
    $pythonAvailable = $null -ne (Get-Command python.exe -ErrorAction SilentlyContinue)

    return [pscustomobject][ordered]@{
        success = ($gitAvailable -and $pythonAvailable)
        skipped = $false
        message = 'ComfyUI-Voraussetzungen geprüft.'
        data = [pscustomobject][ordered]@{
            gitAvailable = $gitAvailable
            pythonAvailable = $pythonAvailable
        }
    }
}

function Install-KIModuleComfyUI {
    param([Parameter(Mandatory)][object]$Context)

    $root = [string]$Context.Config.comfyUI.root
    $venv = [string]$Context.Config.comfyUI.venv
    $customNodes = [string]$Context.Config.comfyUI.customNodesRoot

    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $false
            message = 'Dry-Run: ComfyUI-Installation wurde geplant.'
            data = [pscustomobject][ordered]@{
                repository = [string]$Context.Config.comfyUI.repository
                branch = [string]$Context.Config.comfyUI.branch
                root = $root
                venv = $venv
                customNodesRoot = $customNodes
                createdByTransaction = @()
            }
        }
    }

    $created = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $root)) {
        & git.exe clone --branch ([string]$Context.Config.comfyUI.branch) `
            ([string]$Context.Config.comfyUI.repository) $root
        if ($LASTEXITCODE -ne 0) { throw 'ComfyUI-Repository konnte nicht geklont werden.' }
        [void]$created.Add($root)
    }

    if (-not (Test-Path -LiteralPath $venv)) {
        & python.exe -m venv $venv
        if ($LASTEXITCODE -ne 0) { throw 'ComfyUI-venv konnte nicht erstellt werden.' }
        [void]$created.Add($venv)
    }

    $venvPython = Join-Path $venv 'Scripts\python.exe'
    & $venvPython -m pip install --upgrade pip
    if ($LASTEXITCODE -ne 0) { throw 'pip-Upgrade für ComfyUI fehlgeschlagen.' }

    & $venvPython -m pip install -r (Join-Path $root 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw 'ComfyUI-Abhängigkeiten konnten nicht installiert werden.' }

    return [pscustomobject][ordered]@{
        success = $true
        skipped = $false
        message = 'ComfyUI wurde installiert.'
        data = [pscustomobject][ordered]@{ createdByTransaction = @($created) }
    }
}

function Validate-KIModuleComfyUI {
    param([Parameter(Mandatory)][object]$Context)

    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $false
            message = 'Dry-Run: ComfyUI-Zielzustand ist planbar.'
            data = $null
        }
    }

    $root = [string]$Context.Config.comfyUI.root
    $venvPython = Join-Path ([string]$Context.Config.comfyUI.venv) 'Scripts\python.exe'
    $mainPy = Join-Path $root 'main.py'
    $missing = @()
    foreach ($path in @($root,$venvPython,$mainPy)) {
        if (-not (Test-Path -LiteralPath $path)) { $missing += $path }
    }

    return [pscustomobject][ordered]@{
        success = ($missing.Count -eq 0)
        skipped = $false
        message = if ($missing.Count -eq 0) { 'ComfyUI-Dateistruktur ist vollständig.' } else { 'ComfyUI-Dateien fehlen.' }
        data = [pscustomobject][ordered]@{ missingPaths = $missing }
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

    $created = @($Context.ModuleResult.data.createdByTransaction) | Where-Object { $_ }
    foreach ($path in ($created | Sort-Object Length -Descending)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }

    return [pscustomobject][ordered]@{
        success = $true
        skipped = $false
        message = 'Durch die Transaktion erzeugte ComfyUI-Pfade wurden entfernt.'
        data = [pscustomobject][ordered]@{ removed = $created }
    }
}

Export-ModuleMember -Function *

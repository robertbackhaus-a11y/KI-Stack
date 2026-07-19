Set-StrictMode -Version Latest

function Get-KIModelsManifest {
    param([Parameter(Mandatory)][object]$Context)
    $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $manifestPath = Join-Path $projectRoot ([string]$Context.Config.models.manifestPath)
    return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 50
}

function Test-KIModuleModels {
    param([Parameter(Mandatory)][object]$Context)
    $manifest = Get-KIModelsManifest -Context $Context
    $enabledModels = @($manifest.models | Where-Object { [bool]$_.enabled })
    $invalidModels = @($enabledModels | Where-Object {
        -not [string]$_.fileName -or -not [string]$_.source -or -not [string]$_.sha256
    })
    return [pscustomobject][ordered]@{
        success = ($invalidModels.Count -eq 0)
        skipped = $false
        message = 'Modellmanifest geprüft.'
        data = [pscustomobject][ordered]@{
            enabledModelCount = $enabledModels.Count
            invalidModelCount = $invalidModels.Count
        }
    }
}

function Install-KIModuleModels {
    param([Parameter(Mandatory)][object]$Context)
    $root = [string]$Context.Config.models.root
    $targets = @($Context.Config.models.directories | ForEach-Object { Join-Path $root ([string]$_) })

    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $false
            message = 'Dry-Run: Modellstruktur wurde geplant.'
            data = [pscustomobject][ordered]@{
                wouldCreate = $targets
                downloadsEnabled = [bool]$Context.Config.models.downloadsEnabled
                createdByTransaction = @()
            }
        }
    }

    $createdPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            [void]$createdPaths.Add($target)
        }
    }

    return [pscustomobject][ordered]@{
        success = $true
        skipped = $false
        message = 'Modellverzeichnisse wurden erstellt.'
        data = [pscustomobject][ordered]@{ createdByTransaction = @($createdPaths) }
    }
}

function Validate-KIModuleModels {
    param([Parameter(Mandatory)][object]$Context)
    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $false
            message = 'Dry-Run: Modellzielzustand ist planbar.'
            data = $null
        }
    }
    $root = [string]$Context.Config.models.root
    $missingPaths = @($Context.Config.models.directories |
        ForEach-Object { Join-Path $root ([string]$_) } |
        Where-Object { -not (Test-Path -LiteralPath $_) })
    return [pscustomobject][ordered]@{
        success = ($missingPaths.Count -eq 0)
        skipped = $false
        message = if ($missingPaths.Count -eq 0) { 'Modellstruktur vollständig.' } else { 'Modellverzeichnisse fehlen.' }
        data = [pscustomobject][ordered]@{ missingPaths = $missingPaths }
    }
}

function Rollback-KIModuleModels {
    param([Parameter(Mandatory)][object]$Context)
    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $true
            message = 'Dry-Run: Kein Modell-Rollback erforderlich.'
            data = $null
        }
    }
    $createdPaths = @($Context.ModuleResult.data.createdByTransaction) | Where-Object { $_ }
    foreach ($target in ($createdPaths | Sort-Object Length -Descending)) {
        if (Test-Path -LiteralPath $target) {
            $children = @(Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue)
            if ($children.Count -eq 0) { Remove-Item -LiteralPath $target -Force }
        }
    }
    return [pscustomobject][ordered]@{
        success = $true
        skipped = $false
        message = 'Leere Modellverzeichnisse wurden entfernt.'
        data = [pscustomobject][ordered]@{ removed = $createdPaths }
    }
}

Export-ModuleMember -Function *

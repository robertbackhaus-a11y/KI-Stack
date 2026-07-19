Set-StrictMode -Version Latest

function Test-KIModuleFoundation {
    param([Parameter(Mandatory)][object]$Context)

    $targets = @(
        $Context.Config.stackRoot,
        $Context.Config.stateRoot,
        $Context.Config.logRoot,
        $Context.Config.cacheRoot,
        $Context.Config.backupRoot,
        $Context.Config.moduleRoot
    )

    $existing = @(
        $targets |
        Where-Object { Test-Path -LiteralPath $_ }
    )

    return [pscustomobject][ordered]@{
        success = $true
        skipped = $false
        message = 'Foundation-Voraussetzungen geprüft.'
        data = [pscustomobject][ordered]@{
            targetPaths = $targets
            existingPaths = $existing
        }
    }
}

function Install-KIModuleFoundation {
    param([Parameter(Mandatory)][object]$Context)

    $targets = @(
        $Context.Config.stackRoot,
        $Context.Config.stateRoot,
        $Context.Config.logRoot,
        $Context.Config.cacheRoot,
        $Context.Config.backupRoot,
        $Context.Config.moduleRoot
    )

    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $false
            message = 'Dry-Run: Foundation-Verzeichnisse würden angelegt.'
            data = [pscustomobject][ordered]@{
                wouldCreate = @($targets | Where-Object { -not (Test-Path -LiteralPath $_) })
            }
        }
    }

    $created = [System.Collections.Generic.List[string]]::new()
    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop |
                Out-Null
            [void]$created.Add($target)
        }
    }

    return [pscustomobject][ordered]@{
        success = $true
        skipped = $false
        message = 'Foundation-Verzeichnisse wurden angelegt.'
        data = [pscustomobject][ordered]@{
            created = @($created)
        }
    }
}

function Validate-KIModuleFoundation {
    param([Parameter(Mandatory)][object]$Context)

    $targets = @(
        $Context.Config.stackRoot,
        $Context.Config.stateRoot,
        $Context.Config.logRoot,
        $Context.Config.cacheRoot,
        $Context.Config.backupRoot,
        $Context.Config.moduleRoot
    )

    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $false
            message = 'Dry-Run: Foundation-Zielstruktur ist planbar.'
            data = [pscustomobject][ordered]@{
                targetPaths = $targets
            }
        }
    }

    $missing = @(
        $targets |
        Where-Object { -not (Test-Path -LiteralPath $_) }
    )

    return [pscustomobject][ordered]@{
        success = ($missing.Count -eq 0)
        skipped = $false
        message = if ($missing.Count -eq 0) {
            'Foundation-Zielstruktur ist vollständig.'
        } else {
            'Foundation-Zielstruktur ist unvollständig.'
        }
        data = [pscustomobject][ordered]@{
            missing = $missing
        }
    }
}

function Rollback-KIModuleFoundation {
    param([Parameter(Mandatory)][object]$Context)

    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $true
            message = 'Dry-Run: Kein Rollback erforderlich.'
            data = $null
        }
    }

    $created = @(
        $Context.ModuleResult.data.created
    ) | Where-Object { $_ }

    $removed = [System.Collections.Generic.List[string]]::new()
    foreach ($target in ($created | Sort-Object Length -Descending)) {
        if (Test-Path -LiteralPath $target) {
            $children = @(Get-ChildItem -LiteralPath $target -Force -ErrorAction Stop)
            if ($children.Count -eq 0) {
                Remove-Item -LiteralPath $target -Force -ErrorAction Stop
                [void]$removed.Add($target)
            }
        }
    }

    return [pscustomobject][ordered]@{
        success = $true
        skipped = $false
        message = 'Leere, durch den Lauf erzeugte Foundation-Verzeichnisse entfernt.'
        data = [pscustomobject][ordered]@{
            removed = @($removed)
        }
    }
}

Export-ModuleMember -Function *

Set-StrictMode -Version Latest

function Get-KIStarterDefaultSearchRoots {
    [CmdletBinding()]
    param([string]$ProjectRoot)

    $roots = [System.Collections.Generic.List[string]]::new()

    if ($env:KI_STACK_PREFLIGHT_ROOT) {
        [void]$roots.Add([Environment]::ExpandEnvironmentVariables(
            [string]$env:KI_STACK_PREFLIGHT_ROOT
        ))
    }

    if ($env:USERPROFILE) {
        $downloadsRoot = Join-Path ([string]$env:USERPROFILE) 'Downloads'
        [void]$roots.Add((Join-Path $downloadsRoot 'KI_Stack'))
        [void]$roots.Add($downloadsRoot)
    }

    if ($ProjectRoot) {
        [void]$roots.Add($ProjectRoot)
        $parent = Split-Path -Parent $ProjectRoot
        if ($parent) {
            [void]$roots.Add($parent)
        }
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    return @(
        foreach ($root in $roots) {
            if (-not $root) { continue }
            $expanded = [Environment]::ExpandEnvironmentVariables([string]$root)
            if ($seen.Add($expanded)) {
                $expanded
            }
        }
    )
}

function Find-KILatestPreflight {
    [CmdletBinding()]
    param(
        [string]$ExplicitPath,
        [string[]]$SearchRoots,
        [string]$FilePattern = 'Preflight-*.zip',
        [bool]$SearchRecursively = $true,
        [switch]$RequireStateDirectory
    )

    if ($ExplicitPath) {
        $expandedPath = [Environment]::ExpandEnvironmentVariables($ExplicitPath)
        $resolved = Resolve-Path -LiteralPath $expandedPath -ErrorAction Stop
        $item = Get-Item -LiteralPath $resolved.Path -ErrorAction Stop

        if (-not $item.PSIsContainer -and $item.Extension -ieq '.zip') {
            return $item
        }

        throw "Der explizite Preflight-Pfad ist keine ZIP-Datei: $expandedPath"
    }

    $candidates = [System.Collections.Generic.List[object]]::new()
    $seenFiles = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($root in @($SearchRoots)) {
        if (-not $root) { continue }

        $expandedRoot = [Environment]::ExpandEnvironmentVariables([string]$root)
        if (-not (Test-Path -LiteralPath $expandedRoot -PathType Container)) {
            continue
        }

        $found = @(
            Get-ChildItem -LiteralPath $expandedRoot -File `
                -Recurse:$SearchRecursively -Filter $FilePattern -Force `
                -ErrorAction SilentlyContinue
        )

        foreach ($file in $found) {
            if ($RequireStateDirectory -and $file.Directory.Name -ine 'State') {
                continue
            }

            if ($seenFiles.Add($file.FullName)) {
                [void]$candidates.Add($file)
            }
        }
    }

    if ($candidates.Count -eq 0) {
        $rootText = @($SearchRoots) -join ' | '
        throw "Kein Preflight-ZIP gefunden. Durchsuchte Wurzeln: $rootText"
    }

    return @(
        $candidates |
        Sort-Object `
            @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true }, `
            @{ Expression = { $_.FullName }; Descending = $true }
    )[0]
}

function Test-KIStarterPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $requiredPaths = @(
        'Config\kernel-config.json',
        'Core\KIStack.BuilderKernel.Core.psm1',
        'Core\KIStack.Starter.psm1',
        'Invoke-KIStackBuilderKernel.ps1',
        'Bootstrap-KIStack-Integration.cmd',
        'Start-KIStack-Integration.ps1',
        'Request-KIStack-Elevation.ps1',
        'Tests\Test-KIStackPowerShellSyntax.ps1',
        'Tests\Test-KIStackBuilderKernel.ps1',
        'Tests\Test-KIStackPathResolution.ps1',
        'Embedded\Preflight\State\Preflight-Continuation-v1.5.7.zip'
    )

    $missing = @(
        foreach ($relativePath in $requiredPaths) {
            $fullPath = Join-Path $ProjectRoot $relativePath
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                $relativePath
            }
        }
    )

    return [pscustomobject][ordered]@{
        valid = ($missing.Count -eq 0)
        missing = @($missing)
        required = $requiredPaths
    }
}

function New-KIStarterLogPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $directory = Join-Path $ProjectRoot 'State\Starter'
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    return Join-Path $directory (
        'Starter-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmssfff')
    )
}

function Write-KIStarterLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )

    $line = '[{0}] {1}' -f (Get-Date).ToString('o'), $Message
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

Export-ModuleMember -Function *

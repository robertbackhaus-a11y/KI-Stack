Set-StrictMode -Version Latest

function Test-KIModuleIntegration {
    param([Parameter(Mandatory)][object]$Context)
    $wslAvailable = $null -ne (Get-Command wsl.exe -ErrorAction SilentlyContinue)
    return [pscustomobject][ordered]@{
        success = $wslAvailable
        skipped = $false
        message = 'WSL-/SearXNG-Voraussetzungen geprüft.'
        data = [pscustomobject][ordered]@{
            wslAvailable = $wslAvailable
            distribution = [string]$Context.Config.integration.wslDistribution
        }
    }
}

function Install-KIModuleIntegration {
    param([Parameter(Mandatory)][object]$Context)
    if ($Context.Mode -ne 'DryRun') {
        throw 'Execute ist in v1.0.2 noch nicht freigegeben.'
    }
    return [pscustomobject][ordered]@{
        success = $true
        skipped = $false
        message = 'Dry-Run: WSL-, SearXNG- und Cutover-Integration wurde geplant.'
        data = [pscustomobject][ordered]@{
            distribution = [string]$Context.Config.integration.wslDistribution
            cutoverEnabled = [bool]$Context.Config.integration.cutoverEnabled
        }
    }
}

function Validate-KIModuleIntegration {
    param([Parameter(Mandatory)][object]$Context)
    $endpoints = @(
        [string]$Context.Config.integration.searxngUrl,
        [string]$Context.Config.integration.openWebUIUrl,
        [string]$Context.Config.integration.lmStudioUrl,
        [string]$Context.Config.integration.comfyUIUrl
    )
    return [pscustomobject][ordered]@{
        success = $true
        skipped = $false
        message = 'Dry-Run: End-to-End-Endpunkte wurden zur Prüfung eingeplant.'
        data = [pscustomobject][ordered]@{
            endpoints = $endpoints
            timeoutSeconds = [int]$Context.Config.integration.timeoutSeconds
        }
    }
}

Export-ModuleMember -Function *

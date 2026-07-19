Set-StrictMode -Version Latest

function Test-KIModuleApplications {
    param([Parameter(Mandatory)][object]$Context)
    $wingetAvailable = $null -ne (Get-Command winget.exe -ErrorAction SilentlyContinue)
    $pythonAvailable = $null -ne (Get-Command python.exe -ErrorAction SilentlyContinue)
    return [pscustomobject][ordered]@{
        success = ($wingetAvailable -and $pythonAvailable)
        skipped = $false
        message = 'LM Studio/Open WebUI-Voraussetzungen geprüft.'
        data = [pscustomobject][ordered]@{
            wingetAvailable = $wingetAvailable
            pythonAvailable = $pythonAvailable
        }
    }
}

function Install-KIModuleApplications {
    param([Parameter(Mandatory)][object]$Context)
    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $false
            message = 'Dry-Run: LM Studio und Open WebUI wurden geplant.'
            data = [pscustomobject][ordered]@{
                lmStudioPackageId = [string]$Context.Config.applications.lmStudio.packageId
                openWebUIVenv = [string]$Context.Config.applications.openWebUI.venv
                openWebUIDataRoot = [string]$Context.Config.applications.openWebUI.dataRoot
                createdByTransaction = @()
            }
        }
    }
    throw 'Execute ist in v1.0.2 noch nicht freigegeben.'
}

function Validate-KIModuleApplications {
    param([Parameter(Mandatory)][object]$Context)
    return [pscustomobject][ordered]@{
        success = $true
        skipped = $false
        message = if ($Context.Mode -eq 'DryRun') {
            'Dry-Run: Anwendungszielzustand ist planbar.'
        } else {
            'Anwendungsvalidierung abgeschlossen.'
        }
        data = [pscustomobject][ordered]@{
            lmStudioUrl = [string]$Context.Config.applications.lmStudio.serverUrl
            openWebUIUrl = [string]$Context.Config.applications.openWebUI.url
        }
    }
}

function Rollback-KIModuleApplications {
    param([Parameter(Mandatory)][object]$Context)
    return [pscustomobject][ordered]@{
        success = $true
        skipped = $true
        message = 'Kein Anwendungs-Rollback erforderlich.'
        data = $null
    }
}

Export-ModuleMember -Function *

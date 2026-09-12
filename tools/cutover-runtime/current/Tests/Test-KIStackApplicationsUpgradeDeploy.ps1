[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$failures=[Collections.Generic.List[string]]::new()

Import-Module (Join-Path $ProjectRoot 'Modules/06-Applications/KIModuleApplications.psm1') -Force -DisableNameChecking

# A real, reproduced defect (found on the live target after the 2.18.1 OpenWebUI
# secret-key fix shipped): Complete Installer's compliance check for the
# 'applications' component compared the pinned Contracts/COMPONENTS.json version
# against the value baked into modules/applications/installation.json's own
# 'release' string -- bumping the *content* of Install-KIModuleApplications
# (the secret-key contract) without also bumping this version marker left every
# existing target permanently "compliant" at the old version, so the fix was
# never deployed to any target that had already run the old code. This suite
# proves the module-level half of the fix: that Install-KIModuleApplications,
# when it DOES run (as it will once the pinned version no longer matches),
# actually rewrites Start-KIStack-OpenWebUI.cmd with the secret-key contract,
# writes the new version into installation.json, and leaves pre-existing
# Applications/OpenWebUI data untouched. The plan-level half (Skip -> Upgrade
# -> Skip as the pin is bumped) is covered separately by
# Test-KIStackApplicationsUpgradePlan.ps1 in the Complete Installer package.

function New-KIFixtureRoot {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-AppsUpgrade-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    $root
}

$pythonCommand=@(Get-Command python.exe -All -ErrorAction SilentlyContinue|Where-Object{$_.Source -notmatch '(?i)\\Microsoft\\WindowsApps\\'})|Select-Object -First 1
if(-not $pythonCommand){
    [pscustomobject]@{passed=$true;skipped=$true;reason='No real Python 3.11/3.12 available on this machine to build a hermetic fixture venv.';checks=0;failures=@()}|ConvertTo-Json -Depth 5
    exit 0
}

$root=New-KIFixtureRoot
try{
    $moduleRoot=Join-Path $root 'modules\applications'
    $venvRoot=Join-Path $root 'python\venvs\openwebui'
    $dataRoot=Join-Path $root 'OpenWebUI\data'
    New-Item -ItemType Directory -Path $moduleRoot,$dataRoot -Force|Out-Null

    # --- Build a hermetic fake venv: a real venv (no network) whose Scripts\python.exe
    # reports open-webui==0.11.3 via a planted .dist-info, so Install-KIModuleApplications
    # takes the "already at target version" path and never touches pip/network. ---------
    $venvCreate=Start-Process -FilePath $pythonCommand.Source -ArgumentList @('-m','venv',$venvRoot,'--without-pip') -Wait -PassThru -NoNewWindow
    if($venvCreate.ExitCode -ne 0){throw "Fixture-Venv konnte nicht erstellt werden (Exitcode $($venvCreate.ExitCode))."}
    $venvPython=Join-Path $venvRoot 'Scripts\python.exe'
    $distInfo=Join-Path $venvRoot 'Lib\site-packages\open_webui-0.11.3.dist-info'
    New-Item -ItemType Directory -Path $distInfo -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $distInfo 'METADATA') -Encoding ascii -Value @('Metadata-Version: 2.1','Name: open-webui','Version: 0.11.3')

    # --- Canaries proving existing Applications/OpenWebUI data survives the upgrade. ---
    $dataCanary=Join-Path $dataRoot 'user-uploaded-canary.txt'
    Set-Content -LiteralPath $dataCanary -Encoding utf8 -Value 'pre-existing OpenWebUI user data'
    $venvCanary=Join-Path $venvRoot 'pyvenv-canary.txt'
    Set-Content -LiteralPath $venvCanary -Encoding utf8 -Value 'pre-existing venv (must not be recreated)'

    # --- Seed an existing installation at the OLD 1.4.11 marker, matching the real ------
    # target defect report exactly (release string ends in -v1.4.11). -------------------
    $installationMarker=Join-Path $moduleRoot 'installation.json'
    Set-Content -LiteralPath $installationMarker -Encoding utf8 -Value (
        [pscustomobject][ordered]@{managedBy='KI-STACK-APPLICATIONS-MANAGED';release='KI-Stack-Applications-Execute-v1.4.11';installedAt=(Get-Date).ToString('o')}|ConvertTo-Json
    )
    $oldStarterContent=@'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
title KI-Stack Open WebUI
set "DATA_DIR=OLD"
"OLD-PYTHON" -c "from open_webui import app; app()" serve --host 127.0.0.1 --port 8080
'@
    Set-Content -LiteralPath (Join-Path $moduleRoot 'Start-KIStack-OpenWebUI.cmd') -Encoding ascii -Value $oldStarterContent

    $transactionDirectory=Join-Path $root 'transaction-state'
    New-Item -ItemType Directory -Path $transactionDirectory -Force|Out-Null

    $context=[pscustomobject]@{
        Mode='Upgrade'
        LogPath=$null
        TransactionDirectory=$transactionDirectory
        Transaction=[pscustomobject]@{transactionId='TEST-APPS-UPGRADE-1'}
        Config=[pscustomobject]@{
            applications=[pscustomobject]@{
                moduleRoot=$moduleRoot
                installationMarker=$installationMarker
                lmStudio=[pscustomobject]@{
                    enabled=$false
                    packageId='ElementLabs.LMStudio'
                    serverUrl='http://127.0.0.1:1234'
                    bindAddress='127.0.0.1'
                    port=1234
                    allowWingetInstall=$false
                }
                openWebUI=[pscustomobject]@{
                    packageName='open-webui'
                    version='0.11.3'
                    minimumSupportedVersion='0.11.3'
                    maximumSupportedVersion=$null
                    venv=$venvRoot
                    dataRoot=$dataRoot
                    url='http://127.0.0.1:8080'
                    bindAddress='127.0.0.1'
                    port=8080
                    openAIBaseUrl='http://127.0.0.1:1234/v1'
                    openAIKey='lm-studio'
                    disableOllama=$true
                    pipUpgrade=$false
                }
            }
        }
    }

    $result=Install-KIModuleApplications -Context $context
    if(-not [bool]$result.success){throw "Install-KIModuleApplications ist fehlgeschlagen: $($result.message)"}

    $newStarterContent=Get-Content -LiteralPath (Join-Path $moduleRoot 'Start-KIStack-OpenWebUI.cmd') -Raw
    $newMarker=Get-Content -LiteralPath $installationMarker -Raw|ConvertFrom-Json -Depth 20

    $checks=[ordered]@{
        starterRewritten = (-not $newStarterContent.Contains('OLD-PYTHON'))
        starterHasSecretKeyContract = ($newStarterContent.Contains('set /p WEBUI_SECRET_KEY=<"') -and $newStarterContent.Contains('state\openwebui\.webui_secret_key'))
        starterHasStableWorkingDirectory = $newStarterContent.Contains('cd /d "'+$root+'"')
        markerVersionBumped = ([string]$newMarker.release -match '-v1\.4\.12$')
        markerVersionNoLongerOld = (-not ([string]$newMarker.release -match '-v1\.4\.11$'))
        dataCanarySurvived = ((Test-Path -LiteralPath $dataCanary -PathType Leaf) -and (Get-Content -LiteralPath $dataCanary -Raw).Trim() -eq 'pre-existing OpenWebUI user data')
        venvCanarySurvived = ((Test-Path -LiteralPath $venvCanary -PathType Leaf) -and (Get-Content -LiteralPath $venvCanary -Raw).Trim() -eq 'pre-existing venv (must not be recreated)')
        secretKeyFileCreatedUnderStateNotDataOrVenv = (Test-Path -LiteralPath (Join-Path $root 'state\openwebui\.webui_secret_key') -PathType Leaf)
    }
    foreach($name in $checks.Keys){
        if(-not [bool]$checks[$name]){$failures.Add("Check '$name' fehlgeschlagen.")}
    }

    # Repeat run: the marker is now at 1.4.12; a second Install call (as would happen on a
    # rerun before Complete Installer re-checks compliance) must remain stable -- same
    # version, canaries still intact, no error.
    $result2=Install-KIModuleApplications -Context $context
    if(-not [bool]$result2.success){$failures.Add('Wiederholter Install-Aufruf ist fehlgeschlagen.')}
    $marker2=Get-Content -LiteralPath $installationMarker -Raw|ConvertFrom-Json -Depth 20
    if([string]$marker2.release -ne [string]$newMarker.release){$failures.Add('Wiederholter Install-Aufruf hat die Marker-Version veraendert.')}
    if(-not(Test-Path -LiteralPath $dataCanary -PathType Leaf)){$failures.Add('Wiederholter Install-Aufruf hat vorhandene OpenWebUI-Daten entfernt.')}
}
finally{
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}

$result=[pscustomobject]@{passed=($failures.Count-eq0);skipped=$false;checks=11;failures=@($failures)}
$result|ConvertTo-Json -Depth 10
if(-not $result.passed){exit 1}

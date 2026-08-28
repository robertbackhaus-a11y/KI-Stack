[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$fixtureFakeModuleContent=@'
Set-StrictMode -Version Latest

function Get-KIOpenWebUIVersion {
    param([Parameter(Mandatory)][object]$Context)
    $marker=Join-Path ([string]$Context.Config.applications.openWebUI.venv) 'current-version.txt'
    if(-not(Test-Path -LiteralPath $marker -PathType Leaf)){return $null}
    (Get-Content -LiteralPath $marker -Raw).Trim()
}

function Test-KIApplicationEndpoint {
    param([string]$Uri,[string]$Name,[object]$Context,[int]$TimeoutSeconds=3)
    $flag=Join-Path ([string]$Context.Config.applications.openWebUI.venv) 'health-flag.txt'
    if(-not(Test-Path -LiteralPath $flag -PathType Leaf)){return $false}
    (Get-Content -LiteralPath $flag -Raw).Trim()-eq'healthy'
}

function Install-KIModuleApplications {
    param([Parameter(Mandatory)][object]$Context)
    $venv=[string]$Context.Config.applications.openWebUI.venv
    $marker=Join-Path $venv 'current-version.txt'
    $failFlag=Join-Path $venv 'FORCE_INSTALL_FAIL'
    $rollbackStatePath=Join-Path ([string]$Context.TransactionDirectory) 'rollback-state.json'
    $previous=if(Test-Path -LiteralPath $marker -PathType Leaf){(Get-Content -LiteralPath $marker -Raw).Trim()}else{$null}
    [pscustomobject]@{previousVersion=$previous}|ConvertTo-Json|Set-Content -LiteralPath $rollbackStatePath -Encoding UTF8
    if(Test-Path -LiteralPath $failFlag -PathType Leaf){
        return [pscustomobject][ordered]@{success=$false;skipped=$false;message='Simulierter Installationsfehler.';data=$null}
    }
    $target=[string]$Context.Config.applications.openWebUI.version
    Set-Content -LiteralPath $marker -Value $target -Encoding UTF8
    [pscustomobject][ordered]@{success=$true;skipped=$false;message='OK';data=$null}
}

function Rollback-KIModuleApplications {
    param([Parameter(Mandatory)][object]$Context)
    $venv=[string]$Context.Config.applications.openWebUI.venv
    $marker=Join-Path $venv 'current-version.txt'
    $rollbackStatePath=Join-Path ([string]$Context.TransactionDirectory) 'rollback-state.json'
    if(-not(Test-Path -LiteralPath $rollbackStatePath -PathType Leaf)){
        return [pscustomobject][ordered]@{success=$true;skipped=$true;message='Kein Rollbackjournal.';data=$null}
    }
    $state=Get-Content -LiteralPath $rollbackStatePath -Raw|ConvertFrom-Json
    if($null-ne$state.previousVersion){Set-Content -LiteralPath $marker -Value ([string]$state.previousVersion) -Encoding UTF8}
    else{Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue}
    [pscustomobject][ordered]@{success=$true;skipped=$false;message='Rollback OK';data=$null}
}
'@

function New-KIOpenWebUIUpdateFixture {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$FixtureRoot,
        [Parameter(Mandatory)][string]$CurrentVersion,
        [Parameter(Mandatory)][string]$TargetVersion,
        [string]$HealthFlag='healthy',
        [switch]$ForceInstallFail
    )
    $targetRoot=Join-Path $FixtureRoot 'target'
    $installerRoot=Join-Path $targetRoot 'installer/complete'
    New-Item -ItemType Directory -Path $installerRoot -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Destination $installerRoot -Force

    $cutoverRuntimeSource=[IO.Path]::GetFullPath((Join-Path $PackageRoot '../../cutover-runtime/current'))
    if(-not(Test-Path -LiteralPath $cutoverRuntimeSource -PathType Container)){throw "cutover-runtime-Quelle nicht gefunden: $cutoverRuntimeSource"}
    $cutoverBuild=Join-Path $FixtureRoot 'cutover-build'
    if(Test-Path -LiteralPath $cutoverBuild){Remove-Item -LiteralPath $cutoverBuild -Recurse -Force}
    New-Item -ItemType Directory -Path (Join-Path $cutoverBuild 'CutoverRuntime/Core'),(Join-Path $cutoverBuild 'CutoverRuntime/Modules/06-Applications'),(Join-Path $cutoverBuild 'CutoverRuntime/Config') -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $cutoverRuntimeSource 'Core/KIStack.BuilderKernel.Core.psm1') -Destination (Join-Path $cutoverBuild 'CutoverRuntime/Core') -Force
    Copy-Item -LiteralPath (Join-Path $cutoverRuntimeSource 'Modules/06-Applications/module.json') -Destination (Join-Path $cutoverBuild 'CutoverRuntime/Modules/06-Applications') -Force
    Set-Content -LiteralPath (Join-Path $cutoverBuild 'CutoverRuntime/Modules/06-Applications/KIModuleApplications.psm1') -Value $fixtureFakeModuleContent -Encoding UTF8

    $venvRoot=Join-Path $targetRoot 'python/venvs/openwebui'
    $moduleRoot=Join-Path $targetRoot 'modules/applications'
    New-Item -ItemType Directory -Path $venvRoot,$moduleRoot -Force|Out-Null
    if($CurrentVersion){Set-Content -LiteralPath (Join-Path $venvRoot 'current-version.txt') -Value $CurrentVersion -Encoding UTF8}
    if($HealthFlag){Set-Content -LiteralPath (Join-Path $venvRoot 'health-flag.txt') -Value $HealthFlag -Encoding UTF8}
    if($ForceInstallFail){Set-Content -LiteralPath (Join-Path $venvRoot 'FORCE_INSTALL_FAIL') -Value '1' -Encoding UTF8}
    Set-Content -LiteralPath (Join-Path $moduleRoot 'Stop-KIStack-Applications.ps1') -Value "param()`n" -Encoding UTF8
    [IO.File]::WriteAllText((Join-Path $moduleRoot 'Start-KIStack-OpenWebUI.cmd'),"@echo off`r`nexit /b 0`r`n",[Text.Encoding]::ASCII)

    $kernelConfig=[ordered]@{
        applications=[ordered]@{
            moduleRoot=$moduleRoot
            openWebUI=[ordered]@{version=$TargetVersion;venv=$venvRoot;url='http://127.0.0.1:0/fixture'}
        }
    }
    Set-Content -LiteralPath (Join-Path $cutoverBuild 'CutoverRuntime/Config/kernel-config.json') -Value ($kernelConfig|ConvertTo-Json -Depth 10) -Encoding UTF8

    $payloadDir=Join-Path $installerRoot 'Payload/CutoverRuntime'
    New-Item -ItemType Directory -Path $payloadDir -Force|Out-Null
    $zipPath=Join-Path $payloadDir 'CutoverRuntime.zip'
    Compress-Archive -Path (Join-Path $cutoverBuild 'CutoverRuntime') -DestinationPath $zipPath -Force
    $targetRoot
}

function Get-CurrentFixtureVersion { param([string]$TargetRoot) $p=Join-Path $TargetRoot 'python/venvs/openwebui/current-version.txt';if(Test-Path -LiteralPath $p -PathType Leaf){(Get-Content -LiteralPath $p -Raw).Trim()}else{$null} }

function Get-KIJsonFromMixedOutput {
    param([string[]]$Output)
    $text=($Output-join "`n")
    $match=[regex]::Match($text,'(?s)\{.*\}')
    if(-not$match.Success){return $null}
    try{$match.Value|ConvertFrom-Json}catch{$null}
}

$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}
$fixtureRootBase=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-OWUIUpdate-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $fixtureRootBase -Force|Out-Null

    # 1. Target version already installed -> clean Skip, no mutation.
    $skipRoot=New-KIOpenWebUIUpdateFixture -PackageRoot $PackageRoot -FixtureRoot (Join-Path $fixtureRootBase 'skip') -CurrentVersion '0.11.0' -TargetVersion '0.11.0'
    $skipOutput=& pwsh.exe -NoLogo -NoProfile -File (Join-Path $PackageRoot 'Lifecycle/Update-KIStack-OpenWebUI.ps1') -TargetRoot $skipRoot 2>&1
    $skipExit=$LASTEXITCODE
    $skipJson=Get-KIJsonFromMixedOutput $skipOutput
    $checks.skip=[ordered]@{exitCodeZero=$skipExit-eq0;statusSkip=$skipJson.status-eq'Skip';versionUnchanged=(Get-CurrentFixtureVersion $skipRoot)-eq'0.11.0'}
    if($checks.skip.Values-contains$false){$fail.Add('Scenario Skip failed: '+($skipJson|ConvertTo-Json -Compress))}

    # 2. Successful upgrade.
    $upgradeRoot=New-KIOpenWebUIUpdateFixture -PackageRoot $PackageRoot -FixtureRoot (Join-Path $fixtureRootBase 'upgrade') -CurrentVersion '0.10.2' -TargetVersion '0.11.0'
    $upgradeOutput=& pwsh.exe -NoLogo -NoProfile -File (Join-Path $PackageRoot 'Lifecycle/Update-KIStack-OpenWebUI.ps1') -TargetRoot $upgradeRoot 2>&1
    $upgradeExit=$LASTEXITCODE
    $upgradeJson=Get-KIJsonFromMixedOutput $upgradeOutput
    $checks.upgrade=[ordered]@{exitCodeZero=$upgradeExit-eq0;statusCompleted=$upgradeJson.status-eq'Completed';versionUpdated=(Get-CurrentFixtureVersion $upgradeRoot)-eq'0.11.0';healthcheckPassed=[bool]$upgradeJson.healthcheckPassed}
    if($checks.upgrade.Values-contains$false){$fail.Add('Scenario Upgrade failed: '+($upgradeJson|ConvertTo-Json -Compress))}

    # 3. Successful downgrade -- same contract as upgrade.
    $downgradeRoot=New-KIOpenWebUIUpdateFixture -PackageRoot $PackageRoot -FixtureRoot (Join-Path $fixtureRootBase 'downgrade') -CurrentVersion '0.11.0' -TargetVersion '0.10.2'
    $downgradeOutput=& pwsh.exe -NoLogo -NoProfile -File (Join-Path $PackageRoot 'Lifecycle/Update-KIStack-OpenWebUI.ps1') -TargetRoot $downgradeRoot 2>&1
    $downgradeExit=$LASTEXITCODE
    $downgradeJson=Get-KIJsonFromMixedOutput $downgradeOutput
    $checks.downgrade=[ordered]@{exitCodeZero=$downgradeExit-eq0;statusCompleted=$downgradeJson.status-eq'Completed';versionUpdated=(Get-CurrentFixtureVersion $downgradeRoot)-eq'0.10.2'}
    if($checks.downgrade.Values-contains$false){$fail.Add('Scenario Downgrade failed: '+($downgradeJson|ConvertTo-Json -Compress))}

    # 4. Install fails -> rollback restores previous version, error propagates, exit non-zero.
    $installFailRoot=New-KIOpenWebUIUpdateFixture -PackageRoot $PackageRoot -FixtureRoot (Join-Path $fixtureRootBase 'installfail') -CurrentVersion '0.10.2' -TargetVersion '0.11.0' -ForceInstallFail
    $installFailOutput=& pwsh.exe -NoLogo -NoProfile -File (Join-Path $PackageRoot 'Lifecycle/Update-KIStack-OpenWebUI.ps1') -TargetRoot $installFailRoot 2>&1
    $installFailExit=$LASTEXITCODE
    $installFailJson=Get-KIJsonFromMixedOutput $installFailOutput
    $checks.installFailRollback=[ordered]@{
        exitCodeNonZero=$installFailExit-ne0
        statusFailed=$null-ne$installFailJson-and$installFailJson.status-eq'Failed'
        versionRestored=(Get-CurrentFixtureVersion $installFailRoot)-eq'0.10.2'
        errorPropagated=($installFailOutput-join"`n")-match'Simulierter Installationsfehler|Update fehlgeschlagen'
    }
    if($checks.installFailRollback.Values-contains$false){$fail.Add('Scenario InstallFail-Rollback failed: '+(($installFailOutput-join ' | ')))}

    # 5. Install succeeds but healthcheck fails -> rollback restores previous version.
    $healthFailRoot=New-KIOpenWebUIUpdateFixture -PackageRoot $PackageRoot -FixtureRoot (Join-Path $fixtureRootBase 'healthfail') -CurrentVersion '0.10.2' -TargetVersion '0.11.0' -HealthFlag 'unhealthy'
    $healthFailOutput=& pwsh.exe -NoLogo -NoProfile -File (Join-Path $PackageRoot 'Lifecycle/Update-KIStack-OpenWebUI.ps1') -TargetRoot $healthFailRoot 2>&1
    $healthFailExit=$LASTEXITCODE
    $healthFailJson=Get-KIJsonFromMixedOutput $healthFailOutput
    $checks.healthFailRollback=[ordered]@{
        exitCodeNonZero=$healthFailExit-ne0
        statusFailed=$null-ne$healthFailJson-and$healthFailJson.status-eq'Failed'
        versionRestored=(Get-CurrentFixtureVersion $healthFailRoot)-eq'0.10.2'
        errorPropagated=($healthFailOutput-join"`n")-match'Healthcheck nach Update fehlgeschlagen'
    }
    if($checks.healthFailRollback.Values-contains$false){$fail.Add('Scenario HealthFail-Rollback failed: '+(($healthFailOutput-join ' | ')))}

    $passed=$fail.Count-eq0
    [pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
    if(-not$passed){throw 'OpenWebUI-Managed-Update-Regression fehlgeschlagen.'}
}
finally{if(Test-Path $fixtureRootBase){Remove-Item -LiteralPath $fixtureRootBase -Recurse -Force}}

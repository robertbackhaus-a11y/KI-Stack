[CmdletBinding()]
param(
    [string]$TargetRoot='C:\KI-Stack',
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw 'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}

$installerRoot=Join-Path $TargetRoot 'installer/complete'
$completeModulePath=Join-Path $installerRoot 'CompleteInstaller.psm1'
if(-not(Test-Path -LiteralPath $completeModulePath -PathType Leaf)){throw "Complete-Installer-Paket fehlt unter $installerRoot; verwaltetes OpenWebUI-Update ist nicht möglich."}
Import-Module $completeModulePath -Force

$transactionId='openwebui-update-'+([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))+'-'+([guid]::NewGuid().ToString('N').Substring(0,8))
$stateDirectory=Join-Path $TargetRoot ('state/openwebui-update/'+$transactionId)
New-Item -ItemType Directory -Path $stateDirectory -Force|Out-Null
if([string]::IsNullOrWhiteSpace($LogPath)){$LogPath=Join-Path $stateDirectory 'update.log.txt'}

$extract=Join-Path $stateDirectory 'CutoverRuntime'
$cutoverRoot=Expand-KICompletePayload -PackageRoot $installerRoot -PayloadName 'CutoverRuntime' -Destination $extract
Import-Module (Join-Path $cutoverRoot 'Core/KIStack.BuilderKernel.Core.psm1') -Force -Global
Import-Module (Join-Path $cutoverRoot 'Modules/06-Applications/KIModuleApplications.psm1') -Force -Global

$config=Read-KIJson -Path (Join-Path $cutoverRoot 'Config/kernel-config.json')
$targetVersion=[string]$config.applications.openWebUI.version
$moduleRoot=[string]$config.applications.moduleRoot
$openWebUIUrl=[string]$config.applications.openWebUI.url

$moduleDefinitions=Get-KIModuleDefinitions -ModuleDirectory (Join-Path $cutoverRoot 'Modules')
$applicationsModule=@($moduleDefinitions|Where-Object{[string]$_.id-eq'KIModuleApplications'})
if($applicationsModule.Count-ne1){throw "Applications-Moduldefinition nicht eindeutig gefunden: $($applicationsModule.Count)"}
$applicationsModule=$applicationsModule[0]

$context=[pscustomobject][ordered]@{
    Mode='Execute'
    Config=$config
    Report=$null
    VersionLock=$null
    Plan=$null
    Transaction=[pscustomobject]@{transactionId=$transactionId}
    TransactionDirectory=$stateDirectory
    LogPath=$LogPath
}

function Test-KIOpenWebUIHealthWithRetry {
    param([Parameter(Mandatory)][object]$Context,[Parameter(Mandatory)][string]$Url,[int]$MaxAttempts=15,[int]$IntervalSeconds=2)
    for($attempt=1;$attempt-le$MaxAttempts;$attempt++){
        if(Test-KIApplicationEndpoint -Uri $Url -Name 'OpenWebUI' -Context $Context){return $true}
        if($attempt-lt$MaxAttempts){Start-Sleep -Seconds $IntervalSeconds}
    }
    return $false
}

function Stop-KIOpenWebUIManaged {
    param([Parameter(Mandatory)][string]$ModuleRoot)
    $stopScript=Join-Path $ModuleRoot 'Stop-KIStack-Applications.ps1'
    if(Test-Path -LiteralPath $stopScript -PathType Leaf){
        & (Get-Command pwsh.exe).Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $stopScript|Out-Null
    }
}

function Start-KIOpenWebUIManaged {
    param([Parameter(Mandatory)][string]$ModuleRoot)
    $startScript=Join-Path $ModuleRoot 'Start-KIStack-OpenWebUI.cmd'
    if(-not(Test-Path -LiteralPath $startScript -PathType Leaf)){throw "OpenWebUI-Starter fehlt: $startScript"}
    Start-Process -FilePath $startScript -WindowStyle Minimized|Out-Null
}

$previousVersion=Get-KIOpenWebUIVersion -Context $context
$result=[ordered]@{
    transactionId=$transactionId
    targetVersion=$targetVersion
    previousVersion=$previousVersion
    status=$null
    installedVersion=$null
    healthcheckPassed=$null
    rollback=$null
}

if($previousVersion-eq$targetVersion){
    $result.status='Skip'
    $result.installedVersion=$previousVersion
    [pscustomobject]$result|ConvertTo-Json -Depth 10
    exit 0
}

try{
    $installOutcome=Invoke-KIModuleCommand -Module $applicationsModule -Command Install -Context $context
    Import-Module $applicationsModule.scriptPath -Force -Global
    if(-not[bool]$installOutcome.success){throw "Update fehlgeschlagen: $($installOutcome.message)"}
    $installedVersion=Get-KIOpenWebUIVersion -Context $context
    if($installedVersion-ne$targetVersion){throw "Versionsprüfung nach Update fehlgeschlagen: erwartet=$targetVersion; installiert=$installedVersion"}
    Stop-KIOpenWebUIManaged -ModuleRoot $moduleRoot
    Start-KIOpenWebUIManaged -ModuleRoot $moduleRoot
    $healthy=Test-KIOpenWebUIHealthWithRetry -Context $context -Url $openWebUIUrl
    if(-not$healthy){throw "OpenWebUI-Healthcheck nach Update fehlgeschlagen ($openWebUIUrl nicht erreichbar)."}
    $result.status='Completed'
    $result.installedVersion=$installedVersion
    $result.healthcheckPassed=$true
    [pscustomobject]$result|ConvertTo-Json -Depth 10
    exit 0
}
catch{
    $failure=$_
    $rollbackDetail=[ordered]@{attempted=$true;success=$false;restoredVersion=$null;expectedVersion=$previousVersion;versionRestored=$false;healthcheckPassed=$false;error=$null}
    try{
        Stop-KIOpenWebUIManaged -ModuleRoot $moduleRoot
        $rollbackOutcome=Invoke-KIModuleCommand -Module $applicationsModule -Command Rollback -Context $context
        Import-Module $applicationsModule.scriptPath -Force -Global
        $restoredVersion=Get-KIOpenWebUIVersion -Context $context
        Start-KIOpenWebUIManaged -ModuleRoot $moduleRoot
        $rollbackHealthy=Test-KIOpenWebUIHealthWithRetry -Context $context -Url $openWebUIUrl
        $rollbackDetail.success=[bool]$rollbackOutcome.success
        $rollbackDetail.restoredVersion=$restoredVersion
        $rollbackDetail.versionRestored=($restoredVersion-eq$previousVersion)
        $rollbackDetail.healthcheckPassed=$rollbackHealthy
    }catch{
        $rollbackDetail.error=$_.Exception.Message
    }
    $result.status='Failed'
    $result.rollback=$rollbackDetail
    [pscustomobject]$result|ConvertTo-Json -Depth 10
    throw $failure
}

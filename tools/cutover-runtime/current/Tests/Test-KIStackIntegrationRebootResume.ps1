[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $ProjectRoot 'Modules/07-Integration/KIModuleIntegration.psm1') -Force -PassThru -DisableNameChecking
try{
    $greenfield=Get-KIIntegrationDistributionActivationDisposition -DistributionActive $false -ExitCode 0 -Output 'Changes will not be effective until the system is rebooted.'
    $resume=Get-KIIntegrationDistributionActivationDisposition -DistributionActive $true -ExitCode 0 -Output ''
    $alreadyActive=Get-KIIntegrationDistributionActivationDisposition -DistributionActive $true -ExitCode 0 -Output ''
    $failure=Get-KIIntegrationDistributionActivationDisposition -DistributionActive $false -ExitCode 5 -Output 'Access denied.'
    $kernelPath=Join-Path $ProjectRoot 'Invoke-KIStackBuilderKernel.ps1'
    $kernel=Get-Content -LiteralPath $kernelPath -Raw
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($kernelPath,[ref]$tokens,[ref]$parseErrors)
    if(@($parseErrors).Count){throw ('Kernel parser errors: '+(@($parseErrors.Message)-join'; '))}
    $statusFunction=$ast.Find({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-eq'Get-KIInstallResultControlStatus'},$true)
    if($null-eq$statusFunction){throw 'Get-KIInstallResultControlStatus fehlt.'}
    . ([scriptblock]::Create($statusFunction.Extent.Text))
    $normalData=[pscustomobject]@{success=$true;data=[pscustomobject]@{detail='normal'}}
    $nullData=[pscustomobject]@{success=$true;data=$null}
    $rebootData=[pscustomobject]@{success=$true;data=[pscustomobject]@{status='RebootRequired'}}
    $waitingData=[pscustomobject]@{success=$true;data=[pscustomobject]@{status='WaitingForRestart'}}
    $normalStatus=Get-KIInstallResultControlStatus $normalData
    $nullStatus=Get-KIInstallResultControlStatus $nullData
    $rebootStatus=Get-KIInstallResultControlStatus $rebootData
    $waitingStatus=Get-KIInstallResultControlStatus $waitingData
    $passed=(
        $greenfield-eq'RebootRequired'-and
        $resume-eq'Active'-and
        $alreadyActive-eq'Active'-and
        $failure-eq'Failed'-and
        $null-eq$normalStatus-and
        $null-eq$nullStatus-and
        $rebootStatus-eq'RebootRequired'-and
        $waitingStatus-eq'WaitingForRestart'-and
        $kernel.Contains("`$moduleState.status = 'WaitingForRestart'")-and
        $kernel.Contains("exit 31")-and
        $kernel.Contains("@('Completed','Validated')")-and
        $kernel.Contains("@('Failed','WaitingForRestart')")
    )
    [pscustomobject][ordered]@{
        passed=$passed
        greenfield=$greenfield
        resumeAfterRestart=$resume
        wslAlreadyActive=$alreadyActive
        actualFailure=$failure
        normalDataWithoutStatus=if($null-eq$normalStatus){'ContinueToValidation'}else{$normalStatus}
        nullData=if($null-eq$nullStatus){'ContinueToValidation'}else{$nullStatus}
        rebootControlStatus=$rebootStatus
        waitingControlStatus=$waitingStatus
        completedModulesReused=$kernel.Contains("@('Completed','Validated')")
        rebootExitCode=31
        targetSystemAccessed=$false
    }|ConvertTo-Json -Depth 10
    if(-not$passed){throw 'Integration-Reboot-/Resume-Regression fehlgeschlagen.'}
}finally{
    if($module){Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue}
}

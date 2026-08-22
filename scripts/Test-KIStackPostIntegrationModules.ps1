#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CutoverRoot,
    [Parameter(Mandatory)][string]$SourceTransactionPath,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [Parameter(Mandatory)][ValidateSet('POST_INTEGRATION_TEST')][string]$ExecutionConfirmation,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$CutoverRoot=(Resolve-Path -LiteralPath $CutoverRoot).Path
$SourceTransactionPath=(Resolve-Path -LiteralPath $SourceTransactionPath).Path
$EvidenceDirectory=[IO.Path]::GetFullPath($EvidenceDirectory)
$sourceHashBefore=(Get-FileHash -LiteralPath $SourceTransactionPath -Algorithm SHA256).Hash
$corePath=Join-Path $CutoverRoot 'Core\KIStack.BuilderKernel.Core.psm1'
$configPath=Join-Path $CutoverRoot 'Config\kernel-config.json'
$moduleRoot=Join-Path $CutoverRoot 'Modules'
foreach($required in @($corePath,$configPath,$moduleRoot)){if(-not(Test-Path -LiteralPath $required)){throw "Erforderliche Cutover-Quelle fehlt: $required"}}

Import-Module $corePath -Force -ErrorAction Stop
$sourceTransaction=Read-KIJson -Path $SourceTransactionPath
$integrationState=@($sourceTransaction.modules|Where-Object{[string]$_.id-eq'KIModuleIntegration'})
if($integrationState.Count-ne1-or[string]$integrationState[0].status-ne'Failed'){
    throw 'Der Harness erfordert genau einen unverändert fehlgeschlagenen KIModuleIntegration-Status.'
}

$modules=Get-KIModuleDefinitions -ModuleDirectory $moduleRoot
$integrationDefinition=@($modules|Where-Object id -eq 'KIModuleIntegration')|Select-Object -First 1
$following=@($modules|Where-Object{$_.enabled-and$_.order-gt$integrationDefinition.order}|Sort-Object order,id)
$expected=@('KIModuleCutover','KIModuleValidation')
if(@(Compare-Object $expected @($following.id) -SyncWindow 0).Count){throw ('Unerwartete Modulfolge nach Integration: '+(@($following.id)-join', '))}

New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
$transaction=$sourceTransaction|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100
$transaction.transactionId=([string]$sourceTransaction.transactionId)+'-post-integration-test-'+(Get-Date -Format 'yyyyMMdd-HHmmss')
$transaction.status='PostIntegrationTest'
$config=Read-KIJson -Path $configPath
$config.validation.latestReportPath=Join-Path $EvidenceDirectory 'validation-latest.json'
$context=[pscustomobject][ordered]@{
    Mode=if($Execute){'Execute'}else{'DryRun'}
    Config=$config
    Report=$null
    VersionLock=$null
    Plan=$null
    Transaction=$transaction
    TransactionDirectory=$EvidenceDirectory
    LogPath=Join-Path $EvidenceDirectory 'post-integration.log.jsonl'
    Module=$null
    ModuleResult=$null
}

$results=[Collections.Generic.List[object]]::new()
foreach($module in $following){
    $context.Module=$module
    $testResult=Invoke-KIModuleCommand -Module $module -Command Test -Context $context
    if(-not[bool]$testResult.success){throw "Test für $($module.id) fehlgeschlagen: $($testResult.message)"}
    $installResult=$null;$validationResult=$null
    try{
        $installResult=Invoke-KIModuleCommand -Module $module -Command Install -Context $context
        if(-not[bool]$installResult.success){throw "Install für $($module.id) fehlgeschlagen: $($installResult.message)"}
        $context.ModuleResult=$installResult
        $moduleState=@($transaction.modules|Where-Object{[string]$_.id-eq[string]$module.id})|Select-Object -First 1
        if($module.id-eq'KIModuleCutover'){$moduleState.status='Validated'}
        $validationResult=Invoke-KIModuleCommand -Module $module -Command Validate -Context $context
        if($module.id-eq'KIModuleCutover'-and-not[bool]$validationResult.success){throw "Validate für $($module.id) fehlgeschlagen: $($validationResult.message)"}
        $results.Add([pscustomobject][ordered]@{id=$module.id;test=$testResult;install=$installResult;validation=$validationResult})|Out-Null
    }catch{
        if($Execute-and$module.supportsRollback-and$null-ne$installResult){
            try{$context.ModuleResult=$installResult;$rollback=Invoke-KIModuleCommand -Module $module -Command Rollback -Context $context}catch{$rollback=[pscustomobject]@{success=$false;message=$_.Exception.Message}}
            $_.Exception.Data['PostIntegrationRollback']=$rollback
        }
        throw
    }
}

$validationResult=@($results|Where-Object id -eq 'KIModuleValidation'|Select-Object -First 1).validation
$truthfulIntegrationFailure=(
    -not[bool]$validationResult.success-and
    @($validationResult.data.failedModuleIds).Count-eq1-and
    [string]$validationResult.data.failedModuleIds[0]-eq'KIModuleIntegration'
)
if(-not$truthfulIntegrationFailure){throw 'Abschlussvalidation hat den realen Integration-Fehler nicht eindeutig erhalten.'}
$sourceHashAfter=(Get-FileHash -LiteralPath $SourceTransactionPath -Algorithm SHA256).Hash
if($sourceHashAfter-ne$sourceHashBefore){throw 'Die bestehende fehlgeschlagene Transaktion wurde verändert.'}

$report=[pscustomobject][ordered]@{
    schemaVersion='1.0'
    passed=$true
    mode=$context.Mode
    sourceTransactionPath=$SourceTransactionPath
    sourceTransactionSha256=$sourceHashAfter.ToLowerInvariant()
    sourceIntegrationStatus='Failed'
    sourceTransactionUnchanged=$true
    moduleOrder=@($following.id)
    results=@($results)
    validationExpectedlyRejectedFor=@('KIModuleIntegration')
    productInstallerModified=$false
}
$reportPath=Join-Path $EvidenceDirectory 'post-integration-result.json'
[IO.File]::WriteAllText($reportPath,($report|ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($false))
$report

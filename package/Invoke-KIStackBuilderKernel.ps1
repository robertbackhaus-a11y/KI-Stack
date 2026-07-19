#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PreflightPath,
    [ValidateSet('DryRun','Execute')][string]$Mode = 'DryRun',
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Config\kernel-config.json'),
    [string]$StateDirectory = (Join-Path $PSScriptRoot 'State'),
    [string]$TransactionId,
    [switch]$Resume,
    [switch]$RollbackOnFailure,
    [string]$ExecutionConfirmation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Core\KIStack.BuilderKernel.Core.psm1') `
    -Force -ErrorAction Stop

$config = Read-KIJson -Path $ConfigPath

if ($Mode -eq 'Execute') {
    if (-not [bool]$config.defaults.requireAdministratorForExecute) {
        throw 'Ungültige Kernel-Konfiguration für Execute.'
    }
    if (-not (Test-KIAdministrator)) {
        throw 'Execute erfordert Administratorrechte.'
    }

    $requiredToken = [string]$config.executeRelease.confirmationToken
    if (-not $requiredToken -or $ExecutionConfirmation -cne $requiredToken) {
        throw 'Execute wurde nicht mit dem erforderlichen Bestätigungstoken freigegeben.'
    }

    if ([bool]$config.defaults.allowDestructiveActions) {
        throw 'Destruktive Aktionen dürfen für diese Freigabe nicht aktiviert sein.'
    }
}

if (-not $TransactionId) {
    $TransactionId = 'KI-STACK-TX-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
}

$transactionDirectory = Join-Path $StateDirectory $TransactionId
$transactionPath = Join-Path $transactionDirectory 'transaction.json'
$logPath = Join-Path $transactionDirectory 'transaction.log.jsonl'
$inputDirectory = Join-Path $transactionDirectory 'input'

if (-not (Test-Path -LiteralPath $transactionDirectory)) {
    New-Item -ItemType Directory -Path $transactionDirectory -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $inputDirectory)) {
    New-Item -ItemType Directory -Path $inputDirectory -Force | Out-Null
}

if ($Resume) {
    if (-not (Test-Path -LiteralPath $transactionPath)) {
        throw 'Resume angefordert, aber transaction.json wurde nicht gefunden.'
    }

    $transaction = Read-KIJson -Path $transactionPath
    if ($transaction.status -eq 'Completed') {
        throw 'Die Transaktion ist bereits abgeschlossen.'
    }

    $reportPath = [string]$transaction.input.reportCopyPath
    $lockPath = [string]$transaction.input.lockCopyPath
    $planPath = [string]$transaction.input.planCopyPath
}
else {
    if (Test-Path -LiteralPath $transactionPath) {
        throw 'Transaktions-ID existiert bereits. Resume verwenden oder neue ID wählen.'
    }

    $workingDirectory = Join-Path $transactionDirectory 'working'
    New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null

    $resolvedInput = Resolve-KIPreflightInput `
        -InputPath $PreflightPath `
        -WorkingDirectory $workingDirectory

    $reportPath = Join-Path $inputDirectory 'preflight-report.json'
    $lockPath = Join-Path $inputDirectory 'versions.lock.json'
    $planPath = Join-Path $inputDirectory 'install-plan.source.json'

    Copy-Item -LiteralPath $resolvedInput.reportPath -Destination $reportPath -Force
    Copy-Item -LiteralPath $resolvedInput.lockPath -Destination $lockPath -Force
    Copy-Item -LiteralPath $resolvedInput.planPath -Destination $planPath -Force

    $report = Read-KIJson -Path $reportPath
    $versionLock = Read-KIJson -Path $lockPath
    $plan = Read-KIJson -Path $planPath

    $inputValidation = Test-KIKernelInput `
        -Report $report `
        -VersionLock $versionLock `
        -Plan $plan `
        -Config $config

    if (-not $inputValidation.valid) {
        throw ('Kernel-Eingabe ungültig: {0}' -f ($inputValidation.issues -join ' | '))
    }

    $modules = Get-KIModuleDefinitions -ModuleDirectory (Join-Path $PSScriptRoot 'Modules')
    $graphValidation = Test-KIModuleGraph -Modules $modules

    if (-not $graphValidation.valid) {
        throw ('Modulgraph ungültig: {0}' -f ($graphValidation.issues -join ' | '))
    }

    $inputState = [pscustomobject][ordered]@{
        originalPath = (Resolve-Path -LiteralPath $PreflightPath).Path
        reportCopyPath = $reportPath
        reportSha256 = Get-KISha256 -Path $reportPath
        lockCopyPath = $lockPath
        lockSha256 = Get-KISha256 -Path $lockPath
        planCopyPath = $planPath
        planSha256 = Get-KISha256 -Path $planPath
        reportId = $report.reportId
        lockId = $versionLock.lockId
        planId = $plan.planId
    }

    $transaction = New-KITransaction `
        -TransactionId $TransactionId `
        -Mode $Mode `
        -InputState $inputState `
        -Modules $modules

    Add-KITransactionEvent `
        -Transaction $transaction `
        -Type 'Initialized' `
        -Message 'Transaktion initialisiert.'

    Write-KIJson -Value $transaction -Path $transactionPath
}

$report = Read-KIJson -Path $reportPath
$versionLock = Read-KIJson -Path $lockPath
$plan = Read-KIJson -Path $planPath

if ((Get-KISha256 -Path $reportPath) -ne [string]$transaction.input.reportSha256) {
    throw 'Prüfsumme des Preflight-Berichts stimmt nicht mehr.'
}
if ((Get-KISha256 -Path $lockPath) -ne [string]$transaction.input.lockSha256) {
    throw 'Prüfsumme des Versions-Locks stimmt nicht mehr.'
}
if ((Get-KISha256 -Path $planPath) -ne [string]$transaction.input.planSha256) {
    throw 'Prüfsumme des Installationsplans stimmt nicht mehr.'
}

$modules = Get-KIModuleDefinitions -ModuleDirectory (Join-Path $PSScriptRoot 'Modules')

if ($Mode -eq 'Execute') {
    $enabledModuleIds = @($modules | Where-Object enabled | ForEach-Object id)
    $approvedModuleIds = @($config.executeRelease.enabledModules)

    $unapprovedModuleIds = @(
        $enabledModuleIds |
        Where-Object { $approvedModuleIds -notcontains [string]$_ }
    )
    $missingApprovedModuleIds = @(
        $approvedModuleIds |
        Where-Object { $enabledModuleIds -notcontains [string]$_ }
    )

    if ($unapprovedModuleIds.Count -gt 0) {
        throw ('Nicht freigegebene Execute-Module aktiv: {0}' -f ($unapprovedModuleIds -join ', '))
    }
    if ($missingApprovedModuleIds.Count -gt 0) {
        throw ('Freigegebene Execute-Module fehlen: {0}' -f ($missingApprovedModuleIds -join ', '))
    }
}

$transaction.status = 'Running'
$transaction.updatedAt = (Get-Date).ToString('o')
Write-KIJson -Value $transaction -Path $transactionPath

$contextBase = [pscustomobject][ordered]@{
    Mode = $Mode
    Config = $config
    Report = $report
    VersionLock = $versionLock
    Plan = $plan
    Transaction = $transaction
    TransactionDirectory = $transactionDirectory
    LogPath = $logPath
}

$failureDetected = $false

foreach ($module in $modules) {
    if (-not $module.enabled) { continue }

    $moduleStateMatches = @(
        $transaction.modules |
        Where-Object { [string]$_.id -eq [string]$module.id }
    )

    if ($moduleStateMatches.Count -ne 1) {
        throw ("Transaktionsstatus für Modul '{0}' wurde nicht eindeutig gefunden. Treffer: {1}." -f
            $module.id,
            $moduleStateMatches.Count
        )
    }

    $moduleState = $moduleStateMatches[0]

    if ($moduleState.status -in @('Completed','Validated')) {
        continue
    }

    foreach ($dependency in @($module.dependencies)) {
        $dependencyStateMatches = @(
            $transaction.modules |
            Where-Object { [string]$_.id -eq [string]$dependency }
        )

        if ($dependencyStateMatches.Count -ne 1) {
            throw ("Transaktionsstatus für Abhängigkeit '{0}' von Modul '{1}' wurde nicht eindeutig gefunden. Treffer: {2}." -f
                $dependency,
                $module.id,
                $dependencyStateMatches.Count
            )
        }

        $dependencyState = $dependencyStateMatches[0]

        if ($dependencyState.status -notin @('Completed','Validated')) {
            throw "Abhängigkeit '$dependency' für '$($module.id)' ist nicht abgeschlossen."
        }
    }

    $transaction.currentModuleId = $module.id
    $moduleState.status = 'Running'
    $moduleState.attempts = [int]$moduleState.attempts + 1
    $moduleState.startedAt = (Get-Date).ToString('o')
    $transaction.updatedAt = (Get-Date).ToString('o')
    Write-KIJson -Value $transaction -Path $transactionPath

    Write-KILog -LogPath $logPath -Entry (
        New-KILogEntry -Level 'Info' -Component $module.id `
            -Message 'Modulausführung gestartet.'
    )

    try {
        $context = [pscustomobject][ordered]@{
            Mode = $contextBase.Mode
            Config = $contextBase.Config
            Report = $contextBase.Report
            VersionLock = $contextBase.VersionLock
            Plan = $contextBase.Plan
            Transaction = $transaction
            TransactionDirectory = $transactionDirectory
            LogPath = $logPath
            Module = $module
            ModuleResult = $moduleState.result
        }

        $testResult = Invoke-KIModuleCommand `
            -Module $module -Command Test -Context $context
        if (-not [bool]$testResult.success) {
            throw "Modultest fehlgeschlagen: $($testResult.message)"
        }

        $installResult = Invoke-KIModuleCommand `
            -Module $module -Command Install -Context $context
        if (-not [bool]$installResult.success) {
            throw "Modulinstallation fehlgeschlagen: $($installResult.message)"
        }

        $moduleState.result = $installResult
        $context.ModuleResult = $installResult

        $validationResult = Invoke-KIModuleCommand `
            -Module $module -Command Validate -Context $context
        if (-not [bool]$validationResult.success) {
            throw "Modulvalidierung fehlgeschlagen: $($validationResult.message)"
        }

        $moduleState.status = 'Validated'
        $moduleState.completedAt = (Get-Date).ToString('o')
        $moduleState.error = $null

        Add-KITransactionEvent `
            -Transaction $transaction `
            -Type 'ModuleValidated' `
            -Message ("Modul abgeschlossen: {0}" -f $module.id)

        Write-KILog -LogPath $logPath -Entry (
            New-KILogEntry -Level 'Info' -Component $module.id `
                -Message 'Modul erfolgreich validiert.' `
                -Data $validationResult
        )
    }
    catch {
        $failureDetected = $true
        $moduleState.status = 'Failed'
        $moduleState.completedAt = (Get-Date).ToString('o')
        $moduleState.error = $_.Exception.Message

        Add-KITransactionEvent `
            -Transaction $transaction `
            -Type 'ModuleFailed' `
            -Message ("Modul fehlgeschlagen: {0}" -f $module.id) `
            -Data $_.Exception.Message

        $errorData = [pscustomobject][ordered]@{
            exceptionType = $_.Exception.GetType().FullName
            message = $_.Exception.Message
            scriptStackTrace = $_.ScriptStackTrace
            positionMessage = $_.InvocationInfo.PositionMessage
            fullyQualifiedErrorId = $_.FullyQualifiedErrorId
        }

        Write-KILog -LogPath $logPath -Entry (
            New-KILogEntry -Level 'Error' -Component $module.id `
                -Message $_.Exception.Message `
                -Data $errorData
        )

        Write-KIJson -Value $transaction -Path $transactionPath

        if ($RollbackOnFailure -and $module.supportsRollback) {
            try {
                $context.ModuleResult = $moduleState.result
                $rollbackResult = Invoke-KIModuleCommand `
                    -Module $module -Command Rollback -Context $context

                $moduleState.rollbackStatus = if ([bool]$rollbackResult.success) {
                    'Completed'
                } else {
                    'Failed'
                }

                if ([bool]$rollbackResult.success) {
                    $rollbackLogLevel = 'Info'
                }
                else {
                    $rollbackLogLevel = 'Error'
                }

                Write-KILog -LogPath $logPath -Entry (
                    New-KILogEntry -Level $rollbackLogLevel `
                        -Component $module.id `
                        -Message ([string]$rollbackResult.message) `
                        -Data $rollbackResult
                )
            }
            catch {
                $moduleState.rollbackStatus = 'Failed'
                Write-KILog -LogPath $logPath -Entry (
                    New-KILogEntry -Level 'Error' -Component $module.id `
                        -Message ("Rollback fehlgeschlagen: {0}" -f $_.Exception.Message)
                )
            }
        }

        break
    }
    finally {
        $transaction.updatedAt = (Get-Date).ToString('o')
        Write-KIJson -Value $transaction -Path $transactionPath
    }
}

$transaction.currentModuleId = $null
$transaction.status = if ($failureDetected) { 'Failed' } else { 'Completed' }
$transaction.updatedAt = (Get-Date).ToString('o')

Add-KITransactionEvent `
    -Transaction $transaction `
    -Type $transaction.status `
    -Message ("Transaktion beendet: {0}" -f $transaction.status)

Write-KIJson -Value $transaction -Path $transactionPath

$resultPath = Join-Path $transactionDirectory 'kernel-result.json'
$result = [pscustomobject][ordered]@{
    schemaVersion = '1.0'
    transactionId = $transaction.transactionId
    mode = $transaction.mode
    status = $transaction.status
    completedAt = $transaction.updatedAt
    resumeAvailable = ($transaction.status -eq 'Failed')
    transactionPath = $transactionPath
    logPath = $logPath
    modules = @($transaction.modules)
}
Write-KIJson -Value $result -Path $resultPath

Write-Host ''
Write-Host ("Transaktion: {0}" -f $transaction.transactionId) -ForegroundColor Cyan
Write-Host ("Modus: {0}" -f $transaction.mode)
Write-Host ("Status: {0}" -f $transaction.status)
Write-Host ("State: {0}" -f $transactionPath)
Write-Host ("Log: {0}" -f $logPath)
Write-Host ''

if ($failureDetected) { exit 30 }
exit 0

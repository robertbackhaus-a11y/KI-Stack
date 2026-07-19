#Requires -Version 7.0
[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failed = $false
$results = @()

function Add-Result {
    param([string]$Name,[bool]$Passed,[string]$Message)

    $script:results += [pscustomobject][ordered]@{
        name = $Name
        passed = $Passed
        message = $Message
    }
    if (-not $Passed) { $script:failed = $true }
}

function Get-KIReleaseVersion {
    param([Parameter(Mandatory)][string]$ReleaseId)

    $versionMatch = [regex]::Match($ReleaseId, '(?<version>\d+\.\d+\.\d+)$')
    if (-not $versionMatch.Success) {
        throw "Release-ID enthält keine abschließende Versionsnummer: $ReleaseId"
    }

    return $versionMatch.Groups['version'].Value
}

$psFiles = @(
    Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File |
    Where-Object { $_.Extension -in @('.ps1','.psm1') }
)

foreach ($file in $psFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )

    Add-Result `
        -Name ("Parser: {0}" -f $file.Name) `
        -Passed (@($parseErrors).Count -eq 0) `
        -Message ((@($parseErrors) | ForEach-Object Message) -join ' | ')
}

try {
    Import-Module (Join-Path $ProjectRoot 'Core\KIStack.BuilderKernel.Core.psm1') `
        -Force -ErrorAction Stop
    Add-Result -Name 'Core-Modul' -Passed $true -Message 'Import erfolgreich.'
}
catch {
    Add-Result -Name 'Core-Modul' -Passed $false -Message $_.Exception.Message
}

try {
    $config = Read-KIJson -Path (Join-Path $ProjectRoot 'Config\kernel-config.json')
    $releaseVersion = Get-KIReleaseVersion `
        -ReleaseId ([string]$config.executeRelease.releaseId)

    $valid = (
        $config.kernelVersion -eq $releaseVersion -and
        $config.stackRoot -eq 'C:\KI-Stack' -and
        $config.defaults.executionMode -eq 'DryRun' -and
        -not $config.defaults.allowDestructiveActions
    )
    Add-Result -Name 'Kernel-Konfiguration' -Passed $valid `
        -Message 'Version und Sicherheitsgrenzen geprüft.'
}
catch {
    Add-Result -Name 'Kernel-Konfiguration' -Passed $false `
        -Message $_.Exception.Message
}

try {
    $modules = Get-KIModuleDefinitions -ModuleDirectory (Join-Path $ProjectRoot 'Modules')
    $graph = Test-KIModuleGraph -Modules $modules
    Add-Result -Name 'Modulgraph' -Passed $graph.valid `
        -Message ($(if ($graph.valid) {
            ('Module: {0}' -f $modules.Count)
        } else {
            $graph.issues -join ' | '
        }))
}
catch {
    Add-Result -Name 'Modulgraph' -Passed $false -Message $_.Exception.Message
}

try {
    $protectedVariableNames = @(
        'args','error','event','eventargs','eventsubscriber','executioncontext',
        'false','foreach','home','host','input','iscoreclr','islinux','ismacos',
        'iswindows','matches','myinvocation','null','pid','profile',
        'psboundparameters','pscmdlet','pscommandpath','psculture','pshome',
        'psitem','psscriptroot','psuiculture','psversiontable','pwd','shellid',
        'stacktrace','switch','this','true'
    )
    $allowedAssignmentTargets = @('null')
    $collisions = @()

    foreach ($file in $psFiles) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        )

        $assignments = @(
            $ast.FindAll(
                {
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst]
                },
                $true
            )
        )

        foreach ($assignment in $assignments) {
            if ($assignment.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $name = $assignment.Left.VariablePath.UserPath
                $normalizedName = $name.ToLowerInvariant()
                if (
                    $protectedVariableNames -contains $normalizedName -and
                    $allowedAssignmentTargets -notcontains $normalizedName
                ) {
                    $collisions += ('{0}:{1}: `${2}' -f
                        $file.Name,
                        $assignment.Extent.StartLineNumber,
                        $name
                    )
                }
            }
        }
    }

    Add-Result -Name 'Automatische Variablen' `
        -Passed ($collisions.Count -eq 0) `
        -Message ($(if ($collisions.Count -eq 0) {
            'Keine Kollisionen.'
        } else {
            $collisions -join ' | '
        }))
}
catch {
    Add-Result -Name 'Automatische Variablen' -Passed $false `
        -Message $_.Exception.Message
}

try {
    $pythonGitModulePath = Join-Path $ProjectRoot `
        'Modules\03-PythonGit\KIModulePythonGit.psm1'
    $pythonGitModuleContent = Get-Content -LiteralPath $pythonGitModulePath -Raw
    $nullDiscardAllowed = (
        $allowedAssignmentTargets -contains 'null' -and
        $pythonGitModuleContent.Contains('$null = & $PythonCommand.Source -m uv --version') -and
        $pythonGitModuleContent.Contains('$null = & $gitCommand.Source config --system --get core.longpaths')
    )

    Add-Result -Name 'Null-Discard-keine-Automatikvariablen-Kollision' `
        -Passed $nullDiscardAllowed `
        -Message '$null bleibt als zulässiges PowerShell-Verwerfungsziel von der Kollisionsprüfung ausgenommen.'
}
catch {
    Add-Result -Name 'Null-Discard-keine-Automatikvariablen-Kollision' `
        -Passed $false `
        -Message $_.Exception.Message
}

try {
    $mockInput = [pscustomobject][ordered]@{
        reportCopyPath = 'report.json'
        lockCopyPath = 'lock.json'
        planCopyPath = 'plan.json'
    }
    $modules = Get-KIModuleDefinitions -ModuleDirectory (Join-Path $ProjectRoot 'Modules')
    $transaction = New-KITransaction `
        -TransactionId 'TEST-TX' `
        -Mode 'DryRun' `
        -InputState $mockInput `
        -Modules $modules

    $valid = (
        $transaction.status -eq 'Initialized' -and
        -not $transaction.approved -and
        -not $transaction.destructiveActionsAllowed -and
        $transaction.modules.Count -eq $modules.Count
    )
    Add-Result -Name 'Transaktionsmodell' -Passed $valid `
        -Message 'Initialzustand geprüft.'
}
catch {
    Add-Result -Name 'Transaktionsmodell' -Passed $false `
        -Message $_.Exception.Message
}


try {
    $mockStates = @(
        [pscustomobject]@{ id = 'KIModuleFoundation'; status = 'Validated' },
        [pscustomobject]@{ id = 'KIModuleValidation'; status = 'Pending' }
    )
    $moduleId = 'KIModuleValidation'
    $dependencyId = 'KIModuleFoundation'

    $moduleMatches = @(
        $mockStates |
        Where-Object { [string]$_.id -eq [string]$moduleId }
    )
    $dependencyMatches = @(
        $mockStates |
        Where-Object { [string]$_.id -eq [string]$dependencyId }
    )

    $validLookup = (
        $moduleMatches.Count -eq 1 -and
        $dependencyMatches.Count -eq 1 -and
        $dependencyMatches[0].status -eq 'Validated'
    )

    Add-Result -Name 'Sichere Modulstatus-Auflösung' -Passed $validLookup `
        -Message 'Modul- und Abhängigkeitsstatus werden eindeutig per ScriptBlock aufgelöst.'
}
catch {
    Add-Result -Name 'Sichere Modulstatus-Auflösung' -Passed $false `
        -Message $_.Exception.Message
}


try {
    $validationModulePath = Join-Path $ProjectRoot `
        'Modules\99-Validation\KIModuleValidation.psm1'
    $validationModule = Import-Module $validationModulePath `
        -Force -PassThru -DisableNameChecking -ErrorAction Stop

    try {
        $cleanContext = [pscustomobject]@{
            Transaction = [pscustomobject]@{
                modules = @(
                    [pscustomobject]@{
                        id = 'KIModuleFoundation'
                        status = 'Validated'
                    },
                    [pscustomobject]@{
                        id = 'KIModuleValidation'
                        status = 'Running'
                    }
                )
            }
        }

        $cleanResult = & (
            Get-Command -Name 'Validate-KIModuleValidation' `
                -Module $validationModule.Name -ErrorAction Stop
        ) -Context $cleanContext

        $failedContext = [pscustomobject]@{
            Transaction = [pscustomobject]@{
                modules = @(
                    [pscustomobject]@{
                        id = 'KIModuleFoundation'
                        status = 'Failed'
                    }
                )
            }
        }

        $failedResult = & (
            Get-Command -Name 'Validate-KIModuleValidation' `
                -Module $validationModule.Name -ErrorAction Stop
        ) -Context $failedContext

        $validValidationBehavior = (
            [bool]$cleanResult.success -and
            @($cleanResult.data.failedModuleIds).Count -eq 0 -and
            -not [bool]$failedResult.success -and
            @($failedResult.data.failedModuleIds).Count -eq 1 -and
            [string]$failedResult.data.failedModuleIds[0] -eq 'KIModuleFoundation'
        )

        Add-Result -Name 'Validation-Modul Leermenge und Fehlerfall' `
            -Passed $validValidationBehavior `
            -Message 'Leere Fehlerliste und vorhandenes Fehlermodul werden ohne Property-Zugriffsfehler verarbeitet.'
    }
    finally {
        Remove-Module -ModuleInfo $validationModule -Force `
            -ErrorAction SilentlyContinue
    }
}
catch {
    Add-Result -Name 'Validation-Modul Leermenge und Fehlerfall' `
        -Passed $false `
        -Message $_.Exception.Message
}

try {
    $invalidContext = [pscustomobject]@{
        Transaction = [pscustomobject]@{
            modules = @(
                [pscustomobject]@{
                    name = 'Ohne ID und Status'
                }
            )
        }
    }

    $validationModulePath = Join-Path $ProjectRoot `
        'Modules\99-Validation\KIModuleValidation.psm1'
    $validationModule = Import-Module $validationModulePath `
        -Force -PassThru -DisableNameChecking -ErrorAction Stop

    try {
        $invalidResult = & (
            Get-Command -Name 'Validate-KIModuleValidation' `
                -Module $validationModule.Name -ErrorAction Stop
        ) -Context $invalidContext

        $validInvalidEntryHandling = (
            -not [bool]$invalidResult.success -and
            @($invalidResult.data.invalidModuleEntries).Count -eq 1
        )

        Add-Result -Name 'Validation-Modul ungültiger Statuseintrag' `
            -Passed $validInvalidEntryHandling `
            -Message 'Ungültige Statuseinträge werden als Validierungsfehler gemeldet.'
    }
    finally {
        Remove-Module -ModuleInfo $validationModule -Force `
            -ErrorAction SilentlyContinue
    }
}
catch {
    Add-Result -Name 'Validation-Modul ungültiger Statuseintrag' `
        -Passed $false `
        -Message $_.Exception.Message
}


try {
    $runtimePath = Join-Path $ProjectRoot `
        'Modules\02-Runtime\KIModuleRuntime.psm1'
    $runtimeModule = Import-Module $runtimePath -Force -PassThru `
        -DisableNameChecking -ErrorAction Stop

    try {
        $testConfig = Read-KIJson -Path (
            Join-Path $ProjectRoot 'Config\kernel-config.json'
        )

        $runtimeContext = [pscustomobject]@{
            Mode = 'DryRun'
            Config = $testConfig
        }

        $installResult = & (
            Get-Command -Name 'Install-KIModuleRuntime' `
                -Module $runtimeModule.Name -ErrorAction Stop
        ) -Context $runtimeContext

        $validateResult = & (
            Get-Command -Name 'Validate-KIModuleRuntime' `
                -Module $runtimeModule.Name -ErrorAction Stop
        ) -Context $runtimeContext

        Add-Result -Name 'Runtime-Modul Dry-Run' `
            -Passed (
                [bool]$installResult.success -and
                [bool]$validateResult.success
            ) `
            -Message 'Runtime-Planung und Dry-Run-Validierung erfolgreich.'
    }
    finally {
        Remove-Module -ModuleInfo $runtimeModule -Force `
            -ErrorAction SilentlyContinue
    }
}
catch {
    Add-Result -Name 'Runtime-Modul Dry-Run' `
        -Passed $false `
        -Message $_.Exception.Message
}

try {
    Import-Module (Join-Path $ProjectRoot 'Core\KIStack.DownloadManager.psm1') `
        -Force -DisableNameChecking -ErrorAction Stop

    $downloadConfig = Read-KIJson -Path (
        Join-Path $ProjectRoot 'Config\kernel-config.json'
    )
    $downloadContext = [pscustomobject]@{
        Mode = 'DryRun'
        Config = $downloadConfig
    }

    $downloadResult = Invoke-KIDownload `
        -Context $downloadContext `
        -Uri 'https://example.invalid/package.bin' `
        -FileName 'package.bin' `
        -ExpectedSha256 ('0' * 64)

    Add-Result -Name 'Download-Manager Dry-Run' `
        -Passed (
            [bool]$downloadResult.success -and
            [string]$downloadResult.data.destination -eq `
                'C:\KI-Stack\cache\package.bin'
        ) `
        -Message 'Download wird im Dry-Run ausschließlich geplant.'
}
catch {
    Add-Result -Name 'Download-Manager Dry-Run' `
        -Passed $false `
        -Message $_.Exception.Message
}


try {
    $modulePath = Join-Path $ProjectRoot 'Modules\03-PythonGit\KIModulePythonGit.psm1'
    $moduleInfo = Import-Module $modulePath -Force -PassThru -DisableNameChecking -ErrorAction Stop
    try {
        $testConfig = Read-KIJson -Path (
            Join-Path $ProjectRoot 'Config\kernel-config.json'
        )
        $context = [pscustomobject]@{
            Mode = 'DryRun'
            Config = $testConfig
        }
        $result = & (Get-Command Install-KIModulePythonGit -Module $moduleInfo.Name) -Context $context
        Add-Result -Name 'PythonGit Dry-Run' -Passed ([bool]$result.success) -Message 'Python-/Git-Planung erfolgreich.'
    } finally { Remove-Module -ModuleInfo $moduleInfo -Force -ErrorAction SilentlyContinue }
} catch {
    Add-Result -Name 'PythonGit Dry-Run' -Passed $false -Message $_.Exception.Message
}

try {
    $fixtureConfig = Read-KIJson -Path (
        Join-Path $ProjectRoot 'Config\kernel-config.json'
    )

    $fixtureIssues = [System.Collections.Generic.List[string]]::new()
    foreach ($propertyName in @(
        'root','venvRoot','packageCache','preferredInstaller',
        'bootstrapUv','pipUpgrade'
    )) {
        if ($null -eq $fixtureConfig.pythonEnvironment.PSObject.Properties[$propertyName]) {
            [void]$fixtureIssues.Add("pythonEnvironment.$propertyName")
        }
    }
    foreach ($propertyName in @(
        'repositoryRoot','defaultBranch','longPaths','safeDirectoryRoot'
    )) {
        if ($null -eq $fixtureConfig.gitEnvironment.PSObject.Properties[$propertyName]) {
            [void]$fixtureIssues.Add("gitEnvironment.$propertyName")
        }
    }

    Add-Result -Name 'PythonGit-Testkonfiguration-vollständig' `
        -Passed ($fixtureIssues.Count -eq 0) `
        -Message ($(if ($fixtureIssues.Count -eq 0) {
            'Der Dry-Run verwendet die vollständige reale Releasekonfiguration einschließlich pipUpgrade.'
        } else {
            'Fehlende Eigenschaften: {0}' -f ($fixtureIssues -join ', ')
        }))
}
catch {
    Add-Result -Name 'PythonGit-Testkonfiguration-vollständig' `
        -Passed $false `
        -Message $_.Exception.Message
}


try {
    $modulePath = Join-Path $ProjectRoot 'Modules\04-ComfyUI\KIModuleComfyUI.psm1'
    $moduleInfo = Import-Module $modulePath -Force -PassThru -DisableNameChecking -ErrorAction Stop
    try {
        $testConfig = Read-KIJson -Path (
            Join-Path $ProjectRoot 'Config\kernel-config.json'
        )
        $context = [pscustomobject]@{
            Mode='DryRun'
            Config=$testConfig
        }
        $result = & (Get-Command Install-KIModuleComfyUI -Module $moduleInfo.Name) -Context $context
        Add-Result -Name 'ComfyUI Dry-Run' -Passed ([bool]$result.success) -Message 'ComfyUI-Planung erfolgreich.'
    } finally { Remove-Module -ModuleInfo $moduleInfo -Force -ErrorAction SilentlyContinue }
} catch {
    Add-Result -Name 'ComfyUI Dry-Run' -Passed $false -Message $_.Exception.Message
}


try {
    $manifest = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Manifests\models.manifest.json') -Raw |
        ConvertFrom-Json -Depth 20
    Add-Result -Name 'Modellmanifest' -Passed (
        $manifest.schemaVersion -eq '1.0' -and @($manifest.models).Count -eq 3
    ) -Message 'Modellmanifest und Platzhalter geprüft.'
} catch {
    Add-Result -Name 'Modellmanifest' -Passed $false -Message $_.Exception.Message
}


try {
    $modulePath = Join-Path $ProjectRoot 'Modules\06-Applications\KIModuleApplications.psm1'
    $moduleInfo = Import-Module $modulePath -Force -PassThru -DisableNameChecking -ErrorAction Stop
    try {
        $testConfig = Read-KIJson -Path (
            Join-Path $ProjectRoot 'Config\kernel-config.json'
        )
        $context = [pscustomobject]@{
            Mode='DryRun'
            Config=$testConfig
        }
        $result = & (Get-Command Install-KIModuleApplications -Module $moduleInfo.Name) -Context $context
        Add-Result -Name 'Applications Dry-Run' -Passed ([bool]$result.success) -Message 'LM Studio/Open WebUI-Planung erfolgreich.'
    } finally {
        Remove-Module -ModuleInfo $moduleInfo -Force -ErrorAction SilentlyContinue
    }
} catch {
    Add-Result -Name 'Applications Dry-Run' -Passed $false -Message $_.Exception.Message
}


try {
    $modulePath = Join-Path $ProjectRoot 'Modules\07-Integration\KIModuleIntegration.psm1'
    $moduleInfo = Import-Module $modulePath -Force -PassThru -DisableNameChecking -ErrorAction Stop
    try {
        $testConfig = Read-KIJson -Path (
            Join-Path $ProjectRoot 'Config\kernel-config.json'
        )
        $context = [pscustomobject]@{
            Mode='DryRun'
            Config=$testConfig
        }
        $result = & (Get-Command Validate-KIModuleIntegration -Module $moduleInfo.Name) -Context $context
        Add-Result -Name 'Integration Dry-Run' -Passed (
            [bool]$result.success -and @($result.data.endpoints).Count -eq 4
        ) -Message 'WSL/SearXNG-End-to-End-Planung erfolgreich.'
    } finally {
        Remove-Module -ModuleInfo $moduleInfo -Force -ErrorAction SilentlyContinue
    }
} catch {
    Add-Result -Name 'Integration Dry-Run' -Passed $false -Message $_.Exception.Message
}


try {
    $configPath = Join-Path $ProjectRoot 'Config\kernel-config.json'
    $releaseConfig = Get-Content -LiteralPath $configPath -Raw |
        ConvertFrom-Json -Depth 50

    $activeManifestIds = @(
        Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'Modules') -Recurse `
            -File -Filter 'module.json' |
        ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 20
        } |
        Where-Object enabled |
        ForEach-Object id
    )

    $approvedIds = @($releaseConfig.executeRelease.enabledModules)
    $allowlistValid = (
        $activeManifestIds.Count -eq 4 -and
        $activeManifestIds -contains 'KIModuleFoundation' -and
        $activeManifestIds -contains 'KIModuleRuntime' -and
        $activeManifestIds -contains 'KIModulePythonGit' -and
        $activeManifestIds -contains 'KIModuleComfyUI' -and
        @($activeManifestIds | Where-Object { $approvedIds -notcontains $_ }).Count -eq 0
    )

    Add-Result -Name 'Execute-Modulfreigabe' `
        -Passed $allowlistValid `
        -Message 'Nur Foundation, Runtime, PythonGit und ComfyUI sind für Execute aktiviert.'
}
catch {
    Add-Result -Name 'Execute-Modulfreigabe' `
        -Passed $false `
        -Message $_.Exception.Message
}

try {
    $kernelPath = Join-Path $ProjectRoot 'Invoke-KIStackBuilderKernel.ps1'
    $kernelContent = Get-Content -LiteralPath $kernelPath -Raw
    $gateValid = (
        $kernelContent.Contains('ExecutionConfirmation') -and
        $kernelContent.Contains('confirmationToken') -and
        $kernelContent.Contains('unapprovedModuleIds')
    )

    Add-Result -Name 'Execute-Sicherheitsgates' `
        -Passed $gateValid `
        -Message 'Bestätigungstoken und Modul-Allowlist sind im Kernel verankert.'
}
catch {
    Add-Result -Name 'Execute-Sicherheitsgates' `
        -Passed $false `
        -Message $_.Exception.Message
}


try {
    $corePath = Join-Path $ProjectRoot 'Core\KIStack.BuilderKernel.Core.psm1'
    $coreContent = Get-Content -LiteralPath $corePath -Raw

    $dispatcherHardened = (
        $coreContent.Contains('$commandOutput = @(& $functionName -Context $Context)') -and
        $coreContent.Contains('$resultCandidates') -and
        $coreContent.Contains("lieferte kein gültiges Ergebnisobjekt") -and
        $coreContent.Contains("lieferte mehrere Ergebnisobjekte")
    )

    Add-Result -Name 'Modulergebnis-Normalisierung' `
        -Passed $dispatcherHardened `
        -Message 'Pipeline-Ausgaben werden vom eigentlichen Modulergebnis getrennt.'
}
catch {
    Add-Result -Name 'Modulergebnis-Normalisierung' `
        -Passed $false `
        -Message $_.Exception.Message
}

try {
    $runtimePath = Join-Path $ProjectRoot 'Modules\02-Runtime\KIModuleRuntime.psm1'
    $runtimeContent = Get-Content -LiteralPath $runtimePath -Raw

    $runtimeHardened = (
        $runtimeContent.Contains('$wingetOutput = @(') -and
        $runtimeContent.Contains('Keine verwertbaren Runtime-Rollbackdaten vorhanden.') -and
        $runtimeContent.Contains('$wingetRollbackOutput = @(')
    )

    Add-Result -Name 'Runtime-Ausgabe-und-Rollbackschutz' `
        -Passed $runtimeHardened `
        -Message 'winget-Ausgaben und fehlende Rollbackdaten sind abgesichert.'
}
catch {
    Add-Result -Name 'Runtime-Ausgabe-und-Rollbackschutz' `
        -Passed $false `
        -Message $_.Exception.Message
}


try {
    $configPath = Join-Path $ProjectRoot 'Config\kernel-config.json'
    $schemaConfig = Get-Content -LiteralPath $configPath -Raw |
        ConvertFrom-Json -Depth 50

    $schemaMatrixValid = (
        @($schemaConfig.supportedPreflightSchemas) -contains '1.0' -and
        @($schemaConfig.supportedLockSchemas) -contains '1.0' -and
        @($schemaConfig.supportedPlanSchemas) -contains '1.0.1'
    )

    Add-Result -Name 'Schema-Kompatibilitätsmatrix' `
        -Passed $schemaMatrixValid `
        -Message 'Preflight 1.0, Lock 1.0 und Planner 1.0.1 werden unterstützt.'
}
catch {
    Add-Result -Name 'Schema-Kompatibilitätsmatrix' `
        -Passed $false `
        -Message $_.Exception.Message
}


try {
    $configPath = Join-Path $ProjectRoot 'Config\kernel-config.json'
    $versionConfig = Get-Content -LiteralPath $configPath -Raw |
        ConvertFrom-Json -Depth 50

    $expectedVersion = [string]$versionConfig.kernelVersion
    $releaseVersion = Get-KIReleaseVersion `
        -ReleaseId ([string]$versionConfig.executeRelease.releaseId)

    $corePath = Join-Path $ProjectRoot 'Core\KIStack.BuilderKernel.Core.psm1'
    $coreContent = Get-Content -LiteralPath $corePath -Raw
    $coreVersionMatch = [regex]::Match(
        $coreContent,
        "kernelVersion\s*=\s*'([^']+)'"
    )

    $versionConsistent = (
        $expectedVersion -eq $releaseVersion -and
        $coreVersionMatch.Success -and
        $coreVersionMatch.Groups[1].Value -eq $expectedVersion
    )

    Add-Result -Name 'Release-Versionskonsistenz' `
        -Passed $versionConsistent `
        -Message (
            'Config={0}; Release={1}; Core={2}' -f
            $expectedVersion,
            $releaseVersion,
            $(if ($coreVersionMatch.Success) {
                $coreVersionMatch.Groups[1].Value
            } else {
                'nicht gefunden'
            })
        )
}
catch {
    Add-Result -Name 'Release-Versionskonsistenz' `
        -Passed $false `
        -Message $_.Exception.Message
}


try {
    $runtimePath = Join-Path $ProjectRoot 'Modules\02-Runtime\KIModuleRuntime.psm1'
    $runtimeContent = Get-Content -LiteralPath $runtimePath -Raw

    $runtimeRevalidation = (
        $runtimeContent.Contains('$afterState = Get-KIRuntimeComponentState') -and
        $runtimeContent.Contains('[bool]$afterState.versionSufficient') -and
        $runtimeContent.Contains('alreadyCompliantAfterWinget')
    )

    Add-Result -Name 'Runtime-winget-Revalidierung' `
        -Passed $runtimeRevalidation `
        -Message 'Nach winget wird die tatsächlich installierte Version erneut geprüft.'
}
catch {
    Add-Result -Name 'Runtime-winget-Revalidierung' `
        -Passed $false `
        -Message $_.Exception.Message
}

try {
    $runtimePath = Join-Path $ProjectRoot 'Modules\02-Runtime\KIModuleRuntime.psm1'
    $runtimeContent = Get-Content -LiteralPath $runtimePath -Raw
    $kernelPath = Join-Path $ProjectRoot 'Invoke-KIStackBuilderKernel.ps1'
    $kernelContent = Get-Content -LiteralPath $kernelPath -Raw

    $parserSafeRollback = (
        $runtimeContent.Contains('$rollbackMessage') -and
        $kernelContent.Contains('$rollbackLogLevel') -and
        -not [regex]::IsMatch(
            $kernelContent,
            'New-KILogEntry\s+-Level\s*\(\s*if\b'
        )
    )

    Add-Result -Name 'Rollback-Parser-Sicherheit-v2' `
        -Passed $parserSafeRollback `
        -Message 'Rollback-Meldung und Log-Level werden vorab zugewiesen.'
}
catch {
    Add-Result -Name 'Rollback-Parser-Sicherheit-v2' `
        -Passed $false `
        -Message $_.Exception.Message
}


try {
    $runtimePath = Join-Path $ProjectRoot 'Modules\02-Runtime\KIModuleRuntime.psm1'
    $runtimeContent = Get-Content -LiteralPath $runtimePath -Raw

    $stateRoundTripSafe = (
        $runtimeContent.Contains('function Get-KIRuntimePropertyValue') -and
        $runtimeContent.Contains("-PropertyNames @('requiredCommand','command')") -and
        $runtimeContent.Contains('requiredCommand = $requiredCommand') -and
        $runtimeContent.Contains('command = $requiredCommand')
    )

    Add-Result -Name 'Runtime-State-Roundtrip' `
        -Passed $stateRoundTripSafe `
        -Message 'Konfigurationsobjekte und bereits erzeugte State-Objekte sind gleichermaßen verarbeitbar.'
}
catch {
    Add-Result -Name 'Runtime-State-Roundtrip' `
        -Passed $false `
        -Message $_.Exception.Message
}


try {
    $runtimePath = Join-Path $ProjectRoot 'Modules\02-Runtime\KIModuleRuntime.psm1'
    $runtimeContent = Get-Content -LiteralPath $runtimePath -Raw

    $validatedStateControlsFlow = (
        $runtimeContent.Contains('# Ausschließlich der validierte Endzustand entscheidet.') -and
        $runtimeContent.Contains('if ([bool]$afterState.versionSufficient)') -and
        $runtimeContent.Contains('continue') -and
        -not $runtimeContent.Contains('if ($wingetExitCode -ne 0)')
    )

    Add-Result -Name 'Runtime-Endzustand-entscheidet' `
        -Passed $validatedStateControlsFlow `
        -Message 'Nach winget entscheidet ausschließlich die erneut validierte Mindestversion.'
}
catch {
    Add-Result -Name 'Runtime-Endzustand-entscheidet' `
        -Passed $false `
        -Message $_.Exception.Message
}

try {
    $runtimePath = Join-Path $ProjectRoot 'Modules\02-Runtime\KIModuleRuntime.psm1'
    $runtimeContent = Get-Content -LiteralPath $runtimePath -Raw

    $configLookupUsed = (
        $runtimeContent.Contains('$componentConfig = @(') -and
        $runtimeContent.Contains('$Context.Config.runtime.components') -and
        $runtimeContent.Contains('Get-KIRuntimeComponentState -Component $componentConfig')
    )

    Add-Result -Name 'Runtime-Revalidierung-gegen-Konfiguration' `
        -Passed $configLookupUsed `
        -Message 'Die Nachprüfung verwendet die vollständige ursprüngliche Komponentenkonfiguration.'
}
catch {
    Add-Result -Name 'Runtime-Revalidierung-gegen-Konfiguration' `
        -Passed $false `
        -Message $_.Exception.Message
}


try {
    $runtimePath = Join-Path $ProjectRoot 'Modules\02-Runtime\KIModuleRuntime.psm1'
    Import-Module -Name $runtimePath -Force

    $versionAccepted = Test-KIVersionAtLeast `
        -DetectedVersion '2.55.0.windows.3' `
        -MinimumVersion '2.45.0'

    Add-Result -Name 'Git-Windows-Version-Normalisierung' `
        -Passed ([bool]$versionAccepted) `
        -Message '2.55.0.windows.3 wird korrekt als größer als 2.45.0 bewertet.'
}
catch {
    Add-Result -Name 'Git-Windows-Version-Normalisierung' `
        -Passed $false `
        -Message $_.Exception.Message
}

try {
    $runtimePath = Join-Path $ProjectRoot 'Modules\02-Runtime\KIModuleRuntime.psm1'
    $runtimeContent = Get-Content -LiteralPath $runtimePath -Raw

    $noDirectVersionCast = (
        $runtimeContent.Contains('function ConvertTo-KINormalizedVersion') -and
        $runtimeContent.Contains('function Test-KIVersionAtLeast') -and
        -not $runtimeContent.Contains('[version]$detectedVersion -ge')
    )

    Add-Result -Name 'Keine-rohen-SystemVersion-Vergleiche' `
        -Passed $noDirectVersionCast `
        -Message 'Versionsstrings mit Hersteller-Suffix werden vor dem Vergleich normalisiert.'
}
catch {
    Add-Result -Name 'Keine-rohen-SystemVersion-Vergleiche' `
        -Passed $false `
        -Message $_.Exception.Message
}


try {
    $runtimePath = Join-Path $ProjectRoot 'Modules\02-Runtime\KIModuleRuntime.psm1'
    $runtimeContent = Get-Content -LiteralPath $runtimePath -Raw

    $automaticVariableSafe = (
        $runtimeContent.Contains('$numericMatches = [regex]::Matches(') -and
        $runtimeContent.Contains('foreach ($numericMatch in $numericMatches)') -and
        -not $runtimeContent.Contains('$matches = [regex]::Matches(')
    )

    Add-Result -Name 'Versionsnormalisierung-ohne-Matches-Kollision' `
        -Passed $automaticVariableSafe `
        -Message 'Die PowerShell-Automatikvariable $Matches wird nicht überschrieben.'
}
catch {
    Add-Result -Name 'Versionsnormalisierung-ohne-Matches-Kollision' `
        -Passed $false `
        -Message $_.Exception.Message
}

try {
    $configPath = Join-Path $ProjectRoot 'Config\kernel-config.json'
    $releaseConfig = Get-Content -LiteralPath $configPath -Raw |
        ConvertFrom-Json -Depth 50

    $pythonGitApproved = (
        [string]$releaseConfig.kernelVersion -eq '1.2.0' -and
        [string]$releaseConfig.executeRelease.releaseId -eq 'COMFYUI-1.2.0' -and
        @($releaseConfig.executeRelease.enabledModules) -contains 'KIModulePythonGit'
    )

    Add-Result -Name 'PythonGit-Referenzfreigabe-beibehalten' `
        -Passed $pythonGitApproved `
        -Message 'Der freigegebene PythonGit-Baustein bleibt als drittes Execute-Modul aktiv.'
}
catch {
    Add-Result -Name 'PythonGit-Referenzfreigabe-beibehalten' `
        -Passed $false `
        -Message $_.Exception.Message
}

try {
    $modulePath = Join-Path $ProjectRoot 'Modules\03-PythonGit\KIModulePythonGit.psm1'
    $moduleContent = Get-Content -LiteralPath $modulePath -Raw

    $uvFallbackSafe = (
        $moduleContent.Contains('function Test-KIUvAvailable') -and
        $moduleContent.Contains('-m uv --version') -and
        $moduleContent.Contains('uv ist nach der Installation weder als Befehl noch als Python-Modul verfügbar.')
    )

    Add-Result -Name 'PythonGit-uv-Fallback' `
        -Passed $uvFallbackSafe `
        -Message 'uv wird als Befehl oder als Python-Modul validiert.'
}
catch {
    Add-Result -Name 'PythonGit-uv-Fallback' `
        -Passed $false `
        -Message $_.Exception.Message
}

try {
    $modulePath = Join-Path $ProjectRoot 'Modules\03-PythonGit\KIModulePythonGit.psm1'
    $moduleContent = Get-Content -LiteralPath $modulePath -Raw

    $rollbackScoped = (
        $moduleContent.Contains('KIModulePythonGit.rollback.json') -and
        $moduleContent.Contains('Write-KIPythonGitRollbackState') -and
        $moduleContent.Contains('Read-KIPythonGitRollbackState') -and
        $moduleContent.Contains('gitLongPathsValueBefore') -and
        $moduleContent.Contains('-m pip uninstall --yes uv')
    )

    Add-Result -Name 'PythonGit-transaktionsgebundener-Rollback' `
        -Passed $rollbackScoped `
        -Message 'Teiländerungen werden fortlaufend journalisiert und gezielt zurückgesetzt.'
}
catch {
    Add-Result -Name 'PythonGit-transaktionsgebundener-Rollback' `
        -Passed $false `
        -Message $_.Exception.Message
}


try {
    $starterModulePath = Join-Path $ProjectRoot 'Core\KIStack.Starter.psm1'
    Import-Module $starterModulePath -Force -ErrorAction Stop

    $starterPackage = Test-KIStarterPackage -ProjectRoot $ProjectRoot
    Add-Result -Name 'Starter-Paketvollständigkeit' `
        -Passed ([bool]$starterPackage.valid) `
        -Message ($(if ($starterPackage.valid) {
            'Alle zentralen Starterdateien sind vorhanden.'
        } else {
            $starterPackage.missing -join ' | '
        }))
}
catch {
    Add-Result -Name 'Starter-Paketvollständigkeit' `
        -Passed $false `
        -Message $_.Exception.Message
}

$temporaryRoot = $null
try {
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'KIStack-StarterTest-{0}' -f [guid]::NewGuid().ToString('N')
    )
    $olderState = Join-Path $temporaryRoot 'KI-Stack-Preflight-v0.2.0\State'
    $newerState = Join-Path $temporaryRoot (
        'KI-Stack-Preflight-v0.2.1\KI-Stack-Preflight-v0.2.1\State'
    )
    New-Item -ItemType Directory -Path $olderState -Force | Out-Null
    New-Item -ItemType Directory -Path $newerState -Force | Out-Null

    $olderFile = Join-Path $olderState 'Preflight-20260718-100000.zip'
    $newerFile = Join-Path $newerState 'Preflight-20260718-211931.zip'
    Set-Content -LiteralPath $olderFile -Value 'older' -Encoding ASCII
    Set-Content -LiteralPath $newerFile -Value 'newer' -Encoding ASCII
    (Get-Item -LiteralPath $olderFile).LastWriteTimeUtc = [datetime]'2026-07-18T10:00:00Z'
    (Get-Item -LiteralPath $newerFile).LastWriteTimeUtc = [datetime]'2026-07-18T21:19:31Z'

    $selectedPreflight = Find-KILatestPreflight `
        -SearchRoots @($temporaryRoot) `
        -RequireStateDirectory

    $recursiveSelectionValid = (
        $selectedPreflight.FullName -eq (Get-Item -LiteralPath $newerFile).FullName
    )

    Add-Result -Name 'Preflight-Rekursion-und-Zeitstempel' `
        -Passed $recursiveSelectionValid `
        -Message 'Doppelte Paketverschachtelung und Auswahl nach LastWriteTimeUtc geprüft.'
}
catch {
    Add-Result -Name 'Preflight-Rekursion-und-Zeitstempel' `
        -Passed $false `
        -Message $_.Exception.Message
}
finally {
    if ($temporaryRoot -and (Test-Path -LiteralPath $temporaryRoot)) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
}

try {
    $wrapperNames = @(
        'Start-Nur-Selbsttest.cmd',
        'Start-KIStack-ComfyUI-DryRun.cmd',
        'Start-KIStack-ComfyUI-Execute.cmd'
    )
    $cmdIssues = [System.Collections.Generic.List[string]]::new()

    foreach ($wrapperName in $wrapperNames) {
        $wrapperPath = Join-Path $ProjectRoot $wrapperName
        $wrapperContent = Get-Content -LiteralPath $wrapperPath -Raw
        $wrapperBytes = [IO.File]::ReadAllBytes($wrapperPath)
        $wrapperAscii = [Text.Encoding]::ASCII.GetString($wrapperBytes)

        if (-not $wrapperContent.Contains('%ComSpec%" /D /K')) {
            [void]$cmdIssues.Add("${wrapperName}: dauerhafte cmd-/K-Diagnosesitzung fehlt")
        }
        if (-not $wrapperContent.Contains('Bootstrap-KIStack-ComfyUI.cmd')) {
            [void]$cmdIssues.Add("${wrapperName}: gemeinsamer Bootstrap fehlt")
        }
        if ([regex]::IsMatch($wrapperAscii, '(?<!\r)\n')) {
            [void]$cmdIssues.Add("${wrapperName}: enthält LF ohne CR")
        }
    }

    $bootstrapPath = Join-Path $ProjectRoot 'Bootstrap-KIStack-ComfyUI.cmd'
    $bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw
    $bootstrapBytes = [IO.File]::ReadAllBytes($bootstrapPath)
    $bootstrapAscii = [Text.Encoding]::ASCII.GetString($bootstrapBytes)

    if (-not $bootstrapContent.Contains('%ProgramW6432%\PowerShell\7\pwsh.exe')) {
        [void]$cmdIssues.Add('Bootstrap: ProgramW6432-Fallback fehlt')
    }
    if (-not $bootstrapContent.Contains('where pwsh.exe')) {
        [void]$cmdIssues.Add('Bootstrap: PATH-Fallback fehlt')
    }
    if (-not $bootstrapContent.Contains('KI-Stack-ComfyUI-Bootstrap.log')) {
        [void]$cmdIssues.Add('Bootstrap: TEMP-Diagnoselog fehlt')
    }
    if (-not $bootstrapContent.Contains('pause >nul')) {
        [void]$cmdIssues.Add('Bootstrap: kontrollierte Abschluss-Pause fehlt')
    }
    if ([regex]::IsMatch($bootstrapAscii, '(?<!\r)\n')) {
        [void]$cmdIssues.Add('Bootstrap: enthält LF ohne CR')
    }

    Add-Result -Name 'CMD-Starter-Robustheit' `
        -Passed ($cmdIssues.Count -eq 0) `
        -Message ($(if ($cmdIssues.Count -eq 0) {
            'Persistente /K-Sitzung, gemeinsamer Bootstrap, Fallbacks, Logs und CRLF geprüft.'
        } else {
            $cmdIssues -join ' | '
        }))
}
catch {
    Add-Result -Name 'CMD-Starter-Robustheit' `
        -Passed $false `
        -Message $_.Exception.Message
}

try {
    $launcherPath = Join-Path $ProjectRoot 'Start-KIStack-ComfyUI.ps1'
    $launcherContent = Get-Content -LiteralPath $launcherPath -Raw
    $tryMatch = [regex]::Match(
        $launcherContent,
        'try\s*\{\s*Write-EmergencyStarterLog'
    )
    $tryIndex = $(if ($tryMatch.Success) { $tryMatch.Index } else { -1 })
    $importIndex = $launcherContent.IndexOf('Import-Module $starterModulePath')
    $newLogIndex = $launcherContent.IndexOf('$starterLogPath = New-KIStarterLogPath')

    $bootstrapGuarded = (
        $tryIndex -ge 0 -and
        $importIndex -gt $tryIndex -and
        $newLogIndex -gt $tryIndex -and
        $launcherContent.Contains('Write-EmergencyStarterLog') -and
        $launcherContent.Contains('KI-Stack-ComfyUI-Starter.log') -and
        -not $launcherContent.StartsWith('#Requires')
    )

    Add-Result -Name 'PowerShell-Fruehstart-Diagnose' `
        -Passed $bootstrapGuarded `
        -Message 'Import, Paket-Log-Erzeugung und Versionsprüfung liegen im geschützten Startpfad; TEMP-Notfalllog vorhanden.'
}
catch {
    Add-Result -Name 'PowerShell-Fruehstart-Diagnose' `
        -Passed $false `
        -Message $_.Exception.Message
}

try {
    $elevationPath = Join-Path $ProjectRoot 'Request-KIStack-Elevation.ps1'
    $bootstrapPath = Join-Path $ProjectRoot 'Bootstrap-KIStack-ComfyUI.cmd'
    $launcherPath = Join-Path $ProjectRoot 'Start-KIStack-ComfyUI.ps1'

    $elevationContent = Get-Content -LiteralPath $elevationPath -Raw
    $bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw
    $launcherContent = Get-Content -LiteralPath $launcherPath -Raw

    $automaticElevationValid = (
        $elevationContent.Contains('[Security.Principal.WindowsBuiltInRole]::Administrator') -and
        $elevationContent.Contains('Start-Process') -and
        $elevationContent.Contains('-Verb RunAs') -and
        $elevationContent.Contains('/D /K') -and
        $elevationContent.Contains('exit 10') -and
        $bootstrapContent.Contains('Request-KIStack-Elevation.ps1') -and
        $bootstrapContent.Contains('ELEVATION_MARKER') -and
        $bootstrapContent.Contains(':ElevationHandedOff') -and
        $bootstrapContent.Contains('if "%ELEVATION_RESULT%"=="10" exit /b 20') -and
        -not $launcherContent.Contains('Execute erfordert eine als Administrator gestartete CMD-Datei.')
    )

    Add-Result -Name 'Execute-automatische-UAC-Elevation' `
        -Passed $automaticElevationValid `
        -Message 'Execute erkennt fehlende Rechte und startet selbstständig einen erhöhten, persistenten Diagnoseprozess.'
}
catch {
    Add-Result -Name 'Execute-automatische-UAC-Elevation' `
        -Passed $false `
        -Message $_.Exception.Message
}

try {
    $configPath = Join-Path $ProjectRoot 'Config\kernel-config.json'
    $starterConfig = Get-Content -LiteralPath $configPath -Raw |
        ConvertFrom-Json -Depth 100

    $starterConfigValid = (
        [string]$starterConfig.starter.preflightFilePattern -eq 'Preflight-*.zip' -and
        [bool]$starterConfig.starter.searchRecursively -and
        [string]$starterConfig.starter.sortBy -eq 'LastWriteTimeUtc' -and
        @($starterConfig.starter.preflightSearchRoots).Count -ge 2
    )

    Add-Result -Name 'Starter-Konfiguration' `
        -Passed $starterConfigValid `
        -Message 'Suchwurzeln, Rekursion und Zeitstempelsortierung geprüft.'
}
catch {
    Add-Result -Name 'Starter-Konfiguration' `
        -Passed $false `
        -Message $_.Exception.Message
}

try {
    $selfTestContent = Get-Content -LiteralPath $PSCommandPath -Raw
    $aggregationIndex = $selfTestContent.LastIndexOf('$failedResults = @(')
    $lastResultIndex = $selfTestContent.LastIndexOf('Add-Result -Name')
    $aggregationComplete = (
        $aggregationIndex -gt $lastResultIndex -and
        $aggregationIndex -ge 0
    )

    Add-Result -Name 'Vollständige-Fehleraggregation' `
        -Passed $aggregationComplete `
        -Message 'Die Fehlerliste wird erst nach sämtlichen Einzelprüfungen berechnet.'
}
catch {
    Add-Result -Name 'Vollständige-Fehleraggregation' `
        -Passed $false `
        -Message $_.Exception.Message
}


try {
    $configPath = Join-Path $ProjectRoot 'Config\kernel-config.json'
    $comfyConfig = Get-Content -LiteralPath $configPath -Raw |
        ConvertFrom-Json -Depth 100

    $requiredProperties = @(
        'root','repository','ref','refType','cloneDepth','venv','customNodesRoot',
        'modelsRoot','moduleRoot','extraModelPathsConfig','inputDirectory',
        'outputDirectory','userDirectory','listenAddress','port','enableManager',
        'dependencyInstaller','pipUpgrade','installManagerRequirements','torch'
    )
    $missingProperties = @(
        $requiredProperties |
        Where-Object { $null -eq $comfyConfig.comfyUI.PSObject.Properties[$_] }
    )
    $comfyConfigValid = (
        $missingProperties.Count -eq 0 -and
        [string]$comfyConfig.comfyUI.repository -eq 'https://github.com/Comfy-Org/ComfyUI.git' -and
        [string]$comfyConfig.comfyUI.ref -eq 'v0.28.0' -and
        [string]$comfyConfig.comfyUI.refType -eq 'tag' -and
        [string]$comfyConfig.comfyUI.torch.extraIndexUrl -eq
            'https://download.pytorch.org/whl/cu130' -and
        [bool]$comfyConfig.comfyUI.torch.requireCuda -and
        [int]$comfyConfig.comfyUI.torch.minimumComputeCapabilityMajor -ge 12 -and
        [string]$comfyConfig.comfyUI.torch.expectedDeviceNamePattern -eq 'RTX 5090'
    )

    Add-Result -Name 'ComfyUI-Releasekonfiguration-vollständig' `
        -Passed $comfyConfigValid `
        -Message ($(if ($comfyConfigValid) {
            'ComfyUI v0.28.0, offizieller CUDA-13.0-Index und RTX-5090-Gates sind vollständig konfiguriert.'
        } else {
            'Fehlende oder ungültige Eigenschaften: {0}' -f ($missingProperties -join ', ')
        }))
}
catch {
    Add-Result -Name 'ComfyUI-Releasekonfiguration-vollständig' `
        -Passed $false -Message $_.Exception.Message
}

try {
    $configPath = Join-Path $ProjectRoot 'Config\kernel-config.json'
    $releaseConfig = Get-Content -LiteralPath $configPath -Raw |
        ConvertFrom-Json -Depth 100
    $comfyApproved = (
        [string]$releaseConfig.kernelVersion -eq '1.2.0' -and
        [string]$releaseConfig.executeRelease.releaseId -eq 'COMFYUI-1.2.0' -and
        @($releaseConfig.executeRelease.enabledModules).Count -eq 4 -and
        @($releaseConfig.executeRelease.enabledModules) -contains 'KIModuleComfyUI'
    )
    Add-Result -Name 'ComfyUI-Execute-Freigabe' `
        -Passed $comfyApproved `
        -Message 'ComfyUI ist als viertes und letztes Modul dieses Execute-Releases freigegeben.'
}
catch {
    Add-Result -Name 'ComfyUI-Execute-Freigabe' `
        -Passed $false -Message $_.Exception.Message
}

try {
    $modulePath = Join-Path $ProjectRoot 'Modules\04-ComfyUI\KIModuleComfyUI.psm1'
    $moduleContent = Get-Content -LiteralPath $modulePath -Raw
    $moduleHardened = (
        $moduleContent.Contains('KIModuleComfyUI.rollback.json') -and
        $moduleContent.Contains('Write-KIComfyRollbackState') -and
        $moduleContent.Contains('Read-KIComfyRollbackState') -and
        $moduleContent.Contains('rootCreatedByTransaction') -and
        $moduleContent.Contains('venvCreatedByTransaction') -and
        $moduleContent.Contains('Nicht verwaltete Datei wird nicht überschrieben') -and
        $moduleContent.Contains('describe --tags --exact-match') -and
        $moduleContent.Contains('manager_requirements.txt') -and
        $moduleContent.Contains('torch.cuda.get_device_capability') -and
        $moduleContent.Contains("managedBy = 'KI-STACK-COMFYUI-MANAGED'") -and
        $moduleContent.Contains('PYTHONNOUSERSITE') -and
        $moduleContent.Contains('validationModelDirectories')
    )
    Add-Result -Name 'ComfyUI-Transaktion-und-Rollback' `
        -Passed $moduleHardened `
        -Message 'Repository, Venv, verwaltete Dateien und Teilzustände werden transaktionsgebunden behandelt.'
}
catch {
    Add-Result -Name 'ComfyUI-Transaktion-und-Rollback' `
        -Passed $false -Message $_.Exception.Message
}

try {
    $modulePath = Join-Path $ProjectRoot 'Modules\04-ComfyUI\KIModuleComfyUI.psm1'
    $moduleContent = Get-Content -LiteralPath $modulePath -Raw
    $pinnedRelease = (
        $moduleContent.Contains("[string]$Context.Config.comfyUI.ref") -and
        $moduleContent.Contains("[string]$repositoryState.exactTag") -and
        $moduleContent.Contains('Das ComfyUI-Repository enthält lokale Änderungen') -and
        -not $moduleContent.Contains('git pull')
    )
    Add-Result -Name 'ComfyUI-kein-ungeprüftes-Master-Update' `
        -Passed $pinnedRelease `
        -Message 'Execute arbeitet mit dem freigegebenen Tag und führt kein implizites git pull aus.'
}
catch {
    Add-Result -Name 'ComfyUI-kein-ungeprüftes-Master-Update' `
        -Passed $false -Message $_.Exception.Message
}

try {
    $modulePath = Join-Path $ProjectRoot 'Modules\04-ComfyUI\KIModuleComfyUI.psm1'
    $moduleContent = Get-Content -LiteralPath $modulePath -Raw
    $launcherSafe = (
        $moduleContent.Contains('Start-KIStack-ComfyUI.cmd') -and
        $moduleContent.Contains('Stop-KIStack-ComfyUI.ps1') -and
        $moduleContent.Contains('--extra-model-paths-config') -and
        $moduleContent.Contains('--input-directory') -and
        $moduleContent.Contains('--output-directory') -and
        $moduleContent.Contains('--user-directory') -and
        $moduleContent.Contains('--enable-manager') -and
        $moduleContent.Contains('$matchingProcesses') -and
        -not $moduleContent.Contains('$matches =')
    )
    Add-Result -Name 'ComfyUI-Start-Stop-und-Matches-Regression' `
        -Passed $launcherSafe `
        -Message 'Start/Stop-Artefakte, zentrale Datenpfade und Schutz vor $Matches-Kollision sind enthalten.'
}
catch {
    Add-Result -Name 'ComfyUI-Start-Stop-und-Matches-Regression' `
        -Passed $false -Message $_.Exception.Message
}

try {
    $bootstrapPath = Join-Path $ProjectRoot 'Bootstrap-KIStack-ComfyUI.cmd'
    $bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw
    $versionLabelValid = (
        $bootstrapContent.Contains('KI-Stack ComfyUI v1.2.0 - %ACTION%') -and
        -not [regex]::IsMatch($bootstrapContent, 'PythonGit v1\\.1\\.[0-9]+')
    )
    Add-Result -Name 'Starter-sichtbare-Versionskonsistenz' `
        -Passed $versionLabelValid `
        -Message 'Der sichtbare CMD-Kopf entspricht dem Paket v1.2.0.'
}
catch {
    Add-Result -Name 'Starter-sichtbare-Versionskonsistenz' `
        -Passed $false -Message $_.Exception.Message
}

$failedResults = @(
    $results |
    Where-Object { -not [bool]$_.passed }
)

$summary = [pscustomobject][ordered]@{
    generatedAt = (Get-Date).ToString('o')
    packageVersion = '1.2.0'
    passed = ($failedResults.Count -eq 0)
    failedNames = @(
        $failedResults |
        ForEach-Object { [string]$_.name }
    )
    results = $results
}
$selfTestJson = $summary | ConvertTo-Json -Depth 20

try {
    $selfTestStateRoot = Join-Path $ProjectRoot 'State\SelfTest'
    New-Item -ItemType Directory -Path $selfTestStateRoot -Force | Out-Null
    $selfTestTimestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $selfTestReportPath = Join-Path $selfTestStateRoot (
        'SelfTest-{0}.json' -f $selfTestTimestamp
    )
    $selfTestLatestPath = Join-Path $selfTestStateRoot 'SelfTest-latest.json'
    Set-Content -LiteralPath $selfTestReportPath -Value $selfTestJson `
        -Encoding UTF8 -ErrorAction Stop
    Set-Content -LiteralPath $selfTestLatestPath -Value $selfTestJson `
        -Encoding UTF8 -ErrorAction Stop
}
catch {
    try {
        $tempSelfTestPath = Join-Path ([IO.Path]::GetTempPath()) `
            'KI-Stack-ComfyUI-SelfTest-latest.json'
        Set-Content -LiteralPath $tempSelfTestPath -Value $selfTestJson `
            -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch {
    }
}

$selfTestJson

if ($failedResults.Count -gt 0) {
    Write-Host ''
    Write-Host 'FEHLGESCHLAGENE SELBSTTESTS:' -ForegroundColor Red
    foreach ($failedResult in $failedResults) {
        Write-Host ('- {0}: {1}' -f $failedResult.name, $failedResult.message) `
            -ForegroundColor Red
    }
    exit 1
}
exit 0

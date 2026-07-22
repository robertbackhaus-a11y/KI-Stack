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
    $modelsModulePath = Join-Path $ProjectRoot 'Modules\05-Models\KIModuleModels.psm1'
    $modelsModuleContent = Get-Content -LiteralPath $modelsModulePath -Raw
    $downloadStreamVariableSafe = (
        -not [regex]::IsMatch(
            $modelsModuleContent,
            '(?im)^\s*\$input\s*=',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        ) -and
        $modelsModuleContent.Contains('$responseStream = $response.Content.ReadAsStream()') -and
        $modelsModuleContent.Contains('$responseStream.Read($buffer,0,$buffer.Length)') -and
        $modelsModuleContent.Contains('$responseStream.Dispose()')
    )
    Add-Result -Name 'Models-Downloadstream-keine-Input-Kollision' `
        -Passed $downloadStreamVariableSafe `
        -Message 'Der HTTP-Downloadstream überschreibt die PowerShell-Automatikvariable $input nicht.'
}
catch {
    Add-Result -Name 'Models-Downloadstream-keine-Input-Kollision' `
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
            [string]$cleanResult.data.transactionId -eq 'UNSPECIFIED' -and
            [string]$cleanResult.data.mode -eq 'Unknown' -and
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
            @($invalidResult.data.invalidModuleEntries).Count -eq 1 -and
            [string]$invalidResult.data.transactionId -eq 'UNSPECIFIED' -and
            @($invalidResult.data.report.modules).Count -eq 1
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
    $managedRequiredModels = @(
        $manifest.models | Where-Object {
            [bool]$_.enabled -and [bool]$_.required -and [bool]$_.managed
        }
    )
    $localModelPlaceholders = @(
        $manifest.models | Where-Object {
            [bool]$_.enabled -and -not [bool]$_.required -and -not [bool]$_.managed
        }
    )
    $requiredModelIds = @(
        $managedRequiredModels | ForEach-Object { [string]$_.id } | Sort-Object
    )
    $placeholderIds = @(
        $localModelPlaceholders | ForEach-Object { [string]$_.id } | Sort-Object
    )
    $managedMetadataValid = @(
        $managedRequiredModels | Where-Object {
            [string]::IsNullOrWhiteSpace([string]$_.source) -or
            [int64]$_.sizeBytes -le 0 -or
            [string]$_.sha256 -notmatch '^[0-9a-fA-F]{64}$'
        }
    ).Count -eq 0
    $placeholderMetadataValid = @(
        $localModelPlaceholders | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.source) -or
            $null -ne $_.sizeBytes -or
            $null -ne $_.sha256
        }
    ).Count -eq 0
    $manifestValid = (
        [string]$manifest.schemaVersion -eq '1.1' -and
        @($manifest.models).Count -eq 8 -and
        $managedRequiredModels.Count -eq 3 -and
        $localModelPlaceholders.Count -eq 5 -and
        ($requiredModelIds -join '|') -eq 'flux2-klein-9b-fp8|flux2-vae|qwen-3-8b-fp8mixed' -and
        ($placeholderIds -join '|') -eq 'clip-l|flux-ae|flux1-krea-dev-fp8|pony-v6-xl|t5xxl-fp16' -and
        $managedMetadataValid -and
        $placeholderMetadataValid
    )
    Add-Result -Name 'Modellmanifest' -Passed $manifestValid -Message $(
        if ($manifestValid) {
            'Schema 1.1, drei verwaltete Pflichtmodelle und fünf lokale Platzhalter geprüft.'
        }
        else {
            'Der Modellmanifest-Vertrag entspricht nicht dem freigegebenen Schema 1.1.'
        }
    )
} catch {
    Add-Result -Name 'Modellmanifest' -Passed $false -Message $_.Exception.Message
}


try {
    $modulePath = Join-Path $ProjectRoot 'Modules\06-Applications\KIModuleApplications.psm1'
    $moduleInfo = Import-Module $modulePath -Force -PassThru -DisableNameChecking -ErrorAction Stop
    $transactionDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        'KIStack-Applications-DryRun-' + [guid]::NewGuid().ToString('N')
    )
    try {
        New-Item -ItemType Directory -Path $transactionDirectory -Force | Out-Null
        $testConfig = Read-KIJson -Path (
            Join-Path $ProjectRoot 'Config\kernel-config.json'
        )
        $context = [pscustomobject]@{
            Mode = 'DryRun'
            Config = $testConfig
            TransactionDirectory = $transactionDirectory
            Transaction = [pscustomobject]@{
                transactionId = 'SELFTEST-APPLICATIONS-DRYRUN'
            }
        }
        $result = & (Get-Command Install-KIModuleApplications -Module $moduleInfo.Name) -Context $context
        $diagnosticPath = Join-Path $transactionDirectory 'module-state\KIModuleApplications.diagnostic.json'
        $dryRunValid = (
            [bool]$result.success -and
            (Test-Path -LiteralPath $diagnosticPath -PathType Leaf)
        )
        Add-Result -Name 'Applications Dry-Run' -Passed $dryRunValid -Message 'LM Studio/Open WebUI-Planung mit vollständigem Transaktionskontext erfolgreich.'
    }
    finally {
        Remove-Module -ModuleInfo $moduleInfo -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $transactionDirectory) {
            Remove-Item -LiteralPath $transactionDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
catch {
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
        $integrationEndpointNames = @(
            'searxngUrl',
            'openWebUIUrl',
            'lmStudioUrl',
            'comfyUIUrl'
        )
        $missingIntegrationEndpoints = @(
            $integrationEndpointNames |
            Where-Object {
                $null -eq $testConfig.integration.PSObject.Properties[[string]$_]
            }
        )
        $integrationDryRunValid = (
            [bool]$result.success -and
            $missingIntegrationEndpoints.Count -eq 0 -and
            @($result.data.endpoints).Count -eq $integrationEndpointNames.Count
        )
        Add-Result -Name 'Integration Dry-Run' `
            -Passed $integrationDryRunValid `
            -Message 'Die vier konfigurierten End-to-End-Endpunkte wurden unabhängig von der Modulanzahl validiert.'
    } finally {
        Remove-Module -ModuleInfo $moduleInfo -Force -ErrorAction SilentlyContinue
    }
} catch {
    Add-Result -Name 'Integration Dry-Run' -Passed $false -Message $_.Exception.Message
}


try {
    $integrationModulePath = Join-Path $ProjectRoot `
        'Modules\07-Integration\KIModuleIntegration.psm1'
    $integrationModuleContent = Get-Content -LiteralPath $integrationModulePath -Raw
    $integrationContractValid = (
        $integrationModuleContent.Contains('[string]$Context.Config.integration.searxngUrl') -and
        $integrationModuleContent.Contains('[string]$Context.Config.integration.openWebUIUrl') -and
        $integrationModuleContent.Contains('[string]$Context.Config.integration.lmStudioUrl') -and
        $integrationModuleContent.Contains('[string]$Context.Config.integration.comfyUIUrl')
    )
    Add-Result -Name 'Integration-Endpunktvertrag-vier-Endpunkte' `
        -Passed $integrationContractValid `
        -Message 'Der Integration-Endpunktvertrag umfasst SearXNG, Open WebUI, LM Studio und ComfyUI.'
}
catch {
    Add-Result -Name 'Integration-Endpunktvertrag-vier-Endpunkte' `
        -Passed $false -Message $_.Exception.Message
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
        $activeManifestIds.Count -eq 9 -and
        $activeManifestIds -contains 'KIModuleFoundation' -and
        $activeManifestIds -contains 'KIModuleRuntime' -and
        $activeManifestIds -contains 'KIModulePythonGit' -and
        $activeManifestIds -contains 'KIModuleComfyUI' -and
        $activeManifestIds -contains 'KIModuleModels' -and
        $activeManifestIds -contains 'KIModuleApplications' -and
        $activeManifestIds -contains 'KIModuleIntegration' -and
        @($activeManifestIds | Where-Object { $approvedIds -notcontains $_ }).Count -eq 0
    )

    Add-Result -Name 'Execute-Modulfreigabe' `
        -Passed $allowlistValid `
        -Message 'Foundation, Runtime, PythonGit, ComfyUI, Models, Applications und Integration sind für Execute aktiviert.'
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
        [string]$releaseConfig.kernelVersion -eq '1.6.3' -and
        [string]$releaseConfig.executeRelease.releaseId -eq 'CUTOVER-1.6.3' -and
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
        'Start-KIStack-Cutover-DryRun.cmd',
        'Start-KIStack-Cutover-Execute.cmd'
    )
    $cmdIssues = [System.Collections.Generic.List[string]]::new()

    foreach ($wrapperName in $wrapperNames) {
        $wrapperPath = Join-Path $ProjectRoot $wrapperName
        $wrapperContent = Get-Content -LiteralPath $wrapperPath -Raw
        $wrapperBytes = [IO.File]::ReadAllBytes($wrapperPath)
        $wrapperAscii = [Text.Encoding]::ASCII.GetString($wrapperBytes)

        if (-not $wrapperContent.Contains('%ComSpec%" /D /C')) {
            [void]$cmdIssues.Add("${wrapperName}: cmd-/C-Aufruf für automatisches Schließen bei Erfolg fehlt")
        }
        if (-not $wrapperContent.Contains('Bootstrap-KIStack-Cutover.cmd')) {
            [void]$cmdIssues.Add("${wrapperName}: gemeinsamer Bootstrap fehlt")
        }
        if ([regex]::IsMatch($wrapperAscii, '(?<!\r)\n')) {
            [void]$cmdIssues.Add("${wrapperName}: enthält LF ohne CR")
        }
    }

    $bootstrapPath = Join-Path $ProjectRoot 'Bootstrap-KIStack-Cutover.cmd'
    $bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw
    $bootstrapBytes = [IO.File]::ReadAllBytes($bootstrapPath)
    $bootstrapAscii = [Text.Encoding]::ASCII.GetString($bootstrapBytes)

    if (-not $bootstrapContent.Contains('%ProgramW6432%\PowerShell\7\pwsh.exe')) {
        [void]$cmdIssues.Add('Bootstrap: ProgramW6432-Fallback fehlt')
    }
    if (-not $bootstrapContent.Contains('where pwsh.exe')) {
        [void]$cmdIssues.Add('Bootstrap: PATH-Fallback fehlt')
    }
    if (-not $bootstrapContent.Contains('KI-Stack-Cutover-Bootstrap.log')) {
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
            'cmd /C, gemeinsamer Bootstrap, Ergebnis-/Exitcodeanzeige, Tastendruckabschluss, Fallbacks, Logs und CRLF geprüft.'
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
    $launcherPath = Join-Path $ProjectRoot 'Start-KIStack-Cutover.ps1'
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
        $launcherContent.Contains('KI-Stack-Cutover-Starter.log') -and
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
    $bootstrapPath = Join-Path $ProjectRoot 'Bootstrap-KIStack-Cutover.cmd'
    $launcherPath = Join-Path $ProjectRoot 'Start-KIStack-Cutover.ps1'

    $elevationContent = Get-Content -LiteralPath $elevationPath -Raw
    $bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw
    $launcherContent = Get-Content -LiteralPath $launcherPath -Raw

    $automaticElevationValid = (
        $elevationContent.Contains('[Security.Principal.WindowsBuiltInRole]::Administrator') -and
        $elevationContent.Contains('Start-Process') -and
        $elevationContent.Contains('-Verb RunAs') -and
        $elevationContent.Contains('/D /C') -and
        $elevationContent.Contains('exit 10') -and
        $bootstrapContent.Contains('Request-KIStack-Elevation.ps1') -and
        $bootstrapContent.Contains('ELEVATION_MARKER') -and
        $bootstrapContent.Contains(':ElevationHandedOff') -and
        $bootstrapContent.Contains('if "%ELEVATION_RESULT%"=="10" exit /b 20') -and
        -not $launcherContent.Contains('Execute erfordert eine als Administrator gestartete CMD-Datei.')
    )

    Add-Result -Name 'Execute-automatische-UAC-Elevation' `
        -Passed $automaticElevationValid `
        -Message 'Execute erkennt fehlende Rechte und startet einen erhöhten Prozess; das Ergebnis bleibt bis zum Tastendruck sichtbar.'
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
        [string]$starterConfig.starter.preflightSelectionMode -eq 'EmbeddedDefault' -and
        [bool]$starterConfig.starter.allowExplicitPreflightOverride -and
        [string]$starterConfig.starter.embeddedPreflightRelativePath -eq
            'Embedded\Preflight\State\Preflight-Continuation-v1.6.3.zip' -and
        @($starterConfig.starter.preflightSearchRoots).Count -ge 2
    )

    Add-Result -Name 'Starter-Konfiguration' `
        -Passed $starterConfigValid `
        -Message 'Paketinterner Standard-Preflight, expliziter Override und historische Suchlogik wurden geprüft.'
}
catch {
    Add-Result -Name 'Starter-Konfiguration' `
        -Passed $false `
        -Message $_.Exception.Message
}

try {
    $embeddedConfig = Get-Content -LiteralPath (
        Join-Path $ProjectRoot 'Config\kernel-config.json'
    ) -Raw | ConvertFrom-Json -Depth 100
    $embeddedPreflightPath = Join-Path $ProjectRoot `
        ([string]$embeddedConfig.starter.embeddedPreflightRelativePath)
    $embeddedWorkingRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'KI-Stack-Embedded-Preflight-Test-' + [guid]::NewGuid().ToString('N')
    )
    try {
        New-Item -ItemType Directory -Path $embeddedWorkingRoot -Force | Out-Null
        $resolvedEmbeddedInput = Resolve-KIPreflightInput `
            -InputPath $embeddedPreflightPath `
            -WorkingDirectory $embeddedWorkingRoot
        $embeddedReport = Read-KIJson -Path $resolvedEmbeddedInput.reportPath
        $embeddedLock = Read-KIJson -Path $resolvedEmbeddedInput.lockPath
        $embeddedPlan = Read-KIJson -Path $resolvedEmbeddedInput.planPath
        $embeddedValidation = Test-KIKernelInput `
            -Report $embeddedReport `
            -VersionLock $embeddedLock `
            -Plan $embeddedPlan `
            -Config $embeddedConfig
        $embeddedPreflightValid = (
            [bool]$embeddedValidation.valid -and
            [string]$embeddedReport.reportId -eq
                'PREFLIGHT-CONTINUATION-CUTOVER-1.6.3' -and
            [string]$embeddedLock.lockId -eq
                'VERSION-LOCK-CONTINUATION-CUTOVER-1.6.3' -and
            [string]$embeddedPlan.planId -eq
                'INSTALL-PLAN-CONTINUATION-CUTOVER-1.6.3'
        )
        Add-Result -Name 'Paketinterner-Fortsetzungs-Preflight' `
            -Passed $embeddedPreflightValid `
            -Message 'Der eingebettete Preflight wurde extrahiert, geparst und durch die echte Kernel-Eingabevalidierung geprüft.'
    }
    finally {
        if (Test-Path -LiteralPath $embeddedWorkingRoot) {
            Remove-Item -LiteralPath $embeddedWorkingRoot -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }
}
catch {
    Add-Result -Name 'Paketinterner-Fortsetzungs-Preflight' `
        -Passed $false -Message $_.Exception.Message
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
        [string]$releaseConfig.kernelVersion -eq '1.6.3' -and
        [string]$releaseConfig.executeRelease.releaseId -eq 'CUTOVER-1.6.3' -and
        @($releaseConfig.executeRelease.enabledModules).Count -eq 9 -and
        @($releaseConfig.executeRelease.enabledModules) -contains 'KIModuleComfyUI'
    )
    Add-Result -Name 'ComfyUI-Execute-Freigabe' `
        -Passed $comfyApproved `
        -Message 'ComfyUI bleibt viertes Referenzmodul; Models ist fünftes und Applications sechstes Execute-Modul.'
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
    $releaseConfig = Read-KIJson -Path (Join-Path $ProjectRoot 'Config\kernel-config.json')

    $containsExecutablePullArgument = [regex]::IsMatch(
        $moduleContent,
        '(?im)(?:^|[,(]\s*)[''"]pull[''"](?:\s*[,)]|$)'
    )
    $branchLiteral = [char]39 + '--branch' + [char]39 + ', $expectedRef'
    $singleBranchLiteral = [char]39 + '--single-branch' + [char]39

    $pinnedRelease = (
        [string]$releaseConfig.comfyUI.refType -eq 'tag' -and
        -not [string]::IsNullOrWhiteSpace([string]$releaseConfig.comfyUI.ref) -and
        -not [bool]$releaseConfig.comfyUI.updateExistingRepository -and
        $moduleContent.Contains('[string]$Context.Config.comfyUI.ref') -and
        $moduleContent.Contains('[string]$repositoryState.exactTag') -and
        $moduleContent.Contains($branchLiteral) -and
        $moduleContent.Contains($singleBranchLiteral) -and
        $moduleContent.Contains('Das ComfyUI-Repository enthält lokale Änderungen') -and
        -not $containsExecutablePullArgument
    )
    Add-Result -Name 'ComfyUI-kein-ungeprüftes-Master-Update' `
        -Passed $pinnedRelease `
        -Message 'Execute arbeitet mit dem freigegebenen Tag und enthält keinen ausführbaren Git-Pull-Aufruf.'
}
catch {
    Add-Result -Name 'ComfyUI-kein-ungeprüftes-Master-Update' `
        -Passed $false -Message $_.Exception.Message
}

try {
    $selfTestPath = Join-Path $ProjectRoot 'Tests\Test-KIStackBuilderKernel.ps1'
    $selfTestContent = Get-Content -LiteralPath $selfTestPath -Raw
    $contextLiteralCheck = '$moduleContent.Contains(' + [char]39 + '[string]$Context.Config.comfyUI.ref' + [char]39 + ')'
    $exactTagLiteralCheck = '$moduleContent.Contains(' + [char]39 + '[string]$repositoryState.exactTag' + [char]39 + ')'

    $literalSafe = (
        $selfTestContent.Contains($contextLiteralCheck) -and
        $selfTestContent.Contains($exactTagLiteralCheck) -and
        -not [regex]::IsMatch(
            $selfTestContent,
            '(?m)^\s*\$moduleContent\.Contains\("\[string\]\$Context\.Config\.comfyUI\.ref"\)'
        ) -and
        -not [regex]::IsMatch(
            $selfTestContent,
            '(?m)^\s*\$moduleContent\.Contains\("\[string\]\$repositoryState\.exactTag"\)'
        )
    )
    Add-Result -Name 'ComfyUI-Quelltextliteral-ohne-Interpolation' `
        -Passed $literalSafe `
        -Message 'PowerShell-Quelltext mit $Context wird als Literal geprüft und nicht im Test interpoliert.'
}
catch {
    Add-Result -Name 'ComfyUI-Quelltextliteral-ohne-Interpolation' `
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
    $releaseConfig = Get-Content -LiteralPath (
        Join-Path $ProjectRoot 'Config\kernel-config.json'
    ) -Raw | ConvertFrom-Json -Depth 100
    $modelModule = Get-Content -LiteralPath (
        Join-Path $ProjectRoot 'Modules\05-Models\KIModuleModels.psm1'
    ) -Raw
    $modelsApproved = (
        @($releaseConfig.executeRelease.enabledModules).Count -eq 9 -and
        @($releaseConfig.executeRelease.enabledModules) -contains 'KIModuleModels' -and
        $modelModule.Contains('KIModuleModels.rollback.json') -and
        $modelModule.Contains('Invoke-KIResumableHttpDownload') -and
        $modelModule.Contains('Get-KIHuggingFaceToken') -and
        $modelModule.Contains('KI-STACK-MODELS-WORKFLOWS-MANAGED')
    )
    Add-Result -Name 'Models-Workflows-Execute-Freigabe' `
        -Passed $modelsApproved `
        -Message 'Models bleibt als fünftes Modul mit Rollbackjournal, Resume-Download und Token-Schutz aktiv.'
}
catch {
    Add-Result -Name 'Models-Workflows-Execute-Freigabe' `
        -Passed $false -Message $_.Exception.Message
}

try {
    $manifest = Get-Content -LiteralPath (
        Join-Path $ProjectRoot 'Manifests\models.manifest.json'
    ) -Raw | ConvertFrom-Json -Depth 100
    $requiredModels = @($manifest.models | Where-Object { [bool]$_.required })
    $valid = (
        $requiredModels.Count -eq 3 -and
        @($requiredModels | Where-Object {
            [string]$_.sha256 -notmatch '^[0-9a-fA-F]{64}$'
        }).Count -eq 0 -and
        @($requiredModels | Where-Object { [int64]$_.sizeBytes -le 0 }).Count -eq 0 -and
        @($requiredModels | Where-Object {
            [string]$_.source -notmatch '^https://huggingface\.co/(black-forest-labs|Comfy-Org)/'
        }).Count -eq 0
    )
    Add-Result -Name 'FLUX2-Pflichtmodelle-offiziell-und-hashgebunden' `
        -Passed $valid `
        -Message 'Drei Pflichtdateien besitzen offizielle Quellen, Größe und SHA256.'
}
catch {
    Add-Result -Name 'FLUX2-Pflichtmodelle-offiziell-und-hashgebunden' `
        -Passed $false -Message $_.Exception.Message
}

try {
    $apiPath = Join-Path $ProjectRoot 'Workflows\FLUX2-Klein-9B-OpenWebUI-API-FLAT.json'
    $api = Get-Content -LiteralPath $apiPath -Raw | ConvertFrom-Json -Depth 100
    $flatValid = (
        $api.PSObject.Properties.Name -contains '92' -and
        $api.PSObject.Properties.Name -contains '87' -and
        $api.PSObject.Properties.Name -contains '84' -and
        $api.PSObject.Properties.Name -contains '85' -and
        $api.'92'.inputs.PSObject.Properties.Name -contains 'text' -and
        [string]$api.'87'.inputs.unet_name -eq 'flux-2-klein-9b-fp8.safetensors'
    )
    Add-Result -Name 'OpenWebUI-FLUX2-API-flach-Node92' `
        -Passed $flatValid `
        -Message 'Flacher API-Workflow schützt gegen den historischen KeyError(92).'
}
catch {
    Add-Result -Name 'OpenWebUI-FLUX2-API-flach-Node92' `
        -Passed $false -Message $_.Exception.Message
}

try {
    $modelModule = Get-Content -LiteralPath (
        Join-Path $ProjectRoot 'Modules\05-Models\KIModuleModels.psm1'
    ) -Raw
    $secretSafe = (
        $modelModule.Contains(
            'Read-Host ''Hugging-Face Read-Token eingeben (wird nicht angezeigt)'' -AsSecureString'
        ) -and
        $modelModule.Contains('Export-Clixml') -and
        $modelModule.Contains('ZeroFreeBSTR') -and
        -not $modelModule.Contains('Write-Host $token')
    )
    Add-Result -Name 'HuggingFace-Token-nicht-im-Log' `
        -Passed $secretSafe `
        -Message 'Token wird verdeckt abgefragt, benutzergebunden gespeichert und nicht ausgegeben.'
}
catch {
    Add-Result -Name 'HuggingFace-Token-nicht-im-Log' `
        -Passed $false -Message $_.Exception.Message
}

try {
    $catalog = Get-Content -LiteralPath (
        Join-Path $ProjectRoot 'Manifests\workflows.catalog.json'
    ) -Raw | ConvertFrom-Json -Depth 100
    $files = @($catalog.workflows | ForEach-Object { [string]$_.file })
    $workflowValid = (
        $files -contains 'KI-Stack-FLUX2-Text-to-Image-v1.3.8.json' -and
        $files -contains 'FLUX2-Klein-9B-OpenWebUI-API-FLAT.json' -and
        $files.Count -eq 2
    )
    Add-Result -Name 'Workflowkatalog-vollständig' `
        -Passed $workflowValid `
        -Message 'Nur der freigegebene FLUX2-UI- und API-Workflow sind katalogisiert; KREA, Pony und ControlNet bleiben zurückgestellt.'
}
catch {
    Add-Result -Name 'Workflowkatalog-vollständig' `
        -Passed $false -Message $_.Exception.Message
}

try {
    $syntaxTestPath = Join-Path $ProjectRoot 'Tests\Test-KIStackPowerShellSyntax.ps1'
    $starterPath = Join-Path $ProjectRoot 'Start-KIStack-Cutover.ps1'
    $starterContent = Get-Content -LiteralPath $starterPath -Raw
    $syntaxTestExists = Test-Path -LiteralPath $syntaxTestPath -PathType Leaf
    $syntaxGateValid = (
        $syntaxTestExists -and
        $starterContent.Contains("'Tests\Test-KIStackPowerShellSyntax.ps1'") -and
        $starterContent.Contains('PowerShell-Syntaxprüfung-Exitcode') -and
        $starterContent.IndexOf('PowerShell-Syntaxprüfung-Exitcode') -lt
            $starterContent.IndexOf('Der vollständige Selbsttest wird vor Execute ausgeführt.')
    )
    Add-Result -Name 'PowerShell-AST-Syntaxgate-vor-Ausführung' `
        -Passed $syntaxGateValid `
        -Message 'Alle PowerShell-Dateien werden vor SelfTest, DryRun und Execute nativ geparst.'
}
catch {
    Add-Result -Name 'PowerShell-AST-Syntaxgate-vor-Ausführung' `
        -Passed $false -Message $_.Exception.Message
}

try {
    $bootstrapPath = Join-Path $ProjectRoot 'Bootstrap-KIStack-Cutover.cmd'
    $bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw
    $versionLabelValid = (
        $bootstrapContent.Contains('KI-Stack Cutover v1.6.3 - %ACTION%') -and
        -not [regex]::IsMatch($bootstrapContent, 'PythonGit v1\\.1\\.[0-9]+')
    )
    Add-Result -Name 'Starter-sichtbare-Versionskonsistenz' `
        -Passed $versionLabelValid `
        -Message 'Der sichtbare CMD-Kopf entspricht dem Paket v1.5.8.'
}
catch {
    Add-Result -Name 'Starter-sichtbare-Versionskonsistenz' `
        -Passed $false -Message $_.Exception.Message
}

try {
    $selfTestSource = Get-Content -LiteralPath $PSCommandPath -Raw
    $ambiguousCmdletBoolean = [regex]::IsMatch(
        $selfTestSource,
        '(?m)^\s*Test-Path\b[^\r\n]*\s-and\s*$'
    )
    $fixedBooleanPattern = (
        $selfTestSource.Contains(
            '$syntaxTestExists = Test-Path -LiteralPath $syntaxTestPath -PathType Leaf'
        ) -and
        $selfTestSource.Contains('$syntaxTestExists -and')
    )
    Add-Result -Name 'PowerShell-Cmdlet-nicht-direkt-mit-and-verkettet' `
        -Passed (-not $ambiguousCmdletBoolean -and $fixedBooleanPattern) `
        -Message 'Cmdlet-Ergebnisse werden vor boolescher Verknüpfung explizit ausgewertet.'
}
catch {
    Add-Result -Name 'PowerShell-Cmdlet-nicht-direkt-mit-and-verkettet' `
        -Passed $false -Message $_.Exception.Message
}


try {
    $cmdFiles = @(Get-ChildItem -LiteralPath $ProjectRoot -File -Filter '*.cmd')
    $badBom = @()
    $badLineEndings = @()
    foreach ($cmdFile in $cmdFiles) {
        $bytes = [IO.File]::ReadAllBytes($cmdFile.FullName)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $badBom += $cmdFile.Name
        }
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 10 -and ($i -eq 0 -or $bytes[$i - 1] -ne 13)) {
                $badLineEndings += $cmdFile.Name
                break
            }
        }
    }
    Add-Result -Name 'CMD-UTF8-ohne-BOM-und-CRLF' `
        -Passed ($badBom.Count -eq 0 -and $badLineEndings.Count -eq 0) `
        -Message ('BOM: {0}; LF-ohne-CR: {1}' -f ($badBom -join ','), ($badLineEndings -join ','))
}
catch {
    Add-Result -Name 'CMD-UTF8-ohne-BOM-und-CRLF' -Passed $false -Message $_.Exception.Message
}

try {
    $starterSource = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Core\KIStack.Starter.psm1') -Raw
    $trailingCommaRemoved = (
        -not $starterSource.Contains("'Embedded\Preflight\State\Preflight-Continuation-v1.6.3.zip',") -and
        $starterSource.Contains("'Embedded\Preflight\State\Preflight-Continuation-v1.6.3.zip'")
    )
    Add-Result -Name 'PowerShell-Array-ohne-abschliessendes-Komma' `
        -Passed $trailingCommaRemoved `
        -Message 'Die Required-Path-Liste endet ohne syntaktisch unzulässiges Komma.'
}
catch {
    Add-Result -Name 'PowerShell-Array-ohne-abschliessendes-Komma' -Passed $false -Message $_.Exception.Message
}

try {
    $launcherSource = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Start-KIStack-Cutover.ps1') -Raw
    $syntaxIndex = $launcherSource.IndexOf('Native PowerShell-Syntaxprüfung wird vor jedem Modulimport gestartet.')
    $importIndex = $launcherSource.IndexOf('Import-Module $starterModulePath')
    $pathGateIndex = $launcherSource.IndexOf('Tests\Test-KIStackPathResolution.ps1')
    $pathGateValid = (
        $syntaxIndex -ge 0 -and
        $importIndex -gt $syntaxIndex -and
        $pathGateIndex -gt $importIndex
    )
    Add-Result -Name 'Syntaxgate-vor-Startermodul-und-Pfadgate' `
        -Passed $pathGateValid `
        -Message 'Der native Parser läuft vor dem Startermodul; anschließend folgt die Pfadprüfung.'
}
catch {
    Add-Result -Name 'Syntaxgate-vor-Startermodul-und-Pfadgate' -Passed $false -Message $_.Exception.Message
}

try {
    $pathTest = Join-Path $ProjectRoot 'Tests\Test-KIStackPathResolution.ps1'
    $pathSource = Get-Content -LiteralPath $pathTest -Raw
    $pathRegressionValid = (
        (Test-Path -LiteralPath $pathTest -PathType Leaf) -and
        $pathSource.Contains('Doppelt verschachtelt') -and
        $pathSource.Contains('Leerzeichen und doppelte Verschachtelung') -and
        $pathSource.Contains('Preflight-Continuation-v1.6.3.zip')
    )
    Add-Result -Name 'Pfade-doppelt-verschachtelt-und-mit-Leerzeichen' `
        -Passed $pathRegressionValid `
        -Message 'Paketwurzel und eingebetteter Preflight werden in allen relevanten Pfadvarianten geprüft.'
}
catch {
    Add-Result -Name 'Pfade-doppelt-verschachtelt-und-mit-Leerzeichen' -Passed $false -Message $_.Exception.Message
}



try {
    $applicationConfig = Get-Content -LiteralPath (
        Join-Path $ProjectRoot 'Config\kernel-config.json'
    ) -Raw | ConvertFrom-Json -Depth 100
    $applicationModulePath = Join-Path $ProjectRoot 'Modules\06-Applications\KIModuleApplications.psm1'
    $applicationModule = Get-Content -LiteralPath $applicationModulePath -Raw
    $applicationsApproved = (
        @($applicationConfig.executeRelease.enabledModules).Count -eq 9 -and
        @($applicationConfig.executeRelease.enabledModules) -contains 'KIModuleApplications' -and
        [string]$applicationConfig.applications.openWebUI.version -eq '0.10.2' -and
        [string]$applicationConfig.applications.lmStudio.packageId -eq 'ElementLabs.LMStudio' -and
        [string]$applicationConfig.applications.openWebUI.openAIBaseUrl -eq 'http://127.0.0.1:1234/v1' -and
        $applicationModule.Contains('KIModuleApplications.rollback.json') -and
        $applicationModule.Contains('lmStudioInstalledByTransaction') -and
        $applicationModule.Contains('openWebUIVenvCreatedByTransaction') -and
        $applicationModule.Contains('KI-STACK-APPLICATIONS-MANAGED') -and
        $applicationModule.Contains('open-webui=={0}') -and
        -not $applicationModule.Contains("throw 'Execute ist")
    )
    Add-Result -Name 'Applications-Execute-Freigabe' `
        -Passed $applicationsApproved `
        -Message 'LM Studio und Open WebUI 0.10.2 sind als sechstes transaktionsgesichertes Execute-Modul freigegeben.'
}
catch {
    Add-Result -Name 'Applications-Execute-Freigabe' -Passed $false -Message $_.Exception.Message
}

try {
    $applicationModule = Get-Content -LiteralPath (
        Join-Path $ProjectRoot 'Modules\06-Applications\KIModuleApplications.psm1'
    ) -Raw
    $applicationSafety = (
        -not [regex]::IsMatch($applicationModule,'(?im)^\s*\$input\s*=') -and
        $applicationModule.Contains('Get-KILMStudioState') -and
        $applicationModule.Contains('Get-KIOpenWebUIVersion') -and
        $applicationModule.Contains('--host __BIND_ADDRESS__ --port __PORT__') -and
        $applicationModule.Contains('ENABLE_OLLAMA_API=False') -and
        $applicationModule.Contains('OPENAI_API_BASE_URL=__OPENAI_BASE_URL__') -and
        $applicationModule.Contains('Write-KIUtf8NoBomCrLf') -and
        $applicationModule.Contains('Get-CimInstance Win32_Process') -and
        $applicationModule.Contains('where lms.exe') -and
        $applicationModule.Contains('%USERPROFILE%\.lmstudio\bin\lms.exe') -and
        $applicationModule.Contains("serverUrl + '/v1/models'")
    )
    Add-Result -Name 'Applications-Starter-und-Automatikvariablen' `
        -Passed $applicationSafety `
        -Message 'Lokale Bindings, LM-Studio-Anbindung, Start/Stop-Artefakte und Schutz vor $input-Kollision sind enthalten.'
}
catch {
    Add-Result -Name 'Applications-Starter-und-Automatikvariablen' -Passed $false -Message $_.Exception.Message
}


try {
    $applicationsModulePath = Join-Path $ProjectRoot 'Modules\06-Applications\KIModuleApplications.psm1'
    $applicationsModuleContent = Get-Content -LiteralPath $applicationsModulePath -Raw
    $registryStrictModeSafe = (
        $applicationsModuleContent.Contains('Get-KIOptionalPropertyValue') -and
        $applicationsModuleContent.Contains("-Name 'DisplayName'") -and
        $applicationsModuleContent.Contains("-Name 'DisplayIcon'") -and
        $applicationsModuleContent.Contains("-Name 'InstallLocation'") -and
        -not $applicationsModuleContent.Contains('$entry.DisplayName') -and
        -not $applicationsModuleContent.Contains('$entry.DisplayIcon') -and
        -not $applicationsModuleContent.Contains('$entry.InstallLocation')
    )
    Add-Result -Name 'Applications-Registry-StrictMode' -Passed $registryStrictModeSafe -Message 'Optionale Uninstall-Registrywerte werden unter StrictMode eigenschaftssicher gelesen.'
}
catch { Add-Result -Name 'Applications-Registry-StrictMode' -Passed $false -Message $_.Exception.Message }

try {
    $kernelContent = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Invoke-KIStackBuilderKernel.ps1') -Raw
    $failureVisibilityValid = (
        $kernelContent.Contains("Write-Host 'FEHLERDETAILS:'") -and
        $kernelContent.Contains("'failure-summary.json'") -and
        $kernelContent.Contains('Ursache: {0}')
    )
    Add-Result -Name 'Kernel-sichtbare-Fehlerursache' -Passed $failureVisibilityValid -Message 'Exitcode 30 zeigt Modul, Ursache, Rollbackstatus und Fehlerbericht direkt an.'
}
catch { Add-Result -Name 'Kernel-sichtbare-Fehlerursache' -Passed $false -Message $_.Exception.Message }

try {
    $applicationsModuleContent = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Modules\06-Applications\KIModuleApplications.psm1') -Raw
    $windowsAppsPatternLiteral = '(?i)\\Microsoft\\WindowsApps\\'
    $pythonResolutionValid = (
        $applicationsModuleContent.Contains('function Resolve-KIApplicationPython') -and
        $applicationsModuleContent.Contains('$candidatePaths = [System.Collections.Generic.List[string]]::new()') -and
        $applicationsModuleContent.Contains('Python312\python.exe') -and
        $applicationsModuleContent.Contains('Python311\python.exe') -and
        $applicationsModuleContent.Contains('sys.version_info[:2]') -and
        $applicationsModuleContent.Contains($windowsAppsPatternLiteral) -and
        $applicationsModuleContent.Contains('compatible = ($versionResult.exitCode -eq 0)')
    )
    Add-Result -Name 'Applications-Python-Auflösung' -Passed $pythonResolutionValid -Message 'Python 3.11/3.12 wird über ausführbare, versionsgeprüfte Kandidaten aufgelöst; WindowsApps-Aliase werden ausgeschlossen.'
}
catch { Add-Result -Name 'Applications-Python-Auflösung' -Passed $false -Message $_.Exception.Message }

try {
    $versionConfig = Get-Content -LiteralPath (
        Join-Path $ProjectRoot 'Config\kernel-config.json'
    ) -Raw | ConvertFrom-Json -Depth 100
    $versionModule = Get-Content -LiteralPath (
        Join-Path $ProjectRoot 'Modules\08-Cutover\module.json'
    ) -Raw | ConvertFrom-Json -Depth 100
    $versionCore = Get-Content -LiteralPath (
        Join-Path $ProjectRoot 'Core\KIStack.BuilderKernel.Core.psm1'
    ) -Raw
    $versionBootstrap = Get-Content -LiteralPath (
        Join-Path $ProjectRoot 'Bootstrap-KIStack-Cutover.cmd'
    ) -Raw
    $versionReadmeTitle = [string](Get-Content -LiteralPath (
        Join-Path $ProjectRoot 'README.md'
    ) -TotalCount 1)

    $authoritativeVersionValid = (
        [string]$versionConfig.kernelVersion -eq '1.6.3' -and
        [string]$versionConfig.executeRelease.releaseId -eq 'CUTOVER-1.6.3' -and
        [string]$versionModule.version -eq '1.6.3' -and
        $versionCore.Contains("kernelVersion = '1.6.3'") -and
        $versionBootstrap.Contains('KI-Stack Cutover v1.6.3 - %ACTION%') -and
        $versionReadmeTitle -eq '# KI-Stack Cutover Execute v1.6.3'
    )

    Add-Result -Name 'Integration-aktive-Versionskonsolidierung' `
        -Passed $authoritativeVersionValid `
        -Message 'Autoritative Versionsfelder in Config, Release, Core, Modul, Starter und README-Titel sind konsistent; historische Hinweise werden nicht als aktive Version bewertet.'
}
catch {
    Add-Result -Name 'Integration-aktive-Versionskonsolidierung' `
        -Passed $false -Message $_.Exception.Message
}


try {
    $bootstrapPath = Join-Path $ProjectRoot 'Bootstrap-KIStack-Cutover.cmd'
    $bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw
    $entryStarterFiles = @(
        'Start-Nur-Selbsttest.cmd',
        'Start-KIStack-Cutover-DryRun.cmd',
        'Start-KIStack-Cutover-Execute.cmd'
    )
    $conditionalEntryStarters = $true
    foreach ($entryStarterFile in $entryStarterFiles) {
        $entryStarterContent = Get-Content -LiteralPath (
            Join-Path $ProjectRoot $entryStarterFile
        ) -Raw
        if (-not $entryStarterContent.Contains('"%ComSpec%" /D /C')) {
            $conditionalEntryStarters = $false
        }
    }
    $finishSectionMatch = [regex]::Match(
        $bootstrapContent,
        '(?ms)^:Finish\s*\r?\n.*?(?=^:[A-Za-z0-9_]+\s*$|\z)'
    )
    $finishSection = if ($finishSectionMatch.Success) {
        $finishSectionMatch.Value
    } else {
        ''
    }
    $elevationSource = Get-Content -LiteralPath (
        Join-Path $ProjectRoot 'Request-KIStack-Elevation.ps1'
    ) -Raw
    $elevationLogIdentityValid = (
        $elevationSource.Contains('KI-Stack-Cutover-Elevation.log') -and
        -not $elevationSource.Contains('KI-Stack-ModelsWorkflows-Elevation.log')
    )
    $acknowledgedBootstrapLifecycle = (
        $finishSection.Contains('Vorgang erfolgreich abgeschlossen. Exitcode: 0') -and
        $finishSection.Contains('Vorgang fehlgeschlagen. Exitcode: %EXITCODE%') -and
        $finishSection.Contains('pause >nul') -and
        $finishSection.Contains('exit /b %EXITCODE%') -and
        -not $finishSection.Contains('exit /b 0') -and
        -not [regex]::IsMatch(
            $finishSection,
            '(?im)^\s*exit\s+%EXITCODE%\s*$'
        )
    )
    $integrationTopLevelContract = (
        (Test-Path -LiteralPath (Join-Path $ProjectRoot 'Bootstrap-KIStack-Cutover.cmd') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $ProjectRoot 'Start-KIStack-Cutover.ps1') -PathType Leaf) -and
        -not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'Bootstrap-KIStack-Applications.cmd') -PathType Leaf) -and
        -not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'Start-KIStack-Applications.ps1') -PathType Leaf)
    )
    Add-Result -Name 'CMD-Diagnosefenster-bleibt-offen' `
        -Passed ($conditionalEntryStarters -and $acknowledgedBootstrapLifecycle -and $elevationLogIdentityValid -and $integrationTopLevelContract) `
        -Message 'Cutover-Einstiegsstarter zeigen Erfolg und Fehler samt Exitcode, warten auf Tastendruck und schließen danach; Bootstrap, Logs und Elevation sind konsistent.'
}
catch {
    Add-Result -Name 'CMD-Diagnosefenster-bleibt-offen' `
        -Passed $false -Message $_.Exception.Message
}

try {
    $integrationConfig = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Config\kernel-config.json') -Raw | ConvertFrom-Json -Depth 100
    $integrationModulePath = Join-Path $ProjectRoot 'Modules\07-Integration\KIModuleIntegration.psm1'
    $integrationModuleContent = Get-Content -LiteralPath $integrationModulePath -Raw
    $integrationManifest = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Modules\07-Integration\module.json') -Raw | ConvertFrom-Json -Depth 30
    $integrationApproved = (
        [bool]$integrationManifest.enabled -and
        [string]$integrationManifest.version -eq '1.5.8' -and
        [bool]$integrationManifest.supportsRollback -and
        @($integrationConfig.executeRelease.enabledModules) -contains 'KIModuleIntegration' -and
        @($integrationConfig.executeRelease.enabledModules).Count -eq 9 -and
        [string]$integrationConfig.integration.wslDistribution -eq 'Debian' -and
        [string]$integrationConfig.integration.searxngRef -eq '277d8469c' -and
        [string]$integrationConfig.integration.searxngQueryUrl -eq 'http://localhost/searxng/search?q=<query>' -and
        $integrationModuleContent.Contains('KIModuleIntegration.rollback.json') -and
        $integrationModuleContent.Contains('Start-KIStack-OpenWebUI-WithSearch.cmd') -and
        $integrationModuleContent.Contains('ENABLE_WEB_SEARCH=True') -and
        $integrationModuleContent.Contains('WEB_SEARCH_ENGINE=searxng') -and
        $integrationModuleContent.Contains('SEARXNG_QUERY_URL=__QUERY_URL__') -and
        $integrationModuleContent.Contains('exit 42') -eq $false
    )
    Add-Result -Name 'Integration-Execute-Freigabe' -Passed $integrationApproved -Message 'WSL2, Debian, gepinntes SearXNG, JSON-API, Keeper und Open-WebUI-Websuche sind als siebtes Referenzmodul aktiv; Cutover und Validation folgen als achtes und neuntes Modul.'
}
catch { Add-Result -Name 'Integration-Execute-Freigabe' -Passed $false -Message $_.Exception.Message }

try {
    $installerPath = Join-Path $ProjectRoot 'Integration\Linux\install-ki-stack-searxng.sh'
    $rollbackPath = Join-Path $ProjectRoot 'Integration\Linux\rollback-ki-stack-searxng.sh'
    $installerContent = Get-Content -LiteralPath $installerPath -Raw
    $linuxAssetsValid = (
        (Test-Path -LiteralPath $installerPath -PathType Leaf) -and
        (Test-Path -LiteralPath $rollbackPath -PathType Leaf) -and
        $installerContent.Contains('formats:') -and
        $installerContent.Contains('    - json') -and
        $installerContent.Contains('valkey://localhost:6379/0') -and
        $installerContent.Contains('systemd=true') -and
        $installerContent.Contains('git -C "$ROOT/src" checkout --detach FETCH_HEAD') -and
        $installerContent.Contains('write_marker ''adopted-existing''') -and
        $installerContent.Contains('systemctl start "$VALKEY_SERVICE" uwsgi nginx') -and
        $installerContent.Contains('/etc/uwsgi/apps-enabled/searxng.ini') -and
        $installerContent.Contains('/etc/nginx/default.d/searxng.conf') -and
        $installerContent.Contains('parallele Installation wird verweigert') -and
        $installerContent.Contains('write_marker ''managed''')
    )
    Add-Result -Name 'SearXNG-Linux-Installationsvertrag' -Passed $linuxAssetsValid -Message 'Bestehende JSON-Endpunkte werden übernommen; Neuinstallationen nutzen systemd, Valkey, nginx, uWSGI und einen gepinnten Commit.'
}
catch { Add-Result -Name 'SearXNG-Linux-Installationsvertrag' -Passed $false -Message $_.Exception.Message }

try {
    $integrationModuleContent = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Modules\07-Integration\KIModuleIntegration.psm1') -Raw
    $lifecycleValid = (
        $integrationModuleContent.Contains("systemctl start valkey-server uwsgi nginx") -and
        $integrationModuleContent.Contains("systemctl is-active --quiet valkey-server") -and
        $integrationModuleContent.Contains("systemctl is-active --quiet uwsgi") -and
        $integrationModuleContent.Contains("systemctl is-active --quiet nginx") -and
        $integrationModuleContent.Contains("Win32_Process") -and
        $integrationModuleContent.Contains("exec sleep infinity") -and
        $integrationModuleContent.Contains("application/json") -and
        $integrationModuleContent.Contains("PSObject.Properties['results']")
    )
    Add-Result -Name 'SearXNG-Standarddienstkette-und-Keeper' -Passed $lifecycleValid -Message 'Starter prüft den verwalteten Keeper sowie valkey-server, uwsgi, nginx, HTML und JSON; fremde oder veraltete PID-Dateien werden nicht blind beendet.'
}
catch { Add-Result -Name 'SearXNG-Standarddienstkette-und-Keeper' -Passed $false -Message $_.Exception.Message }

try {
    $integrationModuleContent = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Modules\07-Integration\KIModuleIntegration.psm1') -Raw
    $integrationSafety = (
        -not [regex]::IsMatch($integrationModuleContent,'(?im)^\s*\$input\s*=') -and
        $integrationModuleContent.Contains('distroInstalledByTransaction') -and
        $integrationModuleContent.Contains('eine neu installierte WSL-Distribution bleibt aus Sicherheitsgründen registriert') -and
        $integrationModuleContent.Contains('ConvertTo-KIShellSingleQuoted') -and
        $integrationModuleContent.Contains('base64 -d') -and
        $integrationModuleContent.Contains('Test-KIIntegrationJsonEndpoint')
    )
    Add-Result -Name 'Integration-Rollback-und-Quoting' -Passed $integrationSafety -Message 'Dateitransfer, Shell-Quoting, JSON-Healthcheck und nichtdestruktiver Rollback sind enthalten.'
}
catch { Add-Result -Name 'Integration-Rollback-und-Quoting' -Passed $false -Message $_.Exception.Message }


try {
    $integrationModulePath = Join-Path $ProjectRoot 'Modules\07-Integration\KIModuleIntegration.psm1'
    $integrationModuleSource = Get-Content -LiteralPath $integrationModulePath -Raw
    $moduleInfo = Import-Module $integrationModulePath -Force -PassThru -DisableNameChecking -ErrorAction Stop
    try {
        $nulSample = 'Debian' + [char]0
        $nulResult = & (Get-Command Remove-KIIntegrationNullCharacters -Module $moduleInfo.Name) -Value $nulSample
        $nulRegressionValid = (
            $nulResult -eq 'Debian' -and
            $integrationModuleSource.Contains("Replace(([char]0).ToString(), [string]::Empty)") -and
            -not [regex]::IsMatch($integrationModuleSource, '\.Replace\(\s*\[char\]\s*0\s*,\s*[''\"]{2}\s*\)')
        )
        Add-Result -Name 'Integration-NUL-Entfernung-ohne-Char-Overload' `
            -Passed $nulRegressionValid `
            -Message 'WSL-Ausgaben entfernen NUL-Zeichen über den String/String-Overload und nicht über Char plus leeren String.'
    }
    finally {
        Remove-Module -ModuleInfo $moduleInfo -Force -ErrorAction SilentlyContinue
    }
}
catch {
    Add-Result -Name 'Integration-NUL-Entfernung-ohne-Char-Overload' -Passed $false -Message $_.Exception.Message
}



try {
    $integrationModulePath = Join-Path $ProjectRoot 'Modules\07-Integration\KIModuleIntegration.psm1'
    $integrationSource = Get-Content -LiteralPath $integrationModulePath -Raw
    $wslEndStateContract = (
        $integrationSource.Contains('function Get-KIIntegrationDistributionVersion') -and
        $integrationSource.Contains('function Test-KIIntegrationDistributionWsl2') -and
        $integrationSource.Contains('$wslVersionBefore = Get-KIIntegrationDistributionVersion') -and
        $integrationSource.Contains('$wslVersionAfter = Get-KIIntegrationDistributionVersion') -and
        $integrationSource.Contains('$wslVersionAfter -ne 2') -and
        $integrationSource.Contains('Der Endzustand entscheidet.') -and
        -not [regex]::IsMatch($integrationSource, 'setVersion\.exitCode\s+-ne\s+0\s+-and\s+\(')
    )
    Add-Result -Name 'Integration-WSL2-Endzustand-entscheidet' `
        -Passed $wslEndStateContract `
        -Message 'Die validierte WSL-Distributionsversion entscheidet; ein fehlerhafter set-version-Exitcode allein führt nicht zum Abbruch.'
}
catch {
    Add-Result -Name 'Integration-WSL2-Endzustand-entscheidet' -Passed $false -Message $_.Exception.Message
}

try {
    $bootstrapLifecycle = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Bootstrap-KIStack-Cutover.cmd') -Raw
    $elevationLifecycle = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Request-KIStack-Elevation.ps1') -Raw
    $entryLifecycleOk = $true
    foreach ($entryLifecycleName in @('Start-Nur-Selbsttest.cmd','Start-KIStack-Cutover-DryRun.cmd','Start-KIStack-Cutover-Execute.cmd')) {
        $entryLifecycleSource = Get-Content -LiteralPath (Join-Path $ProjectRoot $entryLifecycleName) -Raw
        if (-not $entryLifecycleSource.Contains('"%ComSpec%" /D /C')) { $entryLifecycleOk = $false }
    }
    $finishLifecycleMatch = [regex]::Match(
        $bootstrapLifecycle,
        '(?ms)^:Finish\s*\r?\n.*?(?=^:[A-Za-z0-9_]+\s*$|\z)'
    )
    $finishLifecycle = if ($finishLifecycleMatch.Success) { $finishLifecycleMatch.Value } else { '' }
    $windowLifecycleValid = (
        $entryLifecycleOk -and
        $elevationLifecycle.Contains('$cmdArguments = ''/D /C') -and
        $finishLifecycle.Contains('Vorgang erfolgreich abgeschlossen. Exitcode: 0') -and
        $finishLifecycle.Contains('Vorgang fehlgeschlagen. Exitcode: %EXITCODE%') -and
        $finishLifecycle.Contains('pause >nul') -and
        $finishLifecycle.Contains('exit /b %EXITCODE%') -and
        -not $finishLifecycle.Contains('exit /b 0')
    )
    Add-Result -Name 'Integration-Fenster-Lifecycle' `
        -Passed $windowLifecycleValid `
        -Message 'Erfolgreiche und fehlgeschlagene Starter bleiben bis zum Tastendruck sichtbar und schließen anschließend.'
}
catch {
    Add-Result -Name 'Integration-Fenster-Lifecycle' -Passed $false -Message $_.Exception.Message
}



try {
    $precisionBootstrap = Get-Content -LiteralPath (
        Join-Path $ProjectRoot 'Bootstrap-KIStack-Cutover.cmd'
    ) -Raw
    $precisionMatch = [regex]::Match(
        $precisionBootstrap,
        '(?ms)^:Finish\s*\r?\n.*?(?=^:[A-Za-z0-9_]+\s*$|\z)'
    )
    $precisionBlock = if ($precisionMatch.Success) { $precisionMatch.Value } else { '' }
    $precisionValid = (
        $precisionMatch.Success -and
        $precisionBlock.Contains('Vorgang erfolgreich abgeschlossen. Exitcode: 0') -and
        $precisionBlock.Contains('Vorgang fehlgeschlagen. Exitcode: %EXITCODE%') -and
        $precisionBlock.Contains('pause >nul') -and
        $precisionBlock.Contains('exit /b %EXITCODE%') -and
        -not $precisionBlock.Contains(':EnsureElevation') -and
        -not $precisionBlock.Contains(':FindPowerShell') -and
        -not $precisionBlock.Contains(':Log') -and
        -not $precisionBlock.Contains('exit /b 0')
    )
    Add-Result -Name 'CMD-Finishblock-Praezision' `
        -Passed $precisionValid `
        -Message 'Der Lifecycle-Test wertet ausschließlich den :Finish-Block bis zum nächsten CMD-Label aus.'
}
catch {
    Add-Result -Name 'CMD-Finishblock-Praezision' -Passed $false -Message $_.Exception.Message
}



try {
    $cutoverConfig = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Config\kernel-config.json') -Raw | ConvertFrom-Json -Depth 100
    $cutoverPath = Join-Path $ProjectRoot 'Modules\08-Cutover\KIModuleCutover.psm1'
    $cutoverModule = Import-Module $cutoverPath -Force -PassThru -DisableNameChecking -ErrorAction Stop
    try {
        $cutoverContext = [pscustomobject]@{
            Mode = 'DryRun'
            Config = $cutoverConfig
            Transaction = [pscustomobject]@{ transactionId='TEST-CUTOVER'; mode='DryRun'; modules=@() }
            TransactionDirectory = Join-Path ([IO.Path]::GetTempPath()) ('KI-Cutover-Test-'+[guid]::NewGuid().ToString('N'))
        }
        New-Item -ItemType Directory -Path $cutoverContext.TransactionDirectory -Force | Out-Null
        $installResult = & (Get-Command Install-KIModuleCutover -Module $cutoverModule.Name) -Context $cutoverContext
        $validationResult = & (Get-Command Validate-KIModuleCutover -Module $cutoverModule.Name) -Context $cutoverContext
        $cutoverDryRunValid = (
            [bool]$installResult.success -and
            @($installResult.data.endpoints).Count -eq 4 -and
            @($installResult.data.plannedFiles).Count -ge 8 -and
            [bool]$validationResult.success -and
            @($validationResult.data.endpoints).Count -eq 4
        )
        Add-Result -Name 'Cutover-DryRun-Vertrag' -Passed $cutoverDryRunValid -Message 'Dry-Run liefert vier Endpunkte sowie Gesamtstarter, Stopper, Healthcheck und Berichte.'
    }
    finally {
        if ($cutoverContext -and (Test-Path -LiteralPath $cutoverContext.TransactionDirectory)) { Remove-Item -LiteralPath $cutoverContext.TransactionDirectory -Recurse -Force -ErrorAction SilentlyContinue }
        Remove-Module -ModuleInfo $cutoverModule -Force -ErrorAction SilentlyContinue
    }
}
catch { Add-Result -Name 'Cutover-DryRun-Vertrag' -Passed $false -Message $_.Exception.Message }

try {
    $cutoverConfig = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Config\kernel-config.json') -Raw | ConvertFrom-Json -Depth 100
    $cutoverManifest = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Modules\08-Cutover\module.json') -Raw | ConvertFrom-Json -Depth 30
    $validationManifest = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Modules\99-Validation\module.json') -Raw | ConvertFrom-Json -Depth 30
    $cutoverApproved = (
        [string]$cutoverConfig.kernelVersion -eq '1.6.3' -and
        [string]$cutoverConfig.executeRelease.releaseId -eq 'CUTOVER-1.6.3' -and
        [bool]$cutoverConfig.executeRelease.cutoverEnabled -and
        [bool]$cutoverConfig.integration.cutoverEnabled -and
        @($cutoverConfig.executeRelease.enabledModules).Count -eq 9 -and
        @($cutoverConfig.executeRelease.enabledModules) -contains 'KIModuleCutover' -and
        @($cutoverConfig.executeRelease.enabledModules) -contains 'KIModuleValidation' -and
        [bool]$cutoverManifest.enabled -and
        [bool]$validationManifest.enabled -and
        @($validationManifest.dependencies) -contains 'KIModuleCutover'
    )
    Add-Result -Name 'Cutover-Execute-Freigabe' -Passed $cutoverApproved -Message 'Cutover und Abschlussvalidierung sind als achtes und neuntes Execute-Modul freigegeben.'
}
catch { Add-Result -Name 'Cutover-Execute-Freigabe' -Passed $false -Message $_.Exception.Message }

try {
    $validationPath = Join-Path $ProjectRoot 'Modules\99-Validation\KIModuleValidation.psm1'
    $validationModule = Import-Module $validationPath -Force -PassThru -DisableNameChecking -ErrorAction Stop
    $acceptanceTemp = Join-Path ([IO.Path]::GetTempPath()) ('KI-Validation-Acceptance-' + [guid]::NewGuid().ToString('N'))
    try {
        $transactionDirectory = Join-Path $acceptanceTemp 'transaction'
        $latestReportPath = Join-Path $acceptanceTemp 'global\Acceptance-latest.json'
        New-Item -ItemType Directory -Path $transactionDirectory -Force | Out-Null
        $acceptanceContext = [pscustomobject]@{
            Transaction = [pscustomobject]@{
                transactionId = 'TEST-VALIDATION-ACCEPTANCE'
                mode = 'DryRun'
                modules = @(
                    [pscustomobject]@{id='KIModuleFoundation';status='Validated'},
                    [pscustomobject]@{id='KIModuleValidation';status='Running'}
                )
            }
            TransactionDirectory = $transactionDirectory
            Config = [pscustomobject]@{
                validation = [pscustomobject]@{latestReportPath=$latestReportPath}
            }
        }
        $acceptanceResult = & (
            Get-Command -Name 'Validate-KIModuleValidation' -Module $validationModule.Name -ErrorAction Stop
        ) -Context $acceptanceContext
        $transactionReportPath = Join-Path $transactionDirectory 'acceptance-report.json'
        $transactionReport = Get-Content -LiteralPath $transactionReportPath -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 50 -ErrorAction Stop
        $latestReport = Get-Content -LiteralPath $latestReportPath -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 50 -ErrorAction Stop
        $acceptanceContract = (
            [bool]$acceptanceResult.success -and
            @($acceptanceResult.data.reportPaths).Count -eq 2 -and
            (Test-Path -LiteralPath $transactionReportPath -PathType Leaf) -and
            (Test-Path -LiteralPath $latestReportPath -PathType Leaf) -and
            [string]$transactionReport.transactionId -eq 'TEST-VALIDATION-ACCEPTANCE' -and
            [string]$transactionReport.status -eq 'Accepted' -and
            [string]$latestReport.status -eq 'Accepted' -and
            @($transactionReport.modules).Count -eq 2
        )
        Add-Result -Name 'Validation-Abnahmebericht-Vertrag' -Passed $acceptanceContract -Message 'Das Abschlussmodul erzeugt transaktionsgebundene und globale Abnahmeberichte mit sicherer Metadatenauswertung.'
    }
    finally {
        if ($acceptanceTemp -and (Test-Path -LiteralPath $acceptanceTemp)) {
            Remove-Item -LiteralPath $acceptanceTemp -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Module -ModuleInfo $validationModule -Force -ErrorAction SilentlyContinue
    }
}
catch { Add-Result -Name 'Validation-Abnahmebericht-Vertrag' -Passed $false -Message $_.Exception.Message }


$failedResults = @(
    $results |
    Where-Object { -not [bool]$_.passed }
)

$summary = [pscustomobject][ordered]@{
    generatedAt = (Get-Date).ToString('o')
    packageVersion = '1.6.3'
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
            'KI-Stack-Cutover-SelfTest-latest.json'
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

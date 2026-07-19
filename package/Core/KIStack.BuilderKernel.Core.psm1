Set-StrictMode -Version Latest

function Get-KIProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}

function Write-KIJson {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Path,
        [int]$Depth = 80
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $temporaryPath = '{0}.tmp' -f $Path
    $Value | ConvertTo-Json -Depth $Depth |
        Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Read-KIJson {
    param([Parameter(Mandatory)][string]$Path)

    return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop |
        ConvertFrom-Json -Depth 100 -ErrorAction Stop
}

function Get-KISha256 {
    param([Parameter(Mandatory)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Test-KIAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
    }
    catch {
        return $false
    }
}

function New-KILogEntry {
    param(
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [string]$Component = 'Kernel',
        [AllowNull()][object]$Data = $null
    )

    return [pscustomobject][ordered]@{
        timestamp = (Get-Date).ToString('o')
        level = $Level
        component = $Component
        message = $Message
        data = $Data
    }
}

function Write-KILog {
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][object]$Entry
    )

    $parent = Split-Path -Parent $LogPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $line = $Entry | ConvertTo-Json -Depth 20 -Compress
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Resolve-KIPreflightInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    $resolvedPath = (Resolve-Path -LiteralPath $InputPath -ErrorAction Stop).Path
    $extension = [IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()

    if ($extension -eq '.json') {
        $name = [IO.Path]::GetFileName($resolvedPath)
        if ($name -ne 'preflight-report.json') {
            throw 'Bei JSON-Eingabe wird preflight-report.json erwartet.'
        }

        $directory = Split-Path -Parent $resolvedPath
        $lockPath = Join-Path $directory 'versions.lock.json'
        $planPath = Join-Path $directory 'install-plan.source.json'

        if (-not (Test-Path -LiteralPath $lockPath)) {
            throw 'versions.lock.json wurde neben dem Bericht nicht gefunden.'
        }
        if (-not (Test-Path -LiteralPath $planPath)) {
            throw 'install-plan.source.json wurde neben dem Bericht nicht gefunden.'
        }

        return [pscustomobject][ordered]@{
            inputType = 'json'
            originalPath = $resolvedPath
            extractedPath = $null
            reportPath = $resolvedPath
            lockPath = $lockPath
            planPath = $planPath
        }
    }

    if ($extension -ne '.zip') {
        throw 'Erwartet wird eine Preflight-ZIP oder preflight-report.json.'
    }

    $extractRoot = Join-Path $WorkingDirectory 'preflight-extracted'
    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    Expand-Archive -LiteralPath $resolvedPath -DestinationPath $extractRoot -Force

    $reportFiles = @(
        Get-ChildItem -LiteralPath $extractRoot -Recurse -File `
            -Filter 'preflight-report.json' -ErrorAction Stop
    )
    $lockFiles = @(
        Get-ChildItem -LiteralPath $extractRoot -Recurse -File `
            -Filter 'versions.lock.json' -ErrorAction Stop
    )
    $planFiles = @(
        Get-ChildItem -LiteralPath $extractRoot -Recurse -File `
            -Filter 'install-plan.source.json' -ErrorAction Stop
    )

    if ($reportFiles.Count -ne 1) {
        throw 'Die Preflight-ZIP muss genau eine preflight-report.json enthalten.'
    }
    if ($lockFiles.Count -ne 1) {
        throw 'Die Preflight-ZIP muss genau eine versions.lock.json enthalten.'
    }
    if ($planFiles.Count -ne 1) {
        throw 'Die Preflight-ZIP muss genau eine install-plan.source.json enthalten.'
    }

    return [pscustomobject][ordered]@{
        inputType = 'zip'
        originalPath = $resolvedPath
        extractedPath = $extractRoot
        reportPath = $reportFiles[0].FullName
        lockPath = $lockFiles[0].FullName
        planPath = $planFiles[0].FullName
    }
}

function Test-KIKernelInput {
    param(
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory)][object]$VersionLock,
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$Config
    )

    $issues = [System.Collections.Generic.List[string]]::new()

    if (@($Config.supportedPreflightSchemas) -notcontains [string]$Report.schemaVersion) {
        [void]$issues.Add('Nicht unterstütztes Preflight-Schema.')
    }
    if (@($Config.supportedLockSchemas) -notcontains [string]$VersionLock.schemaVersion) {
        [void]$issues.Add('Nicht unterstütztes Versions-Lock-Schema.')
    }
    if (@($Config.supportedPlanSchemas) -notcontains [string]$Plan.schemaVersion) {
        [void]$issues.Add('Nicht unterstütztes Plan-Schema.')
    }

    if (-not [bool]$Report.result.preflightPassed) {
        [void]$issues.Add('Der Preflight ist nicht bestanden.')
    }
    if (-not [bool]$Report.result.versionsComplete) {
        [void]$issues.Add('Der Versions-Lock ist nicht vollständig.')
    }
    if ([bool]$Report.result.installerMayExecute) {
        [void]$issues.Add('Der Preflight-Bericht darf die Ausführung noch nicht freigeben.')
    }
    if ([bool]$VersionLock.approved) {
        [void]$issues.Add('Der Versions-Lock darf noch nicht freigegeben sein.')
    }
    if ([bool]$VersionLock.executable) {
        [void]$issues.Add('Der Versions-Lock darf noch nicht ausführbar sein.')
    }
    if ([bool]$Plan.destructiveActionsAllowed) {
        [void]$issues.Add('Der Installationsplan erlaubt destruktive Aktionen.')
    }

    return [pscustomobject][ordered]@{
        valid = ($issues.Count -eq 0)
        issues = @($issues)
    }
}

function Get-KIModuleDefinitions {
    param([Parameter(Mandatory)][string]$ModuleDirectory)

    $manifestFiles = @(
        Get-ChildItem -LiteralPath $ModuleDirectory -Recurse -File `
            -Filter 'module.json' -ErrorAction Stop
    )

    $definitions = foreach ($manifestFile in $manifestFiles) {
        $manifest = Read-KIJson -Path $manifestFile.FullName
        $scriptPath = Join-Path $manifestFile.DirectoryName ([string]$manifest.script)

        if (-not (Test-Path -LiteralPath $scriptPath)) {
            throw "Modulskript fehlt: $scriptPath"
        }

        [pscustomobject][ordered]@{
            id = [string]$manifest.id
            order = [int]$manifest.order
            name = [string]$manifest.name
            version = [string]$manifest.version
            enabled = [bool]$manifest.enabled
            supportsRollback = [bool]$manifest.supportsRollback
            manifestPath = $manifestFile.FullName
            scriptPath = $scriptPath
            dependencies = @($manifest.dependencies)
            actions = @($manifest.actions)
        }
    }

    return @($definitions | Sort-Object order, id)
}

function Test-KIModuleGraph {
    param([Parameter(Mandatory)][object[]]$Modules)

    $issues = [System.Collections.Generic.List[string]]::new()
    $ids = @($Modules.id)

    $duplicateIds = @(
        $Modules |
        Group-Object id |
        Where-Object Count -gt 1
    )
    foreach ($duplicate in $duplicateIds) {
        [void]$issues.Add("Doppelte Modul-ID: $($duplicate.Name)")
    }

    foreach ($module in $Modules) {
        foreach ($dependency in @($module.dependencies)) {
            if ($ids -notcontains [string]$dependency) {
                [void]$issues.Add(
                    "Fehlende Abhängigkeit '$dependency' für Modul '$($module.id)'."
                )
            }
        }
    }

    return [pscustomobject][ordered]@{
        valid = ($issues.Count -eq 0)
        issues = @($issues)
    }
}

function New-KITransaction {
    param(
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][object]$InputState,
        [Parameter(Mandatory)][object[]]$Modules
    )

    $moduleStates = foreach ($module in $Modules) {
        [pscustomobject][ordered]@{
            id = $module.id
            name = $module.name
            order = $module.order
            status = if ($module.enabled) { 'Pending' } else { 'Disabled' }
            attempts = 0
            startedAt = $null
            completedAt = $null
            error = $null
            rollbackStatus = 'NotRequired'
            result = $null
        }
    }

    return [pscustomobject][ordered]@{
        schemaVersion = '1.0'
        transactionId = $TransactionId
        kernelVersion = '1.1.5'
        createdAt = (Get-Date).ToString('o')
        updatedAt = (Get-Date).ToString('o')
        mode = $Mode
        status = 'Initialized'
        approved = $false
        destructiveActionsAllowed = $false
        currentModuleId = $null
        input = $InputState
        modules = @($moduleStates)
        events = @()
    }
}

function Add-KITransactionEvent {
    param(
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Message,
        [AllowNull()][object]$Data = $null
    )

    $eventEntry = [pscustomobject][ordered]@{
        timestamp = (Get-Date).ToString('o')
        type = $Type
        message = $Message
        data = $Data
    }
    $Transaction.events = @($Transaction.events) + @($eventEntry)
    $Transaction.updatedAt = (Get-Date).ToString('o')
}

function Invoke-KIModuleCommand {
    param(
        [Parameter(Mandatory)][object]$Module,
        [Parameter(Mandatory)][ValidateSet('Test','Install','Validate','Rollback')]
        [string]$Command,
        [Parameter(Mandatory)][object]$Context
    )

    $moduleImplementation = Import-Module $Module.scriptPath -Force -PassThru `
        -DisableNameChecking -WarningAction SilentlyContinue -ErrorAction Stop

    try {
        $functionName = '{0}-{1}' -f $Command, $Module.id
        $commandInfo = Get-Command -Name $functionName -Module $moduleImplementation.Name `
            -ErrorAction SilentlyContinue

        if (-not $commandInfo) {
            if ($Command -eq 'Rollback' -and -not $Module.supportsRollback) {
                return [pscustomobject][ordered]@{
                    success = $true
                    skipped = $true
                    message = 'Rollback wird von diesem Modul nicht benötigt.'
                    data = $null
                }
            }
            throw "Modulfunktion fehlt: $functionName"
        }

        $commandOutput = @(& $functionName -Context $Context)

        $resultCandidates = @(
            $commandOutput |
            Where-Object {
                $null -ne $_ -and
                $null -ne $_.PSObject -and
                $_.PSObject.Properties.Name -contains 'success'
            }
        )

        if ($resultCandidates.Count -eq 0) {
            $outputPreview = @(
                $commandOutput |
                Select-Object -First 10 |
                ForEach-Object { [string]$_ }
            ) -join ' | '

            throw (
                "Modulfunktion '$functionName' lieferte kein gültiges Ergebnisobjekt." +
                $(if ($outputPreview) { " Ausgabe: $outputPreview" } else { '' })
            )
        }

        if ($resultCandidates.Count -gt 1) {
            throw (
                "Modulfunktion '$functionName' lieferte mehrere Ergebnisobjekte: " +
                $resultCandidates.Count
            )
        }

        $moduleResult = $resultCandidates[0]

        foreach ($requiredProperty in @('success','skipped','message','data')) {
            if ($moduleResult.PSObject.Properties.Name -notcontains $requiredProperty) {
                throw (
                    "Modulfunktion '$functionName' lieferte ein unvollständiges " +
                    "Ergebnisobjekt. Fehlende Eigenschaft: $requiredProperty"
                )
            }
        }

        return $moduleResult
    }
    finally {
        Remove-Module -ModuleInfo $moduleImplementation -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function *

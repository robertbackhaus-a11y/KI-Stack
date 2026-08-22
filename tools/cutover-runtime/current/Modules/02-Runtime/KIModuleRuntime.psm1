Set-StrictMode -Version Latest

function Update-KIProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machinePath, $userPath) -join ';'
}

function ConvertTo-KINormalizedVersion {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$VersionText
    )

    $numericMatches = [regex]::Matches(
        [string]$VersionText,
        '\d+'
    )

    if ($numericMatches.Count -eq 0) {
        return $null
    }

    $parts = [System.Collections.Generic.List[int]]::new()
    foreach ($numericMatch in $numericMatches) {
        if ($parts.Count -ge 4) {
            break
        }

        try {
            [void]$parts.Add([int]$numericMatch.Value)
        }
        catch {
            return $null
        }
    }

    while ($parts.Count -lt 2) {
        [void]$parts.Add(0)
    }

    while ($parts.Count -lt 4) {
        [void]$parts.Add(0)
    }

    return [version]::new(
        $parts[0],
        $parts[1],
        $parts[2],
        $parts[3]
    )
}

function Test-KIVersionAtLeast {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$DetectedVersion,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$MinimumVersion
    )

    $detectedNormalized = ConvertTo-KINormalizedVersion `
        -VersionText $DetectedVersion

    $minimumNormalized = ConvertTo-KINormalizedVersion `
        -VersionText $MinimumVersion

    if ($null -eq $detectedNormalized -or $null -eq $minimumNormalized) {
        return $false
    }

    return ($detectedNormalized -ge $minimumNormalized)
}

function Get-KIRuntimePropertyValue {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string[]]$PropertyNames,

        [object]$DefaultValue = $null
    )

    if ($null -eq $InputObject -or $null -eq $InputObject.PSObject) {
        return $DefaultValue
    }

    foreach ($propertyName in $PropertyNames) {
        if ($InputObject.PSObject.Properties.Name -contains $propertyName) {
            return $InputObject.$propertyName
        }
    }

    return $DefaultValue
}

function Get-KIRuntimeFileVersion {
    param([Parameter(Mandatory)][string]$Path)
    $fileVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($Path).FileVersion
    if(-not[string]::IsNullOrWhiteSpace($fileVersion)){return $fileVersion}
    try{return [Reflection.AssemblyName]::GetAssemblyName($Path).Version.ToString()}catch{return $null}
}

function Get-KIRuntimeComponentState {
    param([Parameter(Mandatory)][object]$Component)

    Update-KIProcessPath

    $componentId = [string](Get-KIRuntimePropertyValue `
        -InputObject $Component `
        -PropertyNames @('id','name') `
        -DefaultValue 'UnknownRuntimeComponent')

    $displayName = [string](Get-KIRuntimePropertyValue `
        -InputObject $Component `
        -PropertyNames @('displayName','id','name') `
        -DefaultValue $componentId)

    $requiredCommand = [string](Get-KIRuntimePropertyValue `
        -InputObject $Component `
        -PropertyNames @('requiredCommand','command') `
        -DefaultValue '')

    $minimumVersion = [string](Get-KIRuntimePropertyValue `
        -InputObject $Component `
        -PropertyNames @('minimumVersion') `
        -DefaultValue '0.0.0')

    $packageManager = [string](Get-KIRuntimePropertyValue `
        -InputObject $Component `
        -PropertyNames @('packageManager') `
        -DefaultValue 'winget')

    $packageId = [string](Get-KIRuntimePropertyValue `
        -InputObject $Component `
        -PropertyNames @('packageId') `
        -DefaultValue '')

    $requiredFiles = @(
        Get-KIRuntimePropertyValue `
            -InputObject $Component `
            -PropertyNames @('requiredFiles') `
            -DefaultValue @() |
        ForEach-Object { [Environment]::ExpandEnvironmentVariables([string]$_) }
    )
    $missingFiles = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    $fileVersions = @(
        $requiredFiles |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        ForEach-Object {
            [pscustomobject][ordered]@{
                path = $_
                version = Get-KIRuntimeFileVersion -Path $_
            }
        }
    )

    $commandInfo = $null
    if (-not [string]::IsNullOrWhiteSpace($requiredCommand)) {
        $commandInfo = Get-Command -Name $requiredCommand `
            -ErrorAction SilentlyContinue
    }

    $detectedVersion = $null
    if ($componentId -eq 'VisualCppRuntimeX64') {
        if ($missingFiles.Count -eq 0 -and $fileVersions.Count -eq $requiredFiles.Count) {
            $detectedVersion = @(
                $fileVersions |
                ForEach-Object { ConvertTo-KINormalizedVersion -VersionText ([string]$_.version) } |
                Where-Object { $null -ne $_ } |
                Sort-Object
            ) | Select-Object -First 1
        }
    }
    elseif ($commandInfo) {
        try {
            switch ($componentId) {
                'PowerShell7' {
                    $detectedVersion = (
                        & $commandInfo.Source -NoLogo -NoProfile -Command `
                            '$PSVersionTable.PSVersion.ToString()'
                    ).Trim()
                }
                'Git' {
                    $detectedVersion = (
                        & $commandInfo.Source --version
                    ) -replace '^git version\s+', ''
                }
                'Python' {
                    $detectedVersion = (
                        & $commandInfo.Source --version 2>&1
                    ) -replace '^Python\s+', ''
                }
                default {
                    $detectedVersion = [string](Get-KIRuntimePropertyValue `
                        -InputObject $Component `
                        -PropertyNames @('detectedVersion','installedVersion') `
                        -DefaultValue $null)
                }
            }
        }
        catch {
            $detectedVersion = $null
        }
    }

    $versionSufficient = $false
    if ($componentId -eq 'VisualCppRuntimeX64') {
        $versionSufficient = (
            $requiredFiles.Count -gt 0 -and
            $missingFiles.Count -eq 0 -and
            $null -ne $detectedVersion -and
            (Test-KIVersionAtLeast -DetectedVersion ([string]$detectedVersion) -MinimumVersion $minimumVersion)
        )
    }
    elseif ($detectedVersion) {
        try {
            $versionSufficient = Test-KIVersionAtLeast `
                -DetectedVersion $detectedVersion `
                -MinimumVersion $minimumVersion
        }
        catch {
            $versionSufficient = $false
        }
    }

    return [pscustomobject][ordered]@{
        id = $componentId
        displayName = $displayName
        requiredCommand = $requiredCommand
        command = $requiredCommand
        commandFound = if ($componentId -eq 'VisualCppRuntimeX64') { $missingFiles.Count -eq 0 } else { $null -ne $commandInfo }
        commandPath = if ($commandInfo) { $commandInfo.Source } else { $null }
        detectedVersion = $detectedVersion
        minimumVersion = $minimumVersion
        versionSufficient = $versionSufficient
        packageManager = $packageManager
        packageId = $packageId
        requiredFiles = $requiredFiles
        missingFiles = $missingFiles
        fileVersions = $fileVersions
    }
}

function Test-KIModuleRuntime {
    param([Parameter(Mandatory)][object]$Context)

    $wingetCommand = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue
    $componentStates = foreach ($component in @($Context.Config.runtime.components)) {
        Get-KIRuntimeComponentState -Component $component
    }

    $missingComponents = @($componentStates | Where-Object { -not $_.versionSufficient })
    $canProceed = (
        $missingComponents.Count -eq 0 -or
        $null -ne $wingetCommand
    )

    return [pscustomobject][ordered]@{
        success = $canProceed
        skipped = $false
        message = if ($canProceed) {
            'Runtime-Voraussetzungen geprüft.'
        } else {
            'winget.exe fehlt und Runtime-Komponenten müssen installiert werden.'
        }
        data = [pscustomobject][ordered]@{
            wingetAvailable = ($null -ne $wingetCommand)
            components = @($componentStates)
            missingComponentIds = @($missingComponents | ForEach-Object id)
        }
    }
}

function Install-KIModuleRuntime {
    param([Parameter(Mandatory)][object]$Context)

    $initialStates = foreach ($component in @($Context.Config.runtime.components)) {
        Get-KIRuntimeComponentState -Component $component
    }

    $pendingStates = @(
        $initialStates |
        Where-Object { -not [bool]$_.versionSufficient }
    )

    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $false
            message = 'Dry-Run: Runtime-Installationen wurden geplant.'
            data = [pscustomobject][ordered]@{
                alreadyCompliant = @(
                    $initialStates |
                    Where-Object { [bool]$_.versionSufficient } |
                    ForEach-Object { [string]$_.id }
                )
                wouldInstall = @(
                    $pendingStates |
                    ForEach-Object {
                        [pscustomobject][ordered]@{
                            id = [string]$_.id
                            packageManager = [string]$_.packageManager
                            packageId = [string]$_.packageId
                            minimumVersion = [string]$_.minimumVersion
                        }
                    }
                )
                installedByTransaction = @()
            }
        }
    }

    if ($pendingStates.Count -eq 0) {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $true
            message = 'Alle Runtime-Komponenten sind bereits in ausreichender Version vorhanden.'
            data = [pscustomobject][ordered]@{
                installedByTransaction = @()
                alreadyCompliant = @(
                    $initialStates |
                    ForEach-Object { [string]$_.id }
                )
                priorStates = @($initialStates)
            }
        }
    }

    if (-not [bool]$Context.Config.executeRelease.allowWingetInstall) {
        throw 'winget-Installationen sind für diese Execute-Freigabe gesperrt.'
    }

    $wingetCommand = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue
    if (-not $wingetCommand) {
        throw 'winget.exe fehlt; Runtime-Komponenten können nicht installiert werden.'
    }

    $installedByTransaction = [System.Collections.Generic.List[string]]::new()
    $alreadyCompliantAfterWinget = [System.Collections.Generic.List[string]]::new()
    $wingetDiagnostics = [System.Collections.Generic.List[object]]::new()

    foreach ($pendingState in $pendingStates) {
        $wingetOutput = @(
            & $wingetCommand.Source install `
                --id ([string]$pendingState.packageId) `
                --exact `
                --silent `
                --accept-package-agreements `
                --accept-source-agreements `
                --disable-interactivity 2>&1
        )

        $wingetExitCode = $LASTEXITCODE
        Update-KIProcessPath

        $componentConfig = @(
            $Context.Config.runtime.components |
            Where-Object { [string]$_.id -eq [string]$pendingState.id }
        ) | Select-Object -First 1

        if ($null -eq $componentConfig) {
            throw "Runtime-Komponentenkonfiguration nicht gefunden: $($pendingState.id)"
        }

        $afterState = Get-KIRuntimeComponentState -Component $componentConfig

        [void]$wingetDiagnostics.Add(
            [pscustomobject][ordered]@{
                id = [string]$pendingState.id
                wingetExitCode = $wingetExitCode
                detectedVersion = [string]$afterState.detectedVersion
                normalizedDetectedVersion = [string](
                    ConvertTo-KINormalizedVersion `
                        -VersionText ([string]$afterState.detectedVersion)
                )
                minimumVersion = [string]$afterState.minimumVersion
                normalizedMinimumVersion = [string](
                    ConvertTo-KINormalizedVersion `
                        -VersionText ([string]$afterState.minimumVersion)
                )
                versionSufficient = [bool]$afterState.versionSufficient
                output = @($wingetOutput | ForEach-Object { [string]$_ })
            }
        )

        # Ausschließlich der validierte Endzustand entscheidet.
        if ([bool]$afterState.versionSufficient) {
            if ($wingetExitCode -eq 0) {
                [void]$installedByTransaction.Add([string]$pendingState.id)
            }
            else {
                [void]$alreadyCompliantAfterWinget.Add([string]$pendingState.id)
            }

            continue
        }

        $wingetMessage = @(
            $wingetOutput |
            ForEach-Object { [string]$_ }
        ) -join ' | '

        throw (
            "Runtime-Komponente erfüllt nach winget weiterhin nicht die Mindestversion: " +
            "$($pendingState.id), Exitcode $wingetExitCode, " +
            "erkannte Version $($afterState.detectedVersion), " +
            "Mindestversion $($afterState.minimumVersion). $wingetMessage"
        )
    }

    if ($installedByTransaction.Count -gt 0) {
        $installMessage = 'Runtime-Komponenten wurden installiert oder aktualisiert.'
    }
    else {
        $installMessage = 'Runtime-Komponenten waren nach erneuter Prüfung bereits konform.'
    }

    return [pscustomobject][ordered]@{
        success = $true
        skipped = ($installedByTransaction.Count -eq 0)
        message = $installMessage
        data = [pscustomobject][ordered]@{
            installedByTransaction = @($installedByTransaction)
            alreadyCompliantAfterWinget = @($alreadyCompliantAfterWinget)
            priorStates = @($initialStates)
            wingetDiagnostics = @($wingetDiagnostics)
        }
    }
}

function Validate-KIModuleRuntime {
    param([Parameter(Mandatory)][object]$Context)

    Update-KIProcessPath
    $componentStates = foreach ($component in @($Context.Config.runtime.components)) {
        Get-KIRuntimeComponentState -Component $component
    }

    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $false
            message = 'Dry-Run: Runtime-Zielzustand ist ausführbar geplant.'
            data = [pscustomobject][ordered]@{
                currentStates = @($componentStates)
            }
        }
    }

    $nonCompliant = @(
        $componentStates |
        Where-Object { -not $_.versionSufficient }
    )

    return [pscustomobject][ordered]@{
        success = ($nonCompliant.Count -eq 0)
        skipped = $false
        message = if ($nonCompliant.Count -eq 0) {
            'Alle Runtime-Komponenten erfüllen den Mindeststand.'
        } else {
            'Mindestens eine Runtime-Komponente erfüllt den Mindeststand nicht.'
        }
        data = [pscustomobject][ordered]@{
            components = @($componentStates)
            nonCompliantIds = @($nonCompliant | ForEach-Object id)
        }
    }
}

function Rollback-KIModuleRuntime {
    param([Parameter(Mandatory)][object]$Context)

    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $true
            message = 'Dry-Run: Kein Runtime-Rollback erforderlich.'
            data = $null
        }
    }

    if (
        $null -eq $Context.ModuleResult -or
        $null -eq $Context.ModuleResult.PSObject -or
        $Context.ModuleResult.PSObject.Properties.Name -notcontains 'data' -or
        $null -eq $Context.ModuleResult.data -or
        $null -eq $Context.ModuleResult.data.PSObject -or
        $Context.ModuleResult.data.PSObject.Properties.Name -notcontains 'installedByTransaction'
    ) {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $true
            message = 'Keine verwertbaren Runtime-Rollbackdaten vorhanden.'
            data = $null
        }
    }

    $installedIds = @($Context.ModuleResult.data.installedByTransaction) |
        Where-Object { $_ }

    if ($installedIds.Count -eq 0) {
        return [pscustomobject][ordered]@{
            success = $true
            skipped = $true
            message = 'Keine durch diese Transaktion installierten Runtime-Komponenten.'
            data = $null
        }
    }

    if (-not [bool]$Context.Config.executeRelease.allowWingetUninstallDuringRollback) {
        return [pscustomobject][ordered]@{
            success = $false
            skipped = $true
            message = 'Automatischer Runtime-Rollback ist gesperrt.'
            data = [pscustomobject][ordered]@{
                installedByTransaction = $installedIds
            }
        }
    }

    $wingetCommand = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue
    if (-not $wingetCommand) {
        throw 'winget.exe fehlt; Runtime-Rollback ist nicht möglich.'
    }

    $removed = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()

    foreach ($installedId in $installedIds) {
        $component = @(
            $Context.Config.runtime.components |
            Where-Object { [string]$_.id -eq [string]$installedId }
        ) | Select-Object -First 1

        if ($null -eq $component) {
            [void]$failed.Add([string]$installedId)
            continue
        }

        $wingetRollbackOutput = @(
            & $wingetCommand.Source uninstall `
                --id ([string]$component.packageId) `
                --exact `
                --silent `
                --disable-interactivity 2>&1
        )

        if ($LASTEXITCODE -eq 0) {
            [void]$removed.Add([string]$installedId)
        }
        else {
            [void]$failed.Add([string]$installedId)
        }
    }

    if ($failed.Count -eq 0) {
        $rollbackMessage = 'Runtime-Rollback wurde ausgeführt.'
    }
    else {
        $rollbackMessage = 'Runtime-Rollback war nicht vollständig erfolgreich.'
    }

    return [pscustomobject][ordered]@{
        success = ($failed.Count -eq 0)
        skipped = $false
        message = $rollbackMessage
        data = [pscustomobject][ordered]@{
            requested = $installedIds
            removed = @($removed)
            failed = @($failed)
        }
    }
}

Export-ModuleMember -Function *

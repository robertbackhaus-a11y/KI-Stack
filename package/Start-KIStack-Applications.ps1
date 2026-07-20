[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('SelfTest','DryRun','Execute')]
    [string]$Action,

    [string]$PreflightPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$tempLogPath = Join-Path ([IO.Path]::GetTempPath()) 'KI-Stack-Applications-Starter.log'
$starterLogPath = $null
$finalExitCode = 1

function Write-EmergencyStarterLog {
    param([Parameter(Mandatory)][string]$Message)

    try {
        $line = '[{0}] {1}' -f (Get-Date).ToString('o'), $Message
        Add-Content -LiteralPath $tempLogPath -Value $line -Encoding UTF8
    }
    catch {
    }
}

function Write-StarterStatus {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host $Message
    Write-EmergencyStarterLog -Message $Message

    if ($starterLogPath) {
        try {
            Write-KIStarterLog -Path $starterLogPath -Message $Message
        }
        catch {
            Write-EmergencyStarterLog -Message (
                'Paket-Log konnte nicht geschrieben werden: {0}' -f $_.Exception.Message
            )
        }
    }
}

function Get-CurrentPwshExecutable {
    $preferred = Join-Path $PSHOME 'pwsh.exe'
    if (Test-Path -LiteralPath $preferred -PathType Leaf) {
        return $preferred
    }

    $processPath = (Get-Process -Id $PID -ErrorAction Stop).Path
    if ($processPath -and (Test-Path -LiteralPath $processPath -PathType Leaf)) {
        return $processPath
    }

    throw 'Der Pfad der laufenden PowerShell-7-Instanz konnte nicht ermittelt werden.'
}

function Test-LauncherAdministrator {
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

function Invoke-ChildPwsh {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $pwshExecutable = Get-CurrentPwshExecutable
    & $pwshExecutable @Arguments | Out-Host
    return [int]$LASTEXITCODE
}

function Write-SelfTestFailureSummary {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $candidatePaths = @(
        (Join-Path $ProjectRoot 'State\SelfTest\SelfTest-latest.json'),
        (Join-Path ([IO.Path]::GetTempPath()) 'KI-Stack-Applications-SelfTest-latest.json')
    )

    $reportPath = @(
        $candidatePaths |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    ) | Select-Object -First 1

    if (-not $reportPath) {
        Write-StarterStatus 'Kein lesbarer Selbsttestbericht gefunden.'
        return
    }

    try {
        $report = Get-Content -LiteralPath $reportPath -Raw -ErrorAction Stop |
            ConvertFrom-Json -Depth 100 -ErrorAction Stop

        Write-StarterStatus ("Selbsttest-Bericht: {0}" -f $reportPath)
        foreach ($failedResult in @($report.results | Where-Object { -not [bool]$_.passed })) {
            Write-StarterStatus (
                'FEHLTEST: {0} -- {1}' -f
                [string]$failedResult.name,
                [string]$failedResult.message
            )
        }
    }
    catch {
        Write-StarterStatus (
            'Selbsttestbericht konnte nicht ausgewertet werden: {0}' -f
            $_.Exception.Message
        )
    }
}

try {
    Write-EmergencyStarterLog -Message 'PowerShell-Starter wurde betreten.'
    Write-EmergencyStarterLog -Message ('Aktion: {0}' -f $Action)
    Write-EmergencyStarterLog -Message ('Paketwurzel: {0}' -f $projectRoot)

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw ('PowerShell 7 oder neuer ist erforderlich. Gefunden: {0}' -f
            $PSVersionTable.PSVersion)
    }

    $syntaxTestPath = Join-Path $projectRoot 'Tests\Test-KIStackPowerShellSyntax.ps1'
    if (-not (Test-Path -LiteralPath $syntaxTestPath -PathType Leaf)) {
        throw "Native PowerShell-Syntaxprüfung fehlt: $syntaxTestPath"
    }

    Write-EmergencyStarterLog -Message 'Native PowerShell-Syntaxprüfung wird vor jedem Modulimport gestartet.'
    $syntaxExitCode = Invoke-ChildPwsh -Arguments @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $syntaxTestPath,
        '-ProjectRoot', $projectRoot
    )
    Write-EmergencyStarterLog -Message ("PowerShell-Syntaxprüfung-Exitcode: {0}" -f $syntaxExitCode)
    if ($syntaxExitCode -ne 0) {
        throw "Die native PowerShell-Syntaxprüfung ist fehlgeschlagen. Exitcode: $syntaxExitCode"
    }

    $starterModulePath = Join-Path $projectRoot 'Core\KIStack.Starter.psm1'
    if (-not (Test-Path -LiteralPath $starterModulePath -PathType Leaf)) {
        throw "Startermodul fehlt: $starterModulePath"
    }

    Import-Module $starterModulePath -Force -ErrorAction Stop
    $starterLogPath = New-KIStarterLogPath -ProjectRoot $projectRoot

    Write-StarterStatus ("Starteraktion: {0}" -f $Action)
    Write-StarterStatus ("Paketwurzel: {0}" -f $projectRoot)
    Write-StarterStatus ("PowerShell: {0}" -f (Get-CurrentPwshExecutable))
    Write-StarterStatus ("Notfall-Log: {0}" -f $tempLogPath)
    Write-StarterStatus ("PowerShell-Syntaxprüfung-Exitcode: {0}" -f $syntaxExitCode)

    $packageCheck = Test-KIStarterPackage -ProjectRoot $projectRoot
    if (-not $packageCheck.valid) {
        throw ('Paket ist unvollständig. Fehlend: {0}' -f ($packageCheck.missing -join ', '))
    }

    $pathTestPath = Join-Path $projectRoot 'Tests\Test-KIStackPathResolution.ps1'
    $testPath = Join-Path $projectRoot 'Tests\Test-KIStackBuilderKernel.ps1'
    $kernelPath = Join-Path $projectRoot 'Invoke-KIStackBuilderKernel.ps1'
    $configPath = Join-Path $projectRoot 'Config\kernel-config.json'

    Write-StarterStatus 'Paket- und Pfadauflösung wird gegen reale und verschachtelte Pfade geprüft.'
    $pathExitCode = Invoke-ChildPwsh -Arguments @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $pathTestPath,
        '-ProjectRoot', $projectRoot
    )
    Write-StarterStatus ("Pfadprüfung-Exitcode: {0}" -f $pathExitCode)
    if ($pathExitCode -ne 0) {
        throw "Die Paket- und Pfadprüfung ist fehlgeschlagen. Exitcode: $pathExitCode"
    }

    if ($Action -eq 'SelfTest') {
        $testExitCode = Invoke-ChildPwsh -Arguments @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $testPath,
            '-ProjectRoot', $projectRoot
        )
        Write-StarterStatus ("Selbsttest-Exitcode: {0}" -f $testExitCode)
        $selfTestLatestPath = Join-Path $projectRoot `
            'State\SelfTest\SelfTest-latest.json'
        if ($testExitCode -ne 0) {
            Write-SelfTestFailureSummary -ProjectRoot $projectRoot
        }
        elseif (Test-Path -LiteralPath $selfTestLatestPath -PathType Leaf) {
            Write-StarterStatus ("Selbsttest-Bericht: {0}" -f $selfTestLatestPath)
        }
        $finalExitCode = $testExitCode
    }
    else {
        if ($Action -eq 'Execute') {
            if (-not (Test-LauncherAdministrator)) {
                throw 'Die automatische UAC-Elevation wurde nicht wirksam. Der Execute-Kernel wird aus Sicherheitsgründen nicht gestartet.'
            }

            Write-StarterStatus 'Der vollständige Selbsttest wird vor Execute ausgeführt.'
            $testExitCode = Invoke-ChildPwsh -Arguments @(
                '-NoLogo',
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', $testPath,
                '-ProjectRoot', $projectRoot
            )
            if ($testExitCode -ne 0) {
                Write-SelfTestFailureSummary -ProjectRoot $projectRoot
                throw "Der Selbsttest ist fehlgeschlagen. Exitcode: $testExitCode"
            }
        }

        $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop |
            ConvertFrom-Json -Depth 100 -ErrorAction Stop

        $configuredRoots = @(
            foreach ($configuredRoot in @($config.starter.preflightSearchRoots)) {
                if ($configuredRoot) {
                    [Environment]::ExpandEnvironmentVariables([string]$configuredRoot)
                }
            }
        )

        $defaultRoots = Get-KIStarterDefaultSearchRoots -ProjectRoot $projectRoot
        $searchRoots = @($configuredRoots + $defaultRoots | Select-Object -Unique)

        $effectiveExplicitPath = if ($PreflightPath) {
            $PreflightPath
        }
        elseif ($env:KI_STACK_PREFLIGHT_PATH) {
            [string]$env:KI_STACK_PREFLIGHT_PATH
        }
        else {
            $null
        }

        Write-StarterStatus ("Preflight-Suchwurzeln: {0}" -f ($searchRoots -join ' | '))

        $preflightSource = $null
        if ($effectiveExplicitPath) {
            $preflight = Find-KILatestPreflight `
                -ExplicitPath $effectiveExplicitPath `
                -SearchRoots $searchRoots `
                -FilePattern ([string]$config.starter.preflightFilePattern) `
                -SearchRecursively:([bool]$config.starter.searchRecursively) `
                -RequireStateDirectory:([bool]$config.starter.requireStateDirectory)
            $preflightSource = 'Expliziter Override'
        }
        elseif ([string]$config.starter.preflightSelectionMode -eq 'EmbeddedDefault') {
            $embeddedPreflightPath = Join-Path $projectRoot `
                ([string]$config.starter.embeddedPreflightRelativePath)
            if (-not (Test-Path -LiteralPath $embeddedPreflightPath -PathType Leaf)) {
                throw "Eingebetteter Fortsetzungs-Preflight fehlt: $embeddedPreflightPath"
            }
            $preflight = Get-Item -LiteralPath $embeddedPreflightPath -ErrorAction Stop
            $preflightSource = 'Paketinterner Fortsetzungs-Preflight'
        }
        else {
            $preflight = Find-KILatestPreflight `
                -SearchRoots $searchRoots `
                -FilePattern ([string]$config.starter.preflightFilePattern) `
                -SearchRecursively:([bool]$config.starter.searchRecursively) `
                -RequireStateDirectory:([bool]$config.starter.requireStateDirectory)
            $preflightSource = 'Externe Suche'
        }

        Write-Host ''
        Write-Host '== Preflight-Eingabe ermitteln ==' -ForegroundColor Cyan
        Write-Host ("Quelle: {0}" -f $preflightSource)
        Write-Host ("Verwendeter Preflight: {0}" -f $preflight.FullName)
        Write-Host ("Änderungszeit UTC: {0:o}" -f $preflight.LastWriteTimeUtc)
        Write-Host ''

        Write-StarterStatus ("Preflight-Quelle: {0}" -f $preflightSource)
        Write-StarterStatus ("Ausgewählter Preflight: {0}" -f $preflight.FullName)

        $kernelArguments = @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $kernelPath,
            '-PreflightPath', $preflight.FullName,
            '-Mode', $Action,
            '-RollbackOnFailure'
        )

        if ($Action -eq 'Execute') {
            $confirmation = Read-Host 'Zur echten Ausführung EXECUTE eingeben'
            if ($confirmation -cne [string]$config.executeRelease.confirmationToken) {
                throw 'Execute wurde nicht mit dem erforderlichen Bestätigungstoken freigegeben.'
            }

            $kernelArguments += @(
                '-ExecutionConfirmation',
                [string]$config.executeRelease.confirmationToken
            )
        }

        $kernelExitCode = Invoke-ChildPwsh -Arguments $kernelArguments
        Write-StarterStatus ("Kernel-Exitcode: {0}" -f $kernelExitCode)
        $finalExitCode = $kernelExitCode
    }
}
catch {
    $message = $_.Exception.Message
    Write-Host ''
    Write-Host ("START FEHLGESCHLAGEN: {0}" -f $message) -ForegroundColor Red
    Write-Host ("Notfall-Log: {0}" -f $tempLogPath)
    if ($starterLogPath) {
        Write-Host ("Starter-Log: {0}" -f $starterLogPath)
    }

    Write-EmergencyStarterLog -Message ("FEHLER: {0}" -f $message)
    if ($_.ScriptStackTrace) {
        Write-EmergencyStarterLog -Message (
            "STACK: {0}" -f ($_.ScriptStackTrace -replace "`r?`n", ' | ')
        )
    }

    if ($starterLogPath) {
        try {
            Write-KIStarterLog -Path $starterLogPath -Message ("FEHLER: {0}" -f $message)
            if ($_.ScriptStackTrace) {
                Write-KIStarterLog -Path $starterLogPath -Message (
                    "STACK: {0}" -f ($_.ScriptStackTrace -replace "`r?`n", ' | ')
                )
            }
        }
        catch {
        }
    }

    $finalExitCode = 1
}

exit $finalExitCode

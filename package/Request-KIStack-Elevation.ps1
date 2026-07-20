[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BootstrapPath,

    [Parameter(Mandatory)]
    [ValidateSet('Execute')]
    [string]$Action,

    [Parameter(Mandatory)]
    [string]$WindowTitle
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tempLogPath = Join-Path ([IO.Path]::GetTempPath()) 'KI-Stack-Integration-Elevation.log'

function Write-ElevationLog {
    param([Parameter(Mandatory)][string]$Message)

    try {
        $line = '[{0}] {1}' -f (Get-Date).ToString('o'), $Message
        Add-Content -LiteralPath $tempLogPath -Value $line -Encoding UTF8
    }
    catch {
    }
}

function Test-KIProcessAdministrator {
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

try {
    Write-ElevationLog -Message 'UAC-Prüfung gestartet.'
    Write-ElevationLog -Message ('Bootstrap: {0}' -f $BootstrapPath)

    if (Test-KIProcessAdministrator) {
        Write-ElevationLog -Message 'Der aktuelle Prozess besitzt bereits Administratorrechte.'
        exit 0
    }

    if (-not (Test-Path -LiteralPath $BootstrapPath -PathType Leaf)) {
        throw "Bootstrap-Datei fehlt: $BootstrapPath"
    }

    if (-not $env:ComSpec -or -not (Test-Path -LiteralPath $env:ComSpec -PathType Leaf)) {
        throw 'ComSpec/cmd.exe konnte nicht ermittelt werden.'
    }

    $escapedBootstrap = $BootstrapPath.Replace('"', '""')
    $escapedTitle = $WindowTitle.Replace('"', '""')
    $cmdArguments = '/D /C ""{0}" {1} "{2}" Elevated"' -f `
        $escapedBootstrap,
        $Action,
        $escapedTitle

    Write-ElevationLog -Message 'Administratorrechte werden über die Windows-UAC angefordert.'
    Write-ElevationLog -Message ('CMD-Argumente: {0}' -f $cmdArguments)

    [void](Start-Process `
        -FilePath $env:ComSpec `
        -ArgumentList $cmdArguments `
        -WorkingDirectory (Split-Path -Parent $BootstrapPath) `
        -Verb RunAs `
        -PassThru `
        -ErrorAction Stop)

    Write-ElevationLog -Message 'Der erhöhte Diagnoseprozess wurde gestartet.'
    exit 10
}
catch {
    $message = $_.Exception.Message
    Write-ElevationLog -Message ('FEHLER: {0}' -f $message)
    [Console]::Error.WriteLine('UAC-ELEVATION FEHLGESCHLAGEN: {0}' -f $message)
    [Console]::Error.WriteLine('Elevation-Log: {0}' -f $tempLogPath)
    exit 1
}

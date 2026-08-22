[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallerScript,
    [Parameter(Mandatory)][string]$LogPath,
    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-KIBootstrapAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function ConvertTo-KIBootstrapArgument {
    param([Parameter(Mandatory)][string]$Value)
    return '"' + $Value.Replace('"','\"') + '"'
}

function Get-KIBootstrapPowerShell7 {
    $fixed = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $fixed -PathType Leaf) { return $fixed }
    $command = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function Write-KIBootstrapDiagnostic {
    param([Parameter(Mandatory)][string]$Event,[AllowNull()][object]$Data=$null)
    $entry=[ordered]@{timestampUtc=[DateTime]::UtcNow.ToString('o');event=$Event;processId=$PID;data=$Data}
    [IO.File]::AppendAllText($script:BootstrapLogPath,($entry|ConvertTo-Json -Depth 20 -Compress)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
}

function Get-KIBootstrapLastNativeExitCode {
    $value=Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    if($null-ne$value){return $value.Value}
    return $null
}

function Get-KIBootstrapDiscoveryState {
    param([switch]$IncludeVersion)
    $command=Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
    $whereOutput=@();$whereExitCode=$null
    try{$whereOutput=@(& (Join-Path $env:SystemRoot 'System32\where.exe') pwsh.exe 2>&1|ForEach-Object{[string]$_});$whereExitCode=$LASTEXITCODE}catch{$whereOutput=@($_.Exception.Message);$whereExitCode=-1}
    $knownPaths=@(
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Join-Path $env:ProgramFiles 'PowerShell\7-preview\pwsh.exe'),
        $(if($env:LOCALAPPDATA){Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'}else{$null})
    )|Where-Object{$_}|ForEach-Object{$candidate=$_;$exists=$false;$probeError=$null;try{$exists=Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction Stop}catch{$probeError=$_.Exception.Message};[pscustomobject]@{path=$candidate;exists=$exists;probeError=$probeError}}
    $winget=Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
    $wingetList=@();$wingetListExitCode=$null
    if($winget){try{$wingetList=@(& $winget.Source list --id Microsoft.PowerShell --exact --accept-source-agreements --disable-interactivity 2>&1|ForEach-Object{[string]$_});$wingetListExitCode=$LASTEXITCODE}catch{$wingetList=@($_.Exception.Message);$wingetListExitCode=-1}}
    $resolved=Get-KIBootstrapPowerShell7
    $version=$null;$versionExitCode=$null
    if($IncludeVersion-and$resolved){try{$version=@(& $resolved -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>&1|ForEach-Object{[string]$_})-join[Environment]::NewLine;$versionExitCode=$LASTEXITCODE}catch{$version=$_.Exception.Message;$versionExitCode=-1}}
    [pscustomobject][ordered]@{
        getCommandPath=if($command){$command.Source}else{$null}
        whereOutput=$whereOutput
        whereExitCode=$whereExitCode
        knownPaths=$knownPaths
        wingetPath=if($winget){$winget.Source}else{$null}
        wingetList=$wingetList
        wingetListExitCode=$wingetListExitCode
        resolvedPwshPath=$resolved
        resolvedPwshVersion=$version
        resolvedPwshVersionExitCode=$versionExitCode
    }
}

$InstallerScript = [IO.Path]::GetFullPath($InstallerScript)
$LogPath = [IO.Path]::GetFullPath($LogPath)
$packageRoot = Split-Path -Parent $InstallerScript
$script:BootstrapLogPath=$LogPath+'.bootstrap.jsonl'
$bootstrapLogParent=Split-Path -Parent $script:BootstrapLogPath
if(-not(Test-Path -LiteralPath $bootstrapLogParent)){New-Item -ItemType Directory -Path $bootstrapLogParent -Force|Out-Null}
if(-not$Elevated-or-not(Test-Path -LiteralPath $script:BootstrapLogPath -PathType Leaf)){[IO.File]::WriteAllText($script:BootstrapLogPath,'',[Text.UTF8Encoding]::new($false))}

try {
Write-KIBootstrapDiagnostic -Event 'BootstrapStart' -Data ([ordered]@{installerScript=$InstallerScript;logPath=$LogPath;bootstrapLogPath=$script:BootstrapLogPath;elevated=[bool]$Elevated;windowsPowerShell=$PSHOME})

if (-not (Test-KIBootstrapAdministrator)) {
    if ($Elevated) { throw 'Die UAC-Elevation für den PowerShell-7-Bootstrap war nicht wirksam.' }
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (ConvertTo-KIBootstrapArgument $PSCommandPath),
        '-InstallerScript', (ConvertTo-KIBootstrapArgument $InstallerScript),
        '-LogPath', (ConvertTo-KIBootstrapArgument $LogPath),
        '-Elevated'
    ) -join ' '
    Write-KIBootstrapDiagnostic -Event 'ElevationHandoff' -Data ([ordered]@{filePath=(Join-Path $PSHOME 'powershell.exe');arguments=$arguments})
    $elevatedProcess = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
        -ArgumentList $arguments -Verb RunAs -Wait -PassThru -ErrorAction Stop
    Write-KIBootstrapDiagnostic -Event 'ElevationExit' -Data ([ordered]@{exitCode=[int]$elevatedProcess.ExitCode})
    exit $elevatedProcess.ExitCode
}

Write-KIBootstrapDiagnostic -Event 'StateBeforeInstallation' -Data (Get-KIBootstrapDiscoveryState)
$pwsh = Get-KIBootstrapPowerShell7
if (-not $pwsh) {
    $payloadDirectory = Join-Path $packageRoot 'Payload\CutoverRuntime'
    $payloads = @(Get-ChildItem -LiteralPath $payloadDirectory -Filter '*.zip' -File -ErrorAction Stop)
    if ($payloads.Count -ne 1) {
        throw "Cutover-Runtime-Payload muss genau einmal vorhanden sein; gefunden: $($payloads.Count)."
    }

    $extractRoot = Join-Path ([IO.Path]::GetTempPath()) ('KIStack-PS7-Bootstrap-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($payloads[0].FullName,$extractRoot)
        $runtimeModule = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter 'KIModuleRuntime.psm1')
        $runtimeConfig = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter 'kernel-config.json')
        if ($runtimeModule.Count -ne 1 -or $runtimeConfig.Count -ne 1) {
            throw 'Der eingebettete Foundation-/Runtime-Vertrag ist unvollständig oder mehrdeutig.'
        }

        Import-Module $runtimeModule[0].FullName -Force
        $fullConfig = Get-Content -LiteralPath $runtimeConfig[0].FullName -Raw | ConvertFrom-Json
        $powerShellComponent = @($fullConfig.runtime.components | Where-Object { $_.id -eq 'PowerShell7' })
        if ($powerShellComponent.Count -ne 1 -or $powerShellComponent[0].packageId -ne 'Microsoft.PowerShell') {
            throw 'Der autoritative PowerShell-7-Runtimevertrag fehlt oder ist mehrdeutig.'
        }
        $bootstrapConfig = [pscustomobject]@{
            runtime = [pscustomobject]@{ components = @($powerShellComponent[0]) }
            executeRelease = [pscustomobject]@{ allowWingetInstall = [bool]$fullConfig.executeRelease.allowWingetInstall }
        }
        $context = [pscustomobject]@{ Config = $bootstrapConfig; Mode = 'Execute' }
        Write-KIBootstrapDiagnostic -Event 'WingetInstallStart' -Data ([ordered]@{packageId='Microsoft.PowerShell';runtimeModule=$runtimeModule[0].FullName})
        $result = Install-KIModuleRuntime -Context $context
        $diagnostics=$null;$dataProperty=$result.PSObject.Properties['data'];if($null-ne$dataProperty-and$null-ne$dataProperty.Value){$diagnosticsProperty=$dataProperty.Value.PSObject.Properties['wingetDiagnostics'];if($null-ne$diagnosticsProperty){$diagnostics=$diagnosticsProperty.Value}}
        Write-KIBootstrapDiagnostic -Event 'WingetInstallExit' -Data ([ordered]@{lastExitCode=$LASTEXITCODE;success=[bool]$result.success;diagnostics=$diagnostics})
        if (-not [bool]$result.success) { throw 'Der vorhandene Runtime-Bootstrap konnte PowerShell 7 nicht bereitstellen.' }
    }
    finally {
        if (Test-Path -LiteralPath $extractRoot) {
            Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-KIBootstrapDiagnostic -Event 'StateAfterInstallation' -Data (Get-KIBootstrapDiscoveryState -IncludeVersion)
    $pwsh = Get-KIBootstrapPowerShell7
}

Write-KIBootstrapDiagnostic -Event 'ReadbackDecision' -Data ([ordered]@{resolvedPwshPath=$pwsh;accepted=(-not[string]::IsNullOrWhiteSpace([string]$pwsh))})
if (-not $pwsh) { throw 'PowerShell 7 fehlt nach erfolgreichem Runtime-Bootstrap-Readback.' }
$actualMajor = & $pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.Major'
Write-KIBootstrapDiagnostic -Event 'VersionReadback' -Data ([ordered]@{resolvedPwshPath=$pwsh;major=$actualMajor;exitCode=$LASTEXITCODE})
if ($LASTEXITCODE -ne 0 -or [int]$actualMajor -lt 7) {
    throw 'Das bereitgestellte pwsh.exe ist nicht funktionsfähig oder keine PowerShell-7-Instanz.'
}

$installerArguments = @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    (ConvertTo-KIBootstrapArgument $InstallerScript),
    '-Elevated', '-LogPath', (ConvertTo-KIBootstrapArgument $LogPath)
) -join ' '
Write-KIBootstrapDiagnostic -Event 'CompleteInstallerHandoff' -Data ([ordered]@{filePath=$pwsh;installerScript=$InstallerScript;arguments=$installerArguments})
$installerProcess = Start-Process -FilePath $pwsh -ArgumentList $installerArguments `
    -Wait -PassThru -NoNewWindow -ErrorAction Stop
Write-KIBootstrapDiagnostic -Event 'CompleteInstallerExit' -Data ([ordered]@{exitCode=[int]$installerProcess.ExitCode})
exit $installerProcess.ExitCode
}
catch {
    $exceptionData=[ordered]@{
        message=$_.Exception.Message
        exceptionType=$_.Exception.GetType().FullName
        scriptStackTrace=$_.ScriptStackTrace
        positionMessage=$_.InvocationInfo.PositionMessage
        innerException=if($_.Exception.InnerException){[ordered]@{message=$_.Exception.InnerException.Message;exceptionType=$_.Exception.InnerException.GetType().FullName}}else{$null}
        lastNativeExitCode=Get-KIBootstrapLastNativeExitCode
    }
    try{Write-KIBootstrapDiagnostic -Event 'BootstrapException' -Data $exceptionData}catch{}
    throw
}

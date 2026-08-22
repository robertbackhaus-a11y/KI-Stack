[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-Bootstrap-Logging-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $temp -Force|Out-Null
    $source=Get-Content -LiteralPath (Join-Path $PackageRoot 'Bootstrap-KIStackPowerShell7.ps1') -Raw
    $source=$source.Replace('if (-not (Test-KIBootstrapAdministrator)) {','if ($false) {')
    $bootstrap=Join-Path $temp 'Bootstrap-KIStackPowerShell7.ps1'
    [IO.File]::WriteAllText($bootstrap,$source,[Text.UTF8Encoding]::new($false))
    $installer=Join-Path $temp 'Start-KIStackCompleteInstaller.ps1'
    [IO.File]::WriteAllText($installer,'exit 30',[Text.UTF8Encoding]::new($false))
    $log=Join-Path $temp 'installer.log'
    $windowsPowerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $windowsPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $bootstrap -InstallerScript $installer -LogPath $log -Elevated *> $null
    $handoffExit=$LASTEXITCODE
    $bootstrapLog=$log+'.bootstrap.jsonl'
    $events=@(Get-Content -LiteralPath $bootstrapLog|ForEach-Object{$_|ConvertFrom-Json})
    $eventNames=@($events.event)

    $earlySource=$source.Replace('if ($false) {',"throw 'FixtureEarlyBootstrapFailure'`r`nif (`$false) {")
    $earlyBootstrap=Join-Path $temp 'Bootstrap-EarlyFailure.ps1'
    [IO.File]::WriteAllText($earlyBootstrap,$earlySource,[Text.UTF8Encoding]::new($false))
    $earlyLog=Join-Path $temp 'early.log'
    & $windowsPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $earlyBootstrap -InstallerScript $installer -LogPath $earlyLog -Elevated *> $null
    $earlyExit=$LASTEXITCODE
    $earlyEvents=@(Get-Content -LiteralPath ($earlyLog+'.bootstrap.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
    $exception=@($earlyEvents|Where-Object event -eq 'BootstrapException')|Select-Object -First 1

    $cmd=Get-Content -LiteralPath (Join-Path $PackageRoot 'Start-KIStack-Installer.cmd') -Raw
    $requiredMarkers=@('BootstrapStart','StateBeforeInstallation','WingetInstallStart','WingetInstallExit','StateAfterInstallation','ReadbackDecision','VersionReadback','CompleteInstallerHandoff','CompleteInstallerExit','BootstrapException')
    $markersPresent=@($requiredMarkers|Where-Object{-not$source.Contains("'$($_)'" )}).Count-eq0
    $passed=(
        $handoffExit-eq30-and
        (Test-Path -LiteralPath $bootstrapLog -PathType Leaf)-and
        @('BootstrapStart','StateBeforeInstallation','ReadbackDecision','VersionReadback','CompleteInstallerHandoff','CompleteInstallerExit'|Where-Object{$eventNames-notcontains$_}).Count-eq0-and
        $earlyExit-ne0-and$null-ne$exception-and
        -not[string]::IsNullOrWhiteSpace([string]$exception.data.message)-and
        -not[string]::IsNullOrWhiteSpace([string]$exception.data.exceptionType)-and
        $markersPresent-and
        $cmd.Contains('if exist "%LOG%.bootstrap.jsonl" echo Bootstrap-Diagnose:')-and
        $cmd.Contains('if exist "%LOG%.stderr.txt" echo Fehlerausgabe:')-and
        $cmd.Contains('if exist "%LOG%.transcript.txt" echo Transcript:')-and
        $cmd.Contains('if exist "%LOG%.exitcode.txt" echo Exitcode:')
    )
    [pscustomobject][ordered]@{passed=$passed;handoffExitCode=$handoffExit;earlyFailureExitCode=$earlyExit;bootstrapLog=$bootstrapLog;events=$eventNames;earlyExceptionLogged=($null-ne$exception);allDiagnosticMarkers=$markersPresent;targetSystemAccessed=$false}|ConvertTo-Json -Depth 10
    if(-not$passed){throw 'Bootstrap-Logging-Regression fehlgeschlagen.'}
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}

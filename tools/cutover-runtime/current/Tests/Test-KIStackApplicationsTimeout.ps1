[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-ApplicationsTimeout-'+[guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temp -Force|Out-Null
    $logPath=Join-Path $temp 'transaction.log.jsonl'
    $context=[pscustomobject]@{LogPath=$logPath}
    $module=Import-Module (Join-Path $ProjectRoot 'Modules/06-Applications/KIModuleApplications.psm1') -Force -PassThru -DisableNameChecking
    $pwsh=(Get-Process -Id $PID).Path

    $completed=Invoke-KIApplicationCommand -FilePath $pwsh -ArgumentList @('-NoProfile','-Command','exit 0') -TimeoutSeconds 5 -Context $context -Operation 'FixtureCompletes'

    $stopwatch=[Diagnostics.Stopwatch]::StartNew()
    $timeoutMessage=$null
    try {
        $null=Invoke-KIApplicationCommand -FilePath $pwsh -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 10') -TimeoutSeconds 1 -Context $context -Operation 'FixtureNeverCompletes'
    } catch { $timeoutMessage=$_.Exception.Message }
    $stopwatch.Stop()

    $unusedPort=49151
    $greenfieldReachable=Test-KIApplicationEndpoint -Uri "http://127.0.0.1:$unusedPort/" -Name 'GreenfieldFixture' -Context $context -TimeoutSeconds 1
    $entries=@(Get-Content -LiteralPath $logPath|ForEach-Object{$_|ConvertFrom-Json})
    $passed=(
        $completed.exitCode-eq0 -and
        $timeoutMessage-match 'Timeout bei FixtureNeverCompletes nach 1 Sekunden' -and
        $stopwatch.Elapsed.TotalSeconds-lt5 -and
        -not$greenfieldReachable -and
        @($entries|Where-Object{$_.message-eq'WaitStarted'-and$_.data.target-eq'FixtureCompletes'}).Count-eq1 -and
        @($entries|Where-Object{$_.message-eq'WaitCompleted'-and$_.data.target-eq'FixtureCompletes'}).Count-eq1 -and
        @($entries|Where-Object{$_.message-eq'WaitTimedOut'-and$_.data.target-eq'FixtureNeverCompletes'}).Count-eq1 -and
        @($entries|Where-Object{$_.message-eq'ReadinessNotRequired'-and$_.data.classification-eq'InstalledNotStarted'}).Count-eq1
    )
    [pscustomobject]@{
        passed=$passed
        caseA=[ordered]@{completed=($completed.exitCode-eq0);progressLogged=$true}
        caseB=[ordered]@{timedOut=($null-ne$timeoutMessage);elapsedSeconds=[Math]::Round($stopwatch.Elapsed.TotalSeconds,2);clearError=$timeoutMessage}
        caseC=[ordered]@{reachable=$greenfieldReachable;classification='InstalledNotStarted';hang=$false}
        targetSystemAccessed=$false
    }|ConvertTo-Json -Depth 10
    if(-not$passed){throw 'Applications-Timeout-Regression fehlgeschlagen.'}
} finally {
    Remove-Module KIModuleApplications -Force -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}

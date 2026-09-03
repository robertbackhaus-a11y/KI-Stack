[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-ExitCode-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $temp -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Destination $temp
    New-Item -ItemType Directory -Path (Join-Path $temp 'Runtime') -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'Runtime/KIStackPathContext.psm1') -Destination (Join-Path $temp 'Runtime')
    $source=Get-Content -LiteralPath (Join-Path $PackageRoot 'Start-KIStackCompleteInstaller.ps1') -Raw
    $source=$source.Replace('if(-not(Test-KICompleteAdministrator)){','if($false){')
    $source=$source.Replace('$plan=New-KICompletePlan -Mode Upgrade -PackageRoot $PSScriptRoot -TargetRoot ''C:\KI-Stack'' -ReplayComponent $ReplayComponent','$plan=[pscustomobject]@{steps=@()}')
    $successScript=Join-Path $temp 'success.ps1';[IO.File]::WriteAllText($successScript,$source,[Text.UTF8Encoding]::new($false))
    $successLog=Join-Path $temp 'success.log'; & (Get-Command pwsh.exe).Source -NoLogo -NoProfile -File $successScript -Elevated -LoggingProbe -LogPath $successLog *> $null;$successCode=$LASTEXITCODE

    $failureSource=$source.Replace('$result=Invoke-KIStackCompleteInstaller -Mode Upgrade -PackageRoot $PSScriptRoot -TargetRoot ''C:\KI-Stack'' -TransactionId $TransactionId -Resume:$Resume -OpenWebUIApiToken $apiToken -ReplayComponent $ReplayComponent','$failure=[InvalidOperationException]::new(''Cutover-Kernel fehlgeschlagen: Exitcode 30''); $failure.Data[''KIStackExitCode'']=30; throw $failure')
    $failureScript=Join-Path $temp 'failure.ps1';[IO.File]::WriteAllText($failureScript,$failureSource,[Text.UTF8Encoding]::new($false))
    $failureLog=Join-Path $temp 'failure.log'; & (Get-Command pwsh.exe).Source -NoLogo -NoProfile -File $failureScript -Elevated -LogPath $failureLog *> $null;$failureCode=$LASTEXITCODE
    $restartSource=$source.Replace('$result=Invoke-KIStackCompleteInstaller -Mode Upgrade -PackageRoot $PSScriptRoot -TargetRoot ''C:\KI-Stack'' -TransactionId $TransactionId -Resume:$Resume -OpenWebUIApiToken $apiToken -ReplayComponent $ReplayComponent','$result=[pscustomobject]@{status=''WaitingForRestart'';transactionId=''TEST-RESTART''}')
    $restartScript=Join-Path $temp 'restart.ps1';[IO.File]::WriteAllText($restartScript,$restartSource,[Text.UTF8Encoding]::new($false))
    $restartLog=Join-Path $temp 'restart.log'; & (Get-Command pwsh.exe).Source -NoLogo -NoProfile -File $restartScript -Elevated -LogPath $restartLog *> $null;$restartCode=$LASTEXITCODE
    $cmdSource=Get-Content -LiteralPath (Join-Path $PackageRoot 'Start-KIStack-Installer.cmd') -Raw
    $bootstrapSafe=$cmdSource.Contains('call set "RC=%%ERRORLEVEL%%"')-and$cmdSource.Contains('if "%RC%"=="31"')
    $cmdFixture=Join-Path $temp 'cmd-bootstrap';New-Item -ItemType Directory -Path $cmdFixture -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $cmdFixture 'Start-KIStackCompleteInstaller.ps1'),'# fixture',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $cmdFixture 'CompleteInstaller.psm1'),'# fixture',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $cmdFixture 'Bootstrap-KIStackPowerShell7.ps1'),"param([string]`$InstallerScript,[string]`$LogPath); exit 30",[Text.UTF8Encoding]::new($false))
    $cmdFixtureSource=$cmdSource.Replace('if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"','rem fixture: PowerShell 7 absent').Replace('if not defined PWSH for /f "delims=" %%I in (''where pwsh.exe 2^>nul'') do if not defined PWSH set "PWSH=%%~fI"','rem fixture: PATH lookup disabled').Replace('pause','rem pause')
    $cmdFixturePath=Join-Path $cmdFixture 'Start-KIStack-Installer.cmd';[IO.File]::WriteAllText($cmdFixturePath,$cmdFixtureSource,[Text.Encoding]::ASCII)
    & $env:ComSpec /d /c $cmdFixturePath *> $null;$bootstrapFailureCode=$LASTEXITCODE
    $moduleText=Get-Content -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Raw
    $passed=$successCode-eq0-and$failureCode-eq30-and$restartCode-eq31-and$bootstrapFailureCode-eq30-and((Get-Content ($successLog+'.exitcode.txt') -Raw).Trim()-eq'0')-and((Get-Content ($failureLog+'.exitcode.txt') -Raw).Trim()-eq'30')-and((Get-Content ($restartLog+'.exitcode.txt') -Raw).Trim()-eq'31')-and$bootstrapSafe-and$moduleText.Contains("`$kernelFailure.Data['KIStackExitCode']=[int]`$process.ExitCode")
    [pscustomobject]@{passed=$passed;successExitCode=$successCode;innerFailureExitCode=30;outerFailureExitCode=$failureCode;rebootRequiredExitCode=$restartCode;bootstrapFailureExitCode=$bootstrapFailureCode;bootstrapErrorLevelLateBound=$bootstrapSafe;loggingPreserved=((Test-Path ($failureLog+'.transcript.txt'))-and(Test-Path ($failureLog+'.stderr.txt')));targetSystemAccessed=$false}|ConvertTo-Json -Depth 10
    if(-not$passed){throw 'Exitcode-Propagation-Regression fehlgeschlagen.'}
}finally{if(Test-Path $temp){Remove-Item $temp -Recurse -Force}}

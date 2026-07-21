Set-StrictMode -Version Latest

function Get-KIIntegrationProperty {
    param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name,[AllowNull()][object]$Default=$null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}

function Remove-KIIntegrationNullCharacters {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return [string]::Empty }
    return $Value.Replace(([char]0).ToString(), [string]::Empty)
}

function Invoke-KIIntegrationNative {
    param([Parameter(Mandatory)][string]$FilePath,[Parameter(Mandatory)][string[]]$ArgumentList)
    $commandOutput = @(& $FilePath @ArgumentList 2>&1)
    $nativeExitCode = $LASTEXITCODE
    return [pscustomobject][ordered]@{ exitCode=$nativeExitCode; output=@($commandOutput|ForEach-Object{[string]$_}) }
}

function Get-KIIntegrationWslCommand {
    $command = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $command) { $command = Get-Command wsl -ErrorAction SilentlyContinue }
    return $command
}

function Get-KIIntegrationDistributions {
    param([Parameter(Mandatory)][object]$WslCommand)
    $result = Invoke-KIIntegrationNative -FilePath ([string]$WslCommand.Source) -ArgumentList @('--list','--quiet')
    if ($result.exitCode -ne 0) { return @() }
    return @($result.output | ForEach-Object { (Remove-KIIntegrationNullCharacters -Value ([string]$_)).Trim() } | Where-Object { $_ })
}


function Get-KIIntegrationDistributionVersion {
    param(
        [Parameter(Mandatory)][object]$WslCommand,
        [Parameter(Mandatory)][string]$Distribution
    )

    try {
        $lxssRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
        if (Test-Path -LiteralPath $lxssRoot -PathType Container) {
            foreach ($key in @(Get-ChildItem -LiteralPath $lxssRoot -ErrorAction Stop)) {
                $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                $distributionName = [string](Get-KIIntegrationProperty -Object $properties -Name 'DistributionName' -Default '')
                if ($distributionName -ieq $Distribution) {
                    $registryVersion = Get-KIIntegrationProperty -Object $properties -Name 'Version' -Default $null
                    if ($null -ne $registryVersion) { return [int]$registryVersion }
                }
            }
        }
    }
    catch {
    }

    $verboseResult = Invoke-KIIntegrationNative -FilePath ([string]$WslCommand.Source) -ArgumentList @('--list','--verbose')
    if ($verboseResult.exitCode -ne 0) { return $null }
    $escapedDistribution = [regex]::Escape($Distribution)
    foreach ($rawLine in @($verboseResult.output)) {
        $line = (Remove-KIIntegrationNullCharacters -Value ([string]$rawLine)).Trim()
        if ($line -match ('^\*?\s*' + $escapedDistribution + '\s+.+?\s+([12])\s*$')) {
            return [int]$Matches[1]
        }
    }
    return $null
}

function Test-KIIntegrationDistributionWsl2 {
    param(
        [Parameter(Mandatory)][object]$WslCommand,
        [Parameter(Mandatory)][string]$Distribution
    )
    return ((Get-KIIntegrationDistributionVersion -WslCommand $WslCommand -Distribution $Distribution) -eq 2)
}

function Invoke-KIIntegrationWslBash {
    param([Parameter(Mandatory)][object]$WslCommand,[Parameter(Mandatory)][string]$Distribution,[Parameter(Mandatory)][string]$Command)
    return Invoke-KIIntegrationNative -FilePath ([string]$WslCommand.Source) -ArgumentList @('-d',$Distribution,'-u','root','--','bash','-lc',$Command)
}

function ConvertTo-KIShellSingleQuoted {
    param([Parameter(Mandatory)][string]$Value)
    $singleQuoteEscape = "'" + [char]34 + "'" + [char]34 + "'"
    return "'" + $Value.Replace("'", $singleQuoteEscape) + "'"
}

function Copy-KIIntegrationFileToWsl {
    param([Parameter(Mandatory)][object]$WslCommand,[Parameter(Mandatory)][string]$Distribution,[Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination,[string]$Mode='0700')
    $encoded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Source))
    $destinationQuoted = ConvertTo-KIShellSingleQuoted -Value $Destination
    $command = "install -d -m 0700 /tmp/ki-stack-integration && printf '%s' '$encoded' | base64 -d > $destinationQuoted && chmod $Mode $destinationQuoted"
    $result = Invoke-KIIntegrationWslBash -WslCommand $WslCommand -Distribution $Distribution -Command $command
    if ($result.exitCode -ne 0) { throw ('WSL-Dateikopie fehlgeschlagen: {0}' -f ($result.output -join ' | ')) }
}

function Get-KIIntegrationRollbackStatePath {
    param([Parameter(Mandatory)][object]$Context)
    $directory=Join-Path ([string]$Context.TransactionDirectory) 'module-state'
    if(-not(Test-Path -LiteralPath $directory -PathType Container)){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
    return Join-Path $directory 'KIModuleIntegration.rollback.json'
}

function Write-KIIntegrationRollbackState {
    param([Parameter(Mandatory)][object]$Context,[Parameter(Mandatory)][object]$State)
    $path=Get-KIIntegrationRollbackStatePath -Context $Context
    $temporaryPath=$path+'.tmp'; $State.updatedAt=(Get-Date).ToString('o')
    $State|ConvertTo-Json -Depth 100|Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $path -Force
}

function Read-KIIntegrationRollbackState {
    param([Parameter(Mandatory)][object]$Context)
    $path=Get-KIIntegrationRollbackStatePath -Context $Context
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    return Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -Depth 100
}

function Install-KIIntegrationWindowsFile {
    param([Parameter(Mandatory)][object]$Context,[Parameter(Mandatory)][object]$RollbackState,[Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Content)
    $existing=$null; $existed=Test-Path -LiteralPath $Path -PathType Leaf
    if($existed){$existing=[Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))}
    if(-not(@($RollbackState.files|Where-Object{[string]$_.path -eq $Path}).Count)){
        $RollbackState.files += [pscustomobject][ordered]@{path=$Path;existedBefore=$existed;previousContentBase64=$existing}
        Write-KIIntegrationRollbackState -Context $Context -State $RollbackState
    }
    $parent=Split-Path -Parent $Path
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    [IO.File]::WriteAllText($Path,$Content.Replace("`r`n","`n").Replace("`r","`n").Replace("`n","`r`n"),[Text.UTF8Encoding]::new($false))
}

function Test-KIIntegrationJsonEndpoint {
    param([Parameter(Mandatory)][string]$BaseUrl,[int]$TimeoutSeconds=15)
    try {
        $uri=$BaseUrl.TrimEnd('/')+'/search?q=ki-stack&format=json'
        $response=Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        return ($null -ne $response -and $null -ne $response.PSObject.Properties['results'])
    } catch { return $false }
}

function Get-KIIntegrationAssetRoot {
    $projectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    return Join-Path $projectRoot 'Integration\Linux'
}

function Test-KIModuleIntegration {
    param([Parameter(Mandatory)][object]$Context)
    $config=$Context.Config.integration; $wsl=Get-KIIntegrationWslCommand
    if(-not $wsl){
        return [pscustomobject][ordered]@{success=$false;skipped=$false;message='wsl.exe wurde nicht gefunden.';data=$null}
    }
    $distributions=Get-KIIntegrationDistributions -WslCommand $wsl
    $distributionPresent=@($distributions|Where-Object{$_ -ieq [string]$config.wslDistribution}).Count -gt 0
    $endpointHealthy=Test-KIIntegrationJsonEndpoint -BaseUrl ([string]$config.searxngUrl) -TimeoutSeconds ([int]$config.timeoutSeconds
    )
    return [pscustomobject][ordered]@{
        success=($distributionPresent -or [bool]$config.allowWslInstall)
        skipped=$false
        message='WSL-, Debian- und SearXNG-Ausgangszustand geprüft.'
        data=[pscustomobject][ordered]@{distributionPresent=$distributionPresent;distributions=$distributions;searxngJsonHealthy=$endpointHealthy}
    }
}

function Install-KIModuleIntegration {
    param([Parameter(Mandatory)][object]$Context)
    $config=$Context.Config.integration
    if($Context.Mode -eq 'DryRun'){
        return [pscustomobject][ordered]@{success=$true;skipped=$false;message='Dry-Run: WSL/Debian, SearXNG, Keeper und Open-WebUI-Websuche würden eingerichtet oder übernommen.';data=[pscustomobject][ordered]@{distribution=[string]$config.wslDistribution;ref=[string]$config.searxngRef;url=[string]$config.searxngUrl}}
    }
    $wsl=Get-KIIntegrationWslCommand
    if(-not $wsl){throw 'wsl.exe wurde nicht gefunden. WSL muss durch Windows bereitgestellt werden.'}
    $distribution=[string]$config.wslDistribution
    $rollbackState=[pscustomobject][ordered]@{schemaVersion='1.0';transactionId=[string]$Context.Transaction.transactionId;updatedAt=(Get-Date).ToString('o');distroInstalledByTransaction=$false;linuxChanged=$false;files=@()}
    Write-KIIntegrationRollbackState -Context $Context -State $rollbackState
    $distributions=Get-KIIntegrationDistributions -WslCommand $wsl
    if(@($distributions|Where-Object{$_ -ieq $distribution}).Count -eq 0){
        if (-not [bool]$config.allowWslInstall){throw "WSL-Distribution '$distribution' fehlt und Installation ist deaktiviert."}
        $installResult=Invoke-KIIntegrationNative -FilePath ([string]$wsl.Source) -ArgumentList @('--install','--distribution',$distribution,'--no-launch','--web-download')
        if($installResult.exitCode -ne 0){
            $installResult=Invoke-KIIntegrationNative -FilePath ([string]$wsl.Source) -ArgumentList @('--install','--distribution',$distribution,'--no-launch')
        }
        Start-Sleep -Seconds 3
        $distributions=Get-KIIntegrationDistributions -WslCommand $wsl
        if(@($distributions|Where-Object{$_ -ieq $distribution}).Count -eq 0){throw ("Debian-Installation ist noch nicht aktiv. Windows-Neustart kann erforderlich sein. Ausgabe: {0}" -f ($installResult.output -join ' | '))}
        $rollbackState.distroInstalledByTransaction=$true; Write-KIIntegrationRollbackState -Context $Context -State $rollbackState
    }
    if([bool]$config.requireWsl2){
        $wslVersionBefore = Get-KIIntegrationDistributionVersion -WslCommand $wsl -Distribution $distribution
        if($wslVersionBefore -ne 2){
            $setVersion=Invoke-KIIntegrationNative -FilePath ([string]$wsl.Source) -ArgumentList @('--set-version',$distribution,'2')
            Start-Sleep -Seconds 2
            $wslVersionAfter = Get-KIIntegrationDistributionVersion -WslCommand $wsl -Distribution $distribution
            if($wslVersionAfter -ne 2){
                throw ('WSL2 konnte für {0} nicht sichergestellt werden. Vorher={1}; Nachher={2}; Exitcode={3}; Ausgabe={4}' -f $distribution,$wslVersionBefore,$wslVersionAfter,$setVersion.exitCode,($setVersion.output -join ' | '))
            }
            if($setVersion.exitCode -ne 0){
                Write-Host ('WSL meldete Exitcode {0}, der validierte Endzustand ist jedoch Version 2. Der Endzustand entscheidet.' -f $setVersion.exitCode)
            }
        }
    }
    $assetRoot=Get-KIIntegrationAssetRoot
    $installerPath=Join-Path $assetRoot 'install-ki-stack-searxng.sh'
    $rollbackPath=Join-Path $assetRoot 'rollback-ki-stack-searxng.sh'
    foreach($required in @($installerPath,$rollbackPath)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "Integrationsasset fehlt: $required"}}
    Copy-KIIntegrationFileToWsl -WslCommand $wsl -Distribution $distribution -Source $installerPath -Destination '/tmp/ki-stack-integration/install.sh'
    Copy-KIIntegrationFileToWsl -WslCommand $wsl -Distribution $distribution -Source $rollbackPath -Destination '/tmp/ki-stack-integration/rollback.sh'
    $environmentCommand=(
        'KI_RELEASE={0} KI_SEARXNG_REPOSITORY={1} KI_SEARXNG_REF={2} KI_SEARXNG_BASE_URL={3} KI_SEARXNG_BACKEND_PORT={4} /tmp/ki-stack-integration/install.sh' -f
        (ConvertTo-KIShellSingleQuoted -Value $Context.Config.kernelVersion),
        (ConvertTo-KIShellSingleQuoted -Value ([string]$config.searxngRepository)),
        (ConvertTo-KIShellSingleQuoted -Value ([string]$config.searxngRef)),
        (ConvertTo-KIShellSingleQuoted -Value (([string]$config.searxngUrl).TrimEnd('/')+'/')),
        [int]$config.backendPort
    )
    $installResult=Invoke-KIIntegrationWslBash -WslCommand $wsl -Distribution $distribution -Command $environmentCommand
    if($installResult.exitCode -eq 42){
        [void](Invoke-KIIntegrationNative -FilePath ([string]$wsl.Source) -ArgumentList @('--terminate',$distribution))
        Start-Sleep -Seconds 3
        $installResult=Invoke-KIIntegrationWslBash -WslCommand $wsl -Distribution $distribution -Command $environmentCommand
    }
    foreach($line in @($installResult.output)){Write-Host $line}
    if($installResult.exitCode -ne 0){throw ('SearXNG-Installation fehlgeschlagen. Exitcode: {0}; Ausgabe: {1}' -f $installResult.exitCode,($installResult.output -join ' | '))}
    $markerResult=Invoke-KIIntegrationWslBash -WslCommand $wsl -Distribution $distribution -Command 'cat /opt/ki-stack/integration/installation.json'
    if($markerResult.exitCode -ne 0){throw 'Linux-Integrationsmarker konnte nicht gelesen werden.'}
    $linuxMarker=($markerResult.output -join "`n")|ConvertFrom-Json -Depth 30
    $rollbackState.linuxChanged=[bool]$linuxMarker.linuxChanged; Write-KIIntegrationRollbackState -Context $Context -State $rollbackState

    $moduleRoot=[string]$config.moduleRoot; if(-not(Test-Path -LiteralPath $moduleRoot)){New-Item -ItemType Directory -Path $moduleRoot -Force|Out-Null}
    $startPs=@'
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$distribution='__DISTRO__'
$pidFile='__PID_FILE__'
$wsl=(Get-Command wsl.exe -ErrorAction Stop).Source
function Test-ExpectedKeeper([int]$ProcessId){$p=Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue;if($null-eq$p){return $false};$c=[string]$p.CommandLine;return ([string]$p.Name-ieq'wsl.exe'-and$c-match'(?i)(?:^|\s)-d\s+Debian(?:\s|$)'-and$c-match'(?i)--exec\s+sleep\s+infinity')}
$keeperAlive=$false
if(Test-Path -LiteralPath $pidFile -PathType Leaf){$raw=(Get-Content -LiteralPath $pidFile -Raw).Trim();if($raw-match'^\d+$'){$keeperAlive=Test-ExpectedKeeper -ProcessId([int]$raw)};if(-not$keeperAlive){Remove-Item -LiteralPath $pidFile -Force;Write-Host 'Veraltete oder fremde Keeper-PID-Datei wurde bereinigt.'}}
if(-not $keeperAlive){
  $keeper=Start-Process -FilePath $wsl -ArgumentList @('-d',$distribution,'-u','root','--exec','sleep','infinity') -WindowStyle Hidden -PassThru
  Set-Content -LiteralPath $pidFile -Value ([string]$keeper.Id) -Encoding ascii
  $verified=$false;for($attempt=0;$attempt-lt 20-and-not$verified;$attempt++){Start-Sleep -Milliseconds 250;$verified=Test-ExpectedKeeper -ProcessId $keeper.Id}
  if(-not$verified){Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue;throw 'WSL-Keeper konnte nicht verifiziert werden.'}
}
$probe=@(& $wsl -d $distribution -u root -- bash -lc 'test -e /etc/uwsgi/apps-enabled/searxng.ini && test -e /etc/nginx/default.d/searxng.conf && test -f /etc/searxng/settings.yml' 2>&1)
if($LASTEXITCODE-ne 0){throw 'Reale SearXNG-Standardkonfiguration fehlt (uWSGI, nginx oder settings.yml).'}
$output=@(& $wsl -d $distribution -u root -- bash -lc 'systemctl start valkey-server uwsgi nginx && systemctl is-active --quiet valkey-server uwsgi nginx' 2>&1)
if($LASTEXITCODE-ne 0){throw ('Linux-Dienste konnten nicht gestartet werden: '+($output-join ' | '))}
$deadline=(Get-Date).AddSeconds(30)
do { try{$tcp=Test-NetConnection -ComputerName localhost -Port 80 -InformationLevel Quiet -WarningAction SilentlyContinue;$html=Invoke-WebRequest -Uri 'http://localhost/searxng/' -MaximumRedirection 0 -TimeoutSec 5 -ErrorAction Stop;$json=Invoke-WebRequest -Uri 'http://localhost/searxng/search?q=ki-stack&format=json' -MaximumRedirection 0 -TimeoutSec 10 -ErrorAction Stop;$payload=$json.Content|ConvertFrom-Json -Depth 20;if($tcp-and[int]$html.StatusCode-eq200-and[int]$json.StatusCode-eq200-and[string]$json.Headers.'Content-Type'-match'application/json'-and$null-ne$payload.PSObject.Properties['results']){Write-Host 'SearXNG-Standarddienstkette, Webseite und JSON-Suche sind erreichbar.';return}}catch{};Start-Sleep -Seconds 1 } while((Get-Date) -lt  $deadline)
throw 'SearXNG ist nach 30 Sekunden nicht erreichbar.'
'@
    $startPs=$startPs.Replace('__DISTRO__',$distribution.Replace("'","''")).Replace('__PID_FILE__',([string]$config.keeperPidFile).Replace("'","''"))
    $stopPs=@'
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$distribution='__DISTRO__';$pidFile='__PID_FILE__';$wsl=(Get-Command wsl.exe -ErrorAction Stop).Source
function Test-ExpectedKeeper([int]$ProcessId){$p=Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue;if($null-eq$p){return $false};$c=[string]$p.CommandLine;return ([string]$p.Name-ieq'wsl.exe'-and$c-match'(?i)(?:^|\s)-d\s+Debian(?:\s|$)'-and$c-match'(?i)--exec\s+sleep\s+infinity')}
$stopped=$false
if(Test-Path -LiteralPath $pidFile -PathType Leaf){$raw=(Get-Content -LiteralPath $pidFile -Raw).Trim();if($raw-match'^\d+$'-and(Test-ExpectedKeeper -ProcessId([int]$raw))){Stop-Process -Id([int]$raw)-Force -ErrorAction Stop;$stopped=$true};Remove-Item -LiteralPath $pidFile -Force}
$status=@(& $wsl -d $distribution -u root -- bash -lc 'for s in valkey-server uwsgi nginx; do printf "%s=%s " "$s" "$(systemctl is-active "$s" 2>/dev/null || true)"; done' 2>&1)
Write-Host ('WSL-Keeper beendet={0}; Standarddienste bleiben unverändert: {1}'-f $stopped,($status-join' '))
'@
    $stopPs=$stopPs.Replace('__DISTRO__',$distribution.Replace("'","''")).Replace('__PID_FILE__',([string]$config.keeperPidFile).Replace("'","''"))
    $cmdTemplate=@'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "PWSH="
if defined ProgramW6432 if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined PWSH if defined ProgramFiles if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH set "PWSH=%%~fI"
if not defined PWSH exit /b 1
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0__SCRIPT__"
exit /b %ERRORLEVEL%
'@
    $webCmd=@'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "ENABLE_WEB_SEARCH=True"
set "WEB_SEARCH_ENGINE=searxng"
set "WEB_SEARCH_RESULT_COUNT=__RESULT_COUNT__"
set "WEB_SEARCH_CONCURRENT_REQUESTS=__SEARCH_CONCURRENCY__"
set "WEB_LOADER_CONCURRENT_REQUESTS=__LOADER_CONCURRENCY__"
set "SEARXNG_QUERY_URL=__QUERY_URL__"
call "C:\KI-Stack\modules\applications\Start-KIStack-OpenWebUI.cmd"
exit /b %ERRORLEVEL%
'@
    $webCmd=$webCmd.Replace('__RESULT_COUNT__',[string]$config.webSearchResultCount).Replace('__SEARCH_CONCURRENCY__',[string]$config.webSearchConcurrentRequests).Replace('__LOADER_CONCURRENCY__',[string]$config.webLoaderConcurrentRequests).Replace('__QUERY_URL__',[string]$config.searxngQueryUrl)
    $allCmd=@'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
call "%~dp0Start-KIStack-SearXNG.cmd"
if errorlevel 1 exit /b %ERRORLEVEL%
start "KI-Stack LM Studio" cmd.exe /D /C call "C:\KI-Stack\modules\applications\Start-KIStack-LMStudio.cmd"
timeout /t 3 /nobreak >nul
start "KI-Stack Open WebUI + SearXNG" cmd.exe /D /K call "%~dp0Start-KIStack-OpenWebUI-WithSearch.cmd"
exit /b 0
'@
    $stopAllCmd=@'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
call "C:\KI-Stack\modules\applications\Stop-KIStack-Applications.cmd"
call "%~dp0Stop-KIStack-SearXNG.cmd"
exit /b %ERRORLEVEL%
'@
    $files=@{
      (Join-Path $moduleRoot 'Start-KIStack-SearXNG.ps1')=$startPs;
      (Join-Path $moduleRoot 'Stop-KIStack-SearXNG.ps1')=$stopPs;
      (Join-Path $moduleRoot 'Start-KIStack-SearXNG.cmd')=$cmdTemplate.Replace('__SCRIPT__','Start-KIStack-SearXNG.ps1');
      (Join-Path $moduleRoot 'Stop-KIStack-SearXNG.cmd')=$cmdTemplate.Replace('__SCRIPT__','Stop-KIStack-SearXNG.ps1');
      (Join-Path $moduleRoot 'Start-KIStack-OpenWebUI-WithSearch.cmd')=$webCmd;
      (Join-Path $moduleRoot 'Start-KIStack-IntegratedStack.cmd')=$allCmd;
      (Join-Path $moduleRoot 'Stop-KIStack-IntegratedStack.cmd')=$stopAllCmd
    }
    foreach($path in $files.Keys){Install-KIIntegrationWindowsFile -Context $Context -RollbackState $rollbackState -Path $path -Content ([string]$files[$path])}
    $marker=[pscustomobject][ordered]@{schemaVersion='1.0';managedBy='KI-STACK-INTEGRATION-MANAGED';release=('KI-Stack-Integration-Execute-v'+[string]$Context.Config.kernelVersion);installedAt=(Get-Date).ToString('o');transactionId=[string]$Context.Transaction.transactionId;distribution=$distribution;searxngUrl=[string]$config.searxngUrl;searxngRef=[string]$config.searxngRef;linuxMode=[string]$linuxMarker.mode}
    Install-KIIntegrationWindowsFile -Context $Context -RollbackState $rollbackState -Path ([string]$config.installationMarker) -Content ($marker|ConvertTo-Json -Depth 20)
    return [pscustomobject][ordered]@{success=$true;skipped=$false;message='WSL/SearXNG und Open-WebUI-Websuche wurden eingerichtet oder übernommen.';data=[pscustomobject][ordered]@{distribution=$distribution;linuxMode=[string]$linuxMarker.mode;searxngUrl=[string]$config.searxngUrl;starter=(Join-Path $moduleRoot 'Start-KIStack-IntegratedStack.cmd')}}
}

function Validate-KIModuleIntegration {
    param([Parameter(Mandatory)][object]$Context)
    if($Context.Mode -eq 'DryRun'){
      $dryRunEndpoints=@(
        [pscustomobject][ordered]@{name='searxngUrl';url=[string]$Context.Config.integration.searxngUrl},
        [pscustomobject][ordered]@{name='openWebUIUrl';url=[string]$Context.Config.integration.openWebUIUrl},
        [pscustomobject][ordered]@{name='lmStudioUrl';url=[string]$Context.Config.integration.lmStudioUrl},
        [pscustomobject][ordered]@{name='comfyUIUrl';url=[string]$Context.Config.integration.comfyUIUrl}
      )
      return [pscustomobject][ordered]@{success=$true;skipped=$false;message='Dry-Run: Integration ist vollständig planbar.';data=[pscustomobject][ordered]@{endpoints=$dryRunEndpoints}}
    }
    $config=$Context.Config.integration; $issues=[System.Collections.Generic.List[string]]::new();$wsl=Get-KIIntegrationWslCommand
    if(-not $wsl){[void]$issues.Add('wsl.exe fehlt.')}else{
      $distribution=[string]$config.wslDistribution;$distributions=Get-KIIntegrationDistributions -WslCommand $wsl
      if(@($distributions|Where-Object{$_ -ieq $distribution}).Count -eq 0){[void]$issues.Add("Distribution '$distribution' fehlt.")}
      else{
        $service=Invoke-KIIntegrationWslBash -WslCommand $wsl -Distribution $distribution -Command 'systemctl is-active nginx >/dev/null && (systemctl is-active valkey-server >/dev/null)'
        if ($service.exitCode -ne 0){[void]$issues.Add('nginx oder valkey-server ist nicht aktiv.')}
      }
    }
    if (-not (Test-KIIntegrationJsonEndpoint -BaseUrl ([string]$config.searxngUrl) -TimeoutSeconds ([int]$config.timeoutSeconds))) { [void]$issues.Add('SearXNG-JSON-Endpunkt ist nicht erreichbar.') }
    foreach($required in @([string]$config.installationMarker,(Join-Path ([string]$config.moduleRoot) 'Start-KIStack-SearXNG.cmd'),(Join-Path ([string]$config.moduleRoot) 'Start-KIStack-OpenWebUI-WithSearch.cmd'),(Join-Path ([string]$config.moduleRoot) 'Start-KIStack-IntegratedStack.cmd'))){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){[void]$issues.Add("Integrationsdatei fehlt: $required")}}
    return [pscustomobject][ordered]@{success=($issues.Count -eq 0);skipped=$false;message=if($issues.Count -eq 0){'WSL/SearXNG, JSON-API und Integrationsstarter wurden validiert.'}else{$issues-join ' | '};data=[pscustomobject][ordered]@{issues=@($issues);searxngUrl=[string]$config.searxngUrl}}
}

function Rollback-KIModuleIntegration {
    param([Parameter(Mandatory)][object]$Context)
    if($Context.Mode -eq 'DryRun'){return [pscustomobject][ordered]@{success=$true;skipped=$true;message='Dry-Run: Kein Integrationsrollback erforderlich.';data=$null}}
    $state=Read-KIIntegrationRollbackState -Context $Context
    if(-not $state){return [pscustomobject][ordered]@{success=$true;skipped=$true;message='Kein Integrationsrollbackjournal vorhanden.';data=$null}}
    $issues=[System.Collections.Generic.List[string]]::new()
    if([bool]$state.linuxChanged){try{$wsl=Get-KIIntegrationWslCommand;if($wsl){$result=Invoke-KIIntegrationWslBash -WslCommand $wsl -Distribution ([string]$Context.Config.integration.wslDistribution) -Command '/tmp/ki-stack-integration/rollback.sh';if($result.exitCode-ne 0){[void]$issues.Add($result.output-join ' | ')}}}catch{[void]$issues.Add($_.Exception.Message)}}
    foreach($entry in @($state.files)|Sort-Object{([string]$_.path).Length}-Descending){try{if([bool]$entry.existedBefore){[IO.File]::WriteAllBytes([string]$entry.path,[Convert]::FromBase64String([string]$entry.previousContentBase64))}elseif(Test-Path -LiteralPath ([string]$entry.path)-PathType Leaf){Remove-Item -LiteralPath ([string]$entry.path)-Force}}catch{[void]$issues.Add($_.Exception.Message)}}
    return [pscustomobject][ordered]@{success=($issues.Count -eq 0);skipped=$false;message=if($issues.Count -eq 0){'Integrationsänderungen wurden zurückgesetzt; eine neu installierte WSL-Distribution bleibt aus Sicherheitsgründen registriert.'}else{$issues-join ' | '};data=[pscustomobject][ordered]@{issues=@($issues);distroRetained=[bool]$state.distroInstalledByTransaction}}
}

Export-ModuleMember -Function *

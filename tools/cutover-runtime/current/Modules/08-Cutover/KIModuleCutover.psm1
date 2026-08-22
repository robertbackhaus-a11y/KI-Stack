Set-StrictMode -Version Latest

function Get-KICutoverRollbackStatePath {
    param([Parameter(Mandatory)][object]$Context)
    $directory = Join-Path ([string]$Context.TransactionDirectory) 'module-state'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    return Join-Path $directory 'KIModuleCutover.rollback.json'
}

function Write-KICutoverRollbackState {
    param([Parameter(Mandatory)][object]$Context,[Parameter(Mandatory)][object]$State)
    $path = Get-KICutoverRollbackStatePath -Context $Context
    $temporaryPath = $path + '.tmp'
    $State.updatedAt = (Get-Date).ToString('o')
    $State | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $path -Force
}

function Read-KICutoverRollbackState {
    param([Parameter(Mandatory)][object]$Context)
    $path = Get-KICutoverRollbackStatePath -Context $Context
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100
}

function Install-KICutoverManagedFile {
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][object]$RollbackState,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    $existingEntry = @($RollbackState.files | Where-Object { [string]$_.path -eq $Path })
    if ($existingEntry.Count -eq 0) {
        $existedBefore = Test-Path -LiteralPath $Path -PathType Leaf
        $previousContentBase64 = if ($existedBefore) {
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
        } else { $null }
        $RollbackState.files = @($RollbackState.files) + @([pscustomobject][ordered]@{
            path = $Path
            existedBefore = $existedBefore
            previousContentBase64 = $previousContentBase64
        })
        Write-KICutoverRollbackState -Context $Context -State $RollbackState
    }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText(
        $Path,
        $Content.Replace("`r`n","`n").Replace("`r","`n").Replace("`n","`r`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-KICutoverEndpointDefinitions {
    param([Parameter(Mandatory)][object]$Context)
    return @($Context.Config.cutover.endpoints | ForEach-Object {
        [pscustomobject][ordered]@{
            name = [string]$_.name
            kind = [string]$_.kind
            url = [string]$_.url
        }
    })
}

function Test-KICutoverEndpoint {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSeconds = 10
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $reachable = $false
    $detail = ''
    try {
        if ($Kind -in @('searxng','openai','json')) {
            $response = Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec $TimeoutSeconds -ErrorAction Stop
            if ($Kind -eq 'searxng') {
                $reachable = ($null -ne $response.PSObject.Properties['results'])
            }
            elseif ($Kind -eq 'openai') {
                $reachable = ($null -ne $response.PSObject.Properties['data'])
            }
            else {
                $reachable = ($null -ne $response)
            }
        }
        else {
            $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $TimeoutSeconds -SkipHttpErrorCheck -ErrorAction Stop
            $reachable = ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 500)
        }
        $detail = if ($reachable) { 'Endpoint erreichbar.' } else { 'Antwort entspricht nicht dem erwarteten Vertrag.' }
    }
    catch { $detail = $_.Exception.Message }
    finally { $stopwatch.Stop() }
    return [pscustomobject][ordered]@{
        name = $Name
        kind = $Kind
        url = $Url
        reachable = $reachable
        durationMs = [int64]$stopwatch.ElapsedMilliseconds
        detail = $detail
    }
}

function Get-KICutoverHealthSnapshot {
    param([Parameter(Mandatory)][object]$Context,[int]$TimeoutSeconds=10)
    $results = @(
        Get-KICutoverEndpointDefinitions -Context $Context | ForEach-Object {
            Test-KICutoverEndpoint -Name $_.name -Kind $_.kind -Url $_.url -TimeoutSeconds $TimeoutSeconds
        }
    )
    return [pscustomobject][ordered]@{
        generatedAt = (Get-Date).ToString('o')
        allReachable = (@($results | Where-Object { -not [bool]$_.reachable }).Count -eq 0)
        endpoints = $results
    }
}

function Get-KICutoverRequiredSourceFiles {
    param([Parameter(Mandatory)][object]$Context)
    $start = $Context.Config.cutover.startScripts
    $stop = $Context.Config.cutover.stopScripts
    return @(
        [string]$start.searxng,
        [string]$start.lmStudio,
        [string]$start.openWebUI,
        [string]$start.comfyUI,
        [string]$stop.applications,
        [string]$stop.searxng,
        [string]$stop.comfyUI
    )
}

function Get-KICutoverGeneratedContent {
    param([Parameter(Mandatory)][object]$Context)
    $configJson = $Context.Config.cutover | ConvertTo-Json -Depth 50 -Compress
    $healthScript = @'
[CmdletBinding()]
param([int]$TimeoutSeconds=10)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$config = '__CONFIG_JSON__' | ConvertFrom-Json -Depth 50
$results = [System.Collections.Generic.List[object]]::new()
foreach($endpoint in @($config.endpoints)){
 $sw=[Diagnostics.Stopwatch]::StartNew();$ok=$false;$detail=''
 try{
  if([string]$endpoint.kind -in @('searxng','openai','json')){
   $response=Invoke-RestMethod -Uri ([string]$endpoint.url) -Method Get -TimeoutSec $TimeoutSeconds -ErrorAction Stop
   if([string]$endpoint.kind -eq 'searxng'){$ok=($null-ne $response.PSObject.Properties['results'])}
   elseif([string]$endpoint.kind -eq 'openai'){$ok=($null-ne $response.PSObject.Properties['data'])}
   else{$ok=($null-ne $response)}
  }else{
   $response=Invoke-WebRequest -Uri ([string]$endpoint.url) -Method Get -TimeoutSec $TimeoutSeconds -SkipHttpErrorCheck -ErrorAction Stop
   $ok=([int]$response.StatusCode-ge 200 -and [int]$response.StatusCode-lt 500)
  }
  $detail=if($ok){'Endpoint erreichbar.'}else{'Antwortvertrag nicht erfüllt.'}
 }catch{$detail=$_.Exception.Message}finally{$sw.Stop()}
 [void]$results.Add([pscustomobject][ordered]@{name=[string]$endpoint.name;kind=[string]$endpoint.kind;url=[string]$endpoint.url;reachable=$ok;durationMs=[int64]$sw.ElapsedMilliseconds;detail=$detail})
}
$report=[pscustomobject][ordered]@{generatedAt=(Get-Date).ToString('o');allReachable=(@($results|Where-Object{-not [bool]$_.reachable}).Count-eq 0);endpoints=@($results)}
$reportRoot=[string]$config.reportRoot
if(-not(Test-Path -LiteralPath $reportRoot -PathType Container)){New-Item -ItemType Directory -Path $reportRoot -Force|Out-Null}
$json=$report|ConvertTo-Json -Depth 50
Set-Content -LiteralPath ([string]$config.healthReportPath) -Value $json -Encoding UTF8
$json
if(-not [bool]$report.allReachable){exit 1}
exit 0
'@
    $healthScript = $healthScript.Replace('__CONFIG_JSON__',$configJson.Replace("'","''"))
    $startScript = @'
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$config='__CONFIG_JSON__'|ConvertFrom-Json -Depth 50
function Start-Managed([string]$Name,[string]$Path){
 if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Startskript fehlt: $Path"}
 Write-Host ("Starte {0}: {1}" -f $Name,$Path)
 Start-Process -FilePath $env:ComSpec -ArgumentList @('/D','/C','call',('"'+$Path+'"')) -WindowStyle Minimized|Out-Null
}
Start-Managed 'SearXNG' ([string]$config.startScripts.searxng)
Start-Sleep -Seconds 2
Start-Managed 'ComfyUI' ([string]$config.startScripts.comfyUI)
Start-Managed 'LM Studio' ([string]$config.startScripts.lmStudio)
Start-Sleep -Seconds 3
Start-Managed 'Open WebUI' ([string]$config.startScripts.openWebUI)
Start-Sleep -Seconds ([int]$config.startupGraceSeconds)
$healthScript=Join-Path $PSScriptRoot 'Test-KIStack-Health.ps1'
& $healthScript -TimeoutSeconds 10
'@
    $startScript = $startScript.Replace('__CONFIG_JSON__',$configJson.Replace("'","''"))
    $stopScript = @'
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Continue'
$config='__CONFIG_JSON__'|ConvertFrom-Json -Depth 50
foreach($entry in @(
 [pscustomobject]@{name='Applications';path=[string]$config.stopScripts.applications},
 [pscustomobject]@{name='ComfyUI';path=[string]$config.stopScripts.comfyUI},
 [pscustomobject]@{name='SearXNG';path=[string]$config.stopScripts.searxng}
)){
 if(Test-Path -LiteralPath $entry.path -PathType Leaf){Write-Host ("Stoppe {0}" -f $entry.name);& $env:ComSpec /D /C call ('"'+$entry.path+'"')|Out-Host}
}
exit 0
'@
    $stopScript = $stopScript.Replace('__CONFIG_JSON__',$configJson.Replace("'","''"))
    $cmdTemplate = @'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "PWSH="
if defined ProgramW6432 if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined PWSH if defined ProgramFiles if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH if exist "%%~fI" set "PWSH=%%~fI"
if not defined PWSH (echo FEHLER: PowerShell 7 wurde nicht gefunden.& set "EC=1"& goto :Finish)
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0__SCRIPT__"
set "EC=%ERRORLEVEL%"
:Finish
echo.
if "%EC%"=="0" (echo Vorgang erfolgreich abgeschlossen. Exitcode: 0) else (echo Vorgang fehlgeschlagen. Exitcode: %EC%)
echo Druecken Sie eine beliebige Taste, um dieses Fenster zu schliessen.
pause >nul
exit /b %EC%
'@
    return [pscustomobject][ordered]@{
        startPs1=$startScript
        stopPs1=$stopScript
        healthPs1=$healthScript
        startCmd=$cmdTemplate.Replace('__SCRIPT__','Start-KIStack.ps1')
        stopCmd=$cmdTemplate.Replace('__SCRIPT__','Stop-KIStack.ps1')
        healthCmd=$cmdTemplate.Replace('__SCRIPT__','Test-KIStack-Health.ps1')
    }
}

function Test-KIModuleCutover {
    param([Parameter(Mandatory)][object]$Context)
    $issues=[System.Collections.Generic.List[string]]::new()
    if(-not [bool]$Context.Config.executeRelease.cutoverEnabled){[void]$issues.Add('Execute-Release hat Cutover nicht aktiviert.')}
    if(-not [bool]$Context.Config.integration.cutoverEnabled){[void]$issues.Add('Integration hat Cutover nicht aktiviert.')}
    if($null-eq $Context.Config.PSObject.Properties['cutover']){[void]$issues.Add('Cutover-Konfiguration fehlt.')}
    $definitions=Get-KICutoverEndpointDefinitions -Context $Context
    if($definitions.Count-ne 4){[void]$issues.Add('Cutover muss genau vier Endpunkte definieren.')}
    return [pscustomobject][ordered]@{success=($issues.Count-eq 0);skipped=$false;message=if($issues.Count-eq 0){'Cutover-Konfiguration und Endpunktvertrag wurden geprüft.'}else{$issues-join ' | '};data=[pscustomobject][ordered]@{issues=@($issues);endpoints=$definitions}}
}

function Install-KIModuleCutover {
    param([Parameter(Mandatory)][object]$Context)
    $config=$Context.Config.cutover
    $plannedFiles=@('Start-KIStack.ps1','Start-KIStack.cmd','Stop-KIStack.ps1','Stop-KIStack.cmd','Test-KIStack-Health.ps1','Test-KIStack-Health.cmd','installation.json','Readiness-latest.json')
    if($Context.Mode-eq'DryRun'){
        return [pscustomobject][ordered]@{success=$true;skipped=$false;message='Dry-Run: Gesamtstarter, Stopper, Healthcheck und Abnahmeberichte würden eingerichtet.';data=[pscustomobject][ordered]@{moduleRoot=[string]$config.moduleRoot;plannedFiles=$plannedFiles;endpoints=(Get-KICutoverEndpointDefinitions -Context $Context)}}
    }
    $rollback=[pscustomobject][ordered]@{schemaVersion='1.0';transactionId=[string]$Context.Transaction.transactionId;updatedAt=(Get-Date).ToString('o');files=@()}
    Write-KICutoverRollbackState -Context $Context -State $rollback
    $missingSources=@(Get-KICutoverRequiredSourceFiles -Context $Context|Where-Object{-not(Test-Path -LiteralPath $_ -PathType Leaf)})
    if($missingSources.Count-gt 0){throw ('Vorgänger-Starter fehlen: '+($missingSources-join ', '))}
    $content=Get-KICutoverGeneratedContent -Context $Context
    $root=[string]$config.moduleRoot
    $fileMap=@{
        (Join-Path $root 'Start-KIStack.ps1')=[string]$content.startPs1
        (Join-Path $root 'Start-KIStack.cmd')=[string]$content.startCmd
        (Join-Path $root 'Stop-KIStack.ps1')=[string]$content.stopPs1
        (Join-Path $root 'Stop-KIStack.cmd')=[string]$content.stopCmd
        (Join-Path $root 'Test-KIStack-Health.ps1')=[string]$content.healthPs1
        (Join-Path $root 'Test-KIStack-Health.cmd')=[string]$content.healthCmd
    }
    foreach($path in $fileMap.Keys){Install-KICutoverManagedFile -Context $Context -RollbackState $rollback -Path $path -Content ([string]$fileMap[$path])}
    $health=Get-KICutoverHealthSnapshot -Context $Context -TimeoutSeconds 3
    $reportRoot=[string]$config.reportRoot
    if(-not(Test-Path -LiteralPath $reportRoot -PathType Container)){New-Item -ItemType Directory -Path $reportRoot -Force|Out-Null}
    $readiness=[pscustomobject][ordered]@{schemaVersion='1.0';release=[string]$Context.Config.executeRelease.releaseId;transactionId=[string]$Context.Transaction.transactionId;generatedAt=(Get-Date).ToString('o');requiredSourcesPresent=$true;liveEndpointsRequired=[bool]$config.requireLiveEndpointsDuringExecute;health=$health}
    $readinessPath=Join-Path $reportRoot 'Readiness-latest.json'
    Install-KICutoverManagedFile -Context $Context -RollbackState $rollback -Path $readinessPath -Content ($readiness|ConvertTo-Json -Depth 50)
    $marker=[pscustomobject][ordered]@{managedBy='KI-STACK-CUTOVER-MANAGED';schemaVersion='1.0';release='KI-Stack-Cutover-Execute-v1.6.10';installedAt=(Get-Date).ToString('o');transactionId=[string]$Context.Transaction.transactionId;moduleRoot=$root;readinessReport=$readinessPath}
    Install-KICutoverManagedFile -Context $Context -RollbackState $rollback -Path ([string]$config.installationMarker) -Content ($marker|ConvertTo-Json -Depth 30)
    return [pscustomobject][ordered]@{success=$true;skipped=$false;message='Gesamtstarter, Stopper, Healthcheck und Readiness-Bericht wurden eingerichtet.';data=[pscustomobject][ordered]@{moduleRoot=$root;readinessReport=$readinessPath;initialHealth=$health;rollbackStatePath=(Get-KICutoverRollbackStatePath -Context $Context)}}
}

function Validate-KIModuleCutover {
    param([Parameter(Mandatory)][object]$Context)
    if($Context.Mode-eq'DryRun'){
        return [pscustomobject][ordered]@{success=$true;skipped=$false;message='Dry-Run: Cutover-Zielzustand ist vollständig planbar.';data=[pscustomobject][ordered]@{endpoints=(Get-KICutoverEndpointDefinitions -Context $Context);requiredFiles=@('Start-KIStack.cmd','Stop-KIStack.cmd','Test-KIStack-Health.cmd')}}
    }
    $config=$Context.Config.cutover;$issues=[System.Collections.Generic.List[string]]::new()
    foreach($required in @([string]$config.installationMarker,(Join-Path ([string]$config.moduleRoot) 'Start-KIStack.ps1'),(Join-Path ([string]$config.moduleRoot) 'Start-KIStack.cmd'),(Join-Path ([string]$config.moduleRoot) 'Stop-KIStack.ps1'),(Join-Path ([string]$config.moduleRoot) 'Stop-KIStack.cmd'),(Join-Path ([string]$config.moduleRoot) 'Test-KIStack-Health.ps1'),(Join-Path ([string]$config.moduleRoot) 'Test-KIStack-Health.cmd'),(Join-Path ([string]$config.reportRoot) 'Readiness-latest.json'))){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){[void]$issues.Add("Cutover-Datei fehlt: $required")}}
    $health=Get-KICutoverHealthSnapshot -Context $Context -TimeoutSeconds 3
    if([bool]$config.requireLiveEndpointsDuringExecute -and -not [bool]$health.allReachable){[void]$issues.Add('Nicht alle Endpunkte sind während Execute erreichbar.')}
    return [pscustomobject][ordered]@{success=($issues.Count-eq 0);skipped=$false;message=if($issues.Count-eq 0){'Cutover-Artefakte und Readiness-Vertrag wurden validiert.'}else{$issues-join ' | '};data=[pscustomobject][ordered]@{issues=@($issues);health=$health}}
}

function Rollback-KIModuleCutover {
    param([Parameter(Mandatory)][object]$Context)
    if($Context.Mode-eq'DryRun'){return [pscustomobject][ordered]@{success=$true;skipped=$true;message='Dry-Run: Kein Cutover-Rollback erforderlich.';data=$null}}
    $state=Read-KICutoverRollbackState -Context $Context
    if(-not $state){return [pscustomobject][ordered]@{success=$true;skipped=$true;message='Kein Cutover-Rollbackjournal vorhanden.';data=$null}}
    $issues=[System.Collections.Generic.List[string]]::new()
    foreach($entry in @($state.files)|Sort-Object{([string]$_.path).Length}-Descending){try{if([bool]$entry.existedBefore){[IO.File]::WriteAllBytes([string]$entry.path,[Convert]::FromBase64String([string]$entry.previousContentBase64))}elseif(Test-Path -LiteralPath ([string]$entry.path)-PathType Leaf){Remove-Item -LiteralPath ([string]$entry.path)-Force}}catch{[void]$issues.Add($_.Exception.Message)}}
    return [pscustomobject][ordered]@{success=($issues.Count-eq 0);skipped=$false;message=if($issues.Count-eq 0){'Cutover-Dateien und Berichte wurden transaktionsbezogen zurückgesetzt.'}else{$issues-join ' | '};data=[pscustomobject][ordered]@{issues=@($issues)}}
}

Export-ModuleMember -Function *

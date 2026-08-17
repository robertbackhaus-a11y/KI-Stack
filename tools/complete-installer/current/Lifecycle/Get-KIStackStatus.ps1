[CmdletBinding()]
param([int]$TimeoutSeconds = 5)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7){throw 'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}

function New-StatusResult {
    param([string]$Name,[string]$Status,[string]$Detail)
    [pscustomobject]@{ Name=$Name; Status=$Status; Detail=$Detail }
}

function Test-HttpStatus {
    param([string]$Name,[string]$Uri,[scriptblock]$ContentCheck)
    try {
        $response=Invoke-WebRequest -Uri $Uri -Method Get -TimeoutSec $TimeoutSeconds -UseBasicParsing
        if($response.StatusCode -lt 200 -or $response.StatusCode -ge 400){return New-StatusResult $Name 'Fehler' "HTTP $($response.StatusCode)"}
        if($ContentCheck -and -not(& $ContentCheck $response.Content)){return New-StatusResult $Name 'Fehler' 'Antwort unplausibel'}
        New-StatusResult $Name 'Läuft' "HTTP $($response.StatusCode)"
    }
    catch {
        $message=$_.Exception.Message
        if($message -match '(?i)connection refused|actively refused|Keine Verbindung|Zielcomputer verweigerte'){return New-StatusResult $Name 'Gestoppt' 'Nicht erreichbar'}
        New-StatusResult $Name 'Fehler' $message
    }
}

$results=[Collections.Generic.List[object]]::new()
$lmProcesses=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -eq 'LM Studio.exe'-and$_.CommandLine -match '(?i)(?:^|\s)--run-as-service(?:\s|$)'})
$results.Add((New-StatusResult 'LM Studio' $(if($lmProcesses.Count){'Läuft'}else{'Gestoppt'}) $(if($lmProcesses.Count){"PID $($lmProcesses[0].ProcessId)"}else{'Kein Dienstprozess'})))
$results.Add((Test-HttpStatus 'LM Studio /v1/models' 'http://127.0.0.1:1234/v1/models' {param($c);try{$null=$c|ConvertFrom-Json;return $true}catch{return $false}}))
$results.Add((Test-HttpStatus 'OpenWebUI' 'http://127.0.0.1:8080/api/config' {param($c);try{return [bool](($c|ConvertFrom-Json).status)}catch{return $false}}))
$results.Add((Test-HttpStatus 'SearXNG HTML' 'http://localhost/searxng/' $null))
$results.Add((Test-HttpStatus 'SearXNG JSON-Suche' 'http://localhost/searxng/search?q=ki-stack&format=json' {param($c);try{$j=$c|ConvertFrom-Json;return $null-ne$j.results}catch{return $false}}))
$results.Add((Test-HttpStatus 'ComfyUI Health' 'http://127.0.0.1:8188/system_stats' {param($c);try{$null=$c|ConvertFrom-Json;return $true}catch{return $false}}))
$codexMarker='C:\KI-Stack\modules\codex-local\installation.json'
$ragMarker='C:\KI-Stack\modules\rag\installation.json'
$codexCommand=Get-Command codex.exe,codex.cmd,codex -ErrorAction SilentlyContinue|Select-Object -First 1
$results.Add((New-StatusResult 'Codex Local' $(if((Test-Path $codexMarker)-and$codexCommand){'Läuft'}else{'Gestoppt'}) $(if($codexCommand){"CLI $(& $codexCommand.Source --version 2>$null)"}else{'CLI nicht gefunden'})))
$results.Add((New-StatusResult 'RAG-Modul' $(if(Test-Path $ragMarker){'Läuft'}else{'Gestoppt'}) $(if(Test-Path $ragMarker){'Installiert; Import bedarfsgesteuert'}else{'Nicht installiert'})))

$keeper=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -eq 'wsl.exe'-and$_.CommandLine -match '(?i)-d\s+Debian\b.*--exec\s+sleep\s+infinity\b'})
$results.Add((New-StatusResult 'WSL-Keeper' $(if($keeper.Count){'Läuft'}else{'Gestoppt'}) $(if($keeper.Count){"PID $($keeper[0].ProcessId)"}else{'Kein Keeper-Prozess'})))

$runningDistros=@((& wsl.exe --list --running --quiet 2>$null)|ForEach-Object{$_.Trim([char]0).Trim()}|Where-Object{$_})
foreach($unit in @('valkey-server','uwsgi','nginx')){
    if($runningDistros -notcontains 'Debian'){$results.Add((New-StatusResult $unit 'Gestoppt' 'Debian läuft nicht'));continue}
    try{$state=((& wsl.exe -d Debian -- systemctl is-active $unit 2>$null)-join'').Trim();if($state-eq'active'){$results.Add((New-StatusResult $unit 'Läuft' 'active'))}elseif($state-in@('inactive','failed','deactivating','activating')){$results.Add((New-StatusResult $unit $(if($state-eq'failed'){'Fehler'}else{'Gestoppt'}) $state))}else{$results.Add((New-StatusResult $unit 'Fehler' $(if($state){$state}else{'Status unbekannt'})))}}catch{$results.Add((New-StatusResult $unit 'Fehler' $_.Exception.Message))}
}

$running=@($results|Where-Object Status -eq 'Läuft').Count
$errors=@($results|Where-Object Status -eq 'Fehler').Count
$stopped=@($results|Where-Object Status -eq 'Gestoppt').Count
if($errors){$overall='Fehler';$exitCode=2}elseif($running-eq0){$overall='Gestoppt';$exitCode=1}elseif($stopped){$overall='Teilweise gestartet';$exitCode=1}else{$overall='Läuft';$exitCode=0}

Write-Host ''
Write-Host 'KI-Stack Status' -ForegroundColor Cyan
Write-Host ('='*72)
foreach($item in $results){$color=switch($item.Status){'Läuft'{'Green'}'Gestoppt'{'Yellow'}default{'Red'}};Write-Host ('{0,-26} {1,-10} {2}' -f $item.Name,$item.Status,$item.Detail) -ForegroundColor $color}
Write-Host ('-'*72)
Write-Host ("Gesamtstatus: {0}" -f $overall) -ForegroundColor $(if($exitCode-eq0){'Green'}elseif($exitCode-eq1){'Yellow'}else{'Red'})
Write-Host ("Zeitstempel:  {0}" -f ([DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz')))
exit $exitCode

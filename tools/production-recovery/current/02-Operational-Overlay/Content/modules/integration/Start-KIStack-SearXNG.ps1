[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$distribution='Debian'
$pidFile='C:\KI-Stack\modules\integration\wsl-keeper.pid'
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

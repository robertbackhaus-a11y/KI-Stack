[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$distribution='Debian'
$pidFile='C:\KI-Stack\modules\integration\wsl-keeper.pid'
$wsl=(Get-Command wsl.exe -ErrorAction Stop).Source
$keeperAlive=$false
if(Test-Path -LiteralPath $pidFile -PathType Leaf){
  $keeperPid=[int](Get-Content -LiteralPath $pidFile -Raw)
  $keeperAlive=$null -ne (Get-Process -Id $keeperPid -ErrorAction SilentlyContinue)
}
if(-not $keeperAlive){
  $keeper=Start-Process -FilePath $wsl -ArgumentList @('-d',$distribution,'-u','root','--','bash','-lc','exec sleep infinity') -WindowStyle Hidden -PassThru
  Set-Content -LiteralPath $pidFile -Value ([string]$keeper.Id) -Encoding ascii
}
$output=@(& $wsl -d $distribution -u root -- bash -lc 'systemctl start valkey-server nginx; if systemctl list-unit-files ki-stack-searxng.service --no-legend 2>/dev/null | grep -q ki-stack; then systemctl start ki-stack-searxng; fi' 2>&1)
if($LASTEXITCODE-ne 0){throw ('Linux-Dienste konnten nicht gestartet werden: '+($output-join ' | '))}
$deadline=(Get-Date).AddSeconds(30)
do { try{$result=Invoke-RestMethod -Uri 'http://localhost/searxng/search?q=ki-stack&format=json' -TimeoutSec 5; if($null -ne  $result.results){Write-Host 'SearXNG ist erreichbar.';return}}catch{};Start-Sleep -Seconds 1 } while((Get-Date) -lt  $deadline)
throw 'SearXNG ist nach 30 Sekunden nicht erreichbar.'
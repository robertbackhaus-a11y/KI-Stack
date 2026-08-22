[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$distribution='Debian'
$pidFile='C:\KI-Stack\modules\integration\wsl-keeper.pid'
$wsl=(Get-Command wsl.exe -ErrorAction Stop).Source
$keeperAlive=$false
if(Test-Path -LiteralPath $pidFile -PathType Leaf){
    $raw=(Get-Content -LiteralPath $pidFile -Raw).Trim()
    if($raw-match'^\d+$'){$keeperAlive=$null-ne(Get-Process -Id([int]$raw)-ErrorAction SilentlyContinue)}
    if(-not$keeperAlive){Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue}
}
if(-not$keeperAlive){
    $keeper=Start-Process -FilePath $wsl -ArgumentList @('-d',$distribution,'-u','root','--','bash','-lc','exec sleep infinity') -WindowStyle Hidden -PassThru
    Set-Content -LiteralPath $pidFile -Value ([string]$keeper.Id) -Encoding ascii
}
$output=@(& $wsl -d $distribution -u root -- bash -lc 'systemctl start valkey-server uwsgi nginx && systemctl is-active --quiet valkey-server uwsgi nginx' 2>&1)
if($LASTEXITCODE-ne0){throw('Linux-Dienste konnten nicht gestartet werden: '+($output-join' | '))}
$deadline=(Get-Date).AddSeconds(30)
do {
    try {
        $health=Invoke-WebRequest -Uri 'http://localhost/searxng/healthz' -TimeoutSec 5 -ErrorAction Stop
        $config=Invoke-RestMethod -Uri 'http://localhost/searxng/config' -TimeoutSec 5 -ErrorAction Stop
        $isSearXNG=($null-ne$config.PSObject.Properties['version']-and$config.version-is[string]-and$null-ne$config.PSObject.Properties['engines']-and$config.engines-is[object[]]-and$null-ne$config.PSObject.Properties['categories']-and$config.categories-is[object[]]-and$null-ne$config.PSObject.Properties['brand'])
        if($health.StatusCode-eq200-and$health.Content.Trim()-eq'OK'-and$isSearXNG){Write-Host 'SearXNG ist erreichbar.';return}
    } catch {}
    Start-Sleep -Seconds 1
} while((Get-Date)-lt$deadline)
throw 'SearXNG ist nach 30 Sekunden nicht erreichbar.'

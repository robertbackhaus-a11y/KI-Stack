[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$distribution='Debian'
$pidFile='C:\KI-Stack\modules\integration\wsl-keeper.pid'
$wsl=(Get-Command wsl.exe -ErrorAction Stop).Source
# Historically (Integration 1.5.8) valkey-server/uwsgi/nginx were enabled
# systemd units: the keeper's only job was to keep the Debian VM alive so
# systemd's own boot sequence could bring them up itself. A later regression
# left the units disabled, which forced this script to orchestrate
# 'systemctl start ...' from Windows immediately after an async keeper
# launch -- a sequence that was never validated as a real cold-start
# contract and is not needed now that install-searxng-payload.sh enables
# the units again (diag14). Restore that contract: keeper only, systemd
# owns the service lifecycle, Windows only verifies readiness below.
$expectedArgs=@('-d',$distribution,'-u','root','--exec','sleep','infinity')
function Test-KeeperIdentity([int]$ProcessId){
    $proc=Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if($null-eq$proc){return $false}
    if($proc.Name-ne'wsl.exe'){return $false}
    return ($proc.CommandLine-match[regex]::Escape($distribution))-and($proc.CommandLine-match'sleep')-and($proc.CommandLine-match'infinity')
}
$keeperAlive=$false
if(Test-Path -LiteralPath $pidFile -PathType Leaf){
    $raw=(Get-Content -LiteralPath $pidFile -Raw).Trim()
    if($raw-match'^\d+$'){$keeperAlive=(Test-KeeperIdentity([int]$raw))}
    if(-not$keeperAlive){Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue}
}
if(-not$keeperAlive){
    $keeper=Start-Process -FilePath $wsl -ArgumentList $expectedArgs -WindowStyle Hidden -PassThru
    Set-Content -LiteralPath $pidFile -Value ([string]$keeper.Id) -Encoding ascii
}
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

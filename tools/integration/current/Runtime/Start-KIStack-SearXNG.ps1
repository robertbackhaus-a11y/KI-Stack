[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$distribution='Debian'
$pidFile=Join-Path $PSScriptRoot 'wsl-keeper.pid'
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
#
# 2.18.2 hotfix (real, reproduced defect, verified live against a real Debian WSL instance):
# launching the keeper via '-u root -- bash -lc "exec sleep infinity"' opens a login shell
# (bash -l); on this real target the wsl.exe launcher itself exited within ~1 second of being
# started and the exec'ed sleep process never survived past that, so Debian fell back to Stopped
# shortly after Get-KIStackStatus.ps1 had reported it Running. '--exec /bin/sleep infinity' runs
# the binary directly, with no shell and no login session, and was confirmed durably stable (both
# the Windows launcher and the in-Debian process) over repeated real checks. The Windows-side
# launcher PID recorded below is informational/best-effort only -- Test-KIWslKeeperProcessAlive
# is the only thing that decides whether a keeper is already alive, so a stale or missing PID can
# never make a real, still-running keeper look Stopped.
function Test-KIWslDebianRunning {
    $running=@((& $wsl --list --running --quiet 2>$null)|ForEach-Object{$_.Trim([char]0).Trim()}|Where-Object{$_})
    return $running -contains $distribution
}
function Test-KIWslKeeperProcessAlive {
    if(-not(Test-KIWslDebianRunning)){return $false}
    $pgrepOutput=@(& $wsl -d $distribution -- pgrep -f 'sleep infinity' 2>$null)
    return ($LASTEXITCODE-eq0)-and(@($pgrepOutput|Where-Object{$_-match'^\d+$'}).Count-gt0)
}
if(Test-Path -LiteralPath $pidFile -PathType Leaf){
    $raw=(Get-Content -LiteralPath $pidFile -Raw).Trim()
    if($raw-notmatch'^\d+$'-or$null-eq(Get-Process -Id([int]$raw)-ErrorAction SilentlyContinue)){
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }
}
if(-not(Test-KIWslKeeperProcessAlive)){
    $keeper=Start-Process -FilePath $wsl -ArgumentList @('-d',$distribution,'--exec','/bin/sleep','infinity') -WindowStyle Hidden -PassThru
    Set-Content -LiteralPath $pidFile -Value ([string]$keeper.Id) -Encoding ascii
    $keeperDeadline=(Get-Date).AddSeconds(15)
    do{
        if(Test-KIWslKeeperProcessAlive){break}
        Start-Sleep -Milliseconds 500
    }while((Get-Date)-lt$keeperDeadline)
    if(-not(Test-KIWslKeeperProcessAlive)){throw 'WSL-Keeper (sleep infinity in Debian) konnte nicht gestartet werden oder ist nicht dauerhaft aktiv.'}
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

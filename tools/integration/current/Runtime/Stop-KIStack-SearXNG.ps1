[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$distribution='Debian'
$pidFile=Join-Path $PSScriptRoot 'wsl-keeper.pid'
$wsl=(Get-Command wsl.exe -ErrorAction Stop).Source
$distributionRunning=@((& $wsl --list --running --quiet 2>$null)|ForEach-Object{$_.Trim([char]0).Trim()}|Where-Object{$_}) -contains $distribution
$stopped=$true
$status=@()
if($distributionRunning){
    # Kills the real in-Debian keeper process directly -- the Windows-side wsl.exe launcher PID
    # in $pidFile is best-effort/informational only and may already be gone even while the keeper
    # is still alive, so it is never the sole stop mechanism (see Start-KIStack-SearXNG.ps1).
    & $wsl -d $distribution -- pkill -f 'sleep infinity' 2>$null|Out-Null
    # Real, reproduced defect: once the keeper is killed and nothing else keeps Debian attached,
    # WSL can tear the whole distribution down almost immediately -- querying systemctl for a
    # status readout at that point would itself auto-start a fresh Debian instance just to answer
    # it, defeating the clean shutdown this script just achieved (2.18.2, item 6). Only ask if
    # Debian is still actually up after the kill.
    $distributionStillRunning=@((& $wsl --list --running --quiet 2>$null)|ForEach-Object{$_.Trim([char]0).Trim()}|Where-Object{$_}) -contains $distribution
    if($distributionStillRunning){
        $status=@(& $wsl -d $distribution -u root -- bash -lc 'for s in valkey-server uwsgi nginx; do printf "%s=%s " "$s" "$(systemctl is-active "$s" 2>/dev/null || true)"; done' 2>&1)
    }
}
if(Test-Path -LiteralPath $pidFile -PathType Leaf){
    $raw=(Get-Content -LiteralPath $pidFile -Raw).Trim()
    if($raw-match'^\d+$'){Stop-Process -Id([int]$raw)-Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $pidFile -Force
}
Write-Host('WSL-Keeper beendet={0}; Standarddienste bleiben unverändert: {1}'-f$stopped,($status-join' '))

[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$distribution='Debian'
$pidFile=Join-Path $PSScriptRoot 'wsl-keeper.pid'
$wsl=(Get-Command wsl.exe -ErrorAction Stop).Source
$stopped=$false
if(Test-Path -LiteralPath $pidFile -PathType Leaf){
    $raw=(Get-Content -LiteralPath $pidFile -Raw).Trim()
    if($raw-match'^\d+$'-and$null-ne(Get-Process -Id([int]$raw)-ErrorAction SilentlyContinue)){Stop-Process -Id([int]$raw)-Force -ErrorAction Stop;$stopped=$true}
    Remove-Item -LiteralPath $pidFile -Force
}
$status=@(& $wsl -d $distribution -u root -- bash -lc 'for s in valkey-server uwsgi nginx; do printf "%s=%s " "$s" "$(systemctl is-active "$s" 2>/dev/null || true)"; done' 2>&1)
Write-Host('WSL-Keeper beendet={0}; Standarddienste bleiben unverändert: {1}'-f$stopped,($status-join' '))

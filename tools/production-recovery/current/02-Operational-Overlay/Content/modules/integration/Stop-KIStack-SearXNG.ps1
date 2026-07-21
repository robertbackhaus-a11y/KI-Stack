[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$distribution='Debian';$pidFile='C:\KI-Stack\modules\integration\wsl-keeper.pid';$wsl=(Get-Command wsl.exe -ErrorAction Stop).Source
& $wsl -d $distribution -u root -- bash -lc 'systemctl stop ki-stack-searxng 2>/dev/null || true' 2>$null|Out-Null
if(Test-Path -LiteralPath $pidFile -PathType Leaf){$keeperPid=[int](Get-Content -LiteralPath $pidFile -Raw);Stop-Process -Id $keeperPid -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue}
Write-Host 'SearXNG/WSL-Keeper wurde beendet.'
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$distribution='Debian';$pidFile='C:\KI-Stack\modules\integration\wsl-keeper.pid';$wsl=(Get-Command wsl.exe -ErrorAction Stop).Source
function Test-ExpectedKeeper([int]$ProcessId){$p=Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue;if($null-eq$p){return $false};$c=[string]$p.CommandLine;return ([string]$p.Name-ieq'wsl.exe'-and$c-match'(?i)(?:^|\s)-d\s+Debian(?:\s|$)'-and$c-match'(?i)--exec\s+sleep\s+infinity')}
$stopped=$false
if(Test-Path -LiteralPath $pidFile -PathType Leaf){$raw=(Get-Content -LiteralPath $pidFile -Raw).Trim();if($raw-match'^\d+$'-and(Test-ExpectedKeeper -ProcessId([int]$raw))){Stop-Process -Id([int]$raw)-Force -ErrorAction Stop;$stopped=$true};Remove-Item -LiteralPath $pidFile -Force}
$status=@(& $wsl -d $distribution -u root -- bash -lc 'for s in valkey-server uwsgi nginx; do printf "%s=%s " "$s" "$(systemctl is-active "$s" 2>/dev/null || true)"; done' 2>&1)
Write-Host ('WSL-Keeper beendet={0}; Standarddienste bleiben unverändert: {1}'-f $stopped,($status-join' '))

[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fail=[Collections.Generic.List[string]]::new()

# 2.18.2 hotfix, real reproduziert (live gegen eine echte Debian-WSL-Instanz verifiziert):
# Get-KIStackStatus.ps1's WSL-Keeper-Erkennung verglich bislang nur, ob ein Windows-Prozess
# 'wsl.exe' mit passender CommandLine noch existiert. Live beobachtet: dieser Windows-Launcher-
# Prozess kann sich selbst innerhalb von rund einer Sekunde beenden, wahrend Debian kurzzeitig noch
# als Running gemeldet wird -- ein real weiterlaufender Keeper wurde dadurch faelschlich als
# "Gestoppt" gemeldet, sobald sein eigener Launcher-Prozess weg war. Dieser Test prueft strukturell
# (wie die bereits etablierte Test-KIStackStatusOpenTerminalDetection.ps1 fuer denselben
# Skriptblock-Typ), dass die Erkennung jetzt konsistent auf dem echten, in Debian laufenden
# Prozess beruht statt auf dem kurzlebigen Windows-Launcher.

$scriptPath=Join-Path $PackageRoot 'Lifecycle/Get-KIStackStatus.ps1'
$source=[IO.File]::ReadAllText($scriptPath)

$checks=[ordered]@{
    noLongerGatesOnWin32ProcessLauncher=(-not $source.Contains("Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{`$_.Name -eq 'wsl.exe'"))
    checksDebianIsActuallyRunningFirst=$source.Contains('$runningDistros=@((& wsl.exe --list --running --quiet 2>$null)') -and $source.Contains('$debianRunning=$runningDistros -contains ''Debian''')
    verifiesRealInDebianSleepProcess=$source.Contains("pgrep -f 'sleep infinity'")
    neverQueriesInsideDebianWithoutCheckingItIsRunningFirst=($source.IndexOf('if($debianRunning){') -lt $source.IndexOf("pgrep -f 'sleep infinity'"))
    reportsRunningOnlyWhenProcessAliveConfirmed=$source.Contains('$(if($keeperProcessAlive){''Läuft''}else{''Gestoppt''})')
    valkeyNginxUwsgiReuseSameDebianRunningCheck=$source.Contains('if(-not$debianRunning){$results.Add((New-StatusResult $unit ''Gestoppt'' ''Debian läuft nicht''))')
}
foreach($name in $checks.Keys){if(-not $checks[$name]){$fail.Add("$name failed")}}

$tokens=$null;$parseErrors=$null
[void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
if(@($parseErrors).Count){$fail.Add("Get-KIStackStatus.ps1 parse errors: $(@($parseErrors).Message -join '; ')")}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'Status-WSL-Keeper-Detection-Regression fehlgeschlagen.'}

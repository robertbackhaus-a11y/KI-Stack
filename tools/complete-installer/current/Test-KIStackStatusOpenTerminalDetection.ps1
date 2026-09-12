[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fail=[Collections.Generic.List[string]]::new()

# 2.18.2 hotfix, real reproduziert: Get-KIStackStatus.ps1's inline dupliziertes Identitaets-
# Kriterium fuer Open Terminal (bewusst dupliziert statt eines Cross-Package-Imports, siehe die
# Kommentare direkt im Skript) kannte nur 'uvx.exe'/'uv.exe' als erlaubte Prozessnamen und hatte
# keinen Fallback jenseits der PID-Datei. Live beobachtet: `uv tool run open-terminal ...` uebergibt
# an den eigentlichen, langlebigen Server und beendet sich selbst -- der reale Server erscheint bei
# Win32_Process mit Name "python.exe", nicht "uv.exe"/"uvx.exe" -- wodurch ein gesunder, real
# laufender Open Terminal faelschlich als "Gestoppt" gemeldet wurde. Dieser Test prueft strukturell
# (wie die bereits etablierte Test-KIStackStatusCodexDetection.ps1 fuer denselben Skriptblock-Typ),
# dass das Skript jetzt konsistent mit OpenTerminal.psm1's eigenem, kanonischem Identitaetsvertrag
# ist: 'python.exe' als erlaubter Name, ein identitaetsgeprueftes Get-NetTCPConnection-Fallback
# (niemals eine bloße Portpruefung), und eine Workspace-Pfad-Pruefung.

$scriptPath=Join-Path $PackageRoot 'Lifecycle/Get-KIStackStatus.ps1'
$source=[IO.File]::ReadAllText($scriptPath)

$checks=[ordered]@{
    allowsPythonExeIdentity=$source.Contains("'uv.exe','uvx.exe','python.exe'")
    checksWorkspacePath=$source.Contains('$openTerminalWorkspace=Join-Path $targetRoot ''state/open-terminal/workspace''') -and $source.Contains('-WorkspacePath $openTerminalWorkspace')
    hasPortOwnerFallback=$source.Contains('Get-NetTCPConnection -LocalPort $otPort -State Listen')
    fallbackIsIdentityVerifiedNeverBarePortCheck=$source.Contains('Test-KIStackOpenTerminalIdentityForStatus -ProcessId ([int]$otOwner) -Port $otPort -WorkspacePath $openTerminalWorkspace')
    stillRequiresOpenTerminalCommandLineToken=$source.Contains("'(?i)open-terminal'")
    stillRequiresPortMatchInCommandLine=$source.Contains('"--port $Port"') -and $source.Contains('"--port=$Port"')
    stillFollowedByRealHealthcheck=$source.Contains('/openapi.json')
    neverReportsApiKey=(-not ($source -match '(?i)apiKey.*Open Terminal|Open Terminal.*apiKey'))
}
foreach($name in $checks.Keys){if(-not $checks[$name]){$fail.Add("$name failed")}}

$tokens=$null;$parseErrors=$null
[void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
if(@($parseErrors).Count){$fail.Add("Get-KIStackStatus.ps1 parse errors: $(@($parseErrors).Message -join '; ')")}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'Status-OpenTerminal-Detection-Regression fehlgeschlagen.'}

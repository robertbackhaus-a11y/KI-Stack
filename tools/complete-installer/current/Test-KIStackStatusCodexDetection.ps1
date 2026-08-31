[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fail=[Collections.Generic.List[string]]::new()

# 2.13.0-Consolidation-Workstream, Nebenfund C (real, already-flagged in an earlier workstream,
# fixed here): Get-KIStackStatus.ps1 used to detect Codex Local via a global PATH lookup
# (Get-Command codex.exe,codex.cmd,codex), which is always empty by CodexLocal.psm1's own
# deliberate managed-runtime contract (no global registration) -- verified live against the real
# target: a genuinely installed, Healthy Codex Local 0.2.1 was still reported "Gestoppt"/"CLI
# nicht gefunden". Structural, fast, no-network regression: the script must reference the real
# managed node.exe/codex.js paths and the isolated CODEX_HOME, and must never reintroduce the
# global PATH lookup.

$scriptPath=Join-Path $PackageRoot 'Lifecycle/Get-KIStackStatus.ps1'
$source=[IO.File]::ReadAllText($scriptPath)

$checks=[ordered]@{
    usesRealManagedNodePath=$source.Contains('modules\codex-local\runtime\node.exe')
    usesRealManagedCodexCliPath=$source.Contains('npm-global\node_modules\@openai\codex\bin\codex.js')
    usesIsolatedCodexHome=$source.Contains("`$env:CODEX_HOME='C:\KI-Stack\state\codex-local\codex-home'")
    neverUsesGlobalPathLookup=(-not $source.Contains('Get-Command codex.exe,codex.cmd,codex'))
}
foreach($name in $checks.Keys){if(-not $checks[$name]){$fail.Add("$name failed")}}

$tokens=$null;$parseErrors=$null
[void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
if(@($parseErrors).Count){$fail.Add("Get-KIStackStatus.ps1 parse errors: $(@($parseErrors).Message -join '; ')")}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'Status-Codex-Detection-Regression fehlgeschlagen.'}

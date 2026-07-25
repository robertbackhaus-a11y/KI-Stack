[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7){throw 'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}
$failures = [Collections.Generic.List[string]]::new()
$required = @(
    'VERSION','Config/agent-pack.config.json','Definitions/ki-stack-it-technik.json','Definitions/ki-stack-allgemein.json',
    'OpenWebUIAgentPack.psm1','Invoke-OpenWebUIAgentPack.ps1','Test-OpenWebUIAgentPackTarget.ps1','New-OpenWebUIAgentPackArchive.ps1','Start-OpenWebUI-Agent-Pack-SelfTest.cmd',
    'Start-OpenWebUI-Agent-Pack-DryRun.cmd','Start-OpenWebUI-Agent-Pack-Execute.cmd','Test-AgentPackHttpFailures.ps1','README.md','MANIFEST.json','SHA256SUMS.txt'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot $relative) -PathType Leaf)) { $failures.Add("Fehlt: $relative") }
}
$version = (Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim()
$config = Get-Content -LiteralPath (Join-Path $PackageRoot 'Config\agent-pack.config.json') -Raw | ConvertFrom-Json -Depth 20
$manifest = Get-Content -LiteralPath (Join-Path $PackageRoot 'MANIFEST.json') -Raw | ConvertFrom-Json -Depth 20
if ($version -ne '1.8.7' -or $config.version -ne $version -or $manifest.version -ne $version) { $failures.Add('Versionskonsistenz') }
$definitions = @(Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Definitions') -File -Filter '*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 30 })
if (($definitions.id | Sort-Object) -join '|' -ne 'ki-stack-allgemein|ki-stack-it-technik') { $failures.Add('Technische IDs') }
foreach ($definition in $definitions) {
    if ($definition.schemaVersion -ne '1.0' -or [string]::IsNullOrWhiteSpace($definition.displayName) -or [string]::IsNullOrWhiteSpace($definition.systemPrompt)) { $failures.Add("Definitionsschema: $($definition.id)") }
    if ($definition.functionCalling -ne 'native') { $failures.Add("Function Calling: $($definition.id)") }
    if ($definition.codeInterpreter -ne $true) { $failures.Add("Code Interpreter: $($definition.id)") }
    if (@($definition.knowledge).Count -or @($definition.toolIds).Count -or @($definition.skillIds).Count -or @($definition.functionIds).Count) { $failures.Add("Unerwünschte Bindung: $($definition.id)") }
}
$text = Get-ChildItem -LiteralPath $PackageRoot -Recurse -File | Where-Object { $_.Extension -in '.ps1','.psm1','.cmd','.json','.md','.txt' } | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
if (($text -join "`n") -match '(?i)sk-[a-z0-9]{20,}|C:\\Users\\[A-Za-z0-9._-]+') { $failures.Add('Secret oder persönlicher Pfad') }
$moduleText = Get-Content -LiteralPath (Join-Path $PackageRoot 'OpenWebUIAgentPack.psm1') -Raw
foreach ($contract in @('/api/v1/models','/api/v1/models/create','/api/v1/models/model/update','/api/v1/models/model/delete','/openai/config','/openai/config/update','model_ids','function_calling')) {
    if (-not $moduleText.Contains($contract)) { $failures.Add("API-Vertrag: $contract") }
}
foreach ($contract in @('ki_stack_generate_image','ki_stack_generate_video','2.0.5-rc2')) {
    if (-not $moduleText.Contains($contract)) { $failures.Add("Visual-Tool-Vertrag: $contract") }
}
$report = [ordered]@{ version='1.8.7'; action='SelfTest'; passed=($failures.Count -eq 0); checks=13; failures=@($failures) }
$report | ConvertTo-Json -Depth 10
if ($failures.Count) { throw ('Agent-Pack-SelfTest fehlgeschlagen: ' + ($failures -join '; ')) }

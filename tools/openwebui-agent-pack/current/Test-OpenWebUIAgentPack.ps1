[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7){throw 'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}
$failures = [Collections.Generic.List[string]]::new()
$required = @(
    'VERSION','Config/agent-pack.config.json','Definitions/ki-stack-it-technik.json','Definitions/ki-stack-allgemein.json','Definitions/ki-stack-research.json',
    'OpenWebUIAgentPack.psm1','Invoke-OpenWebUIAgentPack.ps1','Test-OpenWebUIAgentPackTarget.ps1','New-OpenWebUIAgentPackArchive.ps1','Start-OpenWebUI-Agent-Pack-SelfTest.cmd',
    'Start-OpenWebUI-Agent-Pack-DryRun.cmd','Start-OpenWebUI-Agent-Pack-Execute.cmd','Test-AgentPackHttpFailures.ps1','README.md','MANIFEST.json','SHA256SUMS.txt'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot $relative) -PathType Leaf)) { $failures.Add("Fehlt: $relative") }
}
$version = (Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim()
$config = Get-Content -LiteralPath (Join-Path $PackageRoot 'Config\agent-pack.config.json') -Raw | ConvertFrom-Json -Depth 20
$manifest = Get-Content -LiteralPath (Join-Path $PackageRoot 'MANIFEST.json') -Raw | ConvertFrom-Json -Depth 20
if ($version -ne '1.9.0' -or $config.version -ne $version -or $manifest.version -ne $version) { $failures.Add('Versionskonsistenz') }
$definitions = @(Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Definitions') -File -Filter '*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 30 })
if (($definitions.id | Sort-Object) -join '|' -ne 'ki-stack-allgemein|ki-stack-it-technik|ki-stack-research') { $failures.Add('Technische IDs') }
foreach ($definition in $definitions) {
    if ($definition.schemaVersion -ne '1.0' -or [string]::IsNullOrWhiteSpace($definition.displayName) -or [string]::IsNullOrWhiteSpace($definition.systemPrompt)) { $failures.Add("Definitionsschema: $($definition.id)") }
    if ($definition.functionCalling -ne 'native') { $failures.Add("Function Calling: $($definition.id)") }
    if ($definition.codeInterpreter -ne $true) { $failures.Add("Code Interpreter: $($definition.id)") }
    # The static definition file itself never carries a real binding (knowledge/toolIds/
    # skillIds/functionIds all stay empty for every profile, including ki-stack-research
    # -- its RAG knowledge and dynamic extensionTools opt-out are separate, explicit
    # fields resolved at install time, not values baked into this file).
    if (@($definition.knowledge).Count -or @($definition.toolIds).Count -or @($definition.skillIds).Count -or @($definition.functionIds).Count) { $failures.Add("Unerwünschte Bindung: $($definition.id)") }
}
$research = $definitions | Where-Object id -eq 'ki-stack-research'
if ($null -eq $research) {
    $failures.Add('ki-stack-research fehlt')
} else {
    if ([string]$research.knowledgeSource -ne 'rag-global') { $failures.Add('ki-stack-research: knowledgeSource') }
    if ([bool]$research.extensionTools -ne $false) { $failures.Add('ki-stack-research: extensionTools muss deaktiviert sein') }
    $deniedBuiltinTools = @('time','user_input','files','chats','subagents','memory','image_generation','notes')
    foreach ($category in $deniedBuiltinTools) {
        if ([bool]$research.builtinTools.$category -ne $false) { $failures.Add("ki-stack-research: builtinTools.$category muss verboten sein") }
    }
    $allowedBuiltinTools = @('knowledge','web_search','code_interpreter')
    foreach ($category in $allowedBuiltinTools) {
        if ([bool]$research.builtinTools.$category -ne $true) { $failures.Add("ki-stack-research: builtinTools.$category muss erlaubt sein") }
    }
    # 'terminal' gates OpenWebUI's terminal-server tool bridge (utils/middleware.py) --
    # the closest real capability to "beliebige Shell gegen Host" this schema exposes.
    # It defaults to true when absent (get_model_capability(name, default=True)), so it
    # must be explicitly denied here even though no terminal_server.connections admin
    # config exists anywhere in this KI-Stack deployment today (defense in depth, not
    # reliance on an external precondition staying absent).
    if ([bool]$research.capabilities.image_generation -ne $false -or [bool]$research.capabilities.memory -ne $false -or [bool]$research.capabilities.terminal -ne $false) { $failures.Add('ki-stack-research: capabilities-Deny-Liste') }
}
$text = Get-ChildItem -LiteralPath $PackageRoot -Recurse -File | Where-Object { $_.Extension -in '.ps1','.psm1','.cmd','.json','.md','.txt' } | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
if (($text -join "`n") -match '(?i)sk-[a-z0-9]{20,}|C:\\Users\\[A-Za-z0-9._-]+') { $failures.Add('Secret oder persönlicher Pfad') }
$moduleText = Get-Content -LiteralPath (Join-Path $PackageRoot 'OpenWebUIAgentPack.psm1') -Raw
foreach ($contract in @('/api/v1/models','/api/v1/models/create','/api/v1/models/model/update','/api/v1/models/model/delete','/openai/config','/openai/config/update','model_ids','function_calling','/api/v1/knowledge/')) {
    if (-not $moduleText.Contains($contract)) { $failures.Add("API-Vertrag: $contract") }
}
foreach ($contract in @('ki_stack_generate_image','ki_stack_generate_video','2.0.5')) {
    if (-not $moduleText.Contains($contract)) { $failures.Add("Visual-Tool-Vertrag: $contract") }
}
# The module hardcodes agentPackVersion as a literal in New-AgentPackModelForm (it must be
# a plain literal there, not a runtime file read, so a generated form is reproducible from
# the module alone) -- this self-test is what actually catches VERSION/module drift, since
# nothing else would notice if a future bump only touched one of the two.
if (-not $moduleText.Contains("agentPackVersion = '$version'")) { $failures.Add('agentPackVersion-Literal stimmt nicht mit VERSION überein') }
$report = [ordered]@{ version=$version; action='SelfTest'; passed=($failures.Count -eq 0); checks=18; failures=@($failures) }
$report | ConvertTo-Json -Depth 10
if ($failures.Count) { throw ('Agent-Pack-SelfTest fehlgeschlagen: ' + ($failures -join '; ')) }

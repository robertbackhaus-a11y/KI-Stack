#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string]$ProjectName,
    [string]$PackageRoot=$PSScriptRoot,
    [string]$GlobalConfigPath=(Join-Path $PSScriptRoot 'Config\rag.config.json'),
    [switch]$Force
)

# Creates a new, fully isolated project-scoped rag.config.json/sources.json
# pair from the existing global configuration, so that a project's documents
# land in their own, dedicated OpenWebUI Knowledge collection and never share
# retrieval results with the global collection or any other project (see
# Get-RAGKnowledgeName / Test-RAGSourcesMatchConfiguredProject in
# KIStackRAG.psm1). This is the only supported way to stand up a new project
# scope -- hand-editing a copy of rag.config.json risks a stateRoot/sourceRoot
# collision with another scope, which this script prevents by construction.
#
# The resulting scope is operated with the exact same, unmodified
# Invoke-KIStackRAG.ps1 entry point already used for the global scope, just
# pointed at the new -ConfigPath/-SourcesPath:
#   Invoke-KIStackRAG.ps1 -Mode Execute -ConfigPath Config\rag.config.<ProjectName>.json -SourcesPath Config\sources.<ProjectName>.json -ApiToken $token
#
# Idempotent by refusal, not by silent reuse: an already-existing scope for
# the same ProjectName is left untouched unless -Force is passed, so a second,
# accidental invocation can never silently reset a project's already-curated
# sources.json back to an empty allow-list.

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PackageRoot 'KIStackRAG.psm1') -Force -DisableNameChecking

if ($ProjectName -eq 'global') { throw "'global' ist der reservierte Name des globalen Scopes und kann nicht als Projektname verwendet werden." }
if (-not (Test-Path -LiteralPath $GlobalConfigPath -PathType Leaf)) { throw "Globale RAG-Konfiguration fehlt: $GlobalConfigPath" }

$globalConfig = Get-Content -LiteralPath $GlobalConfigPath -Raw | ConvertFrom-Json -Depth 50
$globalConfigDirectory = Split-Path -Parent $GlobalConfigPath
$projectConfigPath = Join-Path $globalConfigDirectory "rag.config.$ProjectName.json"
$projectSourcesPath = Join-Path $globalConfigDirectory "sources.$ProjectName.json"

if (-not $Force) {
    foreach ($existing in @($projectConfigPath, $projectSourcesPath)) {
        if (Test-Path -LiteralPath $existing -PathType Leaf) {
            throw "Projekt-Scope '$ProjectName' existiert bereits (${existing}); -Force verwenden, um eine bewusste Neuerzeugung zu erzwingen. Ein bestehendes sources.json wird dabei NICHT automatisch überschrieben, wenn es bereits Quellen enthält."
        }
    }
}

$stateRootParent = Split-Path -Parent ([string]$globalConfig.stateRoot)
$sourceRootParent = Split-Path -Parent ([string]$globalConfig.sourceRoot)

$projectConfig = $globalConfig.PSObject.Copy()
$projectConfig | Add-Member -NotePropertyName project -NotePropertyValue $ProjectName -Force
$projectConfig.stateRoot = Join-Path $stateRootParent "projects\$ProjectName"
$projectConfig.sourceRoot = Join-Path $sourceRootParent "projects\$ProjectName"
$projectConfig.knowledgeName = [string]$globalConfig.knowledgeName
$projectConfig.knowledgeDescription = "Project-scoped knowledge for '$ProjectName', managed by KI-Stack RAG. Isolated from the global collection and from every other project."

($projectConfig | ConvertTo-Json -Depth 50) | Set-Content -LiteralPath $projectConfigPath -Encoding utf8NoBOM
if (-not (Test-Path -LiteralPath $projectSourcesPath -PathType Leaf)) {
    ([ordered]@{schemaVersion='1.0';sources=@()} | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $projectSourcesPath -Encoding utf8NoBOM
}

[pscustomobject][ordered]@{
    project=$ProjectName
    configPath=$projectConfigPath
    sourcesPath=$projectSourcesPath
    knowledgeName=(Get-RAGKnowledgeName -Config $projectConfig)
    stateRoot=$projectConfig.stateRoot
    sourceRoot=$projectConfig.sourceRoot
} | ConvertTo-Json -Depth 10

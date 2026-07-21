[CmdletBinding()]
param(
    [string]$Endpoint = 'http://127.0.0.1:8080',
    [Parameter(Mandatory)][string]$BaseModelId,
    [Security.SecureString]$ApiToken,
    [string]$SearXNGUrl = 'http://localhost/searxng/search?q=KI-Stack&format=json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OpenWebUIAgentPack.psm1') -Force
if ($null -eq $ApiToken) { $ApiToken = Read-Host 'Temporären OpenWebUI API-Key eingeben' -AsSecureString }

function Invoke-TestChat {
    param([string]$ModelId,[string]$Prompt,[bool]$WebSearch)
    $body = [ordered]@{
        model = $ModelId
        messages = @([ordered]@{ role='user'; content=$Prompt })
        stream = $false
        params = @{ function_calling='native' }
        features = @{ web_search=$WebSearch }
    }
    $result = Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path '/api/chat/completions' -Method POST -Body $body
    $content = [string]$result.choices[0].message.content
    if ([string]::IsNullOrWhiteSpace($content)) { throw "Leere Chat-Antwort für $ModelId" }
    return $content.Length
}

try {
    $readback = Test-OpenWebUIAgentPack -PackageRoot $PSScriptRoot -Endpoint $Endpoint -ApiToken $ApiToken -BaseModelId $BaseModelId
    if (-not $readback.passed) { throw ('Readback: ' + ($readback.failures -join '; ')) }
    $searxng = Invoke-RestMethod -Uri $SearXNGUrl -TimeoutSec 30
    if ($null -eq $searxng.results) { throw 'SearXNG lieferte kein Ergebnisfeld.' }
    $itLength = Invoke-TestChat -ModelId 'ki-stack-it-technik' -Prompt 'Nenne in zwei kurzen Sätzen einen sicheren ersten Diagnoseschritt bei einem nicht erreichbaren lokalen HTTP-Dienst.' -WebSearch $false
    $webLength = Invoke-TestChat -ModelId 'ki-stack-it-technik' -Prompt 'Suche im Web nach der offiziellen Bezeichnung des HTTP-Statuscodes 418 und antworte mit der Bezeichnung.' -WebSearch $true
    $generalLength = Invoke-TestChat -ModelId 'ki-stack-allgemein' -Prompt 'Erkläre in einem kurzen Satz, warum klare Annahmen hilfreich sind.' -WebSearch $false
    [ordered]@{
        version='1.8.0'; passed=$true; readback=$true; searxngEndpoint=$true
        chats=[ordered]@{ itTechnik=$itLength; itTechnikWebSearch=$webLength; allgemein=$generalLength }
        chatHistoryCreated=$false
    } | ConvertTo-Json -Depth 10
}
finally {
    $ApiToken = $null
    [GC]::Collect()
}

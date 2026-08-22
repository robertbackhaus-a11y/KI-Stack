#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Audit','DryRun','Execute','Status','Rollback')][string]$Mode='Audit',
    [string]$ConfigPath=(Join-Path $PSScriptRoot 'Config\rag.config.json'),
    [string]$SourcesPath=(Join-Path $PSScriptRoot 'Config\sources.json'),
    [Security.SecureString]$ApiToken
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'KIStackRAG.psm1') -Force
$result=Invoke-KIStackRAG -Mode $Mode -PackageRoot $PSScriptRoot -ConfigPath $ConfigPath -SourcesPath $SourcesPath -ApiToken $ApiToken
$result|ConvertTo-Json -Depth 30

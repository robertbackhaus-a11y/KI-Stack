[CmdletBinding()]
param([string]$Endpoint='http://localhost:8080',[Parameter(Mandatory)][Security.SecureString]$ApiToken)
$ErrorActionPreference='Stop';Import-Module (Join-Path $PSScriptRoot 'OpenWebUIBallisticsPack.psm1') -Force
try {$r=Test-OpenWebUIBallisticsPack $Endpoint $ApiToken;$r;if(-not$r.passed){exit 1}}finally{$ApiToken=$null;[GC]::Collect()}

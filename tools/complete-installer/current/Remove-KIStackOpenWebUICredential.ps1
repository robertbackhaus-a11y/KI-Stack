#Requires -Version 7.0
[CmdletBinding()]
param([string]$Endpoint='',[string]$TargetRoot='C:\KI-Stack')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}
Import-Module (Join-Path $PSScriptRoot 'Lifecycle/KIStackOpenWebUICredential.psm1') -Force -DisableNameChecking
# Explicit operator revoke path (Section 11): removes only the KI-Stack-owned local credential
# store and revokes only that same credential's own remote OpenWebUI API key -- never any other
# user's key, never an admin password change.
$result=Remove-KIStackOpenWebUICredential -Endpoint $Endpoint -TargetRoot $TargetRoot
$result|ConvertTo-Json -Depth 10
if(-not[bool]$result.passed){exit 1}

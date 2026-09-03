#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Endpoint='http://127.0.0.1:8080',
    [string]$TargetRoot='C:\KI-Stack',
    [switch]$Rotate
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}
Import-Module (Join-Path $PSScriptRoot 'Lifecycle/KIStackOpenWebUICredential.psm1') -Force -DisableNameChecking

# The one interactive entry point for the entire OpenWebUI-Credential-Bootstrap-Workstream
# (Section 4). Never called automatically by a normal Complete-Installer run (Section 24) -- an
# operator runs this deliberately, once, in their own real terminal. The admin password:
#   - is read via Read-Host -AsSecureString (never echoed to the console);
#   - is never written to a variable outside this script other than the SecureString itself;
#   - is never logged, never included in any transcript this script produces, never passed to
#     any child process as a command-line argument;
#   - is converted to plaintext exactly once, transiently, inside
#     Invoke-KIStackOpenWebUIAdminSignin's single signin HTTP call, and zeroed immediately after.
if(-not $Rotate){
    $existing=Test-KIStackOpenWebUICredential -Endpoint $Endpoint -TargetRoot $TargetRoot
    if([string]$existing.status-eq'Valid'){
        Write-Host "Bereits konfiguriert und gültig (Benutzer: $($existing.userEmail), Rolle: $($existing.role)). Kein neuer Bootstrap nötig -- zum Erzwingen -Rotate verwenden."
        [pscustomobject]@{passed=$true;status='AlreadyValid';credentialStatus=$existing}|ConvertTo-Json -Depth 10
        return
    }
}

Write-Host "OpenWebUI-Endpunkt: $Endpoint"
Write-Host 'Bitte die E-Mail-Adresse des OpenWebUI-Administrator-Kontos eingeben.'
$adminEmail=Read-Host 'Admin-E-Mail'
Write-Host 'Bitte das zugehörige Passwort eingeben (wird nicht angezeigt, nicht geloggt, nicht gespeichert).'
$adminPassword=Read-Host 'Admin-Passwort' -AsSecureString

try{
    $result=Initialize-KIStackOpenWebUICredential -Endpoint $Endpoint -AdminEmail $adminEmail -AdminPassword $adminPassword -TargetRoot $TargetRoot -Rotate:$Rotate
}finally{
    $adminPassword=$null
    $adminEmail=$null
    [GC]::Collect()
}

$result|ConvertTo-Json -Depth 10
if(-not[bool]$result.passed){exit 1}

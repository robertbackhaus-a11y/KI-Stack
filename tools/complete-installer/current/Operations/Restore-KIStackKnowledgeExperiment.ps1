[CmdletBinding()]
param(
    [string]$Endpoint = 'http://127.0.0.1:8080',
    [Parameter(Mandatory)][Security.SecureString]$ApiToken,
    [Parameter(Mandatory)][string]$BackupPath
)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}
# Compensates the PRE-COMMIT Knowledge-Detach step (Remove-KIStackKnowledgeExperiment.ps1) for a
# LATER finalization failure (Finalization-Rollback-P1). Restores exactly the complete model
# forms Detach itself backed up -- Detach never deletes a Knowledge collection or file, so there
# is nothing else to recreate here. Deliberately NOT implemented by reusing
# Restore-KIStackCodeInterpreter.ps1's pattern of also replaying a saved global config: Detach
# never touches OpenWebUI's code_execution config, so doing that here would risk overwriting an
# unrelated, untouched config value with a stale/irrelevant one.
function ConvertFrom-Secure([Security.SecureString]$Value){$p=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value);try{[Runtime.InteropServices.Marshal]::PtrToStringBSTR($p)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p)}}
function Invoke-Api([string]$Path,[object]$Body){$plain=ConvertFrom-Secure $ApiToken;try{Invoke-RestMethod -Uri ($Endpoint.TrimEnd('/')+$Path) -Method POST -Headers @{Authorization="Bearer $plain"} -ContentType 'application/json; charset=utf-8' -Body ($Body|ConvertTo-Json -Depth 50 -Compress) -TimeoutSec 120|Out-Null}finally{$plain=$null}}
$backup=Get-Content -LiteralPath $BackupPath -Raw|ConvertFrom-Json -Depth 50
foreach($profile in @($backup.profiles)){Invoke-Api '/api/v1/models/model/update' $profile.form}
$ApiToken=$null;[GC]::Collect();[pscustomobject]@{status='Restored';apiKeyStored=$false}

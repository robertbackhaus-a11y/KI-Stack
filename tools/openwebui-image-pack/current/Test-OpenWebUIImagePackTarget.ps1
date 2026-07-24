[CmdletBinding()]
param([string]$Endpoint='http://127.0.0.1:8080',[Security.SecureString]$ApiToken)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop';Import-Module (Join-Path $PSScriptRoot 'OpenWebUIImagePack.psm1') -Force
if($null-eq$ApiToken){$ApiToken=Read-Host 'Temporären OpenWebUI API-Key eingeben' -AsSecureString}
try{$v=Test-OpenWebUIImagePack $Endpoint $ApiToken;if(-not$v.passed){throw($v.failures-join'; ')}
$comfy=Invoke-RestMethod 'http://127.0.0.1:8188/system_stats' -TimeoutSec 20;if($null-eq$comfy.system){throw'ComfyUI-Systemstatus fehlt.'}
@{version='1.10.0';passed=$true;toolReadback=$true;methods=@('generate_image','generate_pony_image');profileBindings=$true;duplicateTool=$false;comfyUI=$true}|ConvertTo-Json
}finally{$ApiToken=$null;[GC]::Collect()}

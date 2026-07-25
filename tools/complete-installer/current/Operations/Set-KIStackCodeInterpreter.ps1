[CmdletBinding()]
param(
    [string]$Endpoint = 'http://127.0.0.1:8080',
    [Parameter(Mandatory)][Security.SecureString]$ApiToken,
    [Parameter(Mandatory)][string]$BackupDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}

function ConvertFrom-Secure([Security.SecureString]$Value){$p=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value);try{[Runtime.InteropServices.Marshal]::PtrToStringBSTR($p)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p)}}
function Invoke-Api([string]$Path,[string]$Method='GET',[object]$Body=$null){$plain=ConvertFrom-Secure $ApiToken;try{$p=@{Uri=$Endpoint.TrimEnd('/')+$Path;Method=$Method;Headers=@{Authorization="Bearer $plain"};TimeoutSec=120};if($null-ne$Body){$p.ContentType='application/json; charset=utf-8';$p.Body=$Body|ConvertTo-Json -Depth 50 -Compress};Invoke-RestMethod @p}finally{$plain=$null}}
function Get-Model([string]$Id){Invoke-Api ('/api/v1/models/model?id='+[Uri]::EscapeDataString($Id))}
function Get-Form([object]$Model){[ordered]@{id=[string]$Model.id;base_model_id=[string]$Model.base_model_id;name=[string]$Model.name;meta=$Model.meta;params=$Model.params;access_grants=@($Model.access_grants);is_active=[bool]$Model.is_active}}

New-Item -ItemType Directory -Path $BackupDirectory -Force|Out-Null
$config=Invoke-Api '/api/v1/configs/code_execution'
$ids=@('ki-stack-allgemein','ki-stack-it-technik','ki-stack-18bravo')
$models=@($ids|ForEach-Object{Get-Model $_})
$backup=[ordered]@{schemaVersion='1.0';createdAtUtc=[DateTime]::UtcNow.ToString('o');config=$config;models=@($models|ForEach-Object{Get-Form $_});containsSecrets=$false}
$backupPath=Join-Path $BackupDirectory 'code-interpreter.backup.json'
$backup|ConvertTo-Json -Depth 50|Set-Content -LiteralPath $backupPath -Encoding UTF8

$result=$null
try {
$desired=[ordered]@{
    ENABLE_CODE_EXECUTION=[bool]$config.ENABLE_CODE_EXECUTION;CODE_EXECUTION_ENGINE=[string]$config.CODE_EXECUTION_ENGINE
    CODE_EXECUTION_JUPYTER_URL=$config.CODE_EXECUTION_JUPYTER_URL;CODE_EXECUTION_JUPYTER_AUTH=$config.CODE_EXECUTION_JUPYTER_AUTH
    CODE_EXECUTION_JUPYTER_AUTH_TOKEN=$config.CODE_EXECUTION_JUPYTER_AUTH_TOKEN;CODE_EXECUTION_JUPYTER_AUTH_PASSWORD=$config.CODE_EXECUTION_JUPYTER_AUTH_PASSWORD
    CODE_EXECUTION_JUPYTER_TIMEOUT=$config.CODE_EXECUTION_JUPYTER_TIMEOUT;ENABLE_CODE_INTERPRETER=$true;CODE_INTERPRETER_ENGINE='pyodide'
    CODE_INTERPRETER_PROMPT_TEMPLATE=$config.CODE_INTERPRETER_PROMPT_TEMPLATE;CODE_INTERPRETER_JUPYTER_URL=$null;CODE_INTERPRETER_JUPYTER_AUTH=$null
    CODE_INTERPRETER_JUPYTER_AUTH_TOKEN=$null;CODE_INTERPRETER_JUPYTER_AUTH_PASSWORD=$null;CODE_INTERPRETER_JUPYTER_TIMEOUT=$null
}
$null=Invoke-Api '/api/v1/configs/code_execution' 'POST' $desired
$expectedTools=@{
    'ki-stack-allgemein'=@('ki_stack_generate_image','ki_stack_generate_video')
    'ki-stack-it-technik'=@('ki_stack_generate_image','ki_stack_generate_video')
    'ki-stack-18bravo'=@('ki_stack_ballistics_calculator')
}
foreach($model in $models){$id=[string]$model.id;$actual=@($model.meta.toolIds);if(($actual-join'|')-ne($expectedTools[$id]-join'|')){throw "Unerwartete Toolbindung für ${id}: $($actual-join', ')"};$form=Get-Form $model;$form.meta.knowledge=@();$form.meta.toolIds=@($expectedTools[$id]);if($null-eq$form.meta.capabilities){$form.meta|Add-Member -NotePropertyName capabilities -NotePropertyValue ([pscustomobject]@{})};$enabled=$id-in@('ki-stack-allgemein','ki-stack-it-technik');$form.meta.capabilities|Add-Member -NotePropertyName code_interpreter -NotePropertyValue $enabled -Force;$null=Invoke-Api '/api/v1/models/model/update' 'POST' $form}
$readbackConfig=Invoke-Api '/api/v1/configs/code_execution'
$readback=@($ids|ForEach-Object{$m=Get-Model $_;[ordered]@{id=$_.ToString();codeInterpreter=[bool]$m.meta.capabilities.code_interpreter;knowledge=@($m.meta.knowledge);toolIds=@($m.meta.toolIds)}})
$ok=[bool]$readbackConfig.ENABLE_CODE_INTERPRETER-and[string]$readbackConfig.CODE_INTERPRETER_ENGINE-eq'pyodide'-and@($readback|Where-Object{@($_.knowledge).Count-ne0-or(@($_.toolIds)-join'|')-ne($expectedTools[$_.id]-join'|')-or($_.codeInterpreter-ne($_.id-in@('ki-stack-allgemein','ki-stack-it-technik')))}).Count-eq0
if(-not$ok){throw'Code-Interpreter-Readback entspricht nicht dem KI-Stack-Vertrag.'}
$result=[pscustomobject]@{status='Configured';engine='pyodide';profiles=$readback;backupPath=$backupPath;apiKeyStored=$false}
}
catch {
    $configurationError=$_
    try {
        & (Join-Path $PSScriptRoot 'Restore-KIStackCodeInterpreter.ps1') -Endpoint $Endpoint -ApiToken $ApiToken -BackupPath $backupPath | Out-Null
        $configurationError.Exception.Data['KIStackRollbackStatus']='Completed'
        $configurationError.Exception.Data['KIStackBackupPath']=$backupPath
    }
    catch {
        throw "Code-Interpreter-Konfiguration und Rollback fehlgeschlagen: $($configurationError.Exception.Message); Rollback: $($_.Exception.Message)"
    }
    throw $configurationError
}
$ApiToken=$null;[GC]::Collect();$result

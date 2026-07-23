[CmdletBinding()]
param(
    [string]$SourcePath = (Join-Path $PSScriptRoot 'ExternalModels'),
    [string]$TargetRoot = 'C:\KI-Stack\models',
    [string]$StateRoot = 'C:\KI-Stack\state\model-import',
    [string]$TransactionId,
    [switch]$Resume,
    [switch]$Rollback,
    [switch]$Audit,
    [switch]$DisableNetwork
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$payloadDirectory=Join-Path $PSScriptRoot 'Payload\ModelsWorkflows'
$archive=Get-ChildItem -LiteralPath $payloadDirectory -File -Filter 'KI-Stack-Models-Workflows-Execute-v1.4.5.zip'|Select-Object -First 1
if(-not$archive){throw "Models-/Workflows-Payload 1.4.5 fehlt: $payloadDirectory"}
$extractRoot=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-Models-1.4.5-'+[guid]::NewGuid().ToString('N'))
try{
    Expand-Archive -LiteralPath $archive.FullName -DestinationPath $extractRoot
    $importer=Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter 'Import-KIStackExternalModels.ps1'|Select-Object -First 1
    if(-not$importer){throw 'Import-KIStackExternalModels.ps1 fehlt im Models-/Workflows-Payload.'}
    $arguments=@('-SourcePath',$SourcePath,'-TargetRoot',$TargetRoot,'-StateRoot',$StateRoot)
    if($TransactionId){$arguments+=@('-TransactionId',$TransactionId)}
    if($Resume){$arguments+='-Resume'}
    if($Rollback){$arguments+='-Rollback'}
    if($Audit){$arguments+='-Audit'}
    if($DisableNetwork){$arguments+='-DisableNetwork'}
    & $importer.FullName @arguments
}finally{
    if(Test-Path -LiteralPath $extractRoot){Remove-Item -LiteralPath $extractRoot -Recurse -Force}
}

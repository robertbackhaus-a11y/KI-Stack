[CmdletBinding()]
param(
    [string]$Endpoint = 'http://127.0.0.1:8080',
    [Parameter(Mandatory)][Security.SecureString]$ApiToken,
    [Parameter(Mandatory)][string]$BackupDirectory
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}
# PRE-COMMIT step ("Detach") of the two-phase Knowledge-Experiment removal
# (Finalization-Rollback-P1). Despite its historical name, this script no longer deletes
# anything: it only unbinds meta.knowledge from KI-Stack's managed profiles, which is fully
# reversible via Restore-KIStackKnowledgeExperiment.ps1 and the complete model forms backed up
# below. Actually deleting the now-unreferenced Knowledge collections/files is real,
# irreversible destruction (OpenWebUI has no soft-delete/rename for Knowledge, and a recreated
# collection is assigned a new id regardless, so even a perfect content backup could not restore
# an identical reference) and must never happen before WriteFinalState -- the installation's
# commit boundary. That deletion now lives in the separate, POST-COMMIT, best-effort
# Operations/Remove-KIStackKnowledgeExperimentCollections.ps1, run only after a successful
# commit and never able to roll back an already-committed installation.
function Get-Optional($Object,[string]$Name,$Default=$null){if($null -eq $Object){return $Default};$property=$Object.PSObject.Properties[$Name];if($null -ne $property){return $property.Value};return $Default}
function Invoke-Api($Path,$Method='GET',$Body=$null){$pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($ApiToken);try{$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer);$p=@{Uri=$Endpoint.TrimEnd('/')+$Path;Method=$Method;Headers=@{Authorization="Bearer $plain"};TimeoutSec=120};if($null -ne $Body){$p.ContentType='application/json';$p.Body=$Body|ConvertTo-Json -Depth 50 -Compress};Invoke-RestMethod @p}finally{$plain=$null;[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}}
function Convert-Model($Model){[ordered]@{id=[string](Get-Optional $Model id);base_model_id=[string](Get-Optional $Model base_model_id);name=[string](Get-Optional $Model name);meta=Get-Optional $Model meta ([pscustomobject]@{});params=Get-Optional $Model params ([pscustomobject]@{});access_grants=@(Get-Optional $Model access_grants @());is_active=[bool](Get-Optional $Model is_active $true)}}
New-Item $BackupDirectory -ItemType Directory -Force|Out-Null
$response=Invoke-Api '/api/v1/knowledge/';$collections=@(if($response-is[array]){$response}elseif(Get-Optional $response items){$response.items}else{@($response)})
$matched=@($collections|Where-Object{(([string](Get-Optional $_ id))+' '+([string](Get-Optional $_ name))+' '+([string](Get-Optional $_ description))) -match '(?i)ki[- ]?stack|openwebui[- ]knowledge|chatgpt[- ]knowledge'})
$profiles=@();foreach($id in 'ki-stack-allgemein','ki-stack-it-technik','ki-stack-18bravo'){$model=Invoke-Api('/api/v1/models/model?id='+[Uri]::EscapeDataString($id));$profiles+=@([ordered]@{id=$id;form=Convert-Model $model})}
# Note (fixed alongside this P1 split): each matched collection now gets its OWN fileIds list --
# the prior version accumulated every collection's file ids into one shared HashSet, so a
# collection's recorded fileIds silently included every earlier collection's files too.
$collectionsPendingCleanup=@()
foreach($collection in $matched){
    $id=[string](Get-Optional $collection id)
    $files=Invoke-Api("/api/v1/knowledge/$id/files")
    $entries=@(if(Get-Optional $files items){$files.items}else{$files})
    $fileIds=[Collections.Generic.List[string]]::new()
    foreach($file in $entries){$fileId=[string](Get-Optional $file id (Get-Optional $file file_id));if($fileId){$fileIds.Add($fileId)}}
    $collectionsPendingCleanup+=@([pscustomobject]@{id=$id;name=[string](Get-Optional $collection name);fileIds=@($fileIds)})
}
$backup=[ordered]@{schemaVersion='2.0';createdAtUtc=[DateTime]::UtcNow.ToString('o');profiles=$profiles;collectionsPendingCleanup=$collectionsPendingCleanup;containsFileContent=$false;containsSecrets=$false}
$backupPath=Join-Path $BackupDirectory 'knowledge-rollback.backup.json'
$backup|ConvertTo-Json -Depth 50|Set-Content -LiteralPath $backupPath -Encoding UTF8
foreach($profile in $profiles){$form=$profile.form;$meta=$form.meta;if($null -eq $meta.PSObject.Properties['knowledge']){$meta|Add-Member -NotePropertyName knowledge -NotePropertyValue @()}else{$meta.knowledge=@()};$null=Invoke-Api '/api/v1/models/model/update' 'POST' $form}
$readback=@();foreach($id in 'ki-stack-allgemein','ki-stack-it-technik','ki-stack-18bravo'){$model=Invoke-Api('/api/v1/models/model?id='+[Uri]::EscapeDataString($id));$readback+=@([ordered]@{id=$id;knowledge=@(Get-Optional (Get-Optional $model meta ([pscustomobject]@{})) knowledge @());toolIds=@(Get-Optional (Get-Optional $model meta ([pscustomobject]@{})) toolIds @())})}
$passed=(@($readback|Where-Object{@($_.knowledge).Count -ne 0}).Count -eq 0)
if(-not$passed){throw'Knowledge-Detach-Readback entspricht nicht dem KI-Stack-Vertrag: mindestens ein Profil enthält nach dem Entkoppeln weiterhin Knowledge-Bindungen.'}
[pscustomobject]@{status='Detached';passed=$passed;profiles=$readback;collectionsPendingCleanup=$collectionsPendingCleanup;backupPath=$backupPath;apiKeyStored=$false}

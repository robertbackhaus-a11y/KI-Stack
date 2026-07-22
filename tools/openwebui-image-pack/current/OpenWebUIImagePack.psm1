Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-ImagePackSecureString {
    param([Parameter(Mandatory)][Security.SecureString]$SecureString)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Invoke-ImagePackApi {
    param([string]$Endpoint,[Security.SecureString]$ApiToken,[string]$Path,[ValidateSet('GET','POST','DELETE')][string]$Method='GET',[AllowNull()][object]$Body=$null)
    $plainToken = ConvertFrom-ImagePackSecureString $ApiToken
    try {
        $p=@{Uri=$Endpoint.TrimEnd('/')+$Path;Method=$Method;Headers=@{Authorization="Bearer $plainToken"};TimeoutSec=120}
        if($null-ne $Body){$p.ContentType='application/json; charset=utf-8';$p.Body=$Body|ConvertTo-Json -Depth 40 -Compress}
        Invoke-RestMethod @p
    } finally { $plainToken=$null }
}

function Get-ImagePackTool {
    param([string]$Endpoint,[Security.SecureString]$ApiToken)
    try { Invoke-ImagePackApi $Endpoint $ApiToken '/api/v1/tools/id/ki_stack_generate_image' }
    catch { if($_.Exception.Response.StatusCode.value__ -eq 404){return $null};throw }
}

function Get-ImagePackModel {
    param([string]$Endpoint,[Security.SecureString]$ApiToken,[string]$Id)
    try { Invoke-ImagePackApi $Endpoint $ApiToken ("/api/v1/models/model?id="+[Uri]::EscapeDataString($Id)) }
    catch { if($_.Exception.Response.StatusCode.value__ -eq 404){return $null};throw }
}

function ConvertTo-ImagePackModelForm {
    param([object]$Model,[string[]]$ToolIds)
    $meta=[ordered]@{}; $Model.meta.psobject.Properties|ForEach-Object{$meta[$_.Name]=$_.Value};$meta.toolIds=@($ToolIds)
    [ordered]@{id=[string]$Model.id;base_model_id=[string]$Model.base_model_id;name=[string]$Model.name;meta=$meta;params=$Model.params;access_grants=@($Model.access_grants);is_active=[bool]$Model.is_active}
}

function New-ImagePackToolForm {
    param([string]$PackageRoot)
    [ordered]@{
        id='ki_stack_generate_image';name='KI-Stack Bildgenerierung'
        content=Get-Content -LiteralPath (Join-Path $PackageRoot 'Tool\ki-stack-generate-image.py') -Raw -Encoding UTF8
        meta=[ordered]@{description='Direkte FLUX2-Bildgenerierung über die lokale ComfyUI-API.';manifest=[ordered]@{managedBy='KI-STACK-OPENWEBUI-IMAGE-PACK';version='1.9.1';workflow='FLUX2-Klein-9B-OpenWebUI-API-FLAT'};has_user_valves=$false}
        access_grants=@()
    }
}

function ConvertTo-ImagePackToolForm {
    param([object]$Tool)
    [ordered]@{id=[string]$Tool.id;name=[string]$Tool.name;content=[string]$Tool.content;meta=$Tool.meta;access_grants=@($Tool.access_grants)}
}

function Backup-OpenWebUIImagePack {
    param([string]$Endpoint,[Security.SecureString]$ApiToken,[string]$BackupDirectory)
    New-Item -ItemType Directory -Path $BackupDirectory -Force|Out-Null
    $tool=Get-ImagePackTool $Endpoint $ApiToken
    $models=@(@('ki-stack-it-technik','ki-stack-allgemein')|ForEach-Object{Get-ImagePackModel $Endpoint $ApiToken $_})
    $backup=[ordered]@{schemaVersion='1.0';createdAtUtc=[DateTime]::UtcNow.ToString('o');toolExisted=($null-ne $tool);tool=if($null-ne$tool){ConvertTo-ImagePackToolForm $tool}else{$null};profileBindings=@($models|ForEach-Object{if($null-eq $_){$null}else{[ordered]@{id=[string]$_.id;toolIds=@($_.meta.toolIds)}}})}
    $path=Join-Path $BackupDirectory 'image-pack.backup.json';$backup|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $path -Encoding UTF8;$path
}

function Install-OpenWebUIImagePack {
    param([string]$PackageRoot,[string]$Endpoint,[Security.SecureString]$ApiToken,[string]$BackupDirectory)
    $backup=Backup-OpenWebUIImagePack $Endpoint $ApiToken $BackupDirectory
    $form=New-ImagePackToolForm $PackageRoot;$current=Get-ImagePackTool $Endpoint $ApiToken
    if($null-ne$current-and[string]$current.meta.manifest.managedBy-ne'KI-STACK-OPENWEBUI-IMAGE-PACK'){throw'Tool-ID-Kollision: ki_stack_generate_image ist nicht durch KI-STACK-OPENWEBUI-IMAGE-PACK verwaltet.'}
    $path=if($null-eq $current){'/api/v1/tools/create'}else{'/api/v1/tools/id/ki_stack_generate_image/update'}
    $null=Invoke-ImagePackApi $Endpoint $ApiToken $path POST $form
    foreach($id in @('ki-stack-it-technik','ki-stack-allgemein')){$model=Get-ImagePackModel $Endpoint $ApiToken $id;if($null-eq $model){throw "Agent-Pack-Profil fehlt: $id"};$null=Invoke-ImagePackApi $Endpoint $ApiToken '/api/v1/models/model/update' POST (ConvertTo-ImagePackModelForm $model @('ki_stack_generate_image'))}
    [pscustomobject]@{backupPath=$backup;toolAction=if($null-eq $current){'created'}else{'updated'}}
}

function Test-OpenWebUIImagePack {
    param([string]$Endpoint,[Security.SecureString]$ApiToken)
    $fail=[Collections.Generic.List[string]]::new();$tool=Get-ImagePackTool $Endpoint $ApiToken
    if($null-eq $tool){$fail.Add('Tool fehlt')}else{if([string]$tool.id-ne'ki_stack_generate_image'){$fail.Add('Tool-ID')};if([string]$tool.name-ne'KI-Stack Bildgenerierung'){$fail.Add('Tool-Name')};if([string]$tool.meta.manifest.managedBy-ne'KI-STACK-OPENWEBUI-IMAGE-PACK'-or[string]$tool.meta.manifest.version-ne'1.9.1'-or[string]$tool.meta.manifest.canonical_id-ne'ki-stack-generate-image'){$fail.Add('Tool-Manifest')}}
    foreach($id in @('ki-stack-it-technik','ki-stack-allgemein')){$m=Get-ImagePackModel $Endpoint $ApiToken $id;$ids=@($m.meta.toolIds);if($ids.Count-ne 1-or[string]$ids[0]-ne'ki_stack_generate_image'){$fail.Add("Profilbindung: $id")}}
    $list=Invoke-ImagePackApi $Endpoint $ApiToken '/api/v1/tools/';if(@($list|Where-Object{$_.id-eq'ki_stack_generate_image'}).Count-ne 1){$fail.Add('Tool-Duplikat')}
    [pscustomobject]@{passed=($fail.Count-eq 0);failures=@($fail)}
}

function Restore-OpenWebUIImagePack {
    param([string]$Endpoint,[Security.SecureString]$ApiToken,[string]$BackupPath)
    $b=Get-Content -LiteralPath $BackupPath -Raw|ConvertFrom-Json -Depth 40
    if($b.toolExisted){$null=Invoke-ImagePackApi $Endpoint $ApiToken '/api/v1/tools/id/ki_stack_generate_image/update' POST $b.tool}elseif($null-ne(Get-ImagePackTool $Endpoint $ApiToken)){$null=Invoke-ImagePackApi $Endpoint $ApiToken '/api/v1/tools/id/ki_stack_generate_image/delete' DELETE}
    foreach($binding in @($b.profileBindings)){if($null-ne$binding){$current=Get-ImagePackModel $Endpoint $ApiToken ([string]$binding.id);if($null-ne$current){$null=Invoke-ImagePackApi $Endpoint $ApiToken '/api/v1/models/model/update' POST (ConvertTo-ImagePackModelForm $current @($binding.toolIds))}}}
}

Export-ModuleMember -Function Invoke-ImagePackApi,Install-OpenWebUIImagePack,Test-OpenWebUIImagePack,Restore-OpenWebUIImagePack

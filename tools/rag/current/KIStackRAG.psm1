#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-RAGSecureString {
    param([Parameter(Mandatory)][Security.SecureString]$Value)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Write-RAGJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$Value)
    $parent = Split-Path -Parent $Path
    if ($parent) { $null = New-Item -ItemType Directory -Path $parent -Force }
    $temporary = "$Path.new"
    $Value | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-RAGJson {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 50
}

function Get-RAGProperty {
    param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name,[AllowNull()][object]$Default=$null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    $property.Value
}

function Invoke-RAGApi {
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][Security.SecureString]$ApiToken,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('GET','POST','DELETE')][string]$Method='GET',
        [AllowNull()][object]$Body=$null,
        [AllowEmptyString()][string]$UploadPath='',
        [AllowNull()][object]$Metadata=$null
    )
    $plainToken = ConvertFrom-RAGSecureString $ApiToken
    try {
        $parameters = @{
            Uri = $Endpoint.TrimEnd('/') + $Path
            Method = $Method
            Headers = @{Authorization="Bearer $plainToken"}
            TimeoutSec = 180
        }
        if ($UploadPath) {
            $parameters.Form = @{file=Get-Item -LiteralPath $UploadPath}
            if ($null -ne $Metadata) { $parameters.Form.metadata=($Metadata|ConvertTo-Json -Depth 20 -Compress) }
        } elseif ($null -ne $Body) {
            $parameters.ContentType='application/json; charset=utf-8'
            $parameters.Body=$Body|ConvertTo-Json -Depth 30 -Compress
        }
        Invoke-RestMethod @parameters
    } catch {
        $message = [string]$_.Exception.Message
        if ($plainToken) { $message=$message.Replace($plainToken,'<redacted>') }
        $message=$message -replace '(?i)Bearer\s+\S+','Bearer <redacted>' -replace '(?i)\bsk-[A-Za-z0-9._-]{10,}\b','<redacted>'
        throw "OpenWebUI-API-Fehler ($Method $Path): $message"
    } finally { $plainToken=$null }
}

function Get-RAGStableId {
    param([Parameter(Mandatory)][string]$SourceId,[Parameter(Mandatory)][string]$RelativePath)
    $bytes=[Text.Encoding]::UTF8.GetBytes("$SourceId`n$($RelativePath.Replace('\','/').ToLowerInvariant())")
    $hash=[Security.Cryptography.SHA256]::HashData($bytes)
    ([Convert]::ToHexString($hash)).ToLowerInvariant()
}

function Split-RAGContent {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][int]$Size,
        [Parameter(Mandatory)][int]$Overlap
    )
    if ($Size -lt 1000 -or $Overlap -lt 0 -or $Overlap -ge $Size) { throw 'Ungültiger Chunkvertrag.' }
    $normalized=$Content.Replace("`r`n","`n").Replace("`r","`n").Trim()
    if (-not $normalized) { return @() }
    $chunks=[Collections.Generic.List[string]]::new()
    $start=0
    while($start -lt $normalized.Length){
        $length=[Math]::Min($Size,$normalized.Length-$start)
        if($start+$length -lt $normalized.Length){
            $window=$normalized.Substring($start,$length)
            $break=$window.LastIndexOf("`n`n")
            if($break -lt [int]($Size*0.55)){$break=$window.LastIndexOf("`n")}
            if($break -ge [int]($Size*0.55)){$length=$break}
        }
        $chunk=$normalized.Substring($start,$length).Trim()
        if($chunk){$chunks.Add($chunk)}
        if($start+$length -ge $normalized.Length){break}
        $start=[Math]::Max($start+1,$start+$length-$Overlap)
    }
    @($chunks)
}

function Get-RAGSection {
    param([string]$Text)
    $heading=@($Text -split "`n"|Where-Object{$_ -match '^\s{0,3}#{1,6}\s+\S'}|Select-Object -First 1)
    if($heading.Count){return ([string]$heading[0]).TrimStart('#',' ')}
    'content'
}

function Get-RAGInventory {
    param([Parameter(Mandatory)][object]$Config,[Parameter(Mandatory)][object]$Sources)
    $result=[Collections.Generic.List[object]]::new()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($source in @($Sources.sources|Where-Object enabled)){
        if(-not(Test-Path -LiteralPath $source.root -PathType Container)){throw "Quellpfad fehlt: $($source.root)"}
        if(-not$seen.Add([string]$source.source_id)){throw "source_id doppelt: $($source.source_id)"}
        $files=Get-ChildItem -LiteralPath $source.root -File -Recurse|Where-Object{
            $relativeParts=$_.FullName.Substring(([string]$source.root).Length).TrimStart('\','/') -split '[\\/]'
            $excluded=@($relativeParts|Where-Object{@($Config.excludedDirectoryNames)-contains$_}).Count -gt 0
            (@($Config.allowedExtensions)-contains$_.Extension.ToLowerInvariant()) -and -not$excluded
        }
        foreach($file in $files){
            $relative=[IO.Path]::GetRelativePath([string]$source.root,$file.FullName).Replace('\','/')
            $hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $stable=Get-RAGStableId -SourceId ([string]$source.source_id) -RelativePath $relative
            $result.Add([pscustomobject]@{
                key=$stable;source_id=[string]$source.source_id;source_type=[string]$source.source_type
                project=[string]$source.project;visibility=[string]$source.visibility
                root=[string]$source.root;path=$file.FullName;relative_path=$relative
                file_name=$file.Name;file_sha256=$hash;modified_at=$file.LastWriteTimeUtc.ToString('o')
            })
        }
    }
    @($result|Sort-Object source_id,relative_path)
}

function Get-RAGPlan {
    param([object[]]$Inventory,[AllowNull()][object]$State)
    $old=@{}
    if($null-ne$State){foreach($entry in @($State.entries)){$old[[string]$entry.key]=$entry}}
    $current=@{};foreach($entry in $Inventory){$current[[string]$entry.key]=$entry}
    $actions=[Collections.Generic.List[object]]::new()
    foreach($entry in $Inventory){
        if(-not$old.ContainsKey($entry.key)){$actions.Add([pscustomobject]@{action='Add';current=$entry;previous=$null})}
        elseif([string]$old[$entry.key].file_sha256-ne$entry.file_sha256){$actions.Add([pscustomobject]@{action='Replace';current=$entry;previous=$old[$entry.key]})}
        else{$actions.Add([pscustomobject]@{action='Skip';current=$entry;previous=$old[$entry.key]})}
    }
    foreach($key in $old.Keys){if(-not$current.ContainsKey($key)){$actions.Add([pscustomobject]@{action='Remove';current=$null;previous=$old[$key]})}}
    @($actions)
}

function Get-RAGKnowledge {
    param([object]$Config,[Security.SecureString]$ApiToken,[switch]$Create)
    $response=Invoke-RAGApi $Config.openWebUIEndpoint $ApiToken '/api/v1/knowledge/'
    $items=@(if($null-ne(Get-RAGProperty $response 'items')){$response.items}elseif($response-is[array]){$response}else{@($response)})
    $matches=@($items|Where-Object{[string]$_.name-eq[string]$Config.knowledgeName})
    if($matches.Count -gt 1){throw "Knowledge-Name ist nicht eindeutig: $($Config.knowledgeName)"}
    if($matches.Count -eq 1){return$matches[0]}
    if(-not$Create){return$null}
    Invoke-RAGApi $Config.openWebUIEndpoint $ApiToken '/api/v1/knowledge/create' POST ([ordered]@{
        name=[string]$Config.knowledgeName;description=[string]$Config.knowledgeDescription;access_grants=@()
    })
}

function Set-RAGEmbeddingContract {
    param([object]$Config,[Security.SecureString]$ApiToken,[string]$BackupPath)
    $models=Invoke-RestMethod -Uri ($Config.embeddingBaseUrl.TrimEnd('/')+'/models') -Method GET -TimeoutSec 30
    $modelIds=@($models.data|ForEach-Object{[string]$_.id})
    if($modelIds-notcontains[string]$Config.embeddingModel){
        throw "LM-Studio-Embedding-Modell ist nicht geladen: $($Config.embeddingModel)"
    }
    $current=Invoke-RAGApi $Config.openWebUIEndpoint $ApiToken '/api/v1/retrieval/embedding'
    $safeBackup=[ordered]@{
        captured_at=[DateTime]::UtcNow.ToString('o')
        RAG_EMBEDDING_ENGINE=[string]$current.RAG_EMBEDDING_ENGINE
        RAG_EMBEDDING_MODEL=[string]$current.RAG_EMBEDDING_MODEL
        RAG_EMBEDDING_BATCH_SIZE=$current.RAG_EMBEDDING_BATCH_SIZE
        ENABLE_ASYNC_EMBEDDING=$current.ENABLE_ASYNC_EMBEDDING
        RAG_EMBEDDING_CONCURRENT_REQUESTS=$current.RAG_EMBEDDING_CONCURRENT_REQUESTS
        openai_url=[string]$current.openai_config.url
        credentials_omitted=$true
        containsSecrets=$false
    }
    Write-RAGJson $BackupPath $safeBackup
    $body=[ordered]@{
        openai_config=[ordered]@{url=[string]$Config.embeddingBaseUrl;key=''}
        ollama_config=$null;azure_openai_config=$null
        RAG_EMBEDDING_ENGINE='openai';RAG_EMBEDDING_MODEL=[string]$Config.embeddingModel
        RAG_EMBEDDING_BATCH_SIZE=1;ENABLE_ASYNC_EMBEDDING=$true;RAG_EMBEDDING_CONCURRENT_REQUESTS=1
    }
    $null=Invoke-RAGApi $Config.openWebUIEndpoint $ApiToken '/api/v1/retrieval/embedding/update' POST $body
    $readback=Invoke-RAGApi $Config.openWebUIEndpoint $ApiToken '/api/v1/retrieval/embedding'
    if([string]$readback.RAG_EMBEDDING_ENGINE-ne'openai' -or [string]$readback.RAG_EMBEDDING_MODEL-ne[string]$Config.embeddingModel){
        throw 'OpenWebUI-Embedding-Readback verletzt den Nomic-Vertrag.'
    }
    $readback
}

function New-RAGChunks {
    param([object]$Entry,[object]$Config,[string]$Directory,[string]$ImportedAt)
    $content=Get-Content -LiteralPath $Entry.path -Raw -Encoding UTF8
    $parts=Split-RAGContent $content ([int]$Config.chunkCharacters) ([int]$Config.chunkOverlapCharacters)
    $result=[Collections.Generic.List[object]]::new();$index=0
    foreach($part in $parts){
        $metadata=[ordered]@{
            source_id=$Entry.source_id;source_type=$Entry.source_type;project=$Entry.project
            relative_path=$Entry.relative_path;file_name=$Entry.file_name;file_sha256=$Entry.file_sha256
            document_version='sha256:'+$Entry.file_sha256;section=Get-RAGSection $part;chunk_index=$index
            imported_at=$ImportedAt;modified_at=$Entry.modified_at;content_language='und'
            visibility=$Entry.visibility;parser_version=[string]$Config.parserVersion
        }
        $name="$($Entry.key)-$('{0:d5}'-f$index).md";$path=Join-Path $Directory $name
        $header="---`n"+(($metadata|ConvertTo-Json -Compress).Replace("`n",''))+"`n---`n`n"
        Set-Content -LiteralPath $path -Value ($header+$part) -Encoding utf8NoBOM
        $result.Add([pscustomobject]@{path=$path;name=$name;metadata=$metadata;index=$index})
        $index++
    }
    @($result)
}

function Remove-RAGRemoteEntry {
    param([object]$Config,[Security.SecureString]$ApiToken,[string]$KnowledgeId,[object]$Entry)
    foreach($chunk in @($Entry.chunks)){
        $body=@{file_id=[string]$chunk.file_id}
        $null=Invoke-RAGApi $Config.openWebUIEndpoint $ApiToken "/api/v1/knowledge/$KnowledgeId/file/remove?delete_file=true" POST $body
    }
}

function Add-RAGRemoteEntry {
    param([object]$Config,[Security.SecureString]$ApiToken,[string]$KnowledgeId,[object]$Entry,[string]$WorkDirectory)
    $chunks=New-RAGChunks $Entry $Config $WorkDirectory ([DateTime]::UtcNow.ToString('o'))
    $uploaded=[Collections.Generic.List[object]]::new()
    try{
        foreach($chunk in $chunks){
            $file=Invoke-RAGApi $Config.openWebUIEndpoint $ApiToken '/api/v1/files/?process=true&process_in_background=false' POST $null $chunk.path $chunk.metadata
            $uploaded.Add([pscustomobject]@{file_id=[string]$file.id;chunk_index=$chunk.index;name=$chunk.name})
        }
        if($uploaded.Count){
            $forms=@($uploaded|ForEach-Object{@{file_id=$_.file_id;directory_id=$null}})
            $null=Invoke-RAGApi $Config.openWebUIEndpoint $ApiToken "/api/v1/knowledge/$KnowledgeId/files/batch/add" POST $forms
        }
        [pscustomobject]@{
            key=$Entry.key;source_id=$Entry.source_id;source_type=$Entry.source_type;project=$Entry.project
            visibility=$Entry.visibility;relative_path=$Entry.relative_path;file_name=$Entry.file_name
            file_sha256=$Entry.file_sha256;modified_at=$Entry.modified_at;chunks=@($uploaded)
        }
    }catch{
        foreach($item in $uploaded){try{$null=Invoke-RAGApi $Config.openWebUIEndpoint $ApiToken "/api/v1/files/$($item.file_id)" DELETE}catch{}}
        throw
    }
}

function Invoke-KIStackRAG {
    [CmdletBinding()]
    param(
        [ValidateSet('Audit','DryRun','Execute','Status','Rollback')][string]$Mode='Audit',
        [string]$PackageRoot=$PSScriptRoot,
        [string]$ConfigPath=(Join-Path $PSScriptRoot 'Config\rag.config.json'),
        [string]$SourcesPath=(Join-Path $PSScriptRoot 'Config\sources.json'),
        [Security.SecureString]$ApiToken
    )
    $config=Read-RAGJson $ConfigPath;$sources=Read-RAGJson $SourcesPath
    $stateRoot=[string]$config.stateRoot;$statePath=Join-Path $stateRoot 'state.json'
    $state=if(Test-Path -LiteralPath $statePath){Read-RAGJson $statePath}else{$null}
    $inventory=Get-RAGInventory $config $sources;$plan=Get-RAGPlan $inventory $state
    if($Mode-in@('Audit','DryRun','Status')){
        return[pscustomobject]@{
            mode=$Mode;version=[string]$config.version;sources=@($sources.sources).Count;files=$inventory.Count
            add=@($plan|Where-Object action-eq'Add').Count;replace=@($plan|Where-Object action-eq'Replace').Count
            remove=@($plan|Where-Object action-eq'Remove').Count;skip=@($plan|Where-Object action-eq'Skip').Count
            statePresent=($null-ne$state);mutatesTarget=$false
        }
    }
    if($null-eq$ApiToken){throw 'ApiToken ist für Execute und Rollback erforderlich.'}
    if($Mode-eq'Rollback'){
        $backupPath=Join-Path $stateRoot 'previous-state.json'
        if(-not(Test-Path -LiteralPath $backupPath)){throw 'Kein rücksetzbarer Vorzustand vorhanden.'}
        throw 'Explizites Remote-Rollback wird erst nach Zielsystem-Abnahme freigegeben; der Vorzustand ist erhalten.'
    }
    $knowledge=Get-RAGKnowledge $config $ApiToken -Create
    $transaction=Join-Path $stateRoot ('transactions\'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    $work=Join-Path $transaction 'chunks';$null=New-Item -ItemType Directory -Path $work -Force
    $embedding=Set-RAGEmbeddingContract $config $ApiToken (Join-Path $transaction 'embedding-before.json')
    if($null-ne$state){Write-RAGJson (Join-Path $stateRoot 'previous-state.json') $state}
    $entries=@{};if($null-ne$state){foreach($entry in @($state.entries)){$entries[[string]$entry.key]=$entry}}
    try{
        foreach($action in @($plan|Where-Object action-in@('Add','Replace'))){
            $new=Add-RAGRemoteEntry $config $ApiToken ([string]$knowledge.id) $action.current $work
            if($action.action-eq'Replace'){Remove-RAGRemoteEntry $config $ApiToken ([string]$knowledge.id) $action.previous}
            $entries[[string]$new.key]=$new
        }
        foreach($action in @($plan|Where-Object action-eq'Remove')){
            Remove-RAGRemoteEntry $config $ApiToken ([string]$knowledge.id) $action.previous
            $entries.Remove([string]$action.previous.key)
        }
        $newState=[ordered]@{schemaVersion='1.0';version=[string]$config.version;knowledge_id=[string]$knowledge.id;updated_at=[DateTime]::UtcNow.ToString('o');entries=@($entries.Values|Sort-Object source_id,relative_path)}
        Write-RAGJson $statePath $newState
        [pscustomobject]@{mode='Execute';passed=$true;knowledge_id=[string]$knowledge.id;embeddingModel=[string]$embedding.RAG_EMBEDDING_MODEL;entries=$entries.Count;transaction=$transaction;apiKeyStored=$false}
    }catch{
        Write-RAGJson (Join-Path $transaction 'failure.json') ([ordered]@{failed_at=[DateTime]::UtcNow.ToString('o');message=[string]$_.Exception.Message;apiKeyStored=$false})
        throw
    }
}

Export-ModuleMember -Function Invoke-KIStackRAG,Get-RAGInventory,Get-RAGPlan,Split-RAGContent

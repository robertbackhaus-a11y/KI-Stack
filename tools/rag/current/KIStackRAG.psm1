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
        [AllowNull()][object]$Metadata=$null,
        [switch]$BodyIsArray
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
            if ($BodyIsArray) {
                # A single-element array piped into ConvertTo-Json is enumerated by
                # the pipeline before it arrives, so @($one) | ConvertTo-Json emits a
                # bare JSON object instead of a one-element array. Passing via
                # -InputObject (not the pipe) preserves the array as one object, so
                # ConvertTo-Json serializes it correctly for 0, 1, or many elements.
                # -AsArray is deliberately not used here: $Body is already a real
                # array (callers pass it via @(...)), and -AsArray unconditionally
                # adds one more array wrapper on top, double-nesting the result.
                $parameters.Body=ConvertTo-Json -InputObject $Body -Depth 30 -Compress
            } else {
                $parameters.Body=$Body|ConvertTo-Json -Depth 30 -Compress
            }
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

function Test-RAGSourcesAgainstSchema {
    # Validates each entry of sources.json against the published
    # Contracts/source.schema.json via the built-in Test-Json cmdlet --
    # no parallel, hand-written field-validation logic is maintained here.
    # The empty default allow-list (`"sources": []`) is valid: the loop
    # below simply does not execute.
    param(
        [Parameter(Mandatory)][object]$Sources,
        [Parameter(Mandatory)][string]$SchemaPath
    )
    if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) { throw "RAG-Quellenschema fehlt: $SchemaPath" }
    if ($null -eq $Sources -or $null -eq $Sources.PSObject.Properties['sources']) {
        throw "sources.json ist ungültig: das Pflichtfeld 'sources' fehlt."
    }
    # @($null) would yield a one-element array containing $null, not an
    # empty array, so an explicit null-check precedes the @() wrap; a
    # single-object JSON array is also normalized to a one-element array
    # here (ConvertFrom-Json would otherwise return it unwrapped).
    $list = if ($null -eq $Sources.sources) { @() } else { @($Sources.sources) }
    $index = 0
    foreach ($source in $list) {
        $label = if ($null -ne $source -and $null -ne $source.PSObject.Properties['source_id'] -and -not [string]::IsNullOrWhiteSpace([string]$source.source_id)) {
            [string]$source.source_id
        } else {
            "sources[$index]"
        }
        $itemJson = $source | ConvertTo-Json -Depth 20 -Compress
        try {
            $null = Test-Json -Json $itemJson -SchemaFile $SchemaPath -ErrorAction Stop
        } catch {
            throw "sources.json ist ungültig bei Quelle '$label': $($_.Exception.Message)"
        }
        $index++
    }
}

function Resolve-RAGLMStudioCli {
    # Mirrors the resolution order already used by the Applications
    # module's Start-KIStack-LMStudio.cmd starter (PATH, then the
    # per-user LM Studio install location) -- not a new mechanism.
    param([Parameter(Mandatory)][string]$TargetRoot)
    foreach ($name in @('lms.exe','lms.cmd')) {
        $found = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $found) { return $found.Source }
    }
    foreach ($name in @('lms.exe','lms.cmd')) {
        $candidate = Join-Path $env:USERPROFILE (".lmstudio/bin/$name")
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $null
}

function Test-RAGEmbeddingModelAvailable {
    param([Parameter(Mandatory)][string]$EmbeddingBaseUrl,[Parameter(Mandatory)][string]$EmbeddingModel)
    try {
        $models = Invoke-RestMethod -Uri ($EmbeddingBaseUrl.TrimEnd('/')+'/models') -Method GET -TimeoutSec 10
        $ids = @($models.data | ForEach-Object { [string]$_.id })
        $ids -contains $EmbeddingModel
    } catch { $false }
}

function Assert-RAGEmbeddingModelReady {
    # Execute-preflight: the embedding model previously had to be loaded
    # into LM Studio by hand, with no automation and no clear failure
    # message otherwise. This reuses the existing managed LM Studio
    # starter (server readiness) and the existing lms CLI contract (model
    # loading) -- no new LM Studio automation surface is introduced.
    param(
        [Parameter(Mandatory)][object]$Config,
        [int]$LoadWaitMaxAttempts = 15,
        [int]$LoadWaitIntervalSeconds = 2
    )
    if (Test-RAGEmbeddingModelAvailable -EmbeddingBaseUrl ([string]$Config.embeddingBaseUrl) -EmbeddingModel ([string]$Config.embeddingModel)) {
        return
    }
    $targetRoot = [string]$Config.targetRoot
    $lms = Resolve-RAGLMStudioCli -TargetRoot $targetRoot
    if (-not $lms) {
        $starter = Join-Path $targetRoot 'modules/applications/Start-KIStack-LMStudio.cmd'
        if (-not (Test-Path -LiteralPath $starter -PathType Leaf)) {
            throw "LM-Studio-Embedding-Modell ist nicht geladen und der verwaltete LM-Studio-Starter fehlt: $starter"
        }
        $null = Start-Process -FilePath $starter -Wait -PassThru -WindowStyle Hidden
        $lms = Resolve-RAGLMStudioCli -TargetRoot $targetRoot
    }
    if (-not $lms) {
        throw "LM-Studio-Embedding-Modell ist nicht geladen und die lms-CLI konnte nicht aufgelöst werden: $($Config.embeddingModel)"
    }
    $loadProcess = Start-Process -FilePath $lms -ArgumentList @('load', [string]$Config.embeddingModel, '-y') -Wait -PassThru -WindowStyle Hidden
    $ready = $false
    for ($attempt = 0; $attempt -lt $LoadWaitMaxAttempts; $attempt++) {
        if (Test-RAGEmbeddingModelAvailable -EmbeddingBaseUrl ([string]$Config.embeddingBaseUrl) -EmbeddingModel ([string]$Config.embeddingModel)) { $ready = $true; break }
        Start-Sleep -Seconds $LoadWaitIntervalSeconds
    }
    if (-not $ready) {
        throw "LM-Studio-Embedding-Modell konnte nicht bereitgestellt werden: $($Config.embeddingModel) (lms-load-Exitcode: $($loadProcess.ExitCode))"
    }
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
    # Get-RAGProperty's plain-value return collapses an empty-array
    # property value to $null (PowerShell's pipeline output unwraps a
    # zero-element array to nothing), which previously made a brand-new
    # OpenWebUI instance with zero existing Knowledge collections --
    # "items": [] -- fall through to the wrong branch below and crash.
    # Checked directly here instead, so existence (not value) decides.
    $itemsProperty=$response.PSObject.Properties['items']
    $items=@(if($null-ne$itemsProperty){$itemsProperty.Value}elseif($response-is[array]){$response}else{@($response)})
    $matches=@($items|Where-Object{[string]$_.name-eq[string]$Config.knowledgeName})
    if($matches.Count -gt 1){throw "Knowledge-Name ist nicht eindeutig: $($Config.knowledgeName)"}
    if($matches.Count -eq 1){return $matches[0]}
    if(-not$Create){return $null}
    Invoke-RAGApi $Config.openWebUIEndpoint $ApiToken '/api/v1/knowledge/create' POST ([ordered]@{
        name=[string]$Config.knowledgeName;description=[string]$Config.knowledgeDescription;access_grants=@()
    })
}

function Set-RAGEmbeddingContract {
    param([object]$Config,[Security.SecureString]$ApiToken,[string]$BackupPath)
    Assert-RAGEmbeddingModelReady -Config $Config
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
            $null=Invoke-RAGApi $Config.openWebUIEndpoint $ApiToken "/api/v1/knowledge/$KnowledgeId/files/batch/add" POST $forms -BodyIsArray
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

function Save-RAGStateCheckpoint {
    # Single checkpoint writer for state.json, reused after every
    # individually completed remote Add/Replace/Remove so a retry never
    # re-uploads an entry that already succeeded. Persistence itself stays
    # atomic via the existing Write-RAGJson temp-file+rename pattern -- no
    # new atomic-write mechanism is introduced.
    #
    # PendingRemovals: a Replace's superseded old remote entry, recorded
    # here from the moment its replacement's upload is confirmed until its
    # own removal is confirmed. Not a general rollback log -- just enough
    # to let a retry find and finish a Replace's cleanup half specifically,
    # without ever re-uploading the (already committed) new content.
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$KnowledgeId,
        [Parameter(Mandatory)][hashtable]$Entries,
        [object[]]$PendingRemovals=@()
    )
    $checkpoint=[ordered]@{
        schemaVersion='1.0';version=[string]$Config.version;knowledge_id=$KnowledgeId
        updated_at=[DateTime]::UtcNow.ToString('o');entries=@($Entries.Values|Sort-Object source_id,relative_path)
        pendingRemovals=@($PendingRemovals)
    }
    Write-RAGJson $StatePath $checkpoint
    $checkpoint
}

function Invoke-KIStackRAG {
    [CmdletBinding()]
    param(
        [ValidateSet('Audit','DryRun','Execute','Status','Rollback')][string]$Mode='Audit',
        [string]$PackageRoot=$PSScriptRoot,
        [string]$ConfigPath=(Join-Path $PSScriptRoot 'Config\rag.config.json'),
        [string]$SourcesPath=(Join-Path $PSScriptRoot 'Config\sources.json'),
        [string]$SourceSchemaPath=(Join-Path $PSScriptRoot 'Contracts\source.schema.json'),
        [Security.SecureString]$ApiToken
    )
    $config=Read-RAGJson $ConfigPath;$sources=Read-RAGJson $SourcesPath
    Test-RAGSourcesAgainstSchema -Sources $sources -SchemaPath $SourceSchemaPath
    $stateRoot=[string]$config.stateRoot;$statePath=Join-Path $stateRoot 'state.json'
    $state=if(Test-Path -LiteralPath $statePath){Read-RAGJson $statePath}else{$null}
    # Get-RAGInventory's own @(...)-wrapped internal return still collapses to
    # $null at this call site when zero files match (the last file of a
    # source was just removed) -- the same function-output array-collapse
    # class as Get-RAGProperty, hit here for the first time only because no
    # real run had ever driven a source down to zero files before. Wrapping
    # the call itself in @(...) guarantees $inventory stays a real array.
    $inventory=@(Get-RAGInventory $config $sources);$plan=Get-RAGPlan $inventory $state
    if($Mode-in@('Audit','DryRun','Status')){
        return [pscustomobject]@{
            mode=$Mode;version=[string]$config.version;sources=@($sources.sources).Count;files=$inventory.Count
            add=@($plan|Where-Object action -eq 'Add').Count;replace=@($plan|Where-Object action -eq 'Replace').Count
            remove=@($plan|Where-Object action -eq 'Remove').Count;skip=@($plan|Where-Object action -eq 'Skip').Count
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
    # Entries a prior Replace already committed the new content for, but
    # whose superseded old remote entry was not yet confirmed removed
    # (that removal failed, or the process stopped, before it committed).
    # Kept in state.json specifically so a retry can find and finish just
    # that cleanup -- see AP02.5.
    $pendingRemovals=@();if($null-ne$state-and$null-ne$state.PSObject.Properties['pendingRemovals']){$pendingRemovals=@($state.pendingRemovals)}
    try{
        foreach($pending in @($pendingRemovals)){
            Remove-RAGRemoteEntry $config $ApiToken ([string]$knowledge.id) $pending
            $pendingRemovals=@($pendingRemovals|Where-Object{[string]$_.removal_id -ne [string]$pending.removal_id})
            $null=Save-RAGStateCheckpoint -StatePath $statePath -Config $config -KnowledgeId ([string]$knowledge.id) -Entries $entries -PendingRemovals $pendingRemovals
        }
        foreach($action in @($plan|Where-Object {$_.action -in @('Add','Replace')})){
            # Commit point: the new remote content is confirmed to exist
            # (upload + batch-add both succeeded) the instant control
            # returns here, so the checkpoint is written before attempting
            # to remove the superseded old entry. A retry after this point
            # sees the new content as unchanged (Skip), never re-uploads
            # it -- regardless of whether the old-entry removal below still
            # succeeds. state.json therefore never points at remote
            # content that does not exist.
            $new=Add-RAGRemoteEntry $config $ApiToken ([string]$knowledge.id) $action.current $work
            $entries[[string]$new.key]=$new
            if($action.action-eq'Replace'){
                # The old entry is recorded as pending *before* the removal
                # attempt, in the same checkpoint as the new content, so a
                # failure right here still leaves state.json naming exactly
                # what still needs cleanup -- not silently forgotten.
                $removalId=[guid]::NewGuid().ToString()
                $pendingEntry=$action.previous|Select-Object *
                $pendingEntry|Add-Member -NotePropertyName removal_id -NotePropertyValue $removalId -Force
                $pendingRemovals=@($pendingRemovals)+$pendingEntry
                $null=Save-RAGStateCheckpoint -StatePath $statePath -Config $config -KnowledgeId ([string]$knowledge.id) -Entries $entries -PendingRemovals $pendingRemovals
                Remove-RAGRemoteEntry $config $ApiToken ([string]$knowledge.id) $action.previous
                $pendingRemovals=@($pendingRemovals|Where-Object{[string]$_.removal_id -ne $removalId})
            }
            $null=Save-RAGStateCheckpoint -StatePath $statePath -Config $config -KnowledgeId ([string]$knowledge.id) -Entries $entries -PendingRemovals $pendingRemovals
        }
        foreach($action in @($plan|Where-Object action -eq 'Remove')){
            # Commit point: only after the remote removal itself succeeds.
            # A failed removal leaves the entry -- and therefore the
            # previously written, still-accurate checkpoint -- untouched.
            Remove-RAGRemoteEntry $config $ApiToken ([string]$knowledge.id) $action.previous
            $entries.Remove([string]$action.previous.key)
            $null=Save-RAGStateCheckpoint -StatePath $statePath -Config $config -KnowledgeId ([string]$knowledge.id) -Entries $entries -PendingRemovals $pendingRemovals
        }
        [pscustomobject]@{mode='Execute';passed=$true;knowledge_id=[string]$knowledge.id;embeddingModel=[string]$embedding.RAG_EMBEDDING_MODEL;entries=$entries.Count;pendingRemovals=$pendingRemovals.Count;transaction=$transaction;apiKeyStored=$false}
    }catch{
        Write-RAGJson (Join-Path $transaction 'failure.json') ([ordered]@{failed_at=[DateTime]::UtcNow.ToString('o');message=[string]$_.Exception.Message;apiKeyStored=$false})
        throw
    }
}

Export-ModuleMember -Function Invoke-KIStackRAG,Get-RAGInventory,Get-RAGPlan,Split-RAGContent,Test-RAGSourcesAgainstSchema,Resolve-RAGLMStudioCli,Test-RAGEmbeddingModelAvailable,Assert-RAGEmbeddingModelReady,Save-RAGStateCheckpoint

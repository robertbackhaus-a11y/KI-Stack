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

function Test-RAGEmbeddingAlreadyAtTarget {
    # Only the non-sensitive fields RAG itself actually sets are compared --
    # never openai_config.key. If a real key happens to already be present
    # while everything else already matches the target, that is left alone:
    # idempotent means "do not touch anything that does not need to change."
    param([Parameter(Mandatory)][object]$Current,[Parameter(Mandatory)][object]$Config)
    [string]$Current.RAG_EMBEDDING_ENGINE -eq 'openai' -and
    [string]$Current.RAG_EMBEDDING_MODEL -eq [string]$Config.embeddingModel -and
    [int]$Current.RAG_EMBEDDING_BATCH_SIZE -eq 1 -and
    [bool]$Current.ENABLE_ASYNC_EMBEDDING -eq $true -and
    [int]$Current.RAG_EMBEDDING_CONCURRENT_REQUESTS -eq 1 -and
    [string]$Current.openai_config.url -eq [string]$Config.embeddingBaseUrl
}

function Get-RAGEmbeddingCredentialFieldsPresent {
    # Names only, never values -- OpenWebUI 0.11.0's GET /retrieval/embedding
    # always returns openai_config/ollama_config/azure_openai_config with a
    # key field (source-confirmed: routers/retrieval.py get_embedding_config),
    # so a present-but-unsaved key is exactly the case a blind restore must
    # never silently paper over with an empty string.
    param([Parameter(Mandatory)][object]$Current)
    $present=[Collections.Generic.List[string]]::new()
    if(-not[string]::IsNullOrEmpty([string]$Current.openai_config.key)){$present.Add('openai_config.key')}
    if(-not[string]::IsNullOrEmpty([string]$Current.ollama_config.key)){$present.Add('ollama_config.key')}
    if(-not[string]::IsNullOrEmpty([string]$Current.azure_openai_config.key)){$present.Add('azure_openai_config.key')}
    @($present)
}

function Test-RAGEmbeddingRestoreSafe {
    # A backup is safely, automatically restorable only when RAG actually
    # changed something (mutationPerformed) and the captured prior state had
    # no credential field RAG could not save. Restoring a state that HAD a
    # real key, using key='' because the real value was never stored, would
    # silently produce a broken, non-functional config while looking like a
    # successful restore -- worse than leaving RAG's own working config in
    # place and flagging it for a human.
    param([AllowNull()][object]$Backup)
    $null-ne$Backup -and [bool]$Backup.mutationPerformed -and @($Backup.credentialFieldsPresent).Count -eq 0
}

function Test-RAGEmbeddingMatchesBackup {
    # Idempotency for the restore direction, mirroring
    # Test-RAGEmbeddingAlreadyAtTarget: if the live config already matches
    # the backed-up prior state (e.g. a previous restore already ran), a
    # second restore attempt is a clean no-op rather than a redundant POST.
    param([Parameter(Mandatory)][object]$Current,[Parameter(Mandatory)][object]$PriorState)
    [string]$Current.RAG_EMBEDDING_ENGINE -eq [string]$PriorState.RAG_EMBEDDING_ENGINE -and
    [string]$Current.RAG_EMBEDDING_MODEL -eq [string]$PriorState.RAG_EMBEDDING_MODEL -and
    [string]$Current.openai_config.url -eq [string]$PriorState.openai_url
}

function Restore-RAGEmbeddingContract {
    # Only ever called after Test-RAGEmbeddingRestoreSafe confirmed the
    # backup's priorState carries no omitted credential value. ollama_config/
    # azure_openai_config are sent as null -- OpenWebUI's update handler
    # only touches those blocks when they are non-null (source-confirmed),
    # so this never overwrites those provider's stored keys either way.
    param([Parameter(Mandatory)][object]$Config,[Parameter(Mandatory)][Security.SecureString]$ApiToken,[Parameter(Mandatory)][object]$Backup)
    $prior=$Backup.priorState
    $body=[ordered]@{
        openai_config=[ordered]@{url=[string]$prior.openai_url;key=''}
        ollama_config=$null;azure_openai_config=$null
        RAG_EMBEDDING_ENGINE=[string]$prior.RAG_EMBEDDING_ENGINE;RAG_EMBEDDING_MODEL=[string]$prior.RAG_EMBEDDING_MODEL
        RAG_EMBEDDING_BATCH_SIZE=$prior.RAG_EMBEDDING_BATCH_SIZE;ENABLE_ASYNC_EMBEDDING=$prior.ENABLE_ASYNC_EMBEDDING
        RAG_EMBEDDING_CONCURRENT_REQUESTS=$prior.RAG_EMBEDDING_CONCURRENT_REQUESTS
    }
    $null=Invoke-RAGApi $Config.openWebUIEndpoint $ApiToken '/api/v1/retrieval/embedding/update' POST $body
}

function Resolve-RAGEmbeddingRestoreOutcome {
    # Shared by Execute's failure path and Rollback's success path (AP07,
    # point 5: "gleiche Regel") so the safe/manual-action decision is made
    # exactly once, the same way, everywhere a prior embedding mutation
    # might need undoing. Returns one of: NoMutation, AlreadyRestored,
    # Restored, EmbeddingRestoreRequiresManualAction. Never throws for the
    # unsafe case -- that is the expected, correct outcome, not an error.
    param([Parameter(Mandatory)][object]$Config,[Parameter(Mandatory)][Security.SecureString]$ApiToken,[Parameter(Mandatory)][string]$BackupPath)
    if(-not(Test-Path -LiteralPath $BackupPath)){return [pscustomobject]@{status='NoMutation';previousEngine=$null;previousModel=$null}}
    $backup=Read-RAGJson $BackupPath
    if(-not[bool]$backup.mutationPerformed){return [pscustomobject]@{status='NoMutation';previousEngine=$null;previousModel=$null}}
    $previousEngine=[string]$backup.priorState.RAG_EMBEDDING_ENGINE
    $previousModel=[string]$backup.priorState.RAG_EMBEDDING_MODEL
    $current=Invoke-RAGApi $Config.openWebUIEndpoint $ApiToken '/api/v1/retrieval/embedding'
    if(Test-RAGEmbeddingMatchesBackup -Current $current -PriorState $backup.priorState){
        return [pscustomobject]@{status='AlreadyRestored';previousEngine=$previousEngine;previousModel=$previousModel}
    }
    if(Test-RAGEmbeddingRestoreSafe -Backup $backup){
        Restore-RAGEmbeddingContract -Config $Config -ApiToken $ApiToken -Backup $backup
        return [pscustomobject]@{status='Restored';previousEngine=$previousEngine;previousModel=$previousModel}
    }
    [pscustomobject]@{status='EmbeddingRestoreRequiresManualAction';previousEngine=$previousEngine;previousModel=$previousModel}
}

function Set-RAGEmbeddingContract {
    # Idempotent: a POST to the real, global-only OpenWebUI embedding
    # config (see README -- OpenWebUI 0.11.0 has no collection/knowledge-
    # scoped embedding contract at all) only happens when the current state
    # genuinely differs from RAG's target. Every mutation is preceded by a
    # full non-sensitive backup naming exactly which credential fields (not
    # values) were present, so a later failure or Rollback can tell a safe
    # full restore apart from one that would silently destroy a real key.
    param([Parameter(Mandatory)][object]$Config,[Parameter(Mandatory)][Security.SecureString]$ApiToken,[Parameter(Mandatory)][string]$BackupPath)
    Assert-RAGEmbeddingModelReady -Config $Config
    $current=Invoke-RAGApi $Config.openWebUIEndpoint $ApiToken '/api/v1/retrieval/embedding'
    $alreadyAtTarget=Test-RAGEmbeddingAlreadyAtTarget -Current $current -Config $Config
    $credentialFieldsPresent=@(Get-RAGEmbeddingCredentialFieldsPresent -Current $current)
    $safeBackup=[ordered]@{
        schemaVersion='1.0';captured_at=[DateTime]::UtcNow.ToString('o')
        mutationPerformed=(-not$alreadyAtTarget)
        credentialsOmitted=$true;credentialFieldsPresent=@($credentialFieldsPresent)
        priorState=[ordered]@{
            RAG_EMBEDDING_ENGINE=[string]$current.RAG_EMBEDDING_ENGINE
            RAG_EMBEDDING_MODEL=[string]$current.RAG_EMBEDDING_MODEL
            RAG_EMBEDDING_BATCH_SIZE=$current.RAG_EMBEDDING_BATCH_SIZE
            ENABLE_ASYNC_EMBEDDING=$current.ENABLE_ASYNC_EMBEDDING
            RAG_EMBEDDING_CONCURRENT_REQUESTS=$current.RAG_EMBEDDING_CONCURRENT_REQUESTS
            openai_url=[string]$current.openai_config.url
        }
    }
    Write-RAGJson $BackupPath $safeBackup
    if($alreadyAtTarget){return $current}
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

function Publish-RAGPreparedChunks {
    # Uploads a list of already-prepared local chunk files (path/name/
    # metadata/index -- the exact shape New-RAGChunks produces) and
    # batch-adds them to the knowledge base. Extracted out of
    # Add-RAGRemoteEntry (pure refactor, identical behavior) so Rollback's
    # restore path can reuse the same upload/batch-add/partial-failure
    # logic against archived chunk files instead of freshly chunked ones,
    # without a second parallel implementation of that logic.
    param([object]$Config,[Security.SecureString]$ApiToken,[string]$KnowledgeId,[object]$Entry,[object[]]$Chunks)
    $uploaded=[Collections.Generic.List[object]]::new()
    try{
        foreach($chunk in $Chunks){
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

function Add-RAGRemoteEntry {
    param([object]$Config,[Security.SecureString]$ApiToken,[string]$KnowledgeId,[object]$Entry,[string]$WorkDirectory)
    $chunks=New-RAGChunks $Entry $Config $WorkDirectory ([DateTime]::UtcNow.ToString('o'))
    Publish-RAGPreparedChunks $Config $ApiToken $KnowledgeId $Entry $chunks
}

function Save-RAGRollbackArchiveEntry {
    # Rollback-only: archives an entry's exact remote chunk content to local
    # disk BEFORE it is remotely deleted (Replace-cleanup or a genuine
    # Remove). Once AP02.5's normal cleanup deletes the old file_id, that
    # content is gone from OpenWebUI for good -- state.json only ever kept
    # metadata and remote-ID references, never the actual bytes. Fetching
    # via the real GET /api/v1/files/{id} content field (confirmed against
    # the live target during AP03) is the only reliable source left.
    # Archive scope is a single transaction; the caller is responsible for
    # clearing any prior transaction's archive before a new one starts.
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][Security.SecureString]$ApiToken,
        [Parameter(Mandatory)][string]$ArchiveRoot,
        [Parameter(Mandatory)][object]$Entry
    )
    $entryArchiveDir=Join-Path $ArchiveRoot ([string]$Entry.key)
    $null=New-Item -ItemType Directory -Path $entryArchiveDir -Force
    $archivedChunks=[Collections.Generic.List[object]]::new()
    foreach($chunk in @($Entry.chunks)){
        $remote=Invoke-RAGApi $Config.openWebUIEndpoint $ApiToken "/api/v1/files/$([string]$chunk.file_id)" GET
        $content=[string]$remote.data.content
        if([string]::IsNullOrEmpty($content)){
            throw "Rollback-Archivierung fehlgeschlagen: kein Inhalt für Datei $([string]$chunk.file_id) (Chunk $([string]$chunk.name))."
        }
        $archivePath=Join-Path $entryArchiveDir ([string]$chunk.name)
        Set-Content -LiteralPath $archivePath -Value $content -Encoding utf8NoBOM
        $archivedChunks.Add([pscustomobject]@{chunk_index=$chunk.chunk_index;name=[string]$chunk.name;archive_path=$archivePath})
    }
    [pscustomobject]@{key=[string]$Entry.key;previous_entry=$Entry;archived_chunks=@($archivedChunks)}
}

function ConvertFrom-RAGChunkHeader {
    # Rollback-only: parses the "---\n<compact-json-metadata>\n---\n\n"
    # header this module itself writes at upload time (see New-RAGChunks)
    # back into a metadata object. state.json's own entry schema does not
    # retain per-chunk fields like section/parser_version/imported_at, so
    # re-deriving them from the archived content's own embedded header --
    # exactly what was originally uploaded -- is more faithful than
    # reconstructing an approximation from partial state.json fields.
    param([Parameter(Mandatory)][string]$Content)
    if($Content -notmatch '^---\n(?<meta>[^\n]*)\n---\n\n'){
        throw 'Archivierter Chunk-Inhalt enthält keinen gültigen Metadaten-Header.'
    }
    $Matches.meta|ConvertFrom-Json -Depth 20
}

function Restore-RAGArchivedEntry {
    # Rollback-only: re-uploads archived chunk content as fresh remote
    # files and batch-adds them back to the knowledge base. The original
    # file_id is never reused (it was deleted by the transaction being
    # rolled back) -- restoration produces new file_ids for byte-identical
    # content, which is what "vorherigen Zustand wiederherstellen" can
    # actually mean once the original remote object is gone.
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][Security.SecureString]$ApiToken,
        [Parameter(Mandatory)][string]$KnowledgeId,
        [Parameter(Mandatory)][object]$Archived
    )
    $chunkFiles=@(@($Archived.archived_chunks)|Sort-Object chunk_index|ForEach-Object{
        $content=Get-Content -LiteralPath ([string]$_.archive_path) -Raw -Encoding UTF8
        $metadata=ConvertFrom-RAGChunkHeader -Content $content
        [pscustomobject]@{path=[string]$_.archive_path;name=[string]$_.name;metadata=$metadata;index=[int]$_.chunk_index}
    })
    Publish-RAGPreparedChunks $Config $ApiToken $KnowledgeId $Archived.previous_entry $chunkFiles
}

function Get-RAGPendingRemovals {
    # Single place that reads pendingRemovals off a parsed state.json object
    # (or absent state), reused by Execute, DryRun and Status alike -- was
    # previously duplicated inline in Execute only, before DryRun/Status
    # needed the same value.
    param([AllowNull()][object]$State)
    if($null-eq$State -or $null-eq$State.PSObject.Properties['pendingRemovals']){return @()}
    @($State.pendingRemovals)
}

function Test-RAGConfigFieldsPresent {
    # Audit-only: names the rag.config.json fields the module's own code
    # actually dereferences elsewhere (Invoke-RAGApi calls, chunking,
    # embedding preflight, state paths -- grepped, not guessed) that are
    # missing or blank. There is no dedicated schema for rag.config.json
    # (unlike sources.json/source.schema.json), so this is a minimal
    # presence check, not formal validation.
    param([Parameter(Mandatory)][object]$Config)
    $required=@(
        'stateRoot','embeddingBaseUrl','embeddingModel','openWebUIEndpoint',
        'knowledgeName','knowledgeDescription','chunkCharacters','chunkOverlapCharacters',
        'parserVersion','allowedExtensions','excludedDirectoryNames','version'
    )
    @($required|Where-Object{
        $property=$Config.PSObject.Properties[$_]
        $null-eq$property -or $null-eq$property.Value -or ($property.Value -is [string] -and [string]::IsNullOrWhiteSpace($property.Value))
    })
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
    if($Mode-eq'Audit'){
        # Read-only local contract/config capability check -- never a
        # preview of what Execute would do (that's DryRun) and never a
        # remote call (sources.json schema already validated above;
        # Get-RAGInventory below both proves every configured source root
        # exists/is readable and throws its own clear message otherwise,
        # so there is no separate try/catch translation layer here to
        # duplicate that message). No new remote reachability check is
        # introduced: the prior unified Audit/DryRun/Status branch never
        # made one either.
        $inventory=@(Get-RAGInventory $config $sources)
        $missingConfigFields=@(Test-RAGConfigFieldsPresent -Config $config)
        return [pscustomobject]@{
            mode='Audit';version=[string]$config.version
            sourcesSchemaValid=$true;sources=@($sources.sources).Count;sourcesReachable=$true;files=$inventory.Count
            statePresent=($null-ne$state);stateReadable=$true
            configComplete=(@($missingConfigFields).Count-eq0);missingConfigFields=@($missingConfigFields)
            mutatesTarget=$false
        }
    }
    if($Mode-eq'DryRun'){
        # Read-only preview of exactly what the next Execute would do --
        # the same inventory/plan machinery Execute itself uses below, only
        # ever read here, never acted on.
        $inventory=@(Get-RAGInventory $config $sources)
        $plan=Get-RAGPlan $inventory $state
        $pendingRemovals=@(Get-RAGPendingRemovals -State $state)
        return [pscustomobject]@{
            mode='DryRun';version=[string]$config.version;sources=@($sources.sources).Count;files=$inventory.Count
            add=@($plan|Where-Object action -eq 'Add').Count;replace=@($plan|Where-Object action -eq 'Replace').Count
            remove=@($plan|Where-Object action -eq 'Remove').Count;skip=@($plan|Where-Object action -eq 'Skip').Count
            pendingRemovals=@($pendingRemovals).Count
            statePresent=($null-ne$state);mutatesTarget=$false
        }
    }
    if($Mode-eq'Status'){
        # Reports exactly what is persisted on local disk in state.json and
        # rollback-archive.json -- deliberately never touches the local
        # source inventory or builds an Execute delta plan (Status is not a
        # preview), and makes no OpenWebUI call at all. remoteReadbackPerformed
        # is always false here so this can never be mistaken for a live
        # remote query of the actual knowledge base contents.
        $pendingRemovals=@(Get-RAGPendingRemovals -State $state)
        $entries=@()
        if($null-ne$state){
            $entries=@(@($state.entries)|ForEach-Object{
                [pscustomobject]@{
                    key=[string]$_.key;source_id=[string]$_.source_id;relative_path=[string]$_.relative_path
                    file_sha256=[string]$_.file_sha256;chunks=@($_.chunks).Count
                }
            })
        }
        $rollbackManifestPath=Join-Path $stateRoot 'rollback-archive.json'
        $rollbackArchive=$null
        if(Test-Path -LiteralPath $rollbackManifestPath){
            $manifest=Read-RAGJson $rollbackManifestPath
            $rollbackArchive=[pscustomobject]@{
                transaction=[string]$manifest.transaction;createdAt=[string]$manifest.created_at
                added=@($manifest.added).Count;replaced=@($manifest.replaced).Count;removed=@($manifest.removed).Count
                rolledBackAt=$(if($manifest.PSObject.Properties['rolledBackAt']){[string]$manifest.rolledBackAt}else{$null})
            }
        }
        return [pscustomobject]@{
            mode='Status';version=[string]$config.version;statePresent=($null-ne$state)
            knowledgeId=$(if($null-ne$state){[string]$state.knowledge_id}else{$null})
            lastUpdatedAt=$(if($null-ne$state){[string]$state.updated_at}else{$null})
            entries=@($entries);entryCount=@($entries).Count;pendingRemovals=@($pendingRemovals).Count
            rollbackArchivePresent=($null-ne$rollbackArchive);rollbackArchive=$rollbackArchive
            remoteReadbackPerformed=$false;mutatesTarget=$false
        }
    }
    if($null-eq$ApiToken){throw 'ApiToken ist für Execute und Rollback erforderlich.'}
    # Get-RAGInventory's own @(...)-wrapped internal return still collapses to
    # $null at this call site when zero files match (the last file of a
    # source was just removed) -- the same function-output array-collapse
    # class as Get-RAGProperty, hit here for the first time only because no
    # real run had ever driven a source down to zero files before. Wrapping
    # the call itself in @(...) guarantees $inventory stays a real array.
    #
    # Rollback does not use $inventory/$plan at all (it is driven entirely
    # by rollback-archive.json against the current state, never by the
    # local file inventory) -- computed unconditionally here anyway only
    # because that already was Rollback's existing, unchanged behavior.
    $inventory=@(Get-RAGInventory $config $sources);$plan=Get-RAGPlan $inventory $state
    if($Mode-eq'Rollback'){
        # Scope: only the remote changes made by the single most recent
        # Execute transaction, driven entirely by rollback-archive.json --
        # never by re-deriving intent from the current local file inventory
        # or from sources.json. Execute clears this manifest at the start of
        # every new transaction (see below), so it can only ever describe
        # the last Execute run; a stale or missing manifest means there is
        # nothing this module can safely roll back, not something to guess.
        $rollbackManifestPath=Join-Path $stateRoot 'rollback-archive.json'
        if(-not(Test-Path -LiteralPath $rollbackManifestPath)){throw 'Kein Rollback-Nachweis für die letzte Execute-Transaktion vorhanden.'}
        if($null-eq$state){throw 'Kein State vorhanden, gegen den ein Rollback ausgeführt werden könnte.'}
        $manifest=Read-RAGJson $rollbackManifestPath
        if([string]$manifest.knowledge_id-ne[string]$state.knowledge_id){
            throw 'Rollback-Nachweis gehört nicht zum aktuellen State (abweichende knowledge_id) -- Rollback abgebrochen.'
        }
        $knowledgeId=[string]$state.knowledge_id
        $entries=@{};foreach($entry in @($state.entries)){$entries[[string]$entry.key]=$entry}
        $pendingRemovals=@(Get-RAGPendingRemovals -State $state)
        $rolledBack=[Collections.Generic.List[string]]::new()
        $alreadyClean=[Collections.Generic.List[string]]::new()
        try{
            # Add-rollback: delete what this transaction newly created. If
            # the key is already gone from entries.json -- a prior, partial
            # Rollback attempt already removed it -- that is a clean no-op,
            # not an error: idempotency comes from checking current state
            # before acting, never from assuming the manifest is fresh.
            foreach($key in @($manifest.added)){
                $key=[string]$key
                if(-not$entries.ContainsKey($key)){$alreadyClean.Add($key);continue}
                Remove-RAGRemoteEntry $config $ApiToken $knowledgeId $entries[$key]
                $entries.Remove($key)
                $rolledBack.Add($key)
                $null=Save-RAGStateCheckpoint -StatePath $statePath -Config $config -KnowledgeId $knowledgeId -Entries $entries -PendingRemovals $pendingRemovals
            }
            # Replace-rollback: remove the new content this transaction
            # uploaded, then re-upload the archived old content. The old
            # entry's original file_id is gone by design (AP02.5 cleanup) --
            # restoration always produces a fresh file_id for byte-identical
            # content, which is what "restore" can mean once the original
            # remote object no longer exists.
            foreach($archived in @($manifest.replaced)){
                $key=[string]$archived.key
                $currentEntry=if($entries.ContainsKey($key)){$entries[$key]}else{$null}
                if($null-ne$currentEntry -and [string]$currentEntry.file_sha256-eq[string]$archived.previous_entry.file_sha256){
                    $alreadyClean.Add($key);continue
                }
                if($null-ne$currentEntry){Remove-RAGRemoteEntry $config $ApiToken $knowledgeId $currentEntry}
                $entries[$key]=Restore-RAGArchivedEntry $config $ApiToken $knowledgeId $archived
                $rolledBack.Add($key)
                $null=Save-RAGStateCheckpoint -StatePath $statePath -Config $config -KnowledgeId $knowledgeId -Entries $entries -PendingRemovals $pendingRemovals
            }
            # Remove-rollback: re-upload the archived content this
            # transaction deleted. If the key is already present again --
            # a prior partial Rollback attempt already restored it -- skip.
            foreach($archived in @($manifest.removed)){
                $key=[string]$archived.key
                if($entries.ContainsKey($key)){$alreadyClean.Add($key);continue}
                $entries[$key]=Restore-RAGArchivedEntry $config $ApiToken $knowledgeId $archived
                $rolledBack.Add($key)
                $null=Save-RAGStateCheckpoint -StatePath $statePath -Config $config -KnowledgeId $knowledgeId -Entries $entries -PendingRemovals $pendingRemovals
            }
            # AP07, point 5: a successful Rollback of the file-level changes
            # follows the same safe/manual-action rule as Execute's failure
            # path for the embedding config that transaction's Set-RAG-
            # EmbeddingContract call may have mutated. This is a genuine,
            # deliberately requested scope addition to Rollback (it never
            # touched embedding before AP07) -- file rollback still counts
            # as passed regardless of the embedding outcome; a manual-action
            # result is reported, never silently dropped, never destructive.
            $embeddingOutcome=Resolve-RAGEmbeddingRestoreOutcome -Config $config -ApiToken $ApiToken -BackupPath (Join-Path ([string]$manifest.transaction) 'embedding-before.json')
            $manifest=[ordered]@{
                schemaVersion=[string]$manifest.schemaVersion;transaction=[string]$manifest.transaction
                knowledge_id=[string]$manifest.knowledge_id;created_at=[string]$manifest.created_at
                added=@($manifest.added);replaced=@($manifest.replaced);removed=@($manifest.removed)
                rolledBackAt=[DateTime]::UtcNow.ToString('o')
            }
            Write-RAGJson $rollbackManifestPath $manifest
            return [pscustomobject]@{
                mode='Rollback';passed=$true;knowledge_id=$knowledgeId;rolledBack=@($rolledBack);alreadyClean=@($alreadyClean);entries=$entries.Count
                embeddingRestoreStatus=$embeddingOutcome.status;embeddingPreviousEngine=$embeddingOutcome.previousEngine;embeddingPreviousModel=$embeddingOutcome.previousModel
            }
        }catch{
            Write-RAGJson (Join-Path $stateRoot ('rollback-failure-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'.json')) ([ordered]@{failed_at=[DateTime]::UtcNow.ToString('o');message=[string]$_.Exception.Message;rolledBackSoFar=@($rolledBack)})
            throw
        }
    }
    $knowledge=Get-RAGKnowledge $config $ApiToken -Create
    $transaction=Join-Path $stateRoot ('transactions\'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    $work=Join-Path $transaction 'chunks';$null=New-Item -ItemType Directory -Path $work -Force
    $embedding=Set-RAGEmbeddingContract $config $ApiToken (Join-Path $transaction 'embedding-before.json')
    if($null-ne$state){Write-RAGJson (Join-Path $stateRoot 'previous-state.json') $state}
    # Rollback scope: only the transaction about to run. Any archive left
    # over from an earlier transaction no longer represents "the last
    # Execute run" once a new one starts, so it is cleared up front. A
    # crash between this point and the manifest being written at the end
    # leaves no rollback-archive.json at all for this attempt -- Rollback
    # then correctly reports nothing to roll back, rather than silently
    # replaying a stale, already-superseded manifest.
    $rollbackManifestPath=Join-Path $stateRoot 'rollback-archive.json'
    $rollbackArchiveRoot=Join-Path $stateRoot 'rollback-archive'
    if(Test-Path -LiteralPath $rollbackManifestPath){Remove-Item -LiteralPath $rollbackManifestPath -Force}
    if(Test-Path -LiteralPath $rollbackArchiveRoot){Remove-Item -LiteralPath $rollbackArchiveRoot -Recurse -Force}
    $null=New-Item -ItemType Directory -Path $rollbackArchiveRoot -Force
    $rollbackAdded=[Collections.Generic.List[string]]::new()
    $rollbackReplaced=[Collections.Generic.List[object]]::new()
    $rollbackRemoved=[Collections.Generic.List[object]]::new()
    $entries=@{};if($null-ne$state){foreach($entry in @($state.entries)){$entries[[string]$entry.key]=$entry}}
    # Entries a prior Replace already committed the new content for, but
    # whose superseded old remote entry was not yet confirmed removed
    # (that removal failed, or the process stopped, before it committed).
    # Kept in state.json specifically so a retry can find and finish just
    # that cleanup -- see AP02.5.
    $pendingRemovals=@(Get-RAGPendingRemovals -State $state)
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
                # Archived *before* the old entry is touched at all, so the
                # exact pre-Replace remote content is captured while it is
                # still guaranteed to exist -- Rollback can restore it later
                # even after AP02.5's normal cleanup deletes the original.
                $rollbackReplaced.Add((Save-RAGRollbackArchiveEntry $config $ApiToken $rollbackArchiveRoot $action.previous))
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
            } else {
                $rollbackAdded.Add([string]$new.key)
            }
            $null=Save-RAGStateCheckpoint -StatePath $statePath -Config $config -KnowledgeId ([string]$knowledge.id) -Entries $entries -PendingRemovals $pendingRemovals
        }
        foreach($action in @($plan|Where-Object action -eq 'Remove')){
            # Archived before the remote removal, for the same reason as
            # the Replace case above -- once removed, the content is gone.
            $rollbackRemoved.Add((Save-RAGRollbackArchiveEntry $config $ApiToken $rollbackArchiveRoot $action.previous))
            # Commit point: only after the remote removal itself succeeds.
            # A failed removal leaves the entry -- and therefore the
            # previously written, still-accurate checkpoint -- untouched.
            Remove-RAGRemoteEntry $config $ApiToken ([string]$knowledge.id) $action.previous
            $entries.Remove([string]$action.previous.key)
            $null=Save-RAGStateCheckpoint -StatePath $statePath -Config $config -KnowledgeId ([string]$knowledge.id) -Entries $entries -PendingRemovals $pendingRemovals
        }
        $rollbackManifest=[ordered]@{
            schemaVersion='1.0';transaction=$transaction;knowledge_id=[string]$knowledge.id
            created_at=[DateTime]::UtcNow.ToString('o')
            added=@($rollbackAdded);replaced=@($rollbackReplaced);removed=@($rollbackRemoved)
        }
        Write-RAGJson $rollbackManifestPath $rollbackManifest
        [pscustomobject]@{mode='Execute';passed=$true;knowledge_id=[string]$knowledge.id;embeddingModel=[string]$embedding.RAG_EMBEDDING_MODEL;entries=$entries.Count;pendingRemovals=$pendingRemovals.Count;transaction=$transaction;apiKeyStored=$false}
    }catch{
        $originalError=$_
        $failureRecord=[ordered]@{failed_at=[DateTime]::UtcNow.ToString('o');message=[string]$originalError.Exception.Message;apiKeyStored=$false}
        # AP07, point 4: if Set-RAGEmbeddingContract mutated the global
        # embedding config earlier in this same transaction and Execute then
        # failed for any other reason, only auto-restore when the prior
        # state is fully reconstructable without an omitted credential;
        # otherwise a manual-action status is recorded (previous engine/
        # model only, never a secret value). A failure inside this recovery
        # step itself must never replace or hide the original error.
        try{
            $embeddingOutcome=Resolve-RAGEmbeddingRestoreOutcome -Config $config -ApiToken $ApiToken -BackupPath (Join-Path $transaction 'embedding-before.json')
            $failureRecord['embeddingRestoreStatus']=$embeddingOutcome.status
            $failureRecord['embeddingPreviousEngine']=$embeddingOutcome.previousEngine
            $failureRecord['embeddingPreviousModel']=$embeddingOutcome.previousModel
        }catch{
            $failureRecord['embeddingRestoreStatus']='RestoreAttemptFailed'
            $failureRecord['embeddingRestoreError']=[string]$_.Exception.Message
        }
        Write-RAGJson (Join-Path $transaction 'failure.json') $failureRecord
        throw $originalError
    }
}

Export-ModuleMember -Function Invoke-KIStackRAG,Get-RAGInventory,Get-RAGPlan,Split-RAGContent,Test-RAGSourcesAgainstSchema,Resolve-RAGLMStudioCli,Test-RAGEmbeddingModelAvailable,Assert-RAGEmbeddingModelReady,Save-RAGStateCheckpoint

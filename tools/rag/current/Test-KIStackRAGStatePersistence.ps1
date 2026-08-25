[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$failures=[Collections.Generic.List[string]]::new()

# Regression suite for KI-Stack Complete Installer 2.5.0 RAG AP02:
# transaction-safe state.json persistence / retry without duplicates.
#
# Drives the real Invoke-KIStackRAG -Mode Execute path (chunking, upload,
# batch-add, remove -- nothing mocked on the RAG side) against a small,
# purpose-built HTTP mock of the OpenWebUI + LM Studio endpoints it calls,
# over real loopback sockets. Only the remote backend is a fixture; the
# module logic under test runs unmodified.

Import-Module (Join-Path $PackageRoot 'KIStackRAG.psm1') -Force -DisableNameChecking

$knowledgeId='fixture-kb'
$embeddingModel='text-embedding-nomic-embed-text-v1.5'

# Raw TcpListener HTTP mock (not HttpListener: avoids http.sys URL-ACL
# requirements for a non-admin test process). Routes just enough of the
# OpenWebUI + LM Studio contract for a full Execute run: knowledge
# lookup/create, embedding readback/update, LM Studio /models, file
# upload (+ induced failure by ordinal), batch-add, file removal (+
# induced failure via marker file), and the cleanup DELETE that
# Add-RAGRemoteEntry issues for chunks already uploaded when a later
# chunk in the same entry fails.
$mockServerScriptContent=@'
param([int]$Port,[int]$RequestCount,[string]$StateDir,[string]$KnowledgeId,[string]$EmbeddingModel,[int]$FailOnUploadNumber=-1,[int]$FailOnRemoveNumber=-1,[string]$InitialEmbeddingEngine='openai',[string]$InitialEmbeddingModel=$EmbeddingModel,[string]$InitialEmbeddingUrl='fixture',[string]$InitialOpenAIKey='')
Set-StrictMode -Version Latest
# $uploadCounter stays process-local and always starts at 0, exactly as
# before -FailOnUploadNumber compares against it to fail the Nth upload of
# *this* mock invocation, and existing scenarios (1, 3, 7) depend on that
# being invocation-relative, not cumulative across restarts.
#
# $globalFileCounter is a separate, disk-persisted counter used only to
# assign globally unique file ids. Each Execute/Rollback call in a
# multi-call scenario stops this mock process and starts a fresh one, so
# both this counter and the content it hands out on GET /api/v1/files/{id}
# (AP05 Rollback archival) must survive process restarts within the same
# fixture -- an in-memory-only, per-process-reset store would 404 on any
# file uploaded by an earlier call, and reusing $uploadCounter for both
# purposes was tried and broke -FailOnUploadNumber for every scenario with
# more than one Execute call.
$uploadCounter=0
$removeCounter=0
$mockCounterPath=Join-Path $StateDir 'mock-upload-counter.txt'
$mockContentsPath=Join-Path $StateDir 'mock-file-contents.json'
$globalFileCounter=if(Test-Path -LiteralPath $mockCounterPath){[int](Get-Content -LiteralPath $mockCounterPath -Raw)}else{0}
$fileContents=@{}
if(Test-Path -LiteralPath $mockContentsPath){
    # This mock process is launched as Windows PowerShell 5.1 (see
    # Start-RAGMockOpenWebUIServer), whose ConvertFrom-Json has no -Depth
    # parameter at all (only added in PowerShell 6+) -- passing it here
    # crashed the mock at startup with a parameter-binding error, before
    # the TcpListener ever started, which the client only ever saw as a
    # generic connection failure on its next request.
    (Get-Content -LiteralPath $mockContentsPath -Raw|ConvertFrom-Json).PSObject.Properties|ForEach-Object{$fileContents[$_.Name]=[string]$_.Value}
}
function Save-MockUploadState {
    # This mock runs as Windows PowerShell 5.1 (see Start-RAGMockOpenWebUIServer),
    # whose Set-Content -Encoding enum has no "utf8NoBOM" value at all (that
    # name only exists in PowerShell 6+) -- it threw a ParameterBindingException
    # here on every upload, silently killing request handling (caught and
    # logged by the loop's own catch, but never reaching the client, which
    # only ever saw a generic connection failure). ConvertTo-Json's output is
    # pure ASCII (non-ASCII is \u-escaped), so plain ascii avoids the
    # cross-version encoding-name mismatch entirely instead of picking
    # another name that happens to exist on both.
    Set-Content -LiteralPath $mockCounterPath -Value $globalFileCounter -Encoding ascii
    ($fileContents|ConvertTo-Json -Depth 5)|Set-Content -LiteralPath $mockContentsPath -Encoding ascii
}

# --- Embedding config state (AP07) -- persisted for the same reason as
# above: it must survive this mock process being stopped and a fresh one
# started for a later Execute/Rollback call within the same fixture. Shape
# mirrors the real OpenWebUI GET /retrieval/embedding response exactly
# (routers/retrieval.py get_embedding_config, source-confirmed against the
# actually installed open_webui-0.11.0 package), including the per-provider
# key fields Get-RAGEmbeddingCredentialFieldsPresent must be able to read.
$mockEmbeddingStatePath=Join-Path $StateDir 'mock-embedding-state.json'
$mockEmbeddingUpdateCountPath=Join-Path $StateDir 'mock-embedding-update-count.txt'
if(Test-Path -LiteralPath $mockEmbeddingStatePath){
    $embeddingState=Get-Content -LiteralPath $mockEmbeddingStatePath -Raw|ConvertFrom-Json
} else {
    $embeddingState=[pscustomobject]@{
        RAG_EMBEDDING_ENGINE=$InitialEmbeddingEngine;RAG_EMBEDDING_MODEL=$InitialEmbeddingModel
        RAG_EMBEDDING_BATCH_SIZE=1;ENABLE_ASYNC_EMBEDDING=$true;RAG_EMBEDDING_CONCURRENT_REQUESTS=1
        openai_config=[pscustomobject]@{url=$InitialEmbeddingUrl;key=$InitialOpenAIKey}
        ollama_config=[pscustomobject]@{url='';key=''}
        azure_openai_config=[pscustomobject]@{url='';key='';version=''}
    }
}
$embeddingUpdateCount=if(Test-Path -LiteralPath $mockEmbeddingUpdateCountPath){[int](Get-Content -LiteralPath $mockEmbeddingUpdateCountPath -Raw)}else{0}
function Save-MockEmbeddingState {
    ($embeddingState|ConvertTo-Json -Depth 6)|Set-Content -LiteralPath $mockEmbeddingStatePath -Encoding ascii
    Set-Content -LiteralPath $mockEmbeddingUpdateCountPath -Value $embeddingUpdateCount -Encoding ascii
}
$tcp=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
$tcp.Start()

function Read-MockHttpRequest {
    param($Stream)
    $ms=[IO.MemoryStream]::new()
    $buf=New-Object byte[] 8192
    $headerText=$null
    while($null -eq $headerText){
        $n=$Stream.Read($buf,0,$buf.Length)
        if($n -le 0){break}
        $ms.Write($buf,0,$n)
        $textSoFar=[Text.Encoding]::ASCII.GetString($ms.ToArray())
        $idx=$textSoFar.IndexOf("`r`n`r`n")
        if($idx -ge 0){$headerText=$textSoFar.Substring(0,$idx)}
    }
    $allBytes=$ms.ToArray()
    $headerByteLen=[Text.Encoding]::ASCII.GetByteCount($headerText)+4
    $bodySoFar=$allBytes.Length-$headerByteLen
    $contentLength=0
    foreach($line in ($headerText -split "`r`n")){
        if($line -match '(?i)^Content-Length:\s*(\d+)'){$contentLength=[int]$Matches[1]}
    }
    $needMore=$contentLength-$bodySoFar
    while($needMore -gt 0){
        $n=$Stream.Read($buf,0,[Math]::Min($buf.Length,$needMore))
        if($n -le 0){break}
        $needMore-=$n
    }
    $requestLine=($headerText -split "`r`n")[0]
    $parts=$requestLine -split ' '
    $bodyText=if($allBytes.Length -gt $headerByteLen){[Text.Encoding]::UTF8.GetString($allBytes,$headerByteLen,$allBytes.Length-$headerByteLen)}else{''}
    [pscustomobject]@{Method=$parts[0];Path=$parts[1];Body=$bodyText}
}

function Read-MockUploadedFileContent {
    # Extracts the "file" part's raw content from a real multipart/form-data
    # body as PowerShell's own -Form parameter actually produces it
    # (confirmed against a real loopback capture): a Content-Disposition
    # line naming filename=..., then a Content-Type line, a blank line, the
    # raw content, then the closing boundary. Bounded, non-greedy match --
    # not a general MIME parser, just enough for this one, fixed shape.
    param([string]$Body)
    if($Body -match '(?s)Content-Disposition:\s*form-data;\s*name=file;[^\r\n]*\r\nContent-Type:[^\r\n]*\r\n\r\n(?<content>.*?)\r\n--'){
        return $Matches.content
    }
    $null
}

function Send-MockJsonResponse {
    param($Stream,[int]$StatusCode,[string]$Json)
    $statusText=if($StatusCode -eq 200){'OK'}else{'Error'}
    $bodyBytes=[Text.Encoding]::UTF8.GetBytes($Json)
    $header="HTTP/1.1 $StatusCode $statusText`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes=[Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes,0,$headerBytes.Length)
    $Stream.Write($bodyBytes,0,$bodyBytes.Length)
    $Stream.Flush()
}

for($i=0;$i -lt $RequestCount;$i++){
    $client=$tcp.AcceptTcpClient()
    $stream=$client.GetStream()
    try{
        $req=Read-MockHttpRequest -Stream $stream
        $path=$req.Path.Split('?')[0]
        if($req.Method -eq 'GET' -and $path -eq '/api/v1/knowledge/'){
            Send-MockJsonResponse $stream 200 '{"items":[]}'
        }
        elseif($req.Method -eq 'POST' -and $path -eq '/api/v1/knowledge/create'){
            Send-MockJsonResponse $stream 200 "{`"id`":`"$KnowledgeId`",`"name`":`"fixture`"}"
        }
        elseif($req.Method -eq 'GET' -and $path -eq '/v1/models'){
            Send-MockJsonResponse $stream 200 "{`"data`":[{`"id`":`"$EmbeddingModel`"}]}"
        }
        elseif($req.Method -eq 'GET' -and $path -eq '/api/v1/retrieval/embedding'){
            Send-MockJsonResponse $stream 200 ($embeddingState|ConvertTo-Json -Depth 6 -Compress)
        }
        elseif($req.Method -eq 'POST' -and $path -eq '/api/v1/retrieval/embedding/update'){
            $embeddingUpdateCount++
            $updateForm=$req.Body|ConvertFrom-Json
            $embeddingState.RAG_EMBEDDING_ENGINE=[string]$updateForm.RAG_EMBEDDING_ENGINE
            $embeddingState.RAG_EMBEDDING_MODEL=[string]$updateForm.RAG_EMBEDDING_MODEL
            $embeddingState.RAG_EMBEDDING_BATCH_SIZE=$updateForm.RAG_EMBEDDING_BATCH_SIZE
            $embeddingState.ENABLE_ASYNC_EMBEDDING=$updateForm.ENABLE_ASYNC_EMBEDDING
            $embeddingState.RAG_EMBEDDING_CONCURRENT_REQUESTS=$updateForm.RAG_EMBEDDING_CONCURRENT_REQUESTS
            # Mirrors the real update handler exactly: a provider block is
            # only touched when the request actually supplies it (source-
            # confirmed: "if form_data.X is not None"), so sending a null
            # ollama/azure block -- as Set-/Restore-RAGEmbeddingContract
            # always do -- leaves that provider's stored key untouched here
            # too, same as the real server.
            if($null-ne$updateForm.openai_config){
                $embeddingState.openai_config.url=[string]$updateForm.openai_config.url
                $embeddingState.openai_config.key=[string]$updateForm.openai_config.key
            }
            if($null-ne$updateForm.ollama_config){
                $embeddingState.ollama_config.url=[string]$updateForm.ollama_config.url
                $embeddingState.ollama_config.key=[string]$updateForm.ollama_config.key
            }
            if($null-ne$updateForm.azure_openai_config){
                $embeddingState.azure_openai_config.url=[string]$updateForm.azure_openai_config.url
                $embeddingState.azure_openai_config.key=[string]$updateForm.azure_openai_config.key
            }
            Save-MockEmbeddingState
            Send-MockJsonResponse $stream 200 ($embeddingState|ConvertTo-Json -Depth 6 -Compress)
        }
        elseif($req.Method -eq 'POST' -and $path -eq '/api/v1/files/'){
            $uploadCounter++
            if($uploadCounter -eq $FailOnUploadNumber){
                Send-MockJsonResponse $stream 500 '{"error":"fixture induced upload failure"}'
            } else {
                $globalFileCounter++
                $fileId="file-$globalFileCounter"
                $fileContents[$fileId]=Read-MockUploadedFileContent -Body $req.Body
                Save-MockUploadState
                Send-MockJsonResponse $stream 200 "{`"id`":`"$fileId`"}"
            }
        }
        elseif($req.Method -eq 'GET' -and $path -like '/api/v1/files/*'){
            $fileId=$path.Substring('/api/v1/files/'.Length)
            if($fileContents.ContainsKey($fileId)){
                $payload=@{data=@{content=$fileContents[$fileId]}}|ConvertTo-Json -Depth 5 -Compress
                Send-MockJsonResponse $stream 200 $payload
            } else {
                Send-MockJsonResponse $stream 404 '{"detail":"Not Found"}'
            }
        }
        elseif($req.Method -eq 'DELETE' -and $path -like '/api/v1/files/*'){
            Send-MockJsonResponse $stream 200 '{}'
        }
        elseif($req.Method -eq 'POST' -and $path -eq "/api/v1/knowledge/$KnowledgeId/files/batch/add"){
            # Mirrors OpenWebUI's real Pydantic contract: the body must be a
            # JSON array, even for exactly one entry. A prior version of this
            # mock accepted any body unconditionally and so could never have
            # caught the AP04 ConvertTo-Json single-element-array defect.
            # The check is on the raw wire text, not a deserialized object:
            # ConvertFrom-Json itself collapses a one-element JSON array back
            # into a scalar PSCustomObject, so it cannot tell "[{...}]" apart
            # from "{...}" either -- only the literal leading bracket can.
            $trimmedBody=$req.Body.TrimStart()
            $isValidList=$trimmedBody.StartsWith('[')
            if($isValidList){
                Send-MockJsonResponse $stream 200 '{}'
            } else {
                Send-MockJsonResponse $stream 422 '{"detail":[{"type":"list_type","loc":["body"],"msg":"Input should be a valid list"}]}'
            }
        }
        elseif($req.Method -eq 'POST' -and $path -eq "/api/v1/knowledge/$KnowledgeId/file/remove"){
            $removeCounter++
            if((Test-Path -LiteralPath (Join-Path $StateDir 'fail-remove.marker')) -or $removeCounter -eq $FailOnRemoveNumber){
                Send-MockJsonResponse $stream 500 '{"error":"fixture induced remove failure"}'
            } else {
                # Mirrors the real server: removing a file_id that is already
                # gone (Files.get_file_by_id returns nothing) is a real 400,
                # not a silent success -- source-confirmed against
                # routers/knowledge.py's remove_file_from_knowledge_by_id. A
                # retry that blindly re-issues this call for an entry whose
                # remote content a prior, partially-failed attempt already
                # deleted must therefore not rely on this route tolerating a
                # repeat; $fileContents (the same store the upload/GET/DELETE
                # routes already use) doubles as the "does this file_id still
                # exist" ledger here, so this stays a single source of truth.
                $removeFileId=[string]($req.Body|ConvertFrom-Json).file_id
                if(-not $fileContents.ContainsKey($removeFileId)){
                    Send-MockJsonResponse $stream 400 '{"detail":"Not Found"}'
                } else {
                    $fileContents.Remove($removeFileId)
                    Save-MockUploadState
                    Send-MockJsonResponse $stream 200 '{}'
                }
            }
        }
        else{
            Send-MockJsonResponse $stream 404 '{"error":"unmapped fixture route"}'
        }
    } catch {
        Add-Content -LiteralPath (Join-Path $StateDir 'mock-error.log') -Value "[$([DateTime]::UtcNow.ToString('o'))] $($_.Exception.GetType().FullName): $($_.Exception.Message)`n$($_.ScriptStackTrace)`n---`n" -Encoding utf8
    } finally { $client.Close() }
}
$tcp.Stop()
'@

function New-RAGExecuteFixture {
    param([int]$FileCount=3)
    $root=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-RAGExecute-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $sourceRoot=Join-Path $root 'sources'
    $stateRoot=Join-Path $root 'state'
    New-Item -ItemType Directory -Path $sourceRoot,$stateRoot -Force|Out-Null
    for($i=1;$i -le $FileCount;$i++){
        Set-Content -LiteralPath (Join-Path $sourceRoot "doc$i.md") -Value "# Document $i`n`nFixture content for document $i." -Encoding utf8NoBOM
    }
    $port=Get-Random -Minimum 36000 -Maximum 40000
    $mockScript=Join-Path $root 'mock-openwebui-server.ps1'
    Set-Content -LiteralPath $mockScript -Encoding utf8NoBOM -Value $mockServerScriptContent
    $configPath=Join-Path $root 'rag.config.json'
    $config=[ordered]@{
        schemaVersion='1.0';version='0.2.0';targetRoot=$root;moduleRoot=$root
        stateRoot=$stateRoot;sourceRoot=$sourceRoot
        embeddingProvider='lmstudio';embeddingBaseUrl="http://127.0.0.1:$port/v1";embeddingModel=$embeddingModel
        documentPrefix='search_document: ';queryPrefix='search_query: ';vectorStore='openwebui-managed'
        openWebUIEndpoint="http://127.0.0.1:$port";knowledgeName='Fixture Knowledge';knowledgeDescription='fixture'
        chunkCharacters=1000;chunkOverlapCharacters=100;parserVersion='fixture-1'
        allowedExtensions=@('.md');excludedDirectoryNames=@('node_modules')
        metadataFields=@('source_id','source_type','project','relative_path','file_name','file_sha256','document_version','section','chunk_index','imported_at','modified_at','content_language','visibility','parser_version')
    }
    ($config|ConvertTo-Json -Depth 10)|Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
    $sourcesPath=Join-Path $root 'sources.json'
    $sources=[ordered]@{schemaVersion='1.0';sources=@(@{source_id='fixture-src';source_type='directory';project='fixture';root=$sourceRoot;visibility='private';enabled=$true})}
    ($sources|ConvertTo-Json -Depth 10)|Set-Content -LiteralPath $sourcesPath -Encoding utf8NoBOM
    [pscustomobject]@{
        Root=$root;SourceRoot=$sourceRoot;StateRoot=$stateRoot;Port=$port;MockScript=$mockScript
        ConfigPath=$configPath;SourcesPath=$sourcesPath;StatePath=(Join-Path $stateRoot 'state.json')
    }
}

function Start-RAGMockOpenWebUIServer {
    param(
        [Parameter(Mandatory)]$Fixture,[int]$RequestCount=20,[int]$FailOnUploadNumber=-1,[int]$FailOnRemoveNumber=-1,
        [string]$InitialEmbeddingEngine='openai',[string]$InitialEmbeddingModel=$embeddingModel,
        [string]$InitialEmbeddingUrl='fixture',[string]$InitialOpenAIKey=''
    )
    # Start-Process -ArgumentList silently drops a bare empty-string array
    # element instead of passing it through as a genuine empty argument, so
    # the following -InitialOpenAIKey (empty by default) was swallowed and
    # its value bound to whatever followed -- confirmed via a minimal
    # isolated repro. A literal '""' is preserved correctly on the command
    # line and binds to an empty string in the child, exactly like passing
    # "" directly on a real command line would.
    $safeOpenAIKeyArg=if([string]::IsNullOrEmpty($InitialOpenAIKey)){'""'}else{$InitialOpenAIKey}
    $proc=Start-Process -FilePath 'powershell' -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$Fixture.MockScript,
        '-Port',$Fixture.Port,'-RequestCount',$RequestCount,'-StateDir',$Fixture.StateRoot,
        '-KnowledgeId',$knowledgeId,'-EmbeddingModel',$embeddingModel,'-FailOnUploadNumber',$FailOnUploadNumber,'-FailOnRemoveNumber',$FailOnRemoveNumber,
        '-InitialEmbeddingEngine',$InitialEmbeddingEngine,'-InitialEmbeddingModel',$InitialEmbeddingModel,
        '-InitialEmbeddingUrl',$InitialEmbeddingUrl,'-InitialOpenAIKey',$safeOpenAIKeyArg
    ) -PassThru
    Start-Sleep -Milliseconds 300
    $proc
}

function Stop-RAGMockOpenWebUIServer {
    param($Process)
    if($null -ne $Process -and -not $Process.HasExited){Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue}
}

$plainToken=ConvertTo-SecureString 'fixture-token' -AsPlainText -Force
$schemaPath=Join-Path $PackageRoot 'Contracts/source.schema.json'
$previousPath=$env:PATH
$minimalWindowsPath=@("$env:SystemRoot\System32","$env:SystemRoot","$env:SystemRoot\System32\WindowsPowerShell\v1.0") -join ';'

# --- Scenario 1: 3 Adds, entry 3 fails -> state has 1+2, retry plans only 3
$fixture1=New-RAGExecuteFixture -FileCount 3
$server1=$null
try{
    $server1=Start-RAGMockOpenWebUIServer -Fixture $fixture1 -FailOnUploadNumber 3
    $env:PATH=$minimalWindowsPath
    $threw=$false
    try{
        Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture1.ConfigPath -SourcesPath $fixture1.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    }catch{$threw=$true}
    if(-not$threw){$failures.Add('Szenario 1: induzierter Upload-Fehler bei Datei 3 führte nicht zu einem Fehlschlag.')}
    if(-not(Test-Path -LiteralPath $fixture1.StatePath)){
        $failures.Add('Szenario 1: state.json wurde nach Teilfehlschlag gar nicht geschrieben (kein inkrementelles Commit).')
    } else {
        $stateAfter=Get-Content -LiteralPath $fixture1.StatePath -Raw|ConvertFrom-Json
        if(@($stateAfter.entries).Count -ne 2){$failures.Add("Szenario 1: state.json enthält $(@($stateAfter.entries).Count) Einträge, erwartet 2 (doc1, doc2).")}
        if(@($stateAfter.entries|Where-Object file_name -eq 'doc3.md').Count -ne 0){$failures.Add('Szenario 1: fehlgeschlagene Datei 3 ist trotzdem im State gelandet.')}
        if(@($stateAfter.entries|Where-Object file_name -eq 'doc1.md').Count -ne 1 -or @($stateAfter.entries|Where-Object file_name -eq 'doc2.md').Count -ne 1){
            $failures.Add('Szenario 1: erfolgreiche Dateien 1/2 fehlen im State.')
        }
    }
    # Retry planning: only the still-missing entry should be planned.
    $retryPlan=Invoke-KIStackRAG -Mode DryRun -ConfigPath $fixture1.ConfigPath -SourcesPath $fixture1.SourcesPath -SourceSchemaPath $schemaPath
    if($retryPlan.add -ne 1){$failures.Add("Szenario 1 Retry-Plan: add=$($retryPlan.add), erwartet 1 (nur Datei 3).")}
    if($retryPlan.skip -ne 2){$failures.Add("Szenario 1 Retry-Plan: skip=$($retryPlan.skip), erwartet 2 (Datei 1+2 bereits erfolgreich).")}
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server1
    if(Test-Path -LiteralPath $fixture1.Root){Remove-Item -LiteralPath $fixture1.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 2: Replace succeeds -> new state persisted, retry = Skip ----
$fixture2=New-RAGExecuteFixture -FileCount 1
$server2=$null
try{
    $server2=Start-RAGMockOpenWebUIServer -Fixture $fixture2
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture2.ConfigPath -SourcesPath $fixture2.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server2
    Set-Content -LiteralPath (Join-Path $fixture2.SourceRoot 'doc1.md') -Value "# Document 1`n`nChanged fixture content for document 1." -Encoding utf8NoBOM
    $server2=Start-RAGMockOpenWebUIServer -Fixture $fixture2
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture2.ConfigPath -SourcesPath $fixture2.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    $stateAfterReplace=Get-Content -LiteralPath $fixture2.StatePath -Raw|ConvertFrom-Json
    $newHash=(Get-FileHash -LiteralPath (Join-Path $fixture2.SourceRoot 'doc1.md') -Algorithm SHA256).Hash.ToLowerInvariant()
    if(@($stateAfterReplace.entries).Count -ne 1){$failures.Add('Szenario 2: nach Replace enthält state.json nicht genau einen Eintrag.')}
    if([string]$stateAfterReplace.entries[0].file_sha256 -ne $newHash){$failures.Add('Szenario 2: state.json zeigt nach Replace nicht den neuen Dateihash.')}
    Stop-RAGMockOpenWebUIServer -Process $server2
    $retryPlan2=Invoke-KIStackRAG -Mode DryRun -ConfigPath $fixture2.ConfigPath -SourcesPath $fixture2.SourcesPath -SourceSchemaPath $schemaPath
    if($retryPlan2.skip -ne 1 -or $retryPlan2.replace -ne 0){$failures.Add("Szenario 2 Retry-Plan nach erfolgreichem Replace: skip=$($retryPlan2.skip), replace=$($retryPlan2.replace), erwartet skip=1/replace=0.")}
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server2
    if(Test-Path -LiteralPath $fixture2.Root){Remove-Item -LiteralPath $fixture2.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 3: Replace's new upload fails before any commit -> previous state untouched
$fixture3=New-RAGExecuteFixture -FileCount 1
$server3=$null
try{
    $server3=Start-RAGMockOpenWebUIServer -Fixture $fixture3
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture3.ConfigPath -SourcesPath $fixture3.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server3
    $stateBefore=Get-Content -LiteralPath $fixture3.StatePath -Raw
    Set-Content -LiteralPath (Join-Path $fixture3.SourceRoot 'doc1.md') -Value "# Document 1`n`nChanged again, upload will fail this time." -Encoding utf8NoBOM
    $server3=Start-RAGMockOpenWebUIServer -Fixture $fixture3 -FailOnUploadNumber 1
    $threw3=$false
    try{Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture3.ConfigPath -SourcesPath $fixture3.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null}catch{$threw3=$true}
    if(-not$threw3){$failures.Add('Szenario 3: induzierter Upload-Fehler beim Replace führte nicht zu einem Fehlschlag.')}
    $stateAfterFailedReplace=Get-Content -LiteralPath $fixture3.StatePath -Raw
    if($stateAfterFailedReplace -ne $stateBefore){$failures.Add('Szenario 3: state.json wurde trotz vor dem Commit fehlgeschlagenem Replace-Upload verändert.')}
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server3
    if(Test-Path -LiteralPath $fixture3.Root){Remove-Item -LiteralPath $fixture3.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 4: Remove succeeds -> entry gone from state -----------------
$fixture4=New-RAGExecuteFixture -FileCount 1
$server4=$null
try{
    $server4=Start-RAGMockOpenWebUIServer -Fixture $fixture4
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture4.ConfigPath -SourcesPath $fixture4.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server4
    Remove-Item -LiteralPath (Join-Path $fixture4.SourceRoot 'doc1.md') -Force
    $server4=Start-RAGMockOpenWebUIServer -Fixture $fixture4
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture4.ConfigPath -SourcesPath $fixture4.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    $stateAfterRemove=Get-Content -LiteralPath $fixture4.StatePath -Raw|ConvertFrom-Json
    if(@($stateAfterRemove.entries).Count -ne 0){$failures.Add('Szenario 4: state.json enthält nach erfolgreichem Remove noch Einträge.')}
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server4
    if(Test-Path -LiteralPath $fixture4.Root){Remove-Item -LiteralPath $fixture4.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 5: Remove fails -> entry stays in state ----------------------
$fixture5=New-RAGExecuteFixture -FileCount 1
$server5=$null
try{
    $server5=Start-RAGMockOpenWebUIServer -Fixture $fixture5
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture5.ConfigPath -SourcesPath $fixture5.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server5
    $stateBefore5=Get-Content -LiteralPath $fixture5.StatePath -Raw
    Remove-Item -LiteralPath (Join-Path $fixture5.SourceRoot 'doc1.md') -Force
    New-Item -ItemType File -Path (Join-Path $fixture5.StateRoot 'fail-remove.marker') -Force|Out-Null
    $server5=Start-RAGMockOpenWebUIServer -Fixture $fixture5
    $threw5=$false
    try{Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture5.ConfigPath -SourcesPath $fixture5.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null}catch{$threw5=$true}
    if(-not$threw5){$failures.Add('Szenario 5: induzierter Remove-Fehler führte nicht zu einem Fehlschlag.')}
    $stateAfterFailedRemove=Get-Content -LiteralPath $fixture5.StatePath -Raw
    if($stateAfterFailedRemove -ne $stateBefore5){$failures.Add('Szenario 5: state.json wurde trotz fehlgeschlagenem Remove verändert.')}
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server5
    if(Test-Path -LiteralPath $fixture5.Root){Remove-Item -LiteralPath $fixture5.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 6: atomic checkpoint write leaves no corrupt/partial file ---
$fixture6=New-RAGExecuteFixture -FileCount 1
try{
    New-Item -ItemType Directory -Path $fixture6.StateRoot -Force|Out-Null
    $configForCheckpoint=Get-Content -LiteralPath $fixture6.ConfigPath -Raw|ConvertFrom-Json
    $entries=@{'k1'=[pscustomobject]@{key='k1';source_id='fixture-src';relative_path='doc1.md'}}
    Save-RAGStateCheckpoint -StatePath $fixture6.StatePath -Config $configForCheckpoint -KnowledgeId $knowledgeId -Entries $entries|Out-Null
    if(Test-Path -LiteralPath "$($fixture6.StatePath).new"){$failures.Add('Szenario 6: temporäre Schreibdatei blieb nach dem Checkpoint zurück.')}
    try{
        $null=Get-Content -LiteralPath $fixture6.StatePath -Raw|ConvertFrom-Json
    }catch{$failures.Add("Szenario 6: state.json ist nach dem Checkpoint keine gültige JSON-Datei: $($_.Exception.Message)")}
    $entries['k2']=[pscustomobject]@{key='k2';source_id='fixture-src';relative_path='doc2.md'}
    Save-RAGStateCheckpoint -StatePath $fixture6.StatePath -Config $configForCheckpoint -KnowledgeId $knowledgeId -Entries $entries|Out-Null
    $reread=Get-Content -LiteralPath $fixture6.StatePath -Raw|ConvertFrom-Json
    if(@($reread.entries).Count -ne 2){$failures.Add('Szenario 6: zweiter Checkpoint hat den ersten Eintrag verloren statt fortzuschreiben.')}
}finally{
    if(Test-Path -LiteralPath $fixture6.Root){Remove-Item -LiteralPath $fixture6.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 7 (AP02.5): Replace's old-removal fails -> retry finishes
# only the pending cleanup, never re-uploads the already-committed new
# content, and no orphaned remote reference remains afterward. ------------
$fixture7=New-RAGExecuteFixture -FileCount 1
$server7=$null
try{
    $server7=Start-RAGMockOpenWebUIServer -Fixture $fixture7
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture7.ConfigPath -SourcesPath $fixture7.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server7

    Set-Content -LiteralPath (Join-Path $fixture7.SourceRoot 'doc1.md') -Value "# Document 1`n`nReplaced content whose old removal will fail." -Encoding utf8NoBOM
    New-Item -ItemType File -Path (Join-Path $fixture7.StateRoot 'fail-remove.marker') -Force|Out-Null
    $server7=Start-RAGMockOpenWebUIServer -Fixture $fixture7
    $threw7=$false
    try{Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture7.ConfigPath -SourcesPath $fixture7.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null}catch{$threw7=$true}
    if(-not$threw7){$failures.Add('Szenario 7: induzierter Fehlschlag der Alt-Entfernung führte nicht zu einem Fehlschlag.')}
    Stop-RAGMockOpenWebUIServer -Process $server7

    $stateAfterFailedCleanup=Get-Content -LiteralPath $fixture7.StatePath -Raw|ConvertFrom-Json
    $newHash7=(Get-FileHash -LiteralPath (Join-Path $fixture7.SourceRoot 'doc1.md') -Algorithm SHA256).Hash.ToLowerInvariant()
    if(@($stateAfterFailedCleanup.entries).Count -ne 1 -or [string]$stateAfterFailedCleanup.entries[0].file_sha256 -ne $newHash7){
        $failures.Add('Szenario 7: neuer Inhalt ist nach fehlgeschlagener Alt-Entfernung nicht konsistent im lokalen State committed.')
    }
    if(-not $stateAfterFailedCleanup.PSObject.Properties['pendingRemovals'] -or @($stateAfterFailedCleanup.pendingRemovals).Count -ne 1){
        $failures.Add("Szenario 7: state.json verzeichnet nicht genau eine ausstehende Alt-Löschung (gefunden: $(if($stateAfterFailedCleanup.PSObject.Properties['pendingRemovals']){@($stateAfterFailedCleanup.pendingRemovals).Count}else{'Feld fehlt'})).")
    }

    # Retry planning: the entry is already committed, so the normal plan
    # must show nothing left to do for it -- only the pending cleanup is
    # outstanding.
    $retryPlan7=Invoke-KIStackRAG -Mode DryRun -ConfigPath $fixture7.ConfigPath -SourcesPath $fixture7.SourcesPath -SourceSchemaPath $schemaPath
    if($retryPlan7.replace -ne 0 -or $retryPlan7.add -ne 0 -or $retryPlan7.skip -ne 1){
        $failures.Add("Szenario 7 Retry-Plan: add=$($retryPlan7.add), replace=$($retryPlan7.replace), skip=$($retryPlan7.skip); erwartet add=0/replace=0/skip=1 (neuer Inhalt bereits committed, kein erneuter Upload nötig).")
    }

    Remove-Item -LiteralPath (Join-Path $fixture7.StateRoot 'fail-remove.marker') -Force
    $server7=Start-RAGMockOpenWebUIServer -Fixture $fixture7
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture7.ConfigPath -SourcesPath $fixture7.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server7

    $stateAfterCleanupRetry=Get-Content -LiteralPath $fixture7.StatePath -Raw|ConvertFrom-Json
    if(@($stateAfterCleanupRetry.entries).Count -ne 1 -or [string]$stateAfterCleanupRetry.entries[0].file_sha256 -ne $newHash7){
        $failures.Add('Szenario 7: Cleanup-Retry hat den committed neuen Inhalt verändert -- er hätte unangetastet bleiben müssen.')
    }
    if(@($stateAfterCleanupRetry.pendingRemovals).Count -ne 0){
        $failures.Add('Szenario 7: nach erfolgreichem Cleanup-Retry ist immer noch eine ausstehende Alt-Löschung im State verzeichnet (verwaiste Remote-Referenz).')
    }
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server7
    if(Test-Path -LiteralPath $fixture7.Root){Remove-Item -LiteralPath $fixture7.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 8 (AP04): batch/add JSON-array root, both element counts ---
# The mock's batch/add route now genuinely validates that the wire body is
# a JSON array (see Read-MockHttpRequest / the route above); it no longer
# accepts any body unconditionally. Scenarios 1/2/4/5/7 above each Add a
# single short (one-chunk) document, so every one of them already re-proves
# the one-element-array case end to end against that validating mock. This
# scenario adds the still-missing multi-element case: a document long
# enough to split into several chunks, so its batch/add body must carry
# more than one file_id and still be accepted as a JSON array.
$fixture8=New-RAGExecuteFixture -FileCount 1
$server8=$null
try{
    $paragraph='Fixture content sentence for multi chunk coverage. '*20
    $longContent=(@($paragraph.Trim(),$paragraph.Trim(),$paragraph.Trim())-join "`n`n")
    Set-Content -LiteralPath (Join-Path $fixture8.SourceRoot 'doc1.md') -Value "# Multi-Chunk Document`n`n$longContent" -Encoding utf8NoBOM
    $server8=Start-RAGMockOpenWebUIServer -Fixture $fixture8
    $env:PATH=$minimalWindowsPath
    $threw8=$false
    try{
        Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture8.ConfigPath -SourcesPath $fixture8.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    }catch{
        $threw8=$true
        $failures.Add("Szenario 8: Execute mit mehreren Chunks scheiterte am (jetzt Array-validierenden) Mock-Batch-Add: $($_.Exception.Message)")
    }
    if(-not$threw8){
        $stateAfter8=Get-Content -LiteralPath $fixture8.StatePath -Raw|ConvertFrom-Json
        if(@($stateAfter8.entries).Count -ne 1){
            $failures.Add('Szenario 8: state.json enthält nach Multi-Chunk-Add nicht genau einen Eintrag.')
        } elseif(@($stateAfter8.entries[0].chunks).Count -lt 2){
            $failures.Add("Szenario 8: Dokument wurde nicht wie erwartet in mehrere Chunks gesplittet (gefunden: $(@($stateAfter8.entries[0].chunks).Count)); der Mehr-Elemente-Array-Fall wurde damit nicht wirklich geprüft.")
        }
    }
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server8
    if(Test-Path -LiteralPath $fixture8.Root){Remove-Item -LiteralPath $fixture8.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 9 (AP04): DryRun/Audit after the last file of a source is
# removed must not crash. Get-RAGInventory's own @(...)-wrapped return still
# collapses to $null at the Invoke-KIStackRAG call site when zero files
# match, and under Set-StrictMode a raw $inventory.Count then throws "The
# property 'Count' cannot be found on this object". This path carries no
# remote API calls at all (Audit/DryRun/Status return before any Invoke-
# RAGApi call), so Scenarios 4/5 above -- which remove the only file and
# then run Execute -- never actually exercised it: Execute skips straight
# past the Count read that only exists in the Audit/DryRun/Status branch.
$fixture9=New-RAGExecuteFixture -FileCount 1
$server9=$null
try{
    $server9=Start-RAGMockOpenWebUIServer -Fixture $fixture9
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture9.ConfigPath -SourcesPath $fixture9.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server9
    Remove-Item -LiteralPath (Join-Path $fixture9.SourceRoot 'doc1.md') -Force

    $threw9=$false
    $dryRun9=$null
    try{
        $dryRun9=Invoke-KIStackRAG -Mode DryRun -ConfigPath $fixture9.ConfigPath -SourcesPath $fixture9.SourcesPath -SourceSchemaPath $schemaPath
    }catch{
        $threw9=$true
        $failures.Add("Szenario 9: DryRun nach Entfernen der letzten Datei einer Quelle warf einen Fehler statt eines sauberen Plans: $($_.Exception.Message)")
    }
    if(-not$threw9){
        if($dryRun9.files -ne 0){$failures.Add("Szenario 9: DryRun-Plan zeigt files=$($dryRun9.files), erwartet 0 (Quelle ist jetzt leer).")}
        if($dryRun9.remove -ne 1){$failures.Add("Szenario 9: DryRun-Plan zeigt remove=$($dryRun9.remove), erwartet 1 (die entfernte Datei).")}
        if($dryRun9.add -ne 0 -or $dryRun9.replace -ne 0 -or $dryRun9.skip -ne 0){
            $failures.Add("Szenario 9: DryRun-Plan zeigt add=$($dryRun9.add)/replace=$($dryRun9.replace)/skip=$($dryRun9.skip), erwartet alle 0.")
        }
    }

    # Audit must be unaffected by the same code path for the identical reason.
    $threwAudit9=$false
    try{
        $null=Invoke-KIStackRAG -Mode Audit -ConfigPath $fixture9.ConfigPath -SourcesPath $fixture9.SourcesPath -SourceSchemaPath $schemaPath
    }catch{
        $threwAudit9=$true
        $failures.Add("Szenario 9: Audit nach Entfernen der letzten Datei einer Quelle warf denselben Fehler: $($_.Exception.Message)")
    }
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server9
    if(Test-Path -LiteralPath $fixture9.Root){Remove-Item -LiteralPath $fixture9.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 10 (AP05): Add -> Rollback -> original state restored; a
# second Rollback call is then a clean idempotent no-op. -------------------
$fixture10=New-RAGExecuteFixture -FileCount 2
$server10=$null
try{
    $server10=Start-RAGMockOpenWebUIServer -Fixture $fixture10
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture10.ConfigPath -SourcesPath $fixture10.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server10
    $stateAfterAdd10=Get-Content -LiteralPath $fixture10.StatePath -Raw|ConvertFrom-Json
    if(@($stateAfterAdd10.entries).Count -ne 2){$failures.Add("Szenario 10: nach initialem Add enthält state.json $(@($stateAfterAdd10.entries).Count) Einträge, erwartet 2.")}

    $server10=Start-RAGMockOpenWebUIServer -Fixture $fixture10
    $rollback10=Invoke-KIStackRAG -Mode Rollback -ConfigPath $fixture10.ConfigPath -SourcesPath $fixture10.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken
    Stop-RAGMockOpenWebUIServer -Process $server10
    if(-not $rollback10.passed){$failures.Add('Szenario 10: Rollback meldete passed=false.')}
    if(@($rollback10.rolledBack).Count -ne 2){$failures.Add("Szenario 10: Rollback hat $(@($rollback10.rolledBack).Count) Einträge zurückgerollt, erwartet 2.")}
    $stateAfterRollback10=Get-Content -LiteralPath $fixture10.StatePath -Raw|ConvertFrom-Json
    if(@($stateAfterRollback10.entries).Count -ne 0){$failures.Add("Szenario 10: state.json enthält nach Rollback noch $(@($stateAfterRollback10.entries).Count) Einträge, erwartet 0 (Ausgangszustand vor dem Add).")}

    # Idempotenz: ein zweiter Rollback-Aufruf muss ein sauberer No-op sein.
    $server10=Start-RAGMockOpenWebUIServer -Fixture $fixture10
    $rollback10b=Invoke-KIStackRAG -Mode Rollback -ConfigPath $fixture10.ConfigPath -SourcesPath $fixture10.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken
    Stop-RAGMockOpenWebUIServer -Process $server10
    if(-not $rollback10b.passed){$failures.Add('Szenario 10: zweiter (idempotenter) Rollback-Aufruf meldete passed=false.')}
    if(@($rollback10b.rolledBack).Count -ne 0){$failures.Add("Szenario 10: zweiter Rollback-Aufruf hat $(@($rollback10b.rolledBack).Count) Einträge erneut zurückgerollt, erwartet 0 (bereits sauber).")}
    if(@($rollback10b.alreadyClean).Count -ne 2){$failures.Add("Szenario 10: zweiter Rollback-Aufruf meldet nicht beide Einträge als bereits bereinigt (alreadyClean=$(@($rollback10b.alreadyClean).Count)).")}
    $stateAfterSecondRollback10=Get-Content -LiteralPath $fixture10.StatePath -Raw|ConvertFrom-Json
    if(@($stateAfterSecondRollback10.entries).Count -ne 0){$failures.Add('Szenario 10: zweiter Rollback-Aufruf hat den bereits leeren State verändert.')}
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server10
    if(Test-Path -LiteralPath $fixture10.Root){Remove-Item -LiteralPath $fixture10.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 11 (AP05): Replace -> Rollback -> old content restored, new
# content removed; verifies the restored entry's content is the exact
# original bytes via the archive round trip, not just a hash match. -------
$fixture11=New-RAGExecuteFixture -FileCount 1
$server11=$null
try{
    $server11=Start-RAGMockOpenWebUIServer -Fixture $fixture11
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture11.ConfigPath -SourcesPath $fixture11.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server11
    $originalHash11=(Get-FileHash -LiteralPath (Join-Path $fixture11.SourceRoot 'doc1.md') -Algorithm SHA256).Hash.ToLowerInvariant()

    Set-Content -LiteralPath (Join-Path $fixture11.SourceRoot 'doc1.md') -Value "# Document 1`n`nReplaced content for rollback test." -Encoding utf8NoBOM
    $server11=Start-RAGMockOpenWebUIServer -Fixture $fixture11
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture11.ConfigPath -SourcesPath $fixture11.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server11
    $stateAfterReplace11=Get-Content -LiteralPath $fixture11.StatePath -Raw|ConvertFrom-Json
    $newFileId11=$stateAfterReplace11.entries[0].chunks[0].file_id

    $server11=Start-RAGMockOpenWebUIServer -Fixture $fixture11
    $rollback11=Invoke-KIStackRAG -Mode Rollback -ConfigPath $fixture11.ConfigPath -SourcesPath $fixture11.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken
    Stop-RAGMockOpenWebUIServer -Process $server11

    if(-not $rollback11.passed){$failures.Add('Szenario 11: Rollback meldete passed=false.')}
    $stateAfterRollback11=Get-Content -LiteralPath $fixture11.StatePath -Raw|ConvertFrom-Json
    if(@($stateAfterRollback11.entries).Count -ne 1){$failures.Add('Szenario 11: state.json enthält nach Replace-Rollback nicht genau einen Eintrag.')}
    if([string]$stateAfterRollback11.entries[0].file_sha256 -ne $originalHash11){$failures.Add('Szenario 11: state.json zeigt nach Rollback nicht den ursprünglichen (vor-Replace) Dateihash.')}
    $restoredFileId11=$stateAfterRollback11.entries[0].chunks[0].file_id
    if([string]$restoredFileId11 -eq [string]$newFileId11){$failures.Add('Szenario 11: Rollback hat keine neue Remote-Datei für den wiederhergestellten Inhalt angelegt (gleiche file_id wie der ersetzte neue Inhalt).')}

    # Inhaltliche Fidelity: der über den Mock gespeicherte Inhalt der
    # wiederhergestellten Datei muss dem ursprünglichen (vor-Replace) Text
    # entsprechen -- nicht nur der Hash in state.json, sondern die
    # tatsächlich erneut hochgeladenen Bytes.
    $mockContents11=Get-Content -LiteralPath (Join-Path $fixture11.StateRoot 'mock-file-contents.json') -Raw|ConvertFrom-Json
    $restoredContent11=[string]($mockContents11.PSObject.Properties|Where-Object Name -eq $restoredFileId11|Select-Object -ExpandProperty Value)
    if($restoredContent11 -notmatch [regex]::Escape('Fixture content for document 1.')){
        $failures.Add('Szenario 11: der über Rollback wiederhergestellte Remote-Inhalt entspricht nicht dem ursprünglichen (vor-Replace) Text.')
    }
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server11
    if(Test-Path -LiteralPath $fixture11.Root){Remove-Item -LiteralPath $fixture11.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 12 (AP05): Remove -> Rollback -> the removed content is
# restored, with its original file_sha256 intact. --------------------------
$fixture12=New-RAGExecuteFixture -FileCount 1
$server12=$null
try{
    $server12=Start-RAGMockOpenWebUIServer -Fixture $fixture12
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture12.ConfigPath -SourcesPath $fixture12.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server12
    $originalHash12=(Get-FileHash -LiteralPath (Join-Path $fixture12.SourceRoot 'doc1.md') -Algorithm SHA256).Hash.ToLowerInvariant()

    Remove-Item -LiteralPath (Join-Path $fixture12.SourceRoot 'doc1.md') -Force
    $server12=Start-RAGMockOpenWebUIServer -Fixture $fixture12
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture12.ConfigPath -SourcesPath $fixture12.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server12
    $stateAfterRemove12=Get-Content -LiteralPath $fixture12.StatePath -Raw|ConvertFrom-Json
    if(@($stateAfterRemove12.entries).Count -ne 0){$failures.Add('Szenario 12: state.json enthält nach Remove noch Einträge.')}

    $server12=Start-RAGMockOpenWebUIServer -Fixture $fixture12
    $rollback12=Invoke-KIStackRAG -Mode Rollback -ConfigPath $fixture12.ConfigPath -SourcesPath $fixture12.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken
    Stop-RAGMockOpenWebUIServer -Process $server12

    if(-not $rollback12.passed){$failures.Add('Szenario 12: Rollback meldete passed=false.')}
    $stateAfterRollback12=Get-Content -LiteralPath $fixture12.StatePath -Raw|ConvertFrom-Json
    if(@($stateAfterRollback12.entries).Count -ne 1){$failures.Add('Szenario 12: state.json enthält nach Remove-Rollback nicht genau einen wiederhergestellten Eintrag.')}
    if([string]$stateAfterRollback12.entries[0].file_sha256 -ne $originalHash12){$failures.Add('Szenario 12: state.json zeigt nach Remove-Rollback nicht den ursprünglichen Dateihash.')}
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server12
    if(Test-Path -LiteralPath $fixture12.Root){Remove-Item -LiteralPath $fixture12.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 13 (AP05): Rollback fails partway through a multi-entry
# transaction -> progress made so far is persisted, and a retry finishes
# only the remaining item without re-touching the one already done. -------
$fixture13=New-RAGExecuteFixture -FileCount 2
$server13=$null
try{
    $server13=Start-RAGMockOpenWebUIServer -Fixture $fixture13
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture13.ConfigPath -SourcesPath $fixture13.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server13
    $manifest13=Get-Content -LiteralPath (Join-Path $fixture13.StateRoot 'rollback-archive.json') -Raw|ConvertFrom-Json
    if(@($manifest13.added).Count -ne 2){$failures.Add("Szenario 13: rollback-archive.json listet $(@($manifest13.added).Count) Add-Einträge, erwartet 2 -- Testannahme verletzt.")}

    # Der zweite Remove-Aufruf (das zweite von zwei Rollback-Elementen)
    # wird induziert zum Scheitern gebracht.
    $server13=Start-RAGMockOpenWebUIServer -Fixture $fixture13 -FailOnRemoveNumber 2
    $threw13=$false
    try{
        Invoke-KIStackRAG -Mode Rollback -ConfigPath $fixture13.ConfigPath -SourcesPath $fixture13.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    }catch{$threw13=$true}
    Stop-RAGMockOpenWebUIServer -Process $server13
    if(-not$threw13){$failures.Add('Szenario 13: induzierter Fehler beim zweiten Rollback-Element führte nicht zu einem Fehlschlag.')}

    $stateAfterPartial13=Get-Content -LiteralPath $fixture13.StatePath -Raw|ConvertFrom-Json
    if(@($stateAfterPartial13.entries).Count -ne 1){
        $failures.Add("Szenario 13: nach dem Teil-Rollback enthält state.json $(@($stateAfterPartial13.entries).Count) Einträge, erwartet 1 (ein Element erfolgreich zurückgerollt, das andere blieb wegen des induzierten Fehlers stehen).")
    }

    # Retry: ohne induzierten Fehler muss das verbleibende Element fertig
    # zurückgerollt werden, ohne das bereits erledigte erneut anzufassen.
    $server13=Start-RAGMockOpenWebUIServer -Fixture $fixture13
    $retryRollback13=Invoke-KIStackRAG -Mode Rollback -ConfigPath $fixture13.ConfigPath -SourcesPath $fixture13.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken
    Stop-RAGMockOpenWebUIServer -Process $server13

    if(-not $retryRollback13.passed){$failures.Add('Szenario 13: Retry-Rollback meldete passed=false.')}
    if(@($retryRollback13.rolledBack).Count -ne 1){$failures.Add("Szenario 13: Retry-Rollback hat $(@($retryRollback13.rolledBack).Count) Elemente zurückgerollt, erwartet genau 1 (nur das zuvor fehlgeschlagene).")}
    if(@($retryRollback13.alreadyClean).Count -ne 1){$failures.Add('Szenario 13: Retry-Rollback meldet nicht das bereits im ersten Versuch erledigte Element als bereits bereinigt.')}
    $stateAfterRetry13=Get-Content -LiteralPath $fixture13.StatePath -Raw|ConvertFrom-Json
    if(@($stateAfterRetry13.entries).Count -ne 0){$failures.Add('Szenario 13: state.json enthält nach dem abschließenden Retry-Rollback noch Einträge.')}
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server13
    if(Test-Path -LiteralPath $fixture13.Root){Remove-Item -LiteralPath $fixture13.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 14 (AP05): Rollback must never touch an entry from an
# earlier, separate Execute transaction -- only rollback-archive.json's own
# added/replaced/removed lists define scope, never the full local state. --
$fixture14=New-RAGExecuteFixture -FileCount 1
$server14=$null
try{
    $server14=Start-RAGMockOpenWebUIServer -Fixture $fixture14
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture14.ConfigPath -SourcesPath $fixture14.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server14
    $foreignEntry14=(Get-Content -LiteralPath $fixture14.StatePath -Raw|ConvertFrom-Json).entries[0]
    $foreignFileId14=[string]$foreignEntry14.chunks[0].file_id

    # Ein zweiter, separater Execute-Lauf legt eine weitere Datei an. Nur
    # DIESE Transaktion darf rollback-archive.json ab hier beschreiben; die
    # "fremde" Datei aus dem ersten Lauf gehört zu keiner der drei Listen.
    Set-Content -LiteralPath (Join-Path $fixture14.SourceRoot 'doc-mine.md') -Value "# Mine`n`nSecond source file for this transaction." -Encoding utf8NoBOM
    $server14=Start-RAGMockOpenWebUIServer -Fixture $fixture14
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture14.ConfigPath -SourcesPath $fixture14.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server14
    $manifest14=Get-Content -LiteralPath (Join-Path $fixture14.StateRoot 'rollback-archive.json') -Raw|ConvertFrom-Json
    if(@($manifest14.added).Count -ne 1){$failures.Add("Szenario 14: rollback-archive.json listet $(@($manifest14.added).Count) Add-Einträge nach dem zweiten Execute-Lauf, erwartet 1 (nur die neue Datei) -- Testannahme verletzt.")}

    $server14=Start-RAGMockOpenWebUIServer -Fixture $fixture14
    $rollback14=Invoke-KIStackRAG -Mode Rollback -ConfigPath $fixture14.ConfigPath -SourcesPath $fixture14.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken
    Stop-RAGMockOpenWebUIServer -Process $server14

    if(-not $rollback14.passed){$failures.Add('Szenario 14: Rollback meldete passed=false.')}
    $stateAfterRollback14=Get-Content -LiteralPath $fixture14.StatePath -Raw|ConvertFrom-Json
    if(@($stateAfterRollback14.entries).Count -ne 1){
        $failures.Add("Szenario 14: state.json enthält nach dem Rollback $(@($stateAfterRollback14.entries).Count) Einträge, erwartet genau 1 (der fremde Eintrag aus der ersten Transaktion muss unangetastet bleiben).")
    } else {
        $survivingEntry14=$stateAfterRollback14.entries[0]
        if([string]$survivingEntry14.relative_path -ne 'doc1.md'){
            $failures.Add("Szenario 14: der nach dem Rollback verbliebene Eintrag ist nicht der fremde ('$([string]$survivingEntry14.relative_path)' statt 'doc1.md').")
        }
        if([string]$survivingEntry14.chunks[0].file_id -ne $foreignFileId14){
            $failures.Add('Szenario 14: die file_id des fremden Eintrags hat sich durch den Rollback verändert -- er wurde offenbar doch angefasst.')
        }
    }
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server14
    if(Test-Path -LiteralPath $fixture14.Root){Remove-Item -LiteralPath $fixture14.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 15 (AP06): Audit with a valid config -> reports local
# capability cleanly, no exception, and does not carry DryRun's
# add/replace/remove/skip plan fields (that would still be the old,
# unified Audit/DryRun/Status contract this AP replaces). ------------------
$fixture15=New-RAGExecuteFixture -FileCount 2
try{
    $audit15=Invoke-KIStackRAG -Mode Audit -ConfigPath $fixture15.ConfigPath -SourcesPath $fixture15.SourcesPath -SourceSchemaPath $schemaPath
    if(-not $audit15.sourcesSchemaValid){$failures.Add('Szenario 15: Audit meldet sourcesSchemaValid=false bei gültiger Config.')}
    if(-not $audit15.sourcesReachable){$failures.Add('Szenario 15: Audit meldet sourcesReachable=false bei gültiger Config.')}
    if(-not $audit15.stateReadable){$failures.Add('Szenario 15: Audit meldet stateReadable=false bei gültiger Config.')}
    if(-not $audit15.configComplete){$failures.Add("Szenario 15: Audit meldet configComplete=false bei vollständiger Config (fehlend: $($audit15.missingConfigFields -join ', ')).")}
    if($audit15.files -ne 2){$failures.Add("Szenario 15: Audit zeigt files=$($audit15.files), erwartet 2.")}
    if($audit15.statePresent){$failures.Add('Szenario 15: Audit meldet statePresent=true, obwohl noch nie Execute lief.')}
    if($audit15.mutatesTarget){$failures.Add('Szenario 15: Audit meldet mutatesTarget=true.')}
    if($audit15.PSObject.Properties['add'] -or $audit15.PSObject.Properties['replace']){
        $failures.Add('Szenario 15: Audit-Ergebnis enthält Add/Replace/Remove/Skip-Felder -- das ist DryRuns Vertrag, nicht Audits.')
    }
}finally{
    if(Test-Path -LiteralPath $fixture15.Root){Remove-Item -LiteralPath $fixture15.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 16 (AP06): Audit against a missing source root -> a clean,
# specific thrown error -- the same contract Get-RAGInventory already
# provided; Audit adds no separate translation layer over it. -------------
$fixture16=New-RAGExecuteFixture -FileCount 1
try{
    $badSourcesPath=Join-Path $fixture16.Root 'sources-bad.json'
    $missingRoot=Join-Path $fixture16.Root 'does-not-exist'
    $badSources=[ordered]@{schemaVersion='1.0';sources=@(@{source_id='bad-src';source_type='directory';project='fixture';root=$missingRoot;visibility='private';enabled=$true})}
    ($badSources|ConvertTo-Json -Depth 10)|Set-Content -LiteralPath $badSourcesPath -Encoding utf8NoBOM

    $threw16=$false;$message16=''
    try{
        Invoke-KIStackRAG -Mode Audit -ConfigPath $fixture16.ConfigPath -SourcesPath $badSourcesPath -SourceSchemaPath $schemaPath|Out-Null
    }catch{
        $threw16=$true;$message16=$_.Exception.Message
    }
    if(-not$threw16){$failures.Add('Szenario 16: Audit gegen eine fehlende Quelle warf keinen Fehler.')}
    if($threw16 -and $message16 -notmatch [regex]::Escape($missingRoot)){
        $failures.Add("Szenario 16: Audit-Fehlermeldung nennt nicht den fehlenden Quellpfad (erhalten: $message16).")
    }
}finally{
    if(Test-Path -LiteralPath $fixture16.Root){Remove-Item -LiteralPath $fixture16.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 17 (AP06): DryRun with a genuine mix of Add/Replace/Remove/
# Skip in a single call -> each count correct. Deliberately never executes
# the previewed changes -- DryRun must be a pure preview regardless. ------
$fixture17=New-RAGExecuteFixture -FileCount 3
$server17=$null
try{
    $server17=Start-RAGMockOpenWebUIServer -Fixture $fixture17
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture17.ConfigPath -SourcesPath $fixture17.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server17

    Set-Content -LiteralPath (Join-Path $fixture17.SourceRoot 'doc1.md') -Value "# Document 1`n`nChanged for DryRun mix test." -Encoding utf8NoBOM
    Remove-Item -LiteralPath (Join-Path $fixture17.SourceRoot 'doc2.md') -Force
    Set-Content -LiteralPath (Join-Path $fixture17.SourceRoot 'doc4.md') -Value "# Document 4`n`nBrand new file." -Encoding utf8NoBOM
    # doc3.md is left untouched -> Skip

    $dryRun17=Invoke-KIStackRAG -Mode DryRun -ConfigPath $fixture17.ConfigPath -SourcesPath $fixture17.SourcesPath -SourceSchemaPath $schemaPath
    if($dryRun17.add -ne 1 -or $dryRun17.replace -ne 1 -or $dryRun17.remove -ne 1 -or $dryRun17.skip -ne 1){
        $failures.Add("Szenario 17: DryRun-Mix zeigt add=$($dryRun17.add)/replace=$($dryRun17.replace)/remove=$($dryRun17.remove)/skip=$($dryRun17.skip), erwartet 1/1/1/1.")
    }
    if($dryRun17.mutatesTarget){$failures.Add('Szenario 17: DryRun meldet mutatesTarget=true.')}
    if($dryRun17.pendingRemovals -ne 0){$failures.Add("Szenario 17: DryRun zeigt pendingRemovals=$($dryRun17.pendingRemovals), erwartet 0 (kein vorheriger fehlgeschlagener Cleanup).")}

    # Der Mix darf nicht real ausgeführt worden sein -- DryRun ist reine
    # Vorschau. state.json muss unverändert die ursprünglichen 3 Adds zeigen.
    $stateAfterDryRun17=Get-Content -LiteralPath $fixture17.StatePath -Raw|ConvertFrom-Json
    if(@($stateAfterDryRun17.entries).Count -ne 3){
        $failures.Add("Szenario 17: state.json enthält nach dem DryRun-Mix $(@($stateAfterDryRun17.entries).Count) Einträge, erwartet weiterhin 3 -- DryRun hat den Plan real ausgeführt.")
    }
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server17
    if(Test-Path -LiteralPath $fixture17.Root){Remove-Item -LiteralPath $fixture17.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 18 (AP06): a stalled Replace cleanup (AP02.5's pending-
# removal case) must be visible both in DryRun.pendingRemovals and in
# Status.pendingRemovals -- the same underlying value, read once via the
# shared Get-RAGPendingRemovals helper, surfaced by two different modes. --
$fixture18=New-RAGExecuteFixture -FileCount 1
$server18=$null
try{
    $server18=Start-RAGMockOpenWebUIServer -Fixture $fixture18
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture18.ConfigPath -SourcesPath $fixture18.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server18

    Set-Content -LiteralPath (Join-Path $fixture18.SourceRoot 'doc1.md') -Value "# Document 1`n`nChanged to trigger a pending removal." -Encoding utf8NoBOM
    New-Item -ItemType File -Path (Join-Path $fixture18.StateRoot 'fail-remove.marker') -Force|Out-Null
    $server18=Start-RAGMockOpenWebUIServer -Fixture $fixture18
    $threw18=$false
    try{Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture18.ConfigPath -SourcesPath $fixture18.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null}catch{$threw18=$true}
    Stop-RAGMockOpenWebUIServer -Process $server18
    if(-not$threw18){$failures.Add('Szenario 18: der induzierte Alt-Entfernungsfehler führte nicht zu einem Fehlschlag -- Testannahme verletzt.')}

    $dryRun18=Invoke-KIStackRAG -Mode DryRun -ConfigPath $fixture18.ConfigPath -SourcesPath $fixture18.SourcesPath -SourceSchemaPath $schemaPath
    if($dryRun18.pendingRemovals -ne 1){$failures.Add("Szenario 18: DryRun zeigt pendingRemovals=$($dryRun18.pendingRemovals), erwartet 1.")}

    $status18=Invoke-KIStackRAG -Mode Status -ConfigPath $fixture18.ConfigPath -SourcesPath $fixture18.SourcesPath -SourceSchemaPath $schemaPath
    if($status18.pendingRemovals -ne 1){$failures.Add("Szenario 18: Status zeigt pendingRemovals=$($status18.pendingRemovals), erwartet 1.")}
    if($status18.remoteReadbackPerformed){$failures.Add('Szenario 18: Status meldet remoteReadbackPerformed=true -- Status darf nie live gegen OpenWebUI lesen.')}
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server18
    if(Test-Path -LiteralPath $fixture18.Root){Remove-Item -LiteralPath $fixture18.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 19 (AP06): Status with no state.json at all yet. -----------
$fixture19=New-RAGExecuteFixture -FileCount 1
try{
    $status19=Invoke-KIStackRAG -Mode Status -ConfigPath $fixture19.ConfigPath -SourcesPath $fixture19.SourcesPath -SourceSchemaPath $schemaPath
    if($status19.statePresent){$failures.Add('Szenario 19: Status meldet statePresent=true ohne je ausgeführtes Execute.')}
    if(@($status19.entries).Count -ne 0){$failures.Add('Szenario 19: Status zeigt Einträge, obwohl kein State existiert.')}
    if($status19.pendingRemovals -ne 0){$failures.Add('Szenario 19: Status zeigt pendingRemovals ungleich 0 ohne State.')}
    if($status19.rollbackArchivePresent){$failures.Add('Szenario 19: Status meldet rollbackArchivePresent=true ohne je ausgeführtes Execute.')}
    if($null-ne$status19.knowledgeId){$failures.Add('Szenario 19: Status nennt eine knowledgeId ohne vorhandenen State.')}
    if($status19.remoteReadbackPerformed){$failures.Add('Szenario 19: Status meldet remoteReadbackPerformed=true.')}
}finally{
    if(Test-Path -LiteralPath $fixture19.Root){Remove-Item -LiteralPath $fixture19.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 20 (AP06): Status after a real Execute -> known entries from
# state.json and the just-written rollback-archive.json are both visible. -
$fixture20=New-RAGExecuteFixture -FileCount 2
$server20=$null
try{
    $server20=Start-RAGMockOpenWebUIServer -Fixture $fixture20
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture20.ConfigPath -SourcesPath $fixture20.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server20

    $status20=Invoke-KIStackRAG -Mode Status -ConfigPath $fixture20.ConfigPath -SourcesPath $fixture20.SourcesPath -SourceSchemaPath $schemaPath
    if(-not $status20.statePresent){$failures.Add('Szenario 20: Status meldet statePresent=false nach erfolgreichem Execute.')}
    if(@($status20.entries).Count -ne 2){$failures.Add("Szenario 20: Status zeigt $(@($status20.entries).Count) Einträge, erwartet 2.")}
    if($status20.entryCount -ne 2){$failures.Add("Szenario 20: Status.entryCount=$($status20.entryCount), erwartet 2.")}
    if([string]::IsNullOrEmpty($status20.knowledgeId)){$failures.Add('Szenario 20: Status nennt keine knowledgeId trotz vorhandenem State.')}
    if([string]::IsNullOrEmpty($status20.lastUpdatedAt)){$failures.Add('Szenario 20: Status nennt kein lastUpdatedAt trotz vorhandenem State.')}
    if(-not $status20.rollbackArchivePresent){$failures.Add('Szenario 20: Status meldet rollbackArchivePresent=false, obwohl Execute gerade erfolgreich lief.')}
    if($null-eq$status20.rollbackArchive -or [int]$status20.rollbackArchive.added -ne 2){
        $failures.Add("Szenario 20: Status.rollbackArchive.added=$($status20.rollbackArchive.added), erwartet 2.")
    }
    if($status20.remoteReadbackPerformed){$failures.Add('Szenario 20: Status meldet remoteReadbackPerformed=true -- state.json ist lokal, kein Live-Readback.')}
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server20
    if(Test-Path -LiteralPath $fixture20.Root){Remove-Item -LiteralPath $fixture20.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 21 (AP06): none of Audit/DryRun/Status ever perform a remote
# mutation -- proven directly, not inferred: the OpenWebUI endpoint points
# at a closed port with nothing listening, and all three still succeed.
# If any of them made a real HTTP call, it would fail fast against a
# refused connection instead of returning cleanly. ------------------------
$fixture21=New-RAGExecuteFixture -FileCount 1
$server21=$null
try{
    $server21=Start-RAGMockOpenWebUIServer -Fixture $fixture21
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture21.ConfigPath -SourcesPath $fixture21.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server21
    $server21=$null

    $threwAudit21=$false;$threwDryRun21=$false;$threwStatus21=$false
    try{Invoke-KIStackRAG -Mode Audit -ConfigPath $fixture21.ConfigPath -SourcesPath $fixture21.SourcesPath -SourceSchemaPath $schemaPath|Out-Null}catch{$threwAudit21=$true;$failures.Add("Szenario 21: Audit gegen einen nicht erreichbaren Endpoint warf einen Fehler ($($_.Exception.Message)) -- deutet auf einen unerwarteten Remote-Aufruf hin.")}
    try{Invoke-KIStackRAG -Mode DryRun -ConfigPath $fixture21.ConfigPath -SourcesPath $fixture21.SourcesPath -SourceSchemaPath $schemaPath|Out-Null}catch{$threwDryRun21=$true;$failures.Add("Szenario 21: DryRun gegen einen nicht erreichbaren Endpoint warf einen Fehler ($($_.Exception.Message)) -- deutet auf einen unerwarteten Remote-Aufruf hin.")}
    try{Invoke-KIStackRAG -Mode Status -ConfigPath $fixture21.ConfigPath -SourcesPath $fixture21.SourcesPath -SourceSchemaPath $schemaPath|Out-Null}catch{$threwStatus21=$true;$failures.Add("Szenario 21: Status gegen einen nicht erreichbaren Endpoint warf einen Fehler ($($_.Exception.Message)) -- deutet auf einen unerwarteten Remote-Aufruf hin.")}

    if(-not($threwAudit21 -or $threwDryRun21 -or $threwStatus21)){
        # Erwarteter Fall: alle drei liefen sauber durch, ohne den (jetzt
        # toten) Endpoint überhaupt zu kontaktieren.
    }
}finally{
    $env:PATH=$previousPath
    if($null-ne$server21){Stop-RAGMockOpenWebUIServer -Process $server21}
    if(Test-Path -LiteralPath $fixture21.Root){Remove-Item -LiteralPath $fixture21.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 22 (AP07): global embedding config already at RAG's target
# -> Set-RAGEmbeddingContract must not POST at all. -------------------------
$fixture22=New-RAGExecuteFixture -FileCount 1
$server22=$null
try{
    $targetUrl22="http://127.0.0.1:$($fixture22.Port)/v1"
    $server22=Start-RAGMockOpenWebUIServer -Fixture $fixture22 -InitialEmbeddingEngine 'openai' -InitialEmbeddingModel $embeddingModel -InitialEmbeddingUrl $targetUrl22 -InitialOpenAIKey ''
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture22.ConfigPath -SourcesPath $fixture22.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server22

    $updateCountPath22=Join-Path $fixture22.StateRoot 'mock-embedding-update-count.txt'
    $updateCount22=if(Test-Path -LiteralPath $updateCountPath22){[int](Get-Content -LiteralPath $updateCountPath22 -Raw)}else{0}
    if($updateCount22 -ne 0){$failures.Add("Szenario 22: Set-RAGEmbeddingContract hat trotz bereits aktivem Zielzustand $updateCount22 POST(s) an /embedding/update gesendet, erwartet 0.")}

    $transactionDirs22=@(Get-ChildItem -LiteralPath (Join-Path $fixture22.StateRoot 'transactions') -Directory)
    $embeddingBackup22=Get-Content -LiteralPath (Join-Path $transactionDirs22[0].FullName 'embedding-before.json') -Raw|ConvertFrom-Json
    if([bool]$embeddingBackup22.mutationPerformed){$failures.Add('Szenario 22: embedding-before.json markiert mutationPerformed=true, obwohl kein POST nötig war.')}
    if(@($embeddingBackup22.credentialFieldsPresent).Count -ne 0){$failures.Add('Szenario 22: embedding-before.json meldet Credential-Felder, obwohl der Fixture-Vorzustand keine gesetzt hatte.')}
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server22
    if(Test-Path -LiteralPath $fixture22.Root){Remove-Item -LiteralPath $fixture22.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 23 (AP07): mutation of a credential-free prior state, then a
# later failure in the same Execute -> automatic, full restore. -----------
$fixture23=New-RAGExecuteFixture -FileCount 1
$server23=$null
try{
    $server23=Start-RAGMockOpenWebUIServer -Fixture $fixture23 -FailOnUploadNumber 1 -InitialEmbeddingEngine 'ollama' -InitialEmbeddingModel 'some-other-model' -InitialEmbeddingUrl 'http://old-ollama-host:11434' -InitialOpenAIKey ''
    $env:PATH=$minimalWindowsPath
    $threw23=$false
    try{
        Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture23.ConfigPath -SourcesPath $fixture23.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    }catch{$threw23=$true}
    Stop-RAGMockOpenWebUIServer -Process $server23
    if(-not$threw23){$failures.Add('Szenario 23: der induzierte Upload-Fehler nach der Embedding-Mutation führte nicht zu einem Fehlschlag -- Testannahme verletzt.')}

    $transactionDirs23=@(Get-ChildItem -LiteralPath (Join-Path $fixture23.StateRoot 'transactions') -Directory)
    $failureRecord23=Get-Content -LiteralPath (Join-Path $transactionDirs23[0].FullName 'failure.json') -Raw|ConvertFrom-Json
    if([string]$failureRecord23.embeddingRestoreStatus -ne 'Restored'){
        $failures.Add("Szenario 23: failure.json zeigt embeddingRestoreStatus=$([string]$failureRecord23.embeddingRestoreStatus), erwartet 'Restored'.")
    }

    $mockEmbeddingStateAfter23=Get-Content -LiteralPath (Join-Path $fixture23.StateRoot 'mock-embedding-state.json') -Raw|ConvertFrom-Json
    if([string]$mockEmbeddingStateAfter23.RAG_EMBEDDING_ENGINE -ne 'ollama' -or [string]$mockEmbeddingStateAfter23.RAG_EMBEDDING_MODEL -ne 'some-other-model'){
        $failures.Add("Szenario 23: die globale Embedding-Konfiguration wurde nicht auf den ursprünglichen Vorzustand zurückgesetzt (engine=$([string]$mockEmbeddingStateAfter23.RAG_EMBEDDING_ENGINE), model=$([string]$mockEmbeddingStateAfter23.RAG_EMBEDDING_MODEL)).")
    }
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server23
    if(Test-Path -LiteralPath $fixture23.Root){Remove-Item -LiteralPath $fixture23.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 24 (AP07): prior state HAD a real credential -> a later
# Execute failure must NOT attempt a restore (that would silently produce a
# broken config with the credential lost), and no secret value may ever
# appear in any RAG-owned JSON artifact. ------------------------------------
$fakeSecret24='sk-FAKE-TEST-SECRET-DO-NOT-PERSIST-7f3a2b'
$fixture24=New-RAGExecuteFixture -FileCount 1
$server24=$null
try{
    $server24=Start-RAGMockOpenWebUIServer -Fixture $fixture24 -FailOnUploadNumber 1 -InitialEmbeddingEngine 'openai' -InitialEmbeddingModel 'gpt-real-model' -InitialEmbeddingUrl 'https://api.openai.example/v1' -InitialOpenAIKey $fakeSecret24
    $env:PATH=$minimalWindowsPath
    $threw24=$false
    try{
        Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture24.ConfigPath -SourcesPath $fixture24.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    }catch{$threw24=$true}
    Stop-RAGMockOpenWebUIServer -Process $server24
    if(-not$threw24){$failures.Add('Szenario 24: der induzierte Upload-Fehler nach der Embedding-Mutation führte nicht zu einem Fehlschlag -- Testannahme verletzt.')}

    $transactionDirs24=@(Get-ChildItem -LiteralPath (Join-Path $fixture24.StateRoot 'transactions') -Directory)
    $failureRecord24=Get-Content -LiteralPath (Join-Path $transactionDirs24[0].FullName 'failure.json') -Raw|ConvertFrom-Json
    if([string]$failureRecord24.embeddingRestoreStatus -ne 'EmbeddingRestoreRequiresManualAction'){
        $failures.Add("Szenario 24: failure.json zeigt embeddingRestoreStatus=$([string]$failureRecord24.embeddingRestoreStatus), erwartet 'EmbeddingRestoreRequiresManualAction'.")
    }
    if([string]$failureRecord24.embeddingPreviousEngine -ne 'openai' -or [string]$failureRecord24.embeddingPreviousModel -ne 'gpt-real-model'){
        $failures.Add('Szenario 24: failure.json nennt nicht den korrekten vorherigen Provider/Engine/Model.')
    }

    # Kein destruktives Teil-Restore: die globale Konfiguration muss bei
    # RAGs eigenem Zielzustand verbleiben, nicht bei irgendeinem kaputten
    # Zwischenzustand mit leerem Key.
    $mockEmbeddingStateAfter24=Get-Content -LiteralPath (Join-Path $fixture24.StateRoot 'mock-embedding-state.json') -Raw|ConvertFrom-Json
    if([string]$mockEmbeddingStateAfter24.RAG_EMBEDDING_ENGINE -ne 'openai' -or [string]$mockEmbeddingStateAfter24.openai_config.url -ne "http://127.0.0.1:$($fixture24.Port)/v1"){
        $failures.Add('Szenario 24: die globale Embedding-Konfiguration wurde nach dem blockierten Restore verändert -- sie muss bei RAGs eigenem Zielzustand bleiben.')
    }

    $ragOwnedJsonFiles24=@(Get-ChildItem -LiteralPath $fixture24.StateRoot -Recurse -File -Filter '*.json'|Where-Object{$_.Name -notlike 'mock-*'})
    $leaked24=@($ragOwnedJsonFiles24|Where-Object{(Get-Content -LiteralPath $_.FullName -Raw) -match [regex]::Escape($fakeSecret24)})
    if($leaked24.Count -gt 0){
        $failures.Add("Szenario 24: das Test-Secret erscheint in RAG-eigenen JSON-Artefakten: $(($leaked24|ForEach-Object{$_.FullName}) -join '; ')")
    }
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server24
    if(Test-Path -LiteralPath $fixture24.Root){Remove-Item -LiteralPath $fixture24.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 25 (AP07): successful Rollback with a safely restorable
# (credential-free) prior embedding state -> restored as part of Rollback. -
$fixture25=New-RAGExecuteFixture -FileCount 1
$server25=$null
try{
    $server25=Start-RAGMockOpenWebUIServer -Fixture $fixture25 -InitialEmbeddingEngine 'ollama' -InitialEmbeddingModel 'prior-model-25' -InitialEmbeddingUrl 'http://old-ollama-host:11434' -InitialOpenAIKey ''
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture25.ConfigPath -SourcesPath $fixture25.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server25

    $server25=Start-RAGMockOpenWebUIServer -Fixture $fixture25
    $rollback25=Invoke-KIStackRAG -Mode Rollback -ConfigPath $fixture25.ConfigPath -SourcesPath $fixture25.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken
    Stop-RAGMockOpenWebUIServer -Process $server25

    if(-not $rollback25.passed){$failures.Add('Szenario 25: Rollback meldete passed=false.')}
    if([string]$rollback25.embeddingRestoreStatus -ne 'Restored'){
        $failures.Add("Szenario 25: Rollback.embeddingRestoreStatus=$([string]$rollback25.embeddingRestoreStatus), erwartet 'Restored'.")
    }
    $mockEmbeddingStateAfter25=Get-Content -LiteralPath (Join-Path $fixture25.StateRoot 'mock-embedding-state.json') -Raw|ConvertFrom-Json
    if([string]$mockEmbeddingStateAfter25.RAG_EMBEDDING_ENGINE -ne 'ollama' -or [string]$mockEmbeddingStateAfter25.RAG_EMBEDDING_MODEL -ne 'prior-model-25'){
        $failures.Add('Szenario 25: die globale Embedding-Konfiguration wurde durch Rollback nicht auf den ursprünglichen Vorzustand zurückgesetzt.')
    }
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server25
    if(Test-Path -LiteralPath $fixture25.Root){Remove-Item -LiteralPath $fixture25.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 26 (AP07): successful Rollback where the embedding prior
# state is NOT safely reconstructable (a credential was present) -> file
# rollback still succeeds, but embedding is left alone with an explicit
# manual-action status -- never a destructive partial restore, and no
# secret anywhere in any RAG-owned JSON artifact. ---------------------------
$fakeSecret26='sk-FAKE-TEST-SECRET-DO-NOT-PERSIST-9c41e0'
$fixture26=New-RAGExecuteFixture -FileCount 1
$server26=$null
try{
    $server26=Start-RAGMockOpenWebUIServer -Fixture $fixture26 -InitialEmbeddingEngine 'openai' -InitialEmbeddingModel 'gpt-real-model-26' -InitialEmbeddingUrl 'https://api.openai.example/v1' -InitialOpenAIKey $fakeSecret26
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture26.ConfigPath -SourcesPath $fixture26.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server26

    $server26=Start-RAGMockOpenWebUIServer -Fixture $fixture26
    $rollback26=Invoke-KIStackRAG -Mode Rollback -ConfigPath $fixture26.ConfigPath -SourcesPath $fixture26.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken
    Stop-RAGMockOpenWebUIServer -Process $server26

    if(-not $rollback26.passed){$failures.Add('Szenario 26: Rollback meldete passed=false -- die Datei-Rückrollung darf vom Embedding-Sonderfall unabhängig gelingen.')}
    if([string]$rollback26.embeddingRestoreStatus -ne 'EmbeddingRestoreRequiresManualAction'){
        $failures.Add("Szenario 26: Rollback.embeddingRestoreStatus=$([string]$rollback26.embeddingRestoreStatus), erwartet 'EmbeddingRestoreRequiresManualAction'.")
    }
    if([string]$rollback26.embeddingPreviousEngine -ne 'openai' -or [string]$rollback26.embeddingPreviousModel -ne 'gpt-real-model-26'){
        $failures.Add('Szenario 26: Rollback nennt nicht den korrekten vorherigen Provider/Engine/Model.')
    }

    $ragOwnedJsonFiles26=@(Get-ChildItem -LiteralPath $fixture26.StateRoot -Recurse -File -Filter '*.json'|Where-Object{$_.Name -notlike 'mock-*'})
    $leaked26=@($ragOwnedJsonFiles26|Where-Object{(Get-Content -LiteralPath $_.FullName -Raw) -match [regex]::Escape($fakeSecret26)})
    if($leaked26.Count -gt 0){
        $failures.Add("Szenario 26: das Test-Secret erscheint in RAG-eigenen JSON-Artefakten: $(($leaked26|ForEach-Object{$_.FullName}) -join '; ')")
    }
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server26
    if(Test-Path -LiteralPath $fixture26.Root){Remove-Item -LiteralPath $fixture26.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 27 (AP01, 2.6.0): Replace-Rollback fails partway through a
# multi-entry restore -> the entry already restored is persisted and never
# re-touched; a retry finishes only the remaining entry's restore, without
# re-issuing a remove against remote content a prior attempt already
# deleted. Mirrors Scenario 13's pattern against the restore-upload path
# specifically (Scenario 13 only ever exercised the plain-delete/Add path). -
$fixture27=New-RAGExecuteFixture -FileCount 2
$server27=$null
try{
    $server27=Start-RAGMockOpenWebUIServer -Fixture $fixture27
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture27.ConfigPath -SourcesPath $fixture27.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server27
    $originalHash27=@{
        'doc1.md'=(Get-FileHash -LiteralPath (Join-Path $fixture27.SourceRoot 'doc1.md') -Algorithm SHA256).Hash.ToLowerInvariant()
        'doc2.md'=(Get-FileHash -LiteralPath (Join-Path $fixture27.SourceRoot 'doc2.md') -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    Set-Content -LiteralPath (Join-Path $fixture27.SourceRoot 'doc1.md') -Value "# Document 1`n`nReplaced content 1 for partial-rollback test." -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $fixture27.SourceRoot 'doc2.md') -Value "# Document 2`n`nReplaced content 2 for partial-rollback test." -Encoding utf8NoBOM
    $server27=Start-RAGMockOpenWebUIServer -Fixture $fixture27
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture27.ConfigPath -SourcesPath $fixture27.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server27
    $manifest27=Get-Content -LiteralPath (Join-Path $fixture27.StateRoot 'rollback-archive.json') -Raw|ConvertFrom-Json
    if(@($manifest27.replaced).Count -ne 2){$failures.Add("Szenario 27: rollback-archive.json listet $(@($manifest27.replaced).Count) Replace-Einträge, erwartet 2 -- Testannahme verletzt.")}

    # Der zweite Restore-Upload (das zweite von zwei Rollback-Elementen) wird
    # induziert zum Scheitern gebracht -- der erste Restore-Upload (Upload 1)
    # muss dabei bereits durchlaufen sein.
    $server27=Start-RAGMockOpenWebUIServer -Fixture $fixture27 -FailOnUploadNumber 2
    $threw27=$false
    try{
        Invoke-KIStackRAG -Mode Rollback -ConfigPath $fixture27.ConfigPath -SourcesPath $fixture27.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    }catch{$threw27=$true}
    Stop-RAGMockOpenWebUIServer -Process $server27
    if(-not$threw27){$failures.Add('Szenario 27: induzierter Fehler beim zweiten Restore-Upload führte nicht zu einem Fehlschlag.')}

    $stateAfterPartial27=Get-Content -LiteralPath $fixture27.StatePath -Raw|ConvertFrom-Json
    $restoredNow27=@($stateAfterPartial27.entries|Where-Object{[string]$_.file_sha256 -in $originalHash27.Values})
    if(@($restoredNow27).Count -ne 1){
        $failures.Add("Szenario 27: nach dem Teil-Rollback zeigen $(@($restoredNow27).Count) Einträge bereits den ursprünglichen Hash, erwartet genau 1 (ein Element erfolgreich zurückgerollt, das andere blieb wegen des induzierten Fehlers stehen).")
    }
    $partiallyRestoredKey27=if(@($restoredNow27).Count -eq 1){[string]$restoredNow27[0].key}else{$null}
    $partiallyRestoredFileId27=if(@($restoredNow27).Count -eq 1){[string]$restoredNow27[0].chunks[0].file_id}else{$null}

    # Retry: ohne induzierten Fehler muss das verbleibende Element fertig
    # zurückgerollt werden, ohne das bereits erledigte erneut anzufassen und
    # ohne gegen bereits entfernten Remote-Inhalt einen erneuten Remove-
    # Aufruf abzusetzen (das würde am realen Server als 400 fehlschlagen --
    # der Mock bildet das jetzt nach).
    $server27=Start-RAGMockOpenWebUIServer -Fixture $fixture27
    $retryRollback27=$null;$retryThrew27=$false;$retryMessage27=''
    try{
        $retryRollback27=Invoke-KIStackRAG -Mode Rollback -ConfigPath $fixture27.ConfigPath -SourcesPath $fixture27.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken
    }catch{$retryThrew27=$true;$retryMessage27=$_.Exception.Message}
    Stop-RAGMockOpenWebUIServer -Process $server27

    if($retryThrew27){
        $failures.Add("Szenario 27: Retry-Rollback des Replace-Restore-Pfads schlug fehl statt nur die offene Recovery fortzusetzen: $retryMessage27")
    } else {
        if(-not $retryRollback27.passed){$failures.Add('Szenario 27: Retry-Rollback meldete passed=false.')}
        if(@($retryRollback27.rolledBack).Count -ne 1){$failures.Add("Szenario 27: Retry-Rollback hat $(@($retryRollback27.rolledBack).Count) Elemente zurückgerollt, erwartet genau 1 (nur das zuvor fehlgeschlagene).")}
        if(@($retryRollback27.alreadyClean).Count -ne 1){$failures.Add('Szenario 27: Retry-Rollback meldet nicht das bereits im ersten Versuch erledigte Element als bereits bereinigt.')}
        $stateAfterRetry27=Get-Content -LiteralPath $fixture27.StatePath -Raw|ConvertFrom-Json
        if(@($stateAfterRetry27.entries).Count -ne 2){$failures.Add('Szenario 27: state.json enthält nach dem abschließenden Retry-Rollback nicht beide Einträge.')}
        foreach($entry in @($stateAfterRetry27.entries)){
            if([string]$entry.file_sha256 -notin $originalHash27.Values){
                $failures.Add("Szenario 27: Eintrag $([string]$entry.relative_path) zeigt nach dem vollständigen Rollback nicht den ursprünglichen Hash.")
            }
        }
        if($null-ne$partiallyRestoredKey27){
            $unchangedEntry27=$stateAfterRetry27.entries|Where-Object{[string]$_.key -eq $partiallyRestoredKey27}
            if($null-eq$unchangedEntry27 -or [string]$unchangedEntry27.chunks[0].file_id -ne $partiallyRestoredFileId27){
                $failures.Add('Szenario 27: das bereits im ersten Versuch wiederhergestellte Element wurde beim Retry erneut angefasst (file_id hat sich verändert -- doppelte Arbeit statt reiner Fortsetzung).')
            }
        }
    }
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server27
    if(Test-Path -LiteralPath $fixture27.Root){Remove-Item -LiteralPath $fixture27.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Scenario 28 (AP01, 2.6.0): Remove-Rollback fails partway through a
# multi-entry restore -> same pattern as Scenario 27, for the Remove-restore
# path (re-upload of previously deleted content, no remote removal step
# involved on this path at all). ------------------------------------------
$fixture28=New-RAGExecuteFixture -FileCount 2
$server28=$null
try{
    $server28=Start-RAGMockOpenWebUIServer -Fixture $fixture28
    $env:PATH=$minimalWindowsPath
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture28.ConfigPath -SourcesPath $fixture28.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server28
    $originalHash28=@{
        'doc1.md'=(Get-FileHash -LiteralPath (Join-Path $fixture28.SourceRoot 'doc1.md') -Algorithm SHA256).Hash.ToLowerInvariant()
        'doc2.md'=(Get-FileHash -LiteralPath (Join-Path $fixture28.SourceRoot 'doc2.md') -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    Remove-Item -LiteralPath (Join-Path $fixture28.SourceRoot 'doc1.md') -Force
    Remove-Item -LiteralPath (Join-Path $fixture28.SourceRoot 'doc2.md') -Force
    $server28=Start-RAGMockOpenWebUIServer -Fixture $fixture28
    Invoke-KIStackRAG -Mode Execute -ConfigPath $fixture28.ConfigPath -SourcesPath $fixture28.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    Stop-RAGMockOpenWebUIServer -Process $server28
    $manifest28=Get-Content -LiteralPath (Join-Path $fixture28.StateRoot 'rollback-archive.json') -Raw|ConvertFrom-Json
    if(@($manifest28.removed).Count -ne 2){$failures.Add("Szenario 28: rollback-archive.json listet $(@($manifest28.removed).Count) Remove-Einträge, erwartet 2 -- Testannahme verletzt.")}

    $server28=Start-RAGMockOpenWebUIServer -Fixture $fixture28 -FailOnUploadNumber 2
    $threw28=$false
    try{
        Invoke-KIStackRAG -Mode Rollback -ConfigPath $fixture28.ConfigPath -SourcesPath $fixture28.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken|Out-Null
    }catch{$threw28=$true}
    Stop-RAGMockOpenWebUIServer -Process $server28
    if(-not$threw28){$failures.Add('Szenario 28: induzierter Fehler beim zweiten Restore-Upload führte nicht zu einem Fehlschlag.')}

    $stateAfterPartial28=Get-Content -LiteralPath $fixture28.StatePath -Raw|ConvertFrom-Json
    if(@($stateAfterPartial28.entries).Count -ne 1){
        $failures.Add("Szenario 28: nach dem Teil-Rollback enthält state.json $(@($stateAfterPartial28.entries).Count) Einträge, erwartet 1 (ein Element erfolgreich wiederhergestellt, das andere blieb wegen des induzierten Fehlers stehen).")
    }
    $partiallyRestoredFileId28=if(@($stateAfterPartial28.entries).Count -eq 1){[string]$stateAfterPartial28.entries[0].chunks[0].file_id}else{$null}
    $partiallyRestoredKey28=if(@($stateAfterPartial28.entries).Count -eq 1){[string]$stateAfterPartial28.entries[0].key}else{$null}

    $server28=Start-RAGMockOpenWebUIServer -Fixture $fixture28
    $retryRollback28=$null;$retryThrew28=$false;$retryMessage28=''
    try{
        $retryRollback28=Invoke-KIStackRAG -Mode Rollback -ConfigPath $fixture28.ConfigPath -SourcesPath $fixture28.SourcesPath -SourceSchemaPath $schemaPath -ApiToken $plainToken
    }catch{$retryThrew28=$true;$retryMessage28=$_.Exception.Message}
    Stop-RAGMockOpenWebUIServer -Process $server28

    if($retryThrew28){
        $failures.Add("Szenario 28: Retry-Rollback des Remove-Restore-Pfads schlug fehl statt nur die offene Recovery fortzusetzen: $retryMessage28")
    } else {
        if(-not $retryRollback28.passed){$failures.Add('Szenario 28: Retry-Rollback meldete passed=false.')}
        if(@($retryRollback28.rolledBack).Count -ne 1){$failures.Add("Szenario 28: Retry-Rollback hat $(@($retryRollback28.rolledBack).Count) Elemente zurückgerollt, erwartet genau 1 (nur das zuvor fehlgeschlagene).")}
        if(@($retryRollback28.alreadyClean).Count -ne 1){$failures.Add('Szenario 28: Retry-Rollback meldet nicht das bereits im ersten Versuch erledigte Element als bereits bereinigt.')}
        $stateAfterRetry28=Get-Content -LiteralPath $fixture28.StatePath -Raw|ConvertFrom-Json
        if(@($stateAfterRetry28.entries).Count -ne 2){$failures.Add('Szenario 28: state.json enthält nach dem abschließenden Retry-Rollback nicht beide wiederhergestellten Einträge.')}
        foreach($entry in @($stateAfterRetry28.entries)){
            if([string]$entry.file_sha256 -notin $originalHash28.Values){
                $failures.Add("Szenario 28: Eintrag $([string]$entry.relative_path) zeigt nach dem vollständigen Rollback nicht den ursprünglichen Hash.")
            }
        }
        if($null-ne$partiallyRestoredKey28){
            $unchangedEntry28=$stateAfterRetry28.entries|Where-Object{[string]$_.key -eq $partiallyRestoredKey28}
            if($null-eq$unchangedEntry28 -or [string]$unchangedEntry28.chunks[0].file_id -ne $partiallyRestoredFileId28){
                $failures.Add('Szenario 28: das bereits im ersten Versuch wiederhergestellte Element wurde beim Retry erneut angefasst (file_id hat sich verändert -- doppelte Arbeit statt reiner Fortsetzung).')
            }
        }
    }
}finally{
    $env:PATH=$previousPath
    Stop-RAGMockOpenWebUIServer -Process $server28
    if(Test-Path -LiteralPath $fixture28.Root){Remove-Item -LiteralPath $fixture28.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

$result=[pscustomobject]@{passed=($failures.Count-eq0);checks=28;failures=@($failures)}
$result|ConvertTo-Json -Depth 10
if(-not$result.passed){exit 1}

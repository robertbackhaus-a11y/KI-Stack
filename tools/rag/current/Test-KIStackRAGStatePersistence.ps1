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
param([int]$Port,[int]$RequestCount,[string]$StateDir,[string]$KnowledgeId,[string]$EmbeddingModel,[int]$FailOnUploadNumber=-1)
Set-StrictMode -Version Latest
$uploadCounter=0
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
            Send-MockJsonResponse $stream 200 "{`"RAG_EMBEDDING_ENGINE`":`"openai`",`"RAG_EMBEDDING_MODEL`":`"$EmbeddingModel`",`"RAG_EMBEDDING_BATCH_SIZE`":1,`"ENABLE_ASYNC_EMBEDDING`":true,`"RAG_EMBEDDING_CONCURRENT_REQUESTS`":1,`"openai_config`":{`"url`":`"fixture`"}}"
        }
        elseif($req.Method -eq 'POST' -and $path -eq '/api/v1/retrieval/embedding/update'){
            Send-MockJsonResponse $stream 200 '{}'
        }
        elseif($req.Method -eq 'POST' -and $path -eq '/api/v1/files/'){
            $uploadCounter++
            if($uploadCounter -eq $FailOnUploadNumber){
                Send-MockJsonResponse $stream 500 '{"error":"fixture induced upload failure"}'
            } else {
                Send-MockJsonResponse $stream 200 "{`"id`":`"file-$uploadCounter`"}"
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
            if(Test-Path -LiteralPath (Join-Path $StateDir 'fail-remove.marker')){
                Send-MockJsonResponse $stream 500 '{"error":"fixture induced remove failure"}'
            } else {
                Send-MockJsonResponse $stream 200 '{}'
            }
        }
        else{
            Send-MockJsonResponse $stream 404 '{"error":"unmapped fixture route"}'
        }
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
    param([Parameter(Mandatory)]$Fixture,[int]$RequestCount=20,[int]$FailOnUploadNumber=-1)
    $proc=Start-Process -FilePath 'powershell' -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$Fixture.MockScript,
        '-Port',$Fixture.Port,'-RequestCount',$RequestCount,'-StateDir',$Fixture.StateRoot,
        '-KnowledgeId',$knowledgeId,'-EmbeddingModel',$embeddingModel,'-FailOnUploadNumber',$FailOnUploadNumber
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

$result=[pscustomobject]@{passed=($failures.Count-eq0);checks=9;failures=@($failures)}
$result|ConvertTo-Json -Depth 10
if(-not$result.passed){exit 1}

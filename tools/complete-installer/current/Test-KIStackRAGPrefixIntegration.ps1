[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$failures=[Collections.Generic.List[string]]::new()

# Regression: rag.config.json must be the single source of truth for the
# search_document:/search_query: embedding prefixes. Previously
# Install-KICompleteRAGModule wrote independently hardcoded literals into
# OpenWebUI-RAG.env.cmd regardless of what rag.config.json actually said.
# This exercises the real function against a fixture with deliberately
# non-default prefix values and asserts those (not the old hardcoded
# strings) end up in the generated environment file.

Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force

$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-RAGPrefix-'+[guid]::NewGuid().ToString('N').Substring(0,8))
try{
    $componentRoot=Join-Path $fixtureRoot 'component'
    $targetRoot=Join-Path $fixtureRoot 'target'
    $backupRoot=Join-Path $fixtureRoot 'backup'
    New-Item -ItemType Directory -Path (Join-Path $componentRoot 'Config') -Force|Out-Null
    New-Item -ItemType Directory -Path (Join-Path $targetRoot 'modules/integration') -Force|Out-Null

    $customDocumentPrefix='custom_document_prefix: '
    $customQueryPrefix='custom_query_prefix: '
    $ragConfig=[ordered]@{
        schemaVersion='1.0';version='0.2.0';targetRoot=$targetRoot;moduleRoot=(Join-Path $targetRoot 'modules/rag')
        stateRoot=(Join-Path $targetRoot 'state/rag');sourceRoot=(Join-Path $targetRoot 'data/rag/sources')
        embeddingProvider='lmstudio';embeddingBaseUrl='http://127.0.0.1:1234/v1';embeddingModel='text-embedding-nomic-embed-text-v1.5'
        documentPrefix=$customDocumentPrefix;queryPrefix=$customQueryPrefix;vectorStore='openwebui-managed'
        openWebUIEndpoint='http://127.0.0.1:8080';knowledgeName='Fixture Knowledge';knowledgeDescription='fixture'
        chunkCharacters=6000;chunkOverlapCharacters=600;parserVersion='fixture-1'
        allowedExtensions=@('.md');excludedDirectoryNames=@('node_modules')
        metadataFields=@('source_id')
    }
    ($ragConfig|ConvertTo-Json -Depth 10)|Set-Content -LiteralPath (Join-Path $componentRoot 'Config/rag.config.json') -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $componentRoot 'placeholder.txt') -Value 'fixture' -Encoding ascii

    # Install-KICompleteRAGModule requires the OpenWebUI integration starter
    # to already exist (it wires OpenWebUI-RAG.env.cmd into it).
    $starterPath=Join-Path $targetRoot 'modules/integration/Start-KIStack-OpenWebUI-WithSearch.cmd'
    Set-Content -LiteralPath $starterPath -Encoding ascii -Value @('@echo off','echo fixture starter')

    $result=Install-KICompleteRAGModule -ComponentRoot $componentRoot -TargetRoot $targetRoot -BackupRoot $backupRoot
    if(-not [bool]$result.passed){$failures.Add('Install-KICompleteRAGModule meldete keinen Erfolg.')}

    $envPath=Join-Path $targetRoot 'modules/rag/OpenWebUI-RAG.env.cmd'
    if(-not(Test-Path -LiteralPath $envPath -PathType Leaf)){
        $failures.Add('OpenWebUI-RAG.env.cmd wurde nicht erzeugt.')
    } else {
        $envContent=Get-Content -LiteralPath $envPath -Raw
        if(-not $envContent.Contains("RAG_EMBEDDING_CONTENT_PREFIX=$customDocumentPrefix")){$failures.Add('Dokumentpräfix aus rag.config.json wurde nicht übernommen.')}
        if(-not $envContent.Contains("RAG_EMBEDDING_QUERY_PREFIX=$customQueryPrefix")){$failures.Add('Querypräfix aus rag.config.json wurde nicht übernommen.')}
        if($envContent.Contains('search_document: ')-or$envContent.Contains('search_query: ')){$failures.Add('Alte hartcodierte Default-Präfixe sind trotz abweichender Konfiguration noch vorhanden.')}
    }

    $starterContent=Get-Content -LiteralPath $starterPath -Raw
    if(-not $starterContent.Contains('OpenWebUI-RAG.env.cmd')){$failures.Add('OpenWebUI-Starter ruft die generierte Environment-Datei nicht auf.')}
}finally{
    if(Test-Path -LiteralPath $fixtureRoot){Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue}
}

$result=[pscustomobject]@{passed=($failures.Count-eq0);checks=4;failures=@($failures)}
$result|ConvertTo-Json -Depth 10
if(-not$result.passed){exit 1}

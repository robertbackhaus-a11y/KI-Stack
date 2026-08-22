#Requires -Version 7.0
[CmdletBinding()]param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$failures=[Collections.Generic.List[string]]::new()
foreach($path in @('VERSION','Config/rag.config.json','Config/sources.json','Contracts/source.schema.json','KIStackRAG.psm1','Invoke-KIStackRAG.ps1','README.md')){
    if(-not(Test-Path -LiteralPath (Join-Path $PackageRoot $path) -PathType Leaf)){$failures.Add("Fehlt: $path")}
}
$config=Get-Content -LiteralPath (Join-Path $PackageRoot 'Config/rag.config.json') -Raw|ConvertFrom-Json
if($config.version-ne(Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim()){$failures.Add('Versionsvertrag inkonsistent.')}
if($config.embeddingModel-notmatch'nomic'){$failures.Add('Nomic-Vertrag fehlt.')}
if($config.documentPrefix-ne'search_document: '){$failures.Add('Dokumentpräfix ist falsch.')}
if($config.queryPrefix-ne'search_query: '){$failures.Add('Querypräfix ist falsch.')}
if($config.chunkCharacters-le$config.chunkOverlapCharacters){$failures.Add('Chunkvertrag ist ungültig.')}
$moduleText=Get-Content -LiteralPath (Join-Path $PackageRoot 'KIStackRAG.psm1') -Raw
foreach($contract in @('/api/v1/knowledge/','/api/v1/knowledge/create','/api/v1/files/?process=true&process_in_background=false','files/batch/add','file/remove?delete_file=true','/api/v1/retrieval/embedding','/api/v1/retrieval/embedding/update')){
    if(-not$moduleText.Contains($contract)){$failures.Add("OpenWebUI-Vertrag fehlt: $contract")}
}
if($moduleText-match'(?i)api[_-]?key\s*=.*ConvertFrom-RAGSecureString'){$failures.Add('API-Key darf nicht persistiert werden.')}
$required=@('source_id','source_type','project','relative_path','file_name','file_sha256','document_version','section','chunk_index','imported_at','modified_at','content_language','visibility','parser_version')
foreach($field in $required){if(@($config.metadataFields)-notcontains$field){$failures.Add("Metadatenfeld fehlt: $field")}}
$result=[pscustomobject]@{passed=($failures.Count-eq0);version=[string]$config.version;failures=@($failures);openWebUIContract='0.11.0';mutatesTarget=$false}
$result|ConvertTo-Json -Depth 20
if(-not$result.passed){exit 1}

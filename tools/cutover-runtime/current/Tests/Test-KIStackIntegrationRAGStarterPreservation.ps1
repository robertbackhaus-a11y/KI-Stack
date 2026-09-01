[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

# Regression: Install-KIModuleIntegration unconditionally regenerates
# Start-KIStack-OpenWebUI-WithSearch.cmd from a hardcoded template on every
# Install/Upgrade/Repair pass. RAG (tools/rag/current, a separately-versioned,
# later-ordered component -- see Contracts/COMPONENTS.json order 60 vs 150)
# patches this exact same file once to source its own OpenWebUI-RAG.env.cmd,
# which sets the search_document:/search_query: embedding prefix contract via
# OpenWebUI's own native RAG_EMBEDDING_CONTENT_PREFIX/RAG_EMBEDDING_QUERY_PREFIX
# environment variables. A later Integration-only reconciliation (RAG already
# compliant, not re-run in that same transaction) blindly overwrote the
# starter and silently erased RAG's line -- confirmed as a live regression on
# the real target (C:\KI-Stack): OpenWebUI-RAG.env.cmd predates the starter's
# last rewrite by a full day. Get-KIIntegrationOpenWebUIWithSearchStarterContent
# now preserves an already-applied RAG env-call line across every regeneration.
$module=Import-Module (Join-Path $ProjectRoot 'Modules/07-Integration/KIModuleIntegration.psm1') -Force -PassThru -DisableNameChecking
try{
    $applicationStarter='D:\Local AI\KI Stack\modules\applications\Start-KIStack-OpenWebUI.cmd'
    $ragCallLine='call "C:\KI-Stack\modules\rag\OpenWebUI-RAG.env.cmd"'
    $existingWithRag=@"
@echo off
setlocal EnableExtensions DisableDelayedExpansion
$ragCallLine
set "ENABLE_WEB_SEARCH=True"
set "WEB_SEARCH_ENGINE=searxng"
set "WEB_SEARCH_RESULT_COUNT=5"
set "WEB_SEARCH_CONCURRENT_REQUESTS=3"
set "WEB_LOADER_CONCURRENT_REQUESTS=5"
set "SEARXNG_QUERY_URL=http://localhost/searxng/search?q=<query>"
call "C:\KI-Stack\modules\applications\Start-KIStack-OpenWebUI.cmd"
exit /b %ERRORLEVEL%
"@

    # A. RAG already patched the starter (steady state after RAG installed
    #    at least once) -- a fresh Integration regeneration must preserve
    #    the exact RAG env-call line, immediately after @echo off, while
    #    still applying the current Integration config values.
    $regeneratedWithRag=Get-KIIntegrationOpenWebUIWithSearchStarterContent -ResultCount '7' -SearchConcurrency '4' -LoaderConcurrency '6' -QueryUrl 'http://localhost/searxng/search?q=<query>' -ApplicationStarterPath $applicationStarter -ExistingContent $existingWithRag
    $checks.ragLinePreservedAcrossRegeneration=[ordered]@{
        containsRagCall=$regeneratedWithRag.Contains($ragCallLine)
        ragCallImmediatelyAfterEchoOff=([regex]::IsMatch($regeneratedWithRag,'(?im)^@echo off\r?\n'+[regex]::Escape($ragCallLine)+'\r?\n'))
        onlyOneRagCall=(@([regex]::Matches($regeneratedWithRag,[regex]::Escape($ragCallLine))).Count-eq1)
        currentConfigValuesApplied=($regeneratedWithRag.Contains('WEB_SEARCH_RESULT_COUNT=7')-and$regeneratedWithRag.Contains('WEB_SEARCH_CONCURRENT_REQUESTS=4')-and$regeneratedWithRag.Contains('WEB_LOADER_CONCURRENT_REQUESTS=6'))
    }
    if($checks.ragLinePreservedAcrossRegeneration.Values-contains$false){$fail.Add('Check A (RagLinePreservedAcrossRegeneration) failed: '+($checks.ragLinePreservedAcrossRegeneration|ConvertTo-Json -Compress)+' | content: '+$regeneratedWithRag)}

    # B. Fresh install / RAG never installed -- no RAG line exists yet, so
    #    none must be fabricated; the plain Integration-owned template is
    #    produced unchanged (no regression on the greenfield path).
    $regeneratedWithoutRag=Get-KIIntegrationOpenWebUIWithSearchStarterContent -ResultCount '5' -SearchConcurrency '3' -LoaderConcurrency '5' -QueryUrl 'http://localhost/searxng/search?q=<query>' -ApplicationStarterPath $applicationStarter -ExistingContent $null
    $checks.noRagLineFabricatedOnFreshInstall=[ordered]@{
        noRagCall=(-not$regeneratedWithoutRag.Contains('OpenWebUI-RAG.env.cmd'))
        startsWithEchoOff=$regeneratedWithoutRag.StartsWith('@echo off')
    }
    if($checks.noRagLineFabricatedOnFreshInstall.Values-contains$false){$fail.Add('Check B (NoRagLineFabricatedOnFreshInstall) failed: '+($checks.noRagLineFabricatedOnFreshInstall|ConvertTo-Json -Compress)+' | content: '+$regeneratedWithoutRag)}

    # C. Re-running regeneration a second time against its own prior output
    #    (idempotency: no duplicate/doubled call line across repeated
    #    Integration reconciliations).
    $regeneratedTwice=Get-KIIntegrationOpenWebUIWithSearchStarterContent -ResultCount '7' -SearchConcurrency '4' -LoaderConcurrency '6' -QueryUrl 'http://localhost/searxng/search?q=<query>' -ApplicationStarterPath $applicationStarter -ExistingContent $regeneratedWithRag
    $checks.idempotentAcrossRepeatedRegeneration=[ordered]@{
        onlyOneRagCall=(@([regex]::Matches($regeneratedTwice,[regex]::Escape($ragCallLine))).Count-eq1)
        identicalToFirstRegeneration=($regeneratedTwice-eq$regeneratedWithRag)
    }
    if($checks.idempotentAcrossRepeatedRegeneration.Values-contains$false){$fail.Add('Check C (IdempotentAcrossRepeatedRegeneration) failed: '+($checks.idempotentAcrossRepeatedRegeneration|ConvertTo-Json -Compress)+' | content: '+$regeneratedTwice)}

    # D. A differently-pathed/quoted RAG call line already present (e.g. an
    #    older or manually-adjusted install path) is still recognized and
    #    preserved by path suffix, not an exact hardcoded string match.
    $existingWithDifferentPath=$existingWithRag.Replace($ragCallLine,'call "D:\Custom\Path\OpenWebUI-RAG.env.cmd"')
    $regeneratedDifferentPath=Get-KIIntegrationOpenWebUIWithSearchStarterContent -ResultCount '5' -SearchConcurrency '3' -LoaderConcurrency '5' -QueryUrl 'http://localhost/searxng/search?q=<query>' -ApplicationStarterPath $applicationStarter -ExistingContent $existingWithDifferentPath
    $checks.differentRagPathStillPreserved=[ordered]@{
        containsCustomPathCall=$regeneratedDifferentPath.Contains('call "D:\Custom\Path\OpenWebUI-RAG.env.cmd"')
    }
    if($checks.differentRagPathStillPreserved.Values-contains$false){$fail.Add('Check D (DifferentRagPathStillPreserved) failed: '+($checks.differentRagPathStillPreserved|ConvertTo-Json -Compress)+' | content: '+$regeneratedDifferentPath)}
}
finally{
    if($module){Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue}
}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'Integration-RAG-Starter-Preservation-Regression fehlgeschlagen.'}

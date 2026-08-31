[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

# Regression: Install-IntegrationRuntime unconditionally copies every file listed in
# Runtime/RUNTIME-CONTRACT.json -- including Start-KIStack-OpenWebUI-WithSearch.cmd -- from
# this package's own static Runtime/ source on every Install/Upgrade/Repair pass. RAG (a
# separately-versioned, later-ordered component) patches this exact same file once to source
# its own OpenWebUI-RAG.env.cmd (search_document:/search_query: embedding prefixes). A blind
# overwrite here would silently erase that patch -- the identical class of regression already
# found and fixed in the BuilderKernel's own copy of this starter
# (tools/cutover-runtime/current/Modules/07-Integration/KIModuleIntegration.psm1
# Get-KIIntegrationOpenWebUIWithSearchStarterContent), just via this package's own
# static-file-copy deployment path (Merge-IntegrationOpenWebUIWithSearchStarterContent) rather
# than dynamic template generation. Both paths can independently reconcile the real target's
# modules/integration folder (see Contracts/COMPONENTS.json: cutover-runtime and integration
# are separately tracked components), so both need this preservation contract.

$module=Import-Module (Join-Path $PackageRoot 'IntegrationPackage.psm1') -Force -PassThru -DisableNameChecking
try{
    $ragCallLine='call "C:\KI-Stack\modules\rag\OpenWebUI-RAG.env.cmd"'
    $sourceContent=(Get-Content -LiteralPath (Join-Path $PackageRoot 'Runtime/Start-KIStack-OpenWebUI-WithSearch.cmd') -Raw)
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

    # A. RAG already patched the starter (steady state after RAG installed at least once) --
    #    a fresh Integration deployment must preserve the exact RAG env-call line, immediately
    #    after @echo off, while still deploying the package's own current template content.
    $mergedWithRag=Merge-IntegrationOpenWebUIWithSearchStarterContent -SourceContent $sourceContent -ExistingContent $existingWithRag
    $checks.ragLinePreservedAcrossDeployment=[ordered]@{
        containsRagCall=$mergedWithRag.Contains($ragCallLine)
        ragCallImmediatelyAfterEchoOff=([regex]::IsMatch($mergedWithRag,'(?im)^@echo off\r?\n'+[regex]::Escape($ragCallLine)+'\r?\n'))
        onlyOneRagCall=(@([regex]::Matches($mergedWithRag,[regex]::Escape($ragCallLine))).Count-eq1)
        stillContainsPackageTemplate=$mergedWithRag.Contains('call "C:\KI-Stack\modules\applications\Start-KIStack-OpenWebUI.cmd"')
    }
    if($checks.ragLinePreservedAcrossDeployment.Values-contains$false){$fail.Add('Check A (RagLinePreservedAcrossDeployment) failed: '+($checks.ragLinePreservedAcrossDeployment|ConvertTo-Json -Compress)+' | content: '+$mergedWithRag)}

    # B. Fresh install / RAG never installed -- no destination file exists yet, so no RAG line
    #    must be fabricated; the package's own template is deployed unchanged.
    $mergedFreshInstall=Merge-IntegrationOpenWebUIWithSearchStarterContent -SourceContent $sourceContent -ExistingContent $null
    $checks.noRagLineFabricatedOnFreshInstall=[ordered]@{
        noRagCall=(-not$mergedFreshInstall.Contains('OpenWebUI-RAG.env.cmd'))
        identicalToSource=($mergedFreshInstall-eq$sourceContent)
    }
    if($checks.noRagLineFabricatedOnFreshInstall.Values-contains$false){$fail.Add('Check B (NoRagLineFabricatedOnFreshInstall) failed: '+($checks.noRagLineFabricatedOnFreshInstall|ConvertTo-Json -Compress)+' | content: '+$mergedFreshInstall)}

    # C. Re-running the merge a second time against its own prior output (idempotency: no
    #    duplicate/doubled call line across repeated Integration reconciliations).
    $mergedTwice=Merge-IntegrationOpenWebUIWithSearchStarterContent -SourceContent $sourceContent -ExistingContent $mergedWithRag
    $checks.idempotentAcrossRepeatedDeployment=[ordered]@{
        onlyOneRagCall=(@([regex]::Matches($mergedTwice,[regex]::Escape($ragCallLine))).Count-eq1)
        identicalToFirstMerge=($mergedTwice-eq$mergedWithRag)
    }
    if($checks.idempotentAcrossRepeatedDeployment.Values-contains$false){$fail.Add('Check C (IdempotentAcrossRepeatedDeployment) failed: '+($checks.idempotentAcrossRepeatedDeployment|ConvertTo-Json -Compress)+' | content: '+$mergedTwice)}

    # D. A differently-pathed/quoted RAG call line already present (e.g. an older or
    #    manually-adjusted install path) is still recognized and preserved, not an exact
    #    hardcoded string match.
    $existingWithDifferentPath=$existingWithRag.Replace($ragCallLine,'call "D:\Custom\Path\OpenWebUI-RAG.env.cmd"')
    $mergedDifferentPath=Merge-IntegrationOpenWebUIWithSearchStarterContent -SourceContent $sourceContent -ExistingContent $existingWithDifferentPath
    $checks.differentRagPathStillPreserved=[ordered]@{
        containsCustomPathCall=$mergedDifferentPath.Contains('call "D:\Custom\Path\OpenWebUI-RAG.env.cmd"')
    }
    if($checks.differentRagPathStillPreserved.Values-contains$false){$fail.Add('Check D (DifferentRagPathStillPreserved) failed: '+($checks.differentRagPathStillPreserved|ConvertTo-Json -Compress)+' | content: '+$mergedDifferentPath)}

    # E. Negative control: patch a copy of the module so Install-IntegrationRuntime always
    #    takes the blind Copy-Item path (mirroring the pre-fix behavior) and prove that, on
    #    disk, the RAG line is genuinely lost -- so this suite would actually catch a
    #    regression back to it, not merely restate that the fix function itself works.
    $moduleSource=Get-Content -LiteralPath (Join-Path $PackageRoot 'IntegrationPackage.psm1') -Raw
    $negativeSource=$moduleSource.Replace(
        "if(`$name-eq'Start-KIStack-OpenWebUI-WithSearch.cmd'){",
        "if(`$false){"
    )
    if($negativeSource-eq$moduleSource){throw 'Negative-Control-Patch griff nicht -- Testannahme verletzt (Zeile im Modul nicht gefunden).'}
    $negativeControlDir=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-IntegrationRagStarter-NegControl-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path (Join-Path $negativeControlDir 'Runtime') -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'Runtime/RUNTIME-CONTRACT.json') -Destination (Join-Path $negativeControlDir 'Runtime') -Force
    foreach($runtimeFile in @('Start-KIStack-IntegratedStack.cmd','Start-KIStack-OpenWebUI-WithSearch.cmd','Start-KIStack-SearXNG.cmd','Start-KIStack-SearXNG.ps1','Stop-KIStack-IntegratedStack.cmd','Stop-KIStack-SearXNG.cmd','Stop-KIStack-SearXNG.ps1')){
        Copy-Item -LiteralPath (Join-Path $PackageRoot "Runtime/$runtimeFile") -Destination (Join-Path $negativeControlDir 'Runtime') -Force
    }
    $negativeModulePath=Join-Path $negativeControlDir 'IntegrationPackage.psm1'
    Set-Content -LiteralPath $negativeModulePath -Value $negativeSource -Encoding UTF8
    $negativeTargetRoot=Join-Path $negativeControlDir 'target'
    New-Item -ItemType Directory -Path $negativeTargetRoot -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $negativeTargetRoot 'Start-KIStack-OpenWebUI-WithSearch.cmd'),$existingWithRag,[Text.Encoding]::ASCII)
    try{
        Remove-Module IntegrationPackage -Force -ErrorAction SilentlyContinue
        Import-Module $negativeModulePath -Force -DisableNameChecking
        $marker=[ordered]@{schemaVersion='1.0';managedBy='TEST';version='0.0.0'}
        [void](Install-IntegrationRuntime -PackageRoot $negativeControlDir -TargetRoot $negativeTargetRoot -Marker $marker)
        $negativeResultContent=Get-Content -LiteralPath (Join-Path $negativeTargetRoot 'Start-KIStack-OpenWebUI-WithSearch.cmd') -Raw
        $negativeControlDetectsRegression=(-not$negativeResultContent.Contains('OpenWebUI-RAG.env.cmd'))
        $checks.negativeControl=[ordered]@{ oldBlindCopyBehaviorWouldHaveErasedRagLine=$negativeControlDetectsRegression }
        if(-not$negativeControlDetectsRegression){$fail.Add('negativeControl failed: patched module did not reproduce the original blind-copy defect, so this suite would not actually catch a regression back to it')}
    }finally{
        Remove-Module IntegrationPackage -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $PackageRoot 'IntegrationPackage.psm1') -Force -DisableNameChecking
        Remove-Item -LiteralPath $negativeControlDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
finally{
    if($module){Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue}
}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'Integration-Package-RAG-Starter-Preservation-Regression fehlgeschlagen.'}

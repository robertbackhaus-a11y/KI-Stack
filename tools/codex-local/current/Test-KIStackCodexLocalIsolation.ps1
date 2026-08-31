[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Fast, network-free CODEX_HOME-isolation contract (CODEX_HOME-Isolation-Workstream, follow-up to
# the Greenfield-Cold-Start workstream's real Architekturfund: KI-Stack Codex Local used to derive
# its runtime home from $env:CODEX_HOME, falling back to the real, shared %USERPROFILE%\.codex --
# pre-existing foreign state there was the actual root cause of a reproduced wrong-model
# auto-download that the explicit -m fix alone did not reliably prevent). Deliberately wired into
# scripts/Test-Repository.ps1 (unlike Test-KIStackCodexLocalOperationalization.ps1/
# Test-KIStackCodexLocalGreenfield.ps1): every check here uses either pure path-resolution
# functions (Get-KICodexPaths, Get-KICodexStarterScriptContent) or Install-KICodexLocal's own
# -DryRun path, none of which download Node.js, install the real Codex CLI, or touch the network.
#
# This suite NEVER reads, writes, or deletes the real %USERPROFILE%\.codex. Wherever a "foreign
# global Codex home" is needed to prove isolation, a disposable fixture directory stands in for
# it -- never the real path itself. A read-only, non-recursive snapshot of the real path (if it
# exists at all) is taken before and after purely to prove this suite left it untouched.

$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

Import-Module (Join-Path $PackageRoot 'CodexLocal.psm1') -Force -DisableNameChecking
$config=Get-KICodexConfig $PackageRoot

$suiteRoot=Join-Path ([IO.Path]::GetTempPath()) ('KICX-ISO-'+[guid]::NewGuid().ToString('N').Substring(0,10))
$targetA=Join-Path $suiteRoot 'target-a'
$targetB=Join-Path $suiteRoot 'target-b'
$workspace=Join-Path $suiteRoot 'workspace'
New-Item -ItemType Directory -Path $targetA,$targetB,$workspace -Force|Out-Null

$realUserCodexHome=Join-Path $env:USERPROFILE '.codex'
function Get-KIRealCodexHomeSnapshot {
    param([string]$Path)
    if(-not(Test-Path -LiteralPath $Path -PathType Container)){return $null}
    @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue|Sort-Object Name|ForEach-Object{
        [pscustomobject]@{name=$_.Name;length=$_.Length;mtimeUtc=$_.LastWriteTimeUtc.ToString('o')}
    })
}
$realCodexHomeSnapshotBefore=Get-KIRealCodexHomeSnapshot $realUserCodexHome

# A fixture stand-in for the real, shared %USERPROFILE%\.codex -- deliberately never the real
# path itself. Deliberately hostile/conflicting content (Section 9 "Isolation A" of the task):
# a different provider and a nonsense model, so any influence from this fixture would be
# unambiguous if it ever leaked into KI-Stack's own resolved paths.
$foreignGlobalHome=Join-Path $suiteRoot 'foreign-global-codex-home'
New-Item -ItemType Directory -Path $foreignGlobalHome -Force|Out-Null
$foreignProfilePath=Join-Path $foreignGlobalHome 'ki-stack-local.config.toml'
[IO.File]::WriteAllText($foreignProfilePath,"oss_provider = `"openai`"`r`nmodel = `"some-foreign-model-should-never-be-used`"`r`n# FOREIGN-GLOBAL-STATE-MARKER`r`n",[Text.UTF8Encoding]::new($false))
$foreignHashBefore=(Get-FileHash -LiteralPath $foreignProfilePath -Algorithm SHA256).Hash
$foreignMtimeBefore=(Get-Item -LiteralPath $foreignProfilePath).LastWriteTimeUtc

# An ambient $env:CODEX_HOME a real shell might legitimately have set (pointing at the fixture
# above, standing in for the real global one) -- the whole point of this suite is that KI-Stack's
# OWN resolution must never be influenced by this, even though it is genuinely present in the
# process environment throughout.
$originalAmbientCodexHome=$env:CODEX_HOME
$env:CODEX_HOME=$foreignGlobalHome

try{
    # --- 1. Get-KICodexPaths (Section 1/2): codexHome is a pure function of TargetRoot, inside
    # the package's existing state area, distinct per target, and never equal to the shared real
    # user home or the poisoned ambient fixture. ---------------------------------------------------
    $pathsA=Get-KICodexPaths -TargetRoot $targetA
    $pathsB=Get-KICodexPaths -TargetRoot $targetB
    $checks.codexHomeIsOwnIsolatedPathPerTarget=[ordered]@{
        underOwnStateArea=([string]$pathsA.codexHome-eq(Join-Path $pathsA.stateRoot 'codex-home'))
        distinctPerTarget=([string]$pathsA.codexHome-ne[string]$pathsB.codexHome)
        neverRealUserHome=([string]$pathsA.codexHome-ne$realUserCodexHome-and[string]$pathsB.codexHome-ne$realUserCodexHome)
        neverAmbientForeignHome=([string]$pathsA.codexHome-ne$foreignGlobalHome-and[string]$pathsB.codexHome-ne$foreignGlobalHome)
    }
    if($checks.codexHomeIsOwnIsolatedPathPerTarget.Values-contains$false){$fail.Add('codexHomeIsOwnIsolatedPathPerTarget failed: '+($checks.codexHomeIsOwnIsolatedPathPerTarget|ConvertTo-Json -Compress))}

    # --- 2. Install-KICodexLocal -DryRun (Section 9 "Isolation A" / "Greenfield"): the real
    # function, real path-resolution code, zero network -- proves the actual install plan's
    # profilePath is the isolated home, ignoring the hostile ambient $env:CODEX_HOME set above. --
    $dryRun=Install-KICodexLocal -PackageRoot $PackageRoot -TargetRoot $targetA -WorkspacePath $workspace -Action Install -DryRun
    $expectedProfilePath=Join-Path $pathsA.codexHome ([string]$config.profileName+'.config.toml')
    $checks.installPlanIgnoresForeignAmbientCodexHome=[ordered]@{
        passed=[bool]$dryRun.passed
        profilePathIsIsolated=([string]$dryRun.plan.profilePath-eq$expectedProfilePath)
        profilePathNotForeign=(-not([string]$dryRun.plan.profilePath).StartsWith($foreignGlobalHome))
    }
    if($checks.installPlanIgnoresForeignAmbientCodexHome.Values-contains$false){$fail.Add('installPlanIgnoresForeignAmbientCodexHome failed: '+($checks.installPlanIgnoresForeignAmbientCodexHome|ConvertTo-Json -Compress)+' | plan: '+($dryRun.plan|ConvertTo-Json -Compress))}

    # --- 3. Isolation B (Section 4/8/9): the foreign fixture itself is never read, written, or
    # deleted by any of the above -- byte- and mtime-identical. -----------------------------------
    $foreignHashAfter=(Get-FileHash -LiteralPath $foreignProfilePath -Algorithm SHA256).Hash
    $foreignMtimeAfter=(Get-Item -LiteralPath $foreignProfilePath).LastWriteTimeUtc
    $checks.foreignGlobalStateNeverTouched=[ordered]@{
        hashUnchanged=($foreignHashAfter-eq$foreignHashBefore)
        mtimeUnchanged=($foreignMtimeAfter-eq$foreignMtimeBefore)
    }
    if($checks.foreignGlobalStateNeverTouched.Values-contains$false){$fail.Add('foreignGlobalStateNeverTouched failed: '+($checks.foreignGlobalStateNeverTouched|ConvertTo-Json -Compress))}

    # --- 4. Starter content (Section 3/6): the generated starter sets the isolated CODEX_HOME
    # BEFORE Codex ever runs, and always pins the explicit contracted chat model -- independent of
    # whatever a foreign/global config might otherwise default to. Uses the extracted
    # Get-KICodexStarterScriptContent helper directly: no real npm install needed. -----------------
    $fixtureNode='C:\fixture\runtime\node.exe'
    $fixtureCodexCli='C:\fixture\npm-global\node_modules\@openai\codex\bin\codex.js'
    $starterContent=Get-KICodexStarterScriptContent -NodePath $fixtureNode -CodexCliPath $fixtureCodexCli -ProfileName ([string]$config.profileName) -ChatModel ([string]$config.chatModel) -CodexHome $pathsA.codexHome -WorkspacePath $workspace
    $codexHomeLineIndex=$starterContent.IndexOf("set `"CODEX_HOME=$($pathsA.codexHome)`"")
    $nodeInvocationLineIndex=$starterContent.IndexOf($fixtureNode)
    $checks.starterPinsIsolatedHomeAndExplicitModel=[ordered]@{
        setsIsolatedCodexHome=($codexHomeLineIndex-ge0)
        codexHomeSetBeforeCodexRuns=($codexHomeLineIndex-ge0-and$nodeInvocationLineIndex-ge0-and$codexHomeLineIndex-lt$nodeInvocationLineIndex)
        pinsExplicitContractedModel=($starterContent.Contains("-m $([string]$config.chatModel)"))
        neverReferencesRealUserProfileVariable=(-not$starterContent.Contains('%USERPROFILE%'))
        neverReferencesForeignFixtureHome=(-not$starterContent.Contains($foreignGlobalHome))
    }
    if($checks.starterPinsIsolatedHomeAndExplicitModel.Values-contains$false){$fail.Add('starterPinsIsolatedHomeAndExplicitModel failed: '+($checks.starterPinsIsolatedHomeAndExplicitModel|ConvertTo-Json -Compress)+" | starter: $starterContent")}

    # --- 5. Static source proof (Section 3): every real codex.js/npm invocation site in the
    # module passes an explicit -CodexHome -- Get-KICodexVersion, Invoke-KICodexAnalysisAcceptance,
    # Install-KICodexLocal's npm install call, Test-KICodexArtifact's npm install call. -----------
    $moduleSource=[IO.File]::ReadAllText((Join-Path $PackageRoot 'CodexLocal.psm1'))
    $explicitCodexHomeCallSites=([regex]::Matches($moduleSource,'-CodexHome \$(paths\.codexHome|codexHome)\b')).Count
    $checks.everyRealCallSitePassesExplicitCodexHome=[ordered]@{
        processFunctionAcceptsCodexHomeParameter=$moduleSource.Contains("[string]`$CodexHome=''")
        environmentOverrideAppliedToChildProcessOnly=$moduleSource.Contains("psi.Environment['CODEX_HOME']=`$CodexHome")
        atLeastFourRealCallSitesIsolated=($explicitCodexHomeCallSites-ge4)
        backupContractReferencesIsolatedProfilePath=$moduleSource.Contains("@{path=`$profilePath;name='profile.config.toml'}")
    }
    if($checks.everyRealCallSitePassesExplicitCodexHome.Values-contains$false){$fail.Add("everyRealCallSitePassesExplicitCodexHome failed (found $explicitCodexHomeCallSites call sites): "+($checks.everyRealCallSitePassesExplicitCodexHome|ConvertTo-Json -Compress))}

    # --- 6. Negative Control (Section 10): patch a copy of the module to revert JUST the
    # codexHome derivation back to the OLD ambient-env-with-fallback behavior, and prove that with
    # the fix removed, the (fixture, never-real) ambient foreign home regains influence -- i.e.
    # this suite would actually catch a regression back to the original shared-CODEX_HOME defect. -
    $oldDerivation='$codexHome=$paths.codexHome'
    $revertedDerivation='$codexHome=if([string]::IsNullOrWhiteSpace($env:CODEX_HOME)){Join-Path $env:USERPROFILE ''.codex''}else{[string]$env:CODEX_HOME}'
    $negativeModuleSource=$moduleSource-replace[regex]::Escape($oldDerivation),$revertedDerivation
    if($negativeModuleSource-eq$moduleSource){throw 'Negative-Control-Patch griff nicht -- Testannahme verletzt (codexHome-Zuweisung im Modul nicht gefunden).'}
    $negativePackageRoot=Join-Path $suiteRoot 'package-negative'
    Copy-Item -LiteralPath $PackageRoot -Destination $negativePackageRoot -Recurse -Force
    Set-Content -LiteralPath (Join-Path $negativePackageRoot 'CodexLocal.psm1') -Value $negativeModuleSource -Encoding utf8NoBOM
    Remove-Module CodexLocal -Force -ErrorAction SilentlyContinue
    try{
        Import-Module (Join-Path $negativePackageRoot 'CodexLocal.psm1') -Force -DisableNameChecking
        $negativeDryRun=Install-KICodexLocal -PackageRoot $negativePackageRoot -TargetRoot $targetB -WorkspacePath $workspace -Action Install -DryRun
    }finally{
        Remove-Module CodexLocal -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $PackageRoot 'CodexLocal.psm1') -Force -DisableNameChecking
    }
    $checks.negativeControl_AmbientForeignHomeRegainsInfluenceWhenIsolationRemoved=[ordered]@{
        revertedPlanUsesForeignAmbientHome=([string]$negativeDryRun.plan.profilePath).StartsWith($foreignGlobalHome)
        realFixedModuleDoesNotReproduceThis=(-not([string]$dryRun.plan.profilePath).StartsWith($foreignGlobalHome))
    }
    if($checks.negativeControl_AmbientForeignHomeRegainsInfluenceWhenIsolationRemoved.Values-contains$false){$fail.Add('negativeControl_AmbientForeignHomeRegainsInfluenceWhenIsolationRemoved failed -- reverting the isolation fix either did not reproduce the original ambient-fallback defect, or the real module still shows it: '+($checks.negativeControl_AmbientForeignHomeRegainsInfluenceWhenIsolationRemoved|ConvertTo-Json -Compress)+' | reverted plan: '+($negativeDryRun.plan|ConvertTo-Json -Compress))}

    # --- 7. The real %USERPROFILE%\.codex, if it exists at all on this machine, was never read
    # for anything other than this one comparison, and never written or deleted (Section 4/11). --
    $realCodexHomeSnapshotAfter=Get-KIRealCodexHomeSnapshot $realUserCodexHome
    $checks.realUserCodexHomeNeverTouched=[ordered]@{
        snapshotUnchanged=(($realCodexHomeSnapshotBefore|ConvertTo-Json -Compress -Depth 5)-eq($realCodexHomeSnapshotAfter|ConvertTo-Json -Compress -Depth 5))
    }
    if($checks.realUserCodexHomeNeverTouched.Values-contains$false){$fail.Add('realUserCodexHomeNeverTouched failed -- this suite must never modify the real %USERPROFILE%\.codex: '+($checks.realUserCodexHomeNeverTouched|ConvertTo-Json -Compress))}

    foreach($file in Get-ChildItem -LiteralPath $PackageRoot -Recurse -File|Where-Object Extension -in '.ps1','.psm1'){
        $tokens=$null;$errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        if(@($errors).Count){$fail.Add("$($file.Name): $(@($errors).Message -join '; ')")}
    }

    $passed=$fail.Count-eq0
    [pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail);realUserCodexHomePath=$realUserCodexHome;neverTouchedRealUserCodexHome=$true}|ConvertTo-Json -Depth 12
    if(-not$passed){throw 'Codex-Local-Isolation-Regression fehlgeschlagen.'}
}
finally{
    $env:CODEX_HOME=$originalAmbientCodexHome
    if(Test-Path -LiteralPath $suiteRoot){Remove-Item -LiteralPath $suiteRoot -Recurse -Force -ErrorAction SilentlyContinue}
}

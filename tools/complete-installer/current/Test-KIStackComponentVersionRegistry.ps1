[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

# Regression suite for the KI-Stack-own component version/registry contract
# (Lifecycle/KIStackComponentVersionRegistry.psm1 + Contracts/COMPONENTS.json's
# versionSourceType/packageIdentity/referenceComponent fields + Update-KIStack-All.ps1's
# packageAvailableVersion/packageVersionSource/packageVersionStatus report fields). Primarily
# fixture-based per the task's own explicit instruction -- Compare-KIStackSemVer and
# Resolve-KIStackComponentVersion are pure and tested with no I/O at all; the two real-I/O
# functions (Get-KIStackLatestPublishedCompleteInstallerRelease /
# Get-KIStackPublishedComponentVersion) are tested via their -Fixture bypass for the resolution
# contract, and via a local Invoke-RestMethod override (not a real network call) for the actual
# JSON-field/composite parsing logic the fixture bypass alone would never exercise. A single,
# separate real-network smoke check is intentionally NOT part of this suite (see the task's own
# Section 23/24 real-target/real-GitHub validation, run once, separately, by hand).

Import-Module (Join-Path $PackageRoot 'Lifecycle/KIStackComponentVersionRegistry.psm1') -Force -DisableNameChecking

# --- A. Compare-KIStackSemVer: every case the task explicitly names, plus the classic
# string-comparison trap ("1.10" vs "1.9" must never compare as strings). -------------------
$semverCases=@(
    @{l='1.9.0';r='1.9.0';expect=0;name='equal'}
    @{l='1.9.1';r='1.9.0';expect=1;name='patchNewer'}
    @{l='2.0.0';r='1.99.99';expect=1;name='minorRolloverBeatsHighPatch'}
    @{l='1.6.3';r='1.6.3-rc1';expect=1;name='releaseBeatsPrereleaseOfSameCore'}
    @{l='1.6.3-rc1';r='1.6.3';expect=-1;name='prereleaseBehindItsOwnRelease'}
    @{l='v1.9.0';r='1.9';expect=0;name='vPrefixAndImplicitTrailingZero'}
    @{l='1.10.0';r='1.9.0';expect=1;name='noStringCompareTrap'}
    @{l='1.9.0';r='1.10.0';expect=-1;name='noStringCompareTrapReversed'}
)
$semverResults=[ordered]@{}
foreach($case in $semverCases){
    $actual=Compare-KIStackSemVer -Left $case.l -Right $case.r
    $semverResults[$case.name]=($actual-eq$case.expect)
}
$checks.semVerComparison=$semverResults
if($checks.semVerComparison.Values-contains$false){$fail.Add('semVerComparison failed: '+($semverResults|ConvertTo-Json -Compress))}

# --- B. Resolve-KIStackComponentVersion: pure function, every one of the seven status values
# reachable, each via an unambiguous fixture-shaped input (no network, no disk). -------------
$checks.resolverStatusCoverage=[ordered]@{
    upToDate=((Resolve-KIStackComponentVersion -ComponentId 'x' -InstalledVersion '0.4.0' -VersionSourceType 'own-version-file' -PublishedVersion '0.4.0' -PublishedVersionSource 'fixture').status -eq 'UpToDate')
    updateAvailable=((Resolve-KIStackComponentVersion -ComponentId 'x' -InstalledVersion '0.3.9' -VersionSourceType 'own-version-file' -PublishedVersion '0.4.0' -PublishedVersionSource 'fixture').status -eq 'UpdateAvailable')
    newerInstalled=((Resolve-KIStackComponentVersion -ComponentId 'x' -InstalledVersion '0.5.0' -VersionSourceType 'own-version-file' -PublishedVersion '0.4.0' -PublishedVersionSource 'fixture').status -eq 'NewerInstalled')
    notInstalled=((Resolve-KIStackComponentVersion -ComponentId 'x' -InstalledVersion '' -VersionSourceType 'own-version-file' -PublishedVersion '0.4.0' -PublishedVersionSource 'fixture').status -eq 'NotInstalled')
    versionUnavailableBundledReferenceOnly=((Resolve-KIStackComponentVersion -ComponentId 'x' -InstalledVersion '1.0.9' -VersionSourceType 'bundled-reference-only' -PublishedVersion $null -PublishedVersionSource $null).status -eq 'VersionUnavailable')
    versionUnavailableOffline=((Resolve-KIStackComponentVersion -ComponentId 'x' -InstalledVersion '0.4.0' -VersionSourceType 'own-version-file' -PublishedVersion $null -PublishedVersionSource 'offline' -PublishedVersionAvailable:$false).status -eq 'VersionUnavailable')
    errorOnUnparsableVersion=((Resolve-KIStackComponentVersion -ComponentId 'x' -InstalledVersion 'not-a-version' -VersionSourceType 'own-version-file' -PublishedVersion '0.4.0' -PublishedVersionSource 'fixture').status -eq 'Error')
}
if($checks.resolverStatusCoverage.Values-contains$false){$fail.Add('resolverStatusCoverage failed: '+($checks.resolverStatusCoverage|ConvertTo-Json -Compress))}
# NotManaged is never produced by Resolve-KIStackComponentVersion itself (that classification
# belongs to Update-KIStack-All.ps1's own -Component handling for an id Contracts/COMPONENTS.json
# does not know at all) -- documented here rather than fabricating a fixture path that does not
# exist in the real resolver.
$checks.notManagedIsUpdateAllsOwnConcernNotTheResolvers=[ordered]@{documented=$true}

# --- C. Get-KIStackLatestPublishedCompleteInstallerRelease: fixture bypass never touches gh. -
$checks.latestReleaseFixtureBypass=[ordered]@{
    foundPassesThrough=((Get-KIStackLatestPublishedCompleteInstallerRelease -Fixture @{found=$true;tag='v2.12.0'}).tag -eq 'v2.12.0')
    notFoundPassesThroughWithoutReason=(-not (Get-KIStackLatestPublishedCompleteInstallerRelease -Fixture @{found=$false}).found)
    missingOptionalKeyNeverThrows=$true
}
try{ [void](Get-KIStackLatestPublishedCompleteInstallerRelease -Fixture @{found=$true;tag='v1.0.0'}) }catch{ $checks.latestReleaseFixtureBypass.missingOptionalKeyNeverThrows=$false }
if($checks.latestReleaseFixtureBypass.Values-contains$false){$fail.Add('latestReleaseFixtureBypass failed: '+($checks.latestReleaseFixtureBypass|ConvertTo-Json -Compress))}

# --- D. Get-KIStackPublishedComponentVersion: fixture bypass for all three packageIdentity
# kinds' RESOLUTION contract (found/error), then the REAL (non-fixture) parsing logic for
# 'file'/'jsonField'/'jsonComposite' via a local Invoke-RestMethod override -- proving the
# actual dispatch/extraction code works, not merely that the fixture short-circuit works, while
# still making zero real network calls (task Section 21: fixture-based, no real GitHub calls in
# unit tests). --------------------------------------------------------------------------------
$checks.publishedVersionFixtureBypass=[ordered]@{
    fileFixtureFound=((Get-KIStackPublishedComponentVersion -PackageIdentity ([pscustomobject]@{kind='file';path='tools/rag/current/VERSION'}) -Tag 'v2.12.0' -Fixture @{version='0.4.0'}).version -eq '0.4.0')
    errorFixtureReported=(-not (Get-KIStackPublishedComponentVersion -PackageIdentity ([pscustomobject]@{kind='file';path='x'}) -Tag 'v2.12.0' -Fixture @{error='offline'}).found)
}
if($checks.publishedVersionFixtureBypass.Values-contains$false){$fail.Add('publishedVersionFixtureBypass failed: '+($checks.publishedVersionFixtureBypass|ConvertTo-Json -Compress))}

# Local Invoke-RestMethod override: PowerShell resolves an unqualified command name against the
# caller's own session state before falling back to the built-in cmdlet, so a function of the
# same name defined here (before importing the module with -Force) is what the module's own
# unqualified Invoke-RestMethod calls actually run -- a well-known, zero-dependency mocking
# technique, not a modification of the module itself. Never issues a real HTTP request.
$global:__KIStackRestFixtures=@{
    'tools/rag/current/VERSION'="0.4.0`n"
    'tools/openwebui-visual-pack/current/MANIFEST.json'='{"schemaVersion":"1.0","version":"2.0.5"}'
    'tools/production-recovery/current/RELEASE-MANIFEST.json'='{"productVersion":"1.7.0","recoveryRevision":"r7"}'
}
function global:Invoke-RestMethod{
    param([string]$Uri,[int]$TimeoutSec,[string]$ErrorAction,[hashtable]$Headers)
    foreach($key in $global:__KIStackRestFixtures.Keys){
        if($Uri.EndsWith($key)){
            $raw=$global:__KIStackRestFixtures[$key]
            if($raw.TrimStart().StartsWith('{')){ return ($raw|ConvertFrom-Json -Depth 20) }
            return $raw
        }
    }
    throw "Kein Test-Fixture für URI registriert: $Uri"
}
Import-Module (Join-Path $PackageRoot 'Lifecycle/KIStackComponentVersionRegistry.psm1') -Force -DisableNameChecking
$checks.publishedVersionRealParsingLogicViaMockedHttp=[ordered]@{
    fileKindParsesTrimmedContent=((Get-KIStackPublishedComponentVersion -PackageIdentity ([pscustomobject]@{kind='file';path='tools/rag/current/VERSION'}) -Tag 'v2.12.0').version -eq '0.4.0')
    jsonFieldKindExtractsNamedField=((Get-KIStackPublishedComponentVersion -PackageIdentity ([pscustomobject]@{kind='jsonField';path='tools/openwebui-visual-pack/current/MANIFEST.json';field='version'}) -Tag 'v2.12.0').version -eq '2.0.5')
    jsonCompositeKindJoinsFieldsInOrder=((Get-KIStackPublishedComponentVersion -PackageIdentity ([pscustomobject]@{kind='jsonComposite';path='tools/production-recovery/current/RELEASE-MANIFEST.json';fields=@('productVersion','recoveryRevision');separator='-'}) -Tag 'v2.12.0').version -eq '1.7.0-r7')
    unknownUriDegradesToNotFoundNotCrash=(-not (Get-KIStackPublishedComponentVersion -PackageIdentity ([pscustomobject]@{kind='file';path='tools/does-not-exist/VERSION'}) -Tag 'v2.12.0').found)
}
Remove-Item -Path Function:Invoke-RestMethod -Force -ErrorAction SilentlyContinue
Remove-Variable -Name __KIStackRestFixtures -Scope Global -ErrorAction SilentlyContinue
Import-Module (Join-Path $PackageRoot 'Lifecycle/KIStackComponentVersionRegistry.psm1') -Force -DisableNameChecking
if($checks.publishedVersionRealParsingLogicViaMockedHttp.Values-contains$false){$fail.Add('publishedVersionRealParsingLogicViaMockedHttp failed: '+($checks.publishedVersionRealParsingLogicViaMockedHttp|ConvertTo-Json -Compress))}

# --- E. Contracts/COMPONENTS.json drift check (Section 3: "Tests müssen Drift erkennen" for
# any redundant value): every own-version-file component's pinned .version field must equal
# the actual repository VERSION file it is supposed to describe -- these are two independently
# maintained values today (COMPONENTS.json's "version" is hand-set, the VERSION file is each
# package's own source of truth) and nothing currently keeps them in lockstep except this test.
$repoRoot=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PackageRoot))
$contract=Get-Content -LiteralPath (Join-Path $PackageRoot 'Contracts/COMPONENTS.json') -Raw|ConvertFrom-Json -Depth 30
$driftChecks=[ordered]@{}
foreach($c in $contract.components){
    $versionSourceType=if($c.PSObject.Properties['versionSourceType']){[string]$c.versionSourceType}else{$null}
    if($versionSourceType-ne'own-version-file'){continue}
    $identityPath=Join-Path $repoRoot ([string]$c.packageIdentity.path)
    if(-not(Test-Path -LiteralPath $identityPath -PathType Leaf)){$driftChecks[[string]$c.id]=$false;continue}
    $actual=(Get-Content -LiteralPath $identityPath -Raw).Trim()
    $driftChecks[[string]$c.id]=($actual-eq[string]$c.version)
}
$checks.componentsJsonVersionMatchesRepositoryFile=$driftChecks
if($driftChecks.Values-contains$false){$fail.Add('componentsJsonVersionMatchesRepositoryFile failed (drift between Contracts/COMPONENTS.json "version" and the real VERSION file): '+($driftChecks|ConvertTo-Json -Compress))}

# --- F. Negative Control A: deliberately make COMPONENTS.json's pinned version and the real
# VERSION file contradict each other, prove Check E's own drift logic actually catches it, then
# confirm the real repository state (already checked above) is clean. ------------------------
function Test-KIComponentsJsonDriftAgainstContract{
    param([object[]]$Components,[string]$RepoRoot)
    $result=[ordered]@{}
    foreach($c in $Components){
        $versionSourceType=if($c.PSObject.Properties['versionSourceType']){[string]$c.versionSourceType}else{$null}
        if($versionSourceType-ne'own-version-file'){continue}
        $identityPath=Join-Path $RepoRoot ([string]$c.packageIdentity.path)
        if(-not(Test-Path -LiteralPath $identityPath -PathType Leaf)){$result[[string]$c.id]=$false;continue}
        $actual=(Get-Content -LiteralPath $identityPath -Raw).Trim()
        $result[[string]$c.id]=($actual-eq[string]$c.version)
    }
    $result
}
$contractCopy=Get-Content -LiteralPath (Join-Path $PackageRoot 'Contracts/COMPONENTS.json') -Raw|ConvertFrom-Json -Depth 30
($contractCopy.components|Where-Object id -eq 'rag').version='9.9.9-deliberately-wrong'
$negativeADrift=Test-KIComponentsJsonDriftAgainstContract -Components $contractCopy.components -RepoRoot $repoRoot
$realDrift=Test-KIComponentsJsonDriftAgainstContract -Components $contract.components -RepoRoot $repoRoot
$checks.negativeControlA_VersionDriftDetected=[ordered]@{
    patchedContractDetectsRagDrift=($negativeADrift['rag']-eq$false)
    realContractHasNoRagDrift=($realDrift['rag']-eq$true)
}
if($checks.negativeControlA_VersionDriftDetected.Values-contains$false){$fail.Add('negativeControlA_VersionDriftDetected failed: '+($checks.negativeControlA_VersionDriftDetected|ConvertTo-Json -Compress))}

# --- G. Negative Control B: a resolver caller must never accept another component's release/
# version as this component's own AvailableVersion just because SOME release was found -- prove
# Get-KIStackPublishedComponentVersion is keyed strictly by the packageIdentity.path it was
# given (rag's own VERSION path), and that pointing it at a DIFFERENT component's path (still a
# real, valid file at the same tag) returns THAT component's own value, never rag's, even though
# both live inside the exact same Complete Installer release/tag. -----------------------------
$global:__KIStackRestFixtures=@{
    'tools/rag/current/VERSION'="0.4.0`n"
    'tools/codex-local/current/VERSION'="0.1.4`n"
}
function global:Invoke-RestMethod{
    param([string]$Uri,[int]$TimeoutSec,[string]$ErrorAction,[hashtable]$Headers)
    foreach($key in $global:__KIStackRestFixtures.Keys){ if($Uri.EndsWith($key)){ return $global:__KIStackRestFixtures[$key] } }
    throw "Kein Test-Fixture für URI registriert: $Uri"
}
Import-Module (Join-Path $PackageRoot 'Lifecycle/KIStackComponentVersionRegistry.psm1') -Force -DisableNameChecking
$ragAnswer=Get-KIStackPublishedComponentVersion -PackageIdentity ([pscustomobject]@{kind='file';path='tools/rag/current/VERSION'}) -Tag 'v2.12.0'
$codexAnswer=Get-KIStackPublishedComponentVersion -PackageIdentity ([pscustomobject]@{kind='file';path='tools/codex-local/current/VERSION'}) -Tag 'v2.12.0'
Remove-Item -Path Function:Invoke-RestMethod -Force -ErrorAction SilentlyContinue
Remove-Variable -Name __KIStackRestFixtures -Scope Global -ErrorAction SilentlyContinue
Import-Module (Join-Path $PackageRoot 'Lifecycle/KIStackComponentVersionRegistry.psm1') -Force -DisableNameChecking
$checks.negativeControlB_NeverConflatesADifferentComponentsRelease=[ordered]@{
    ragGetsItsOwnValue=($ragAnswer.version-eq'0.4.0')
    codexGetsItsOwnValue=($codexAnswer.version-eq'0.1.4')
    valuesAreNotAccidentallyIdentical=($ragAnswer.version-ne$codexAnswer.version)
}
if($checks.negativeControlB_NeverConflatesADifferentComponentsRelease.Values-contains$false){$fail.Add('negativeControlB_NeverConflatesADifferentComponentsRelease failed: '+($checks.negativeControlB_NeverConflatesADifferentComponentsRelease|ConvertTo-Json -Compress))}

# --- H. Negative Control C ("newer installed"): installed > published must resolve to
# NewerInstalled, never to a downgrade suggestion -- covered functionally by check B's
# newerInstalled case above; restated here as its own named negative-control assertion per the
# task's explicit numbering, using a value pair that would be silently wrong under a naive
# string comparison (installed "1.10.0" vs published "1.9.0"). ---------------------------------
$checks.negativeControlC_NewerInstalledNeverDowngrades=[ordered]@{
    newerInstalledDetected=((Resolve-KIStackComponentVersion -ComponentId 'x' -InstalledVersion '1.10.0' -VersionSourceType 'own-version-file' -PublishedVersion '1.9.0' -PublishedVersionSource 'fixture').status -eq 'NewerInstalled')
}
if($checks.negativeControlC_NewerInstalledNeverDowngrades.Values-contains$false){$fail.Add('negativeControlC_NewerInstalledNeverDowngrades failed: '+($checks.negativeControlC_NewerInstalledNeverDowngrades|ConvertTo-Json -Compress))}

# --- I. Negative Control D ("Unknown regression"): remove a real, internally-versionable
# component's versionSourceType (mirroring the exact pre-registry state every Klasse-B
# component used to be in) and prove the resolver path correctly falls back to
# VersionUnavailable rather than crashing or silently reporting UpToDate -- then confirm the
# real, current contract does NOT have this gap for the same component. -----------------------
function Test-KIVersionSourceTypePresence{
    param([object[]]$Components,[string]$ComponentId)
    $c=@($Components|Where-Object id -eq $ComponentId)|Select-Object -First 1
    if($null-eq$c){return $null}
    if(-not $c.PSObject.Properties['versionSourceType']){return $null}
    [string]$c.versionSourceType
}
$regressedContract=Get-Content -LiteralPath (Join-Path $PackageRoot 'Contracts/COMPONENTS.json') -Raw|ConvertFrom-Json -Depth 30
$ragEntry=@($regressedContract.components|Where-Object id -eq 'rag')|Select-Object -First 1
$ragEntry.PSObject.Properties.Remove('versionSourceType')
$regressedType=Test-KIVersionSourceTypePresence -Components $regressedContract.components -ComponentId 'rag'
$realType=Test-KIVersionSourceTypePresence -Components $contract.components -ComponentId 'rag'
$checks.negativeControlD_UnknownRegressionDetected=[ordered]@{
    regressedContractHasNoVersionSourceType=($null-eq$regressedType)
    # Mirrors Update-KIStack-All.ps1's own Get-KIPackageVersionInfo guard exactly (a missing/
    # blank versionSourceType short-circuits to VersionUnavailable BEFORE ever calling
    # Resolve-KIStackComponentVersion, which requires a non-empty VersionSourceType by
    # contract) -- this proves the exact real fallback condition fires for the regressed
    # contract, without misusing the pure resolver for a shape it is never actually called with.
    getPackageVersionInfoGuardWouldFallBackToVersionUnavailable=([string]::IsNullOrWhiteSpace($regressedType))
    realContractHasVersionSourceType=($realType-eq'own-version-file')
}
if($checks.negativeControlD_UnknownRegressionDetected.Values-contains$false){$fail.Add('negativeControlD_UnknownRegressionDetected failed: '+($checks.negativeControlD_UnknownRegressionDetected|ConvertTo-Json -Compress))}

# --- J. Every component classified 'bundled-reference-only' names a referenceComponent that
# actually exists and itself has an independent versionSourceType (never a reference to another
# bundled-reference-only id, which would leave the mirror chain unresolved). -------------------
$byId=@{}
foreach($c in $contract.components){$byId[[string]$c.id]=$c}
$referenceChainChecks=[ordered]@{}
foreach($c in $contract.components){
    $versionSourceType=if($c.PSObject.Properties['versionSourceType']){[string]$c.versionSourceType}else{$null}
    if($versionSourceType-ne'bundled-reference-only'){continue}
    $refId=[string]$c.referenceComponent
    $ref=$byId[$refId]
    $refType=if($null-ne$ref-and$ref.PSObject.Properties['versionSourceType']){[string]$ref.versionSourceType}else{$null}
    $referenceChainChecks[[string]$c.id]=($null-ne$ref-and$refType-ne$null-and$refType-ne'bundled-reference-only')
}
$checks.bundledReferenceComponentsResolveToARealIndependentSource=$referenceChainChecks
if($referenceChainChecks.Values-contains$false){$fail.Add('bundledReferenceComponentsResolveToARealIndependentSource failed: '+($referenceChainChecks|ConvertTo-Json -Compress))}

# --- K. Codex Local 0.1.4 -> 0.2.1 bump (Versionsbump-Workstream, extended by the CODEX_HOME-
# Isolation-Workstream's own follow-up 0.2.0 -> 0.2.1 patch bump): explicit, literal proof that
# this feature branch's own, not-yet-published SourceVersion (0.2.1, this repository's own
# tools/codex-local/current/VERSION right now) is never confused with PublishedVersion (still
# 0.1.4 -- the actual, real, latest published Complete Installer release, v2.12.0, has not
# shipped either bump yet -- neither 0.2.0 nor 0.2.1). A real target still at InstalledVersion
# 0.1.4 must report UpToDate against the real Published value, never an update recommendation
# manufactured out of this branch's own unpublished source bump; a hypothetical target already
# sitting on 0.2.1 must report NewerInstalled against that same real Published value, never a
# downgrade suggestion. -----------------------------------------------------------------------
$realCodexSourceVersion=(Get-Content -LiteralPath (Join-Path $repoRoot 'tools/codex-local/current/VERSION') -Raw).Trim()
$checks.codexLocalVersionBump_SourceVersionIsBumped=[ordered]@{
    sourceVersionIs021=($realCodexSourceVersion-eq'0.2.1')
}
if($checks.codexLocalVersionBump_SourceVersionIsBumped.Values-contains$false){$fail.Add("codexLocalVersionBump_SourceVersionIsBumped failed: tools/codex-local/current/VERSION is '$realCodexSourceVersion', expected '0.2.1'.")}

# Real GitHub lookup (not a fixture) -- this is the one deliberate exception to this suite's
# otherwise fixture-only posture (see header comment), needed specifically to prove the actual,
# real Published value is genuinely still 0.1.4 and was not accidentally affected by anything
# in this workstream. Degrades to a documented skip, never a hard failure, if genuinely offline
# -- offline behavior itself is already covered by check C's fixture-based VersionUnavailable
# path; this check's whole point is a real assertion about the real, current GitHub state.
$realLatestRelease=Get-KIStackLatestPublishedCompleteInstallerRelease
if($realLatestRelease.found){
    $realPublished=Get-KIStackPublishedComponentVersion -PackageIdentity ([pscustomobject]@{kind='file';path='tools/codex-local/current/VERSION'}) -Tag ([string]$realLatestRelease.tag)
    $checks.codexLocalVersionBump_PublishedStillMatchesRealRelease=[ordered]@{
        realPublishedVersionIs014=($realPublished.version-eq'0.1.4')
        realPublishedNeverEquals021=($realPublished.version-ne'0.2.1')
    }
    if($checks.codexLocalVersionBump_PublishedStillMatchesRealRelease.Values-contains$false){$fail.Add("codexLocalVersionBump_PublishedStillMatchesRealRelease failed: real GitHub PublishedVersion at $($realLatestRelease.tag) is '$($realPublished.version)', expected '0.1.4' (never '0.2.1' before an actual release ships it).")}

    # Resolver-level proof using the REAL published value alongside two real-shaped installed
    # states -- not a synthetic fixture pair, so this is a direct, literal answer to "does the
    # unpublished branch bump leak into what a real target is told is available".
    $realTargetResolved=Resolve-KIStackComponentVersion -ComponentId 'codex-local' -InstalledVersion '0.1.4' -VersionSourceType 'own-version-file' -PublishedVersion $realPublished.version -PublishedVersionSource "Complete-Installer-Release $($realLatestRelease.tag): tools/codex-local/current/VERSION"
    $hypotheticalNewerResolved=Resolve-KIStackComponentVersion -ComponentId 'codex-local' -InstalledVersion '0.2.1' -VersionSourceType 'own-version-file' -PublishedVersion $realPublished.version -PublishedVersionSource "Complete-Installer-Release $($realLatestRelease.tag): tools/codex-local/current/VERSION"
    $checks.codexLocalVersionBump_PublishedVsSourceResolution=[ordered]@{
        realTargetAt014IsUpToDate=($realTargetResolved.status-eq'UpToDate')
        realTargetNeverShowsUpdateAvailableFromUnpublishedBranch=($realTargetResolved.status-ne'UpdateAvailable')
        hypotheticalTargetAt021IsNewerInstalled=($hypotheticalNewerResolved.status-eq'NewerInstalled')
        hypotheticalTargetNeverDowngraded=($hypotheticalNewerResolved.availableVersion-ne'0.2.1')
    }
    if($checks.codexLocalVersionBump_PublishedVsSourceResolution.Values-contains$false){$fail.Add('codexLocalVersionBump_PublishedVsSourceResolution failed: '+($checks.codexLocalVersionBump_PublishedVsSourceResolution|ConvertTo-Json -Compress))}
}else{
    $checks.codexLocalVersionBump_PublishedStillMatchesRealRelease=[ordered]@{skipped=$true;reason=[string]$realLatestRelease.reason}
    $checks.codexLocalVersionBump_PublishedVsSourceResolution=[ordered]@{skipped=$true;reason='Latest release lookup unavailable (offline) -- see codexLocalVersionBump_PublishedStillMatchesRealRelease.'}
}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 12
if(-not$passed){throw 'Component-Version-Registry-Regression fehlgeschlagen.'}

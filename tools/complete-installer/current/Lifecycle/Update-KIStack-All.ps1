[CmdletBinding()]
param(
    [string]$TargetRoot=$PSScriptRoot,
    [switch]$CheckOnly,
    [string[]]$Component=@(),
    [switch]$NonInteractive,
    # Test-only bypasses, mirroring the existing New-KICompletePlan -FixtureState contract:
    # FixtureState replaces disk-probed installed versions for Contracts/COMPONENTS.json
    # components (same mechanism New-KICompletePlan already exposes); OpenWebUIFixture
    # replaces the real venv/kernel-config readback for the openwebui adapter's plan/report
    # step only; UpstreamFixture (keyed by component id, each value an
    # @{availableVersion=...;upstreamStatus=...;upstreamSource=...} hashtable) replaces the real
    # PyPI/GitHub upstream lookups so tests never depend on live, drifting upstream content and
    # never make real network calls. None of these bypass or duplicate any install/upgrade/
    # rollback logic, which always runs for real (Update-KIStack-OpenWebUI.cmd /
    # Invoke-KIStackCompleteInstaller / Invoke-KIStackIsolatedComponentUpdate) and is never
    # itself driven by upstream data.
    [hashtable]$FixtureState,
    [hashtable]$OpenWebUIFixture,
    [hashtable]$UpstreamFixture,
    # PackageVersionRegistryFixture mirrors UpstreamFixture's role, for the separate
    # KI-Stack-own-component version registry (Lifecycle/KIStackComponentVersionRegistry.psm1):
    # @{ latestRelease=@{found=$true;tag='v2.12.0'} (or found=$false;reason=...);
    #    componentVersions=@{ <componentId>=@{version='...'} (or @{error='...'}) } }. Bypasses
    # only the real gh/GitHub-raw-content calls -- never the resolution logic itself, and never
    # any install/upgrade/rollback path.
    [hashtable]$PackageVersionRegistryFixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw 'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}

$installerRoot=Join-Path $TargetRoot 'installer/complete'
$completeModulePath=Join-Path $installerRoot 'CompleteInstaller.psm1'
if(-not(Test-Path -LiteralPath $completeModulePath -PathType Leaf)){throw "Complete-Installer-Paket fehlt unter $installerRoot; Update-Checker kann nicht laufen."}
Import-Module $completeModulePath -Force
# Component-isolation planning/execution (Resolve-KIStackUpdatePlan /
# Invoke-KIStackIsolatedComponentUpdate) -- see Lifecycle/KIStackUpdateIsolation.psm1 for the
# root-cause analysis and field-ownership contract this closes.
$isolationModulePath=Join-Path $installerRoot 'Lifecycle/KIStackUpdateIsolation.psm1'
if(-not(Test-Path -LiteralPath $isolationModulePath -PathType Leaf)){throw "Isolationsmodul fehlt unter $installerRoot; Update-Checker kann nicht laufen."}
Import-Module $isolationModulePath -Force
# KI-Stack-own component version registry (see that module's header for the root-cause
# analysis this closes: AvailableVersion=Unknown for every internally-authored component that
# actually has a belastbare publish source).
$versionRegistryModulePath=Join-Path $installerRoot 'Lifecycle/KIStackComponentVersionRegistry.psm1'
if(-not(Test-Path -LiteralPath $versionRegistryModulePath -PathType Leaf)){throw "Versionsregistrierungsmodul fehlt unter $installerRoot; Update-Checker kann nicht laufen."}
Import-Module $versionRegistryModulePath -Force
$completeConfig=Read-KICompleteJson (Join-Path $installerRoot 'Config/complete-installer.config.json')
$rawComponentContract=Read-KICompleteJson (Join-Path $installerRoot 'Contracts/COMPONENTS.json')
$isolationMetaById=@{}
foreach($rc in $rawComponentContract.components){
    $isolationMetaById[[string]$rc.id]=[pscustomobject][ordered]@{
        isolation=[string]$rc.isolation; requires=@($rc.requires); isolatedExecutionImplemented=[bool]$rc.isolatedExecutionImplemented
        executionRoute=if([bool]$rc.isolatedExecutionImplemented){'Isolated'}else{'CompleteInstallerBatch'}
    }
}

function Get-KIPinClassification {
    # Compliant means New-KICompletePlan's own compliance check (raw version match plus, for
    # some components, an extra compliance probe) already treats this component as fully
    # up to date against the currently pinned target. This is purely a pin-vs-installed
    # comparison -- it never looks at upstream -- because it is the ONLY thing that decides
    # what may be auto-executed. (equal-but-non-compliant, e.g. a failed extra compliance
    # check, is reported as PinnedUpdatePending -- the existing contract still needs to run
    # to reconcile it).
    param([string]$InstalledVersion,[string]$PinnedVersion,[bool]$Compliant)
    if($Compliant){return 'UpToDate'}
    if([string]::IsNullOrWhiteSpace($InstalledVersion)){return 'PinnedUpdatePending'}
    try{
        $installedMatch=[regex]::Match($InstalledVersion,'^\d+(\.\d+){1,3}')
        $pinnedMatch=[regex]::Match($PinnedVersion,'^\d+(\.\d+){1,3}')
        if(-not$installedMatch.Success-or-not$pinnedMatch.Success){return 'Blocked'}
        $installed=[version]$installedMatch.Value
        $pinned=[version]$pinnedMatch.Value
        if($installed-gt$pinned){return 'DowngradeRequired'}
        return 'PinnedUpdatePending'
    }catch{return 'Blocked'}
}

function Get-KIUpstreamStatusFromVersions {
    param([string]$AvailableVersion,[string]$PinnedVersion)
    try{
        $availableMatch=[regex]::Match($AvailableVersion,'^\d+(\.\d+){1,3}')
        $pinnedMatch=[regex]::Match($PinnedVersion,'^\d+(\.\d+){1,3}')
        if(-not$availableMatch.Success-or-not$pinnedMatch.Success){return 'Unknown'}
        if(([version]$availableMatch.Value)-gt([version]$pinnedMatch.Value)){return 'UpdateAvailableUpstream'}
        return 'Current'
    }catch{return 'Unknown'}
}

# Real, read-only upstream-version detection per component -- reused, well-known, canonical
# sources only (PyPI's own JSON API for a PyPI-distributed package; GitHub's own commits API for
# a component whose payload contract already pins a specific upstream Git revision). Never
# installs or acts on the result; a component with no such reliable source reports Unknown
# instead of guessing. Any failure (no network, API error, missing metadata) degrades to Unknown
# with a short reason -- it must never block or crash the plan/check.
function Get-KIUpstreamInfo {
    param([Parameter(Mandatory)][string]$ComponentId,[Parameter(Mandatory)][string]$PinnedVersion,[Parameter(Mandatory)][string]$InstallerRoot,[hashtable]$UpstreamFixture,[int]$TimeoutSeconds=6)
    if($UpstreamFixture-and$UpstreamFixture.ContainsKey($ComponentId)){
        $f=$UpstreamFixture[$ComponentId]
        return [pscustomobject]@{availableVersion=[string]$f.availableVersion;upstreamStatus=[string]$f.upstreamStatus;upstreamSource=[string]$f.upstreamSource}
    }
    if($ComponentId-eq'openwebui'){
        try{
            $response=Invoke-RestMethod -Uri 'https://pypi.org/pypi/open-webui/json' -TimeoutSec $TimeoutSeconds -ErrorAction Stop
            $available=[string]$response.info.version
            if([string]::IsNullOrWhiteSpace($available)){throw 'PyPI-Antwort enthielt keine info.version.'}
            $status=Get-KIUpstreamStatusFromVersions -AvailableVersion $available -PinnedVersion $PinnedVersion
            return [pscustomobject]@{availableVersion=$available;upstreamStatus=$status;upstreamSource='PyPI:open-webui'}
        }catch{
            return [pscustomobject]@{availableVersion='Unknown';upstreamStatus='Unknown';upstreamSource="PyPI-Abfrage fehlgeschlagen: $($_.Exception.Message)"}
        }
    }
    $gitRevisionPayloads=@{comfyui='ComfyUI';integration='Integration'}
    if($gitRevisionPayloads.ContainsKey($ComponentId)){
        $payloadName=$gitRevisionPayloads[$ComponentId]
        $extractDir=$null
        try{
            $extractDir=Join-Path ([IO.Path]::GetTempPath()) ('ki-update-all-upstream-'+[guid]::NewGuid().ToString('N'))
            $root=Expand-KICompletePayload -PackageRoot $InstallerRoot -PayloadName $payloadName -Destination $extractDir
            $contractPath=Join-Path $root 'Payload/PAYLOAD-CONTRACT.json'
            if(-not(Test-Path -LiteralPath $contractPath -PathType Leaf)){throw "PAYLOAD-CONTRACT.json nicht im $payloadName-Payload gefunden."}
            $contract=Get-Content -LiteralPath $contractPath -Raw|ConvertFrom-Json -Depth 20
            $repo=[string]$contract.upstream.repository
            $pinnedRevision=[string]$contract.upstream.revision
            if([string]::IsNullOrWhiteSpace($repo)-or[string]::IsNullOrWhiteSpace($pinnedRevision)){throw 'Payload-Contract enthält kein upstream.repository/revision.'}
            $repoPath=$repo-replace'^https://github\.com/',''
            $latest=Invoke-RestMethod -Uri "https://api.github.com/repos/$repoPath/commits/HEAD" -TimeoutSec $TimeoutSeconds -Headers @{'User-Agent'='KI-Stack-Update-Checker'} -ErrorAction Stop
            $latestSha=[string]$latest.sha
            if([string]::IsNullOrWhiteSpace($latestSha)){throw 'GitHub-Antwort enthielt keine commit sha.'}
            $shortAvailable=$latestSha.Substring(0,[Math]::Min(12,$latestSha.Length))
            $shortPinned=$pinnedRevision.Substring(0,[Math]::Min(12,$pinnedRevision.Length))
            $status=if($latestSha-eq$pinnedRevision){'Current'}else{'UpdateAvailableUpstream'}
            return [pscustomobject]@{availableVersion=$shortAvailable;upstreamStatus=$status;upstreamSource="GitHub:$repoPath@HEAD (gepinnt: $shortPinned)"}
        }catch{
            return [pscustomobject]@{availableVersion='Unknown';upstreamStatus='Unknown';upstreamSource="Upstream-Prüfung fehlgeschlagen: $($_.Exception.Message)"}
        }finally{
            if($extractDir-and(Test-Path -LiteralPath $extractDir)){Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue}
        }
    }
    # KI-Stack-authored bundles (agent/visual/ballistics packs, models-workflows, codex-local,
    # rag, and every other Contracts/COMPONENTS.json entry) have no external upstream project
    # version to compare against -- reporting Unknown here is structurally correct, not a gap.
    return [pscustomobject]@{availableVersion='Unknown';upstreamStatus='Unknown';upstreamSource='keine belastbare Upstream-Quelle für diese Komponente vorhanden'}
}

# Real, read-only PUBLISHED-version detection for KI-Stack-own components (Contracts/
# COMPONENTS.json versionSourceType: own-version-file/own-manifest-field), via
# Lifecycle/KIStackComponentVersionRegistry.psm1 -- separate from, and never confused with,
# Get-KIUpstreamInfo above (which tracks the EXTERNAL upstream project a component wraps, e.g.
# the real ComfyUI/OpenWebUI application; this tracks the component PACKAGE's own next
# available version, the actual axis Get-KIPinClassification's PinnedUpdatePending/UpToDate/
# DowngradeRequired decision already reasons about). Purely additional/informational -- it
# never feeds into what New-KICompletePlan actually updates.
$script:KILatestCompleteInstallerReleaseCache=$null
function Get-KIPackageVersionInfo{
    param(
        [Parameter(Mandatory)][object]$RawComponent,
        [Parameter(Mandatory)][AllowEmptyString()][string]$InstalledVersion,
        [hashtable]$LatestReleaseFixture,
        [hashtable]$ComponentVersionFixtures
    )
    $componentId=[string]$RawComponent.id
    $versionSourceType=if($RawComponent.PSObject.Properties['versionSourceType']){[string]$RawComponent.versionSourceType}else{$null}
    if([string]::IsNullOrWhiteSpace($versionSourceType)){
        return [pscustomobject]@{componentId=$componentId;installedVersion=$InstalledVersion;availableVersion=$null;versionSource='Kein Registry-Eintrag (versionSourceType fehlt in Contracts/COMPONENTS.json).';status='VersionUnavailable'}
    }
    if($versionSourceType-eq'bundled-reference-only'){
        throw "Get-KIPackageVersionInfo darf für versionSourceType 'bundled-reference-only' nicht direkt aufgerufen werden (Komponente: $componentId) -- siehe referenceComponent-Zweitpass."
    }
    if($null-eq$script:KILatestCompleteInstallerReleaseCache){
        # Fetched at most once per script invocation, shared by every own-* component --
        # never re-queried per component (would be a needless, slow, repeated network call
        # for what is always the exact same answer within one run).
        $script:KILatestCompleteInstallerReleaseCache=Get-KIStackLatestPublishedCompleteInstallerRelease -Fixture $LatestReleaseFixture
    }
    $release=$script:KILatestCompleteInstallerReleaseCache
    if(-not$release.found){
        return [pscustomobject]@{componentId=$componentId;installedVersion=$InstalledVersion;availableVersion=$null;versionSource=[string]$release.reason;status='VersionUnavailable'}
    }
    $componentFixture=if($ComponentVersionFixtures-and$ComponentVersionFixtures.ContainsKey($componentId)){$ComponentVersionFixtures[$componentId]}else{$null}
    $published=Get-KIStackPublishedComponentVersion -PackageIdentity $RawComponent.packageIdentity -Tag ([string]$release.tag) -Fixture $componentFixture
    $source=if($published.found){"Complete-Installer-Release $($release.tag): $([string]$RawComponent.packageIdentity.path)"}else{[string]$published.reason}
    Resolve-KIStackComponentVersion -ComponentId $componentId -InstalledVersion $InstalledVersion -VersionSourceType $versionSourceType -PublishedVersion $published.version -PublishedVersionSource $source -PublishedVersionAvailable ([bool]$published.found)
}

# 1. Enumerate every Complete-Installer-managed component via the existing, read-only Audit plan.
#    This is the same New-KICompletePlan the real installer itself uses -- no separate enumeration logic.
$plan=New-KICompletePlan -Mode Audit -PackageRoot $installerRoot -TargetRoot $TargetRoot -FixtureState $FixtureState
$report=[Collections.Generic.List[object]]::new()
foreach($step in $plan.steps){
    $selected=($Component.Count-eq0-or$Component-contains$step.id)
    $installedVersion=[string]$step.initialState.installedVersion
    $pinnedVersion=[string]$step.version
    $classification=Get-KIPinClassification -InstalledVersion $installedVersion -PinnedVersion $pinnedVersion -Compliant ([bool]$step.initialState.compliant)
    $upstream=if($selected){Get-KIUpstreamInfo -ComponentId ([string]$step.id) -PinnedVersion $pinnedVersion -InstallerRoot $installerRoot -UpstreamFixture $UpstreamFixture}else{[pscustomobject]@{availableVersion='Unknown';upstreamStatus='Unknown';upstreamSource='nicht ausgewählt (-Component)'}}
    $isoMeta=$isolationMetaById[[string]$step.id]
    $report.Add([pscustomobject][ordered]@{
        id=[string]$step.id;name=[string]$step.name
        installedVersion=$installedVersion;pinnedVersion=$pinnedVersion
        availableVersion=$upstream.availableVersion;upstreamStatus=$upstream.upstreamStatus;upstreamSource=$upstream.upstreamSource
        classification=$classification;contract='CompleteInstallerUpgrade';selected=$selected
        isolation=[string]$isoMeta.isolation;requires=@($isoMeta.requires);isolatedExecutionImplemented=[bool]$isoMeta.isolatedExecutionImplemented;executionRoute=[string]$isoMeta.executionRoute
    })
}

# 1b. KI-Stack-own package version registry (Section: Versions-/Registry-Vertrag). Two passes
#     over the just-built $report, driven by Contracts/COMPONENTS.json's versionSourceType --
#     first every component with its own real source (own-version-file/own-manifest-field),
#     then every bundled-reference-only id (foundation-runtime/python-git/applications/
#     target-acceptance) mirrors its referenceComponent's already-resolved answer, since it has
#     no independent source of its own to check. Only computed for selected components (same
#     gating Get-KIUpstreamInfo already uses) so an unselected -Component run never makes
#     needless network calls.
$packageVersionInfoById=@{}
foreach($rc in $rawComponentContract.components){
    $componentId=[string]$rc.id
    $versionSourceType=if($rc.PSObject.Properties['versionSourceType']){[string]$rc.versionSourceType}else{$null}
    if($versionSourceType-eq'bundled-reference-only'-or[string]::IsNullOrWhiteSpace($versionSourceType)){continue}
    $reportRow=@($report|Where-Object{[string]$_.id-eq$componentId})|Select-Object -First 1
    if($null-eq$reportRow-or-not[bool]$reportRow.selected){continue}
    # Indexer syntax ($h['x']), not dot-property syntax, on a [hashtable] -- under Set-StrictMode
    # -Version Latest (this script's own setting), hashtable dot-access throws
    # PropertyNotFoundException for a key that is simply absent (verified directly); a caller's
    # -PackageVersionRegistryFixture is not required to supply both latestRelease and
    # componentVersions.
    $latestReleaseFixture=if($PackageVersionRegistryFixture){$PackageVersionRegistryFixture['latestRelease']}else{$null}
    $componentVersionFixtures=if($PackageVersionRegistryFixture){$PackageVersionRegistryFixture['componentVersions']}else{$null}
    $packageVersionInfoById[$componentId]=Get-KIPackageVersionInfo -RawComponent $rc -InstalledVersion ([string]$reportRow.installedVersion) -LatestReleaseFixture $latestReleaseFixture -ComponentVersionFixtures $componentVersionFixtures
}
foreach($rc in $rawComponentContract.components){
    $componentId=[string]$rc.id
    $versionSourceType=if($rc.PSObject.Properties['versionSourceType']){[string]$rc.versionSourceType}else{$null}
    if($versionSourceType-ne'bundled-reference-only'){continue}
    $reportRow=@($report|Where-Object{[string]$_.id-eq$componentId})|Select-Object -First 1
    if($null-eq$reportRow-or-not[bool]$reportRow.selected){continue}
    $referenceId=[string]$rc.referenceComponent
    $referenced=$packageVersionInfoById[$referenceId]
    if($null-eq$referenced){
        $packageVersionInfoById[$componentId]=[pscustomobject]@{componentId=$componentId;installedVersion=[string]$reportRow.installedVersion;availableVersion=$null;versionSource="Referenzkomponente '$referenceId' nicht aufgelöst.";status='VersionUnavailable'}
    }else{
        # Only the STATUS is mirrored, never the referenced component's raw available-version
        # number: foundation-runtime/python-git/applications/target-acceptance each use their
        # own, unrelated numbering scheme (documentation labels only -- installable:false, no
        # independent installed-marker exists for any of them) that is never meant to be
        # compared against e.g. cutover-runtime's "1.6.14". Reporting that number next to this
        # component's own, differently-scaled installedVersion would silently produce a wrong
        # UpToDate/UpdateAvailable/NewerInstalled verdict (verified while building this: e.g.
        # foundation-runtime installed=1.0.9 vs a mirrored availableVersion=1.6.14 numerically
        # compares as UpdateAvailable/NewerInstalled despite meaning nothing on its own).
        # Whether action is needed is still correctly answered -- it is, precisely when and only
        # when the shared BuilderKernel execution unit it rides on needs updating -- so status
        # alone is mirrored, availableVersion is left null.
        $packageVersionInfoById[$componentId]=[pscustomobject]@{
            componentId=$componentId;installedVersion=[string]$reportRow.installedVersion
            availableVersion=$null
            versionSource="Gebündelt mit '$referenceId' (eigene Versionsnummer nicht unabhängig vergleichbar; Status übernommen): $($referenced.versionSource)"
            status=$referenced.status
        }
    }
}
foreach($row in $report){
    $info=$packageVersionInfoById[[string]$row.id]
    if($null-ne$info){
        $row|Add-Member -NotePropertyName packageAvailableVersion -NotePropertyValue $info.availableVersion
        $row|Add-Member -NotePropertyName packageVersionSource -NotePropertyValue $info.versionSource
        $row|Add-Member -NotePropertyName packageVersionStatus -NotePropertyValue $info.status
    }
}

# 2. OpenWebUI is not tracked by Contracts/COMPONENTS.json at all (Complete Installer only sees the
#    Applications *bundle* version); its own version lives in kernel-config.json / the managed venv,
#    exactly as Update-KIStack-OpenWebUI.ps1 itself reads them. Reused here read-only, for reporting
#    only -- no install/upgrade/rollback logic is duplicated. It already has its own real,
#    single-component contract (Update-KIStack-OpenWebUI.cmd), so its executionRoute is its own
#    dedicated adapter, never the Complete-Installer batch and never the new generic isolated
#    executor (which knows nothing about OpenWebUI).
$owuiSelected=($Component.Count-eq0-or$Component-contains'openwebui')
$owuiInstalled=$null;$owuiPinned=$null;$owuiClassification='Blocked'
$owuiExtract=$null
if($owuiSelected){
    if($OpenWebUIFixture){
        $owuiInstalled=[string]$OpenWebUIFixture.installedVersion
        $owuiPinned=[string]$OpenWebUIFixture.targetVersion
        $owuiClassification=Get-KIPinClassification -InstalledVersion $owuiInstalled -PinnedVersion $owuiPinned -Compliant ($owuiInstalled-eq$owuiPinned)
    }else{
        try{
            $owuiExtract=Join-Path ([IO.Path]::GetTempPath()) ('ki-update-all-owui-'+[guid]::NewGuid().ToString('N'))
            $cutoverRoot=Expand-KICompletePayload -PackageRoot $installerRoot -PayloadName 'CutoverRuntime' -Destination $owuiExtract
            Import-Module (Join-Path $cutoverRoot 'Core/KIStack.BuilderKernel.Core.psm1') -Force -Global
            Import-Module (Join-Path $cutoverRoot 'Modules/06-Applications/KIModuleApplications.psm1') -Force -Global
            $kernelConfig=Read-KIJson -Path (Join-Path $cutoverRoot 'Config/kernel-config.json')
            $owuiPinned=[string]$kernelConfig.applications.openWebUI.version
            $readOnlyContext=[pscustomobject][ordered]@{Config=$kernelConfig}
            $owuiInstalled=Get-KIOpenWebUIVersion -Context $readOnlyContext
            $owuiClassification=Get-KIPinClassification -InstalledVersion $owuiInstalled -PinnedVersion $owuiPinned -Compliant ($owuiInstalled-eq$owuiPinned)
        }catch{
            $owuiClassification='Blocked'
        }finally{
            if($owuiExtract-and(Test-Path -LiteralPath $owuiExtract)){Remove-Item -LiteralPath $owuiExtract -Recurse -Force -ErrorAction SilentlyContinue}
        }
    }
    $owuiUpstream=Get-KIUpstreamInfo -ComponentId 'openwebui' -PinnedVersion $owuiPinned -InstallerRoot $installerRoot -UpstreamFixture $UpstreamFixture
    $report.Add([pscustomobject][ordered]@{
        id='openwebui';name='OpenWebUI'
        installedVersion=$owuiInstalled;pinnedVersion=$owuiPinned
        availableVersion=$owuiUpstream.availableVersion;upstreamStatus=$owuiUpstream.upstreamStatus;upstreamSource=$owuiUpstream.upstreamSource
        classification=$owuiClassification;contract='Update-KIStack-OpenWebUI';selected=$true
        isolation='A';requires=@();isolatedExecutionImplemented=$true;executionRoute='OpenWebUIAdapter'
    })
}

# 3. Any explicitly requested -Component id that matches neither a Contracts/COMPONENTS.json
#    entry nor the dedicated openwebui adapter is not managed by KI-Stack at all; report it as
#    NotManaged instead of silently dropping it. 'complete-installer' is a special pseudo-id
#    (see Resolve-KIStackUpdatePlan -CompleteInstallerExplicitlySelected) meaning "run the real,
#    full batch on purpose" -- it is never itself a managed component row.
if($Component.Count-gt0){
    $knownIds=@($report|ForEach-Object{$_.id})
    foreach($requestedId in @($Component|Select-Object -Unique)){
        if($requestedId-eq'complete-installer'){continue}
        if($knownIds-notcontains$requestedId){
            $report.Add([pscustomobject][ordered]@{
                id=$requestedId;name=$requestedId
                installedVersion=$null;pinnedVersion=$null
                availableVersion='Unknown';upstreamStatus='Unknown';upstreamSource='Komponente nicht verwaltet'
                classification='NotManaged';contract=$null;selected=$true
                isolation=$null;requires=@();isolatedExecutionImplemented=$false;executionRoute=$null
            })
        }
    }
}

Write-Host ''
Write-Host '=== KI-Stack Update-Checker: Plan ===' -ForegroundColor Cyan
$report|Sort-Object id|Format-Table -AutoSize id,installedVersion,pinnedVersion,availableVersion,classification,upstreamStatus,packageAvailableVersion,packageVersionStatus,selected,isolation,executionRoute|Out-String|Write-Host

# Component-isolation planning: a pure, structured resolution of what would actually be
# touched by the current -Component selection, driven entirely by Contracts/COMPONENTS.json's
# isolation metadata -- never a batch run unless the plan says so, and never silently. This
# SAME plan (and this same function call) is used for both -CheckOnly and real execution below,
# so DryRun and Execute can never diverge in what they would do (Section 8's contract).
$completeInstallerExplicitlySelected=($Component-contains'complete-installer')
# The whole if/else must be wrapped in the outer @() -- wrapping only the empty-array branch
# ("if(...){@()}else{...}") still collapses to $null at the assignment site once that branch
# is the one actually taken, and @($null) is a one-element array (Count 1), not an empty one
# -- which would make Resolve-KIStackUpdatePlan's own "no filter means select everything"
# check see a false, phantom single (null) selection instead of "nothing was requested".
$selectedForPlan=@(if($Component.Count-gt0){$Component|Where-Object{$_-ne'complete-installer'}})
$isolationPlan=Resolve-KIStackUpdatePlan -AvailableComponents (@($report|Where-Object{$_.classification-ne'NotManaged'})) -SelectedComponentIds $selectedForPlan -CompleteInstallerExplicitlySelected:$completeInstallerExplicitlySelected

Write-Host ''
Write-Host '=== Component-Isolation-Plan ===' -ForegroundColor Cyan
Write-Host ("Selected: {0}" -f $(if(@($isolationPlan.selectedComponents).Count){$isolationPlan.selectedComponents-join', '}else{'(alle)'}))
Write-Host ("Dependencies: {0}" -f $(if(@($isolationPlan.requiredDependencies).Count){(@($isolationPlan.requiredDependencies)|ForEach-Object{"$($_.id) (für $($_.requiredBy), $(if($_.alreadySatisfied){'bereits erfüllt'}else{'benötigt Aktion'}))"})-join', '}else{'keine'}))
Write-Host ("Will update: {0}" -f $(if(@($isolationPlan.plannedUpdates).Count){(@($isolationPlan.plannedUpdates)|ForEach-Object{"$($_.id) $($_.installedVersion) -> $($_.pinnedVersion) [$($_.executionRoute)]"})-join', '}else{'keine'}))
Write-Host ("Will preserve: {0}" -f $(if(@($isolationPlan.preservedComponents).Count){(@($isolationPlan.preservedComponents)|ForEach-Object id)-join', '}else{'keine'}))
if(@($isolationPlan.blockedComponents).Count){
    Write-Host ("Cannot update: {0}" -f ((@($isolationPlan.blockedComponents)|ForEach-Object{"$($_.id): $($_.reason)"})-join' || ')) -ForegroundColor Red
}
if($isolationPlan.cyclicDependencyError){
    Write-Host $isolationPlan.cyclicDependencyError -ForegroundColor Red
}

$batchBlockedReason=if(@($isolationPlan.blockedComponents).Count-and-not$completeInstallerExplicitlySelected){(@($isolationPlan.blockedComponents)|ForEach-Object{"$($_.id): $($_.reason)"})-join' || '}else{$null}

$result=[ordered]@{mode=if($CheckOnly){'CheckOnly'}else{'Plan'};plan=@($report);executed=@();isolationPlan=$isolationPlan}
if($batchBlockedReason){$result.batchExecutionBlocked=$batchBlockedReason}
if($isolationPlan.cyclicDependencyError){$result.batchExecutionBlocked=$isolationPlan.cyclicDependencyError}

if($CheckOnly){
    [pscustomobject]$result|ConvertTo-Json -Depth 12
    exit 0
}

$owuiPlanned=@($isolationPlan.plannedUpdates|Where-Object id -eq 'openwebui')
$nonOwuiPlanned=@($isolationPlan.plannedUpdates|Where-Object id -ne 'openwebui')
if(@($isolationPlan.plannedUpdates).Count-eq0-and-not$isolationPlan.cyclicDependencyError-and@($isolationPlan.blockedComponents).Count-eq0){
    Write-Host 'Keine ausgewählte Komponente benötigt ein Update.' -ForegroundColor Green
    $result.mode='NoActionNeeded'
    [pscustomobject]$result|ConvertTo-Json -Depth 12
    exit 0
}

if($isolationPlan.cyclicDependencyError-or(@($isolationPlan.blockedComponents).Count-and-not$completeInstallerExplicitlySelected)){
    Write-Host ''
    Write-Host "FEHLER: $(if($isolationPlan.cyclicDependencyError){$isolationPlan.cyclicDependencyError}else{$batchBlockedReason})" -ForegroundColor Red
    $result.mode='Blocked'
    [pscustomobject]$result|ConvertTo-Json -Depth 12
    exit 1
}

if(-not$NonInteractive){
    Write-Host ''
    Write-Host 'Folgende Komponenten würden aktualisiert:' -ForegroundColor Yellow
    $isolationPlan.plannedUpdates|ForEach-Object{Write-Host "  - $($_.id): $($_.installedVersion) -> $($_.pinnedVersion) ($($_.classification), $($_.executionRoute))" -ForegroundColor Yellow}
    $confirmation=Read-Host 'Mit EXECUTE bestätigen, um fortzufahren, sonst abbrechen'
    if($confirmation-ne'EXECUTE'){
        Write-Host 'Abgebrochen; keine Änderung vorgenommen.' -ForegroundColor Yellow
        $result.mode='Cancelled'
        [pscustomobject]$result|ConvertTo-Json -Depth 12
        exit 0
    }
}

$executed=[Collections.Generic.List[object]]::new()
$failed=$false

# Step order: the dedicated OpenWebUI adapter first (isolated, single-component contract),
# then every component the plan routed to the new generic isolated executor (each fully
# independent -- one component's failure never blocks or retroactively un-does another's
# already-completed, independent result), and only then -- and only if the plan actually
# placed anything on that route -- a single real Complete Installer Upgrade run for the
# components that still have no isolated path today. A component never reaches the batch
# route unless the plan explicitly put it there.
$owuiNeedsAction=@($owuiPlanned).Count-gt0
if($owuiNeedsAction-and-not$failed){
    $owuiScript=Join-Path $TargetRoot 'Update-KIStack-OpenWebUI.cmd'
    if(-not(Test-Path -LiteralPath $owuiScript -PathType Leaf)){
        $executed.Add([pscustomobject][ordered]@{id='openwebui';outcome='Blocked';detail='Update-KIStack-OpenWebUI.cmd ist auf diesem Ziel nicht deployt.'})
        $failed=$true
    }else{
        try{
            $owuiOutput=& $owuiScript
            $owuiExitCode=$LASTEXITCODE
            $owuiJson=($owuiOutput|Where-Object{$_-match'^\s*\{'}|Out-String)|ConvertFrom-Json
            if($null-eq$owuiJson){throw "Update-KIStack-OpenWebUI.cmd lieferte keine auswertbare JSON-Ausgabe (Exitcode $owuiExitCode)."}
            # A non-zero exit code or a non-success status is a real failure, but
            # Update-KIStack-OpenWebUI.ps1's own JSON (including its rollback detail, when it
            # already rolled itself back) is still surfaced here instead of being discarded --
            # only a genuinely unparseable/missing response falls through to the catch below.
            if($owuiExitCode-ne0-or$owuiJson.status-notin@('Completed','Skip')){
                $executed.Add([pscustomobject][ordered]@{id='openwebui';outcome=$(if([string]$owuiJson.status){[string]$owuiJson.status}else{'Failed'});detail=$owuiJson})
                $failed=$true
            }else{
                $executed.Add([pscustomobject][ordered]@{id='openwebui';outcome=$owuiJson.status;detail=$owuiJson})
            }
        }catch{
            $executed.Add([pscustomobject][ordered]@{id='openwebui';outcome='Failed';detail=$_.Exception.Message})
            $failed=$true
        }
    }
}

$isolatedPlanned=@($nonOwuiPlanned|Where-Object{[string]$_.executionRoute-eq'Isolated'})
if($isolatedPlanned.Count-and-not$failed){
    for($isoIndex=0;$isoIndex-lt$isolatedPlanned.Count;$isoIndex++){
        $item=$isolatedPlanned[$isoIndex]
        $componentContractEntry=@($rawComponentContract.components|Where-Object{[string]$_.id-eq[string]$item.id})|Select-Object -First 1
        # No credential parameter is passed here at all -- Update-KIStack-All.ps1 never
        # accepts, decrypts, or forwards one (see Test-KIStackUpdateAll.ps1's
        # noSecretHandlingIntroduced check); a component whose isolated path requires an
        # OpenWebUI admin token (openwebui-agent-pack/openwebui-visual-pack/
        # openwebui-ballistics-pack) always reports WaitingForUserAction from here, exactly as
        # it already does today when routed through the Complete-Installer batch instead.
        $isoResult=Invoke-KIStackIsolatedComponentUpdate -ComponentId ([string]$item.id) -PackageRoot $installerRoot -TargetRoot $TargetRoot -Component $componentContractEntry -Config $completeConfig
        $executed.Add([pscustomobject][ordered]@{id=$item.id;outcome=$isoResult.outcome;detail=$isoResult.detail;backupPath=$isoResult.backupPath})
        # Each isolated component is fully independent (own extraction dir, own backup, own
        # try/catch) -- a failure here stops the REST of this isolated loop (so a batch-routed
        # component further down never silently proceeds past an unrelated, unexplained
        # failure), but it never retroactively invalidates an already-Completed prior item in
        # $executed, and it never touches anything outside this one component's own footprint.
        # Anything still queued behind the failure is explicitly recorded as NotRun rather than
        # silently omitted (Fehlerisolation: "nicht gestartete Komponenten korrekt als
        # skipped/not-run markieren").
        if($isoResult.outcome-notin@('Completed')){
            $failed=$true
            for($remainingIndex=$isoIndex+1;$remainingIndex-lt$isolatedPlanned.Count;$remainingIndex++){
                $executed.Add([pscustomobject][ordered]@{id=$isolatedPlanned[$remainingIndex].id;outcome='NotRun';detail='Nicht gestartet: eine vorherige isolierte Komponente in derselben Auswahl ist fehlgeschlagen.'})
            }
            break
        }
    }
}

$batchPlanned=@($nonOwuiPlanned|Where-Object{[string]$_.executionRoute-eq'CompleteInstallerBatch'})
if($batchPlanned.Count-and$failed){
    foreach($componentResult in $batchPlanned){
        $executed.Add([pscustomobject][ordered]@{id=$componentResult.id;outcome='NotRun';detail='Nicht gestartet: eine vorherige Komponente in derselben Auswahl ist fehlgeschlagen.'})
    }
}
elseif($batchPlanned.Count){
    try{
        $upgradeResult=Invoke-KIStackCompleteInstaller -Mode Upgrade -PackageRoot $installerRoot -TargetRoot $TargetRoot
        foreach($componentResult in $batchPlanned){
            $stepResult=@($upgradeResult.steps|Where-Object id -eq $componentResult.id)|Select-Object -First 1
            $executed.Add([pscustomobject][ordered]@{id=$componentResult.id;outcome=if($stepResult){[string]$stepResult.status}else{'Unknown'};detail=$stepResult})
        }
        if($upgradeResult.status-notin@('Completed','WaitingForUserAction','StateReconciled','SkippedAlreadyCompliant')){$failed=$true}
    }catch{
        $executed.Add([pscustomobject][ordered]@{id='(complete-installer-upgrade-batch)';outcome='Failed';detail=$_.Exception.Message})
        $failed=$true
    }
}

$result.mode=if($failed){'Failed'}else{'Executed'}
$result.executed=@($executed)
[pscustomobject]$result|ConvertTo-Json -Depth 12
if($failed){exit 1}
exit 0

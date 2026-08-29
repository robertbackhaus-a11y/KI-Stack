[CmdletBinding()]
param(
    [string]$TargetRoot='C:\KI-Stack',
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
    # Invoke-KIStackCompleteInstaller) and is never itself driven by upstream data.
    [hashtable]$FixtureState,
    [hashtable]$OpenWebUIFixture,
    [hashtable]$UpstreamFixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw 'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}

$installerRoot=Join-Path $TargetRoot 'installer/complete'
$completeModulePath=Join-Path $installerRoot 'CompleteInstaller.psm1'
if(-not(Test-Path -LiteralPath $completeModulePath -PathType Leaf)){throw "Complete-Installer-Paket fehlt unter $installerRoot; Update-Checker kann nicht laufen."}
Import-Module $completeModulePath -Force

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
    $report.Add([pscustomobject][ordered]@{
        id=[string]$step.id;name=[string]$step.name
        installedVersion=$installedVersion;pinnedVersion=$pinnedVersion
        availableVersion=$upstream.availableVersion;upstreamStatus=$upstream.upstreamStatus;upstreamSource=$upstream.upstreamSource
        classification=$classification;contract='CompleteInstallerUpgrade';selected=$selected
    })
}

# 2. OpenWebUI is not tracked by Contracts/COMPONENTS.json at all (Complete Installer only sees the
#    Applications *bundle* version); its own version lives in kernel-config.json / the managed venv,
#    exactly as Update-KIStack-OpenWebUI.ps1 itself reads them. Reused here read-only, for reporting
#    only -- no install/upgrade/rollback logic is duplicated.
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
    })
}

# 3. Any explicitly requested -Component id that matches neither a Contracts/COMPONENTS.json
#    entry nor the dedicated openwebui adapter is not managed by KI-Stack at all; report it as
#    NotManaged instead of silently dropping it.
if($Component.Count-gt0){
    $knownIds=@($report|ForEach-Object{$_.id})
    foreach($requestedId in @($Component|Select-Object -Unique)){
        if($knownIds-notcontains$requestedId){
            $report.Add([pscustomobject][ordered]@{
                id=$requestedId;name=$requestedId
                installedVersion=$null;pinnedVersion=$null
                availableVersion='Unknown';upstreamStatus='Unknown';upstreamSource='Komponente nicht verwaltet'
                classification='NotManaged';contract=$null;selected=$true
            })
        }
    }
}

Write-Host ''
Write-Host '=== KI-Stack Update-Checker: Plan ===' -ForegroundColor Cyan
$report|Sort-Object id|Format-Table -AutoSize id,installedVersion,pinnedVersion,availableVersion,classification,upstreamStatus,selected|Out-String|Write-Host

# -Component narrows WHICH rows are reported/selected, but the Complete-Installer-Upgrade batch
# contract has no per-component isolation: a real run of it reconciles every currently
# non-compliant Contracts/COMPONENTS.json component in one transaction, regardless of -Component.
# Detect up front whether an explicit -Component selection would understate that scope, so the
# tool never suggests "only this one component will change" when the batch would in fact touch
# more. OpenWebUI is exempt -- it has its own real single-component contract.
$allBatchNeedingAction=@($report|Where-Object{$_.contract-eq'CompleteInstallerUpgrade'-and$_.classification-in@('PinnedUpdatePending','DowngradeRequired')})
$selectedBatchNeedingAction=@($allBatchNeedingAction|Where-Object selected)
$componentFilterGiven=$Component.Count-gt0
$batchSelectionUnderstatesScope=$componentFilterGiven-and$selectedBatchNeedingAction.Count-gt0-and$selectedBatchNeedingAction.Count-lt$allBatchNeedingAction.Count
$batchBlockedReason=$null
if($batchSelectionUnderstatesScope){
    $omittedIds=@($allBatchNeedingAction|Where-Object{-not$_.selected}|ForEach-Object{$_.id})
    $batchBlockedReason="Der Complete-Installer-Upgrade-Vertrag ist ein Batch-Vertrag ohne Einzelkomponenten-Isolation. -Component $($Component -join ',') würde fälschlich suggerieren, nur diese Komponente(n) zu verändern -- tatsächlich würde ein Upgrade-Lauf zusätzlich folgende noch nicht konforme Komponenten mit anfassen: $($omittedIds -join ', '). Entweder alle betroffenen Komponenten gemeinsam über -Component angeben (oder -Component ganz weglassen), oder nur -CheckOnly verwenden."
}

$result=[ordered]@{mode=if($CheckOnly){'CheckOnly'}else{'Plan'};plan=@($report);executed=@()}
if($batchBlockedReason){$result.batchExecutionBlocked=$batchBlockedReason}

if($CheckOnly){
    [pscustomobject]$result|ConvertTo-Json -Depth 10
    exit 0
}

$selectedNeedingAction=@($report|Where-Object{$_.selected-and$_.classification-in@('PinnedUpdatePending','DowngradeRequired')})
if($selectedNeedingAction.Count-eq0){
    Write-Host 'Keine ausgewählte Komponente benötigt ein Update.' -ForegroundColor Green
    $result.mode='NoActionNeeded'
    [pscustomobject]$result|ConvertTo-Json -Depth 10
    exit 0
}

if($batchSelectionUnderstatesScope){
    Write-Host ''
    Write-Host "FEHLER: $batchBlockedReason" -ForegroundColor Red
    $result.mode='Blocked'
    [pscustomobject]$result|ConvertTo-Json -Depth 10
    exit 1
}

if(-not$NonInteractive){
    Write-Host ''
    Write-Host 'Folgende Komponenten würden aktualisiert:' -ForegroundColor Yellow
    $selectedNeedingAction|ForEach-Object{Write-Host "  - $($_.id): $($_.installedVersion) -> $($_.pinnedVersion) ($($_.classification))" -ForegroundColor Yellow}
    if($selectedBatchNeedingAction.Count-gt0){
        Write-Host ''
        Write-Host "Hinweis: Der Complete-Installer-Upgrade-Batch führt ALLE aktuell erforderlichen gepinnten Änderungen des Plans in einem Lauf aus (nicht nur die oben einzeln aufgeführten Batch-Komponenten isoliert): $($selectedBatchNeedingAction.id -join ', ')." -ForegroundColor Yellow
    }
    $confirmation=Read-Host 'Mit EXECUTE bestätigen, um fortzufahren, sonst abbrechen'
    if($confirmation-ne'EXECUTE'){
        Write-Host 'Abgebrochen; keine Änderung vorgenommen.' -ForegroundColor Yellow
        $result.mode='Cancelled'
        [pscustomobject]$result|ConvertTo-Json -Depth 10
        exit 0
    }
}

$executed=[Collections.Generic.List[object]]::new()
$failed=$false

# Step order: the dedicated OpenWebUI adapter first (isolated, single-component contract), then --
# only if any other Complete-Installer-tracked component still needs action -- a single real
# Complete Installer Upgrade run, which already handles per-step backup/validate/rollback and stops
# on the first failing step instead of continuing past it.
$owuiNeedsAction=@($selectedNeedingAction|Where-Object id -eq 'openwebui').Count-gt0
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

$remainingNeedAction=@($selectedNeedingAction|Where-Object id -ne 'openwebui')
if($remainingNeedAction.Count-and-not$failed){
    try{
        $upgradeResult=Invoke-KIStackCompleteInstaller -Mode Upgrade -PackageRoot $installerRoot -TargetRoot $TargetRoot
        foreach($componentResult in $remainingNeedAction){
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
[pscustomobject]$result|ConvertTo-Json -Depth 10
if($failed){exit 1}
exit 0

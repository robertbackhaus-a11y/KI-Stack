[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Regression suite for Finalization-Rollback-P1: WriteFinalState as the real commit boundary,
# a reverse-order compensation stack for everything before it (Orchestrator/CentralStarters/
# Operations/Knowledge-Detach/CodeInterpreter), and the two-phase Knowledge-Experiment split
# (PRE-COMMIT Detach, fully reversible; POST-COMMIT Cleanup, best-effort, never rolled back).
#
# Tests the new/changed pieces directly and, where real HTTP would be involved, against a local
# mock of the OpenWebUI API surface actually used (function override technique, same as
# Test-KIStackComponentVersionRegistry.ps1's "gh" fixture and Test-KIStackOpenWebUICredentialBootstrap.ps1's
# mock server) -- never the real target (TargetRoot is explicitly out of scope for this P1) and
# never a real network call.

Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force -DisableNameChecking
$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-FinalizationRollback-'+[guid]::NewGuid().ToString('N'))

function Get-KISecureStringFixture([string]$PlainText){ ConvertTo-SecureString -String $PlainText -AsPlainText -Force }

try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force|Out-Null

    # === A. Restore-KICompleteOrchestrator ==================================================
    $orchTargetA=Join-Path $fixtureRoot 'orchestrator-a';$orchBackupA=Join-Path $fixtureRoot 'orchestrator-a-backup';$orchPackageA=Join-Path $fixtureRoot 'orchestrator-a-package'
    New-Item -ItemType Directory -Path $orchTargetA,$orchPackageA -Force|Out-Null
    $existingDest=Join-Path $orchTargetA 'installer/complete';New-Item -ItemType Directory -Path $existingDest -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $existingDest 'marker.txt') -Value 'original-v1' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $orchPackageA 'marker.txt') -Value 'incoming-v2' -Encoding UTF8
    $orchResultA=Install-KICompleteOrchestrator -PackageRoot $orchPackageA -TargetRoot $orchTargetA -BackupRoot $orchBackupA
    $afterInstallA=Get-Content -LiteralPath (Join-Path $existingDest 'marker.txt') -Raw
    $restoreA=Restore-KICompleteOrchestrator -TargetRoot $orchTargetA -ExistedBefore ([bool]$orchResultA.existedBefore) -BackupPath ([string]$orchResultA.backupPath)
    $afterRestoreA=Get-Content -LiteralPath (Join-Path $existingDest 'marker.txt') -Raw
    $checks.orchestratorRestore_ExistedBefore=[ordered]@{
        existedBeforeReportedTrue=([bool]$orchResultA.existedBefore)
        installOverwroteContent=($afterInstallA.Trim()-eq'incoming-v2')
        restoreStatusCompleted=([string]$restoreA.status-eq'OrchestratorRestored')
        restoreBroughtBackOriginalContent=($afterRestoreA.Trim()-eq'original-v1')
    }
    if($checks.orchestratorRestore_ExistedBefore.Values-contains$false){$fail.Add('orchestratorRestore_ExistedBefore failed: '+($checks.orchestratorRestore_ExistedBefore|ConvertTo-Json -Compress))}

    $orchTargetB=Join-Path $fixtureRoot 'orchestrator-b';$orchBackupB=Join-Path $fixtureRoot 'orchestrator-b-backup';$orchPackageB=Join-Path $fixtureRoot 'orchestrator-b-package'
    New-Item -ItemType Directory -Path $orchTargetB,$orchPackageB -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $orchPackageB 'marker.txt') -Value 'first-ever-install' -Encoding UTF8
    $orchResultB=Install-KICompleteOrchestrator -PackageRoot $orchPackageB -TargetRoot $orchTargetB -BackupRoot $orchBackupB
    $destExistsAfterInstallB=Test-Path -LiteralPath (Join-Path $orchTargetB 'installer/complete')
    $restoreB=Restore-KICompleteOrchestrator -TargetRoot $orchTargetB -ExistedBefore ([bool]$orchResultB.existedBefore) -BackupPath ([string]$orchResultB.backupPath)
    $destExistsAfterRestoreB=Test-Path -LiteralPath (Join-Path $orchTargetB 'installer/complete')
    $checks.orchestratorRestore_DidNotExistBefore=[ordered]@{
        existedBeforeReportedFalse=(-not [bool]$orchResultB.existedBefore)
        backupPathIsNull=([string]::IsNullOrEmpty([string]$orchResultB.backupPath))
        destinationCreatedByInstall=$destExistsAfterInstallB
        destinationRemovedByRestore=(-not $destExistsAfterRestoreB)
    }
    if($checks.orchestratorRestore_DidNotExistBefore.Values-contains$false){$fail.Add('orchestratorRestore_DidNotExistBefore failed: '+($checks.orchestratorRestore_DidNotExistBefore|ConvertTo-Json -Compress))}

    # === B. Restore-KICompleteCentralStarters ================================================
    $startersTargetA=Join-Path $fixtureRoot 'starters-a';$startersBackupA=Join-Path $fixtureRoot 'starters-a-backup';$startersPackageA=Join-Path $fixtureRoot 'starters-a-package/Lifecycle'
    New-Item -ItemType Directory -Path $startersTargetA,$startersPackageA -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $startersTargetA 'Start-KIStack.cmd') -Value 'original-starter-v1' -Encoding UTF8
    foreach($name in @('Start-KIStack.cmd','Stop-KIStack.cmd','Stop-KIStack-Managed.ps1','Validate-KIStack.cmd','Get-KIStackStatus.ps1','Show-KIStackStatus.ps1','Status-KIStack-Interactive.cmd','Repair-KIStack.cmd','Update-KIStack-OpenWebUI.cmd','Update-KIStack-OpenWebUI.ps1','Update-KIStack-All.cmd','Update-KIStack-All.ps1')){
        $content=if($name-eq'Start-KIStack.cmd'){'incoming-starter-v2'}else{"placeholder: $name"}
        Set-Content -LiteralPath (Join-Path $startersPackageA $name) -Value $content -Encoding UTF8
    }
    $startersResultA=Install-KICompleteCentralStarters -PackageRoot (Split-Path -Parent $startersPackageA) -TargetRoot $startersTargetA -BackupRoot $startersBackupA
    $startChangedA=@($startersResultA|Where-Object name -eq 'Start-KIStack.cmd')[0]
    $stopChangedA=@($startersResultA|Where-Object name -eq 'Stop-KIStack.cmd')[0]
    $afterInstallStartA=(Get-Content -LiteralPath (Join-Path $startersTargetA 'Start-KIStack.cmd') -Raw).Trim()
    $restoreStartersA=Restore-KICompleteCentralStarters -TargetRoot $startersTargetA -Changes $startersResultA
    $afterRestoreStartA=(Get-Content -LiteralPath (Join-Path $startersTargetA 'Start-KIStack.cmd') -Raw).Trim()
    $stopExistsAfterRestoreA=Test-Path -LiteralPath (Join-Path $startersTargetA 'Stop-KIStack.cmd')
    $checks.centralStartersRestore_MixedExistedAndNew=[ordered]@{
        startExistedBeforeTrue=([bool]$startChangedA.existedBefore)
        stopExistedBeforeFalse=(-not [bool]$stopChangedA.existedBefore)
        installOverwroteStart=($afterInstallStartA-eq'incoming-starter-v2')
        restoreStatusCompleted=([string]$restoreStartersA.status-eq'CentralStartersRestored')
        restoreBroughtBackOriginalStart=($afterRestoreStartA-eq'original-starter-v1')
        restoreRemovedNewlyCreatedStop=(-not $stopExistsAfterRestoreA)
    }
    if($checks.centralStartersRestore_MixedExistedAndNew.Values-contains$false){$fail.Add('centralStartersRestore_MixedExistedAndNew failed: '+($checks.centralStartersRestore_MixedExistedAndNew|ConvertTo-Json -Compress))}

    # === C. Knowledge Detach / Restore / Cleanup, mocked OpenWebUI API ======================
    # Local mock of the exact OpenWebUI endpoints Remove-/Restore-/Remove-...Collections.ps1
    # actually call, via a function-override of the unqualified Invoke-RestMethod each of those
    # scripts calls internally -- the same zero-dependency technique already used elsewhere in
    # this repository's own test suite (e.g. Test-KIStackComponentVersionRegistry.ps1's "gh"
    # fixture). Never a real network call.
    $global:__KIFinalizationMock=[ordered]@{
        models=[ordered]@{
            'ki-stack-allgemein'=[pscustomobject]@{id='ki-stack-allgemein';base_model_id='base-1';name='Allgemein';meta=[pscustomobject]@{knowledge=@([pscustomobject]@{id='coll-1'});toolIds=@('ki_stack_generate_image','ki_stack_generate_video')};params=[pscustomobject]@{};access_grants=@();is_active=$true}
            'ki-stack-it-technik'=[pscustomobject]@{id='ki-stack-it-technik';base_model_id='base-1';name='IT-Technik';meta=[pscustomobject]@{knowledge=@([pscustomobject]@{id='coll-1'});toolIds=@('ki_stack_generate_image','ki_stack_generate_video')};params=[pscustomobject]@{};access_grants=@();is_active=$true}
            'ki-stack-18bravo'=[pscustomobject]@{id='ki-stack-18bravo';base_model_id='base-1';name='18Bravo';meta=[pscustomobject]@{knowledge=@();toolIds=@('ki_stack_ballistics_calculator')};params=[pscustomobject]@{};access_grants=@();is_active=$true}
        }
        collections=@(
            [pscustomobject]@{id='coll-1';name='KI-Stack Controlled Knowledge';description=''}
            [pscustomobject]@{id='coll-unrelated';name='Some Other Knowledge';description='belongs to a different, unrelated project'}
        )
        files=[ordered]@{'coll-1'=@('file-1','file-2')}
        deletedCollections=[Collections.Generic.List[string]]::new()
        deletedFiles=[Collections.Generic.List[string]]::new()
        deleteEndpointHitDuringDetach=$false
        forceCollectionFailureId=$null
        forceFileFailureId=$null
        force404FileId=$null
    }
    function global:Invoke-RestMethod {
        param([string]$Uri,[string]$Method='GET',[hashtable]$Headers,[int]$TimeoutSec,[string]$ContentType,$Body)
        $state=$global:__KIFinalizationMock
        if($Uri -match '/api/v1/knowledge/\?' -or $Uri.EndsWith('/api/v1/knowledge/')){
            return @($state.collections|Where-Object{$state.deletedCollections-notcontains$_.id})
        }
        if($Uri -match '/api/v1/knowledge/([^/]+)/files$'){
            $collId=$Matches[1]
            $fileIds=@(if($state.files.Contains($collId)){$state.files[$collId]}else{@()})
            return @($fileIds|Where-Object{$state.deletedFiles-notcontains$_}|ForEach-Object{[pscustomobject]@{id=$_}})
        }
        if($Uri -match '/api/v1/knowledge/([^/]+)/delete$' -and $Method-eq'DELETE'){
            $collId=$Matches[1]
            if($collId-eq'coll-1'-or$collId-eq'coll-unrelated'){$state.deleteEndpointHitDuringDetach=$true}
            if($collId-eq$state.forceCollectionFailureId){throw "Simulated collection delete failure for $collId"}
            $state.deletedCollections.Add($collId)
            return [pscustomobject]@{success=$true}
        }
        if($Uri -match '/api/v1/models/model\?id=([^&]+)$'){
            $id=[Uri]::UnescapeDataString($Matches[1])
            return $state.models[$id]
        }
        if($Uri -match '/api/v1/models/model/update$' -and $Method-eq'POST'){
            $form=$Body|ConvertFrom-Json -Depth 50
            $state.models[[string]$form.id]=$form
            return [pscustomobject]@{success=$true}
        }
        if($Uri -match '/api/v1/files/([^/]+)$' -and $Method-eq'DELETE'){
            $fileId=$Matches[1]
            $state.deleteEndpointHitDuringDetach=$true
            if($fileId-eq$state.force404FileId){
                $ex=[Exception]::new('404 Not Found')
                $ex|Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{StatusCode=[pscustomobject]@{value__=404}}) -Force
                throw $ex
            }
            if($fileId-eq$state.forceFileFailureId){throw "Simulated file delete failure for $fileId"}
            $state.deletedFiles.Add($fileId)
            return [pscustomobject]@{success=$true}
        }
        throw "Kein Mock-Handler für Uri/Method: $Method $Uri"
    }

    $knowledgeBackupDir=Join-Path $fixtureRoot 'knowledge-backup'
    $fakeToken=Get-KISecureStringFixture 'fixture-token-not-a-real-secret'
    $detachResult=& (Join-Path $PackageRoot 'Operations/Remove-KIStackKnowledgeExperiment.ps1') -Endpoint 'http://mock.invalid' -ApiToken $fakeToken -BackupDirectory $knowledgeBackupDir
    $checks.knowledgeDetach_UnbindsWithoutDeleting=[ordered]@{
        statusIsDetached=([string]$detachResult.status-eq'Detached')
        neverCalledAnyDeleteEndpoint=(-not $global:__KIFinalizationMock.deleteEndpointHitDuringDetach)
        allProfilesReadbackEmpty=(@($detachResult.profiles|Where-Object{@($_.knowledge).Count-ne0}).Count-eq0)
        collectionsPendingCleanupOnlyMatchesKiStack=((@($detachResult.collectionsPendingCleanup|ForEach-Object id)-join',')-eq'coll-1')
        unrelatedCollectionNeverIncluded=(@($detachResult.collectionsPendingCleanup|Where-Object id -eq 'coll-unrelated').Count-eq0)
        backupFileWritten=(Test-Path -LiteralPath ([string]$detachResult.backupPath))
    }
    if($checks.knowledgeDetach_UnbindsWithoutDeleting.Values-contains$false){$fail.Add('knowledgeDetach_UnbindsWithoutDeleting failed: '+($checks.knowledgeDetach_UnbindsWithoutDeleting|ConvertTo-Json -Compress))}

    $restoreKnowledgeResult=& (Join-Path $PackageRoot 'Operations/Restore-KIStackKnowledgeExperiment.ps1') -Endpoint 'http://mock.invalid' -ApiToken $fakeToken -BackupPath ([string]$detachResult.backupPath)
    $allgemeinAfterRestore=$global:__KIFinalizationMock.models['ki-stack-allgemein']
    $checks.knowledgeRestore_BringsBackOriginalBinding=[ordered]@{
        statusIsRestored=([string]$restoreKnowledgeResult.status-eq'Restored')
        knowledgeBindingBackOnAllgemein=((@($allgemeinAfterRestore.meta.knowledge|ForEach-Object id)-join',')-eq'coll-1')
        neverCalledAnyDeleteEndpoint=(-not $global:__KIFinalizationMock.deleteEndpointHitDuringDetach)
    }
    if($checks.knowledgeRestore_BringsBackOriginalBinding.Values-contains$false){$fail.Add('knowledgeRestore_BringsBackOriginalBinding failed: '+($checks.knowledgeRestore_BringsBackOriginalBinding|ConvertTo-Json -Compress))}

    # Detach again (idempotent re-run against the now-restored state) to get a fresh, real
    # collectionsPendingCleanup list feeding the Cleanup scenarios below, with two collections
    # and a controlled per-item failure mix.
    $global:__KIFinalizationMock.files['coll-unrelated']=@('file-3')
    $global:__KIFinalizationMock.collections=@(
        [pscustomobject]@{id='coll-1';name='KI-Stack Controlled Knowledge';description=''}
        [pscustomobject]@{id='coll-fails';name='ki-stack second collection';description=''}
    )
    $global:__KIFinalizationMock.files=[ordered]@{'coll-1'=@('file-1','file-2');'coll-fails'=@('file-3')}
    $global:__KIFinalizationMock.deletedCollections.Clear();$global:__KIFinalizationMock.deletedFiles.Clear();$global:__KIFinalizationMock.deleteEndpointHitDuringDetach=$false
    $detachResult2=& (Join-Path $PackageRoot 'Operations/Remove-KIStackKnowledgeExperiment.ps1') -Endpoint 'http://mock.invalid' -ApiToken $fakeToken -BackupDirectory (Join-Path $fixtureRoot 'knowledge-backup-2')

    # Cleanup scenario 1: mixed real success/failure -- coll-1's file-2 returns 404 (treated as
    # already-gone/success), coll-fails' own delete AND its file-3 delete both fail for real.
    $global:__KIFinalizationMock.force404FileId='file-2'
    $global:__KIFinalizationMock.forceCollectionFailureId='coll-fails'
    $global:__KIFinalizationMock.forceFileFailureId='file-3'
    $cleanup1=& (Join-Path $PackageRoot 'Operations/Remove-KIStackKnowledgeExperimentCollections.ps1') -Endpoint 'http://mock.invalid' -ApiToken $fakeToken -Collections @($detachResult2.collectionsPendingCleanup)
    $checks.knowledgeCleanup_PartialFailureNeverThrows=[ordered]@{
        statusIsCompletedWithWarnings=([string]$cleanup1.status-eq'CompletedWithWarnings')
        collectionsRemovedIsOne=([int]$cleanup1.collectionsRemoved-eq1)
        filesRemovedCountsBothRealAnd404=([int]$cleanup1.filesRemoved-eq2)
        remainingCollectionsListsOnlyFailedOne=((@($cleanup1.remainingCollections|ForEach-Object id)-join',')-eq'coll-fails')
        failuresRecordedForCollectionAndFile=(@($cleanup1.failures|Where-Object{$_-match'coll-fails'}).Count-gt0-and@($cleanup1.failures|Where-Object{$_-match'file-3'}).Count-gt0)
    }
    if($checks.knowledgeCleanup_PartialFailureNeverThrows.Values-contains$false){$fail.Add('knowledgeCleanup_PartialFailureNeverThrows failed: '+($checks.knowledgeCleanup_PartialFailureNeverThrows|ConvertTo-Json -Compress))}

    # Cleanup scenario 2: nothing to clean.
    $cleanup2=& (Join-Path $PackageRoot 'Operations/Remove-KIStackKnowledgeExperimentCollections.ps1') -Endpoint 'http://mock.invalid' -ApiToken $fakeToken -Collections @()
    $checks.knowledgeCleanup_NothingToClean=[ordered]@{
        statusIsNothingToClean=([string]$cleanup2.status-eq'NothingToClean')
        zeroCounts=([int]$cleanup2.collectionsRemoved-eq0-and[int]$cleanup2.filesRemoved-eq0)
        noFailures=(@($cleanup2.failures).Count-eq0)
    }
    if($checks.knowledgeCleanup_NothingToClean.Values-contains$false){$fail.Add('knowledgeCleanup_NothingToClean failed: '+($checks.knowledgeCleanup_NothingToClean|ConvertTo-Json -Compress))}

    Remove-Item -Path Function:Invoke-RestMethod -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name __KIFinalizationMock -Scope Global -ErrorAction SilentlyContinue

    # === D. Generic reverse-order compensation-stack mechanism (isolated, no real installer) ==
    # Exercises the exact same shape used inside Invoke-KIStackCompleteInstaller's catch block
    # (list of {name;action}, iterated back-to-front, each isolated in its own try/catch, a
    # failed entry never blocking the remaining ones) without needing the full orchestrator.
    $order=[Collections.Generic.List[string]]::new()
    $compensations=[Collections.Generic.List[object]]::new()
    $compensations.Add([pscustomobject]@{name='Orchestrator';action={$order.Add('Orchestrator')}})
    $compensations.Add([pscustomobject]@{name='CentralStarters';action={$order.Add('CentralStarters')}})
    $compensations.Add([pscustomobject]@{name='Operations';action={$order.Add('Operations');throw 'simulated Operations restore failure'}})
    $compensations.Add([pscustomobject]@{name='KnowledgeDetach';action={$order.Add('KnowledgeDetach')}})
    $rollbackSteps=[Collections.Generic.List[object]]::new()
    for($i=$compensations.Count-1;$i-ge0;$i--){
        $entry=$compensations[$i]
        try{ $r=& $entry.action; $rollbackSteps.Add([ordered]@{name=$entry.name;status='Completed';result=$r}) }
        catch{ $rollbackSteps.Add([ordered]@{name=$entry.name;status='Failed';error=$_.Exception.Message}) }
    }
    $checks.compensationStack_ReverseOrderAndIsolation=[ordered]@{
        exactReverseOrder=(($order-join',')-eq'KnowledgeDetach,Operations,CentralStarters,Orchestrator')
        allFourAttemptedDespiteOneFailing=($rollbackSteps.Count-eq4)
        onlyOperationsFailed=((@($rollbackSteps|Where-Object status -eq 'Failed')|ForEach-Object name)-join',')-eq'Operations'
        remainingThreeCompleted=(@($rollbackSteps|Where-Object status -eq 'Completed').Count-eq3)
    }
    if($checks.compensationStack_ReverseOrderAndIsolation.Values-contains$false){$fail.Add('compensationStack_ReverseOrderAndIsolation failed: '+($checks.compensationStack_ReverseOrderAndIsolation|ConvertTo-Json -Compress))}

    # === E. Structural production-wiring checks against the real CompleteInstaller.psm1 =======
    $orchestratorSource=Get-Content -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Raw
    $requiredMarkers=@(
        'function Restore-KICompleteOrchestrator','function Restore-KICompleteCentralStarters',
        '$preCommitCompensations','$committed = $false','$committed = $true',
        "'DetachKnowledgeExperiment'","'CompletedWithWarnings'",
        'Operations/Restore-KIStackKnowledgeExperiment.ps1','Operations/Remove-KIStackKnowledgeExperimentCollections.ps1',
        'Operations/Restore-KIStackCodeInterpreter.ps1'
    )
    $missingMarkers=@($requiredMarkers|Where-Object{-not $orchestratorSource.Contains($_)})
    $checks.productionWiringMarkersPresent=[ordered]@{allPresent=($missingMarkers.Count-eq0);missing=$missingMarkers}
    if($checks.productionWiringMarkersPresent.Values-contains$false){$fail.Add('productionWiringMarkersPresent failed: missing '+($missingMarkers-join', '))}

    # Negative control: the OLD, narrow gating condition this P1 replaces must genuinely be gone
    # -- not just "a new marker was added alongside the old one".
    $forbiddenOldGate='$operationsStarted -and $finalizationPhase -eq ''InstallOperations'''
    $checks.negativeControl_OldNarrowGateRemoved=[ordered]@{
        oldGateAbsent=(-not $orchestratorSource.Contains($forbiddenOldGate))
        oldVariableAbsent=(-not ($orchestratorSource -match '\$operationsStarted\s*='))
    }
    if($checks.negativeControl_OldNarrowGateRemoved.Values-contains$false){$fail.Add('negativeControl_OldNarrowGateRemoved failed: the old narrow InstallOperations-only gate (or its $operationsStarted flag) is still present')}

    # === F. components.json persistence fix -- real end-to-end run of the actual
    # Invoke-KIStackCompleteInstaller, not a piece in isolation. A zero-component package
    # (Contracts/COMPONENTS.json with an empty components array) reaches the real transactional
    # finalization path (Orchestrator/CentralStarters/Operations/Knowledge-Detach/CodeInterpreter/
    # WriteFinalState/Cleanup) with no real per-component payload needed at all -- the smallest
    # package shape that genuinely exercises this exact commit/cleanup sequence. Runs each
    # scenario in an isolated child pwsh.exe process (never the real target), with a local mock
    # of the OpenWebUI endpoints Detach/SetCodeInterpreter/Cleanup actually call, defined inside
    # the child script itself (function-override technique, same as Section C above).
    function New-KIFinalizationE2EPackageRoot {
        param([Parameter(Mandatory)][string]$PackageStageRoot)
        New-Item -ItemType Directory -Path $PackageStageRoot,(Join-Path $PackageStageRoot 'Payload') -Force|Out-Null
        Set-Content -LiteralPath (Join-Path $PackageStageRoot 'MANIFEST.json') -Value '{"schemaVersion":"1.0"}' -Encoding UTF8

        # Administrator-gate bypass on a COPY of the real CompleteInstaller.psm1 (never the real
        # file) -- same technique already used by Test-KIStackComfyUIOverlayProtection.ps1 /
        # Test-KIStackReplayComponent.ps1 / Test-KIStackOpenWebUIVisualPackCutover.ps1.
        $source=Get-Content -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Raw
        $needle='if(-not$ReadOnly-and-not(Test-KICompleteAdministrator)){$issues+=''Administratorrechte erforderlich.''}'
        if($source-notmatch [regex]::Escape($needle)){throw 'Administrator-Gate-Textmuster nicht gefunden -- Patch nicht anwendbar.'}
        Set-Content -LiteralPath (Join-Path $PackageStageRoot 'CompleteInstaller.psm1') -Value $source.Replace($needle,'if($false){$issues+=''Administratorrechte erforderlich.''}') -Encoding UTF8

        # Real Runtime/KIStackPathContext.psm1, copied unmodified -- CompleteInstaller.psm1
        # imports this by relative path from its own $PSScriptRoot, so the fixture must carry a
        # real copy (this is exactly the dependency Test-KIStackComfyUIOverlayProtection.ps1's own
        # fixture is currently missing -- see the separately-flagged, unrelated background task;
        # this fixture includes it correctly from the start).
        New-Item -ItemType Directory -Path (Join-Path $PackageStageRoot 'Runtime') -Force|Out-Null
        Copy-Item -LiteralPath (Join-Path $PackageRoot 'Runtime/KIStackPathContext.psm1') -Destination (Join-Path $PackageStageRoot 'Runtime/KIStackPathContext.psm1') -Force

        # Real Operations/*.ps1 scripts, copied unmodified -- Invoke-KIStackCompleteInstaller
        # invokes these by relative path from $PackageRoot at runtime (Detach/Restore/Cleanup and
        # SetCodeInterpreter/its own Restore), so this is the exact production code under test,
        # not a re-implementation of it.
        Copy-Item -LiteralPath (Join-Path $PackageRoot 'Operations') -Destination (Join-Path $PackageStageRoot 'Operations') -Recurse -Force

        New-Item -ItemType Directory -Path (Join-Path $PackageStageRoot 'Contracts') -Force|Out-Null
        Set-Content -LiteralPath (Join-Path $PackageStageRoot 'Contracts/COMPONENTS.json') -Value '{"schemaVersion":"1.0","components":[]}' -Encoding UTF8

        New-Item -ItemType Directory -Path (Join-Path $PackageStageRoot 'Config') -Force|Out-Null
        $config=[ordered]@{schemaVersion='1.0';version='2.13.0';targetRoot='';stateDirectory='';backupDirectory='';logDirectory='';openWebUIEndpoint='http://mock.invalid';timeouts=[ordered]@{processSeconds=60;healthSeconds=5};optionalComponents=[ordered]@{openWebUIBallistics=$false};healthEndpoints=@()}
        Set-Content -LiteralPath (Join-Path $PackageStageRoot 'Config/complete-installer.config.json') -Value ($config|ConvertTo-Json -Depth 10) -Encoding UTF8

        New-Item -ItemType Directory -Path (Join-Path $PackageStageRoot 'Lifecycle') -Force|Out-Null
        foreach($name in @('Start-KIStack.cmd','Stop-KIStack.cmd','Stop-KIStack-Managed.ps1','Validate-KIStack.cmd','Get-KIStackStatus.ps1','Show-KIStackStatus.ps1','Status-KIStack-Interactive.cmd','Repair-KIStack.cmd','Update-KIStack-OpenWebUI.cmd','Update-KIStack-OpenWebUI.ps1','Update-KIStack-All.cmd','Update-KIStack-All.ps1')){
            Set-Content -LiteralPath (Join-Path $PackageStageRoot "Lifecycle/$name") -Value "rem fixture placeholder: $name" -Encoding UTF8
        }

        $absRoot=(Resolve-Path $PackageStageRoot).Path
        $lines=Get-ChildItem $absRoot -Recurse -File|Sort-Object{[IO.Path]::GetRelativePath($absRoot,$_.FullName).Replace('\','/')}|ForEach-Object{
            $relative=[IO.Path]::GetRelativePath($absRoot,$_.FullName).Replace('\','/')
            "$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) $relative"
        }
        [IO.File]::WriteAllLines((Join-Path $absRoot 'SHA256SUMS.txt'),$lines,[Text.ASCIIEncoding]::new())
        $PackageStageRoot
    }

    function Invoke-KIFinalizationE2EScenario {
        param([Parameter(Mandatory)][string]$PackageStageRoot,[Parameter(Mandatory)][string]$TargetRoot,[Parameter(Mandatory)][string]$RunnerScriptPath,[bool]$SimulateCleanupFailure)
        $fixtureDesktopPath=Join-Path $TargetRoot '__fixture-desktop'
        $mockDefinition=@'
$global:__KIFinalizationE2EMock=[ordered]@{
    models=[ordered]@{
        'ki-stack-allgemein'=[pscustomobject]@{id='ki-stack-allgemein';base_model_id='base-1';name='Allgemein';meta=[pscustomobject]@{knowledge=@([pscustomobject]@{id='coll-1'});toolIds=@('ki_stack_generate_image','ki_stack_generate_video');capabilities=[pscustomobject]@{}};params=[pscustomobject]@{};access_grants=@();is_active=$true}
        'ki-stack-it-technik'=[pscustomobject]@{id='ki-stack-it-technik';base_model_id='base-1';name='IT-Technik';meta=[pscustomobject]@{knowledge=@([pscustomobject]@{id='coll-1'});toolIds=@('ki_stack_generate_image','ki_stack_generate_video');capabilities=[pscustomobject]@{}};params=[pscustomobject]@{};access_grants=@();is_active=$true}
        'ki-stack-18bravo'=[pscustomobject]@{id='ki-stack-18bravo';base_model_id='base-1';name='18Bravo';meta=[pscustomobject]@{knowledge=@();toolIds=@('ki_stack_ballistics_calculator');capabilities=[pscustomobject]@{}};params=[pscustomobject]@{};access_grants=@();is_active=$true}
    }
    collections=@([pscustomobject]@{id='coll-1';name='KI-Stack Controlled Knowledge';description=''})
    files=[ordered]@{'coll-1'=@('file-1')}
    deletedCollections=[Collections.Generic.List[string]]::new()
    deletedFiles=[Collections.Generic.List[string]]::new()
    config=[pscustomobject]@{ENABLE_CODE_EXECUTION=$false;CODE_EXECUTION_ENGINE='jupyter';CODE_EXECUTION_JUPYTER_URL=$null;CODE_EXECUTION_JUPYTER_AUTH=$null;CODE_EXECUTION_JUPYTER_AUTH_TOKEN=$null;CODE_EXECUTION_JUPYTER_AUTH_PASSWORD=$null;CODE_EXECUTION_JUPYTER_TIMEOUT=60;ENABLE_CODE_INTERPRETER=$false;CODE_INTERPRETER_ENGINE=$null;CODE_INTERPRETER_PROMPT_TEMPLATE=$null;CODE_INTERPRETER_JUPYTER_URL=$null;CODE_INTERPRETER_JUPYTER_AUTH=$null;CODE_INTERPRETER_JUPYTER_AUTH_TOKEN=$null;CODE_INTERPRETER_JUPYTER_AUTH_PASSWORD=$null}
}
function global:Invoke-RestMethod {
    param([string]$Uri,[string]$Method='GET',[hashtable]$Headers,[int]$TimeoutSec,[string]$ContentType,$Body)
    $s=$global:__KIFinalizationE2EMock
    if($Uri -match '/api/v1/configs/code_execution$'){
        if($Method-eq'POST'){$s.config=$Body|ConvertFrom-Json -Depth 50;return [pscustomobject]@{success=$true}}
        return $s.config
    }
    if($Uri -match '/api/v1/knowledge/\?' -or $Uri.EndsWith('/api/v1/knowledge/')){
        return @($s.collections|Where-Object{$s.deletedCollections-notcontains$_.id})
    }
    if($Uri -match '/api/v1/knowledge/([^/]+)/files$'){
        $c=$Matches[1];$ids=@(if($s.files.Contains($c)){$s.files[$c]}else{@()})
        return @($ids|Where-Object{$s.deletedFiles-notcontains$_}|ForEach-Object{[pscustomobject]@{id=$_}})
    }
    if($Uri -match '/api/v1/knowledge/([^/]+)/delete$' -and $Method-eq'DELETE'){
        $c=$Matches[1]
        if($env:KI_FIXTURE_SIMULATE_FAILURE -eq '1'){throw "Simulated collection delete failure for $c"}
        $s.deletedCollections.Add($c);return [pscustomobject]@{success=$true}
    }
    if($Uri -match '/api/v1/models/model\?id=([^&]+)$'){
        $id=[Uri]::UnescapeDataString($Matches[1]);return $s.models[$id]
    }
    if($Uri -match '/api/v1/models/model/update$' -and $Method-eq'POST'){
        $form=$Body|ConvertFrom-Json -Depth 50;$s.models[[string]$form.id]=$form;return [pscustomobject]@{success=$true}
    }
    if($Uri -match '/api/v1/files/([^/]+)$' -and $Method-eq'DELETE'){
        $s.deletedFiles.Add($Matches[1]);return [pscustomobject]@{success=$true}
    }
    throw "Kein Mock-Handler für Uri/Method: $Method $Uri"
}
'@
        Set-Content -LiteralPath $RunnerScriptPath -Encoding UTF8 -Value @"
Set-StrictMode -Version Latest
`$ErrorActionPreference='Stop'
`$env:KI_FIXTURE_SIMULATE_FAILURE='$(if($SimulateCleanupFailure){'1'}else{'0'})'
$mockDefinition
Import-Module '$($PackageStageRoot.Replace("'","''"))/CompleteInstaller.psm1' -Force
`$fakeToken=ConvertTo-SecureString -String 'fixture-token-not-a-real-secret' -AsPlainText -Force
try {
    `$result=Invoke-KIStackCompleteInstaller -Mode Install -PackageRoot '$($PackageStageRoot.Replace("'","''"))' -TargetRoot '$($TargetRoot.Replace("'","''"))' -DesktopPath '$($fixtureDesktopPath.Replace("'","''"))' -OpenWebUIApiToken `$fakeToken
    [pscustomobject]@{threw=`$false;result=`$result}|ConvertTo-Json -Depth 20 -Compress
} catch {
    [pscustomobject]@{threw=`$true;message=`$_.Exception.Message}|ConvertTo-Json -Depth 10 -Compress
}
"@
        $raw=& pwsh.exe -NoLogo -NoProfile -File $RunnerScriptPath 2>&1
        $lastLine=$raw|Select-Object -Last 1
        try{ [pscustomobject]@{parsed=($lastLine|ConvertFrom-Json -Depth 20);raw=$raw} }
        catch{ [pscustomobject]@{parsed=$null;raw=$raw} }
    }

    $e2eFixtureRoot=Join-Path $fixtureRoot 'e2e'
    $e2ePackageRoot=New-KIFinalizationE2EPackageRoot -PackageStageRoot (Join-Path $e2eFixtureRoot 'package')

    # F1. Green Path: transaction.json = Completed, components.json = the existing success status
    # ("ValidatedExistingInstallation"), both agree, and no rollback of any kind was ever recorded.
    $greenTargetRoot=Join-Path $e2eFixtureRoot 'green-target';New-Item -ItemType Directory -Path $greenTargetRoot -Force|Out-Null
    $greenScenario=Invoke-KIFinalizationE2EScenario -PackageStageRoot $e2ePackageRoot -TargetRoot $greenTargetRoot -RunnerScriptPath (Join-Path $e2eFixtureRoot 'runner-green.ps1') -SimulateCleanupFailure:$false
    if($null-eq$greenScenario.parsed -or [bool]$greenScenario.parsed.threw){$fail.Add('e2e_GreenPath: runner threw or produced no parseable result: '+(($greenScenario.raw)-join' | '))}
    else {
        $greenTx=$greenScenario.parsed.result
        $greenTxOnDisk=Get-Content -LiteralPath (Join-Path ([string]$greenTx.transactionRoot) 'transaction.json') -Raw|ConvertFrom-Json -Depth 30
        $greenComponentsOnDisk=Get-Content -LiteralPath (Join-Path ([string]$greenTx.stateRoot) 'components.json') -Raw|ConvertFrom-Json -Depth 30
        $checks.e2e_GreenPath=[ordered]@{
            transactionStatusCompleted=([string]$greenTxOnDisk.status-eq'Completed')
            componentsStatusIsExistingSuccessValue=([string]$greenComponentsOnDisk.status-eq'ValidatedExistingInstallation')
            knowledgeCleanupPersistedAsCompleted=([string]$greenTxOnDisk.knowledgeCleanup.status-eq'Completed')
            noFinalizationRollbackRecorded=(-not ($greenTxOnDisk.PSObject.Properties.Name-contains'finalizationRollback'))
            noErrorRecorded=(-not ($greenTxOnDisk.PSObject.Properties.Name-contains'error'))
        }
        if($checks.e2e_GreenPath.Values-contains$false){$fail.Add('e2e_GreenPath failed: '+($checks.e2e_GreenPath|ConvertTo-Json -Compress))}
    }

    # F2. Warning Path: Cleanup genuinely fails for the one real collection -- transaction.json AND
    # components.json must both agree on CompletedWithWarnings (the fixed persistence gap), the
    # cleanup failure must be visible in the persisted transaction.json, and none of this may have
    # triggered any pre-commit rollback (the installation stays committed).
    $warnTargetRoot=Join-Path $e2eFixtureRoot 'warn-target';New-Item -ItemType Directory -Path $warnTargetRoot -Force|Out-Null
    $warnScenario=Invoke-KIFinalizationE2EScenario -PackageStageRoot $e2ePackageRoot -TargetRoot $warnTargetRoot -RunnerScriptPath (Join-Path $e2eFixtureRoot 'runner-warn.ps1') -SimulateCleanupFailure:$true
    if($null-eq$warnScenario.parsed -or [bool]$warnScenario.parsed.threw){$fail.Add('e2e_WarningPath: runner threw or produced no parseable result: '+(($warnScenario.raw)-join' | '))}
    else {
        $warnTx=$warnScenario.parsed.result
        $warnTxOnDisk=Get-Content -LiteralPath (Join-Path ([string]$warnTx.transactionRoot) 'transaction.json') -Raw|ConvertFrom-Json -Depth 30
        $warnComponentsOnDisk=Get-Content -LiteralPath (Join-Path ([string]$warnTx.stateRoot) 'components.json') -Raw|ConvertFrom-Json -Depth 30
        $checks.e2e_WarningPath=[ordered]@{
            transactionStatusCompletedWithWarnings=([string]$warnTxOnDisk.status-eq'CompletedWithWarnings')
            componentsStatusMatchesCompletedWithWarnings=([string]$warnComponentsOnDisk.status-eq'CompletedWithWarnings')
            cleanupFailuresPersisted=(@($warnTxOnDisk.knowledgeCleanup.failures).Count-gt0)
            cleanupStatusIsCompletedWithWarnings=([string]$warnTxOnDisk.knowledgeCleanup.status-eq'CompletedWithWarnings')
            noFinalizationRollbackRecorded=(-not ($warnTxOnDisk.PSObject.Properties.Name-contains'finalizationRollback'))
            noErrorRecorded=(-not ($warnTxOnDisk.PSObject.Properties.Name-contains'error'))
        }
        if($checks.e2e_WarningPath.Values-contains$false){$fail.Add('e2e_WarningPath failed: '+($checks.e2e_WarningPath|ConvertTo-Json -Compress))}
    }
}
finally {
    Remove-Item -Path Function:Invoke-RestMethod -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name __KIFinalizationMock -Scope Global -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $fixtureRoot){Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue}
}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 15
if(-not$passed){throw 'Finalization-Rollback-P1-Regression fehlgeschlagen.'}

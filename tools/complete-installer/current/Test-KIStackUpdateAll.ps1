[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$updateAllScript=Join-Path $PackageRoot 'Lifecycle/Update-KIStack-All.ps1'
$contract=Get-Content -LiteralPath (Join-Path $PackageRoot 'Contracts/COMPONENTS.json') -Raw|ConvertFrom-Json -Depth 30
$allCompliantFixture=@{}
foreach($c in $contract.components){$allCompliantFixture[[string]$c.id]=[string]$c.version}
$owuiCompliantFixture=@{installedVersion='0.11.0';targetVersion='0.11.0'}
# Default upstream stub used by every scenario that isn't specifically exercising upstream
# reporting -- keeps the whole suite hermetic (no real PyPI/GitHub calls, no dependency on live,
# drifting upstream content) without having to repeat this on every single call.
$defaultUpstreamFixture=@{
    openwebui=@{availableVersion='Unknown';upstreamStatus='Unknown';upstreamSource='test-stub'}
    comfyui=@{availableVersion='Unknown';upstreamStatus='Unknown';upstreamSource='test-stub'}
    integration=@{availableVersion='Unknown';upstreamStatus='Unknown';upstreamSource='test-stub'}
}

function New-KIUpdateAllTargetFixture {
    param([Parameter(Mandatory)][string]$FixtureRoot)
    $installerRoot=Join-Path $FixtureRoot 'installer/complete'
    New-Item -ItemType Directory -Path (Join-Path $installerRoot 'Contracts') -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Destination $installerRoot -Force
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'Contracts/COMPONENTS.json') -Destination (Join-Path $installerRoot 'Contracts') -Force
    $FixtureRoot
}

function Get-KIJsonFromMixedOutput {
    param([string[]]$Output)
    $text=($Output-join "`n")
    $match=[regex]::Match($text,'(?s)\{.*\}')
    if(-not$match.Success){return $null}
    try{$match.Value|ConvertFrom-Json -Depth 20}catch{$null}
}

# Update-KIStack-All.ps1's -FixtureState/-OpenWebUIFixture parameters are [hashtable] -- the
# established New-KICompletePlan -FixtureState contract -- meant for in-process PowerShell calls.
# For out-of-process pwsh.exe invocation (needed to exercise the script's own parameter binding,
# Write-Host banners and real exit codes), this generic wrapper takes the same values as JSON
# strings on the command line and converts them back to hashtables in-process before calling the
# real (or fixture-substituted-copy of the real) script. No install/upgrade/rollback logic is
# reimplemented here -- only JSON<->hashtable plumbing for the test harness.
$wrapperSource=@'
[CmdletBinding()]
param([string]$TargetScript,[string]$TargetRoot,[switch]$CheckOnly,[string]$ComponentJson,[switch]$NonInteractive,[string]$FixtureState,[string]$OpenWebUIFixture,[string]$UpstreamFixture)
$fs=$null;if($FixtureState){$obj=$FixtureState|ConvertFrom-Json;$fs=@{};$obj.PSObject.Properties|ForEach-Object{$fs[$_.Name]=$_.Value}}
$owf=$null;if($OpenWebUIFixture){$obj2=$OpenWebUIFixture|ConvertFrom-Json;$owf=@{};$obj2.PSObject.Properties|ForEach-Object{$owf[$_.Name]=$_.Value}}
$uf=$null;if($UpstreamFixture){$obj3=$UpstreamFixture|ConvertFrom-Json;$uf=@{};$obj3.PSObject.Properties|ForEach-Object{$uf[$_.Name]=$_.Value}}
$componentArray=@();if($ComponentJson){$componentArray=@($ComponentJson|ConvertFrom-Json)}
$scriptArgs=@{TargetRoot=$TargetRoot;CheckOnly=$CheckOnly;Component=$componentArray;NonInteractive=$NonInteractive}
if($fs){$scriptArgs.FixtureState=$fs}
if($owf){$scriptArgs.OpenWebUIFixture=$owf}
if($uf){$scriptArgs.UpstreamFixture=$uf}
& $TargetScript @scriptArgs
exit $LASTEXITCODE
'@

function Invoke-KIUpdateAll {
    param(
        [Parameter(Mandatory)][string]$WrapperPath,
        [Parameter(Mandatory)][string]$TargetScript,
        [Parameter(Mandatory)][string]$TargetRoot,
        [switch]$CheckOnly,
        [switch]$NonInteractive,
        [string[]]$Component=@(),
        [hashtable]$FixtureState,
        [hashtable]$OpenWebUIFixture,
        [hashtable]$UpstreamFixture,
        [string]$StdIn
    )
    $fixtureStateJson=($FixtureState|ConvertTo-Json -Compress)
    $owuiFixtureJson=($OpenWebUIFixture|ConvertTo-Json -Compress)
    $scriptArgs=@('-NoLogo','-NoProfile','-File',$WrapperPath,'-TargetScript',$TargetScript,'-TargetRoot',$TargetRoot,'-FixtureState',$fixtureStateJson,'-OpenWebUIFixture',$owuiFixtureJson)
    # Always supply an UpstreamFixture (defaulting to the shared Unknown-for-everything stub when
    # the caller doesn't care) so the test suite never makes a real PyPI/GitHub network call and
    # never depends on live, drifting upstream content.
    $upstreamFixtureToUse=if($UpstreamFixture){$UpstreamFixture}else{$defaultUpstreamFixture}
    $scriptArgs+=@('-UpstreamFixture',($upstreamFixtureToUse|ConvertTo-Json -Compress))
    if($CheckOnly){$scriptArgs+='-CheckOnly'}
    if($NonInteractive){$scriptArgs+='-NonInteractive'}
    # pwsh -File does not run its trailing arguments through the PowerShell parser, so a bare
    # comma or repeated tokens never bind as multiple [string[]] elements -- pass as a JSON array
    # string instead and let the wrapper convert it back to a real array in-process.
    if($Component.Count-gt0){$scriptArgs+=@('-ComponentJson',(@($Component)|ConvertTo-Json -Compress))}
    if($null-ne$StdIn){$out=$StdIn|& pwsh.exe @scriptArgs 2>&1}else{$out=& pwsh.exe @scriptArgs 2>&1}
    [pscustomobject]@{exit=$LASTEXITCODE;json=(Get-KIJsonFromMixedOutput $out);raw=$out}
}

$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}
$fixtureRootBase=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-UpdateAll-'+[guid]::NewGuid().ToString('N'))

try{
    New-Item -ItemType Directory -Path $fixtureRootBase -Force|Out-Null
    $wrapperPath=Join-Path $fixtureRootBase 'wrapper.ps1'
    [IO.File]::WriteAllText($wrapperPath,$wrapperSource,[Text.UTF8Encoding]::new($false))

    # 1. All components (COMPONENTS.json + openwebui) already at target -> only UpToDate.
    $allUpToDateRoot=New-KIUpdateAllTargetFixture -FixtureRoot (Join-Path $fixtureRootBase 'alluptodate')
    $r1=Invoke-KIUpdateAll -WrapperPath $wrapperPath -TargetScript $updateAllScript -TargetRoot $allUpToDateRoot -CheckOnly -FixtureState $allCompliantFixture -OpenWebUIFixture $owuiCompliantFixture
    $checks.allUpToDate=[ordered]@{
        exitZero=$r1.exit-eq0
        allClassifiedUpToDate=($null-ne$r1.json)-and(@($r1.json.plan|Where-Object{$_.classification-ne'UpToDate'}).Count-eq0)
        hasOpenWebUIRow=($null-ne$r1.json)-and(@($r1.json.plan|Where-Object id -eq 'openwebui').Count-eq1)
    }
    if($checks.allUpToDate.Values-contains$false){$fail.Add('Scenario AllUpToDate failed: '+($r1.raw-join ' | '))}

    # 1b. Upstream has something newer than the pin, but installed already matches the pin ->
    #     reported as UpdateAvailableUpstream on the plan row, classification stays UpToDate (the
    #     pin/installed comparison never looks at upstream), and it does not get auto-executed --
    #     "Automatisch ausführbar bleibt ausschließlich: InstalledVersion != PinnedVersion".
    $upstreamRoot=New-KIUpdateAllTargetFixture -FixtureRoot (Join-Path $fixtureRootBase 'upstreamavailable')
    $upstreamNewerFixture=@{openwebui=@{availableVersion='0.99.0';upstreamStatus='UpdateAvailableUpstream';upstreamSource='test-stub-newer'}}
    $r1b=Invoke-KIUpdateAll -WrapperPath $wrapperPath -TargetScript $updateAllScript -TargetRoot $upstreamRoot -CheckOnly -FixtureState $allCompliantFixture -OpenWebUIFixture $owuiCompliantFixture -UpstreamFixture $upstreamNewerFixture
    $owuiRow1b=$r1b.json.plan|Where-Object id -eq 'openwebui'|Select-Object -First 1
    $checks.upstreamAvailableReportedNotExecuted=[ordered]@{
        exitZero=$r1b.exit-eq0
        upstreamStatusReported=$null-ne$owuiRow1b-and$owuiRow1b.upstreamStatus-eq'UpdateAvailableUpstream'
        availableVersionReported=$null-ne$owuiRow1b-and$owuiRow1b.availableVersion-eq'0.99.0'
        classificationStillUpToDate=$null-ne$owuiRow1b-and$owuiRow1b.classification-eq'UpToDate'
    }
    if($checks.upstreamAvailableReportedNotExecuted.Values-contains$false){$fail.Add('Scenario UpstreamAvailableReportedNotExecuted failed: '+($r1b.raw-join ' | '))}
    # Same fixture, full (non-CheckOnly) run with -NonInteractive: upstream availability alone
    # must never trigger execution -- only a genuine pin/installed mismatch may.
    $r1c=Invoke-KIUpdateAll -WrapperPath $wrapperPath -TargetScript $updateAllScript -TargetRoot $upstreamRoot -NonInteractive -FixtureState $allCompliantFixture -OpenWebUIFixture $owuiCompliantFixture -UpstreamFixture $upstreamNewerFixture
    $checks.upstreamAvailableNeverAutoExecuted=[ordered]@{
        exitZero=$r1c.exit-eq0
        noActionNeeded=$null-ne$r1c.json-and$r1c.json.mode-eq'NoActionNeeded'
    }
    if($checks.upstreamAvailableNeverAutoExecuted.Values-contains$false){$fail.Add('Scenario UpstreamAvailableNeverAutoExecuted failed: '+($r1c.raw-join ' | '))}

    # 2. Exactly one COMPONENTS.json component behind -> UpdateAvailable, everything else unaffected.
    $oneBehindRoot=New-KIUpdateAllTargetFixture -FixtureRoot (Join-Path $fixtureRootBase 'onebehind')
    $oneBehindFixture=$allCompliantFixture.Clone();$oneBehindFixture['comfyui']='0.0.1'
    $r2=Invoke-KIUpdateAll -WrapperPath $wrapperPath -TargetScript $updateAllScript -TargetRoot $oneBehindRoot -CheckOnly -FixtureState $oneBehindFixture -OpenWebUIFixture $owuiCompliantFixture
    $comfyRow2=$r2.json.plan|Where-Object id -eq 'comfyui'|Select-Object -First 1
    $othersStillUpToDate2=@($r2.json.plan|Where-Object{$_.id-ne'comfyui'-and$_.classification-ne'UpToDate'}).Count-eq0
    $checks.oneUpdateAvailable=[ordered]@{
        exitZero=$r2.exit-eq0
        comfyClassifiedUpdateAvailable=$null-ne$comfyRow2-and$comfyRow2.classification-eq'PinnedUpdatePending'
        othersUnaffected=$othersStillUpToDate2
    }
    if($checks.oneUpdateAvailable.Values-contains$false){$fail.Add('Scenario OneUpdateAvailable failed: '+($r2.raw-join ' | '))}

    # 3. Installed version numerically higher than the pinned target -> DowngradeRequired.
    $downgradeRoot=New-KIUpdateAllTargetFixture -FixtureRoot (Join-Path $fixtureRootBase 'downgrade')
    $downgradeFixture=$allCompliantFixture.Clone();$downgradeFixture['comfyui']='99.0.0'
    $r3=Invoke-KIUpdateAll -WrapperPath $wrapperPath -TargetScript $updateAllScript -TargetRoot $downgradeRoot -CheckOnly -FixtureState $downgradeFixture -OpenWebUIFixture $owuiCompliantFixture
    $comfyRow3=$r3.json.plan|Where-Object id -eq 'comfyui'|Select-Object -First 1
    $checks.downgradeRequired=[ordered]@{
        exitZero=$r3.exit-eq0
        comfyClassifiedDowngradeRequired=$null-ne$comfyRow3-and$comfyRow3.classification-eq'DowngradeRequired'
    }
    if($checks.downgradeRequired.Values-contains$false){$fail.Add('Scenario DowngradeRequired failed: '+($r3.raw-join ' | '))}

    # 4. Explicitly requested -Component id unknown to both Contracts/COMPONENTS.json and the
    #    dedicated openwebui adapter -> NotManaged, not silently dropped.
    $notManagedRoot=New-KIUpdateAllTargetFixture -FixtureRoot (Join-Path $fixtureRootBase 'notmanaged')
    $r4=Invoke-KIUpdateAll -WrapperPath $wrapperPath -TargetScript $updateAllScript -TargetRoot $notManagedRoot -CheckOnly -FixtureState $allCompliantFixture -OpenWebUIFixture $owuiCompliantFixture -Component @('comfyui','totally-unmanaged-thing')
    $unmanagedRow4=$r4.json.plan|Where-Object id -eq 'totally-unmanaged-thing'|Select-Object -First 1
    $checks.notManaged=[ordered]@{
        exitZero=$r4.exit-eq0
        reportedNotManaged=$null-ne$unmanagedRow4-and$unmanagedRow4.classification-eq'NotManaged'
    }
    if($checks.notManaged.Values-contains$false){$fail.Add('Scenario NotManaged failed: '+($r4.raw-join ' | '))}

    # 5+6+7. Execution: OpenWebUI adapter runs first, a real batch call covers remaining components,
    #        sequential per-component results are reported in order; a failing OpenWebUI adapter stops
    #        before the batch call ever runs (no cascading execution) and its rollback detail is
    #        surfaced; without -NonInteractive, a non-'EXECUTE' confirmation cancels before anything runs.
    function New-KIUpdateAllExecFixture {
        param([Parameter(Mandatory)][string]$FixtureRoot,[Parameter(Mandatory)][string]$OwuiStatus,[int]$OwuiExitCode,[string]$UpgradeResultJson)
        New-KIUpdateAllTargetFixture -FixtureRoot $FixtureRoot|Out-Null
        $orderLog=Join-Path $FixtureRoot 'order.log'
        $rollbackDetail=if($OwuiStatus-ne'Completed'){[ordered]@{attempted=$true;success=$true;restoredVersion='0.10.2';versionRestored=$true;healthcheckPassed=$true}}else{$null}
        $owuiJsonObj=[ordered]@{status=$OwuiStatus;transactionId='T';targetVersion='0.11.0';previousVersion='0.10.2';installedVersion=$(if($OwuiStatus-eq'Completed'){'0.11.0'}else{'0.10.2'});healthcheckPassed=($OwuiStatus-eq'Completed');rollback=$rollbackDetail}
        # cmd.exe's `echo` prints the rest of the line verbatim (it does not strip or interpret
        # quote characters the way argument parsing does), so the JSON needs no quote-escaping here.
        $owuiJsonText=($owuiJsonObj|ConvertTo-Json -Depth 10 -Compress)
        $cmdContent="@echo off`r`necho openwebui>>`"$orderLog`"`r`necho $owuiJsonText`r`nexit /b $OwuiExitCode`r`n"
        [IO.File]::WriteAllText((Join-Path $FixtureRoot 'Update-KIStack-OpenWebUI.cmd'),$cmdContent,[Text.Encoding]::ASCII)
        if($UpgradeResultJson){Set-Content -LiteralPath (Join-Path $FixtureRoot 'fixture-upgrade-result.json') -Value $UpgradeResultJson -Encoding UTF8}
        $orderLog
    }

    # Copy of Update-KIStack-All.ps1 with only the real Invoke-KIStackCompleteInstaller batch call
    # replaced by a fixture read-back + order-log append; the openwebui adapter dispatch (the code
    # actually under test for sequencing/failure-stop) is left completely unmodified.
    $execSource=Get-Content -LiteralPath (Join-Path $PackageRoot 'Lifecycle/Update-KIStack-All.ps1') -Raw
    $originalBatchLine='$upgradeResult=Invoke-KIStackCompleteInstaller -Mode Upgrade -PackageRoot $installerRoot -TargetRoot $TargetRoot'
    if(-not$execSource.Contains($originalBatchLine)){throw 'Fixture-Ersetzung fehlgeschlagen: erwartete Zeile für den Complete-Installer-Upgrade-Batch-Aufruf nicht gefunden.'}
    $fixtureBatchLine='Add-Content -LiteralPath (Join-Path $TargetRoot ''order.log'') -Value ''batch'';$upgradeResult=Get-Content -LiteralPath (Join-Path $TargetRoot ''fixture-upgrade-result.json'') -Raw|ConvertFrom-Json -Depth 20'
    $execSource=$execSource.Replace($originalBatchLine,$fixtureBatchLine)
    $execScriptPath=Join-Path $fixtureRootBase 'Update-KIStack-All.exec.ps1'
    [IO.File]::WriteAllText($execScriptPath,$execSource,[Text.UTF8Encoding]::new($false))

    # 5. Successful sequential execution: openwebui first, then the batch for the remaining component.
    $seqRoot=Join-Path $fixtureRootBase 'sequential'
    $seqOrderLog=New-KIUpdateAllExecFixture -FixtureRoot $seqRoot -OwuiStatus 'Completed' -OwuiExitCode 0 -UpgradeResultJson '{"status":"Completed","steps":[{"id":"comfyui","status":"Completed"}]}'
    $seqFixture=$allCompliantFixture.Clone();$seqFixture['comfyui']='0.0.1'
    $seqOwuiFixture=@{installedVersion='0.10.2';targetVersion='0.11.0'}
    $r5=Invoke-KIUpdateAll -WrapperPath $wrapperPath -TargetScript $execScriptPath -TargetRoot $seqRoot -NonInteractive -FixtureState $seqFixture -OpenWebUIFixture $seqOwuiFixture
    $seqOrder=if(Test-Path $seqOrderLog){(Get-Content -LiteralPath $seqOrderLog)-join ','}else{$null}
    $comfyExec=$r5.json.executed|Where-Object id -eq 'comfyui'|Select-Object -First 1
    $checks.sequentialExecution=[ordered]@{
        exitZero=$r5.exit-eq0
        modeExecuted=$null-ne$r5.json-and$r5.json.mode-eq'Executed'
        openWebUIRanFirst=$seqOrder-eq'openwebui,batch'
        comfyReportedCompleted=$null-ne$comfyExec-and$comfyExec.outcome-eq'Completed'
    }
    if($checks.sequentialExecution.Values-contains$false){$fail.Add('Scenario SequentialExecution failed: order='+$seqOrder+' output='+($r5.raw-join ' | '))}

    # 6. OpenWebUI adapter fails -> batch call must never run (no cascading damage); rollback detail surfaced.
    $failRoot=Join-Path $fixtureRootBase 'failure'
    $failOrderLog=New-KIUpdateAllExecFixture -FixtureRoot $failRoot -OwuiStatus 'Failed' -OwuiExitCode 1 -UpgradeResultJson '{"status":"Completed","steps":[{"id":"comfyui","status":"Completed"}]}'
    $failFixture=$allCompliantFixture.Clone();$failFixture['comfyui']='0.0.1'
    $failOwuiFixture=@{installedVersion='0.10.2';targetVersion='0.11.0'}
    $r6=Invoke-KIUpdateAll -WrapperPath $wrapperPath -TargetScript $execScriptPath -TargetRoot $failRoot -NonInteractive -FixtureState $failFixture -OpenWebUIFixture $failOwuiFixture
    $failOrder=if(Test-Path $failOrderLog){(Get-Content -LiteralPath $failOrderLog)-join ','}else{$null}
    $owuiExecFail=$r6.json.executed|Where-Object id -eq 'openwebui'|Select-Object -First 1
    $comfyExecFail=@($r6.json.executed|Where-Object id -eq 'comfyui')
    $checks.failureStopsCascade=[ordered]@{
        exitNonZero=$r6.exit-ne0
        modeFailed=$null-ne$r6.json-and$r6.json.mode-eq'Failed'
        batchNeverRan=$failOrder-eq'openwebui'
        comfyNotTouched=$comfyExecFail.Count-eq0
        rollbackDetailSurfaced=$null-ne$owuiExecFail-and$null-ne$owuiExecFail.detail.rollback-and[bool]$owuiExecFail.detail.rollback.success
    }
    if($checks.failureStopsCascade.Values-contains$false){$fail.Add('Scenario FailureStopsCascade failed: order='+$failOrder+' output='+($r6.raw-join ' | '))}

    # 7. Without -NonInteractive, a non-'EXECUTE' confirmation cancels before anything runs.
    $cancelRoot=Join-Path $fixtureRootBase 'cancel'
    $cancelOrderLog=New-KIUpdateAllExecFixture -FixtureRoot $cancelRoot -OwuiStatus 'Completed' -OwuiExitCode 0 -UpgradeResultJson '{"status":"Completed","steps":[]}'
    $cancelFixture=$allCompliantFixture.Clone();$cancelFixture['comfyui']='0.0.1'
    $cancelOwuiFixture=@{installedVersion='0.11.0';targetVersion='0.11.0'}
    $r7=Invoke-KIUpdateAll -WrapperPath $wrapperPath -TargetScript $execScriptPath -TargetRoot $cancelRoot -FixtureState $cancelFixture -OpenWebUIFixture $cancelOwuiFixture -StdIn "no`n"
    $checks.confirmationGateCancels=[ordered]@{
        exitZero=$r7.exit-eq0
        modeCancelled=$null-ne$r7.json-and$r7.json.mode-eq'Cancelled'
        noOrderLogWritten=-not(Test-Path $cancelOrderLog)
    }
    if($checks.confirmationGateCancels.Values-contains$false){$fail.Add('Scenario ConfirmationGateCancels failed: '+($r7.raw-join ' | '))}

    # 7b. Two Complete-Installer-Upgrade-batch components need action; -Component names only one
    #     of them. The batch contract has no per-component isolation, so executing would silently
    #     touch the unnamed one too -- this must be refused up front, before any confirmation
    #     prompt and before any mutation, with a clear reason naming the omitted component(s).
    $partialRoot=Join-Path $fixtureRootBase 'partialselect'
    $partialOrderLog=New-KIUpdateAllExecFixture -FixtureRoot $partialRoot -OwuiStatus 'Completed' -OwuiExitCode 0 -UpgradeResultJson '{"status":"Completed","steps":[{"id":"comfyui","status":"Completed"},{"id":"rag","status":"Completed"}]}'
    $partialFixture=$allCompliantFixture.Clone();$partialFixture['comfyui']='0.0.1';$partialFixture['rag']='0.0.1'
    $partialOwuiFixture=@{installedVersion='0.11.0';targetVersion='0.11.0'}
    $r7b=Invoke-KIUpdateAll -WrapperPath $wrapperPath -TargetScript $execScriptPath -TargetRoot $partialRoot -NonInteractive -FixtureState $partialFixture -OpenWebUIFixture $partialOwuiFixture -Component @('comfyui')
    $partialOrderWritten=Test-Path $partialOrderLog
    $checks.batchPartialSelectionBlocked=[ordered]@{
        exitNonZero=$r7b.exit-ne0
        modeBlocked=$null-ne$r7b.json-and$r7b.json.mode-eq'Blocked'
        reasonNamesOmittedComponent=$null-ne$r7b.json-and[string]$r7b.json.batchExecutionBlocked-match'rag'
        noMutationAttempted=-not$partialOrderWritten
    }
    if($checks.batchPartialSelectionBlocked.Values-contains$false){$fail.Add('Scenario BatchPartialSelectionBlocked failed: '+($r7b.raw-join ' | '))}

    # 7c. Same situation, but -Component names EVERY batch component that currently needs action
    #     (comfyui AND rag) -- the selection no longer understates the batch's real scope, so
    #     execution proceeds normally.
    $fullRoot=Join-Path $fixtureRootBase 'fullselect'
    $fullOrderLog=New-KIUpdateAllExecFixture -FixtureRoot $fullRoot -OwuiStatus 'Completed' -OwuiExitCode 0 -UpgradeResultJson '{"status":"Completed","steps":[{"id":"comfyui","status":"Completed"},{"id":"rag","status":"Completed"}]}'
    $fullFixture=$allCompliantFixture.Clone();$fullFixture['comfyui']='0.0.1';$fullFixture['rag']='0.0.1'
    $fullOwuiFixture=@{installedVersion='0.11.0';targetVersion='0.11.0'}
    $r7c=Invoke-KIUpdateAll -WrapperPath $wrapperPath -TargetScript $execScriptPath -TargetRoot $fullRoot -NonInteractive -FixtureState $fullFixture -OpenWebUIFixture $fullOwuiFixture -Component @('comfyui','rag')
    $fullOrder=if(Test-Path $fullOrderLog){(Get-Content -LiteralPath $fullOrderLog)-join ','}else{$null}
    $checks.batchFullSelectionProceeds=[ordered]@{
        exitZero=$r7c.exit-eq0
        modeExecuted=$null-ne$r7c.json-and$r7c.json.mode-eq'Executed'
        batchRan=$fullOrder-eq'batch'
    }
    if($checks.batchFullSelectionProceeds.Values-contains$false){$fail.Add('Scenario BatchFullSelectionProceeds failed: order='+$fullOrder+' output='+($r7c.raw-join ' | '))}

    # 7d. -Component openwebui alone must never be affected by an unrelated batch ambiguity --
    #     it always has real single-component isolation of its own.
    $owuiOnlyRoot=Join-Path $fixtureRootBase 'owuionlyselect'
    $owuiOnlyOrderLog=New-KIUpdateAllExecFixture -FixtureRoot $owuiOnlyRoot -OwuiStatus 'Completed' -OwuiExitCode 0 -UpgradeResultJson '{"status":"Completed","steps":[{"id":"comfyui","status":"Completed"},{"id":"rag","status":"Completed"}]}'
    $owuiOnlyFixture=$allCompliantFixture.Clone();$owuiOnlyFixture['comfyui']='0.0.1';$owuiOnlyFixture['rag']='0.0.1'
    $owuiOnlyOwuiFixture=@{installedVersion='0.10.2';targetVersion='0.11.0'}
    $r7d=Invoke-KIUpdateAll -WrapperPath $wrapperPath -TargetScript $execScriptPath -TargetRoot $owuiOnlyRoot -NonInteractive -FixtureState $owuiOnlyFixture -OpenWebUIFixture $owuiOnlyOwuiFixture -Component @('openwebui')
    $owuiOnlyOrder=if(Test-Path $owuiOnlyOrderLog){(Get-Content -LiteralPath $owuiOnlyOrderLog)-join ','}else{$null}
    $checks.openWebUIIsolationUnaffectedByBatchAmbiguity=[ordered]@{
        exitZero=$r7d.exit-eq0
        modeExecuted=$null-ne$r7d.json-and$r7d.json.mode-eq'Executed'
        onlyOpenWebUIRan=$owuiOnlyOrder-eq'openwebui'
    }
    if($checks.openWebUIIsolationUnaffectedByBatchAmbiguity.Values-contains$false){$fail.Add('Scenario OpenWebUIIsolationUnaffectedByBatchAmbiguity failed: order='+$owuiOnlyOrder+' output='+($r7d.raw-join ' | '))}

    # 8. No secret handling introduced: Update-KIStack-All.ps1 never accepts, decrypts or writes a
    #    credential itself -- it only dispatches to the existing OpenWebUI/Complete-Installer contracts,
    #    neither of which it passes any token to.
    $updateAllSource=Get-Content -LiteralPath (Join-Path $PackageRoot 'Lifecycle/Update-KIStack-All.ps1') -Raw
    $checks.noSecretHandlingIntroduced=[ordered]@{
        noSecureStringParam=-not($updateAllSource-match'SecureString')
        noApiTokenReference=-not($updateAllSource-match'(?i)apitoken|api[-_ ]?key')
        noPlaintextCredentialWrite=-not($updateAllSource-match'(?i)password|secret\s*=')
    }
    if($checks.noSecretHandlingIntroduced.Values-contains$false){$fail.Add('Scenario NoSecretHandlingIntroduced failed')}

    # 9. Normal installer entry points are unchanged: only the two established starter-file lists were
    #    extended (to register the new files), and the ReplayComponent/Upgrade dispatch logic that a
    #    prior regression test already pins is still present verbatim.
    $moduleSource=Get-Content -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Raw
    $checks.normalInstallerUnchanged=[ordered]@{
        replayGuardStillPresent=$moduleSource.Contains('$plan.alreadyCompliant -and -not[bool]$plan.hasReplay')
        centralStartersRegistersNewFiles=$moduleSource.Contains("'Update-KIStack-OpenWebUI.cmd','Update-KIStack-OpenWebUI.ps1','Update-KIStack-All.cmd','Update-KIStack-All.ps1'")
        originalStarterFilesStillListed=$moduleSource.Contains('Start-KIStack.cmd')-and$moduleSource.Contains('Repair-KIStack.cmd')
    }
    if($checks.normalInstallerUnchanged.Values-contains$false){$fail.Add('Scenario NormalInstallerUnchanged failed')}
}
finally{if(Test-Path $fixtureRootBase){Remove-Item -LiteralPath $fixtureRootBase -Recurse -Force -ErrorAction SilentlyContinue}}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'Update-KIStack-All-Regression fehlgeschlagen.'}

[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force

$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

$contract=Get-Content -LiteralPath (Join-Path $PackageRoot 'Contracts/COMPONENTS.json') -Raw|ConvertFrom-Json -Depth 30
$allCompliantFixture=@{}
foreach($c in $contract.components){$allCompliantFixture[[string]$c.id]=[string]$c.version}

# 1. Compliant + no Replay -> unchanged Skip.
$planNoReplay=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot 'X:\NotUsed' -FixtureState $allCompliantFixture
$visualStepNoReplay=@($planNoReplay.steps|Where-Object id -eq 'openwebui-visual-pack')[0]
$checks.skipWithoutReplay=[ordered]@{
    plannedModeSkip=$visualStepNoReplay.plannedMode-eq'Skip'
    statusSkippedAlreadyCompliant=$visualStepNoReplay.status-eq'SkippedAlreadyCompliant'
    planHasReplayFalse=-not[bool]$planNoReplay.hasReplay
}
if($checks.skipWithoutReplay.Values-contains$false){$fail.Add('Scenario SkipWithoutReplay failed: '+($visualStepNoReplay|ConvertTo-Json -Compress))}

# 2. Compliant + Replay selected for Visual Pack -> re-planned, other components unaffected (no implicit recursion).
$planReplay=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot 'X:\NotUsed' -FixtureState $allCompliantFixture -ReplayComponent @('openwebui-visual-pack')
$visualStepReplay=@($planReplay.steps|Where-Object id -eq 'openwebui-visual-pack')[0]
$agentStepReplay=@($planReplay.steps|Where-Object id -eq 'openwebui-agent-pack')[0]
$otherStepReplay=@($planReplay.steps|Where-Object id -eq 'comfyui')[0]
$checks.replayVisualPack=[ordered]@{
    plannedModeReplay=$visualStepReplay.plannedMode-eq'Replay'
    statusPlanned=$visualStepReplay.status-eq'Planned'
    planHasReplayTrue=[bool]$planReplay.hasReplay
    agentPackNotImplicitlyReplayed=$agentStepReplay.plannedMode-eq'Skip'
    unrelatedComponentUnaffected=$otherStepReplay.plannedMode-eq'Skip'
}
if($checks.replayVisualPack.Values-contains$false){$fail.Add('Scenario ReplayVisualPack failed: '+($visualStepReplay|ConvertTo-Json -Compress)+' / '+($agentStepReplay|ConvertTo-Json -Compress))}

# 3. Unknown component id -> clear error before any mutation.
$unknownErrorCaught=$false
$unknownErrorMessage=$null
try{New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot 'X:\NotUsed' -FixtureState $allCompliantFixture -ReplayComponent @('does-not-exist')|Out-Null}
catch{$unknownErrorCaught=$true;$unknownErrorMessage=$_.Exception.Message}
$checks.unknownComponentIdError=[ordered]@{
    threw=$unknownErrorCaught
    correctMessage=$null-ne$unknownErrorMessage-and$unknownErrorMessage-match'Unbekannte Replay-Komponente'
}
if($checks.unknownComponentIdError.Values-contains$false){$fail.Add('Scenario UnknownComponentIdError failed: threw='+$unknownErrorCaught+' message='+$unknownErrorMessage)}

# 4. Known but not-permitted component id -> clear error before any mutation.
$notPermittedErrorCaught=$false
$notPermittedErrorMessage=$null
try{New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot 'X:\NotUsed' -FixtureState $allCompliantFixture -ReplayComponent @('comfyui')|Out-Null}
catch{$notPermittedErrorCaught=$true;$notPermittedErrorMessage=$_.Exception.Message}
$checks.notPermittedComponentIdError=[ordered]@{
    threw=$notPermittedErrorCaught
    correctMessage=$null-ne$notPermittedErrorMessage-and$notPermittedErrorMessage-match'nicht freigegeben'
}
if($checks.notPermittedComponentIdError.Values-contains$false){$fail.Add('Scenario NotPermittedComponentIdError failed: threw='+$notPermittedErrorCaught+' message='+$notPermittedErrorMessage)}

# 5. Normal, genuinely non-compliant Upgrade path is unaffected by the Replay feature.
$upgradeFixture=$allCompliantFixture.Clone()
$upgradeFixture['comfyui']='0.0.1'
$planUpgrade=New-KICompletePlan -Mode Upgrade -PackageRoot $PackageRoot -TargetRoot 'X:\NotUsed' -FixtureState $upgradeFixture
$comfyStepUpgrade=@($planUpgrade.steps|Where-Object id -eq 'comfyui')[0]
$checks.normalUpgradePathUnchanged=[ordered]@{
    plannedModeUpgrade=$comfyStepUpgrade.plannedMode-eq'Upgrade'
    statusPlanned=$comfyStepUpgrade.status-eq'Planned'
}
if($checks.normalUpgradePathUnchanged.Values-contains$false){$fail.Add('Scenario NormalUpgradePathUnchanged failed: '+($comfyStepUpgrade|ConvertTo-Json -Compress))}

# 6. Early-return short-circuit in Invoke-KIStackCompleteInstaller must not fire when a replay is pending.
$orchestratorSource=Get-Content -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Raw
$checks.earlyReturnGuardWired=[ordered]@{
    guardReferencesHasReplay=$orchestratorSource.Contains('$plan.alreadyCompliant -and -not[bool]$plan.hasReplay')
    planPassesReplayComponent=$orchestratorSource.Contains('New-KICompletePlan -Mode $Mode -PackageRoot $PackageRoot -TargetRoot $TargetRoot -EnableOpenWebUIBallistics:$EnableOpenWebUIBallistics -ReplayComponent $ReplayComponent')
}
if($checks.earlyReturnGuardWired.Values-contains$false){$fail.Add('Scenario EarlyReturnGuardWired failed')}

# 7. Guided OpenWebUI cutover is entered when the Visual Pack step arrives with plannedMode='Replay' -- reusing
#    the same process-invocation fixture technique as Test-KIStackOpenWebUIVisualPackCutover.ps1 (only the plan
#    and the final orchestrator call are stubbed; the real interactive-flow logic in
#    Start-KIStackCompleteInstaller.ps1 runs unmodified).
$source=Get-Content -LiteralPath (Join-Path $PackageRoot 'Start-KIStackCompleteInstaller.ps1') -Raw
$source=$source.Replace('if(-not(Test-KICompleteAdministrator)){','if($false){')
$source=$source.Replace('$plan=New-KICompletePlan -Mode Upgrade -PackageRoot $PSScriptRoot -TargetRoot ''C:\KI-Stack'' -ReplayComponent $ReplayComponent','$plan=[pscustomobject]@{steps=@([pscustomobject]@{id=''openwebui-visual-pack'';plannedMode=''Replay''})}')
$source=$source.Replace('try{Start-Process ''http://127.0.0.1:8080''}catch{Write-Host "OpenWebUI konnte nicht automatisch im Browser geoeffnet werden: $($_.Exception.Message)" -ForegroundColor Yellow}','Write-Host ''FIXTURE:BROWSER-OPENED''')
$source=$source.Replace('Read-Host ''Enter druecken, sobald der API-Key erzeugt wurde und bereitsteht''','''FIXTURE-CONFIRM-READY''')
$source=$source.Replace('Read-Host ''Enter druecken, sobald beide Tests erfolgreich abgeschlossen wurden''','''FIXTURE-CONFIRM-TESTS-DONE''')
$source=$source.Replace('$enteredApiToken=Read-Host ''Temporären OpenWebUI-Administrator-API-Key eingeben'' -AsSecureString','$enteredApiToken=(ConvertTo-SecureString ''fixture-token'' -AsPlainText -Force)')
$source=$source.Replace('$result=Invoke-KIStackCompleteInstaller -Mode Upgrade -PackageRoot $PSScriptRoot -TargetRoot ''C:\KI-Stack'' -TransactionId $TransactionId -Resume:$Resume -OpenWebUIApiToken $apiToken -ReplayComponent $ReplayComponent','$result=[pscustomobject]@{status=''Completed'';transactionId=''TEST-REPLAY'';steps=@([pscustomobject]@{id=''openwebui-visual-pack'';status=''Completed''})}')

$owuiLine="`$config=Invoke-WebRequest -Uri 'http://127.0.0.1:8080/api/config' -UseBasicParsing -TimeoutSec 5"
$comfyLine="`$comfy=Invoke-WebRequest -Uri 'http://127.0.0.1:8188/system_stats' -UseBasicParsing -TimeoutSec 5"
$source=$source.Replace($owuiLine,'$config=[pscustomobject]@{StatusCode=200}').Replace($comfyLine,'$comfy=[pscustomobject]@{StatusCode=200}')

$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-ReplayCutover-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $fixtureRoot -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Destination $fixtureRoot
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'Runtime') -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'Runtime/KIStackPathContext.psm1') -Destination (Join-Path $fixtureRoot 'Runtime')
    $replayScript=Join-Path $fixtureRoot 'replay.ps1';[IO.File]::WriteAllText($replayScript,$source,[Text.UTF8Encoding]::new($false))
    $replayLog=Join-Path $fixtureRoot 'replay.log'
    $replayOutput=& pwsh.exe -NoLogo -NoProfile -File $replayScript -ReplayComponent 'openwebui-visual-pack' -LogPath $replayLog 2>&1
    $replayExit=$LASTEXITCODE
    $replayText=($replayOutput-join "`n")
    $checks.guidedCutoverEnteredViaReplay=[ordered]@{
        exitCodeZero=$replayExit-eq0
        browserOpened=$replayText.Contains('FIXTURE:BROWSER-OPENED')
        guidanceBannerShown=$replayText.Contains('OpenWebUI Visual-Pack-Cutover')
        postInstallTestGateShown=$replayText.Contains('abschliessender manueller Funktionstest')
    }
    if($checks.guidedCutoverEnteredViaReplay.Values-contains$false){$fail.Add('Scenario GuidedCutoverEnteredViaReplay failed: '+$replayText)}
}
finally{if(Test-Path $fixtureRoot){Remove-Item -LiteralPath $fixtureRoot -Recurse -Force}}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'Replay-Component-Regression fehlgeschlagen.'}

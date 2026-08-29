[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force

# Exercises Resolve-KICompleteFailedTransactionState directly against the exact real-world shape
# confirmed on the actual target: an old Failed transaction whose 'comfyui' step itself reached
# status=Completed (the v0.28.0 payload-overlay ran and reported success) with rollbackStatus still
# null (the transaction failed LATER, at a different step, before any rollback bookkeeping touched
# this step), followed by a controlled, real repair of the ComfyUI checkout back to a clean,
# supported state. This must not permanently block a new run once the real target is confirmed
# consistent and compliant again -- but a genuinely inconsistent/unsupported target must still block.
function Invoke-FixtureGit {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string[]]$Arguments)
    & git.exe -C $Root @Arguments 2>&1|Out-Null
    if($LASTEXITCODE-ne0){throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"}
}

function New-KIRecoveryFixtureRepository {
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$Tag,
        [string]$MarkerVersion='1.2.4'
    )
    $comfyRoot=Join-Path $TargetRoot 'ComfyUI'
    New-Item -ItemType Directory -Path $comfyRoot -Force|Out-Null
    Invoke-FixtureGit -Root $comfyRoot -Arguments @('init','--quiet')
    Invoke-FixtureGit -Root $comfyRoot -Arguments @('config','user.name','KI-Stack Test')
    Invoke-FixtureGit -Root $comfyRoot -Arguments @('config','user.email','ki-stack-test@example.invalid')
    [IO.File]::WriteAllText((Join-Path $comfyRoot 'main.py'),"print('fixture')`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $comfyRoot 'requirements.txt'),"torch`n",[Text.UTF8Encoding]::new($false))
    Invoke-FixtureGit -Root $comfyRoot -Arguments @('add','main.py','requirements.txt')
    Invoke-FixtureGit -Root $comfyRoot -Arguments @('commit','--quiet','-m','fixture')
    Invoke-FixtureGit -Root $comfyRoot -Arguments @('tag',$Tag)
    $remoteName=('or'+'igin')
    Invoke-FixtureGit -Root $comfyRoot -Arguments @('remote','add',$remoteName,'https://github.com/comfy-org/comfyui')
    New-Item -ItemType Directory -Path (Join-Path $TargetRoot 'modules/comfyui') -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $TargetRoot 'modules/comfyui/installation.json') -Value ('{{"schemaVersion":"1.0","managedBy":"KI-STACK-COMFYUI-MANAGED","version":"{0}","release":"KI-Stack-ComfyUI-Execute-v{0}","payloadId":"KI-STACK-COMFYUI-SOURCE-V0.28.0"}}' -f $MarkerVersion) -Encoding UTF8
    $TargetRoot
}

function New-KIRecoveryFixturePackageRoot {
    param([Parameter(Mandatory)][string]$PackageStageRoot,[string]$MinimumSupportedVersion='v0.28.0',[string]$MaximumSupportedVersion=$null)
    $cutoverStage=Join-Path $PackageStageRoot 'cutover-stage'
    New-Item -ItemType Directory -Path (Join-Path $cutoverStage 'Modules/04-ComfyUI'),(Join-Path $cutoverStage 'Config'),(Join-Path $PackageStageRoot 'Payload/CutoverRuntime') -Force|Out-Null
    $cutoverRuntimeSource=[IO.Path]::GetFullPath((Join-Path $PackageRoot '../../cutover-runtime/current'))
    Copy-Item -LiteralPath (Join-Path $cutoverRuntimeSource 'Modules/04-ComfyUI/KIModuleComfyUI.psm1') -Destination (Join-Path $cutoverStage 'Modules/04-ComfyUI') -Force
    $kernelConfig=[ordered]@{comfyUI=[ordered]@{repository='https://github.com/Comfy-Org/ComfyUI';ref='v0.28.0';minimumSupportedVersion=$MinimumSupportedVersion;maximumSupportedVersion=$MaximumSupportedVersion}}
    Set-Content -LiteralPath (Join-Path $cutoverStage 'Config/kernel-config.json') -Value ($kernelConfig|ConvertTo-Json -Depth 10) -Encoding UTF8
    Compress-Archive -Path (Join-Path $cutoverStage 'Modules'),(Join-Path $cutoverStage 'Config') -DestinationPath (Join-Path $PackageStageRoot 'Payload/CutoverRuntime/CutoverRuntime.zip') -Force
    $PackageStageRoot
}

function New-KIRecoveryFixtureFailedTransaction {
    # Mirrors the exact real transaction.json shape confirmed on the actual target
    # (KI-COMPLETE-20260829-144908): comfyui step reached status=Completed (the payload overlay
    # itself "succeeded"), rollbackStatus is still null (the overall transaction failed LATER, at
    # the unrelated cutover-runtime step), and the transaction's overall status is 'Failed'.
    param([Parameter(Mandatory)][string]$StateDirectory,[string]$ComfyUIStepVersion='1.2.4')
    $transactionId='KI-COMPLETE-20260829-144908'
    $txDir=Join-Path $StateDirectory $transactionId
    New-Item -ItemType Directory -Path $txDir -Force|Out-Null
    $transaction=[ordered]@{
        schemaVersion='1.0';transactionId=$transactionId;status='Failed';mode='Upgrade'
        createdAtUtc=[DateTime]::UtcNow.ToString('o')
        steps=@(
            [ordered]@{name='ComfyUI';id='comfyui';version=$ComfyUIStepVersion;plannedMode='Upgrade';startTime=[DateTime]::UtcNow.ToString('o');endTime=[DateTime]::UtcNow.ToString('o');initialState=[ordered]@{storedVersion=$ComfyUIStepVersion;installedVersion=$ComfyUIStepVersion;compliant=$false;reconciliationNeeded=$false};result=[ordered]@{install=[ordered]@{passed=$true;changed=$true;status='Completed';backup='C:\KI-Stack\backups\comfyui-1.2.4\20260829-144911';files=160;markerMigrated=$false;rollbackStatus='NotRequired'}};backup=$null;rollbackStatus=$null;error=$null;exitCode=0;status='Completed'}
            [ordered]@{name='Cutover Runtime';id='cutover-runtime';version='1.6.11';plannedMode='Upgrade';startTime=[DateTime]::UtcNow.ToString('o');endTime=$null;initialState=[ordered]@{storedVersion='1.6.10';installedVersion='1.6.10';compliant=$false;reconciliationNeeded=$true};result=$null;backup=$null;rollbackStatus=$null;error='Cutover-Kernel fehlgeschlagen: Exitcode 30';exitCode=30;status='Failed'}
        )
    }
    Set-Content -LiteralPath (Join-Path $txDir 'transaction.json') -Value ($transaction|ConvertTo-Json -Depth 20) -Encoding UTF8
    $transactionId
}

$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}
$fixtureRootBase=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-FailedTxComfyUIRecovery-'+[guid]::NewGuid().ToString('N'))

try{
    New-Item -ItemType Directory -Path $fixtureRootBase -Force|Out-Null
    $componentContract=[pscustomobject]@{components=@(
        [pscustomobject]@{id='comfyui';name='ComfyUI';version='1.2.4';order=30;source='Payload/ComfyUI';marker='modules/comfyui/installation.json';probe=[pscustomobject]@{type='json';path='modules/comfyui/installation.json';fields=@('version','releaseVersion','packageVersion')};kind='component';installable=$true}
    )}

    # Realfall: old failed transaction (comfyui step Completed, rollbackStatus=null) + real target
    # since controlled-repaired back to clean, supported v0.34.0 (ReferenceMatch=false, Supported=true).
    $realRoot=Join-Path $fixtureRootBase 'realfall'
    $realTargetRoot=Join-Path $realRoot 'target'
    $realStateDirectory=Join-Path $realTargetRoot 'state/complete-installer'
    New-KIRecoveryFixtureRepository -TargetRoot $realTargetRoot -Tag 'v0.34.0' -MarkerVersion '1.2.4' | Out-Null
    New-Item -ItemType Directory -Path $realStateDirectory -Force|Out-Null
    $realTxId=New-KIRecoveryFixtureFailedTransaction -StateDirectory $realStateDirectory -ComfyUIStepVersion '1.2.4'
    $realPackageRoot=New-KIRecoveryFixturePackageRoot -PackageStageRoot (Join-Path $realRoot 'package')
    $realResult=$null; $realThrew=$false; $realMessage=$null
    try{ $realResult=Resolve-KICompleteFailedTransactionState -PackageRoot $realPackageRoot -TargetRoot $realTargetRoot -StateDirectory $realStateDirectory -ComponentContract $componentContract }
    catch{ $realThrew=$true; $realMessage=$_.Exception.Message }
    $realTxAfter=if(-not$realThrew){Get-Content -LiteralPath (Join-Path $realStateDirectory "$realTxId/transaction.json") -Raw|ConvertFrom-Json -Depth 20}else{$null}
    $realComfyStepAfter=if($null-ne$realTxAfter){@($realTxAfter.steps|Where-Object id -eq 'comfyui')[0]}else{$null}
    $checks.realfallOldTransactionDoesNotBlock=[ordered]@{
        didNotThrow=(-not$realThrew)
        statusRecovered=($null-ne$realResult-and[string]$realResult.status-eq'FailedTransactionStateRecovered')
        stepRetainedVerified=($null-ne$realComfyStepAfter-and[string]$realComfyStepAfter.rollbackStatus-eq'NotRequiredRetainedVerified')
        noNewPayloadMutation=(-not(Test-Path (Join-Path $realTargetRoot 'backups/complete-installer')))
    }
    if($checks.realfallOldTransactionDoesNotBlock.Values-contains$false){$fail.Add('Scenario Realfall failed: '+$realMessage)}

    # Negativkontrolle: same old failed transaction shape, but the target is genuinely inconsistent
    # -- the marker claims "1.2.4" (matching the declared component version, so the plain
    # probe-based check alone would say compliant) while the real repository clone is actually below
    # the supported minimum version. This must still block with the same "nicht recoverbar" error.
    $negativeRoot=Join-Path $fixtureRootBase 'negativkontrolle'
    $negativeTargetRoot=Join-Path $negativeRoot 'target'
    $negativeStateDirectory=Join-Path $negativeTargetRoot 'state/complete-installer'
    New-KIRecoveryFixtureRepository -TargetRoot $negativeTargetRoot -Tag 'v0.20.0' -MarkerVersion '1.2.4' | Out-Null
    New-Item -ItemType Directory -Path $negativeStateDirectory -Force|Out-Null
    New-KIRecoveryFixtureFailedTransaction -StateDirectory $negativeStateDirectory -ComfyUIStepVersion '1.2.4' | Out-Null
    $negativePackageRoot=New-KIRecoveryFixturePackageRoot -PackageStageRoot (Join-Path $negativeRoot 'package') -MinimumSupportedVersion 'v0.28.0'
    $negativeThrew=$false; $negativeMessage=$null
    try{ Resolve-KICompleteFailedTransactionState -PackageRoot $negativePackageRoot -TargetRoot $negativeTargetRoot -StateDirectory $negativeStateDirectory -ComponentContract $componentContract | Out-Null }
    catch{ $negativeThrew=$true; $negativeMessage=$_.Exception.Message }
    $checks.negativeControlStillBlocks=[ordered]@{
        threw=$negativeThrew
        messageMentionsNotRecoverable=($negativeThrew-and[string]$negativeMessage-like '*nicht recoverbar*')
    }
    if($checks.negativeControlStillBlocks.Values-contains$false){$fail.Add('Scenario Negativkontrolle failed: expected throw, got: '+$negativeMessage)}
}
finally{if(Test-Path $fixtureRootBase){Remove-Item -LiteralPath $fixtureRootBase -Recurse -Force -ErrorAction SilentlyContinue}}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'Failed-Transaction-ComfyUI-Recovery-Regression fehlgeschlagen.'}

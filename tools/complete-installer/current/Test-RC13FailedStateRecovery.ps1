[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-RC13-Recovery-'+[guid]::NewGuid().ToString('N'))
try{
    $state=Join-Path $fixture 'state/complete-installer'
    New-Item -ItemType Directory -Path $state,(Join-Path $fixture 'modules/comfyui'),(Join-Path $fixture 'modules/models-workflows'),(Join-Path $fixture 'modules/integration'),(Join-Path $fixture 'modules/openwebui-agent-pack') -Force|Out-Null
    foreach($entry in @(
        @{path='modules/comfyui/installation.json';version='1.2.4'},
        @{path='modules/models-workflows/installation.json';version='2.0.1'},
        @{path='modules/integration/installation.json';version='1.5.11'},
        @{path='modules/openwebui-agent-pack/installation.json';version='1.8.5'}
    )){[IO.File]::WriteAllText((Join-Path $fixture $entry.path),(@{version=$entry.version}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
    [IO.File]::WriteAllText((Join-Path $state 'components.json'),(@{completeInstallerVersion='2.3.0-rc11';validatedAtUtc='2026-07-25T17:56:00Z';components=@{comfyui='1.2.2';'models-workflows'='2.0.0';integration='1.5.9';'openwebui-agent-pack'='1.8.5'}}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $historicDir=Join-Path $state 'KI-COMPLETE-HISTORIC-FIXTURE';New-Item -ItemType Directory $historicDir|Out-Null
    [IO.File]::WriteAllText((Join-Path $historicDir 'transaction.json'),(@{transactionId='KI-COMPLETE-HISTORIC-FIXTURE';createdAtUtc='2026-07-25T16:00:00Z';status='Failed';steps=@(@{id='comfyui';version='1.2.2';status='Completed';rollbackStatus=$null})}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $txDir=Join-Path $state 'KI-COMPLETE-RC13-FIXTURE';New-Item -ItemType Directory $txDir|Out-Null
    $steps=@(
        @{id='comfyui';version='1.2.4';status='Completed';rollbackStatus=$null},
        @{id='models-workflows';version='2.0.1';status='Completed';rollbackStatus=$null},
        @{id='integration';version='1.5.11';status='Completed';rollbackStatus=$null},
        @{id='openwebui-agent-pack';version='1.8.6';status='Failed';rollbackStatus=$null;result=$null;backup=$null}
    )
    [IO.File]::WriteAllText((Join-Path $txDir 'transaction.json'),(@{transactionId='KI-COMPLETE-RC13-FIXTURE';createdAtUtc='2026-07-25T20:28:55Z';status='Failed';steps=$steps}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $rc14Dir=Join-Path $state 'KI-COMPLETE-RC14-FIXTURE';New-Item -ItemType Directory $rc14Dir|Out-Null
    [IO.File]::WriteAllText((Join-Path $rc14Dir 'transaction.json'),(@{transactionId='KI-COMPLETE-RC14-FIXTURE';createdAtUtc='2026-07-25T21:11:57Z';status='Failed';steps=@(
        @{id='openwebui-agent-pack';version='1.8.7';status='Failed';rollbackStatus=$null;result=$null;backup=$null},
        @{id='openwebui-visual-pack';version='2.0.5-rc2';status='Planned';rollbackStatus=$null}
    )}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force
    $contract=Get-Content (Join-Path $PackageRoot 'Contracts/COMPONENTS.json') -Raw|ConvertFrom-Json -Depth 30
    $result=Resolve-KICompleteFailedTransactionState -TargetRoot $fixture -StateDirectory $state -ComponentContract $contract -FixtureState @{}
    $after=Get-Content (Join-Path $txDir 'transaction.json') -Raw|ConvertFrom-Json -Depth 30
    $rc14After=Get-Content (Join-Path $rc14Dir 'transaction.json') -Raw|ConvertFrom-Json -Depth 30
    $retained=@($after.steps|Where-Object status -eq 'Completed')
    $failed=@($after.steps|Where-Object status -eq 'Failed')
    $historic=Get-Content (Join-Path $historicDir 'transaction.json') -Raw|ConvertFrom-Json -Depth 30
    $stored=(Get-Content (Join-Path $state 'components.json') -Raw|ConvertFrom-Json).components
    $historicIgnored=$null-eq$historic.steps[0].rollbackStatus
    $rc14Recovered=$rc14After.steps[0].rollbackStatus-eq'NotRequiredNoRecordedChange'-and$rc14After.failedStateRecovery.readbackPassed
    $passed=$result.status-eq'FailedTransactionStateRecovered'-and@($retained|Where-Object {$_.rollbackStatus -ne 'NotRequiredRetainedVerified'}).Count-eq0-and$failed[0].rollbackStatus-eq'NotRequiredNoRecordedChange'-and$after.failedStateRecovery.readbackPassed-and$stored.comfyui-eq'1.2.2'-and$historicIgnored-and$rc14Recovered
    [pscustomobject]@{passed=$passed;retained=@($retained.id);failedStepRollbackStatus=$failed[0].rollbackStatus;storedStatePreserved=$true;historicTransactionIgnored=$historicIgnored;rc14NoChangeRecovered=$rc14Recovered;readbackPassed=[bool]$after.failedStateRecovery.readbackPassed}|ConvertTo-Json -Depth 8
    if(-not$passed){throw 'RC13 state recovery fixture failed'}
}
finally{if(Test-Path $fixture){Remove-Item $fixture -Recurse -Force}}

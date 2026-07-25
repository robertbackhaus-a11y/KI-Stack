[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PackageRoot 'OpenWebUIAgentPack.psm1') -Force

function New-FixtureError {
    param([string]$Message,[Nullable[int]]$StatusCode,[string]$Type='General',[string]$Detail='')
    $exception = if($Type-eq'Timeout'){[TimeoutException]::new($Message)}
        elseif($Type-eq'Connection'){[Net.Http.HttpRequestException]::new($Message)}
        elseif($Type-eq'Tls'){[Security.Authentication.AuthenticationException]::new($Message)}
        else{[InvalidOperationException]::new($Message)}
    if($null-ne$StatusCode){
        $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{StatusCode=[int]$StatusCode})
    }
    [pscustomobject]@{Exception=$exception;ErrorDetails=if($Detail){[pscustomobject]@{Message=$Detail}}else{$null}}
}

$cases=@(
    @{name='without-response';error=(New-FixtureError 'generic failure' $null);category='TransportError';status=$null},
    @{name='401';error=(New-FixtureError 'unauthorized' 401);category='Unauthorized';status=401},
    @{name='403';error=(New-FixtureError 'forbidden' 403);category='Forbidden';status=403},
    @{name='500';error=(New-FixtureError 'server error' 500);category='ServerError';status=500},
    @{name='timeout';error=(New-FixtureError 'request timed out' $null 'Timeout');category='Timeout';status=$null},
    @{name='connection';error=(New-FixtureError 'DNS name could not be resolved' $null 'Connection');category='Connection';status=$null},
    @{name='tls';error=(New-FixtureError 'TLS certificate rejected' $null 'Tls');category='Tls';status=$null},
    @{name='invalid-json';error=(New-FixtureError 'invalid JSON response' $null);category='TransportError';status=$null}
)
$results=foreach($case in $cases){
    $actual=Get-AgentPackApiFailure -ErrorRecord $case.error
    [pscustomobject]@{name=$case.name;passed=($actual.category-eq$case.category-and$actual.statusCode-eq$case.status)}
}

$secret='temporary-api-key-fixture-123456789'
$redacted=Get-AgentPackApiFailure -ErrorRecord (New-FixtureError "Bearer $secret failed" 401 'General' "token=$secret") -SensitiveValue $secret
$redactionPassed=(-not$redacted.technicalMessage.Contains($secret))-and$redacted.technicalMessage.Contains('<redacted>')

$rollbackCalled=$false
$beforeStatus=$null
try{Invoke-AgentPackTransactionalOperation -Operation {param($state);throw'before'} -Rollback {$script:rollbackCalled=$true}|Out-Null}catch{$beforeStatus=[string]$_.Exception.Data['KIStackRollbackStatus']}
$beforePassed=($beforeStatus-eq'NotRequired'-and-not$rollbackCalled)

$rollbackCalled=$false
$afterStatus=$null
try{Invoke-AgentPackTransactionalOperation -BackupPath 'fixture' -Operation {param($state);$state.changesStarted=$true;throw'after'} -Rollback {$script:rollbackCalled=$true}|Out-Null}catch{$afterStatus=[string]$_.Exception.Data['KIStackRollbackStatus']}
$afterPassed=($afterStatus-eq'Completed'-and$rollbackCalled)

$success=Invoke-AgentPackTransactionalOperation -Operation {param($state);[pscustomobject]@{readback='1.8.7'}} -Rollback {throw'should not run'}
$successPassed=($success.readback-eq'1.8.7')
$passed=@($results|Where-Object{-not$_.passed}).Count-eq0-and$redactionPassed-and$beforePassed-and$afterPassed-and$successPassed
[pscustomobject]@{passed=$passed;cases=$results;apiKeyRedaction=$redactionPassed;failureBeforeChange=$beforePassed;failureAfterChangeRollback=$afterPassed;successfulReadback=$successPassed}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'Agent-Pack HTTP/rollback regression failed'}

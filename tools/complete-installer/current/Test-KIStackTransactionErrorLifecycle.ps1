[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$failures=[Collections.Generic.List[string]]::new()

Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force

# Regression: first attempt failed -> resume succeeds -> final status
# Completed -> error null.
# Simulates exactly what a -Resume load from a previously-failed
# transaction.json produces: a transaction-wide .error property set by the
# catch block (CompleteInstaller.psm1 ~line 962-969) on the earlier failed
# attempt, persisted to disk, and read back unchanged at the start of the
# next attempt.
$failedTx=[pscustomobject][ordered]@{
    schemaVersion='1.0'
    transactionId='KI-COMPLETE-ERRORLIFECYCLE-FIXTURE'
    status='Failed'
    steps=@(
        [pscustomobject][ordered]@{id='codex-local';version='0.1.3';status='Failed';error='LM Studio /v1/models ist nicht erreichbar.';exitCode=1}
    )
}
$failedTx|Add-Member -NotePropertyName error -NotePropertyValue 'LM Studio /v1/models ist nicht erreichbar.' -Force
if(-not $failedTx.PSObject.Properties['error']){$failures.Add('Fixture-Vorbereitung fehlgeschlagen: error-Property nicht gesetzt.')}

$resumedTx=Clear-KICompleteStaleTransactionError -Transaction $failedTx
$resumedTx.status='Completed'
$resumedTx.steps[0].status='Completed'
$resumedTx.steps[0].error=$null
$resumedTx.steps[0].exitCode=0

if($resumedTx.PSObject.Properties['error']){$failures.Add('Stehengebliebenes transaktionsweites error-Feld wurde nicht entfernt.')}
if($resumedTx.status-ne'Completed'){$failures.Add('Transaktionsstatus ist nach erfolgreichem Resume nicht Completed.')}
if($null-ne$resumedTx.steps[0].error){$failures.Add('Schritt-Fehlerfeld ist nach erfolgreichem Resume nicht null.')}

# Round-trip through real JSON serialization, matching how transaction.json
# is actually written/read across a resume.
$roundTripPath=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-ErrorLifecycle-'+[guid]::NewGuid().ToString('N')+'.json')
try{
    Write-KICompleteJson -Path $roundTripPath -Value $resumedTx
    $reloaded=Read-KICompleteJson -Path $roundTripPath
    if($reloaded.PSObject.Properties['error']){$failures.Add('error-Feld tauchte nach JSON-Round-Trip wieder auf.')}
    if([string]$reloaded.status-ne'Completed'){$failures.Add('status ist nach JSON-Round-Trip nicht Completed.')}
}finally{
    if(Test-Path -LiteralPath $roundTripPath){Remove-Item -LiteralPath $roundTripPath -Force}
}

# A transaction that never had the stale property must pass through
# unaffected (no exception, no spurious property added).
$cleanTx=[pscustomobject][ordered]@{schemaVersion='1.0';transactionId='KI-COMPLETE-CLEAN-FIXTURE';status='Completed';steps=@()}
$cleanResult=Clear-KICompleteStaleTransactionError -Transaction $cleanTx
if($cleanResult.PSObject.Properties['error']){$failures.Add('Clear-KICompleteStaleTransactionError fügte fälschlich ein error-Feld hinzu.')}

$result=[pscustomobject]@{passed=($failures.Count-eq0);checks=6;failures=@($failures)}
$result|ConvertTo-Json -Depth 10
if(-not$result.passed){exit 1}

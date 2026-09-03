[CmdletBinding()]
param(
    [string]$Endpoint = 'http://127.0.0.1:8080',
    [Parameter(Mandatory)][Security.SecureString]$ApiToken,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Collections
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# POST-COMMIT, best-effort cleanup (Finalization-Rollback-P1) of the OpenWebUI Knowledge
# collections/files a prior, already-committed Remove-KIStackKnowledgeExperiment.ps1 (Detach)
# run identified as no longer referenced by any KI-Stack-managed profile. Called ONLY after
# WriteFinalState has already succeeded (see CompleteInstaller.psm1's finalization sequence),
# so this script's own outcome -- good or bad -- must never influence whether the already-
# committed installation is considered successful, and must never attempt to reconstruct or
# roll back anything. Every failure is caught per item, never thrown, and left as orphaned/stale
# data on the OpenWebUI side: preferred over destructive loss or an inconsistent rollback
# attempt against an installation that is already committed.
function ConvertFrom-Secure([Security.SecureString]$Value){$p=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value);try{[Runtime.InteropServices.Marshal]::PtrToStringBSTR($p)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p)}}
function Invoke-Api([string]$Path,[string]$Method='GET'){$plain=ConvertFrom-Secure $ApiToken;try{Invoke-RestMethod -Uri ($Endpoint.TrimEnd('/')+$Path) -Method $Method -Headers @{Authorization="Bearer $plain"} -TimeoutSec 120}finally{$plain=$null}}
function Get-KIHttpStatusCodeOrNull($Exception){
    # StrictMode-safe: a genuine HTTP error (Invoke-RestMethod's own HttpResponseException) has a
    # real .Response.StatusCode, but a network-level failure (connection refused, timeout, DNS)
    # throws a different exception type with no .Response property AT ALL -- under
    # Set-StrictMode -Version Latest, referencing a property that does not exist on the object
    # (not merely one that is $null) throws "cannot be found on this object", so this must be
    # checked via PSObject.Properties rather than plain dot-access before ever reading it.
    $responseProperty=$Exception.PSObject.Properties['Response']
    if($null-eq$responseProperty-or$null-eq$responseProperty.Value){return $null}
    $statusCodeProperty=$responseProperty.Value.PSObject.Properties['StatusCode']
    if($null-eq$statusCodeProperty){return $null}
    return [int]$statusCodeProperty.Value.value__
}

$collectionsRemoved=0
$filesRemoved=0
$remaining=[Collections.Generic.List[object]]::new()
$failures=[Collections.Generic.List[string]]::new()
try {
    foreach($collection in @($Collections)){
        $collectionId=[string]$collection.id
        $collectionFailed=$false
        try { $null=Invoke-Api "/api/v1/knowledge/$collectionId/delete" 'DELETE'; $collectionsRemoved++ }
        catch { $collectionFailed=$true; $failures.Add("Collection ${collectionId}: $($_.Exception.Message)") }
        foreach($fileId in @($collection.fileIds)){
            try {
                $null=Invoke-Api "/api/v1/files/$fileId" 'DELETE'
                $filesRemoved++
            }
            catch {
                if((Get-KIHttpStatusCodeOrNull $_.Exception) -eq 404){$filesRemoved++;continue}
                $failures.Add("File ${fileId}: $($_.Exception.Message)")
            }
        }
        if($collectionFailed){$remaining.Add([ordered]@{id=$collectionId;name=[string]$collection.name})}
    }
}
catch {
    # Belt-and-suspenders only -- every real per-item failure above is already caught locally.
    $failures.Add("Unerwarteter Fehler im Knowledge-Cleanup: $($_.Exception.Message)")
}
$ApiToken=$null;[GC]::Collect()
$status=if(@($Collections).Count-eq0){'NothingToClean'}elseif($failures.Count-eq0){'Completed'}else{'CompletedWithWarnings'}
[pscustomobject]@{status=$status;collectionsRemoved=$collectionsRemoved;filesRemoved=$filesRemoved;remainingCollections=@($remaining);failures=@($failures)}

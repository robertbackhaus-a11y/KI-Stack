[CmdletBinding()]
param(
    [string]$SourcePath = (Join-Path $PSScriptRoot 'ExternalModels'),
    [string]$TargetRoot = 'C:\KI-Stack\models',
    [string]$ManifestPath,
    [string]$StateRoot = 'C:\KI-Stack\state\model-import',
    [string]$TransactionId,
    [switch]$Resume,
    [switch]$Rollback,
    [switch]$Audit,
    [switch]$DisableNetwork
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-ResultAndExit {
    param([Parameter(Mandatory)][object]$Result,[int]$ExitCode=0)
    $Result | ConvertTo-Json -Depth 30
    exit $ExitCode
}
function Read-Contracts {
    param([Parameter(Mandatory)][string]$Path)
    $document=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json -Depth 100
    if($document.PSObject.Properties.Name -contains 'models'){
        return @($document.models|Where-Object{$_.PSObject.Properties.Name-contains'profile'-and[string]$_.profile-in@('krea-realism','pony-sdxl','wan22-5b')}|ForEach-Object{
            [pscustomobject]@{id=[string]$_.id;fileName=[string]$_.fileName;sizeBytes=[int64]$_.sizeBytes;sha256=([string]$_.sha256).ToLowerInvariant();targetDirectory=[string]$_.targetDirectory;source=[string]$_.source;manualExternal=[bool]$_.manualExternal}
        })
    }
    return @($document.external|Where-Object{$_.PSObject.Properties.Name-contains'category'-and[string]$_.category-eq'models-workflows-1.4.6'}|ForEach-Object{
        [pscustomobject]@{id=[string]$_.id;fileName=[string]$_.fileName;sizeBytes=[int64]$_.sizeBytes;sha256=([string]$_.sha256).ToLowerInvariant();targetDirectory=([string]$_.target-replace'^models/','');source=[string]$_.source;manualExternal=[bool]$_.manualExternal}
    })
}
function Test-ModelFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$Contract)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return [pscustomobject]@{exists=$false;valid=$false;size=$null;sha256=$null}}
    $item=Get-Item -LiteralPath $Path
    if([int64]$item.Length-ne[long]$Contract.sizeBytes){return [pscustomobject]@{exists=$true;valid=$false;size=[int64]$item.Length;sha256=$null}}
    $hash=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    [pscustomobject]@{exists=$true;valid=($hash-eq[string]$Contract.sha256);size=[int64]$item.Length;sha256=$hash}
}
function Write-State {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$State)
    $State.updatedAtUtc=[DateTime]::UtcNow.ToString('o')
    $temp=$Path+'.tmp'
    $State|ConvertTo-Json -Depth 50|Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

if([string]::IsNullOrWhiteSpace($ManifestPath)){
    $modelsManifest=Join-Path $PSScriptRoot 'Manifests\models.manifest.json'
    $completeManifest=Join-Path $PSScriptRoot 'Contracts\PAYLOADS.json'
    $ManifestPath=if(Test-Path -LiteralPath $modelsManifest){$modelsManifest}else{$completeManifest}
}
$contracts=@(Read-Contracts -Path $ManifestPath)
if($contracts.Count-ne8){throw "Der externe Modellvertrag muss exakt acht Modelle enthalten; gefunden: $($contracts.Count)."}
$SourcePath=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($SourcePath))
$TargetRoot=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($TargetRoot))
$StateRoot=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StateRoot))
if([string]::IsNullOrWhiteSpace($TransactionId)){$TransactionId='model-import-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)}
$transactionDirectory=Join-Path $StateRoot $TransactionId
$statePath=Join-Path $transactionDirectory 'transaction.json'

if($Rollback){
    if(-not(Test-Path -LiteralPath $statePath -PathType Leaf)){throw "Rollback-Transaktion nicht gefunden: $TransactionId"}
    $state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json -Depth 50
    $issues=[Collections.Generic.List[string]]::new()
    foreach($entry in @($state.changes)|Sort-Object order -Descending){
        try{
            if([bool]$entry.existedBefore){Copy-Item -LiteralPath ([string]$entry.backupPath) -Destination ([string]$entry.targetPath) -Force}
            elseif(Test-Path -LiteralPath ([string]$entry.targetPath)){Remove-Item -LiteralPath ([string]$entry.targetPath) -Force}
            $partial=[string]$entry.targetPath+'.partial';if(Test-Path -LiteralPath $partial){Remove-Item -LiteralPath $partial -Force}
        }catch{[void]$issues.Add($_.Exception.Message)}
    }
    $state.status=if($issues.Count){'RollbackFailed'}else{'RolledBack'};Write-State -Path $statePath -State $state
    Write-ResultAndExit -Result ([pscustomobject]@{status=$state.status;transactionId=$TransactionId;issues=@($issues)}) -ExitCode $(if($issues.Count){1}else{0})
}

$inspection=[Collections.Generic.List[object]]::new()
foreach($contract in $contracts){
    $target=Join-Path (Join-Path $TargetRoot ([string]$contract.targetDirectory)) ([string]$contract.fileName)
    $targetState=Test-ModelFile -Path $target -Contract $contract
    $source=Join-Path $SourcePath ([string]$contract.fileName)
    $sourceState=Test-ModelFile -Path $source -Contract $contract
    $action=if($targetState.valid){'AlreadyCompliant'}elseif($sourceState.valid){'Import'}elseif(-not[bool]$contract.manualExternal-and-not$DisableNetwork){'Download'}elseif($sourceState.exists){'InvalidSource'}else{'MissingSource'}
    [void]$inspection.Add([pscustomobject]@{contract=$contract;targetPath=$target;target=$targetState;sourcePath=$source;source=$sourceState;action=$action})
}
$requirements=@($inspection|Where-Object{$_.action-in@('MissingSource','InvalidSource')}|ForEach-Object{
    [pscustomobject]@{fileName=$_.contract.fileName;sizeBytes=$_.contract.sizeBytes;sha256=$_.contract.sha256;sourcePath=$_.sourcePath;reason=$_.action}
})
if($Audit){
    Write-ResultAndExit -Result ([pscustomobject]@{status=if(@($inspection|Where-Object{-not$_.target.valid}).Count){'WaitingForUserAction'}else{'AlreadyCompliant'};readOnly=$true;models=@($inspection|ForEach-Object{[pscustomobject]@{id=$_.contract.id;fileName=$_.contract.fileName;targetPath=$_.targetPath;valid=[bool]$_.target.valid}});requirements=$requirements})
}
if($requirements.Count){
    New-Item -ItemType Directory -Path $transactionDirectory -Force|Out-Null
    $state=[ordered]@{schemaVersion='1.0';transactionId=$TransactionId;status='WaitingForUserAction';sourcePath=$SourcePath;targetRoot=$TargetRoot;createdAtUtc=[DateTime]::UtcNow.ToString('o');updatedAtUtc=$null;changes=@();requirements=$requirements}
    Write-State -Path $statePath -State $state
    Write-ResultAndExit -Result ([pscustomobject]@{status='WaitingForUserAction';transactionId=$TransactionId;resumeCommand="Import-KIStackExternalModels.ps1 -SourcePath `"$SourcePath`" -TransactionId `"$TransactionId`" -Resume";requirements=$requirements}) -ExitCode 20
}

New-Item -ItemType Directory -Path $transactionDirectory -Force|Out-Null
$state=if($Resume-and(Test-Path -LiteralPath $statePath)){Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json -Depth 50}else{[pscustomobject]@{schemaVersion='1.0';transactionId=$TransactionId;status='Running';sourcePath=$SourcePath;targetRoot=$TargetRoot;createdAtUtc=[DateTime]::UtcNow.ToString('o');updatedAtUtc=$null;changes=@();requirements=@()}}
$downloadDirectory=Join-Path $transactionDirectory 'downloads';$backupDirectory=Join-Path $transactionDirectory 'backup'
foreach($item in $inspection){
    if($item.action-eq'AlreadyCompliant'){continue}
    $contract=$item.contract;$source=[string]$item.sourcePath
    if($item.action-eq'Download'){
        New-Item -ItemType Directory -Path $downloadDirectory -Force|Out-Null
        $source=Join-Path $downloadDirectory ([string]$contract.fileName)
        Invoke-WebRequest -Uri ([string]$contract.source) -OutFile $source -UseBasicParsing
        if(-not(Test-ModelFile -Path $source -Contract $contract).valid){throw "Download ist ungültig: $($contract.fileName); erwartet $($contract.sizeBytes) Bytes, SHA256 $($contract.sha256)."}
    }
    $target=[string]$item.targetPath;$parent=Split-Path -Parent $target
    New-Item -ItemType Directory -Path $parent -Force|Out-Null
    $existing=Test-Path -LiteralPath $target -PathType Leaf;$backup=$null
    if($existing){New-Item -ItemType Directory -Path $backupDirectory -Force|Out-Null;$backup=Join-Path $backupDirectory ([string]$contract.fileName);Copy-Item -LiteralPath $target -Destination $backup -Force}
    $entry=[pscustomobject]@{order=@($state.changes).Count;id=$contract.id;targetPath=$target;existedBefore=$existing;backupPath=$backup}
    $state.changes=@($state.changes)+@($entry);Write-State -Path $statePath -State $state
    $partial=$target+'.partial';Copy-Item -LiteralPath $source -Destination $partial -Force
    if(-not(Test-ModelFile -Path $partial -Contract $contract).valid){throw "Übernahmedatei ist ungültig: $($contract.fileName); erwartet $($contract.sizeBytes) Bytes, SHA256 $($contract.sha256)."}
    Move-Item -LiteralPath $partial -Destination $target -Force
}
$invalid=@($contracts|Where-Object{$contract=$_;$target=Join-Path(Join-Path $TargetRoot $contract.targetDirectory)$contract.fileName;-not(Test-ModelFile -Path $target -Contract $contract).valid})
if($invalid.Count){throw "Abschlussprüfung fehlgeschlagen: $($invalid.fileName -join ', ')"}
$state.status='Completed';$state.requirements=@();Write-State -Path $statePath -State $state
Write-ResultAndExit -Result ([pscustomobject]@{status='Completed';transactionId=$TransactionId;models=@($contracts|ForEach-Object{[pscustomobject]@{id=$_.id;status='AlreadyCompliantOrImported'}})})

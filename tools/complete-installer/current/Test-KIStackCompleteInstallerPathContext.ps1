[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'Runtime/KIStackPathContext.psm1') -Force -DisableNameChecking

$failures=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}
function Add-Check {
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][bool]$Passed,[string]$Detail='')
    $script:checks[$Name]=[ordered]@{passed=$Passed;detail=$Detail}
    if(-not$Passed){$script:failures.Add("${Name}: $Detail")}
}
function Test-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action,[Parameter(Mandatory)][string]$Pattern)
    try{& $Action|Out-Null;$false}catch{$_.Exception.Message-match$Pattern}
}
function Test-UnderRoot {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Root)
    $prefix=$Root.TrimEnd('\')+'\'
    $Path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
}

$default=New-KICompletePathContext -PackageRoot $PackageRoot -TransactionId 'COMMIT2-DEFAULT'
$defaultExpected=[ordered]@{
    StateRoot='C:\KI-Stack\state\complete-installer'
    TransactionBaseRoot='C:\KI-Stack\state\complete-installer\transactions'
    TransactionRoot='C:\KI-Stack\state\complete-installer\transactions\COMMIT2-DEFAULT'
    BackupRoot='C:\KI-Stack\backups\complete-installer'
    TransactionBackupRoot='C:\KI-Stack\backups\complete-installer\COMMIT2-DEFAULT'
    LogRoot='C:\KI-Stack\logs\complete-installer'
    TransactionLogRoot='C:\KI-Stack\logs\complete-installer\COMMIT2-DEFAULT'
    PayloadRoot='C:\KI-Stack\state\complete-installer\transactions\COMMIT2-DEFAULT\payload'
    TempRoot='C:\KI-Stack\state\complete-installer\transactions\COMMIT2-DEFAULT\staging'
}
$defaultPathsPass=$true
foreach($name in $defaultExpected.Keys){if([string]$default.$name-ne[string]$defaultExpected[$name]){$defaultPathsPass=$false}}
Add-Check 'DefaultRootPaths' $defaultPathsPass ($default|ConvertTo-Json -Compress)
Add-Check 'DefaultComponentsPath' ((Get-KICompleteComponentStatePath -PathContext $default)-eq'C:\KI-Stack\state\complete-installer\components.json') (Get-KICompleteComponentStatePath -PathContext $default)

$suiteRoot=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-Commit2-'+[guid]::NewGuid().ToString('N'))
try{
    $rootA=Join-Path $suiteRoot 'Root A'
    $rootB=Join-Path $suiteRoot 'Root B'
    $transactionId='SAME-TRANSACTION-ID'
    $contextA=New-KICompletePathContext -TargetRoot $rootA -PackageRoot $PackageRoot -TransactionId $transactionId -Mutating
    $contextB=New-KICompletePathContext -TargetRoot $rootB -PackageRoot $PackageRoot -TransactionId $transactionId -Mutating
    $allA=@($contextA.StateRoot,$contextA.TransactionBaseRoot,$contextA.TransactionRoot,$contextA.BackupRoot,$contextA.TransactionBackupRoot,$contextA.LogRoot,$contextA.TransactionLogRoot,$contextA.PayloadRoot,$contextA.TempRoot,(Get-KICompleteComponentStatePath -PathContext $contextA))
    Add-Check 'AlternateRootIsolation' (@($allA|Where-Object{-not(Test-UnderRoot -Path $_ -Root $contextA.TargetRoot)}).Count-eq0) ($allA-join'; ')
    Add-Check 'NoDefaultRootFallback' (@($allA|Where-Object{$_.StartsWith('C:\KI-Stack\',[StringComparison]::OrdinalIgnoreCase)}).Count-eq0) ($allA-join'; ')
    Add-Check 'TwoRootsSameTransactionId' (
        $contextA.TransactionId-eq$contextB.TransactionId-and
        $contextA.TransactionRoot-ne$contextB.TransactionRoot-and
        $contextA.TransactionBackupRoot-ne$contextB.TransactionBackupRoot-and
        $contextA.TransactionLogRoot-ne$contextB.TransactionLogRoot
    ) "A=$($contextA.TransactionRoot); B=$($contextB.TransactionRoot)"

    $plan=[pscustomobject]@{mode='Install';steps=@()}
    $createdA=New-KICompleteTransaction -Plan $plan -PathContext $contextA
    $createdB=New-KICompleteTransaction -Plan $plan -PathContext $contextB
    Add-Check 'TransactionFilesIsolated' (
        (Test-Path -LiteralPath $createdA.path -PathType Leaf)-and
        (Test-Path -LiteralPath $createdB.path -PathType Leaf)-and
        (Test-UnderRoot -Path $createdA.path -Root $contextA.TargetRoot)-and
        (Test-UnderRoot -Path $createdB.path -Root $contextB.TargetRoot)
    ) "A=$($createdA.path); B=$($createdB.path)"

    $transactionA=Get-Content -LiteralPath $createdA.path -Raw|ConvertFrom-Json -Depth 30
    $metadataPass=[string]$transactionA.schemaVersion-eq'1.1'
    foreach($name in @('targetRoot','stateRoot','transactionRoot','backupRoot','logRoot','pathContractVersion')){
        if(-not[string]::Equals([string]$transactionA.$name,[string]$contextA.$name,[StringComparison]::OrdinalIgnoreCase)){$metadataPass=$false}
    }
    Add-Check 'TransactionMetadata11' $metadataPass ($transactionA|ConvertTo-Json -Compress)
    $loaded=Read-KICompleteTransactionForResume -PathContext $contextA
    Add-Check 'PathAwareResumeSameRoot' (-not[bool]$loaded.legacy-and$loaded.path-eq$createdA.path) $loaded.path

    $statePlan=[pscustomobject]@{steps=@([pscustomobject]@{id='fixture-component';version='1.0';initialState=[pscustomobject]@{compliant=$true}})}
    $stateA=Update-KICompleteComponentState -Plan $statePlan -PathContext $contextA -CompleteVersion '2.13.0'
    $stateB=Update-KICompleteComponentState -Plan $statePlan -PathContext $contextB -CompleteVersion '2.13.0'
    $storedA=Get-KICompleteStoredVersion -Component ([pscustomobject]@{id='fixture-component'}) -PathContext $contextA
    $storedB=Get-KICompleteStoredVersion -Component ([pscustomobject]@{id='fixture-component'}) -PathContext $contextB
    Add-Check 'CanonicalComponentsPath' (
        $stateA-eq(Get-KICompleteComponentStatePath -PathContext $contextA)-and
        $stateB-eq(Get-KICompleteComponentStatePath -PathContext $contextB)-and
        $storedA-eq'1.0'-and$storedB-eq'1.0'-and$stateA-ne$stateB
    ) "A=$stateA; B=$stateB"

    $legacyContext=New-KICompletePathContext -TargetRoot (Join-Path $suiteRoot 'Legacy Alternate') -PackageRoot $PackageRoot -TransactionId 'LEGACY-TX' -Mutating
    $legacyPath=Join-Path $legacyContext.TransactionRoot 'transaction.json'
    Write-KICompleteJson -Path $legacyPath -Value ([ordered]@{schemaVersion='1.0';transactionId='LEGACY-TX';status='Failed';steps=@()})
    $legacyBefore=Get-Content -LiteralPath $legacyPath -Raw
    Add-Check 'LegacyCrossRootFailsClosed' (Test-Throws -Action {Read-KICompleteTransactionForResume -PathContext $legacyContext} -Pattern 'Schema-1.0|Legacy') 'alternate-root schema 1.0 resume was accepted'
    Add-Check 'LegacyNotMigrated' ((Get-Content -LiteralPath $legacyPath -Raw)-ceq$legacyBefore-and[string](Get-Content -LiteralPath $legacyPath -Raw|ConvertFrom-Json).schemaVersion-eq'1.0') $legacyPath

    $source=Get-Content -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Raw
    Add-Check 'ConfigPathsNotRuntimeSources' ($source-notmatch '\$config\.(stateDirectory|backupDirectory|logDirectory)') 'active config path reference found'
    Add-Check 'NoCompetingComponentsLiteral' ($source-notmatch 'Join-Path \$TargetRoot ''state/complete-installer/components\.json''') 'hard-coded components.json path found'
}
finally{
    if(Test-Path -LiteralPath $suiteRoot){Remove-Item -LiteralPath $suiteRoot -Recurse -Force}
}

$result=[pscustomobject][ordered]@{passed=($failures.Count-eq0);checks=$checks;failures=@($failures)}
$result|ConvertTo-Json -Depth 12
if($failures.Count){throw('CompleteInstaller PathContext tests failed: '+($failures-join'; '))}

[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'Runtime/KIStackPathContext.psm1') -Force -DisableNameChecking
$repositoryRoot=(Resolve-Path (Join-Path $PackageRoot '../../..')).Path
$cutoverRoot=Join-Path $repositoryRoot 'tools/cutover-runtime/current'
Import-Module (Join-Path $cutoverRoot 'Core/KIStack.BuilderKernel.Core.psm1') -Force -DisableNameChecking

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

    $baseConfig=Join-Path $cutoverRoot 'Config/kernel-config.json'
    $driveContext=New-KICompletePathContext -TargetRoot 'D:\KI-Stack-Test' -PackageRoot $PackageRoot -TransactionId 'TX-ALT'
    $driveConfig=New-KICompleteKernelRuntimeConfig -PathContext $driveContext -BaseConfigPath $baseConfig -KernelTransactionId 'TX-ALT-cutover' -KernelStateRoot ([IO.Path]::Combine([string]$driveContext.TempRoot,'cutover-state'))
    $drivePaths=Get-KIKernelTargetRelativeConfigPaths -Config $driveConfig
    Add-Check 'KernelRuntimeAlternateRoot' (@($drivePaths.Values|Where-Object{-not(Test-KIPathUnderRoot -Path ([string]$_) -Root 'D:\KI-Stack-Test')}).Count-eq0) ($drivePaths.Values-join'; ')

    $defaultConfig=New-KICompleteKernelRuntimeConfig -PathContext $default -BaseConfigPath $baseConfig -KernelTransactionId 'COMMIT2-DEFAULT-cutover' -KernelStateRoot ([IO.Path]::Combine([string]$default.TempRoot,'cutover-state'))
    Add-Check 'KernelRuntimeDefaultRoot' ([string]$defaultConfig.stackRoot-eq'C:\KI-Stack'-and[string]$defaultConfig.comfyUI.root-eq'C:\KI-Stack\ComfyUI') ([string]$defaultConfig.comfyUI.root)

    $spacesContext=New-KICompletePathContext -TargetRoot 'D:\Local AI\KI Stack' -PackageRoot $PackageRoot -TransactionId 'TX-SPACES'
    $spacesConfig=New-KICompleteKernelRuntimeConfig -PathContext $spacesContext -BaseConfigPath $baseConfig -KernelTransactionId 'TX-SPACES-cutover' -KernelStateRoot ([IO.Path]::Combine([string]$spacesContext.TempRoot,'cutover-state'))
    Add-Check 'KernelRuntimeSpaces' (
        [string]$spacesConfig.applications.openWebUI.dataRoot-eq'D:\Local AI\KI Stack\OpenWebUI\data'-and
        (ConvertTo-KICompleteProcessArgument ([string]$spacesContext.TargetRoot))-eq'"D:\Local AI\KI Stack"'
    ) ([string]$spacesConfig.applications.openWebUI.dataRoot)

    $kernelStateA=[IO.Path]::Combine([string]$contextA.TempRoot,'cutover-state')
    $kernelStateB=[IO.Path]::Combine([string]$contextB.TempRoot,'cutover-state')
    $runtimeA=Write-KICompleteKernelRuntimeConfig -PathContext $contextA -BaseConfigPath $baseConfig -KernelTransactionId ($transactionId+'-cutover') -KernelStateRoot $kernelStateA
    $runtimeARepeat=Write-KICompleteKernelRuntimeConfig -PathContext $contextA -BaseConfigPath $baseConfig -KernelTransactionId ($transactionId+'-cutover') -KernelStateRoot $kernelStateA
    $runtimeB=Write-KICompleteKernelRuntimeConfig -PathContext $contextB -BaseConfigPath $baseConfig -KernelTransactionId ($transactionId+'-cutover') -KernelStateRoot $kernelStateB
    Add-Check 'KernelRuntimeDeterministic' ($runtimeA.sha256-eq$runtimeARepeat.sha256) ([string]$runtimeA.sha256)
    Add-Check 'KernelRuntimeTwoRoots' ($runtimeA.path-ne$runtimeB.path-and$runtimeA.sha256-ne$runtimeB.sha256) "A=$($runtimeA.path); B=$($runtimeB.path)"

    $parsedA=Read-KICompleteJson -Path $runtimeA.path
    Assert-KIKernelRuntimeConfig -Config $parsedA -RuntimeConfigPath $runtimeA.path -ExpectedTargetRoot $rootA -ExpectedTransactionId ($transactionId+'-cutover') -StateDirectory $kernelStateA -ExpectedSha256 $runtimeA.sha256
    Add-Check 'KernelRuntimeValidContract' $true ([string]$runtimeA.path)
    Add-Check 'KernelRuntimeTamperedTarget' (Test-Throws -Action {Assert-KIKernelRuntimeConfig -Config $parsedA -RuntimeConfigPath $runtimeA.path -ExpectedTargetRoot $rootB -ExpectedTransactionId ($transactionId+'-cutover') -StateDirectory $kernelStateA -ExpectedSha256 $runtimeA.sha256} -Pattern 'TargetRoot') 'mismatched ExpectedTargetRoot accepted'
    Add-Check 'KernelRuntimeTamperedTransaction' (Test-Throws -Action {Assert-KIKernelRuntimeConfig -Config $parsedA -RuntimeConfigPath $runtimeA.path -ExpectedTargetRoot $rootA -ExpectedTransactionId 'FOREIGN-cutover' -StateDirectory $kernelStateA -ExpectedSha256 $runtimeA.sha256} -Pattern 'TransactionId') 'mismatched TransactionId accepted'
    Add-Check 'KernelRuntimeMissingFile' (Test-Throws -Action {Assert-KIKernelRuntimeConfig -Config $parsedA -RuntimeConfigPath (Join-Path $contextA.TransactionRoot 'missing.json') -ExpectedTargetRoot $rootA -ExpectedTransactionId ($transactionId+'-cutover') -StateDirectory $kernelStateA -ExpectedSha256 $runtimeA.sha256} -Pattern 'nicht gefunden') 'missing RuntimeConfig accepted'
    Add-Content -LiteralPath $runtimeA.path -Value ' ' -Encoding UTF8
    Add-Check 'KernelRuntimeTamperedSha' (Test-Throws -Action {Assert-KIKernelRuntimeConfig -Config $parsedA -RuntimeConfigPath $runtimeA.path -ExpectedTargetRoot $rootA -ExpectedTransactionId ($transactionId+'-cutover') -StateDirectory $kernelStateA -ExpectedSha256 $runtimeA.sha256} -Pattern 'SHA256') 'tampered RuntimeConfig SHA accepted'

    $runtimeA=Write-KICompleteKernelRuntimeConfig -PathContext $contextA -BaseConfigPath $baseConfig -KernelTransactionId ($transactionId+'-cutover') -KernelStateRoot $kernelStateA
    $injected=Read-KICompleteJson -Path $runtimeA.path
    $injected.pythonEnvironment.root=[IO.Path]::Combine($rootB,'python')
    $injected|ConvertTo-Json -Depth 100|Set-Content -LiteralPath $runtimeA.path -Encoding UTF8
    $injectedSha=(Get-FileHash -LiteralPath $runtimeA.path -Algorithm SHA256).Hash
    Add-Check 'KernelRuntimeForeignPath' (Test-Throws -Action {Assert-KIKernelRuntimeConfig -Config $injected -RuntimeConfigPath $runtimeA.path -ExpectedTargetRoot $rootA -ExpectedTransactionId ($transactionId+'-cutover') -StateDirectory $kernelStateA -ExpectedSha256 $injectedSha} -Pattern 'Target-relativer') 'foreign python root accepted'

    $kernelSource=Get-Content -LiteralPath (Join-Path $cutoverRoot 'Invoke-KIStackBuilderKernel.ps1') -Raw
    $starterSource=Get-Content -LiteralPath (Join-Path $cutoverRoot 'Start-KIStack-Cutover.ps1') -Raw
    Add-Check 'KernelRuntimeCompleteFailClosed' ($source.Contains("'-RuntimeConfigPath'")-and$source.Contains("'-ExpectedTargetRoot'")-and$source.Contains("'-ExpectedRuntimeConfigSha256'")-and$kernelSource.Contains('RuntimeConfigPath und ExpectedTargetRoot müssen')) 'CompleteInstaller runtime binding missing'
    Add-Check 'KernelRuntimeStandaloneCompatibility' ($kernelSource.Contains('[string]$ConfigPath =')-and$starterSource.Contains("'Config\kernel-config.json'")) 'standalone ConfigPath contract missing'
}
finally{
    if(Test-Path -LiteralPath $suiteRoot){Remove-Item -LiteralPath $suiteRoot -Recurse -Force}
}

$result=[pscustomobject][ordered]@{passed=($failures.Count-eq0);checks=$checks;failures=@($failures)}
$result|ConvertTo-Json -Depth 12
if($failures.Count){throw('CompleteInstaller PathContext tests failed: '+($failures-join'; '))}

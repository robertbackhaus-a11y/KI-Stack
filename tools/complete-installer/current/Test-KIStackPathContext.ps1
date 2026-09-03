[CmdletBinding()]
param(
    [string]$PackageRoot = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PackageRoot 'Runtime/KIStackPathContext.psm1') -Force -DisableNameChecking

$failures = [Collections.Generic.List[string]]::new()
$checks = [ordered]@{}

function Add-Check {
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][bool]$Passed,[string]$Detail='')
    $script:checks[$Name] = [ordered]@{passed=$Passed;detail=$Detail}
    if (-not $Passed) { $script:failures.Add("${Name}: $Detail") }
}

function Test-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action,[Parameter(Mandatory)][string]$Pattern)
    try { & $Action | Out-Null; return $false }
    catch { return $_.Exception.Message -match $Pattern }
}

$default = New-KICompletePathContext -PackageRoot $PackageRoot
Add-Check 'DefaultRoot' ($default.TargetRoot -eq 'C:\KI-Stack') $default.TargetRoot
Add-Check 'DefaultDerivedRoots' (
    $default.StateRoot -eq 'C:\KI-Stack\state\complete-installer' -and
    $default.TransactionBaseRoot -eq 'C:\KI-Stack\state\complete-installer\transactions' -and
    $default.BackupRoot -eq 'C:\KI-Stack\backups\complete-installer' -and
    $default.LogRoot -eq 'C:\KI-Stack\logs\complete-installer' -and
    $default.ModuleRoot -eq 'C:\KI-Stack\modules' -and
    $default.PythonRoot -eq 'C:\KI-Stack\python' -and
    $default.DataRoot -eq 'C:\KI-Stack\data'
) ($default | ConvertTo-Json -Depth 5 -Compress)

$alternate = New-KICompletePathContext -TargetRoot 'D:\KI-Stack-Test' -PackageRoot $PackageRoot -Mutating
$alternatePaths = @($alternate.StateRoot,$alternate.TransactionBaseRoot,$alternate.BackupRoot,$alternate.LogRoot,$alternate.ModuleRoot,$alternate.PythonRoot,$alternate.DataRoot)
Add-Check 'AlternateRoot' (@($alternatePaths | Where-Object { -not $_.StartsWith('D:\KI-Stack-Test\',[StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) ($alternatePaths -join '; ')

$withSpaces = New-KICompletePathContext -TargetRoot 'D:\Local AI\KI Stack' -PackageRoot $PackageRoot -Mutating
Add-Check 'SpacesPreserved' ($withSpaces.TargetRoot -eq 'D:\Local AI\KI Stack') $withSpaces.TargetRoot

$trailing = New-KICompletePathContext -TargetRoot 'D:\KI-Stack-Test\' -PackageRoot $PackageRoot -Mutating
Add-Check 'TrailingSeparatorNormalized' (Test-KICompleteSameRoot -First $alternate.TargetRoot -Second $trailing.TargetRoot) "$($alternate.TargetRoot) <> $($trailing.TargetRoot)"
Add-Check 'RootComparisonCaseInsensitive' (Test-KICompleteSameRoot -First 'd:\ki-stack-test\' -Second 'D:\KI-STACK-TEST') 'case/trailing comparison'

Add-Check 'RelativeRejected' (Test-Throws -Action { New-KICompletePathContext -TargetRoot '.\KI-Stack' -PackageRoot $PackageRoot -Mutating } -Pattern 'absolut') 'relative path was not rejected'
Add-Check 'DriveRootRejectedForMutation' (Test-Throws -Action { New-KICompletePathContext -TargetRoot 'D:\' -PackageRoot $PackageRoot -Mutating } -Pattern 'Laufwerkswurzel') 'drive root was not rejected'
Add-Check 'UncRejectedForMutation' (Test-Throws -Action { New-KICompletePathContext -TargetRoot '\\server\share\KI-Stack' -PackageRoot $PackageRoot -Mutating } -Pattern 'UNC') 'UNC path was not rejected'

$txA = New-KICompletePathContext -TargetRoot 'D:\KI-Stack-Test' -PackageRoot $PackageRoot -TransactionId 'A' -Mutating
$txB = New-KICompletePathContext -TargetRoot 'D:\KI-Stack-Test' -PackageRoot $PackageRoot -TransactionId 'B' -Mutating
Add-Check 'TransactionIsolation' (
    $txA.TransactionRoot -eq 'D:\KI-Stack-Test\state\complete-installer\transactions\A' -and
    $txB.TransactionRoot -eq 'D:\KI-Stack-Test\state\complete-installer\transactions\B' -and
    $txA.TransactionBackupRoot -ne $txB.TransactionBackupRoot -and
    $txA.TransactionLogRoot -ne $txB.TransactionLogRoot -and
    $txA.PayloadRoot -ne $txB.PayloadRoot -and
    $txA.TempRoot -ne $txB.TempRoot
) "A=$($txA.TransactionRoot); B=$($txB.TransactionRoot)"

$unsafeIds = @('..','..\foo','foo\bar','C:\absolute','C:drive-qualified','/absolute')
$unsafeRejected = foreach ($unsafeId in $unsafeIds) {
    Test-Throws -Action { New-KICompletePathContext -TargetRoot 'D:\KI-Stack-Test' -PackageRoot $PackageRoot -TransactionId $unsafeId -Mutating } -Pattern 'TransactionId'
}
Add-Check 'TransactionIdTraversalRejected' ($unsafeRejected -notcontains $false) ($unsafeIds -join ', ')

$suiteRoot = Join-Path ([IO.Path]::GetTempPath()) ('KIStack-PathContext-' + [guid]::NewGuid().ToString('N'))
try {
    $nonexistent = Join-Path $suiteRoot 'read-only-does-not-create'
    $null = New-KICompletePathContext -TargetRoot $nonexistent -PackageRoot $PackageRoot
    Add-Check 'ReadOnlyContextHasNoSideEffects' (-not (Test-Path -LiteralPath $nonexistent)) $nonexistent
    Add-Check 'ReadOnlyContextCannotCreateDirectories' (Test-Throws -Action { Initialize-KICompletePathContextDirectories -Context (New-KICompletePathContext -TargetRoot $nonexistent -PackageRoot $PackageRoot) } -Pattern 'mutierenden') 'read-only context accepted directory creation'

    New-Item -ItemType Directory -Path $suiteRoot -Force | Out-Null
    $realRoot = Join-Path $suiteRoot 'real-root'
    $junctionRoot = Join-Path $suiteRoot 'junction-root'
    New-Item -ItemType Directory -Path $realRoot -Force | Out-Null
    $junctionCreated = $false
    try {
        New-Item -ItemType Junction -Path $junctionRoot -Target $realRoot -ErrorAction Stop | Out-Null
        $junctionCreated = $true
        Add-Check 'JunctionRejectedForMutation' (Test-Throws -Action { New-KICompletePathContext -TargetRoot $junctionRoot -PackageRoot $PackageRoot -Mutating } -Pattern 'Junction|symbolisch|Reparse') $junctionRoot
    }
    catch {
        Add-Check 'JunctionRejectedForMutation' $true ('fixture unavailable: ' + $_.Exception.Message)
    }

    $created = @(Initialize-KICompletePathContextDirectories -Context $txA -WhatIf)
    Add-Check 'DirectoryCreationSeparated' ($created.Count -eq 0 -and -not (Test-Path -LiteralPath $txA.TargetRoot)) 'WhatIf must not create directories'
}
finally {
    if (Test-Path -LiteralPath $suiteRoot) { Remove-Item -LiteralPath $suiteRoot -Recurse -Force }
}

$schemaPath = Join-Path $PackageRoot 'Contracts/TRANSACTION.schema.json'
$schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -Depth 30
$legacyRequired = @($schema.'$defs'.legacyTransaction.required)
$pathAwareRequired = @($schema.'$defs'.pathAwareTransaction.required)
$requiredPathFields = @('schemaVersion','targetRoot','stateRoot','transactionRoot','backupRoot','logRoot','pathContractVersion')
Add-Check 'SchemaDeclaresLegacy10' ([string]$schema.'$defs'.legacyTransaction.properties.schemaVersion.const -eq '1.0') 'legacy schema missing'
Add-Check 'SchemaDeclaresPathAware11' (
    [string]$schema.'$defs'.pathAwareTransaction.properties.schemaVersion.const -eq '1.1' -and
    @($requiredPathFields | Where-Object { $pathAwareRequired -notcontains $_ }).Count -eq 0
) ($pathAwareRequired -join ', ')

$legacyDocument = [ordered]@{schemaVersion='1.0';transactionId='legacy';status='Planned';steps=@()}
$legacyRoundTrip = $legacyDocument | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10
Add-Check 'LegacySchemaRoundTripNoMigration' (
    [string]$legacyRoundTrip.schemaVersion -eq '1.0' -and
    $legacyRoundTrip.PSObject.Properties.Name -notcontains 'targetRoot'
) ($legacyRoundTrip | ConvertTo-Json -Compress)

$newDocument = [ordered]@{
    schemaVersion='1.1';transactionId='A';status='Planned';steps=@()
    targetRoot=$txA.TargetRoot;stateRoot=$txA.StateRoot;transactionRoot=$txA.TransactionRoot
    backupRoot=$txA.BackupRoot;logRoot=$txA.LogRoot
    pathContractVersion=$txA.PathContractVersion
}
$newRoundTrip = $newDocument | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10
Add-Check 'PathAwareSchemaRoundTrip' (
    [string]$newRoundTrip.schemaVersion -eq '1.1' -and
    @($requiredPathFields | Where-Object { $newRoundTrip.PSObject.Properties.Name -notcontains $_ }).Count -eq 0
) ($newRoundTrip | ConvertTo-Json -Compress)

$result = [pscustomobject][ordered]@{passed=($failures.Count -eq 0);checks=$checks;failures=@($failures)}
$result | ConvertTo-Json -Depth 12
if ($failures.Count) { throw ('Path context tests failed: ' + ($failures -join '; ')) }

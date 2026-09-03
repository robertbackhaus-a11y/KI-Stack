[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

Import-Module (Join-Path $PackageRoot 'Lifecycle/KIStackUpdateIsolation.psm1') -Force -DisableNameChecking
$checks=[Collections.Generic.List[object]]::new()
$failures=[Collections.Generic.List[string]]::new()

function Add-Check([string]$Name,[bool]$Passed,[string]$Detail) {
    $checks.Add([pscustomobject][ordered]@{name=$Name;passed=$Passed;detail=$Detail})
    if(-not$Passed){$failures.Add("$Name failed: $Detail")}
}

function Test-UnderRoot([string]$Path,[string]$Root) {
    $pathValue=[IO.Path]::GetFullPath($Path)
    $rootValue=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    $pathValue.StartsWith($rootValue,[StringComparison]::OrdinalIgnoreCase)
}

$poison=[pscustomobject]@{stateDirectory='C:\Wrong-State';backupDirectory='C:\Wrong-Backup'}
$default=New-KIStackIsolatedUpdatePaths -TargetRoot 'C:\KI-Stack' -PackageRoot $PackageRoot -RunId 'DEFAULT'
Add-Check 'DefaultRoot' (
    (Test-UnderRoot $default.WorkDirectory 'C:\KI-Stack\state\complete-installer') -and
    (Test-UnderRoot $default.BackupRoot 'C:\KI-Stack\backups\complete-installer')
) "$($default.WorkDirectory); $($default.BackupRoot)"

$rootA='D:\KI-A'
$rootB='E:\KI-B'
$pathsA=New-KIStackIsolatedUpdatePaths -TargetRoot $rootA -PackageRoot $PackageRoot -RunId 'SAME-RUN'
$pathsB=New-KIStackIsolatedUpdatePaths -TargetRoot $rootB -PackageRoot $PackageRoot -RunId 'SAME-RUN'
Add-Check 'AlternateRoot' ((Test-UnderRoot $pathsA.WorkDirectory $rootA)-and(Test-UnderRoot $pathsA.BackupRoot $rootA)) "$($pathsA.WorkDirectory); $($pathsA.BackupRoot)"
Add-Check 'TwoRoots' (
    $pathsA.WorkDirectory-ne$pathsB.WorkDirectory -and $pathsA.BackupRoot-ne$pathsB.BackupRoot -and
    (Test-UnderRoot $pathsB.WorkDirectory $rootB) -and (Test-UnderRoot $pathsB.BackupRoot $rootB)
) "A=$($pathsA.WorkDirectory),$($pathsA.BackupRoot); B=$($pathsB.WorkDirectory),$($pathsB.BackupRoot)"

$spacesRoot='D:\Local AI\KI Stack'
$spaces=New-KIStackIsolatedUpdatePaths -TargetRoot $spacesRoot -PackageRoot $PackageRoot -RunId 'SPACES'
Add-Check 'Spaces' ((Test-UnderRoot $spaces.WorkDirectory $spacesRoot)-and(Test-UnderRoot $spaces.BackupRoot $spacesRoot)) "$($spaces.WorkDirectory); $($spaces.BackupRoot)"

# The production executor still receives Config for endpoint/non-path settings, but path
# resolution deliberately receives no Config object. Poisoned legacy fields therefore cannot
# influence either result.
$poisoned=New-KIStackIsolatedUpdatePaths -TargetRoot $rootA -PackageRoot $PackageRoot -RunId 'POISONED'
Add-Check 'ConfigPoisoningIgnored' (
    -not$poisoned.WorkDirectory.StartsWith([string]$poison.stateDirectory,[StringComparison]::OrdinalIgnoreCase) -and
    -not$poisoned.BackupRoot.StartsWith([string]$poison.backupDirectory,[StringComparison]::OrdinalIgnoreCase) -and
    (Test-UnderRoot $poisoned.WorkDirectory $rootA) -and (Test-UnderRoot $poisoned.BackupRoot $rootA)
) "$($poisoned.WorkDirectory); $($poisoned.BackupRoot)"

$source=Get-Content -LiteralPath (Join-Path $PackageRoot 'Lifecycle/KIStackUpdateIsolation.psm1') -Raw
$caller=Get-Content -LiteralPath (Join-Path $PackageRoot 'Lifecycle/Update-KIStack-All.ps1') -Raw
Add-Check 'NoLegacyConfigRuntimeSource' (
    $source-notmatch '\$Config\.(stateDirectory|backupDirectory)' -and
    $caller.Contains('-PathContext $updatePathContext')
) 'active lifecycle update path must use PathContext, not legacy Config path fields'

$result=[pscustomobject][ordered]@{passed=($failures.Count-eq0);checks=@($checks);failures=@($failures)}
$result|ConvertTo-Json -Depth 10
if(-not$result.passed){throw ('Lifecycle TargetRoot isolation failed: '+($failures-join'; '))}

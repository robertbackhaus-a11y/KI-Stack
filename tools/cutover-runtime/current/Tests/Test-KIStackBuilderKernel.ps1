[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$results = [Collections.Generic.List[object]]::new()
function Add-Check([string]$Name,[bool]$Passed,[string]$Detail) {
    $results.Add([pscustomobject]@{name=$Name;passed=$Passed;detail=$Detail}) | Out-Null
}

$config = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Config\kernel-config.json') -Raw |
    ConvertFrom-Json -Depth 100
$expectedModules = @(
    'KIModuleFoundation',
    'KIModuleRuntime',
    'KIModulePythonGit',
    'KIModuleComfyUI',
    'KIModuleApplications',
    'KIModuleIntegration',
    'KIModuleCutover',
    'KIModuleValidation'
)
$actualModules = @($config.executeRelease.enabledModules)
Add-Check 'Version contract' (
    [string]$config.kernelVersion -eq '1.6.14' -and
    [string]$config.executeRelease.releaseId -eq 'CUTOVER-1.6.14'
) "kernel=$($config.kernelVersion); release=$($config.executeRelease.releaseId)"
Add-Check 'Enabled module contract' (
    @(Compare-Object ($expectedModules | Sort-Object) ($actualModules | Sort-Object)).Count -eq 0
) ($actualModules -join ',')
Add-Check 'No legacy model module' (
    $actualModules -notcontains 'KIModuleModels' -and
    -not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'Modules\05-Models'))
) 'Models and workflows are owned by Complete Installer component 2.0.1.'

$applicationsModule=$null
$applicationsTransaction=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-Applications-DryRun-'+[guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $applicationsTransaction -Force|Out-Null
    $applicationsModule=Import-Module (Join-Path $ProjectRoot 'Modules/06-Applications/KIModuleApplications.psm1') -Force -PassThru -DisableNameChecking
    $applicationsContext=[pscustomobject]@{
        Mode='DryRun';Config=$config;TransactionDirectory=$applicationsTransaction
        Transaction=[pscustomobject]@{transactionId='SELFTEST-APPLICATIONS-DRYRUN'}
        LogPath=(Join-Path $applicationsTransaction 'transaction.log.jsonl')
    }
    $applicationsResult=Install-KIModuleApplications -Context $applicationsContext
    Add-Check 'Applications module DryRun' ([bool]$applicationsResult.success) 'LM Studio/OpenWebUI planning completed without target access.'
} catch {
    Add-Check 'Applications module DryRun' $false $_.Exception.Message
} finally {
    if($applicationsModule){Remove-Module -ModuleInfo $applicationsModule -Force -ErrorAction SilentlyContinue}
    if(Test-Path -LiteralPath $applicationsTransaction){Remove-Item -LiteralPath $applicationsTransaction -Recurse -Force}
}

$moduleErrors = @()
foreach ($directory in Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'Modules') -Directory) {
    $manifestPath = Join-Path $directory.FullName 'module.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $moduleErrors += "missing manifest: $($directory.Name)"
        continue
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 30
    $modulePath = Get-ChildItem -LiteralPath $directory.FullName -File -Filter '*.psm1' |
        Select-Object -First 1
    if (-not $modulePath) { $moduleErrors += "missing module: $($directory.Name)" }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.name)) {
        $moduleErrors += "missing module name: $($directory.Name)"
    }
}
Add-Check 'Module source completeness' ($moduleErrors.Count -eq 0) $(
    if ($moduleErrors) { $moduleErrors -join '; ' } else { 'all module manifests and sources present' }
)

$preflightTest = & (Join-Path $ProjectRoot 'Tests\Test-KIStackEmbeddedPreflight.ps1') `
    -ProjectRoot $ProjectRoot | ConvertFrom-Json
Add-Check 'Runtime preflight generation' ([bool]$preflightTest.passed) (
    "tests=$($preflightTest.tests); sha256=$($preflightTest.sha256)"
)
$restartTest=& (Join-Path $ProjectRoot 'Tests\Test-KIStackIntegrationRebootResume.ps1') -ProjectRoot $ProjectRoot|ConvertFrom-Json
Add-Check 'Integration reboot and resume contract' ([bool]$restartTest.passed) ("greenfield=$($restartTest.greenfield); resume=$($restartTest.resumeAfterRestart); exit=$($restartTest.rebootExitCode)")
$searxngPinTest = & (Join-Path $ProjectRoot 'Tests\Test-KIStackIntegrationSearXNGPin.ps1') -ProjectRoot $ProjectRoot | ConvertFrom-Json
Add-Check 'Integration SearXNG commit pin contract' ([bool]$searxngPinTest.passed) (
    "ref=$($searxngPinTest.configuredRef); valid=$($searxngPinTest.validPinResolvedAndCheckedOut); invalid=$($searxngPinTest.invalidPinFailedDeterministically)"
)
$comfyDirtyTest = & (Join-Path $ProjectRoot 'Tests\Test-KIStackComfyUIDirtyRepository.ps1') -ProjectRoot $ProjectRoot | ConvertFrom-Json
Add-Check 'ComfyUI repository dirty contract' ([bool]$comfyDirtyTest.passed) (
    "lineEndings=$($comfyDirtyTest.lineEndingOnlyAllowed); content=$($comfyDirtyTest.realUnstagedChangeBlocked); staged=$($comfyDirtyTest.realStagedChangeBlocked); untracked=$($comfyDirtyTest.untrackedRelevantFileBlocked)"
)

$failed = @($results | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    generatedAtUtc=[DateTime]::UtcNow.ToString('o')
    release='CUTOVER-1.6.14'
    passed=($failed.Count -eq 0)
    checksPassed=@($results | Where-Object passed).Count
    checksTotal=$results.Count
    results=@($results)
}
$report | ConvertTo-Json -Depth 20
if ($failed) { throw ('Cutover self-test failed: ' + (($failed | ForEach-Object name) -join ', ')) }

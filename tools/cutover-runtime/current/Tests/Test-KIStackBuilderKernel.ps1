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
    [string]$config.kernelVersion -eq '1.6.4' -and
    [string]$config.executeRelease.releaseId -eq 'CUTOVER-1.6.4'
) "kernel=$($config.kernelVersion); release=$($config.executeRelease.releaseId)"
Add-Check 'Enabled module contract' (
    @(Compare-Object ($expectedModules | Sort-Object) ($actualModules | Sort-Object)).Count -eq 0
) ($actualModules -join ',')
Add-Check 'No legacy model module' (
    $actualModules -notcontains 'KIModuleModels' -and
    -not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'Modules\05-Models'))
) 'Models and workflows are owned by Complete Installer component 2.0.1.'

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

$failed = @($results | Where-Object { -not $_.passed })
$report = [pscustomobject][ordered]@{
    generatedAtUtc=[DateTime]::UtcNow.ToString('o')
    release='CUTOVER-1.6.4'
    passed=($failed.Count -eq 0)
    checksPassed=@($results | Where-Object passed).Count
    checksTotal=$results.Count
    results=@($results)
}
$report | ConvertTo-Json -Depth 20
if ($failed) { throw ('Cutover self-test failed: ' + (($failed | ForEach-Object name) -join ', ')) }

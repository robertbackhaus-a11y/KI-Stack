[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedRoot = (Resolve-Path -LiteralPath $ProjectRoot -ErrorAction Stop).Path
$stateRoot = Join-Path $resolvedRoot 'State\PathValidation'
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null

$requiredRelativePaths = @(
    'Bootstrap-KIStack-Cutover.cmd',
    'Start-Nur-Selbsttest.cmd',
    'Start-KIStack-Cutover-DryRun.cmd',
    'Start-KIStack-Cutover-Execute.cmd',
    'Start-KIStack-Cutover.ps1',
    'Request-KIStack-Elevation.ps1',
    'Config\kernel-config.json',
    'Core\KIStack.Starter.psm1',
    'Invoke-KIStackBuilderKernel.ps1',
    'Tests\Test-KIStackBuilderKernel.ps1',
    'Tests\Test-KIStackPowerShellSyntax.ps1',
    'Tests\Test-KIStackPathResolution.ps1',
    'Modules\08-Cutover\KIModuleCutover.psm1',
    'Modules\08-Cutover\module.json',
    'New-KIStackEmbeddedPreflight.ps1'
)

$scenarios = @(
    [pscustomobject]@{ name='Aktuelle Paketwurzel'; path=$resolvedRoot; copy=$false },
    [pscustomobject]@{ name='Einfach entpackt'; path=(Join-Path ([IO.Path]::GetTempPath()) 'KI-Stack-PathTest\Einfach\Paket'); copy=$true },
    [pscustomobject]@{ name='Doppelt verschachtelt'; path=(Join-Path ([IO.Path]::GetTempPath()) 'KI-Stack-PathTest\Doppelt\Paket\Paket'); copy=$true },
    [pscustomobject]@{ name='Leerzeichen und doppelte Verschachtelung'; path=(Join-Path ([IO.Path]::GetTempPath()) 'KI Stack Path Test\Paket mit Leerzeichen\Paket mit Leerzeichen'); copy=$true }
)

$results = [System.Collections.Generic.List[object]]::new()
try {
    $bootstrapContent = Get-Content -LiteralPath (Join-Path $resolvedRoot 'Bootstrap-KIStack-Cutover.cmd') -Raw
    $launcherContent = Get-Content -LiteralPath (Join-Path $resolvedRoot 'Start-KIStack-Cutover.ps1') -Raw
    $starterCmds = @(
        'Start-Nur-Selbsttest.cmd',
        'Start-KIStack-Cutover-DryRun.cmd',
        'Start-KIStack-Cutover-Execute.cmd'
    )

    $semanticChecks = @(
        $bootstrapContent.Contains('set "PACKAGE_ROOT=%~dp0"'),
        $bootstrapContent.Contains('pushd "%PACKAGE_ROOT%"'),
        $launcherContent.Contains('$projectRoot = $PSScriptRoot'),
        $launcherContent.Contains('Join-Path $projectRoot'),
        (@($starterCmds | Where-Object {
            (Get-Content -LiteralPath (Join-Path $resolvedRoot $_) -Raw).Contains('%~dp0')
        }).Count -eq $starterCmds.Count)
    )
    if ($semanticChecks -contains $false) {
        throw 'Die Starter verwenden nicht durchgängig paketrelative, gequotete Pfade.'
    }

    foreach ($scenario in $scenarios) {
        $scenarioRoot = [IO.Path]::GetFullPath([string]$scenario.path)
        if ([bool]$scenario.copy) {
            if (Test-Path -LiteralPath $scenarioRoot) {
                Remove-Item -LiteralPath $scenarioRoot -Recurse -Force
            }
            New-Item -ItemType Directory -Path $scenarioRoot -Force | Out-Null
            Get-ChildItem -LiteralPath $resolvedRoot -Force |
                Where-Object { $_.Name -ne 'State' } |
                ForEach-Object {
                    Copy-Item -LiteralPath $_.FullName -Destination $scenarioRoot -Recurse -Force
                }
        }

        $missing = @(
            foreach ($relativePath in $requiredRelativePaths) {
                $candidate = Join-Path $scenarioRoot $relativePath
                if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                    $relativePath
                }
            }
        )

        $config = Get-Content -LiteralPath (Join-Path $scenarioRoot 'Config\kernel-config.json') -Raw |
            ConvertFrom-Json -Depth 100
        $embeddedPath = Join-Path $scenarioRoot ([string]$config.starter.embeddedPreflightRelativePath)
        $embeddedExists = Test-Path -LiteralPath $embeddedPath -PathType Leaf

        $passed = ($missing.Count -eq 0 -and $embeddedExists)
        [void]$results.Add([pscustomobject][ordered]@{
            name = [string]$scenario.name
            path = $scenarioRoot
            passed = $passed
            missing = @($missing)
            embeddedPreflight = $embeddedPath
            embeddedPreflightExists = $embeddedExists
        })
    }
}
finally {
    foreach ($scenario in $scenarios | Where-Object { [bool]$_.copy }) {
        $scenarioRoot = [IO.Path]::GetFullPath([string]$scenario.path)
        if (Test-Path -LiteralPath $scenarioRoot) {
            Remove-Item -LiteralPath $scenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$failed = @($results | Where-Object { -not [bool]$_.passed })
$report = [pscustomobject][ordered]@{
    generatedAt = (Get-Date).ToString('o')
    projectRoot = $resolvedRoot
    passed = ($failed.Count -eq 0)
    scenarios = @($results)
}
$json = $report | ConvertTo-Json -Depth 20
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$reportPath = Join-Path $stateRoot ("Path-Validation-{0}.json" -f $timestamp)
$latestPath = Join-Path $stateRoot 'Path-Validation-latest.json'
Set-Content -LiteralPath $reportPath -Value $json -Encoding UTF8
Set-Content -LiteralPath $latestPath -Value $json -Encoding UTF8
$json
Write-Host ("Pfadvalidierungsbericht: {0}" -f $latestPath)
if ($failed.Count -gt 0) { exit 1 }
exit 0

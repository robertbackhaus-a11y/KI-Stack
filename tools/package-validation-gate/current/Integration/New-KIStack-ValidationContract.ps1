[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [Parameter(Mandatory)][string]$PackageName,
    [Parameter(Mandatory)][string]$PackageVersion,
    [Parameter(Mandatory)][string]$PackageType,
    [Parameter(Mandatory)][string]$SelfTestEntryPoint,
    [Parameter()][string[]]$RequiredFiles = @(),
    [Parameter()][string[]]$AdditionalRegressionIds = @(),
    [Parameter()][string[]]$NotApplicableRegressionIds = @(),
    [Parameter()][switch]$TargetSystemAcceptanceRequired,
    [Parameter()][string]$GateRoot = 'C:\KI-Stack\Tools\PackageValidationGate\current'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $PackageRoot).Path
$registryPath = Join-Path $GateRoot 'Policy\KNOWN-REGRESSIONS.json'
if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
    throw "Regression Registry fehlt: $registryPath"
}
$registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json -Depth 50
$knownIds = @($registry.regressions | ForEach-Object { [string]$_.id })
$universalIds = @(
    'REG-004-HASHTABLE-KEYS',
    'REG-005-DOUBLE-BACKSLASH-PREFIX',
    'REG-006-BROAD-GIT-TEXT-SCAN',
    'REG-007-NESTED-EXTRACTION-PATHS',
    'REG-009-POWERSHELL7-RESOLUTION',
    'REG-012-SELFTEST-AGGREGATION',
    'REG-014-COMPLETE-LOGGING',
    'REG-015-FINAL-ZIP-NOT-WORKDIR',
    'REG-016-ZIP-PATH-SECURITY',
    'REG-017-EXACT-MANIFEST-SET',
    'REG-018-SIDECAR-IDENTITY',
    'REG-019-NATIVE-PARSER-REQUIRED',
    'REG-020-UNEXECUTED-NOT-PASSED'
)
$allIds = @($universalIds + $AdditionalRegressionIds | Sort-Object -Unique)
$unknown = @($allIds + $NotApplicableRegressionIds | Where-Object { $_ -notin $knownIds } | Sort-Object -Unique)
if ($unknown.Count -gt 0) { throw "Unbekannte Regression-IDs: $($unknown -join ', ')" }
$invalidNotApplicable = @($NotApplicableRegressionIds | Where-Object { $_ -notin $allIds })
if ($invalidNotApplicable.Count -gt 0) { throw "Nicht anwendbare IDs müssen im Vertragsumfang liegen: $($invalidNotApplicable -join ', ')" }

$validationDir = Join-Path $root 'Validation'
New-Item -ItemType Directory -Path $validationDir -Force | Out-Null
$contractPath = Join-Path $validationDir 'VALIDATION-CONTRACT.json'
$coveragePath = Join-Path $validationDir 'REGRESSION-COVERAGE.json'
$mandatoryFiles = @('VERSION','SHA256SUMS.txt','Validation/VALIDATION-CONTRACT.json','Validation/REGRESSION-COVERAGE.json',$SelfTestEntryPoint)
$allRequiredFiles = @($mandatoryFiles + $RequiredFiles | Sort-Object -Unique)
$contract = [ordered]@{
    schemaVersion = '1.0'
    packageName = $PackageName
    packageVersion = $PackageVersion
    packageType = $PackageType
    selfTestEntryPoint = $SelfTestEntryPoint.Replace('\','/')
    selfTestArguments = @()
    regressionCoverageFile = 'Validation/REGRESSION-COVERAGE.json'
    allowRepositoryOperations = $false
    requiredFiles = @($allRequiredFiles | ForEach-Object { $_.Replace('\','/') })
    requiredRegressionIds = $allIds
    targetSystemAcceptanceRequired = [bool]$TargetSystemAcceptanceRequired
}
$coverage = [System.Collections.Generic.List[object]]::new()
foreach ($id in $allIds) {
    if ($id -in $NotApplicableRegressionIds) {
        $coverage.Add([ordered]@{ id=$id; status='notApplicable'; justification='Package builder must replace this generated justification with a concrete technical reason.' })
    } elseif ($id -in $universalIds) {
        $coverage.Add([ordered]@{ id=$id; status='covered'; method='Enforced by the installed KI-Stack Universal Package Validation Gate.' })
    } else {
        $coverage.Add([ordered]@{ id=$id; status='pending'; method='Package-specific regression test must be implemented before release.' })
    }
}
$coverageDocument = [ordered]@{
    schemaVersion='1.0'
    packageName=$PackageName
    packageVersion=$PackageVersion
    coverage=@($coverage)
}
[System.IO.File]::WriteAllText($contractPath, (($contract | ConvertTo-Json -Depth 50) + "`n"), [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($coveragePath, (($coverageDocument | ConvertTo-Json -Depth 50) + "`n"), [System.Text.UTF8Encoding]::new($false))
Write-Host "Validation Contract erstellt: $contractPath"
Write-Host "Regression Coverage erstellt: $coveragePath"
Write-Host 'Einträge mit status=pending müssen vor dem Paketbau durch covered oder notApplicable mit belastbarer Begründung ersetzt werden.'

[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$matrixPath = Join-Path $ProjectRoot 'Tests\HISTORICAL-REGRESSION-MATRIX.json'
$matrix = Get-Content -LiteralPath $matrixPath -Raw | ConvertFrom-Json -Depth 100
$entries = @($matrix.regressions)
if ($entries.Count -eq 0) {
    $entries = @($matrix.tests)
}
if ($entries.Count -eq 0) {
    throw 'Historical regression matrix contains no entries.'
}
$ids = @(
    $entries | ForEach-Object {
        if ($_.PSObject.Properties.Name -contains 'id') { [string]$_.id }
        elseif ($_.PSObject.Properties.Name -contains 'name') { [string]$_.name }
    }
)
if (@($ids | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    throw 'Historical regression matrix contains entries without identifiers.'
}
if (@($ids | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
    throw 'Historical regression matrix contains duplicate identifiers.'
}
[pscustomobject]@{
    passed=$true
    frozenRelease=[string]$matrix.release
    regressionCount=$entries.Count
    currentRuntime='1.6.14'
} | ConvertTo-Json -Depth 10

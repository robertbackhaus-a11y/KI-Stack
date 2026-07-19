[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedRoot = (Resolve-Path -LiteralPath $ProjectRoot -ErrorAction Stop).Path
$stateRoot = Join-Path $resolvedRoot 'State\Syntax'
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null

$syntaxFiles = @(
    Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -Force |
        Where-Object {
            $_.Extension -in @('.ps1', '.psm1') -and
            $_.FullName -notlike (Join-Path $resolvedRoot 'State\*')
        } |
        Sort-Object FullName
)

$results = [System.Collections.Generic.List[object]]::new()
foreach ($file in $syntaxFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )

    $relativePath = [IO.Path]::GetRelativePath($resolvedRoot, $file.FullName)
    if (@($parseErrors).Count -eq 0) {
        [void]$results.Add([pscustomobject][ordered]@{
            file = $relativePath
            passed = $true
            errors = @()
        })
        continue
    }

    $errors = @(
        foreach ($parseError in @($parseErrors)) {
            [pscustomobject][ordered]@{
                message = [string]$parseError.Message
                line = [int]$parseError.Extent.StartLineNumber
                column = [int]$parseError.Extent.StartColumnNumber
                text = [string]$parseError.Extent.Text
            }
        }
    )
    [void]$results.Add([pscustomobject][ordered]@{
        file = $relativePath
        passed = $false
        errors = $errors
    })
}

$failedResults = @($results | Where-Object { -not [bool]$_.passed })
$report = [pscustomobject][ordered]@{
    generatedAt = (Get-Date).ToString('o')
    parserVersion = $PSVersionTable.PSVersion.ToString()
    projectRoot = $resolvedRoot
    fileCount = $syntaxFiles.Count
    passed = ($failedResults.Count -eq 0)
    failedFiles = @($failedResults | ForEach-Object { [string]$_.file })
    results = @($results)
}
$json = $report | ConvertTo-Json -Depth 20
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$reportPath = Join-Path $stateRoot ("PowerShell-Syntax-{0}.json" -f $timestamp)
$latestPath = Join-Path $stateRoot 'PowerShell-Syntax-latest.json'
Set-Content -LiteralPath $reportPath -Value $json -Encoding UTF8
Set-Content -LiteralPath $latestPath -Value $json -Encoding UTF8

$json
Write-Host ("PowerShell-Syntaxbericht: {0}" -f $latestPath)
if ($failedResults.Count -gt 0) {
    Write-Host ''
    Write-Host 'POWERSHELL-SYNTAXFEHLER:' -ForegroundColor Red
    foreach ($failedResult in $failedResults) {
        foreach ($parseError in @($failedResult.errors)) {
            Write-Host (
                '- {0}:{1}:{2} -- {3}' -f
                $failedResult.file,
                $parseError.line,
                $parseError.column,
                $parseError.message
            ) -ForegroundColor Red
        }
    }
    exit 1
}
exit 0

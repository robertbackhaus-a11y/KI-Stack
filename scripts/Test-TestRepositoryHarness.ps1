[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$harness = Join-Path $RepositoryRoot 'scripts\Test-Repository.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('KIStack Repository Harness ' + [guid]::NewGuid().ToString('N'))
$results = [Collections.Generic.List[object]]::new()

function Invoke-HarnessCase {
    param([string]$Name,[string]$Root,[bool]$ExpectedPass,[string]$WorkingDirectory)
    $passed = $false
    $detail = ''
    Push-Location $WorkingDirectory
    try {
        try {
            $output = @(& $harness -RootPath $Root 2>&1)
            $passed = $true
            $detail = ($output -join [Environment]::NewLine)
        }
        catch {
            $detail = $_.Exception.Message
        }
    }
    finally {
        Pop-Location
    }
    $results.Add([pscustomobject]@{
        name=$Name
        expectedPass=$ExpectedPass
        actualPass=$passed
        passed=($passed -eq $ExpectedPass)
        root=$Root
        workingDirectory=$WorkingDirectory
        detail=$detail
    })
}

New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
try {
    $emptyRoot = Join-Path $fixtureRoot 'empty'
    $otherWorkingDirectory = Join-Path $fixtureRoot 'different working directory'
    $spaceRoot = Join-Path $fixtureRoot 'checkout with spaces'
    New-Item -ItemType Directory -Path $emptyRoot,$otherWorkingDirectory -Force | Out-Null
    New-Item -ItemType Junction -Path $spaceRoot -Target $RepositoryRoot | Out-Null

    Invoke-HarnessCase -Name 'valid checkout with files' -Root $RepositoryRoot -ExpectedPass $true -WorkingDirectory $RepositoryRoot
    Invoke-HarnessCase -Name 'empty or wrong RootPath fails' -Root $emptyRoot -ExpectedPass $false -WorkingDirectory $RepositoryRoot
    Invoke-HarnessCase -Name 'RootPath with spaces passes' -Root $spaceRoot -ExpectedPass $true -WorkingDirectory $RepositoryRoot
    Invoke-HarnessCase -Name 'different working directory passes' -Root $RepositoryRoot -ExpectedPass $true -WorkingDirectory $otherWorkingDirectory

    $failed = @($results | Where-Object { -not $_.passed })
    [pscustomobject]@{
        passed=($failed.Count -eq 0)
        cases=$results.Count
        results=@($results)
    } | ConvertTo-Json -Depth 20
    if ($failed.Count) { throw ('Repository harness regression failed: ' + (($failed | ForEach-Object name) -join ', ')) }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

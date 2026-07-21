[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptRoot 'Core\KIStack.ValidationGate.Core.psm1') -Force

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Write-CmdCrlfNoBom {
    param([string]$Path, [string]$Content)
    $normalized = ($Content -replace "`r?`n", "`r`n")
    [System.IO.File]::WriteAllText($Path, $normalized, [System.Text.ASCIIEncoding]::new())
}

function Update-FixtureManifest {
    param([string]$Root)
    $manifestPath = Join-Path $Root 'SHA256SUMS.txt'
    $lines = [System.Collections.Generic.List[string]]::new()
    Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.FullName -ne $manifestPath } | Sort-Object FullName | ForEach-Object {
        $rel = [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines.Add("$hash *$rel")
    }
    Write-Utf8NoBom -Path $manifestPath -Content (($lines -join "`n") + "`n")
}

function New-FixtureFolder {
    param([string]$Parent, [string]$Name = 'Fixture-v1.0.0')
    $root = Join-Path $Parent $Name
    New-Item -ItemType Directory -Path (Join-Path $root 'Validation') -Force | Out-Null
    Write-Utf8NoBom -Path (Join-Path $root 'VERSION') -Content "1.0.0`n"
    Write-Utf8NoBom -Path (Join-Path $root 'data.json') -Content ((([ordered]@{ valid = $true }) | ConvertTo-Json) + "`n")
    Write-Utf8NoBom -Path (Join-Path $root 'Test-Fixture.ps1') -Content "Set-StrictMode -Version Latest`nexit 0`n"
    $cmdContent = @'
@echo off
setlocal
set "ROOT=%~dp0"
exit /b 0
'@
    Write-CmdCrlfNoBom -Path (Join-Path $root 'Start-Fixture.cmd') -Content $cmdContent
    $contract = [ordered]@{
        schemaVersion = '1.0'
        packageName = 'Fixture'
        packageVersion = '1.0.0'
        packageType = 'Generic'
        selfTestEntryPoint = 'Test-Fixture.ps1'
        selfTestArguments = @()
        regressionCoverageFile = 'Validation/REGRESSION-COVERAGE.json'
        allowRepositoryOperations = $false
        requiredFiles = @('VERSION','SHA256SUMS.txt','Validation/VALIDATION-CONTRACT.json','Validation/REGRESSION-COVERAGE.json','Test-Fixture.ps1','Start-Fixture.cmd','data.json')
        requiredRegressionIds = @('REG-015-FINAL-ZIP-NOT-WORKDIR','REG-016-ZIP-PATH-SECURITY','REG-017-EXACT-MANIFEST-SET')
        targetSystemAcceptanceRequired = $false
    }
    Write-Utf8NoBom -Path (Join-Path $root 'Validation\VALIDATION-CONTRACT.json') -Content (($contract | ConvertTo-Json -Depth 20) + "`n")
    $coverage = [ordered]@{
        schemaVersion = '1.0'
        packageName = 'Fixture'
        packageVersion = '1.0.0'
        coverage = @(
            [ordered]@{ id='REG-015-FINAL-ZIP-NOT-WORKDIR'; status='covered'; method='Fixture final ZIP is validated after fresh extraction.' },
            [ordered]@{ id='REG-016-ZIP-PATH-SECURITY'; status='covered'; method='Universal gate path validation.' },
            [ordered]@{ id='REG-017-EXACT-MANIFEST-SET'; status='covered'; method='Universal gate exact manifest validation.' }
        )
    }
    Write-Utf8NoBom -Path (Join-Path $root 'Validation\REGRESSION-COVERAGE.json') -Content (($coverage | ConvertTo-Json -Depth 20) + "`n")
    Update-FixtureManifest -Root $root
    return $root
}

function New-FixtureZip {
    param([string]$Root, [string]$ZipPath)
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    Compress-Archive -LiteralPath $Root -DestinationPath $ZipPath -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8NoBom -Path "$ZipPath.sha256" -Content "$hash *$([System.IO.Path]::GetFileName($ZipPath))`n"
}

function Invoke-GateExpected {
    param(
        [string]$Pwsh,
        [string]$ZipPath,
        [bool]$ExpectedSuccess,
        [string]$Name
    )
    $outDir = Join-Path (Split-Path -Parent $ZipPath) 'reports'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    & $Pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $scriptRoot 'Invoke-KIStack-PackageValidationGate.ps1') `
        -PackagePath $ZipPath -OutputDirectory $outDir *> (Join-Path $outDir ($Name + '.console.txt'))
    $success = $LASTEXITCODE -eq 0
    return [pscustomobject]@{
        name = $Name
        passed = ($success -eq $ExpectedSuccess)
        detail = "ExpectedSuccess=$ExpectedSuccess; ActualSuccess=$success; ExitCode=$LASTEXITCODE"
    }
}

function New-UnsafeZip {
    param([string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = [System.IO.File]::Create($ZipPath)
    $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        $entry = $archive.CreateEntry('Unsafe-v1.0.0/../escape.txt')
        $writer = [System.IO.StreamWriter]::new($entry.Open(), [System.Text.UTF8Encoding]::new($false))
        try { $writer.Write('unsafe') } finally { $writer.Dispose() }
    } finally {
        $archive.Dispose()
        $stream.Dispose()
    }
    $hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8NoBom -Path "$ZipPath.sha256" -Content "$hash *$([System.IO.Path]::GetFileName($ZipPath))`n"
}


function Get-PackageSnapshot {
    param([Parameter(Mandatory)][string]$Root)
    $snapshot = @{}
    Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName | ForEach-Object {
        $rel = [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\','/')
        $snapshot[$rel] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $snapshot
}

function Compare-PackageSnapshots {
    param(
        [Parameter(Mandatory)][hashtable]$Before,
        [Parameter(Mandatory)][hashtable]$After,
        [Parameter(Mandatory)][string]$Name
    )
    $missing = @($Before.Keys | Where-Object { -not $After.ContainsKey($_) } | Sort-Object)
    $extra = @($After.Keys | Where-Object { -not $Before.ContainsKey($_) } | Sort-Object)
    $drift = @($Before.Keys | Where-Object { $After.ContainsKey($_) -and $After[$_] -ne $Before[$_] } | Sort-Object)
    return [pscustomobject]@{
        name = $Name
        passed = ($missing.Count -eq 0 -and $extra.Count -eq 0 -and $drift.Count -eq 0)
        detail = "missing=$($missing -join ','); extra=$($extra -join ','); drift=$($drift -join ',')"
    }
}

function Test-GateExactManifest {
    param([Parameter(Mandatory)][string]$Root)
    $manifestPath = Join-Path $Root 'SHA256SUMS.txt'
    $expected = @{}
    $formatErrors = [System.Collections.Generic.List[string]]::new()
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $manifestPath) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*(.+)$') {
            $formatErrors.Add("line $lineNumber")
            continue
        }
        $rel = $Matches[2].Replace('\','/')
        if ($expected.ContainsKey($rel)) {
            $formatErrors.Add("duplicate $rel")
            continue
        }
        $expected[$rel] = $Matches[1].ToLowerInvariant()
    }
    $actualFiles = Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.FullName -ne $manifestPath }
    $actualRel = @($actualFiles | ForEach-Object { [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\','/') })
    $missing = @($expected.Keys | Where-Object { $_ -notin $actualRel } | Sort-Object)
    $extra = @($actualRel | Where-Object { $_ -notin $expected.Keys } | Sort-Object)
    $drift = @($expected.Keys | Where-Object {
        $p = Join-Path $Root $_
        (Test-Path -LiteralPath $p -PathType Leaf) -and ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected[$_])
    } | Sort-Object)
    return [pscustomobject]@{
        name = 'Gate package exact manifest'
        passed = ($formatErrors.Count -eq 0 -and $missing.Count -eq 0 -and $extra.Count -eq 0 -and $drift.Count -eq 0)
        detail = "format=$($formatErrors -join ','); missing=$($missing -join ','); extra=$($extra -join ','); drift=$($drift -join ',')"
    }
}

$results = [System.Collections.Generic.List[object]]::new()
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("KIStack-Gate-SelfTest-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null

try {
    $pwsh = Resolve-KIStackPwsh7
    $python = Resolve-KIStackPython

    # Trust boundary: validate the delivered extracted package before executing its tests.
    $initialSnapshot = Get-PackageSnapshot -Root $scriptRoot
    $results.Add((Test-GateExactManifest -Root $scriptRoot))
    if (-not $results[$results.Count - 1].passed) {
        throw "Gate-Paketintegrität vor Testausführung fehlgeschlagen: $($results[$results.Count - 1].detail)"
    }

    # Execute Python tests only from an isolated copy. The delivered package must remain immutable.
    $pythonUnitRoot = Join-Path $temp 'python-unit'
    New-Item -ItemType Directory -Path (Join-Path $pythonUnitRoot 'Tests') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $pythonUnitRoot 'Tools') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $scriptRoot 'Tests\test_validate_package.py') -Destination (Join-Path $pythonUnitRoot 'Tests\test_validate_package.py') -Force
    Copy-Item -LiteralPath (Join-Path $scriptRoot 'Tools\validate_package.py') -Destination (Join-Path $pythonUnitRoot 'Tools\validate_package.py') -Force

    $previousDontWriteBytecode = $env:PYTHONDONTWRITEBYTECODE
    try {
        $env:PYTHONDONTWRITEBYTECODE = '1'
        & $python.Path @($python.PrefixArgs) -B -m unittest discover -s (Join-Path $pythonUnitRoot 'Tests') -p 'test_validate_package.py'
        $pythonTestExit = $LASTEXITCODE
    }
    finally {
        if ($null -eq $previousDontWriteBytecode) {
            Remove-Item Env:PYTHONDONTWRITEBYTECODE -ErrorAction SilentlyContinue
        }
        else {
            $env:PYTHONDONTWRITEBYTECODE = $previousDontWriteBytecode
        }
    }
    $results.Add([pscustomobject]@{ name='Independent Python validator unit tests in isolated copy'; passed=($pythonTestExit -eq 0); detail="ExitCode=$pythonTestExit; Root=$pythonUnitRoot" })

    $postPythonSnapshot = Get-PackageSnapshot -Root $scriptRoot
    $results.Add((Compare-PackageSnapshots -Before $initialSnapshot -After $postPythonSnapshot -Name 'Python tests leave delivered gate package byte-identical'))
    $postManifest = Test-GateExactManifest -Root $scriptRoot
    $postManifest.name = 'Gate package exact manifest after Python tests'
    $results.Add($postManifest)
    $validParent = Join-Path $temp 'Nested Path With Spaces\Fixture-v1.0.0'
    New-Item -ItemType Directory -Path $validParent -Force | Out-Null
    $validRoot = New-FixtureFolder -Parent $validParent
    $validZip = Join-Path $validParent 'Fixture-v1.0.0.zip'
    New-FixtureZip -Root $validRoot -ZipPath $validZip
    $results.Add((Invoke-GateExpected -Pwsh $pwsh -ZipPath $validZip -ExpectedSuccess $true -Name 'Valid final ZIP accepted from nested path with spaces'))

    $extraParent = Join-Path $temp 'extra'
    New-Item -ItemType Directory -Path $extraParent -Force | Out-Null
    $extraRoot = New-FixtureFolder -Parent $extraParent
    Write-Utf8NoBom -Path (Join-Path $extraRoot 'extra.txt') -Content "extra`n"
    $extraZip = Join-Path $extraParent 'extra.zip'
    New-FixtureZip -Root $extraRoot -ZipPath $extraZip
    $results.Add((Invoke-GateExpected -Pwsh $pwsh -ZipPath $extraZip -ExpectedSuccess $false -Name 'Unexpected file rejected'))

    $missingParent = Join-Path $temp 'missing'
    New-Item -ItemType Directory -Path $missingParent -Force | Out-Null
    $missingRoot = New-FixtureFolder -Parent $missingParent
    Remove-Item -LiteralPath (Join-Path $missingRoot 'data.json') -Force
    $missingZip = Join-Path $missingParent 'missing.zip'
    New-FixtureZip -Root $missingRoot -ZipPath $missingZip
    $results.Add((Invoke-GateExpected -Pwsh $pwsh -ZipPath $missingZip -ExpectedSuccess $false -Name 'Missing file rejected'))

    $driftParent = Join-Path $temp 'drift'
    New-Item -ItemType Directory -Path $driftParent -Force | Out-Null
    $driftRoot = New-FixtureFolder -Parent $driftParent
    Write-Utf8NoBom -Path (Join-Path $driftRoot 'data.json') -Content ((([ordered]@{ valid = $false }) | ConvertTo-Json) + "`n")
    $driftZip = Join-Path $driftParent 'drift.zip'
    New-FixtureZip -Root $driftRoot -ZipPath $driftZip
    $results.Add((Invoke-GateExpected -Pwsh $pwsh -ZipPath $driftZip -ExpectedSuccess $false -Name 'Hash drift rejected'))

    $unsafeParent = Join-Path $temp 'unsafe'
    New-Item -ItemType Directory -Path $unsafeParent -Force | Out-Null
    $unsafeZip = Join-Path $unsafeParent 'unsafe.zip'
    New-UnsafeZip -ZipPath $unsafeZip
    $results.Add((Invoke-GateExpected -Pwsh $pwsh -ZipPath $unsafeZip -ExpectedSuccess $false -Name 'ZIP traversal rejected'))

    $gitParent = Join-Path $temp 'git-command'
    New-Item -ItemType Directory -Path $gitParent -Force | Out-Null
    $gitRoot = New-FixtureFolder -Parent $gitParent
    $gitText = 'Set-StrictMode -Version Latest' + "`n" + ('g' + 'it status') + "`nexit 0`n"
    Write-Utf8NoBom -Path (Join-Path $gitRoot 'Test-Fixture.ps1') -Content $gitText
    Update-FixtureManifest -Root $gitRoot
    $gitZip = Join-Path $gitParent 'git-command.zip'
    New-FixtureZip -Root $gitRoot -ZipPath $gitZip
    $results.Add((Invoke-GateExpected -Pwsh $pwsh -ZipPath $gitZip -ExpectedSuccess $false -Name 'Actual repository command rejected by AST'))

    $keyParent = Join-Path $temp 'hashtable-key'
    New-Item -ItemType Directory -Path $keyParent -Force | Out-Null
    $keyRoot = New-FixtureFolder -Parent $keyParent
    $badKey = '$expected.' + 'Key'
    Write-Utf8NoBom -Path (Join-Path $keyRoot 'Test-Fixture.ps1') -Content "Set-StrictMode -Version Latest`n`$expected=@{a=1}`n`$null=$badKey`nexit 0`n"
    Update-FixtureManifest -Root $keyRoot
    $keyZip = Join-Path $keyParent 'hashtable-key.zip'
    New-FixtureZip -Root $keyRoot -ZipPath $keyZip
    $results.Add((Invoke-GateExpected -Pwsh $pwsh -ZipPath $keyZip -ExpectedSuccess $false -Name 'Historical hashtable Key regression rejected'))

    $failed = @($results | Where-Object { -not $_.passed })
    $report = [pscustomobject]@{
        schemaVersion='1.0'
        testedAtUtc=[DateTime]::UtcNow.ToString('o')
        passed=($failed.Count -eq 0)
        checks=@($results)
        failed=$failed
    }
    $report | ConvertTo-Json -Depth 20 | Write-Host
    if ($failed.Count -gt 0) { exit 1 }
    exit 0
}
catch {
    [pscustomobject]@{
        schemaVersion='1.0'
        testedAtUtc=[DateTime]::UtcNow.ToString('o')
        passed=$false
        checks=@($results)
        failed=@('Unhandled exception')
        error=$_.Exception.Message
    } | ConvertTo-Json -Depth 20 | Write-Host
    exit 1
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

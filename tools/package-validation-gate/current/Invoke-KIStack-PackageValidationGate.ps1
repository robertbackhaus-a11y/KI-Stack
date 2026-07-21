[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$PackagePath,

    [Parameter()]
    [string]$OutputDirectory,

    [Parameter()]
    [ValidateRange(30, 7200)]
    [int]$SelfTestTimeoutSeconds = 1200,

    [Parameter()]
    [switch]$StaticOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptRoot 'Core\KIStack.ValidationGate.Core.psm1') -Force

$packageFull = (Resolve-Path -LiteralPath $PackagePath).Path
if (-not (Test-Path -LiteralPath $packageFull -PathType Leaf) -or [System.IO.Path]::GetExtension($packageFull) -ne '.zip') {
    throw "Paket ist kein vorhandenes ZIP: $PackagePath"
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Split-Path -Parent $packageFull
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$outputFull = (Resolve-Path -LiteralPath $OutputDirectory).Path
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($packageFull)
$jsonReportPath = Join-Path $outputFull "$baseName.VALIDATION-REPORT.json"
$markdownReportPath = Join-Path $outputFull "$baseName.VALIDATION-REPORT.md"
$staticReportPath = Join-Path $outputFull "$baseName.STATIC-VALIDATION.json"

$checks = [System.Collections.Generic.List[object]]::new()
$notExecuted = [System.Collections.Generic.List[string]]::new()
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("KIStack-ValidationGate-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $python = Resolve-KIStackPython
    $pythonStdOut = Join-Path $tempRoot 'python-validator.stdout.txt'
    $pythonStdErr = Join-Path $tempRoot 'python-validator.stderr.txt'
    $pythonArgs = @($python.PrefixArgs) + @(
        (Join-Path $scriptRoot 'Tools\validate_package.py'),
        '--package', $packageFull,
        '--output', $staticReportPath,
        '--release-mode'
    )
    $pythonResult = Invoke-KIStackProcess -FilePath $python.Path -ArgumentList $pythonArgs -WorkingDirectory $scriptRoot `
        -StdOutPath $pythonStdOut -StdErrPath $pythonStdErr -TimeoutSeconds 1800

    if (-not (Test-Path -LiteralPath $staticReportPath -PathType Leaf)) {
        throw "Unabhängiger Validator hat keinen Bericht erzeugt. STDERR=$($pythonResult.StdErr)"
    }
    $staticReport = Get-Content -LiteralPath $staticReportPath -Raw | ConvertFrom-Json -Depth 100
    foreach ($check in $staticReport.checks) {
        $checks.Add([pscustomobject]@{ name = "Static: $($check.name)"; passed = [bool]$check.passed; detail = [string]$check.detail })
    }
    if ($pythonResult.ExitCode -ne 0 -or -not $staticReport.passed) {
        throw "Unabhängige statische Paketprüfung fehlgeschlagen. Bericht: $staticReportPath"
    }

    $extractPath = Join-Path $tempRoot 'package'
    Expand-KIStackZipSafely -ZipPath $packageFull -DestinationPath $extractPath
    $packageRoot = Get-KIStackPackageRoot -ExtractedPath $extractPath

    $contractCandidates = @(
        (Join-Path $packageRoot 'Validation\VALIDATION-CONTRACT.json'),
        (Join-Path $packageRoot 'Contract\VALIDATION-CONTRACT.json')
    )
    $contractPath = $contractCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $contractPath) { throw 'VALIDATION-CONTRACT.json fehlt.' }
    $contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json -Depth 100

    if ($StaticOnly) {
        $notExecuted.Add('Native PowerShell AST validation was disabled by -StaticOnly.')
        $notExecuted.Add('Package self-test was disabled by -StaticOnly.')
    } else {
        $pwsh = Resolve-KIStackPwsh7
        $forbiddenCommands = @('git', 'git.exe', 'checkout', 'clone')
        $psChecks = Test-KIStackPowerShellFiles -RootPath $packageRoot -ForbiddenCommands $forbiddenCommands
        foreach ($check in $psChecks) { $checks.Add($check) }
        if (@($psChecks | Where-Object { -not $_.passed }).Count -gt 0) {
            throw 'Native PowerShell Parser-/AST-Prüfung fehlgeschlagen.'
        }

        $selfTestRel = [string]$contract.selfTestEntryPoint
        $selfTestPath = Join-Path $packageRoot $selfTestRel
        if (-not (Test-Path -LiteralPath $selfTestPath -PathType Leaf)) {
            throw "Selbsttest fehlt: $selfTestRel"
        }
        $selfTestArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $selfTestPath)
        if ($contract.PSObject.Properties.Name -contains 'selfTestArguments') {
            foreach ($argument in @($contract.selfTestArguments)) { $selfTestArgs += [string]$argument }
        }
        $selfTestStdOut = Join-Path $tempRoot 'package-selftest.stdout.txt'
        $selfTestStdErr = Join-Path $tempRoot 'package-selftest.stderr.txt'
        $selfTestResult = Invoke-KIStackProcess -FilePath $pwsh -ArgumentList $selfTestArgs -WorkingDirectory $packageRoot `
            -StdOutPath $selfTestStdOut -StdErrPath $selfTestStdErr -TimeoutSeconds $SelfTestTimeoutSeconds
        $selfTestPassed = $selfTestResult.ExitCode -eq 0
        $checks.Add([pscustomobject]@{
            name = 'Final extracted package self-test'
            passed = $selfTestPassed
            detail = "ExitCode=$($selfTestResult.ExitCode); STDOUT=$($selfTestResult.StdOut.Trim()); STDERR=$($selfTestResult.StdErr.Trim())"
        })
        if (-not $selfTestPassed) { throw 'Selbsttest des final entpackten Pakets fehlgeschlagen.' }
    }

    $failed = @($checks | Where-Object { -not $_.passed })
    $nativeExecuted = -not $StaticOnly
    $status = if ($failed.Count -gt 0) {
        'REJECTED'
    } elseif ($nativeExecuted) {
        'NATIVE_PACKAGE_VALIDATION_PASSED'
    } else {
        'STATIC_VALIDATION_PASSED'
    }

    $report = [pscustomobject]@{
        schemaVersion = '1.0'
        gateVersion = (Get-Content -LiteralPath (Join-Path $scriptRoot 'VERSION') -Raw).Trim()
        testedAtUtc = [DateTime]::UtcNow.ToString('o')
        packageName = [System.IO.Path]::GetFileName($packageFull)
        packagePath = $packageFull
        sha256 = (Get-FileHash -LiteralPath $packageFull -Algorithm SHA256).Hash.ToLowerInvariant()
        status = $status
        passed = ($failed.Count -eq 0)
        nativePowerShellValidationExecuted = $nativeExecuted
        packageSelfTestExecuted = $nativeExecuted
        finalZipValidated = $true
        validationContract = $contract
        checks = @($checks)
        failed = $failed
        notExecuted = @($notExecuted)
        staticValidationReport = $staticReportPath
    }
    $report | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonReportPath -Encoding utf8NoBOM
    ConvertTo-KIStackMarkdownReport -Report $report | Set-Content -LiteralPath $markdownReportPath -Encoding utf8NoBOM

    Write-Host ""
    Write-Host "KI-Stack Package Validation Gate: $status"
    Write-Host "JSON: $jsonReportPath"
    Write-Host "Markdown: $markdownReportPath"
    if ($failed.Count -gt 0) { exit 1 }
    exit 0
}
catch {
    $message = $_.Exception.Message
    $checks.Add([pscustomobject]@{ name = 'Unhandled exception'; passed = $false; detail = $message })
    $report = [pscustomobject]@{
        schemaVersion = '1.0'
        gateVersion = (Get-Content -LiteralPath (Join-Path $scriptRoot 'VERSION') -Raw).Trim()
        testedAtUtc = [DateTime]::UtcNow.ToString('o')
        packageName = [System.IO.Path]::GetFileName($packageFull)
        packagePath = $packageFull
        sha256 = (Get-FileHash -LiteralPath $packageFull -Algorithm SHA256).Hash.ToLowerInvariant()
        status = 'REJECTED'
        passed = $false
        nativePowerShellValidationExecuted = (-not $StaticOnly)
        packageSelfTestExecuted = $false
        finalZipValidated = $true
        checks = @($checks)
        failed = @($checks | Where-Object { -not $_.passed })
        notExecuted = @($notExecuted)
        error = $message
    }
    $report | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonReportPath -Encoding utf8NoBOM
    ConvertTo-KIStackMarkdownReport -Report $report | Set-Content -LiteralPath $markdownReportPath -Encoding utf8NoBOM
    Write-Error "Paketvalidierung fehlgeschlagen: $message"
    exit 1
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

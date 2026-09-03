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

    # Exit-code contract regression (real, reproduced CI defect: PR #52 / GitHub Actions run
    # 33429046880, job 99609623579 -- Test-Repository.ps1 printed passed=true/37/37 and the step
    # still failed with "Process completed with exit code 1"). Every case above invokes the
    # harness via the call operator (&), i.e. in-process, in the SAME pwsh.exe session -- that
    # invocation shape can never observe this bug class at all, because it never looks at
    # $LASTEXITCODE or the process's own exit code, only at whether an exception was thrown. The
    # real defect only exists for the OTHER invocation shape this script actually runs under in
    # production: GitHub Actions' own "shell: pwsh" step, which does NOT simply run
    # "pwsh -File <script>" -- empirically confirmed (three independent methods: bare -File,
    # Start-Process -File, and a plain ". 'script'" dot-source via -Command all leave the child
    # process's own exit code at 0 despite a stale non-zero $LASTEXITCODE) that a plain
    # PowerShell invocation never propagates a leftover native exit code into the process's own
    # exit code at all. GitHub Actions' pwsh shell appends one specific extra statement after
    # dot-sourcing the step's script -- "if ((Test-Path -LiteralPath variable:\LASTEXITCODE))
    # { exit $LASTEXITCODE }" -- and ONLY that exact, documented wrapper shape reproduces the
    # real, reported defect (verified the same way: reproduces exit code 1 for the unfixed
    # pattern, exit code 0 once the reset is applied). Reproducing anything less than this exact
    # shape would silently fail to test the real bug at all, so this helper builds the identical
    # command GitHub Actions itself runs.
    function Invoke-KIStackChildProcessScript {
        param([Parameter(Mandatory)][string]$ScriptPath, [string]$ScriptArgumentsLiteral = '')
        $dotSourceCommand = ". '$ScriptPath'"
        if ($ScriptArgumentsLiteral) { $dotSourceCommand += " $ScriptArgumentsLiteral" }
        $fullCommand = $dotSourceCommand + '; if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit $LASTEXITCODE }'
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = (Get-Process -Id $PID).Path
        foreach ($a in @('-NoProfile','-NoLogo','-Command',$fullCommand)) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        [pscustomobject]@{ exitCode = $process.ExitCode; stdout = $stdout; stderr = $stderr }
    }

    $exitCodeFixtureRoot = Join-Path $fixtureRoot 'exit-code-contract'
    New-Item -ItemType Directory -Path $exitCodeFixtureRoot -Force | Out-Null
    $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'

    # Mirrors the exact, real fix in scripts/Test-Repository.ps1: a native command leaves a
    # non-zero $LASTEXITCODE behind (exactly like gh release list failing gracefully inside
    # Get-KIStackLatestPublishedCompleteInstallerRelease), the script's own logical result is
    # still success, and the fix explicitly clears $LASTEXITCODE before falling off the end.
    $fixedPatternScript = Join-Path $exitCodeFixtureRoot 'fixed-pattern.ps1'
    Set-Content -LiteralPath $fixedPatternScript -Encoding utf8 -Value @(
        "& '$cmdExe' /c `"exit 1`" | Out-Null"
        "Write-Output '{`"passed`":true}'"
        '$global:LASTEXITCODE = 0'
        'return'
    )

    # Negative control: the identical scenario WITHOUT the reset -- i.e. the exact shape of the
    # real, reported defect. This must fail (process exit code 1) to prove the harness actually
    # detects the regression rather than passing unconditionally.
    $regressedPatternScript = Join-Path $exitCodeFixtureRoot 'regressed-pattern.ps1'
    Set-Content -LiteralPath $regressedPatternScript -Encoding utf8 -Value @(
        "& '$cmdExe' /c `"exit 1`" | Out-Null"
        "Write-Output '{`"passed`":true}'"
        'return'
    )

    $fixedResult = Invoke-KIStackChildProcessScript -ScriptPath $fixedPatternScript
    $results.Add([pscustomobject]@{
        name = 'exit code contract: internally-handled native exit code 1 does not leak into the process exit code'
        expectedPass = $true
        actualPass = ($fixedResult.exitCode -eq 0)
        passed = ($fixedResult.exitCode -eq 0)
        root = $fixedPatternScript
        workingDirectory = $exitCodeFixtureRoot
        detail = "processExitCode=$($fixedResult.exitCode) (expected 0); stdout=$($fixedResult.stdout.Trim())"
    })

    $regressedResult = Invoke-KIStackChildProcessScript -ScriptPath $regressedPatternScript
    $results.Add([pscustomobject]@{
        name = 'exit code contract negative control: without the reset, the same stale native exit code 1 genuinely leaks'
        expectedPass = $true
        actualPass = ($regressedResult.exitCode -eq 1)
        passed = ($regressedResult.exitCode -eq 1)
        root = $regressedPatternScript
        workingDirectory = $exitCodeFixtureRoot
        detail = "processExitCode=$($regressedResult.exitCode) (expected 1, proving the leak mechanism is real and that this test can actually catch a reintroduced regression); stdout=$($regressedResult.stdout.Trim())"
    })

    # Real, direct proof: run the ACTUAL scripts/Test-Repository.ps1 as a genuine separate
    # process against the real repository -- the exact invocation shape GitHub Actions uses.
    # Whether the real "gh" CLI call inside Test-KIStackComponentVersionRegistry.ps1 happens to
    # succeed or gracefully fail in this environment (depends on local gh auth/network) is
    # irrelevant to this assertion: whenever the script's own reported result is passed=true,
    # the real process exit code must be exactly 0, full stop.
    $realResult = Invoke-KIStackChildProcessScript -ScriptPath $harness -ScriptArgumentsLiteral "-RootPath '$RepositoryRoot'"
    $realReport = $null
    try { $realReport = ($realResult.stdout | ConvertFrom-Json -Depth 20) } catch { }
    $realReportedPassed = ($null -ne $realReport -and [bool]$realReport.passed)
    $results.Add([pscustomobject]@{
        name = 'exit code contract, real script: scripts/Test-Repository.ps1 as a genuine separate process against the real repository'
        expectedPass = $true
        actualPass = ($realReportedPassed -and $realResult.exitCode -eq 0)
        passed = ($realReportedPassed -and $realResult.exitCode -eq 0)
        root = $RepositoryRoot
        workingDirectory = $RepositoryRoot
        detail = "reportedPassed=$realReportedPassed; processExitCode=$($realResult.exitCode) (must be 0 whenever reportedPassed is true, regardless of local gh CLI auth/network state)"
    })

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

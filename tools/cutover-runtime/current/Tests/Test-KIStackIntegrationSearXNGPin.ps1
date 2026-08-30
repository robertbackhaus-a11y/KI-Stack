[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$expectedRef = '277d8469cdd4af423a42783ad426e0de09f4e2e9'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('KIStack-SearXNG-Pin-' + [guid]::NewGuid().ToString('N'))

function Invoke-GitChecked {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string[]]$Arguments)
    $output = @(& git.exe -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE`: $($output -join ' | ')"
    }
}

try {
    $config = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Config\kernel-config.json') -Raw | ConvertFrom-Json -Depth 100
    $installer = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Integration\Linux\install-ki-stack-searxng.sh') -Raw
    if ([string]$config.integration.searxngRef -cne $expectedRef) { throw 'Kernel config does not contain the full pinned SearXNG commit.' }
    if ([string]$config.integration.searxngRefType -cne 'commit') { throw 'SearXNG ref type is not commit.' }
    if ($installer -notmatch [regex]::Escape($expectedRef)) { throw 'Linux installer fallback does not contain the full pinned SearXNG commit.' }
    if ($installer -notmatch 'exakt 40 hexadezimale Zeichen') { throw 'Linux installer does not reject abbreviated or malformed commit pins.' }

    $source = Join-Path $fixtureRoot 'source'
    $remote = Join-Path $fixtureRoot 'remote.git'
    $validWork = Join-Path $fixtureRoot 'valid-work'
    $invalidWork = Join-Path $fixtureRoot 'invalid-work'
    New-Item -ItemType Directory -Path $source,$validWork,$invalidWork -Force | Out-Null
    Invoke-GitChecked -Root $source -Arguments @('init','--quiet')
    Invoke-GitChecked -Root $source -Arguments @('config','user.name','KI-Stack Test')
    Invoke-GitChecked -Root $source -Arguments @('config','user.email','ki-stack-test@example.invalid')
    [IO.File]::WriteAllText((Join-Path $source 'README.md'),"fixture`n",[Text.UTF8Encoding]::new($false))
    Invoke-GitChecked -Root $source -Arguments @('add','README.md')
    Invoke-GitChecked -Root $source -Arguments @('commit','--quiet','-m','fixture')
    $fixtureRef = (& git.exe -C $source rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $fixtureRef -notmatch '^[0-9a-f]{40}$') { throw 'Fixture commit could not be resolved.' }
    & git.exe clone --bare --quiet $source $remote 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Fixture bare remote could not be created.' }

    Invoke-GitChecked -Root $validWork -Arguments @('init','--quiet')
    Invoke-GitChecked -Root $validWork -Arguments @('remote','add','origin',$remote)
    Invoke-GitChecked -Root $validWork -Arguments @('fetch','--depth','1','origin',$fixtureRef)
    Invoke-GitChecked -Root $validWork -Arguments @('checkout','--quiet','--detach','FETCH_HEAD')
    $resolved = (& git.exe -C $validWork rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $resolved -cne $fixtureRef) { throw 'A valid full commit pin was not checked out exactly.' }

    Invoke-GitChecked -Root $invalidWork -Arguments @('init','--quiet')
    Invoke-GitChecked -Root $invalidWork -Arguments @('remote','add','origin',$remote)
    $invalidOutput = @(& git.exe -C $invalidWork fetch --depth 1 origin ('0' * 40) 2>&1)
    $invalidExitCode = $LASTEXITCODE
    if ($invalidExitCode -eq 0) { throw 'An invalid commit pin was unexpectedly accepted.' }

    # Execute the installer's *actual* pin-validation logic (not a re-implementation of it)
    # against a real, git-produced 40-char lowercase hex commit. This is what would have
    # caught the off-by-one character-class bug: the old check only confirmed the ref
    # string and error message text were present in the source, never that the guard
    # itself accepted a genuine 40-char pin.
    $validationMatch = [regex]::Match($installer, '(?s)if \[\[ ! "\$REF".*?\nfi')
    if (-not $validationMatch.Success) { throw 'SearXNG ref validation block not found in installer.' }
    # bash.exe on PATH can resolve to the WSL launcher stub, which requires
    # /mnt/c-style paths rather than Windows paths. Derive Git for Windows'
    # own bash.exe (which accepts Windows paths directly) from git.exe --
    # by walking upward from wherever git.exe actually resolved to, not by
    # assuming a fixed number of parent directories. Git for Windows ships
    # more than one real, PATH-resolvable git.exe (cmd\git.exe and
    # mingw64\bin\git.exe live at different depths under the same install
    # root), and which one Get-Command returns depends on the calling
    # process's own PATH order -- e.g. a shell launched from within Git
    # Bash itself puts mingw64\bin ahead of cmd, so a "go up exactly two
    # levels" assumption silently computes mingw64\usr\bin\bash.exe (which
    # does not exist) instead of the real <GitRoot>\usr\bin\bash.exe.
    $gitExeDirectory = Split-Path -Parent (Get-Command git.exe -ErrorAction Stop).Source
    $bashExe = $null
    $candidateDirectory = $gitExeDirectory
    for ($depth = 0; $depth -lt 5 -and -not $bashExe; $depth++) {
        $probe = Join-Path $candidateDirectory 'usr\bin\bash.exe'
        if (Test-Path -LiteralPath $probe -PathType Leaf) { $bashExe = $probe }
        $parentDirectory = Split-Path -Parent $candidateDirectory
        if ([string]::IsNullOrEmpty($parentDirectory) -or $parentDirectory -eq $candidateDirectory) { break }
        $candidateDirectory = $parentDirectory
    }
    if (-not $bashExe) { throw "Git for Windows bash.exe could not be located by walking up from git.exe's resolved path: $gitExeDirectory" }
    $harnessPath = Join-Path $fixtureRoot 'validate-ref.sh'
    $harnessBody = "#!/usr/bin/env bash`nset -Eeuo pipefail`nREF=`"`$1`"`n" + $validationMatch.Value + "`necho VALIDATION_PASSED`n"
    [IO.File]::WriteAllText($harnessPath,$harnessBody,[Text.UTF8Encoding]::new($false))

    $harnessPathForBash = $harnessPath.Replace('\','/')
    $acceptedOutput = @(& $bashExe $harnessPathForBash $fixtureRef 2>&1)
    $acceptedExitCode = $LASTEXITCODE
    if ($acceptedExitCode -ne 0 -or ($acceptedOutput -notcontains 'VALIDATION_PASSED')) {
        throw "A real, valid 40-char lowercase hex pin was rejected by the installer's own validation: exitCode=$acceptedExitCode; output=$($acceptedOutput -join ' | ')"
    }

    $rejectedOutput = @(& $bashExe $harnessPathForBash ($fixtureRef.Substring(0,39)) 2>&1)
    $rejectedExitCode = $LASTEXITCODE
    if ($rejectedExitCode -ne 56 -or ($rejectedOutput -contains 'VALIDATION_PASSED')) {
        throw "A 39-char pin was unexpectedly accepted by the installer's own validation: exitCode=$rejectedExitCode; output=$($rejectedOutput -join ' | ')"
    }

    [pscustomobject][ordered]@{
        passed = $true
        configuredRef = $expectedRef
        validPinResolvedAndCheckedOut = $true
        invalidPinFailedDeterministically = $true
        invalidExitCode = $invalidExitCode
        realValidatorAcceptsGenuineFortyCharPin = $true
        realValidatorRejectsThirtyNineCharPin = $true
    } | ConvertTo-Json -Compress
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

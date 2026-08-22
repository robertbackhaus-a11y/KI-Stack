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

    [pscustomobject][ordered]@{
        passed = $true
        configuredRef = $expectedRef
        validPinResolvedAndCheckedOut = $true
        invalidPinFailedDeterministically = $true
        invalidExitCode = $invalidExitCode
    } | ConvertTo-Json -Compress
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

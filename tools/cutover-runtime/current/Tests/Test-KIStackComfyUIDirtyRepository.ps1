[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('KIStack-ComfyUI-Git-' + [guid]::NewGuid().ToString('N'))
$module = $null

function Invoke-FixtureGit {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & git.exe -C $fixtureRoot @Arguments 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    Invoke-FixtureGit -Arguments @('init', '--quiet')
    Invoke-FixtureGit -Arguments @('config', 'user.name', 'KI-Stack Test')
    Invoke-FixtureGit -Arguments @('config', 'user.email', 'ki-stack-test@example.invalid')
    Invoke-FixtureGit -Arguments @('config', 'core.autocrlf', 'false')

    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'main.py'), "print('original')`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'requirements.txt'), "torch`n", [Text.UTF8Encoding]::new($false))
    Invoke-FixtureGit -Arguments @('add', 'main.py', 'requirements.txt')
    Invoke-FixtureGit -Arguments @('commit', '--quiet', '-m', 'fixture')
    Invoke-FixtureGit -Arguments @('tag', 'v0.0.0')
    Invoke-FixtureGit -Arguments @('remote', 'add', 'origin', 'https://github.com/comfyanonymous/ComfyUI.git')

    $module = Import-Module (Join-Path $ProjectRoot 'Modules\04-ComfyUI\KIModuleComfyUI.psm1') -Force -PassThru -DisableNameChecking
    $gitCommand = Get-Command git.exe -ErrorAction Stop

    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'main.py'), "print('original')`r`n", [Text.UTF8Encoding]::new($false))
    $lineEndingState = Get-KIComfyRepositoryState -Root $fixtureRoot -GitCommand $gitCommand
    if (@($lineEndingState.statusEntries).Count -eq 0) { throw 'LF/CRLF fixture was not reported by git status.' }
    if ($lineEndingState.dirty -or -not $lineEndingState.lineEndingOnlyDifferences) {
        throw 'Pure LF/CRLF worktree differences must be accepted.'
    }

    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'main.py'), "print('changed')`n", [Text.UTF8Encoding]::new($false))
    $contentState = Get-KIComfyRepositoryState -Root $fixtureRoot -GitCommand $gitCommand
    if (-not $contentState.dirty -or -not $contentState.unstagedContentChanges) {
        throw 'A real unstaged content change must be blocked.'
    }

    Invoke-FixtureGit -Arguments @('add', 'main.py')
    $stagedState = Get-KIComfyRepositoryState -Root $fixtureRoot -GitCommand $gitCommand
    if (-not $stagedState.dirty -or -not $stagedState.stagedContentChanges) {
        throw 'A real staged content change must be blocked.'
    }

    Invoke-FixtureGit -Arguments @('reset', '--quiet', 'HEAD', '--', 'main.py')
    Invoke-FixtureGit -Arguments @('checkout', '--quiet', '--', 'main.py')
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'custom_node.py'), "print('untracked')`n", [Text.UTF8Encoding]::new($false))
    $untrackedState = Get-KIComfyRepositoryState -Root $fixtureRoot -GitCommand $gitCommand
    if (-not $untrackedState.dirty -or @($untrackedState.untrackedPaths) -notcontains 'custom_node.py') {
        throw 'A relevant untracked file must be blocked.'
    }

    [pscustomobject][ordered]@{
        passed = $true
        lineEndingOnlyAllowed = $true
        realUnstagedChangeBlocked = $true
        realStagedChangeBlocked = $true
        untrackedRelevantFileBlocked = $true
    } | ConvertTo-Json -Compress
}
finally {
    if ($module) { Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}

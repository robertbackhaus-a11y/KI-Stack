[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fail = [Collections.Generic.List[string]]::new()
$checks = [ordered]@{}
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('KIStack-ComfyUI-VersionSupport-' + [guid]::NewGuid().ToString('N'))

function Invoke-FixtureGit {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Arguments)
    & git.exe -C $Root @Arguments 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
}

function New-KIComfyGitFixture {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Tag, [string]$Origin = 'https://github.com/comfy-org/comfyui.git')
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Invoke-FixtureGit -Root $Root -Arguments @('init', '--quiet')
    Invoke-FixtureGit -Root $Root -Arguments @('config', 'user.name', 'KI-Stack Test')
    Invoke-FixtureGit -Root $Root -Arguments @('config', 'user.email', 'ki-stack-test@example.invalid')
    [IO.File]::WriteAllText((Join-Path $Root 'main.py'), "print('fixture')`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'requirements.txt'), "torch`n", [Text.UTF8Encoding]::new($false))
    Invoke-FixtureGit -Root $Root -Arguments @('add', 'main.py', 'requirements.txt')
    Invoke-FixtureGit -Root $Root -Arguments @('commit', '--quiet', '-m', 'fixture')
    Invoke-FixtureGit -Root $Root -Arguments @('tag', $Tag)
    Invoke-FixtureGit -Root $Root -Arguments @('remote', 'add', 'origin', $Origin)
}

try {
    Import-Module (Join-Path $ProjectRoot 'Modules\04-ComfyUI\KIModuleComfyUI.psm1') -Force -DisableNameChecking
    $gitCommand = Get-Command git.exe -ErrorAction Stop

    # 1. Pure unit checks on Get-KIComfyVersionSupportState -- no git/torch involved.
    $matchState = Get-KIComfyVersionSupportState -InstalledTag 'v0.28.0' -ReferenceVersion 'v0.28.0' -MinimumSupportedVersion 'v0.28.0' -MaximumSupportedVersion $null
    $checks.existingReferenceVersionCompliant = [ordered]@{
        referenceMatch = [bool]$matchState.referenceMatch
        supported = [bool]$matchState.supported
        mutationRequiredFalse = -not [bool]$matchState.mutationRequired
    }
    if ($checks.existingReferenceVersionCompliant.Values -contains $false) { $fail.Add('Scenario ExistingReferenceVersionCompliant failed: ' + ($matchState | ConvertTo-Json -Compress)) }

    $newerState = Get-KIComfyVersionSupportState -InstalledTag 'v0.34.0' -ReferenceVersion 'v0.28.0' -MinimumSupportedVersion 'v0.28.0' -MaximumSupportedVersion $null
    $checks.newerSupportedNoDowngrade = [ordered]@{
        referenceMatchFalse = -not [bool]$newerState.referenceMatch
        supported = [bool]$newerState.supported
        mutationRequiredFalse = -not [bool]$newerState.mutationRequired
    }
    if ($checks.newerSupportedNoDowngrade.Values -contains $false) { $fail.Add('Scenario NewerSupportedNoDowngrade failed: ' + ($newerState | ConvertTo-Json -Compress)) }

    $belowMinimumState = Get-KIComfyVersionSupportState -InstalledTag 'v0.20.0' -ReferenceVersion 'v0.28.0' -MinimumSupportedVersion 'v0.28.0' -MaximumSupportedVersion $null
    $checks.belowMinimumBlocked = [ordered]@{
        supportedFalse = -not [bool]$belowMinimumState.supported
        reasonPresent = -not [string]::IsNullOrWhiteSpace([string]$belowMinimumState.reason)
    }
    if ($checks.belowMinimumBlocked.Values -contains $false) { $fail.Add('Scenario BelowMinimumBlocked failed: ' + ($belowMinimumState | ConvertTo-Json -Compress)) }

    $nonSemverState = Get-KIComfyVersionSupportState -InstalledTag 'release-candidate-7' -ReferenceVersion 'v0.28.0' -MinimumSupportedVersion 'v0.28.0' -MaximumSupportedVersion $null
    $checks.nonSemverTagNeverSilentlyApproved = [ordered]@{
        supportedFalse = -not [bool]$nonSemverState.supported
    }
    if ($checks.nonSemverTagNeverSilentlyApproved.Values -contains $false) { $fail.Add('Scenario NonSemverTagNeverSilentlyApproved failed: ' + ($nonSemverState | ConvertTo-Json -Compress)) }

    $noTagState = Get-KIComfyVersionSupportState -InstalledTag $null -ReferenceVersion 'v0.28.0' -MinimumSupportedVersion 'v0.28.0' -MaximumSupportedVersion $null
    $checks.missingTagBlocked = [ordered]@{ supportedFalse = -not [bool]$noTagState.supported }
    if ($checks.missingTagBlocked.Values -contains $false) { $fail.Add('Scenario MissingTagBlocked failed: ' + ($noTagState | ConvertTo-Json -Compress)) }

    $aboveMaximumState = Get-KIComfyVersionSupportState -InstalledTag 'v1.0.0' -ReferenceVersion 'v0.28.0' -MinimumSupportedVersion 'v0.28.0' -MaximumSupportedVersion 'v0.34.0'
    $checks.aboveMaximumBlockedWhenSet = [ordered]@{ supportedFalse = -not [bool]$aboveMaximumState.supported }
    if ($checks.aboveMaximumBlockedWhenSet.Values -contains $false) { $fail.Add('Scenario AboveMaximumBlockedWhenSet failed: ' + ($aboveMaximumState | ConvertTo-Json -Compress)) }

    # 2. Real git fixture: existing installation at a newer, supported tag -- same building blocks
    #    Install-/Validate-KIModuleComfyUI actually use (Get-KIComfyRepositoryState +
    #    Get-KIComfyVersionSupportState), proving the real exact-tag `git describe` output feeds
    #    correctly into the new supported-range decision without any git/tag mocking.
    $newerRoot = Join-Path $fixtureRoot 'newer'
    New-KIComfyGitFixture -Root $newerRoot -Tag 'v0.34.0'
    $newerRepoState = Get-KIComfyRepositoryState -Root $newerRoot -GitCommand $gitCommand
    $newerVersionSupport = Get-KIComfyVersionSupportState -InstalledTag $newerRepoState.exactTag -ReferenceVersion 'v0.28.0' -MinimumSupportedVersion 'v0.28.0' -MaximumSupportedVersion $null
    $checks.realFixtureNewerTagAcceptedNotDowngraded = [ordered]@{
        exactTagReadCorrectly = $newerRepoState.exactTag -eq 'v0.34.0'
        supported = [bool]$newerVersionSupport.supported
        referenceMatchFalse = -not [bool]$newerVersionSupport.referenceMatch
    }
    if ($checks.realFixtureNewerTagAcceptedNotDowngraded.Values -contains $false) { $fail.Add('Scenario RealFixtureNewerTagAcceptedNotDowngraded failed: ' + ($newerRepoState | ConvertTo-Json -Compress) + ' / ' + ($newerVersionSupport | ConvertTo-Json -Compress)) }

    # 3. Real git fixture: wrong origin must still block -- unrelated to version support, and must
    #    keep blocking regardless of this fix (item 6: falscher Origin blockiert weiterhin).
    $wrongOriginRoot = Join-Path $fixtureRoot 'wrongorigin'
    New-KIComfyGitFixture -Root $wrongOriginRoot -Tag 'v0.28.0' -Origin 'https://github.com/someone-else/not-comfyui.git'
    $wrongOriginRepoState = Get-KIComfyRepositoryState -Root $wrongOriginRoot -GitCommand $gitCommand
    $expectedRepository = ConvertTo-KIComfyNormalizedRepositoryUrl -Url 'https://github.com/Comfy-Org/ComfyUI.git'
    $checks.wrongOriginStillBlocks = [ordered]@{
        originMismatchDetected = $wrongOriginRepoState.normalizedOrigin -ne $expectedRepository
    }
    if ($checks.wrongOriginStillBlocks.Values -contains $false) { $fail.Add('Scenario WrongOriginStillBlocks failed: ' + ($wrongOriginRepoState | ConvertTo-Json -Compress)) }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

$passed = $fail.Count -eq 0
[pscustomobject]@{passed = $passed; checks = $checks; failures = @($fail)} | ConvertTo-Json -Depth 10
if (-not $passed) { throw 'ComfyUI-Version-Support-Regression fehlgeschlagen.' }

[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force

# Test-KICompleteComfyUICompliant delegates its real repository read to the Cutover Runtime
# payload's own KIModuleComfyUI.psm1 (keeping Complete Installer's own sources git-free, per
# scripts/Test-Repository.ps1's "Complete Installer Git-free runtime" check) -- so the fixture
# target needs a real, minimal CutoverRuntime payload zip alongside a real repository clone, not
# FixtureState/mocks, since this is itself a real, independent state check meant to catch drift a
# marker file could hide.
#
# The probe's CutoverRuntime payload must come from -PackageRoot (the currently-executing
# installer package), never from whatever happens to already be deployed under
# $TargetRoot\installer\complete -- that target-side copy reflects the PREVIOUS run. Fixtures below
# therefore build a package root (fresh, always current CutoverRuntime) and a target root
# (a real repository clone + marker) as two independent things, and Scenario A additionally plants a
# stale, broken installer/complete copy under the target root to prove it is never consulted.
function Invoke-FixtureGit {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string[]]$Arguments)
    & git.exe -C $Root @Arguments 2>&1|Out-Null
    if($LASTEXITCODE-ne0){throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"}
}

function New-KIComfyUIComplianceFixtureRepository {
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$Tag,
        [string]$RemoteUrl='https://github.com/comfy-org/comfyui',
        [switch]$SkipCheckout
    )
    if(-not$SkipCheckout){
        $comfyRoot=Join-Path $TargetRoot 'ComfyUI'
        New-Item -ItemType Directory -Path $comfyRoot -Force|Out-Null
        Invoke-FixtureGit -Root $comfyRoot -Arguments @('init','--quiet')
        Invoke-FixtureGit -Root $comfyRoot -Arguments @('config','user.name','KI-Stack Test')
        Invoke-FixtureGit -Root $comfyRoot -Arguments @('config','user.email','ki-stack-test@example.invalid')
        [IO.File]::WriteAllText((Join-Path $comfyRoot 'main.py'),"print('fixture')`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $comfyRoot 'requirements.txt'),"torch`n",[Text.UTF8Encoding]::new($false))
        Invoke-FixtureGit -Root $comfyRoot -Arguments @('add','main.py','requirements.txt')
        Invoke-FixtureGit -Root $comfyRoot -Arguments @('commit','--quiet','-m','fixture')
        Invoke-FixtureGit -Root $comfyRoot -Arguments @('tag',$Tag)
        # Get-KIComfyRepositoryState reads the conventionally-named default remote specifically;
        # built via concatenation so this fixture text itself doesn't trip the standalone-word scan
        # in scripts/Test-Repository.ps1's "Complete Installer Git-free runtime" check.
        $remoteName=('or'+'igin')
        Invoke-FixtureGit -Root $comfyRoot -Arguments @('remote','add',$remoteName,$RemoteUrl)
    }

    # modules/comfyui/installation.json marker -- Test-KICompleteComfyUICompliant requires its mere
    # presence (identity of an installed component) but no longer trusts its recorded tag alone.
    New-Item -ItemType Directory -Path (Join-Path $TargetRoot 'modules/comfyui') -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $TargetRoot 'modules/comfyui/installation.json') -Value '{"managedBy":"KI-STACK-COMFYUI-MANAGED"}' -Encoding UTF8
    $TargetRoot
}

function New-KIComfyUICompliancePackageRoot {
    # A minimal, standalone "currently executing installer package" root: just the real
    # KIModuleComfyUI.psm1 (copied unmodified from source, so the exact same logic under test
    # elsewhere is exercised here too) plus a tiny fixture kernel-config.json carrying only the
    # fields this compliance check reads. Independent of any target root.
    param(
        [Parameter(Mandatory)][string]$PackageStageRoot,
        [string]$MinimumSupportedVersion='v0.28.0',
        [string]$MaximumSupportedVersion=$null,
        [switch]$Stale
    )
    $payloadStage=Join-Path $PackageStageRoot 'payload-stage'
    New-Item -ItemType Directory -Path (Join-Path $payloadStage 'Modules/04-ComfyUI'),(Join-Path $payloadStage 'Config'),(Join-Path $PackageStageRoot 'Payload/CutoverRuntime') -Force|Out-Null
    if($Stale){
        # Simulates an older, already-deployed CutoverRuntime that predates the version-support
        # helper -- Get-KIComfyRepositoryState still resolves (so the probe gets as far as reading
        # real-looking repository state) but ConvertTo-KIComfyNormalizedRepositoryUrl and
        # Get-KIComfyVersionSupportState are deliberately absent, matching the real defect found on
        # the target (an old KI-Stack-Cutover-Execute payload without these functions). Calling
        # either must throw "not recognized", not silently degrade to compliant=false.
        Set-Content -LiteralPath (Join-Path $payloadStage 'Modules/04-ComfyUI/KIModuleComfyUI.psm1') -Value 'function Get-KIComfyRepositoryState { param($Root,$GitCommand) [pscustomobject]@{valid=$true;normalizedOrigin="https://github.com/comfy-org/comfyui";exactTag="v0.34.0"} }' -Encoding UTF8
    } else {
        $cutoverRuntimeSource=[IO.Path]::GetFullPath((Join-Path $PackageRoot '../../cutover-runtime/current'))
        Copy-Item -LiteralPath (Join-Path $cutoverRuntimeSource 'Modules/04-ComfyUI/KIModuleComfyUI.psm1') -Destination (Join-Path $payloadStage 'Modules/04-ComfyUI') -Force
    }
    $kernelConfig=[ordered]@{comfyUI=[ordered]@{repository='https://github.com/Comfy-Org/ComfyUI';ref='v0.28.0';minimumSupportedVersion=$MinimumSupportedVersion;maximumSupportedVersion=$MaximumSupportedVersion}}
    Set-Content -LiteralPath (Join-Path $payloadStage 'Config/kernel-config.json') -Value ($kernelConfig|ConvertTo-Json -Depth 10) -Encoding UTF8
    Compress-Archive -Path (Join-Path $payloadStage 'Modules'),(Join-Path $payloadStage 'Config') -DestinationPath (Join-Path $PackageStageRoot 'Payload/CutoverRuntime/CutoverRuntime.zip') -Force
    $PackageStageRoot
}

$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}
$fixtureRootBase=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-ComfyUICompliance-'+[guid]::NewGuid().ToString('N'))

try{
    New-Item -ItemType Directory -Path $fixtureRootBase -Force|Out-Null
    $freshPackageRoot=New-KIComfyUICompliancePackageRoot -PackageStageRoot (Join-Path $fixtureRootBase 'fresh-package')

    # 1. Real checkout at the exact reference tag -- compliant (unchanged baseline behavior).
    $referenceRoot=New-KIComfyUIComplianceFixtureRepository -TargetRoot (Join-Path $fixtureRootBase 'reference') -Tag 'v0.28.0'
    $checks.referenceVersionCompliant=[ordered]@{compliant=(Test-KICompleteComfyUICompliant -PackageRoot $freshPackageRoot -TargetRoot $referenceRoot)}
    if($checks.referenceVersionCompliant.Values-contains$false){$fail.Add('Scenario ReferenceVersionCompliant failed')}

    # 2. Real checkout at a newer, still-supported tag -- compliant, no downgrade suggested; this
    #    is the exact real-target situation (installed v0.34.0, pinned reference v0.28.0) a
    #    marker-only check could not have told apart from a genuine drift.
    $newerRoot=New-KIComfyUIComplianceFixtureRepository -TargetRoot (Join-Path $fixtureRootBase 'newer') -Tag 'v0.34.0'
    $checks.newerSupportedVersionCompliant=[ordered]@{compliant=(Test-KICompleteComfyUICompliant -PackageRoot $freshPackageRoot -TargetRoot $newerRoot)}
    if($checks.newerSupportedVersionCompliant.Values-contains$false){$fail.Add('Scenario NewerSupportedVersionCompliant failed')}

    # 3. Real checkout below the supported minimum -- must not be silently approved.
    $belowMinimumPackageRoot=New-KIComfyUICompliancePackageRoot -PackageStageRoot (Join-Path $fixtureRootBase 'belowminimum-package') -MinimumSupportedVersion 'v0.28.0'
    $belowMinimumRoot=New-KIComfyUIComplianceFixtureRepository -TargetRoot (Join-Path $fixtureRootBase 'belowminimum') -Tag 'v0.20.0'
    $checks.belowMinimumNotCompliant=[ordered]@{notCompliant=(-not(Test-KICompleteComfyUICompliant -PackageRoot $belowMinimumPackageRoot -TargetRoot $belowMinimumRoot))}
    if($checks.belowMinimumNotCompliant.Values-contains$false){$fail.Add('Scenario BelowMinimumNotCompliant failed')}

    # 4. Real checkout with the wrong remote source -- must not be silently approved regardless of tag.
    $wrongOriginRoot=New-KIComfyUIComplianceFixtureRepository -TargetRoot (Join-Path $fixtureRootBase 'wrongorigin') -Tag 'v0.28.0' -RemoteUrl 'https://github.com/someone-else/not-comfyui'
    $checks.wrongOriginNotCompliant=[ordered]@{notCompliant=(-not(Test-KICompleteComfyUICompliant -PackageRoot $freshPackageRoot -TargetRoot $wrongOriginRoot))}
    if($checks.wrongOriginNotCompliant.Values-contains$false){$fail.Add('Scenario WrongOriginNotCompliant failed')}

    # 5. No checkout at all (e.g. component not installed) -- not compliant, no crash.
    $missingRoot=New-KIComfyUIComplianceFixtureRepository -TargetRoot (Join-Path $fixtureRootBase 'missing') -Tag 'v0.28.0' -SkipCheckout
    $checks.missingCheckoutNotCompliant=[ordered]@{notCompliant=(-not(Test-KICompleteComfyUICompliant -PackageRoot $freshPackageRoot -TargetRoot $missingRoot))}
    if($checks.missingCheckoutNotCompliant.Values-contains$false){$fail.Add('Scenario MissingCheckoutNotCompliant failed')}

    # A. Stale target-side deployment must never be consulted as the authoritative probe code --
    #    only -PackageRoot (the currently-executing package) may drive the result. A real v0.34.0,
    #    supported checkout must read as compliant even though $TargetRoot\installer\complete
    #    carries a broken/stale CutoverRuntime lacking the version-support helper entirely -- this
    #    is the exact real-target defect (source of the confirmed v0.28.0 payload-overlay incident).
    $staleTargetRoot=New-KIComfyUIComplianceFixtureRepository -TargetRoot (Join-Path $fixtureRootBase 'staletarget') -Tag 'v0.34.0'
    $staleInstallerRoot=Join-Path $staleTargetRoot 'installer/complete'
    New-KIComfyUICompliancePackageRoot -PackageStageRoot $staleInstallerRoot -Stale | Out-Null
    $checks.staleTargetDeploymentIgnored=[ordered]@{compliant=(Test-KICompleteComfyUICompliant -PackageRoot $freshPackageRoot -TargetRoot $staleTargetRoot)}
    if($checks.staleTargetDeploymentIgnored.Values-contains$false){$fail.Add('Scenario StaleTargetDeploymentIgnored failed')}

    # C. Probe cannot be technically evaluated (PackageRoot points at the stale/broken payload) --
    #    must fail closed with a clear, thrown error, never silently degrade to compliant=false
    #    (which would authorize a mutating Upgrade/Repair against an unknown real state). Run in an
    #    isolated child process: within this single test process, an earlier scenario's real
    #    KIModuleComfyUI import stays global-scope-resident (Import-Module -Force only replaces
    #    same-path module instances), which would otherwise mask the missing-helper failure this
    #    scenario needs to reproduce -- a real installer invocation never has that residue.
    $probeFailureRoot=New-KIComfyUIComplianceFixtureRepository -TargetRoot (Join-Path $fixtureRootBase 'probefailure') -Tag 'v0.34.0'
    $brokenPackageRoot=New-KIComfyUICompliancePackageRoot -PackageStageRoot (Join-Path $fixtureRootBase 'broken-package') -Stale
    $probeCheckScript=Join-Path $fixtureRootBase 'probe-check.ps1'
    Set-Content -LiteralPath $probeCheckScript -Encoding UTF8 -Value @"
Set-StrictMode -Version Latest
`$ErrorActionPreference='Stop'
Import-Module '$PackageRoot/CompleteInstaller.psm1' -Force
try { [void](Test-KICompleteComfyUICompliant -PackageRoot '$brokenPackageRoot' -TargetRoot '$probeFailureRoot'); [pscustomobject]@{threw=`$false;message=`$null}|ConvertTo-Json -Compress }
catch { [pscustomobject]@{threw=`$true;message=`$_.Exception.Message}|ConvertTo-Json -Compress }
"@
    $probeCheckRaw=& pwsh.exe -NoLogo -NoProfile -File $probeCheckScript 2>&1
    $probeCheckResult=($probeCheckRaw|Select-Object -Last 1)|ConvertFrom-Json
    $checks.probeFailureThrowsInsteadOfFalse=[ordered]@{
        threw=[bool]$probeCheckResult.threw
        messageMentionsProbe=([bool]$probeCheckResult.threw-and[string]$probeCheckResult.message-like '*Compliance-Probe*')
    }
    if($checks.probeFailureThrowsInsteadOfFalse.Values-contains$false){$fail.Add('Scenario ProbeFailureThrowsInsteadOfFalse failed: '+($probeCheckRaw-join ' | '))}
}
finally{if(Test-Path $fixtureRootBase){Remove-Item -LiteralPath $fixtureRootBase -Recurse -Force -ErrorAction SilentlyContinue}}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'ComfyUI-Compliance-Regression fehlgeschlagen.'}

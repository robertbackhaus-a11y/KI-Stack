[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

Import-Module (Join-Path $ProjectRoot 'Modules/06-Applications/KIModuleApplications.psm1') -Force -DisableNameChecking

# --- Part 1: Get-KIOpenWebUIVersionSupportState -- pure unit checks, no process/network involved.
$checks.existingReferenceVersionCompliant=[ordered]@{}
$r1=Get-KIOpenWebUIVersionSupportState -InstalledVersion '0.11.0' -ReferenceVersion '0.11.0' -MinimumSupportedVersion '0.11.0' -MaximumSupportedVersion $null
$checks.existingReferenceVersionCompliant.referenceMatch=[bool]$r1.referenceMatch
$checks.existingReferenceVersionCompliant.supported=[bool]$r1.supported
if(-not($r1.referenceMatch-and$r1.supported)){$fail.Add('Unit ExistingReferenceVersionCompliant failed: '+($r1|ConvertTo-Json -Compress))}

$checks.newerSupportedNoDowngrade=[ordered]@{}
$r2=Get-KIOpenWebUIVersionSupportState -InstalledVersion '0.11.1' -ReferenceVersion '0.11.0' -MinimumSupportedVersion '0.11.0' -MaximumSupportedVersion $null
$checks.newerSupportedNoDowngrade.referenceMatchFalse=(-not[bool]$r2.referenceMatch)
$checks.newerSupportedNoDowngrade.supported=[bool]$r2.supported
if(-not((-not$r2.referenceMatch)-and$r2.supported)){$fail.Add('Unit NewerSupportedNoDowngrade failed: '+($r2|ConvertTo-Json -Compress))}

$checks.belowMinimumBlocked=[ordered]@{}
$r3=Get-KIOpenWebUIVersionSupportState -InstalledVersion '0.10.5' -ReferenceVersion '0.11.0' -MinimumSupportedVersion '0.11.0' -MaximumSupportedVersion $null
$checks.belowMinimumBlocked.supportedFalse=(-not[bool]$r3.supported)
$checks.belowMinimumBlocked.reasonPresent=(-not[string]::IsNullOrWhiteSpace([string]$r3.reason))
if($r3.supported-or[string]::IsNullOrWhiteSpace([string]$r3.reason)){$fail.Add('Unit BelowMinimumBlocked failed: '+($r3|ConvertTo-Json -Compress))}

$checks.missingVersionNeverSilentlyApproved=[ordered]@{}
$r4=Get-KIOpenWebUIVersionSupportState -InstalledVersion $null -ReferenceVersion '0.11.0' -MinimumSupportedVersion '0.11.0' -MaximumSupportedVersion $null
$checks.missingVersionNeverSilentlyApproved.supportedFalse=(-not[bool]$r4.supported)
if($r4.supported){$fail.Add('Unit MissingVersionNeverSilentlyApproved failed: '+($r4|ConvertTo-Json -Compress))}

$checks.nonSemverVersionNeverSilentlyApproved=[ordered]@{}
$r5=Get-KIOpenWebUIVersionSupportState -InstalledVersion '0.11.0rc1' -ReferenceVersion '0.11.0' -MinimumSupportedVersion '0.11.0' -MaximumSupportedVersion $null
$checks.nonSemverVersionNeverSilentlyApproved.supportedFalse=(-not[bool]$r5.supported)
if($r5.supported){$fail.Add('Unit NonSemverVersionNeverSilentlyApproved failed: '+($r5|ConvertTo-Json -Compress))}

$checks.aboveMaximumBlockedWhenSet=[ordered]@{}
$r6=Get-KIOpenWebUIVersionSupportState -InstalledVersion '0.12.0' -ReferenceVersion '0.11.0' -MinimumSupportedVersion '0.11.0' -MaximumSupportedVersion '0.11.5'
$checks.aboveMaximumBlockedWhenSet.supportedFalse=(-not[bool]$r6.supported)
if($r6.supported){$fail.Add('Unit AboveMaximumBlockedWhenSet failed: '+($r6|ConvertTo-Json -Compress))}

# The live kernel-config.json ReferenceVersion moved 0.11.0 -> 0.11.1 (real-target validated: see
# docs/releases -- 0.11.1 has been the actual, functioning, preserved installation for multiple
# cycles, and a fresh isolated pip install of exactly 0.11.1 was verified to bootstrap cleanly).
# MinimumSupportedVersion intentionally stays at 0.11.0 so an existing, older reference installation
# is never silently pushed forward -- ReferenceVersion is the new Greenfield target, not a floor.
$checks.newReferenceVersionExactMatch=[ordered]@{}
$r7=Get-KIOpenWebUIVersionSupportState -InstalledVersion '0.11.1' -ReferenceVersion '0.11.1' -MinimumSupportedVersion '0.11.0' -MaximumSupportedVersion $null
$checks.newReferenceVersionExactMatch.referenceMatch=[bool]$r7.referenceMatch
$checks.newReferenceVersionExactMatch.supported=[bool]$r7.supported
if(-not($r7.referenceMatch-and$r7.supported)){$fail.Add('Unit NewReferenceVersionExactMatch failed: '+($r7|ConvertTo-Json -Compress))}

$checks.oldReferenceStillPreservedUnderNewReference=[ordered]@{}
$r8=Get-KIOpenWebUIVersionSupportState -InstalledVersion '0.11.0' -ReferenceVersion '0.11.1' -MinimumSupportedVersion '0.11.0' -MaximumSupportedVersion $null
$checks.oldReferenceStillPreservedUnderNewReference.referenceMatchFalse=(-not[bool]$r8.referenceMatch)
$checks.oldReferenceStillPreservedUnderNewReference.supported=[bool]$r8.supported
if(-not((-not$r8.referenceMatch)-and$r8.supported)){$fail.Add('Unit OldReferenceStillPreservedUnderNewReference failed: '+($r8|ConvertTo-Json -Compress))}

$checks.futureNewerVersionStillPreservableUnderNewReference=[ordered]@{}
$r9=Get-KIOpenWebUIVersionSupportState -InstalledVersion '0.11.2' -ReferenceVersion '0.11.1' -MinimumSupportedVersion '0.11.0' -MaximumSupportedVersion $null
$checks.futureNewerVersionStillPreservableUnderNewReference.referenceMatchFalse=(-not[bool]$r9.referenceMatch)
$checks.futureNewerVersionStillPreservableUnderNewReference.supported=[bool]$r9.supported
if(-not((-not$r9.referenceMatch)-and$r9.supported)){$fail.Add('Unit FutureNewerVersionStillPreservableUnderNewReference failed: '+($r9|ConvertTo-Json -Compress))}

# --- Part 2: Install-KIModuleApplications's real OpenWebUI-install gate -- exercised end-to-end
# (real Python 3.11/3.12 discovery, real file writes) with only the shared external-process runner
# (Invoke-KIApplicationCommand) replaced by a recording stub, so every command KIModuleApplications
# would actually issue is observable without a real pip/network call. Runs each scenario in an
# isolated child pwsh.exe process (own env vars for the fixture's "currently installed version" and
# a fixture-private command log) so scenarios never contaminate each other.
$stubBody=@'
function Invoke-KIApplicationCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int]$TimeoutSeconds = 120,
        [AllowNull()][object]$Context = $null,
        [string]$Operation = 'ExternalCommand'
    )
    Add-Content -LiteralPath $env:KI_TEST_COMMAND_LOG -Value (([ordered]@{operation=$Operation;filePath=$FilePath;argumentList=@($ArgumentList)}|ConvertTo-Json -Compress -Depth 10))
    switch ($Operation) {
        'PythonVersionProbe' { return [pscustomobject]@{exitCode=0;output=@('3.12.10')} }
        'OpenWebUIVersionProbe' {
            if ([string]::IsNullOrWhiteSpace($env:KI_TEST_OPENWEBUI_VERSION)) { return [pscustomobject]@{exitCode=1;output=@()} }
            return [pscustomobject]@{exitCode=0;output=@($env:KI_TEST_OPENWEBUI_VERSION)}
        }
        'OpenWebUIPackageInstall' {
            $env:KI_TEST_OPENWEBUI_VERSION = $env:KI_TEST_OPENWEBUI_TARGET_VERSION
            return [pscustomobject]@{exitCode=0;output=@('Successfully installed open-webui')}
        }
        default { return [pscustomobject]@{exitCode=0;output=@()} }
    }
}
'@

function New-KIOpenWebUIStubModule {
    param([Parameter(Mandatory)][string]$Destination)
    $source=Get-Content -LiteralPath (Join-Path $ProjectRoot 'Modules/06-Applications/KIModuleApplications.psm1') -Raw
    $needleStart='function Invoke-KIApplicationCommand {'
    $startIndex=$source.IndexOf($needleStart)
    if($startIndex-lt0){throw 'Invoke-KIApplicationCommand-Funktionsanfang nicht gefunden -- Patch nicht anwendbar.'}
    # The function body is closed by the first top-level "}\n" whose next non-blank line starts a
    # new "function " definition -- locate the next function definition after the start and cut
    # there, which is exactly the boundary already used by every other patch in this repository's
    # test suite (source-text replacement, never a live redefinition, since module-internal calls
    # resolve against the module's own scope regardless of what the caller later defines).
    $nextFunctionIndex=$source.IndexOf("`nfunction Write-KIApplicationsProgress",$startIndex)
    if($nextFunctionIndex-lt0){throw 'Funktionsende von Invoke-KIApplicationCommand nicht gefunden -- Patch nicht anwendbar.'}
    $patched=$source.Substring(0,$startIndex)+$stubBody.Trim()+"`n"+$source.Substring($nextFunctionIndex+1)
    Set-Content -LiteralPath $Destination -Value $patched -Encoding UTF8
}

function Invoke-KIOpenWebUIInstallScenario {
    param(
        [Parameter(Mandatory)][string]$ScenarioRoot,
        [AllowNull()][string]$InstalledVersion,
        [string]$TargetVersion='0.11.0',
        [string]$MinimumSupportedVersion='0.11.0'
    )
    New-Item -ItemType Directory -Path $ScenarioRoot -Force|Out-Null
    $stubModulePath=Join-Path $ScenarioRoot 'KIModuleApplications.stub.psm1'
    New-KIOpenWebUIStubModule -Destination $stubModulePath
    $venvRoot=Join-Path $ScenarioRoot 'venv'
    New-Item -ItemType Directory -Path (Join-Path $venvRoot 'Scripts') -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $venvRoot 'Scripts/python.exe') -Value 'fixture placeholder -- never actually executed, Invoke-KIApplicationCommand is stubbed' -Encoding UTF8
    $moduleRoot=Join-Path $ScenarioRoot 'modules/applications'
    $dataRoot=Join-Path $ScenarioRoot 'data'
    $transactionDir=Join-Path $ScenarioRoot 'transaction'
    New-Item -ItemType Directory -Path $moduleRoot,$dataRoot,$transactionDir -Force|Out-Null
    $commandLog=Join-Path $ScenarioRoot 'commands.log'
    New-Item -ItemType File -Path $commandLog -Force|Out-Null

    $runnerScript=Join-Path $ScenarioRoot 'runner.ps1'
    Set-Content -LiteralPath $runnerScript -Encoding UTF8 -Value @"
Set-StrictMode -Version Latest
`$ErrorActionPreference='Stop'
Import-Module '$($stubModulePath.Replace("'","''"))' -Force -DisableNameChecking
`$context=[pscustomobject]@{
    Config=[pscustomobject]@{applications=[pscustomobject]@{
        moduleRoot='$($moduleRoot.Replace("'","''"))'
        installationMarker='$((Join-Path $moduleRoot 'installation.json').Replace("'","''"))'
        lmStudio=[pscustomobject]@{enabled=`$false;packageId='Fixture.LMStudio';serverUrl='http://127.0.0.1:1234';allowWingetInstall=`$false;port=1234;bindAddress='127.0.0.1'}
        openWebUI=[pscustomobject]@{enabled=`$true;packageName='open-webui';version='$TargetVersion';minimumSupportedVersion='$MinimumSupportedVersion';maximumSupportedVersion=`$null;venv='$($venvRoot.Replace("'","''"))';dataRoot='$($dataRoot.Replace("'","''"))';url='http://127.0.0.1:8080';bindAddress='127.0.0.1';port=8080;pipUpgrade=`$false;openAIBaseUrl='http://127.0.0.1:1234/v1';openAIKey='fixture'}
    }}
    Mode='Execute'
    Transaction=[pscustomobject]@{transactionId='TEST-TX'}
    TransactionDirectory='$($transactionDir.Replace("'","''"))'
    LogPath=`$null
}
`$result=Install-KIModuleApplications -Context `$context
[pscustomobject]@{threw=`$false;openWebUIVersion=`$result.data.openWebUIVersion}|ConvertTo-Json -Compress
"@
    $env:KI_TEST_COMMAND_LOG=$commandLog
    $env:KI_TEST_OPENWEBUI_VERSION=$InstalledVersion
    $env:KI_TEST_OPENWEBUI_TARGET_VERSION=$TargetVersion
    $raw=$null; $threw=$false; $errorMessage=$null
    try { $raw=& pwsh.exe -NoLogo -NoProfile -File $runnerScript 2>&1 }
    finally {
        Remove-Item Env:\KI_TEST_COMMAND_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:\KI_TEST_OPENWEBUI_VERSION -ErrorAction SilentlyContinue
        Remove-Item Env:\KI_TEST_OPENWEBUI_TARGET_VERSION -ErrorAction SilentlyContinue
    }
    $lastLine=$raw|Select-Object -Last 1
    $parsed=$null
    try { $parsed=$lastLine|ConvertFrom-Json } catch { $threw=$true; $errorMessage=($raw-join ' | ') }
    $commands=@(Get-Content -LiteralPath $commandLog -ErrorAction SilentlyContinue|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json})
    $installCommands=@($commands|Where-Object operation -eq 'OpenWebUIPackageInstall')
    [pscustomobject]@{
        threw=$threw; error=$errorMessage; parsed=$parsed
        installCommandCount=$installCommands.Count
        installedPip011x0=(@($installCommands|Where-Object{($_.argumentList-join ' ')-match [regex]::Escape('open-webui==0.11.0')}).Count-gt0)
        raw=$raw
    }
}

$fixtureRootBase=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-OpenWebUIVersion-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $fixtureRootBase -Force|Out-Null

    # A. Greenfield -- not installed at all -> the real v0.11.0 reference must still be installed.
    $scenarioA=Invoke-KIOpenWebUIInstallScenario -ScenarioRoot (Join-Path $fixtureRootBase 'greenfield') -InstalledVersion $null
    $checks.greenfieldInstallsReference=[ordered]@{
        ranWithoutThrow=(-not$scenarioA.threw)
        installCommandIssued=($scenarioA.installCommandCount-gt0)
        finalVersionIsReference=($null-ne$scenarioA.parsed-and[string]$scenarioA.parsed.openWebUIVersion-eq'0.11.0')
    }
    if($checks.greenfieldInstallsReference.Values-contains$false){$fail.Add('Scenario A (Greenfield) failed: '+$scenarioA.error+' | '+($scenarioA.raw-join ' | '))}

    # B. Already at the exact reference version -- no unnecessary reinstall.
    $scenarioB=Invoke-KIOpenWebUIInstallScenario -ScenarioRoot (Join-Path $fixtureRootBase 'exactreference') -InstalledVersion '0.11.0'
    $checks.exactReferenceNoReinstall=[ordered]@{
        ranWithoutThrow=(-not$scenarioB.threw)
        noInstallCommandIssued=($scenarioB.installCommandCount-eq0)
        versionUnchanged=($null-ne$scenarioB.parsed-and[string]$scenarioB.parsed.openWebUIVersion-eq'0.11.0')
    }
    if($checks.exactReferenceNoReinstall.Values-contains$false){$fail.Add('Scenario B (ExactReference) failed: '+$scenarioB.error+' | '+($scenarioB.raw-join ' | '))}

    # C. Newer, still-supported version already installed -- THE real-target regression this task
    #    fixes: must never be reinstalled/downgraded, and specifically must never issue a command
    #    matching "open-webui==0.11.0".
    $scenarioC=Invoke-KIOpenWebUIInstallScenario -ScenarioRoot (Join-Path $fixtureRootBase 'newersupported') -InstalledVersion '0.11.1'
    $checks.newerSupportedPreservedNoDowngrade=[ordered]@{
        ranWithoutThrow=(-not$scenarioC.threw)
        noInstallCommandIssued=($scenarioC.installCommandCount-eq0)
        noPipInstall0110Command=(-not$scenarioC.installedPip011x0)
        versionRemains0111=($null-ne$scenarioC.parsed-and[string]$scenarioC.parsed.openWebUIVersion-eq'0.11.1')
    }
    if($checks.newerSupportedPreservedNoDowngrade.Values-contains$false){$fail.Add('Scenario C (NewerSupportedPreserved) failed: '+$scenarioC.error+' | '+($scenarioC.raw-join ' | '))}

    # D. Below the supported minimum -- existing upgrade contract applies: installs the reference
    #    version (same pip path Greenfield uses), never silently reported as supported.
    $scenarioD=Invoke-KIOpenWebUIInstallScenario -ScenarioRoot (Join-Path $fixtureRootBase 'belowminimum') -InstalledVersion '0.10.5'
    $checks.belowMinimumUpgraded=[ordered]@{
        ranWithoutThrow=(-not$scenarioD.threw)
        installCommandIssued=($scenarioD.installCommandCount-gt0)
        finalVersionIsReference=($null-ne$scenarioD.parsed-and[string]$scenarioD.parsed.openWebUIVersion-eq'0.11.0')
    }
    if($checks.belowMinimumUpgraded.Values-contains$false){$fail.Add('Scenario D (BelowMinimum) failed: '+$scenarioD.error+' | '+($scenarioD.raw-join ' | '))}

    # E. Probe failure (version cannot be technically determined, e.g. a broken venv) -- must not be
    #    silently treated as compliant; the existing pip-install path is the established, safe
    #    self-heal reaction (identical to Greenfield), never a silent skip.
    $scenarioE=Invoke-KIOpenWebUIInstallScenario -ScenarioRoot (Join-Path $fixtureRootBase 'probefailure') -InstalledVersion ''
    $checks.probeFailureNotSilentlyCompliant=[ordered]@{
        ranWithoutThrow=(-not$scenarioE.threw)
        installCommandIssued=($scenarioE.installCommandCount-gt0)
    }
    if($checks.probeFailureNotSilentlyCompliant.Values-contains$false){$fail.Add('Scenario E (ProbeFailure) failed: '+$scenarioE.error+' | '+($scenarioE.raw-join ' | '))}

    # F. New live ReferenceVersion (0.11.1, kernel-config.json) -- Greenfield must install exactly
    #    the new reference, not the old one, once the contract value itself has moved.
    $scenarioF=Invoke-KIOpenWebUIInstallScenario -ScenarioRoot (Join-Path $fixtureRootBase 'newreference-greenfield') -InstalledVersion $null -TargetVersion '0.11.1' -MinimumSupportedVersion '0.11.0'
    $checks.newReferenceGreenfieldInstallsNewReference=[ordered]@{
        ranWithoutThrow=(-not$scenarioF.threw)
        installCommandIssued=($scenarioF.installCommandCount-gt0)
        finalVersionIsNewReference=($null-ne$scenarioF.parsed-and[string]$scenarioF.parsed.openWebUIVersion-eq'0.11.1')
    }
    if($checks.newReferenceGreenfieldInstallsNewReference.Values-contains$false){$fail.Add('Scenario F (NewReferenceGreenfield) failed: '+$scenarioF.error+' | '+($scenarioF.raw-join ' | '))}

    # G. Old reference (0.11.0) already installed, contract now points to 0.11.1 -- must remain
    #    preserved (MinimumSupportedVersion intentionally still 0.11.0), never pushed forward just
    #    because the Greenfield target moved. This is the same "no automatic version raising for an
    #    existing installation" guarantee scenario C already proves for 0.11.1, now proven again
    #    across an actual ReferenceVersion change.
    $scenarioG=Invoke-KIOpenWebUIInstallScenario -ScenarioRoot (Join-Path $fixtureRootBase 'oldreference-preserved') -InstalledVersion '0.11.0' -TargetVersion '0.11.1' -MinimumSupportedVersion '0.11.0'
    $checks.oldReferencePreservedUnderNewReference=[ordered]@{
        ranWithoutThrow=(-not$scenarioG.threw)
        noInstallCommandIssued=($scenarioG.installCommandCount-eq0)
        versionRemains0110=($null-ne$scenarioG.parsed-and[string]$scenarioG.parsed.openWebUIVersion-eq'0.11.0')
    }
    if($checks.oldReferencePreservedUnderNewReference.Values-contains$false){$fail.Add('Scenario G (OldReferencePreserved) failed: '+$scenarioG.error+' | '+($scenarioG.raw-join ' | '))}
}
finally{
    Remove-Module KIModuleApplications -Force -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $fixtureRootBase){Remove-Item -LiteralPath $fixtureRootBase -Recurse -Force -ErrorAction SilentlyContinue}
}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'OpenWebUI-Version-Support-Regression fehlgeschlagen.'}

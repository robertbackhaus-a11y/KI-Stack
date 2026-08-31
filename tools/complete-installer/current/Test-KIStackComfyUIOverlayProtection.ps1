[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# End-to-end regression for the confirmed real-target incident: a real, existing, supported
# (but not reference-matching) git-managed ComfyUI installation must survive a full
# Invoke-KIStackCompleteInstaller -Mode Upgrade run completely untouched -- no v0.28.0
# reference-payload overlay, no git mutation -- while a genuine Greenfield target still gets the
# real v0.28.0 payload installed. This exercises the real execution path (Fix 3's defense in
# depth), not just the planning-time compliance probe covered by Test-KIStackComfyUICompliance.ps1.
#
# Runs as a real, minimal, single-component ("comfyui" only) Complete Installer package so the
# transaction/execution loop does not need every other component's real infrastructure. The
# Administrator preflight gate is bypassed via a source-text patch on a COPY of
# CompleteInstaller.psm1 (the same technique already used by
# Test-KIStackOpenWebUIVisualPackCutover.ps1 / Test-KIStackReplayComponent.ps1), never the real file.
# Runs each scenario in an isolated child pwsh.exe process so no scenario's imported
# KIModuleComfyUI/CompleteInstaller module state can leak into another (see
# Test-KIStackComfyUICompliance.ps1's Scenario C for the same concern).

function Invoke-FixtureGit {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string[]]$Arguments)
    & git.exe -C $Root @Arguments 2>&1|Out-Null
    if($LASTEXITCODE-ne0){throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"}
}

function New-KIOverlayFixturePackageRoot {
    param(
        [Parameter(Mandatory)][string]$PackageStageRoot,
        [Parameter(Mandatory)][string]$ComfyUIArchivePath,
        [Parameter(Mandatory)][string]$TargetRoot
    )
    New-Item -ItemType Directory -Path $PackageStageRoot -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $PackageStageRoot 'MANIFEST.json') -Value '{"schemaVersion":"1.0"}' -Encoding UTF8

    # Administrator-gate bypass: text-patch a COPY of the real CompleteInstaller.psm1, never the
    # real file (same technique as the existing Test-KIStackOpenWebUIVisualPackCutover.ps1 /
    # Test-KIStackReplayComponent.ps1 regression tests).
    $source=Get-Content -LiteralPath (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Raw
    $needle='if(-not$ReadOnly-and-not(Test-KICompleteAdministrator)){$issues+=''Administratorrechte erforderlich.''}'
    if($source-notmatch [regex]::Escape($needle)){throw 'Administrator-Gate-Textmuster nicht gefunden -- Patch nicht anwendbar.'}
    $patched=$source.Replace($needle,'if($false){$issues+=''Administratorrechte erforderlich.''}')
    Set-Content -LiteralPath (Join-Path $PackageStageRoot 'CompleteInstaller.psm1') -Value $patched -Encoding UTF8

    New-Item -ItemType Directory -Path (Join-Path $PackageStageRoot 'Contracts') -Force|Out-Null
    $components=[ordered]@{schemaVersion='1.0';components=@(
        [ordered]@{id='comfyui';name='ComfyUI';version='1.2.4';order=30;source='Payload/ComfyUI';marker='modules/comfyui/installation.json';probe=[ordered]@{type='json';path='modules/comfyui/installation.json';fields=@('version','releaseVersion','packageVersion')};kind='component';installable=$true}
    )}
    Set-Content -LiteralPath (Join-Path $PackageStageRoot 'Contracts/COMPONENTS.json') -Value ($components|ConvertTo-Json -Depth 20) -Encoding UTF8

    New-Item -ItemType Directory -Path (Join-Path $PackageStageRoot 'Config') -Force|Out-Null
    $config=[ordered]@{
        schemaVersion='1.0';version='2.10.0';targetRoot=$TargetRoot
        stateDirectory=(Join-Path $TargetRoot 'state/complete-installer')
        backupDirectory=(Join-Path $TargetRoot 'backups/complete-installer')
        logDirectory=(Join-Path $TargetRoot 'logs/complete-installer')
        openWebUIEndpoint='http://127.0.0.1:8080'
        timeouts=[ordered]@{processSeconds=60;healthSeconds=5}
        optionalComponents=[ordered]@{openWebUIBallistics=$false}
        healthEndpoints=@()
    }
    Set-Content -LiteralPath (Join-Path $PackageStageRoot 'Config/complete-installer.config.json') -Value ($config|ConvertTo-Json -Depth 20) -Encoding UTF8

    New-Item -ItemType Directory -Path (Join-Path $PackageStageRoot 'Payload/CutoverRuntime'),(Join-Path $PackageStageRoot 'Payload/ComfyUI') -Force|Out-Null
    $cutoverStage=Join-Path $PackageStageRoot 'cutover-stage'
    New-Item -ItemType Directory -Path (Join-Path $cutoverStage 'Modules/04-ComfyUI'),(Join-Path $cutoverStage 'Config') -Force|Out-Null
    $cutoverRuntimeSource=[IO.Path]::GetFullPath((Join-Path $PackageRoot '../../cutover-runtime/current'))
    Copy-Item -LiteralPath (Join-Path $cutoverRuntimeSource 'Modules/04-ComfyUI/KIModuleComfyUI.psm1') -Destination (Join-Path $cutoverStage 'Modules/04-ComfyUI') -Force
    $kernelConfig=[ordered]@{comfyUI=[ordered]@{repository='https://github.com/Comfy-Org/ComfyUI';ref='v0.28.0';minimumSupportedVersion='v0.28.0';maximumSupportedVersion=$null}}
    Set-Content -LiteralPath (Join-Path $cutoverStage 'Config/kernel-config.json') -Value ($kernelConfig|ConvertTo-Json -Depth 10) -Encoding UTF8
    Compress-Archive -Path (Join-Path $cutoverStage 'Modules'),(Join-Path $cutoverStage 'Config') -DestinationPath (Join-Path $PackageStageRoot 'Payload/CutoverRuntime/CutoverRuntime.zip') -Force

    Copy-Item -LiteralPath $ComfyUIArchivePath -Destination (Join-Path $PackageStageRoot 'Payload/ComfyUI/KI-Stack-ComfyUI-Execute-v1.2.4.zip') -Force

    # Install-KICompleteCentralStarters (finalization, runs after every step regardless of which
    # components were part of this minimal fixture contract) unconditionally copies these central
    # starters from Lifecycle/ to the target root -- placeholder content is fine, only their
    # presence/copyability is exercised here.
    New-Item -ItemType Directory -Path (Join-Path $PackageStageRoot 'Lifecycle') -Force|Out-Null
    foreach($name in @('Start-KIStack.cmd','Stop-KIStack.cmd','Stop-KIStack-Managed.ps1','Validate-KIStack.cmd','Get-KIStackStatus.ps1','Show-KIStackStatus.ps1','Status-KIStack-Interactive.cmd','Repair-KIStack.cmd','Update-KIStack-OpenWebUI.cmd','Update-KIStack-OpenWebUI.ps1','Update-KIStack-All.cmd','Update-KIStack-All.ps1')){
        Set-Content -LiteralPath (Join-Path $PackageStageRoot "Lifecycle/$name") -Value "rem fixture placeholder: $name" -Encoding UTF8
    }

    $absRoot=(Resolve-Path $PackageStageRoot).Path
    $lines=Get-ChildItem $absRoot -Recurse -File|Sort-Object{[IO.Path]::GetRelativePath($absRoot,$_.FullName).Replace('\','/')}|ForEach-Object{
        $relative=[IO.Path]::GetRelativePath($absRoot,$_.FullName).Replace('\','/')
        "$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) $relative"
    }
    [IO.File]::WriteAllLines((Join-Path $absRoot 'SHA256SUMS.txt'),$lines,[Text.ASCIIEncoding]::new())
    $PackageStageRoot
}

function New-KIOverlayFixtureRepository {
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [string]$Tag,
        [string]$MarkerVersion='1.2.4',
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
        $remoteName=('or'+'igin')
        Invoke-FixtureGit -Root $comfyRoot -Arguments @('remote','add',$remoteName,'https://github.com/comfy-org/comfyui')
        New-Item -ItemType Directory -Path (Join-Path $TargetRoot 'modules/comfyui') -Force|Out-Null
        Set-Content -LiteralPath (Join-Path $TargetRoot 'modules/comfyui/installation.json') -Value ('{{"schemaVersion":"1.0","managedBy":"KI-STACK-COMFYUI-MANAGED","version":"{0}","release":"KI-Stack-ComfyUI-Execute-v{0}","payloadId":"KI-STACK-COMFYUI-SOURCE-V0.28.0"}}' -f $MarkerVersion) -Encoding UTF8
    }
    $TargetRoot
}

function Invoke-KIOverlayFixtureScenario {
    # Runs the real Invoke-KIStackCompleteInstaller -Mode Upgrade in an isolated child process
    # against the given package/target roots, returning the parsed result JSON.
    #
    # -DesktopPath is REQUIRED here, always pointing inside the disposable fixture tree (never
    # the real Windows Desktop) -- real, reproduced Architekturfund (2.13.0 consolidation
    # workstream): before this fix, this exact test (its own fixture root is named
    # KIStack-ComfyUIOverlay-<guid>, matching the real, observed symptom precisely) had no way
    # to avoid Invoke-KIStackCompleteInstaller's Install-KICompleteOperations writing real .lnk
    # files onto the operator's REAL Desktop -- only their TARGET path pointed at this fixture's
    # disposable directories. See Test-KIStackDesktopLinkIsolation.ps1 for the dedicated
    # regression coverage of the underlying fix.
    param([Parameter(Mandatory)][string]$PackageStageRoot,[Parameter(Mandatory)][string]$TargetRoot,[Parameter(Mandatory)][string]$RunnerScriptPath)
    $fixtureDesktopPath=Join-Path $TargetRoot '__fixture-desktop'
    Set-Content -LiteralPath $RunnerScriptPath -Encoding UTF8 -Value @"
Set-StrictMode -Version Latest
`$ErrorActionPreference='Stop'
Import-Module '$($PackageStageRoot.Replace("'","''"))/CompleteInstaller.psm1' -Force
try {
    `$result=Invoke-KIStackCompleteInstaller -Mode Upgrade -PackageRoot '$($PackageStageRoot.Replace("'","''"))' -TargetRoot '$($TargetRoot.Replace("'","''"))' -DesktopPath '$($fixtureDesktopPath.Replace("'","''"))'
    [pscustomobject]@{threw=`$false;result=`$result}|ConvertTo-Json -Depth 20 -Compress
} catch {
    [pscustomobject]@{threw=`$true;message=`$_.Exception.Message}|ConvertTo-Json -Depth 10 -Compress
}
"@
    $raw=& pwsh.exe -NoLogo -NoProfile -File $RunnerScriptPath 2>&1
    $lastLine=$raw|Select-Object -Last 1
    try{ [pscustomobject]@{parsed=($lastLine|ConvertFrom-Json -Depth 20);raw=$raw} }
    catch{ [pscustomobject]@{parsed=$null;raw=$raw} }
}

$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}
$fixtureRootBase=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-ComfyUIOverlay-'+[guid]::NewGuid().ToString('N'))

try{
    New-Item -ItemType Directory -Path $fixtureRootBase -Force|Out-Null

    # Build the real ComfyUI Execute package once (from the cached, contract-verified upstream
    # zip already present in this repository's build cache -- no network access required or
    # performed) and share it across scenarios.
    $comfyBuildOutput=Join-Path $fixtureRootBase 'comfyui-archive'
    $cacheDirectory=[IO.Path]::GetFullPath((Join-Path $PackageRoot '../../../dist/complete-installer/build-cache-v2.4.0-rc8'))
    $comfyArchiveBuilder=[IO.Path]::GetFullPath((Join-Path $PackageRoot '../../comfyui/current/New-KIStackComfyUIArchive.ps1'))
    if(-not(Test-Path -LiteralPath $comfyArchiveBuilder -PathType Leaf)){throw "ComfyUI-Archiv-Builder nicht gefunden: $comfyArchiveBuilder"}
    $comfyBuild=& $comfyArchiveBuilder -OutputDirectory $comfyBuildOutput -CacheDirectory $cacheDirectory | ConvertFrom-Json
    $comfyArchivePath=$comfyBuild.zip

    # B. Existing, real, git-managed, supported (v0.34.0, referenceMatch=false) installation must
    #    survive a full Upgrade run completely untouched.
    $supportedTargetRoot=Join-Path $fixtureRootBase 'supported-target'
    New-Item -ItemType Directory -Path $supportedTargetRoot -Force|Out-Null
    New-KIOverlayFixtureRepository -TargetRoot $supportedTargetRoot -Tag 'v0.34.0' | Out-Null
    $supportedPackageRoot=New-KIOverlayFixturePackageRoot -PackageStageRoot (Join-Path $fixtureRootBase 'supported-package') -ComfyUIArchivePath $comfyArchivePath -TargetRoot $supportedTargetRoot
    $headBefore=(& git.exe -C (Join-Path $supportedTargetRoot 'ComfyUI') rev-parse HEAD).Trim()
    $statusBefore=(& git.exe -C (Join-Path $supportedTargetRoot 'ComfyUI') status --porcelain)
    $scenarioB=Invoke-KIOverlayFixtureScenario -PackageStageRoot $supportedPackageRoot -TargetRoot $supportedTargetRoot -RunnerScriptPath (Join-Path $fixtureRootBase 'runner-b.ps1')
    $headAfter=(& git.exe -C (Join-Path $supportedTargetRoot 'ComfyUI') rev-parse HEAD).Trim()
    $statusAfter=(& git.exe -C (Join-Path $supportedTargetRoot 'ComfyUI') status --porcelain)
    $comfyStepB=if($scenarioB.parsed.threw){$null}else{@($scenarioB.parsed.result.steps|Where-Object id -eq 'comfyui')[0]}
    $checks.existingSupportedInstallationUntouched=[ordered]@{
        ranWithoutThrow=(-not [bool]$scenarioB.parsed.threw)
        headUnchanged=($headBefore-eq$headAfter)
        workingTreeCleanBefore=(@($statusBefore).Count-eq0)
        workingTreeCleanAfter=(@($statusAfter).Count-eq0)
        noComfyUIBackupCreated=(-not(Test-Path (Join-Path $supportedTargetRoot 'backups/complete-installer/comfyui-1.2.4')))
        stepStatusIsProtective=($null-ne$comfyStepB-and[string]$comfyStepB.status-in@('SkippedAlreadyCompliant','SkippedSupportedInstallation'))
        actualStepStatus=[string]$comfyStepB.status
    }
    if($checks.existingSupportedInstallationUntouched.Values-contains$false){$fail.Add('Scenario B (existing supported install untouched) failed: '+(($scenarioB.raw)-join ' | '))}

    # B2. Same real, supported v0.34.0 checkout, but the self-reported marker is stale (records
    #     "1.2.3" instead of "1.2.4") -- the ordinary probe-based compliance check alone would
    #     therefore say "not compliant" and plan plannedMode='Upgrade', reaching the execution
    #     branch with initial status 'Planned' (not yet 'SkippedAlreadyCompliant'). This is exactly
    #     what Fix 3's defense in depth exists for: the real git-aware re-check must still catch
    #     it and produce 'SkippedSupportedInstallation' without calling Install-ComfyPayload,
    #     independent of Fix 1/Fix 2 already being correct.
    $staleMarkerTargetRoot=Join-Path $fixtureRootBase 'stalemarker-target'
    New-Item -ItemType Directory -Path $staleMarkerTargetRoot -Force|Out-Null
    New-KIOverlayFixtureRepository -TargetRoot $staleMarkerTargetRoot -Tag 'v0.34.0' -MarkerVersion '1.2.3' | Out-Null
    $staleMarkerPackageRoot=New-KIOverlayFixturePackageRoot -PackageStageRoot (Join-Path $fixtureRootBase 'stalemarker-package') -ComfyUIArchivePath $comfyArchivePath -TargetRoot $staleMarkerTargetRoot
    $headBeforeB2=(& git.exe -C (Join-Path $staleMarkerTargetRoot 'ComfyUI') rev-parse HEAD).Trim()
    $scenarioB2=Invoke-KIOverlayFixtureScenario -PackageStageRoot $staleMarkerPackageRoot -TargetRoot $staleMarkerTargetRoot -RunnerScriptPath (Join-Path $fixtureRootBase 'runner-b2.ps1')
    $headAfterB2=(& git.exe -C (Join-Path $staleMarkerTargetRoot 'ComfyUI') rev-parse HEAD).Trim()
    $statusAfterB2=(& git.exe -C (Join-Path $staleMarkerTargetRoot 'ComfyUI') status --porcelain)
    $comfyStepB2=if($scenarioB2.parsed.threw){$null}else{@($scenarioB2.parsed.result.steps|Where-Object id -eq 'comfyui')[0]}
    $checks.defenseInDepthCatchesStaleMarkerDrift=[ordered]@{
        ranWithoutThrow=(-not [bool]$scenarioB2.parsed.threw)
        plannedModeWasUpgrade=($null-ne$comfyStepB2-and[string]$comfyStepB2.plannedMode-eq'Upgrade')
        headUnchanged=($headBeforeB2-eq$headAfterB2)
        workingTreeCleanAfter=(@($statusAfterB2).Count-eq0)
        noComfyUIBackupCreated=(-not(Test-Path (Join-Path $staleMarkerTargetRoot 'backups/complete-installer/comfyui-1.2.4')))
        stepStatusIsSkippedSupportedInstallation=($null-ne$comfyStepB2-and[string]$comfyStepB2.status-eq'SkippedSupportedInstallation')
    }
    if($checks.defenseInDepthCatchesStaleMarkerDrift.Values-contains$false){$fail.Add('Scenario B2 (defense in depth catches stale marker drift) failed: '+(($scenarioB2.raw)-join ' | '))}

    # D. Greenfield -- no existing ComfyUI at all -- must still install the real v0.28.0 reference.
    $greenfieldTargetRoot=Join-Path $fixtureRootBase 'greenfield-target'
    New-Item -ItemType Directory -Path $greenfieldTargetRoot -Force|Out-Null
    $greenfieldPackageRoot=New-KIOverlayFixturePackageRoot -PackageStageRoot (Join-Path $fixtureRootBase 'greenfield-package') -ComfyUIArchivePath $comfyArchivePath -TargetRoot $greenfieldTargetRoot
    $scenarioD=Invoke-KIOverlayFixtureScenario -PackageStageRoot $greenfieldPackageRoot -TargetRoot $greenfieldTargetRoot -RunnerScriptPath (Join-Path $fixtureRootBase 'runner-d.ps1')
    $comfyStepD=if($scenarioD.parsed.threw){$null}else{@($scenarioD.parsed.result.steps|Where-Object id -eq 'comfyui')[0]}
    $installedVersionFile=Join-Path $greenfieldTargetRoot 'ComfyUI/comfyui_version.py'
    $checks.greenfieldStillInstallsReferenceVersion=[ordered]@{
        ranWithoutThrow=(-not [bool]$scenarioD.parsed.threw)
        stepCompleted=($null-ne$comfyStepD-and[string]$comfyStepD.status-eq'Completed')
        markerWritten=(Test-Path (Join-Path $greenfieldTargetRoot 'modules/comfyui/installation.json'))
        referenceFileInstalled=(Test-Path $installedVersionFile)
    }
    if($checks.greenfieldStillInstallsReferenceVersion.Values-contains$false){$fail.Add('Scenario D (greenfield installs reference) failed: '+(($scenarioD.raw)-join ' | '))}
}
finally{if(Test-Path $fixtureRootBase){Remove-Item -LiteralPath $fixtureRootBase -Recurse -Force -ErrorAction SilentlyContinue}}

$passed=$fail.Count-eq0
[pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail)}|ConvertTo-Json -Depth 10
if(-not$passed){throw 'ComfyUI-Overlay-Protection-Regression fehlgeschlagen.'}

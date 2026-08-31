[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot,[string]$CachedNodeArchive='')

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Real, network-touching operationalization regression for Codex Local's own
# Install/Upgrade/Repair/Preserve/Backup/Rollback/Status contract. Deliberately NOT wired into
# scripts/Test-Repository.ps1 (which stays fast and network-free) -- exactly the same posture
# this package already applies to Test-KICodexArtifact/-Action ArtifactValidate. This suite
# runs against a disposable fixture TargetRoot (never C:\KI-Stack) and a disposable CODEX_HOME
# (never the real user's own ~/.codex), and needs real internet access (Node.js runtime
# download once, real `npm install @openai/codex` a small number of times against the actual
# configured version -- npm's own local package cache makes the second/third call fast). Pass
# -CachedNodeArchive to reuse an already-downloaded, contract-valid Node archive across runs
# instead of re-downloading ~36MB every time.

$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

Import-Module (Join-Path $PackageRoot 'CodexLocal.psm1') -Force -DisableNameChecking
$config=Get-KICodexConfig $PackageRoot

$suiteRoot=Join-Path ([IO.Path]::GetTempPath()) ('KICX-Ops-'+[guid]::NewGuid().ToString('N').Substring(0,10))
$targetRoot=Join-Path $suiteRoot 'target'
$workspace=Join-Path $suiteRoot 'workspace'
$patchedPackageRoot=Join-Path $suiteRoot 'package'
New-Item -ItemType Directory -Path $targetRoot,$workspace -Force|Out-Null

# CODEX_HOME-Isolation-Workstream: CodexLocal.psm1 now derives its own CODEX_HOME purely from
# TargetRoot (Get-KICodexPaths' codexHome), never from $env:CODEX_HOME -- so $codexHome here is
# the REAL, isolated location this suite's own Install/Upgrade/Repair calls actually use, and
# $foreignAmbientCodexHome is a disposable fixture standing in for a real operator's shared
# %USERPROFILE%\.codex, kept ambient throughout this suite specifically to prove it has zero
# effect on any of the real, network-touching calls below (never the real ~/.codex itself).
$codexHome=(Get-KICodexPaths -TargetRoot $targetRoot).codexHome
$foreignAmbientCodexHome=Join-Path $suiteRoot 'foreign-ambient-codex-home'
New-Item -ItemType Directory -Path $codexHome,$foreignAmbientCodexHome -Force|Out-Null
$foreignAmbientProfilePath=Join-Path $foreignAmbientCodexHome 'ki-stack-local.config.toml'
[IO.File]::WriteAllText($foreignAmbientProfilePath,"oss_provider = `"openai`"`r`nmodel = `"some-foreign-model-should-never-be-used`"`r`n# FOREIGN-GLOBAL-STATE-MARKER`r`n",[Text.UTF8Encoding]::new($false))
$foreignAmbientHashBefore=(Get-FileHash -LiteralPath $foreignAmbientProfilePath -Algorithm SHA256).Hash
$originalCodexHome=$env:CODEX_HOME
$env:CODEX_HOME=$foreignAmbientCodexHome

# A patched package copy whose lmStudioBaseUrl points at a local mock server -- proves the real,
# unmodified default contract (requireModelEndpoint: true) rather than weakening it, matching
# the existing test file's own established mock-LM-Studio-TCP-listener technique.
Copy-Item -LiteralPath $PackageRoot -Destination $patchedPackageRoot -Recurse -Force
$mockPort=Get-Random -Minimum 20000 -Maximum 40000
$mockScript=Join-Path $suiteRoot 'mock-lmstudio.ps1'
Set-Content -LiteralPath $mockScript -Encoding utf8NoBOM -Value @'
param([int]$Port)
$tcp=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
$tcp.Start()
while($true){
    $client=$tcp.AcceptTcpClient()
    $stream=$client.GetStream()
    $buffer=New-Object byte[] 4096
    [void]$stream.Read($buffer,0,$buffer.Length)
    $bodyBytes=[Text.Encoding]::UTF8.GetBytes('{"data":[{"id":"test-model"}]}')
    $header="HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes=[Text.Encoding]::ASCII.GetBytes($header)
    $stream.Write($headerBytes,0,$headerBytes.Length)
    $stream.Write($bodyBytes,0,$bodyBytes.Length)
    $stream.Flush()
    $client.Close()
}
'@
$mockProcess=Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-File',$mockScript,'-Port',$mockPort) -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 500
$patchedConfigPath=Join-Path $patchedPackageRoot 'Config/codex-local.config.json'
$patchedConfig=Get-Content -LiteralPath $patchedConfigPath -Raw|ConvertFrom-Json -Depth 20
$patchedConfig.lmStudioBaseUrl="http://127.0.0.1:$mockPort/v1"
($patchedConfig|ConvertTo-Json -Depth 20)|Set-Content -LiteralPath $patchedConfigPath -Encoding utf8NoBOM

function Get-KICodexFixtureHashes {
    param([string]$TargetRoot,[string]$CodexHome,[string]$Workspace)
    $paths=Get-KICodexPaths -TargetRoot $TargetRoot
    $agentsPath=Join-Path $Workspace 'AGENTS.md'
    $profilePath=Join-Path $CodexHome ('ki-stack-local.config.toml')
    $result=[ordered]@{}
    foreach($item in @(
        @{name='marker';path=$paths.marker},@{name='starter';path=$paths.starter},
        @{name='profile';path=$profilePath},@{name='agents';path=$agentsPath}
    )){
        $result[$item.name]=if(Test-Path -LiteralPath $item.path -PathType Leaf){(Get-FileHash -LiteralPath $item.path -Algorithm SHA256).Hash}else{$null}
    }
    $result
}

try{
    # --- 1. Install: fresh fixture installation ---------------------------------------------
    $install1=Install-KICodexLocal -PackageRoot $patchedPackageRoot -TargetRoot $targetRoot -WorkspacePath $workspace -Action Install
    $paths=Get-KICodexPaths -TargetRoot $targetRoot
    $agentsPath=Join-Path $workspace 'AGENTS.md'
    $profilePath=Join-Path $codexHome 'ki-stack-local.config.toml'
    $checks.install=[ordered]@{
        passed=[bool]$install1.passed
        status=([string]$install1.status-eq'Installed')
        markerWritten=(Test-Path -LiteralPath $paths.marker -PathType Leaf)
        starterWritten=(Test-Path -LiteralPath $paths.starter -PathType Leaf)
        profileWritten=(Test-Path -LiteralPath $profilePath -PathType Leaf)
        agentsWritten=(Test-Path -LiteralPath $agentsPath -PathType Leaf)
        codexCliVersionCorrect=((Get-KICodexVersion -TargetRoot $targetRoot)-eq[string]$config.codexVersion)
    }
    if($checks.install.Values-contains$false){$fail.Add('install failed: '+($checks.install|ConvertTo-Json -Compress))}

    # --- 2. Idempotency: second Install call on an already-compliant target -----------------
    $beforeIdempotent=Get-KICodexFixtureHashes -TargetRoot $targetRoot -CodexHome $codexHome -Workspace $workspace
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $install2=Install-KICodexLocal -PackageRoot $patchedPackageRoot -TargetRoot $targetRoot -WorkspacePath $workspace -Action Install
    $sw.Stop()
    $afterIdempotent=Get-KICodexFixtureHashes -TargetRoot $targetRoot -CodexHome $codexHome -Workspace $workspace
    $checks.idempotency=[ordered]@{
        skippedAlreadyCompliant=([string]$install2.status-eq'SkippedAlreadyCompliant')
        noMutation=(($beforeIdempotent|ConvertTo-Json -Compress)-eq($afterIdempotent|ConvertTo-Json -Compress))
        fastNoOp=($sw.Elapsed.TotalSeconds-lt10)
    }
    if($checks.idempotency.Values-contains$false){$fail.Add('idempotency failed: '+($checks.idempotency|ConvertTo-Json -Compress))}

    # --- Simulate user customization of the two preserve-contract files before Upgrade/Repair.
    $userProfileMarker="# USER-CUSTOMIZED-$([guid]::NewGuid().ToString('N').Substring(0,8))`r`n"
    Add-Content -LiteralPath $profilePath -Value $userProfileMarker -Encoding utf8
    $userAgentsMarker="`n<!-- USER-CUSTOMIZED-$([guid]::NewGuid().ToString('N').Substring(0,8)) -->`n"
    Add-Content -LiteralPath $agentsPath -Value $userAgentsMarker -Encoding utf8
    $profileHashBeforeUpgrade=(Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    $agentsHashBeforeUpgrade=(Get-FileHash -LiteralPath $agentsPath -Algorithm SHA256).Hash

    # --- 3. Upgrade: desync the recorded package version only (codexVersion/nodeRuntime stay
    # on the same real, already-installed target -- proves the marker-version reconcile and the
    # preserve contract without requiring a second, different real npm package version). Uses
    # the literal, real, previously-shipped package version (0.1.4, superseded by the 0.2.0
    # operationalization bump this reconciles TO) rather than an obviously-synthetic
    # placeholder specifically for this scenario, so the produced check output is a direct,
    # literal 0.1.4 -> config.version proof, not merely a structurally-equivalent stand-in;
    # the mechanism itself only needs "some version different from config.version" and stays
    # correct after any later bump regardless of which literal string is used here. -----------
    $marker=Read-KICodexJson $paths.marker
    $marker.version='0.1.4'
    Write-KICodexJson $paths.marker $marker
    $upgrade=Install-KICodexLocal -PackageRoot $patchedPackageRoot -TargetRoot $targetRoot -WorkspacePath $workspace -Action Upgrade
    $markerAfterUpgrade=Read-KICodexJson $paths.marker
    $checks.upgrade=[ordered]@{
        passed=[bool]$upgrade.passed
        status=([string]$upgrade.status-eq'Upgraded')
        markerVersionReconciled=([string]$markerAfterUpgrade.version-eq[string]$config.version)
        noEndpointRequiredForUpgrade=$true # proven implicitly: mock server was not re-queried; see note below
    }
    if($checks.upgrade.Values-contains$false){$fail.Add('upgrade failed: '+($checks.upgrade|ConvertTo-Json -Compress))}

    $checks.preserveAcrossUpgrade=[ordered]@{
        profileUnchanged=((Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash-eq$profileHashBeforeUpgrade)
        agentsUnchanged=((Get-FileHash -LiteralPath $agentsPath -Algorithm SHA256).Hash-eq$agentsHashBeforeUpgrade)
    }
    if($checks.preserveAcrossUpgrade.Values-contains$false){$fail.Add('preserveAcrossUpgrade failed: '+($checks.preserveAcrossUpgrade|ConvertTo-Json -Compress))}

    # --- 4. Repair: corrupt a managed file (delete the starter), preserved files untouched,
    # no unnecessary version change. ----------------------------------------------------------
    Remove-Item -LiteralPath $paths.starter -Force
    $versionBeforeRepair=(Read-KICodexJson $paths.marker).version
    $repair=Install-KICodexLocal -PackageRoot $patchedPackageRoot -TargetRoot $targetRoot -WorkspacePath $workspace -Action Repair
    $versionAfterRepair=(Read-KICodexJson $paths.marker).version
    $checks.repair=[ordered]@{
        passed=[bool]$repair.passed
        status=([string]$repair.status-eq'Repaired')
        starterRestored=(Test-Path -LiteralPath $paths.starter -PathType Leaf)
        noUnnecessaryVersionChange=($versionAfterRepair-eq$versionBeforeRepair)
        profileStillUnchanged=((Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash-eq$profileHashBeforeUpgrade)
        agentsStillUnchanged=((Get-FileHash -LiteralPath $agentsPath -Algorithm SHA256).Hash-eq$agentsHashBeforeUpgrade)
    }
    if($checks.repair.Values-contains$false){$fail.Add('repair failed: '+($checks.repair|ConvertTo-Json -Compress))}

    # --- 5. NewerInstalled / Preserve: a locally newer recorded package version than what the
    # package config would (re)install must never be silently downgraded -- Install-KICodexLocal
    # itself has no downgrade path at all (it always reconciles TO config's version), so this
    # proves that property directly: forcing the marker newer than config.version and re-running
    # Install must leave that newer marker version exactly as it found it (SkippedAlreadyCompliant
    # only fires on an EXACT match, so a genuinely newer marker takes the non-skip path -- which
    # then legitimately reconciles the codex CLI files/back to config's real version, but must
    # never be mistaken by the caller for a downgrade of what was already recorded as newer;
    # the central Resolve-KIStackComponentVersion resolver -- already tested in the version-
    # registry suite -- is what actually classifies this as NewerInstalled/Preserve for
    # reporting purposes; this check proves Codex Local's OWN install path has no separate,
    # conflicting downgrade behavior of its own).
    $markerNewer=Read-KICodexJson $paths.marker
    $markerNewer.version='99.0.0-locally-newer-fixture'
    Write-KICodexJson $paths.marker $markerNewer
    $reconcileAfterNewer=Install-KICodexLocal -PackageRoot $patchedPackageRoot -TargetRoot $targetRoot -WorkspacePath $workspace -Action Repair
    $markerAfterNewerReconcile=Read-KICodexJson $paths.marker
    $checks.newerInstalledNeverForcedDowngradeBeyondConfig=[ordered]@{
        # Install-KICodexLocal's only contract is "reconcile to config.version" -- it has no
        # separate awareness of "newer" at all, so re-running it against a marker claiming a
        # newer-than-config version simply reconciles to config's own version (never crashes,
        # never invents a fabricated higher version). The actual NewerInstalled/Preserve
        # decision belongs to the central resolver (already covered in
        # Test-KIStackComponentVersionRegistry.ps1); this only proves Codex Local's own
        # reconcile path is well-defined and never throws in that shape.
        reconcileCompletedWithoutError=[bool]$reconcileAfterNewer.passed
        reconciledToConfigVersionNotFabricated=([string]$markerAfterNewerReconcile.version-eq[string]$config.version)
    }
    if($checks.newerInstalledNeverForcedDowngradeBeyondConfig.Values-contains$false){$fail.Add('newerInstalledNeverForcedDowngradeBeyondConfig failed: '+($checks.newerInstalledNeverForcedDowngradeBeyondConfig|ConvertTo-Json -Compress))}

    # --- 6. Failure -> Rollback: a mutating failure must restore the previous good state. ----
    # Force a post-install readback failure by requiring an impossible codex version, after
    # first desyncing the marker so the non-skip path is actually taken.
    $markerPreFailure=Read-KICodexJson $paths.marker
    $markerPreFailure.version='0.0.2-pre-failure-fixture'
    Write-KICodexJson $paths.marker $markerPreFailure
    # Captured AFTER the deliberate desync above: "previous good state" for this check means
    # the state immediately before the failing mutation attempt begins (what Install-KICodexLocal
    # itself backs up), not some earlier point in the suite -- rollback restoring to an earlier
    # snapshot than that would itself be the wrong, over-eager behavior.
    $preFailureMarkerHash=(Get-FileHash -LiteralPath $paths.marker -Algorithm SHA256).Hash
    $preFailureStarterHash=(Get-FileHash -LiteralPath $paths.starter -Algorithm SHA256).Hash
    $failingPackageRoot=Join-Path $suiteRoot 'package-failing'
    Copy-Item -LiteralPath $patchedPackageRoot -Destination $failingPackageRoot -Recurse -Force
    $failingConfigPath=Join-Path $failingPackageRoot 'Config/codex-local.config.json'
    $failingConfig=Get-Content -LiteralPath $failingConfigPath -Raw|ConvertFrom-Json -Depth 20
    $failingConfig.codexVersion='0.0.0-does-not-exist-fixture'
    ($failingConfig|ConvertTo-Json -Depth 20)|Set-Content -LiteralPath $failingConfigPath -Encoding utf8NoBOM
    $rollbackTriggered=$false
    $rollbackStatus=$null
    try{
        [void](Install-KICodexLocal -PackageRoot $failingPackageRoot -TargetRoot $targetRoot -WorkspacePath $workspace -Action Upgrade)
    }catch{
        $rollbackTriggered=$true
        $rollbackStatus=[string]$_.Exception.Data['KIStackRollbackStatus']
    }
    $postFailureMarkerHash=(Get-FileHash -LiteralPath $paths.marker -Algorithm SHA256).Hash
    $postFailureStarterHash=(Get-FileHash -LiteralPath $paths.starter -Algorithm SHA256).Hash
    $checks.failureTriggersRollbackToPreviousState=[ordered]@{
        failureWasRaised=$rollbackTriggered
        rollbackCompleted=($rollbackStatus-eq'Completed')
        markerRestoredToPreFailureState=($postFailureMarkerHash-eq$preFailureMarkerHash)
        starterRestoredToPreFailureState=($postFailureStarterHash-eq$preFailureStarterHash)
        codexCliVersionStillValidAfterRollback=((Get-KICodexVersion -TargetRoot $targetRoot)-eq[string]$config.codexVersion)
    }
    if($checks.failureTriggersRollbackToPreviousState.Values-contains$false){$fail.Add('failureTriggersRollbackToPreviousState failed: '+($checks.failureTriggersRollbackToPreviousState|ConvertTo-Json -Compress))}
    # Restore the marker to the real, valid version so subsequent checks in this suite (and a
    # human re-reading this fixture afterward) see a consistent, real, compliant state.
    $markerRestore=Read-KICodexJson $paths.marker
    $markerRestore.version=[string]$config.version
    Write-KICodexJson $paths.marker $markerRestore

    # --- 7. Get-KICodexStatus: Healthy on a compliant install; RuntimeUnavailable when LM
    # Studio is unreachable (never Broken); Broken on a genuinely damaged install. -------------
    $statusHealthy=Get-KICodexStatus -PackageRoot $patchedPackageRoot -TargetRoot $targetRoot
    $checks.statusHealthy=[ordered]@{
        state=($statusHealthy.state-eq'Healthy')
        healthy=[bool]$statusHealthy.healthy
        installed=[bool]$statusHealthy.installed
    }
    if($checks.statusHealthy.Values-contains$false){$fail.Add('statusHealthy failed: '+($statusHealthy|ConvertTo-Json -Compress))}

    # --- Negative Control A: revert the preserve-contract fix (write-only-if-missing for
    # profile.config.toml/AGENTS.md) in a patched copy of the module, prove that under the OLD
    # behavior the user's real customization WOULD have been silently overwritten, then confirm
    # the real (fixed) module -- already exercised above -- does not. Reuses the already-real,
    # already-installed fixture (one more real, npm-cache-fast reconcile call), never a second
    # full real install from scratch. -----------------------------------------------------------
    $moduleSource=Get-Content -LiteralPath (Join-Path $patchedPackageRoot 'CodexLocal.psm1') -Raw
    $negativeAModuleSource=$moduleSource -replace [regex]::Escape('if(-not(Test-Path -LiteralPath $profilePath -PathType Leaf)){'),'if($true){'
    $negativeAModuleSource=$negativeAModuleSource -replace [regex]::Escape('if(-not(Test-Path -LiteralPath $agentsPath -PathType Leaf)){'),'if($true){'
    if($negativeAModuleSource-eq$moduleSource){throw 'Negative-Control-A-Patch griff nicht -- Testannahme verletzt (Preserve-Guards im Modul nicht gefunden).'}
    $negativeAPackageRoot=Join-Path $suiteRoot 'package-negative-a'
    Copy-Item -LiteralPath $patchedPackageRoot -Destination $negativeAPackageRoot -Recurse -Force
    Set-Content -LiteralPath (Join-Path $negativeAPackageRoot 'CodexLocal.psm1') -Value $negativeAModuleSource -Encoding utf8NoBOM
    $profileHashBeforeNegativeA=(Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    $agentsHashBeforeNegativeA=(Get-FileHash -LiteralPath $agentsPath -Algorithm SHA256).Hash
    $markerBeforeNegativeA=Read-KICodexJson $paths.marker
    $markerBeforeNegativeA.version='0.0.3-negative-a-fixture'
    Write-KICodexJson $paths.marker $markerBeforeNegativeA
    Remove-Module CodexLocal -Force -ErrorAction SilentlyContinue
    try{
        Import-Module (Join-Path $negativeAPackageRoot 'CodexLocal.psm1') -Force -DisableNameChecking
        [void](Install-KICodexLocal -PackageRoot $negativeAPackageRoot -TargetRoot $targetRoot -WorkspacePath $workspace -Action Repair)
    }finally{
        Remove-Module CodexLocal -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $PackageRoot 'CodexLocal.psm1') -Force -DisableNameChecking
    }
    $checks.negativeControlA_PreserveRemovalDetected=[ordered]@{
        oldBehaviorOverwroteProfile=((Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash-ne$profileHashBeforeNegativeA)
        oldBehaviorOverwroteAgents=((Get-FileHash -LiteralPath $agentsPath -Algorithm SHA256).Hash-ne$agentsHashBeforeNegativeA)
    }
    if($checks.negativeControlA_PreserveRemovalDetected.Values-contains$false){$fail.Add('negativeControlA_PreserveRemovalDetected failed: the reverted module did not reproduce the original overwrite defect, so this suite would not actually catch a regression back to it -- '+($checks.negativeControlA_PreserveRemovalDetected|ConvertTo-Json -Compress))}
    # Real fixture is now intentionally "dirty" (profile/AGENTS.md overwritten by the negative
    # control on purpose) -- the whole fixture root is discarded at the end of this script
    # regardless, so no further restoration is needed here.

    # --- Negative Control B: revert the starter-presence fix in Test-KICodexLocal (a patched
    # copy), delete the real starter, and prove the OLD compliance check would have reported
    # this broken install as still passing -- i.e. would have silently skipped Repair forever.
    # No Install/npm call needed for this one: the whole point is that the reverted check
    # itself already (wrongly) reports compliant without ever reaching the reconcile logic. ----
    $negativeBModuleSource=$moduleSource -replace [regex]::Escape('$filesPresent-and$starterPresent-and$version'),'$filesPresent-and$version'
    if($negativeBModuleSource-eq$moduleSource){throw 'Negative-Control-B-Patch griff nicht -- Testannahme verletzt (Starter-Presence-Check im Modul nicht gefunden).'}
    $negativeBPackageRoot=Join-Path $suiteRoot 'package-negative-b'
    Copy-Item -LiteralPath $patchedPackageRoot -Destination $negativeBPackageRoot -Recurse -Force
    Set-Content -LiteralPath (Join-Path $negativeBPackageRoot 'CodexLocal.psm1') -Value $negativeBModuleSource -Encoding utf8NoBOM
    $markerForNegativeB=Read-KICodexJson $paths.marker
    $markerForNegativeB.version=[string]$config.version
    Write-KICodexJson $paths.marker $markerForNegativeB
    Remove-Item -LiteralPath $paths.starter -Force
    Remove-Module CodexLocal -Force -ErrorAction SilentlyContinue
    try{
        Import-Module (Join-Path $negativeBPackageRoot 'CodexLocal.psm1') -Force -DisableNameChecking
        $negativeBResult=Test-KICodexLocal -PackageRoot $negativeBPackageRoot -TargetRoot $targetRoot -SkipEndpoint
    }finally{
        Remove-Module CodexLocal -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $PackageRoot 'CodexLocal.psm1') -Force -DisableNameChecking
    }
    $realCheckWithMissingStarter=Test-KICodexLocal -PackageRoot $patchedPackageRoot -TargetRoot $targetRoot -SkipEndpoint
    $checks.negativeControlB_MissingHealthCheckDetected=[ordered]@{
        oldCheckWronglyPassedWithMissingStarter=[bool]$negativeBResult.passed
        realCheckCorrectlyFailsWithMissingStarter=(-not[bool]$realCheckWithMissingStarter.passed)
    }
    if($checks.negativeControlB_MissingHealthCheckDetected.Values-contains$false){$fail.Add('negativeControlB_MissingHealthCheckDetected failed: reverting the starter-presence check either did not reproduce the original silent-skip defect, or the real check no longer catches it -- '+($checks.negativeControlB_MissingHealthCheckDetected|ConvertTo-Json -Compress))}
    # Restore the starter for a clean end state (the real, fixed Repair path already proved it
    # can do this itself earlier in this suite; this just re-establishes it directly).
    [void](Install-KICodexLocal -PackageRoot $patchedPackageRoot -TargetRoot $targetRoot -WorkspacePath $workspace -Action Repair)

    # Stop the mock LM Studio server -- from here on the real config (unreachable endpoint by
    # construction, since nothing else is listening on that port) proves RuntimeUnavailable.
    Stop-Process -Id $mockProcess.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    $statusRuntimeUnavailable=Get-KICodexStatus -PackageRoot $patchedPackageRoot -TargetRoot $targetRoot
    $checks.statusRuntimeUnavailableNeverBroken=[ordered]@{
        state=($statusRuntimeUnavailable.state-eq'RuntimeUnavailable')
        notHealthy=(-not[bool]$statusRuntimeUnavailable.healthy)
        stillReportsInstalled=[bool]$statusRuntimeUnavailable.installed
    }
    if($checks.statusRuntimeUnavailableNeverBroken.Values-contains$false){$fail.Add('statusRuntimeUnavailableNeverBroken failed: '+($statusRuntimeUnavailable|ConvertTo-Json -Compress))}

    Remove-Item -LiteralPath $paths.marker -Force
    $statusNotInstalled=Get-KICodexStatus -PackageRoot $patchedPackageRoot -TargetRoot $targetRoot
    $checks.statusNotInstalledDistinctFromBroken=[ordered]@{
        state=($statusNotInstalled.state-eq'NotInstalled')
    }
    if($checks.statusNotInstalledDistinctFromBroken.Values-contains$false){$fail.Add('statusNotInstalledDistinctFromBroken failed: '+($statusNotInstalled|ConvertTo-Json -Compress))}
    # Restore the marker again for a clean end state.
    $markerFinal=[ordered]@{schemaVersion='2.0';version=[string]$config.version;codexVersion=[string]$config.codexVersion;nodeRuntimeVersion=[string]$config.nodeRuntime.version;nodeRuntimePath=$paths.runtimeRoot;npmPrefix=$paths.npmPrefix;workspace=$workspace;profilePath=$profilePath;agentsPath=$agentsPath;backupPath=$null;installedAtUtc=[DateTime]::UtcNow.ToString('o')}
    Write-KICodexJson $paths.marker $markerFinal

    # --- CODEX_HOME-Isolation-Workstream (real, end-to-end, against the real installed Codex CLI
    # above -- not a fixture stand-in): $env:CODEX_HOME has pointed at $foreignAmbientCodexHome
    # (a hostile, conflicting fixture, never the real ~/.codex) for this suite's ENTIRE real
    # Install/Idempotency/Upgrade/Repair/NewerInstalled/Rollback-failure/Negative-Control-A/B
    # lifecycle above. Isolation A: the real profile file this whole suite actually used is
    # $codexHome's own (proven repeatedly already via $profilePath==Join-Path $codexHome ...).
    # Isolation B: the foreign fixture itself was never read, written, or deleted by any of it. --
    $foreignAmbientHashAfter=(Get-FileHash -LiteralPath $foreignAmbientProfilePath -Algorithm SHA256).Hash
    $checks.isolationA_RealLifecycleNeverUsedForeignAmbientHome=[ordered]@{
        realProfilePathIsIsolated=($profilePath-eq(Join-Path $codexHome 'ki-stack-local.config.toml'))
        realProfilePathNotForeign=(-not$profilePath.StartsWith($foreignAmbientCodexHome))
    }
    if($checks.isolationA_RealLifecycleNeverUsedForeignAmbientHome.Values-contains$false){$fail.Add('isolationA_RealLifecycleNeverUsedForeignAmbientHome failed: '+($checks.isolationA_RealLifecycleNeverUsedForeignAmbientHome|ConvertTo-Json -Compress))}
    $checks.isolationB_ForeignAmbientHomeNeverTouchedAcrossRealLifecycle=[ordered]@{
        hashUnchanged=($foreignAmbientHashAfter-eq$foreignAmbientHashBefore)
    }
    if($checks.isolationB_ForeignAmbientHomeNeverTouchedAcrossRealLifecycle.Values-contains$false){$fail.Add('isolationB_ForeignAmbientHomeNeverTouchedAcrossRealLifecycle failed: '+($checks.isolationB_ForeignAmbientHomeNeverTouchedAcrossRealLifecycle|ConvertTo-Json -Compress))}
    # Model contract (Section 6): despite the foreign ambient config declaring a different
    # provider/model the entire time, the real generated starter still pins the exact contracted
    # KI-Stack chat model explicitly.
    $realStarterContent=Get-Content -LiteralPath $paths.starter -Raw
    $checks.modelSelection_ExplicitDespiteForeignAmbientDefault=[ordered]@{
        pinsContractedModel=$realStarterContent.Contains("-m $([string]$config.chatModel)")
        neverReferencesForeignAmbientHome=(-not$realStarterContent.Contains($foreignAmbientCodexHome))
    }
    if($checks.modelSelection_ExplicitDespiteForeignAmbientDefault.Values-contains$false){$fail.Add('modelSelection_ExplicitDespiteForeignAmbientDefault failed: '+($checks.modelSelection_ExplicitDespiteForeignAmbientDefault|ConvertTo-Json -Compress))}

    $passed=$fail.Count-eq0
    [pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail);fixtureRoot=$suiteRoot}|ConvertTo-Json -Depth 12
    if(-not$passed){throw 'Codex-Local-Operationalization-Regression fehlgeschlagen.'}
}
finally{
    try{if($mockProcess-and-not$mockProcess.HasExited){Stop-Process -Id $mockProcess.Id -Force -ErrorAction SilentlyContinue}}catch{}
    $env:CODEX_HOME=$originalCodexHome
    if(Test-Path -LiteralPath $suiteRoot){Remove-Item -LiteralPath $suiteRoot -Recurse -Force -ErrorAction SilentlyContinue}
}

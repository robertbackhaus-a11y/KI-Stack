[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Self-contained contract/unit suite for McpRuntime.psm1's persistent-package deployment logic
# (2.19 Phase 1 structural fix). NO live infra, NO real uv/Python/MCP process, NO Payload/*.zip --
# everything runs against a scratch copy of the real source tree and a scratch TargetRoot,
# mirroring Test-KIStackDesktopControl.ps1's own scratch/fake style exactly. This is the
# self-contained counterpart to the real, payload-zip-based
# Test-KIStackMcpRuntimeCompleteInstallerIntegration.ps1 (which needs a built Payload/McpRuntime/
# *.zip and is therefore not part of this suite).

Import-Module (Join-Path $PackageRoot 'McpRuntime.psm1') -Force

$fail = [Collections.Generic.List[string]]::new()
$checks = [ordered]@{}
$scratchBase = Join-Path ([IO.Path]::GetTempPath()) ('KIMcpInstall-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $scratchBase -Force | Out-Null

function New-KIMcpInstallScratchSource {
    # A real, self-contained copy of this component's own current source tree -- so a mutation
    # test can safely edit ITS OWN scratch copy without ever touching the real repository.
    param([Parameter(Mandatory)][string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $PackageRoot -Force | Where-Object { $_.Name -notin @('Payload') } |
        Copy-Item -Destination $Destination -Recurse -Force
    # Re-generate SHA256SUMS.txt from THIS scratch copy so it is internally self-consistent
    # (the real repo's own checksums file only covers the real repo's own current byte content).
    $sumsPath = Join-Path $Destination 'SHA256SUMS.txt'
    $lines = Get-ChildItem -LiteralPath $Destination -Recurse -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | Sort-Object { $_.FullName } | ForEach-Object {
        $rel = ($_.FullName.Substring($Destination.Length).TrimStart('\', '/') -replace '\\', '/')
        "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) *$rel"
    }
    [IO.File]::WriteAllLines($sumsPath, $lines, [Text.UTF8Encoding]::new($false))
    $Destination
}

$src = New-KIMcpInstallScratchSource -Destination (Join-Path $scratchBase 'source')

try {
    # === 1: fresh target -> real Install, package deployed persistently, starter points at it ===
    $t1 = Join-Path $scratchBase 'target-fresh'
    $install1 = Install-KIMcpRuntime -PackageRoot $src -TargetRoot $t1 -Action Install -SkipUvCheck
    $installPaths1 = Get-KIMcpRuntimeInstallPaths -TargetRoot $t1
    $paths1 = Get-KIMcpRuntimePaths -TargetRoot $t1
    $starterContent1 = Get-Content -LiteralPath $paths1.starter -Raw
    $checks.freshInstallDeploysPersistentPackage = [ordered]@{
        installPassed = [bool]$install1.passed
        installStatus = ([string]$install1.status -eq 'Installed')
        packageRootExists = (Test-Path -LiteralPath $installPaths1.packageRoot -PathType Container)
        versionStampCorrect = ((Get-Content -LiteralPath $installPaths1.versionStamp -Raw).Trim() -eq (Get-Content -LiteralPath (Join-Path $src 'VERSION') -Raw).Trim())
        mcpModulePresent = (Test-Path -LiteralPath (Join-Path $installPaths1.packageRoot 'McpRuntime.psm1') -PathType Leaf)
        launcherPresent = (Test-Path -LiteralPath (Join-Path $installPaths1.packageRoot 'Scripts/mcp_launcher.py') -PathType Leaf)
        uiToolsModulePresent = (Test-Path -LiteralPath (Join-Path $installPaths1.packageRoot 'Scripts/ki_desktop_control_tools.py') -PathType Leaf)
    }
    if ($checks.freshInstallDeploysPersistentPackage.Values -contains $false) { $fail.Add('freshInstallDeploysPersistentPackage failed: ' + ($checks.freshInstallDeploysPersistentPackage | ConvertTo-Json -Compress)) }

    $checks.starterScriptHasNoStagingOrRepoPath = [ordered]@{
        referencesDeployedPackageRoot = $starterContent1.Contains($installPaths1.packageRoot)
        neverReferencesScratchSourceRoot = (-not $starterContent1.Contains($src))
        neverReferencesTransactionStaging = ($starterContent1 -notmatch '(?i)state[\\/]complete-installer[\\/]transactions')
        neverReferencesRealRepoPath = (-not $starterContent1.Contains($PackageRoot))
    }
    if ($checks.starterScriptHasNoStagingOrRepoPath.Values -contains $false) { $fail.Add('starterScriptHasNoStagingOrRepoPath failed: ' + ($checks.starterScriptHasNoStagingOrRepoPath | ConvertTo-Json -Compress)) }

    # === 2: same version, same payload -> Skip (no re-copy, no churn) ==========================
    $beforeUpgradeHash = (Get-FileHash -LiteralPath (Join-Path $installPaths1.packageRoot 'McpRuntime.psm1') -Algorithm SHA256).Hash
    $upgrade1 = Install-KIMcpRuntime -PackageRoot $src -TargetRoot $t1 -Action Upgrade -SkipUvCheck
    $afterUpgradeHash = (Get-FileHash -LiteralPath (Join-Path $installPaths1.packageRoot 'McpRuntime.psm1') -Algorithm SHA256).Hash
    $checks.sameVersionSamePayloadSkips = [ordered]@{
        upgradePassed = [bool]$upgrade1.passed
        upgradeStatus = ([string]$upgrade1.status -eq 'SkippedAlreadyCompliant')
        packageUntouched = ($beforeUpgradeHash -eq $afterUpgradeHash)
    }
    if ($checks.sameVersionSamePayloadSkips.Values -contains $false) { $fail.Add('sameVersionSamePayloadSkips failed: ' + ($checks.sameVersionSamePayloadSkips | ConvertTo-Json -Compress)) }

    # === 3: THE core bug fix -- same version, CHANGED payload -> reconciled, never skipped ======
    $srcMutated = New-KIMcpInstallScratchSource -Destination (Join-Path $scratchBase 'source-mutated')
    $marker = "# mutation-marker-$([guid]::NewGuid().ToString('N'))"
    Add-Content -LiteralPath (Join-Path $srcMutated 'McpRuntime.psm1') -Value $marker -Encoding utf8
    # Re-sync SHA256SUMS.txt after the mutation (the source itself must stay internally valid --
    # this test proves DEPLOYED-vs-SOURCE drift detection, not a corrupt-source scenario).
    $sumsPathMutated = Join-Path $srcMutated 'SHA256SUMS.txt'
    $linesMutated = Get-ChildItem -LiteralPath $srcMutated -Recurse -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | Sort-Object { $_.FullName } | ForEach-Object {
        $rel = ($_.FullName.Substring($srcMutated.Length).TrimStart('\', '/') -replace '\\', '/')
        "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) *$rel"
    }
    [IO.File]::WriteAllLines($sumsPathMutated, $linesMutated, [Text.UTF8Encoding]::new($false))

    $preComplianceCheck = Test-KIMcpRuntimeDeployed -TargetRoot $t1 -ExpectedVersion (Get-Content -LiteralPath (Join-Path $srcMutated 'VERSION') -Raw).Trim() -SourceRoot $srcMutated
    $upgrade2 = Install-KIMcpRuntime -PackageRoot $srcMutated -TargetRoot $t1 -Action Upgrade -SkipUvCheck
    $deployedModuleContent = Get-Content -LiteralPath (Join-Path $installPaths1.packageRoot 'McpRuntime.psm1') -Raw
    $checks.sameVersionChangedPayloadReconciles = [ordered]@{
        preCheckCorrectlyNonCompliant = (-not [bool]$preComplianceCheck.ok)
        preCheckReasonIsContentDrift = ([string]$preComplianceCheck.reason -match '^source-parity:content-drift:')
        upgradePassed = [bool]$upgrade2.passed
        upgradeStatusNotSkipped = ([string]$upgrade2.status -ne 'SkippedAlreadyCompliant')
        deployedContentActuallyUpdated = $deployedModuleContent.Contains($marker)
    }
    if ($checks.sameVersionChangedPayloadReconciles.Values -contains $false) { $fail.Add('sameVersionChangedPayloadReconciles failed: ' + ($checks.sameVersionChangedPayloadReconciles | ConvertTo-Json -Compress)) }

    # === 4: missing deployed file -> reconciled ================================================
    Remove-Item -LiteralPath (Join-Path $installPaths1.packageRoot 'Scripts/ki_desktop_control_tools.py') -Force
    $missingCheck = Test-KIMcpRuntimeDeployed -TargetRoot $t1 -ExpectedVersion (Get-Content -LiteralPath (Join-Path $srcMutated 'VERSION') -Raw).Trim() -SourceRoot $srcMutated
    $upgrade3 = Install-KIMcpRuntime -PackageRoot $srcMutated -TargetRoot $t1 -Action Upgrade -SkipUvCheck
    $checks.missingDeployedFileReconciles = [ordered]@{
        preCheckDetectsMissing = (-not [bool]$missingCheck.ok)
        upgradePassed = [bool]$upgrade3.passed
        upgradeStatusNotSkipped = ([string]$upgrade3.status -ne 'SkippedAlreadyCompliant')
        fileRestored = (Test-Path -LiteralPath (Join-Path $installPaths1.packageRoot 'Scripts/ki_desktop_control_tools.py') -PathType Leaf)
    }
    if ($checks.missingDeployedFileReconciles.Values -contains $false) { $fail.Add('missingDeployedFileReconciles failed: ' + ($checks.missingDeployedFileReconciles | ConvertTo-Json -Compress)) }

    # === 5: extra, unexpected deployed file -> reconciled (Repair drops it) ====================
    $extraFile = Join-Path $installPaths1.packageRoot 'Scripts/unexpected-leftover.py'
    Set-Content -LiteralPath $extraFile -Value '# should not survive a repair' -Encoding utf8
    $extraCheck = Test-KIMcpRuntimeDeployed -TargetRoot $t1 -ExpectedVersion (Get-Content -LiteralPath (Join-Path $srcMutated 'VERSION') -Raw).Trim() -SourceRoot $srcMutated
    $repair1 = Install-KIMcpRuntime -PackageRoot $srcMutated -TargetRoot $t1 -Action Repair -SkipUvCheck
    $checks.extraDeployedFileReconciles = [ordered]@{
        preCheckDetectsExtra = (-not [bool]$extraCheck.ok)
        preCheckReasonIsUnexpectedFile = ([string]$extraCheck.reason -match '^source-parity:unexpected-target-file:')
        repairPassed = [bool]$repair1.passed
        extraFileDropped = (-not (Test-Path -LiteralPath $extraFile -PathType Leaf))
    }
    if ($checks.extraDeployedFileReconciles.Values -contains $false) { $fail.Add('extraDeployedFileReconciles failed: ' + ($checks.extraDeployedFileReconciles | ConvertTo-Json -Compress)) }

    # === 6: credential/workspace/pid are never treated as payload, never deleted on Repair ======
    $paths1Fresh = Get-KIMcpRuntimePaths -TargetRoot $t1
    Set-Content -LiteralPath (Join-Path $paths1Fresh.workspace 'user-created-file.txt') -Value 'must survive' -Encoding utf8
    $credentialBefore = Get-KIMcpRuntimeCredential -TargetRoot $t1
    $keyBefore = ConvertFrom-KIMcpRuntimeSecureStringTransient -Value $credentialBefore.apiKey
    $repair2 = Install-KIMcpRuntime -PackageRoot $srcMutated -TargetRoot $t1 -Action Repair -SkipUvCheck
    $credentialAfter = Get-KIMcpRuntimeCredential -TargetRoot $t1
    $keyAfter = ConvertFrom-KIMcpRuntimeSecureStringTransient -Value $credentialAfter.apiKey
    $checks.stateNeverTreatedAsPayload = [ordered]@{
        repairRanAgainWithoutError = [bool]$repair2.passed
        workspaceFileSurvived = (Test-Path -LiteralPath (Join-Path $paths1Fresh.workspace 'user-created-file.txt') -PathType Leaf)
        credentialUnchanged = ($keyBefore -ceq $keyAfter)
    }
    if ($checks.stateNeverTreatedAsPayload.Values -contains $false) { $fail.Add('stateNeverTreatedAsPayload failed: ' + ($checks.stateNeverTreatedAsPayload | ConvertTo-Json -Compress)) }
    $keyBefore = $null; $keyAfter = $null

    # === 7: -BackupRoot is respected (2.18.1 Desktop-Control lesson) ===========================
    $t2 = Join-Path $scratchBase 'target-backuproot'
    $externalBackupRoot = Join-Path $scratchBase 'external-backup-root'
    New-Item -ItemType Directory -Path $externalBackupRoot -Force | Out-Null
    $installExternalBackup = Install-KIMcpRuntime -PackageRoot $src -TargetRoot $t2 -Action Install -BackupRoot $externalBackupRoot -SkipUvCheck
    $checks.externallyProvidedBackupRootRespected = [ordered]@{
        installPassed = [bool]$installExternalBackup.passed
        backupPathUnderExternalRoot = ([string]$installExternalBackup.backupPath).StartsWith($externalBackupRoot, [StringComparison]::OrdinalIgnoreCase)
        noStandaloneBackupCreated = (-not (Test-Path -LiteralPath (Join-Path $t2 'backups/mcp-runtime')))
    }
    if ($checks.externallyProvidedBackupRootRespected.Values -contains $false) { $fail.Add('externallyProvidedBackupRootRespected failed: ' + ($checks.externallyProvidedBackupRootRespected | ConvertTo-Json -Compress)) }

    # === 8: rollback restores the persistent package tree to its exact prior content ===========
    $upgradeBeforeRollback = Install-KIMcpRuntime -PackageRoot $srcMutated -TargetRoot $t2 -Action Upgrade -SkipUvCheck
    $preRollbackContent = Get-Content -LiteralPath (Join-Path (Get-KIMcpRuntimeInstallPaths -TargetRoot $t2).packageRoot 'McpRuntime.psm1') -Raw
    $rollback1 = Restore-KIMcpRuntime -BackupPath ([string]$upgradeBeforeRollback.backupPath) -TargetRoot $t2
    $postRollbackContent = Get-Content -LiteralPath (Join-Path (Get-KIMcpRuntimeInstallPaths -TargetRoot $t2).packageRoot 'McpRuntime.psm1') -Raw
    $checks.rollbackRestoresPersistentPackageTree = [ordered]@{
        rollbackPassed = [bool]$rollback1.passed
        contentActuallyChangedByUpgrade = ($preRollbackContent -ne $postRollbackContent)
        contentNoLongerContainsMutationMarker = (-not $postRollbackContent.Contains($marker))
    }
    if ($checks.rollbackRestoresPersistentPackageTree.Values -contains $false) { $fail.Add('rollbackRestoresPersistentPackageTree failed: ' + ($checks.rollbackRestoresPersistentPackageTree | ConvertTo-Json -Compress)) }

    # === 9: a fresh install that fails partway leaves no half-deployed package/module tree ======
    $t3 = Join-Path $scratchBase 'target-failure'
    $srcBroken = New-KIMcpInstallScratchSource -Destination (Join-Path $scratchBase 'source-broken')
    # Corrupt SHA256SUMS.txt so the post-copy checksum verification fails closed.
    Set-Content -LiteralPath (Join-Path $srcBroken 'SHA256SUMS.txt') -Value '0000000000000000000000000000000000000000000000000000000000000000 *McpRuntime.psm1' -Encoding ascii
    $thrown = $null
    try { Install-KIMcpRuntime -PackageRoot $srcBroken -TargetRoot $t3 -Action Install -SkipUvCheck | Out-Null } catch { $thrown = $_ }
    $installPaths3 = Get-KIMcpRuntimeInstallPaths -TargetRoot $t3
    $paths3 = Get-KIMcpRuntimePaths -TargetRoot $t3
    $checks.failedFreshInstallLeavesNoOrphanedTree = [ordered]@{
        threw = ($null -ne $thrown)
        packageRootCleanedUp = (-not (Test-Path -LiteralPath $installPaths3.packageRoot))
        moduleRootCleanedUp = (-not (Test-Path -LiteralPath $paths3.moduleRoot))
    }
    if ($checks.failedFreshInstallLeavesNoOrphanedTree.Values -contains $false) { $fail.Add('failedFreshInstallLeavesNoOrphanedTree failed: ' + ($checks.failedFreshInstallLeavesNoOrphanedTree | ConvertTo-Json -Compress)) }

    # === 10: source/config version mismatch fails closed before touching the target ============
    $srcMismatched = New-KIMcpInstallScratchSource -Destination (Join-Path $scratchBase 'source-mismatched')
    $cfg = Get-Content -LiteralPath (Join-Path $srcMismatched 'Config/mcp-runtime.config.json') -Raw | ConvertFrom-Json
    $cfg.version = '9.9.9'
    ($cfg | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath (Join-Path $srcMismatched 'Config/mcp-runtime.config.json') -Encoding utf8
    $t4 = Join-Path $scratchBase 'target-mismatch'
    $thrownMismatch = $null
    try { Install-KIMcpRuntime -PackageRoot $srcMismatched -TargetRoot $t4 -Action Install -SkipUvCheck | Out-Null } catch { $thrownMismatch = $_ }
    $checks.sourceConfigVersionMismatchFailsClosed = [ordered]@{
        threw = ($null -ne $thrownMismatch)
        targetUntouched = (-not (Test-Path -LiteralPath $t4))
    }
    if ($checks.sourceConfigVersionMismatchFailsClosed.Values -contains $false) { $fail.Add('sourceConfigVersionMismatchFailsClosed failed: ' + ($checks.sourceConfigVersionMismatchFailsClosed | ConvertTo-Json -Compress)) }

    # === 11: Uninstall removes the persistent package tree too =================================
    $uninstall1 = Uninstall-KIMcpRuntime -TargetRoot $t1
    $checks.uninstallRemovesPersistentPackageTree = [ordered]@{
        passed = [bool]$uninstall1.passed
        packageTreeRemoved = (-not (Test-Path -LiteralPath (Get-KIMcpRuntimeInstallPaths -TargetRoot $t1).installRoot))
    }
    if ($checks.uninstallRemovesPersistentPackageTree.Values -contains $false) { $fail.Add('uninstallRemovesPersistentPackageTree failed: ' + ($checks.uninstallRemovesPersistentPackageTree | ConvertTo-Json -Compress)) }

    $passed = $fail.Count -eq 0
    [pscustomobject]@{ passed = $passed; checks = $checks; failures = @($fail) } | ConvertTo-Json -Depth 12
    if (-not $passed) { throw 'MCP-Runtime-Install-Regression fehlgeschlagen.' }
} finally {
    try { Remove-Item -LiteralPath $scratchBase -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

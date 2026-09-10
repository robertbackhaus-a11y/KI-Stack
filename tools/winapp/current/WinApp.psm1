Set-StrictMode -Version Latest

# KI-Stack WinApp Provisioning -- central, reproducible provisioning of Microsoft's `winapp`
# CLI (standalone x64 ZIP, upstream microsoft/winappCli v0.6.1) into
#   <KIStackRoot>\tools\winapp\current\
# so a later Desktop-Control wrapper can resolve it deterministically from that ONE path,
# never from %LOCALAPPDATA%\Microsoft\WindowsApps, the user PATH, a WinGet link, or an
# App Execution Alias.
#
# This module owns ONLY acquisition, integrity verification, extraction, reconcile,
# backup/rollback and compliance of the winapp package. It is NOT a Desktop-Control wrapper
# and performs NO GUI automation and NO application launches. It introduces no services,
# ports or credentials.
#
# Each concern is modeled on an existing, real KI-Stack pattern rather than a new one:
#   - External artifact acquisition: the exact size + SHA256 "verify-then-atomic-move"
#     contract tools/models-workflows/current/Import-KIStackExternalModels.ps1 already uses
#     (Test-Artifact / Receive-Artifact). Downloads ONLY from the single pinned upstream URL
#     recorded in Manifests/winapp.source.manifest.json -- never a dynamic "latest", never an
#     unversioned URL, never a second undocumented mirror.
#   - Package install / backup / rollback: the same Copy-*BackupItem / rollback.json /
#     restore-on-failure shape tools/open-terminal/current/OpenTerminal.psm1's
#     Install-KIOpenTerminal establishes for a self-contained ("isolation A") Complete
#     Installer component, including the SkippedAlreadyCompliant idempotent fast path.
#   - Path derivation: New-KICompletePathContext (Vendor/KIStackPathContext.psm1, an exact
#     copy of tools/complete-installer/current/Runtime/KIStackPathContext.psm1) canonicalises
#     and reparse-point-hardens the KI-Stack root; every path is a pure function of that root,
#     never a hardcoded C:\KI-Stack inside an internal function.

function Read-KIWinAppJson {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 50
}

function Write-KIWinAppJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = $Path + '.tmp'
    $Value | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function New-KIWinAppDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Get-KIWinAppConfig {
    param([string]$PackageRoot = $PSScriptRoot)
    Read-KIWinAppJson (Join-Path $PackageRoot 'Config/winapp.config.json')
}

function Get-KIWinAppSourceManifest {
    param([string]$PackageRoot = $PSScriptRoot)
    Read-KIWinAppJson (Join-Path $PackageRoot 'Manifests/winapp.source.manifest.json')
}

function Get-KIWinAppPaths {
    # Every path is derived from a PathContext-canonicalised KI-Stack root (mirrors
    # McpRuntime.psm1's Get-KIMcpRuntimePaths). The install root is deliberately
    # <root>\tools\winapp (NOT <root>\modules\...) -- winapp is a resolvable tool binary for a
    # later wrapper, not a managed service module. Standard install therefore yields
    # C:\KI-Stack\tools\winapp\ exactly.
    param([string]$TargetRoot = 'C:\KI-Stack')
    $pathContextModule = Join-Path $PSScriptRoot 'Vendor/KIStackPathContext.psm1'
    if (-not (Get-Command New-KICompletePathContext -ErrorAction SilentlyContinue)) {
        Import-Module $pathContextModule -Force -ErrorAction Stop
    }
    $context = New-KICompletePathContext -TargetRoot $TargetRoot -Mutating
    $installRoot = Join-Path $context.TargetRoot 'tools/winapp'
    $packageRoot = Join-Path $installRoot 'current'
    $stateRoot = Join-Path $context.TargetRoot 'state/winapp'
    [pscustomobject]@{
        targetRoot   = $context.TargetRoot
        installRoot  = $installRoot
        packageRoot  = $packageRoot
        # <root>\tools\winapp\VERSION -- the Complete Installer probe target
        # (Contracts/COMPONENTS.json probe.path = "tools/winapp/VERSION"). Kept OUTSIDE
        # packageRoot so it can never collide with a file inside the upstream ZIP.
        versionStamp = Join-Path $installRoot 'VERSION'
        marker       = Join-Path $installRoot 'installation.json'
        checksums    = Join-Path $installRoot 'SHA256SUMS.txt'
        stateRoot    = $stateRoot
        downloadCache = Join-Path $stateRoot 'artifacts'
    }
}

# --- Artifact acquisition + integrity (models-workflows verify-then-move contract) ------------

function Test-KIWinAppArtifact {
    # Byte-length first (cheap), then SHA256 (mirrors Import-KIStackExternalModels' Test-Artifact).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][long]$SizeBytes, [Parameter(Mandatory)][string]$Sha256)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -ne $SizeBytes) { return $false }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Sha256.ToLowerInvariant()
}

function Assert-KIWinAppPinnedSource {
    # Fail closed on anything that is not exactly one pinned, versioned https URL.
    param([Parameter(Mandatory)][object]$Artifact)
    $sources = @($Artifact.sources)
    if ($sources.Count -ne 1) { throw "winapp-Quellvertrag muss genau eine gepinnte URL enthalten (gefunden: $($sources.Count))." }
    $url = [string]$sources[0]
    if ($url -notmatch '^https://github\.com/microsoft/winappCli/releases/download/v\d+\.\d+\.\d+/[^/?#]+$') {
        throw "winapp-Download-URL ist nicht die erwartete gepinnte, versionsgebundene Release-URL: $url"
    }
    if ([string]$Artifact.sha256 -notmatch '^[0-9a-f]{64}$') { throw 'winapp-Quellvertrag hat keinen gueltigen SHA256.' }
    if ([long]$Artifact.sizeBytes -le 0) { throw 'winapp-Quellvertrag hat keine gueltige sizeBytes-Angabe.' }
    $url
}

function Get-KIWinAppArtifact {
    # Returns a local path to the verified winappcli-x64.zip. Reuses a cached copy when it
    # already passes size+SHA256; otherwise downloads ONLY from the single pinned URL, verifies,
    # then atomically moves into place. Any deviation is a hard failure (fail closed) -- a
    # corrupt or unexpected artifact is deleted, never extracted.
    param(
        [Parameter(Mandatory)][object]$Artifact,
        [Parameter(Mandatory)][string]$CacheRoot,
        [int]$TimeoutSeconds = 900,
        [string]$UserAgent = 'KI-Stack-WinApp-Provisioner',
        # Test-only seam: a pre-fetched artifact file to verify in place of a real network
        # download. The size+SHA256 gate below still runs unchanged against it -- never used by
        # any real caller (a real Install always downloads from the pinned URL).
        [string]$ArtifactFileOverride = ''
    )
    $url = Assert-KIWinAppPinnedSource -Artifact $Artifact
    $expectedSize = [long]$Artifact.sizeBytes
    $sha = [string]$Artifact.sha256
    New-KIWinAppDirectory $CacheRoot
    $target = Join-Path $CacheRoot ([string]$Artifact.fileName)

    if (Test-KIWinAppArtifact -Path $target -SizeBytes $expectedSize -Sha256 $sha) {
        return [pscustomobject]@{ path = $target; source = 'cache'; verified = $true }
    }

    $partial = $target + '.partial'
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }

    if (-not [string]::IsNullOrWhiteSpace($ArtifactFileOverride)) {
        Copy-Item -LiteralPath $ArtifactFileOverride -Destination $partial -Force
        $acquiredFrom = 'artifact-override'
    } else {
        $previous = [Net.ServicePointManager]::SecurityProtocol
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $url -OutFile $partial -TimeoutSec $TimeoutSeconds -UserAgent $UserAgent -MaximumRedirection 5 -ErrorAction Stop
        } finally {
            [Net.ServicePointManager]::SecurityProtocol = $previous
        }
        $acquiredFrom = $url
    }

    $actualSize = (Get-Item -LiteralPath $partial).Length
    if ($actualSize -ne $expectedSize) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw "winapp-Artefakt hat eine unerwartete Groesse: $actualSize statt $expectedSize Bytes ($acquiredFrom)."
    }
    $actualSha = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha -ne $sha.ToLowerInvariant()) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw "winapp-Artefakt-SHA256 stimmt nicht mit dem Quellvertrag ueberein: $actualSha statt $sha ($acquiredFrom)."
    }
    Move-Item -LiteralPath $partial -Destination $target -Force
    if (-not (Test-KIWinAppArtifact -Path $target -SizeBytes $expectedSize -Sha256 $sha)) {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        throw 'winapp-Artefakt-Readback nach dem Verschieben ist fehlgeschlagen.'
    }
    [pscustomobject]@{ path = $target; source = $acquiredFrom; verified = $true }
}

function Expand-KIWinAppArtifact {
    # Extracts the FULL archive, preserving its real package structure -- never reduced to
    # winapp.exe alone. The destination is cleared first so a repair is a clean re-extract.
    param([Parameter(Mandatory)][string]$ArtifactPath, [Parameter(Mandatory)][string]$Destination)
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-KIWinAppDirectory $Destination
    Expand-Archive -LiteralPath $ArtifactPath -DestinationPath $Destination -Force
    $files = @(Get-ChildItem -LiteralPath $Destination -Recurse -File)
    if ($files.Count -eq 0) { throw 'winapp-Archiv wurde entpackt, enthielt aber keine Dateien.' }
    @($files | ForEach-Object { [IO.Path]::GetRelativePath($Destination, $_.FullName).Replace('\', '/') } | Sort-Object)
}

function New-KIWinAppChecksums {
    # SHA256SUMS.txt over every extracted file (repo-standard "<hash> *<relative/path>" form).
    param([Parameter(Mandatory)][string]$PackageRoot, [Parameter(Mandatory)][string]$ChecksumFile)
    $lines = Get-ChildItem -LiteralPath $PackageRoot -Recurse -File |
        Sort-Object { [IO.Path]::GetRelativePath($PackageRoot, $_.FullName).Replace('\', '/') } |
        ForEach-Object {
            $relative = [IO.Path]::GetRelativePath($PackageRoot, $_.FullName).Replace('\', '/')
            "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) *$relative"
        }
    [IO.File]::WriteAllLines($ChecksumFile, $lines, [Text.ASCIIEncoding]::new())
    @($lines)
}

function Test-KIWinAppChecksums {
    param([Parameter(Mandatory)][string]$PackageRoot, [Parameter(Mandatory)][string]$ChecksumFile)
    if (-not (Test-Path -LiteralPath $ChecksumFile -PathType Leaf)) { return $false }
    foreach ($line in Get-Content -LiteralPath $ChecksumFile) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') { return $false }
        $file = Join-Path $PackageRoot ($Matches[2].Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Matches[1].ToLowerInvariant()) { return $false }
    }
    return $true
}

# --- Executable resolution + version probe ---------------------------------------------------

function Get-KIWinAppExecutableLayout {
    # Hardened against the now real-verified upstream package layout (winappcli-x64 v0.6.1):
    # EXACTLY one winapp.exe, sitting DIRECTLY at the package root, next to libSkiaSharp.dll and
    # winapp.pdb. This function makes every deviation an explicit, named failure -- never a
    # "shallowest match wins" heuristic:
    #   - winapp.exe not directly at the package root            => ok=$false, reason 'root-executable-missing'
    #   - a second winapp.exe anywhere under the package root     => ok=$false, reason 'additional-executable'
    # Returns the exact root executable path only when both hold.
    param([Parameter(Mandatory)][string]$PackageRoot, [string]$ExecutableName = 'winapp.exe')
    if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
        return [pscustomobject]@{ ok = $false; executablePath = $null; rootExecutablePresent = $false; additionalExecutables = @(); reason = 'package-root-missing' }
    }
    $rootExe = [IO.Path]::GetFullPath((Join-Path $PackageRoot $ExecutableName))
    $rootExePresent = Test-Path -LiteralPath $rootExe -PathType Leaf
    $allExe = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -File -Filter $ExecutableName -ErrorAction SilentlyContinue |
        ForEach-Object { [IO.Path]::GetFullPath($_.FullName) })
    $additional = @($allExe | Where-Object { -not [string]::Equals($_, $rootExe, [StringComparison]::OrdinalIgnoreCase) })
    $ok = $rootExePresent -and $additional.Count -eq 0
    $reason = if ($ok) { 'ok' } elseif (-not $rootExePresent) { 'root-executable-missing' } else { 'additional-executable' }
    $resolvedExe = if ($ok) { $rootExe } else { $null }
    [pscustomobject]@{
        ok = $ok
        executablePath = $resolvedExe
        rootExecutablePresent = $rootExePresent
        additionalExecutables = $additional
        reason = $reason
    }
}

function Assert-KIWinAppExecutableLayout {
    # Fail-closed wrapper: throws a clear, actionable error for each deviation.
    param([Parameter(Mandatory)][string]$PackageRoot, [string]$ExecutableName = 'winapp.exe')
    $layout = Get-KIWinAppExecutableLayout -PackageRoot $PackageRoot -ExecutableName $ExecutableName
    if ($layout.ok) { return $layout.executablePath }
    switch ($layout.reason) {
        'package-root-missing'    { throw "winapp-Paketverzeichnis fehlt: '$PackageRoot'." }
        'root-executable-missing' { throw "'$ExecutableName' liegt nicht direkt im Paket-Root '$PackageRoot' (fail closed). Verbindlich ist '$([IO.Path]::Combine($PackageRoot, $ExecutableName))'." }
        'additional-executable'   { throw "Zweite '$ExecutableName' im provisionierten winapp-Paket gefunden (fail closed): $($layout.additionalExecutables -join '; '). Es darf genau eine winapp.exe und nur im Paket-Root existieren." }
        default                   { throw "winapp-Paketlayout ist ungueltig ('$($layout.reason)')." }
    }
}

function Get-KIWinAppRequiredFileState {
    # Presence check for the required upstream files (winapp.exe, libSkiaSharp.dll, winapp.pdb).
    # winapp.pdb is deliberately retained -- it is part of the verified official release artifact.
    param([Parameter(Mandatory)][string]$PackageRoot, [string[]]$RequiredFiles)
    $missing = @($RequiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $PackageRoot $_) -PathType Leaf) })
    [pscustomobject]@{ ok = ($missing.Count -eq 0); missing = @($missing) }
}

function ConvertTo-KIWinAppVersion {
    # Pure parser: pulls the first dotted version out of arbitrary `winapp --version` output
    # (e.g. "winapp 0.6.1", "winapp version 0.6.1 (x64)", "0.6.1"). Deterministically unit
    # testable without spawning the binary (same testability discipline as
    # OpenTerminal.psm1's Get-KIOpenTerminalStartArguments).
    param([AllowNull()][string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $clean = ($Raw -replace "`e\[[0-?]*[ -/]*[@-~]", '')
    if ($clean -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    return $null
}

function Get-KIWinAppReportedVersion {
    # Shells out to the resolved executable with --version. Returns $null on any failure
    # (never throws) so callers decide how strict to be.
    param([Parameter(Mandatory)][string]$ExecutablePath, [scriptblock]$ProbeOverride)
    try {
        if ($null -ne $ProbeOverride) { return (ConvertTo-KIWinAppVersion ([string](& $ProbeOverride $ExecutablePath))) }
        $raw = @(& $ExecutablePath --version 2>&1)
        $exit = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        if ($exit -ne 0) { return $null }
        return (ConvertTo-KIWinAppVersion (($raw | ForEach-Object { [string]$_ }) -join "`n"))
    } catch { return $null }
}

# --- Compliance -----------------------------------------------------------------------------

# NOTE ON TEST/INTERNAL SEAMS (see also section 5 of the 2.18 winapp task):
#   -SkipVersionProbe / -VersionProbeOverride / -ArtifactFileOverride / -SourceManifestOverride
#   exist ONLY so this component's own regression suite (Test-KIStackWinApp.ps1) can exercise
#   the real reconcile / integrity / layout / resolver code paths without a real network
#   download and without a runnable winapp.exe. They are NOT exposed by Invoke-KIStackWinApp.ps1,
#   are NOT passed by the Complete Installer, and MUST NOT be surfaced on any later, LLM-facing
#   Desktop-Control interface. A real operator/installer run always downloads from the pinned
#   URL and always runs `winapp.exe --version`.

function Test-KIWinApp {
    # Install-time compliance (Audit/Validate): the winapp package is provisioned under
    # <root>\tools\winapp\current\, its VERSION stamp and marker both read 0.6.1, every
    # extracted file still matches SHA256SUMS.txt, winapp.exe sits EXACTLY at the package root
    # (no second winapp.exe anywhere under current\), and the required upstream files
    # (libSkiaSharp.dll, winapp.pdb) are present. By default it also runs `winapp --version` and
    # requires 0.6.1; -SkipVersionProbe drops ONLY that live check (all structural checks run).
    param(
        [string]$PackageRoot = $PSScriptRoot,
        [string]$TargetRoot = 'C:\KI-Stack',
        [switch]$SkipVersionProbe,
        [scriptblock]$VersionProbeOverride
    )
    $config = Get-KIWinAppConfig -PackageRoot $PackageRoot
    $paths = Get-KIWinAppPaths -TargetRoot $TargetRoot
    $expected = [string]$config.version
    $requiredFiles = @($config.packageLayout.requiredFiles)

    $marker = $null
    if (Test-Path -LiteralPath $paths.marker -PathType Leaf) { try { $marker = Read-KIWinAppJson $paths.marker } catch {} }
    $markerMatches = ($null -ne $marker) -and ([string]$marker.version -eq $expected)

    $stampMatches = $false
    if (Test-Path -LiteralPath $paths.versionStamp -PathType Leaf) {
        try { $stampMatches = ((Get-Content -LiteralPath $paths.versionStamp -Raw).Trim() -eq $expected) } catch {}
    }

    $packagePresent = Test-Path -LiteralPath $paths.packageRoot -PathType Container
    $checksumsOk = $packagePresent -and (Test-KIWinAppChecksums -PackageRoot $paths.packageRoot -ChecksumFile $paths.checksums)

    $layout = if ($packagePresent) { Get-KIWinAppExecutableLayout -PackageRoot $paths.packageRoot -ExecutableName ([string]$config.executableName) } else { [pscustomobject]@{ ok = $false; executablePath = $null; reason = 'package-root-missing'; additionalExecutables = @() } }
    $executablePath = $layout.executablePath
    $layoutOk = [bool]$layout.ok

    $requiredState = if ($packagePresent) { Get-KIWinAppRequiredFileState -PackageRoot $paths.packageRoot -RequiredFiles $requiredFiles } else { [pscustomobject]@{ ok = $false; missing = @($requiredFiles) } }

    $versionProbeOk = $true
    $reportedVersion = $null
    if (-not $SkipVersionProbe -and $layoutOk) {
        $reportedVersion = Get-KIWinAppReportedVersion -ExecutablePath $executablePath -ProbeOverride $VersionProbeOverride
        $versionProbeOk = ($reportedVersion -eq [string]$config.expectedExecutableVersion)
    }

    [pscustomobject]@{
        passed = ($markerMatches -and $stampMatches -and $packagePresent -and $checksumsOk -and $layoutOk -and [bool]$requiredState.ok -and $versionProbeOk)
        componentVersion = if ($null -ne $marker) { [string]$marker.version } else { $null }
        expectedComponentVersion = $expected
        versionStampMatches = $stampMatches
        packagePresent = $packagePresent
        checksumsValid = $checksumsOk
        executableLayoutOk = $layoutOk
        executableLayoutReason = [string]$layout.reason
        additionalExecutables = @($layout.additionalExecutables)
        requiredFilesOk = [bool]$requiredState.ok
        missingRequiredFiles = @($requiredState.missing)
        executablePath = $executablePath
        versionProbeSkipped = [bool]$SkipVersionProbe
        reportedExecutableVersion = $reportedVersion
        paths = $paths
        mutatesTarget = $false
    }
}

function Get-KIWinAppStatus {
    # Read-only. Never downloads, never runs the binary beyond a single --version probe.
    param([string]$PackageRoot = $PSScriptRoot, [string]$TargetRoot = 'C:\KI-Stack', [switch]$SkipVersionProbe)
    $compliance = Test-KIWinApp -PackageRoot $PackageRoot -TargetRoot $TargetRoot -SkipVersionProbe:$SkipVersionProbe
    $state = if ($compliance.passed) { 'Provisioned' } elseif ($compliance.packagePresent) { 'Degraded' } else { 'NotProvisioned' }
    [pscustomobject][ordered]@{
        passed = $true
        state = $state
        installRoot = $compliance.paths.installRoot
        packageRoot = $compliance.paths.packageRoot
        executablePath = $compliance.executablePath
        componentVersion = $compliance.componentVersion
        reportedExecutableVersion = $compliance.reportedExecutableVersion
        checksumsValid = $compliance.checksumsValid
        mutatesTarget = $false
    }
}

# --- Backup / rollback (Install-KIOpenTerminal shape) ----------------------------------------

function Copy-KIWinAppBackupItem {
    param([string]$Path, [string]$BackupRoot, [string]$Name)
    $entry = [ordered]@{ path = $Path; name = $Name; existed = (Test-Path -LiteralPath $Path); isDirectory = (Test-Path -LiteralPath $Path -PathType Container) }
    if ($entry.existed) { Copy-Item -LiteralPath $Path -Destination (Join-Path $BackupRoot $Name) -Recurse:$entry.isDirectory -Force }
    $entry
}

function Restore-KIWinAppBackup {
    param([Parameter(Mandatory)][string]$BackupPath)
    $backup = Read-KIWinAppJson $BackupPath
    $backupRoot = Split-Path -Parent $BackupPath
    foreach ($entry in @($backup.items)) {
        $path = [string]$entry.path
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        if ([bool]$entry.existed) {
            $parent = Split-Path -Parent $path
            New-KIWinAppDirectory $parent
            Copy-Item -LiteralPath (Join-Path $backupRoot ([string]$entry.name)) -Destination $path -Recurse:([bool]$entry.isDirectory) -Force
        }
    }
    [pscustomobject]@{ passed = $true; status = 'Completed'; backupPath = $BackupPath }
}

# --- Provisioning (Install / Upgrade / Repair reconcile) -------------------------------------

function Install-KIWinApp {
    # Serves Install, Upgrade and Repair alike: the same reconcile-to-source-contract-version
    # discipline codex-local / open-terminal establish. A same-version re-run with an intact,
    # checksum-verified package is a safe no-op via SkippedAlreadyCompliant. A missing or
    # corrupt package is re-acquired (from the pinned URL, integrity-checked) and re-extracted.
    param(
        [string]$PackageRoot = $PSScriptRoot,
        [string]$TargetRoot,
        [ValidateSet('Install', 'Upgrade', 'Repair')][string]$Action = 'Install',
        [switch]$DryRun,
        [switch]$SkipVersionProbe,
        # Test-only seam: a locally-staged winappcli-x64.zip to verify+extract in place of a
        # real network download. Size+SHA256 still verified against the (possibly overridden)
        # source manifest. Never used by any real caller.
        [string]$ArtifactFileOverride = '',
        [object]$SourceManifestOverride = $null,
        [scriptblock]$VersionProbeOverride
    )
    $config = Get-KIWinAppConfig -PackageRoot $PackageRoot
    if ([string]::IsNullOrWhiteSpace($TargetRoot)) { $TargetRoot = [string]$config.targetRoot }
    $sourceManifest = if ($null -ne $SourceManifestOverride) { $SourceManifestOverride } else { Get-KIWinAppSourceManifest -PackageRoot $PackageRoot }
    $paths = Get-KIWinAppPaths -TargetRoot $TargetRoot

    if ([string]$sourceManifest.version -ne [string]$config.version) {
        throw "winapp-Quellvertrag ($($sourceManifest.version)) und Komponenten-Config ($($config.version)) sind nicht deckungsgleich."
    }

    if ($DryRun) {
        return [pscustomobject]@{
            passed = $true; status = 'DryRun'; action = $Action
            plan = [pscustomobject]@{ installRoot = $paths.installRoot; packageRoot = $paths.packageRoot; pinnedUrl = (Assert-KIWinAppPinnedSource -Artifact $sourceManifest.artifact) }
            mutatesTarget = $false
        }
    }

    $existing = Test-KIWinApp -PackageRoot $PackageRoot -TargetRoot $TargetRoot -SkipVersionProbe:$SkipVersionProbe -VersionProbeOverride $VersionProbeOverride
    if ($existing.passed) {
        return [pscustomobject]@{ passed = $true; status = 'SkippedAlreadyCompliant'; action = $Action; marker = (Read-KIWinAppJson $paths.marker); mutatesTarget = $false }
    }

    New-KIWinAppDirectory $paths.installRoot
    New-KIWinAppDirectory $paths.stateRoot
    $backupRoot = Join-Path $TargetRoot ('backups/winapp/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff'))
    New-KIWinAppDirectory $backupRoot
    $items = @()
    foreach ($definition in @(
        @{ path = $paths.marker; name = 'installation.json' },
        @{ path = $paths.versionStamp; name = 'VERSION' },
        @{ path = $paths.checksums; name = 'SHA256SUMS.txt' }
    )) { $items += @(Copy-KIWinAppBackupItem -Path $definition.path -BackupRoot $backupRoot -Name $definition.name) }
    $backupPath = Join-Path $backupRoot 'rollback.json'
    Write-KIWinAppJson $backupPath ([ordered]@{ schemaVersion = '1.0'; createdAtUtc = [DateTime]::UtcNow.ToString('o'); targetRoot = $TargetRoot; items = $items })

    try {
        $artifact = Get-KIWinAppArtifact -Artifact $sourceManifest.artifact -CacheRoot $paths.downloadCache `
            -TimeoutSeconds ([int]$config.download.timeoutSeconds) -UserAgent ([string]$config.download.userAgent) -ArtifactFileOverride $ArtifactFileOverride

        $extracted = Expand-KIWinAppArtifact -ArtifactPath $artifact.path -Destination $paths.packageRoot

        # Hardened layout gate: exactly one winapp.exe, directly at the package root, plus the
        # required upstream files -- any deviation fails closed here (rollback below).
        $executablePath = Assert-KIWinAppExecutableLayout -PackageRoot $paths.packageRoot -ExecutableName ([string]$config.executableName)
        $requiredFiles = @($config.packageLayout.requiredFiles)
        $requiredState = Get-KIWinAppRequiredFileState -PackageRoot $paths.packageRoot -RequiredFiles $requiredFiles
        if (-not [bool]$requiredState.ok) {
            throw "Im entpackten winapp-Paket fehlen erwartete Upstream-Dateien (fail closed): $($requiredState.missing -join ', ')."
        }

        if (-not $SkipVersionProbe) {
            $reported = Get-KIWinAppReportedVersion -ExecutablePath $executablePath -ProbeOverride $VersionProbeOverride
            if ($reported -ne [string]$config.expectedExecutableVersion) {
                throw "winapp meldet Version '$reported', erwartet wurde '$($config.expectedExecutableVersion)'."
            }
        }

        $checksumLines = New-KIWinAppChecksums -PackageRoot $paths.packageRoot -ChecksumFile $paths.checksums
        Set-Content -LiteralPath $paths.versionStamp -Value ([string]$config.version) -Encoding ascii -NoNewline

        $relativeExecutable = [IO.Path]::GetRelativePath($paths.packageRoot, $executablePath).Replace('\', '/')
        $marker = [ordered]@{
            schemaVersion = '1.0'
            version = [string]$config.version
            tool = 'winapp'
            upstreamReleaseTag = [string]$sourceManifest.upstream.releaseTag
            artifactSha256 = [string]$sourceManifest.artifact.sha256
            artifactSizeBytes = [long]$sourceManifest.artifact.sizeBytes
            upstreamSourceRevision = [string]$sourceManifest.upstream.sourceRevision
            resolvedExecutable = $relativeExecutable
            requiredFiles = @($requiredFiles)
            extractedFileCount = @($extracted).Count
            installedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-KIWinAppJson $paths.marker $marker

        $readback = Test-KIWinApp -PackageRoot $PackageRoot -TargetRoot $TargetRoot -SkipVersionProbe:$SkipVersionProbe -VersionProbeOverride $VersionProbeOverride
        if (-not $readback.passed) { throw 'winapp-Readback nach der Provisionierung ist fehlgeschlagen.' }

        $resultStatus = switch ($Action) { 'Upgrade' { 'Upgraded' }; 'Repair' { 'Repaired' }; default { 'Installed' } }
        [pscustomobject]@{
            passed = $true; status = $resultStatus; action = $Action; marker = $marker
            artifactSource = $artifact.source; extractedFiles = @($extracted); checksumCount = @($checksumLines).Count
            backupPath = $backupPath; readback = $readback; mutatesTarget = $true
        }
    } catch {
        $rollbackStatus = 'Failed'
        try { $rollback = Restore-KIWinAppBackup -BackupPath $backupPath; $rollbackStatus = [string]$rollback.status } catch {}
        # On a fresh (no prior marker) failure, also clear a half-extracted package tree so the
        # target is never left in a partially-provisioned state.
        if (-not (Test-Path -LiteralPath $paths.marker -PathType Leaf) -and (Test-Path -LiteralPath $paths.packageRoot)) {
            Remove-Item -LiteralPath $paths.packageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        $_.Exception.Data['KIStackRollbackStatus'] = $rollbackStatus
        $_.Exception.Data['KIStackBackupPath'] = $backupPath
        throw
    }
}

function Restore-KIWinApp {
    param([Parameter(Mandatory)][string]$BackupPath, [string]$PackageRoot = $PSScriptRoot, [string]$TargetRoot = 'C:\KI-Stack')
    Restore-KIWinAppBackup -BackupPath $BackupPath
}

Export-ModuleMember -Function *

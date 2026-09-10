[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Focused regression suite for the WinApp provisioning component (WinApp.psm1) and the
# production resolver contract (WinApp.Resolver.psm1). No network access and no runnable
# winapp.exe are required: acquisition is exercised against a locally-staged fake winappcli ZIP
# via the documented internal test seams (-ArtifactFileOverride / -SourceManifestOverride), and
# the live `winapp --version` probe is injected via -VersionProbeOverride. NO GUI automation,
# NO application launch.
#
# The fake package mirrors the now real-verified upstream x64 layout: exactly one winapp.exe,
# directly at the package root, next to libSkiaSharp.dll and winapp.pdb.

Import-Module (Join-Path $PackageRoot 'WinApp.psm1') -Force
Import-Module (Join-Path $PackageRoot 'WinApp.Resolver.psm1') -Force

$fail = [Collections.Generic.List[string]]::new()
$checks = [ordered]@{}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('KIWinApp-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null

function New-KIWinAppTestRoot {
    param([string]$Name)
    $root = Join-Path $scratch $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $root
}

# Fake winappcli-x64.zip. Default layout matches the verified upstream one. Switches let a test
# deliberately break it (executable only in a subdirectory, or a second winapp.exe).
function New-KIWinAppFakeArtifact {
    param(
        [string]$Label = 'ok',
        [switch]$ExecutableOnlyInSubdir,
        [switch]$SecondExecutableInSubdir,
        [switch]$OmitLibSkiaSharp,
        [switch]$OmitPdb
    )
    $stage = Join-Path $scratch ("artifact-src-$Label-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    if ($ExecutableOnlyInSubdir) {
        New-Item -ItemType Directory -Path (Join-Path $stage 'bin') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $stage 'bin/winapp.exe') -Value 'fake-winapp-cli' -Encoding ascii -NoNewline
    } else {
        Set-Content -LiteralPath (Join-Path $stage 'winapp.exe') -Value 'fake-winapp-cli' -Encoding ascii -NoNewline
        if ($SecondExecutableInSubdir) {
            New-Item -ItemType Directory -Path (Join-Path $stage 'extra') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $stage 'extra/winapp.exe') -Value 'fake-winapp-cli-copy' -Encoding ascii -NoNewline
        }
    }
    if (-not $OmitLibSkiaSharp) { Set-Content -LiteralPath (Join-Path $stage 'libSkiaSharp.dll') -Value 'fake-skia' -Encoding ascii -NoNewline }
    if (-not $OmitPdb) { Set-Content -LiteralPath (Join-Path $stage 'winapp.pdb') -Value 'fake-symbols' -Encoding ascii -NoNewline }
    Set-Content -LiteralPath (Join-Path $stage 'LICENSE.txt') -Value 'fake-license' -Encoding ascii -NoNewline
    $zip = Join-Path $scratch ("winappcli-x64-$Label-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.zip')
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
    [pscustomobject]@{
        path = $zip
        sizeBytes = (Get-Item -LiteralPath $zip).Length
        sha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function New-KIWinAppOverrideManifest {
    param([Parameter(Mandatory)][object]$Artifact, [string]$Version = '0.6.1', [string]$Sha256Override)
    [pscustomobject]@{
        schemaVersion = '1.0'
        tool = 'winapp'
        version = $Version
        upstream = [pscustomobject]@{ project = 'microsoft/winappCli'; releaseTag = "v$Version"; sourceRevision = ('0' * 40) }
        artifact = [pscustomobject]@{
            id = 'winappcli-x64'
            fileName = 'winappcli-x64.zip'
            archiveKind = 'zip'
            sizeBytes = [long]$Artifact.sizeBytes
            sha256 = if ($PSBoundParameters.ContainsKey('Sha256Override')) { $Sha256Override } else { [string]$Artifact.sha256 }
            sources = @("https://github.com/microsoft/winappCli/releases/download/v$Version/winappcli-x64.zip")
            expectedExecutable = 'winapp.exe'
            expectedExecutableVersion = $Version
        }
    }
}

$probe061 = { param($exe) 'winapp 0.6.1 (x64)' }

# Provision a fixture target with a valid fake package, returning its Get-KIWinAppPaths object.
function Install-KIWinAppFixture {
    param([Parameter(Mandatory)][string]$TargetRoot, [object]$Artifact, [object]$Override)
    if ($null -eq $Artifact) { $Artifact = New-KIWinAppFakeArtifact -Label ([guid]::NewGuid().ToString('N').Substring(0, 4)) }
    if ($null -eq $Override) { $Override = New-KIWinAppOverrideManifest -Artifact $Artifact }
    Install-KIWinApp -PackageRoot $PackageRoot -TargetRoot $TargetRoot -Action 'Install' -ArtifactFileOverride $Artifact.path -SourceManifestOverride $Override -VersionProbeOverride $probe061 | Out-Null
    Get-KIWinAppPaths -TargetRoot $TargetRoot
}

try {
    # === 1: static version + supply-chain contract + verified layout =========================
    $config = Get-KIWinAppConfig -PackageRoot $PackageRoot
    $sourceManifest = Get-KIWinAppSourceManifest -PackageRoot $PackageRoot
    $manifest = Get-Content -LiteralPath (Join-Path $PackageRoot 'MANIFEST.json') -Raw | ConvertFrom-Json
    $versionFile = (Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim()
    $sources = @($sourceManifest.artifact.sources)
    $verifiedLayout = $sourceManifest.artifact.verifiedPackageLayout
    $verifiedFiles = @($verifiedLayout.files)
    $checks.staticContract = [ordered]@{
        versionFileIs061 = ($versionFile -eq '0.6.1')
        manifestVersionIs061 = ([string]$manifest.version -eq '0.6.1')
        configVersionIs061 = ([string]$config.version -eq '0.6.1')
        sourceManifestVersionIs061 = ([string]$sourceManifest.version -eq '0.6.1')
        expectedExecutableVersionIs061 = ([string]$sourceManifest.artifact.expectedExecutableVersion -eq '0.6.1')
        exactlyOnePinnedSource = ($sources.Count -eq 1)
        pinnedVersionedHttpsUrl = ([string]$sources[0] -match '^https://github\.com/microsoft/winappCli/releases/download/v0\.6\.1/winappcli-x64\.zip$')
        sha256Is64Hex = ([string]$sourceManifest.artifact.sha256 -match '^[0-9a-f]{64}$')
        sizeBytesExact = ([long]$sourceManifest.artifact.sizeBytes -eq 46673152)
        sha256Exact = ([string]$sourceManifest.artifact.sha256 -eq '11c03be2d356d6f910649cecce912a9bc6a0814dc4f2e9ae14e379a8cf470f01')
        releaseTagPinned = ([string]$sourceManifest.upstream.releaseTag -eq 'v0.6.1')
        sourceRevisionPinned = ([string]$sourceManifest.upstream.sourceRevision -eq 'd9a8d0f8ef192fa3ce07febdbe178606ea5fb4f5')
        noVendoredBinary = (-not [bool]$manifest.vendoredBinary)
        assertPinnedSourceAccepts = ((Assert-KIWinAppPinnedSource -Artifact $sourceManifest.artifact) -eq [string]$sources[0])
        verifiedLayoutExecutableAtRoot = ([bool]$verifiedLayout.executableMustBeAtPackageRoot)
        verifiedLayoutForbidsSecondExe = ([bool]$verifiedLayout.additionalWinappExeForbidden)
        verifiedFilesWinappExe = (@($verifiedFiles | Where-Object { $_.path -eq 'winapp.exe' -and [long]$_.sizeBytes -eq 31485312 }).Count -eq 1)
        verifiedFilesLibSkiaSharp = (@($verifiedFiles | Where-Object { $_.path -eq 'libSkiaSharp.dll' -and [long]$_.sizeBytes -eq 9414216 }).Count -eq 1)
        verifiedFilesPdb = (@($verifiedFiles | Where-Object { $_.path -eq 'winapp.pdb' -and [long]$_.sizeBytes -eq 147656704 }).Count -eq 1)
        requiredFilesInConfig = ((@($config.packageLayout.requiredFiles) -join '|') -eq 'winapp.exe|libSkiaSharp.dll|winapp.pdb')
    }
    if ($checks.staticContract.Values -contains $false) { $fail.Add('staticContract: ' + ($checks.staticContract | ConvertTo-Json -Compress)) }

    # === 2: pure version parser ============================================================
    $checks.versionParser = [ordered]@{
        plain = ((ConvertTo-KIWinAppVersion '0.6.1') -eq '0.6.1')
        prefixed = ((ConvertTo-KIWinAppVersion 'winapp 0.6.1') -eq '0.6.1')
        verbose = ((ConvertTo-KIWinAppVersion 'winapp version 0.6.1 (x64)') -eq '0.6.1')
        wrong = ((ConvertTo-KIWinAppVersion 'winapp 0.5.0') -eq '0.5.0')
        empty = ($null -eq (ConvertTo-KIWinAppVersion ''))
    }
    if ($checks.versionParser.Values -contains $false) { $fail.Add('versionParser: ' + ($checks.versionParser | ConvertTo-Json -Compress)) }

    # === 3: Install provisions to <root>\tools\winapp\ with the exact hardened layout =======
    $rootA = New-KIWinAppTestRoot 'rootA'
    $artA = New-KIWinAppFakeArtifact -Label 'A'
    $ovA = New-KIWinAppOverrideManifest -Artifact $artA
    $installA = Install-KIWinApp -PackageRoot $PackageRoot -TargetRoot $rootA -Action 'Install' -ArtifactFileOverride $artA.path -SourceManifestOverride $ovA -VersionProbeOverride $probe061
    $pathsA = Get-KIWinAppPaths -TargetRoot $rootA
    $checks.install = [ordered]@{
        statusInstalled = ([string]$installA.status -eq 'Installed')
        installRootUnderTools = ($pathsA.installRoot -eq (Join-Path ([IO.Path]::GetFullPath($rootA)) 'tools\winapp'))
        packageRootExists = (Test-Path -LiteralPath $pathsA.packageRoot -PathType Container)
        versionStampAtToolsWinappVersion = ((Get-Content -LiteralPath (Join-Path $rootA 'tools\winapp\VERSION') -Raw).Trim() -eq '0.6.1')
        markerVersion061 = ([string]$installA.marker.version -eq '0.6.1')
        markerResolvedExecutableIsRoot = ([string]$installA.marker.resolvedExecutable -eq 'winapp.exe')
        exeExactlyAtPackageRoot = (Test-Path -LiteralPath (Join-Path $pathsA.packageRoot 'winapp.exe') -PathType Leaf)
        libSkiaSharpPresent = (Test-Path -LiteralPath (Join-Path $pathsA.packageRoot 'libSkiaSharp.dll') -PathType Leaf)
        pdbPresent = (Test-Path -LiteralPath (Join-Path $pathsA.packageRoot 'winapp.pdb') -PathType Leaf)
        pdbNotStripped = ((Get-Content -LiteralPath $pathsA.checksums) -match 'winapp\.pdb').Count -ge 1
        fullPackageExtracted = (@(Get-ChildItem -LiteralPath $pathsA.packageRoot -Recurse -File).Count -ge 4)
        checksumsFileCoversAllFiles = (Test-KIWinAppChecksums -PackageRoot $pathsA.packageRoot -ChecksumFile $pathsA.checksums)
        exactlyOneWinappExe = (@(Get-ChildItem -LiteralPath $pathsA.packageRoot -Recurse -File -Filter 'winapp.exe').Count -eq 1)
        mutatesTarget = ([bool]$installA.mutatesTarget)
    }
    if ($checks.install.Values -contains $false) { $fail.Add('install: ' + ($checks.install | ConvertTo-Json -Compress)) }

    # === 4: idempotent reconcile ==========================================================
    $installA2 = Install-KIWinApp -PackageRoot $PackageRoot -TargetRoot $rootA -Action 'Repair' -ArtifactFileOverride $artA.path -SourceManifestOverride $ovA -VersionProbeOverride $probe061
    $checks.idempotentReconcile = [ordered]@{
        skippedAlreadyCompliant = ([string]$installA2.status -eq 'SkippedAlreadyCompliant')
        noMutation = (-not [bool]$installA2.mutatesTarget)
        auditStillPasses = ([bool](Test-KIWinApp -PackageRoot $PackageRoot -TargetRoot $rootA -VersionProbeOverride $probe061).passed)
    }
    if ($checks.idempotentReconcile.Values -contains $false) { $fail.Add('idempotentReconcile: ' + ($checks.idempotentReconcile | ConvertTo-Json -Compress)) }

    # === 5: resolver -- central-path production resolution, exact winapp.exe ================
    $resolvedA = Resolve-KIStackWinApp -KIStackRoot $rootA -VersionProbeOverride $probe061
    $expectedExeA = Join-Path ([IO.Path]::GetFullPath($rootA)) 'tools\winapp\current\winapp.exe'
    $checks.resolverCentral = [ordered]@{
        resolved = ([bool]$resolvedA.resolved)
        methodCentral = ([string]$resolvedA.resolutionMethod -eq 'central-kistack-tools')
        executableIsExactBindingPath = ([string]$resolvedA.executablePath -eq $expectedExeA)
        reportedVersion061 = ([string]$resolvedA.reportedExecutableVersion -eq '0.6.1')
        version061 = ([string]$resolvedA.version -eq '0.6.1')
    }
    if ($checks.resolverCentral.Values -contains $false) { $fail.Add('resolverCentral: ' + ($checks.resolverCentral | ConvertTo-Json -Compress)) }

    # === 6: resolver -- missing installation -> clear error ===============================
    $rootEmpty = New-KIWinAppTestRoot 'rootEmpty'
    $missingThrew = $false; $missingMessage = ''
    try { Resolve-KIStackWinApp -KIStackRoot $rootEmpty -VersionProbeOverride $probe061 | Out-Null }
    catch { $missingThrew = $true; $missingMessage = [string]$_.Exception.Message }
    $checks.missingInstallation = [ordered]@{
        threw = $missingThrew
        mentionsNotProvisioned = ($missingMessage -match '(?i)nicht zentral provisioniert')
        mentionsReconcile = ($missingMessage -match '(?i)Reconcile|Complete Installer')
    }
    if ($checks.missingInstallation.Values -contains $false) { $fail.Add('missingInstallation: ' + ($checks.missingInstallation | ConvertTo-Json -Compress)) }

    # === 7: resolver -- wrong provisioned version -> clear error ==========================
    $rootC = New-KIWinAppTestRoot 'rootC'
    $pathsC = Install-KIWinAppFixture -TargetRoot $rootC
    Set-Content -LiteralPath $pathsC.versionStamp -Value '0.5.0' -Encoding ascii -NoNewline
    $wrongThrew = $false; $wrongMessage = ''
    try { Resolve-KIStackWinApp -KIStackRoot $rootC -VersionProbeOverride $probe061 | Out-Null }
    catch { $wrongThrew = $true; $wrongMessage = [string]$_.Exception.Message }
    $checks.wrongVersion = [ordered]@{
        threw = $wrongThrew
        mentionsFalscheVersion = ($wrongMessage -match "(?i)falsche Version" -and $wrongMessage -match "'0\.5\.0'")
        auditAlsoFails = (-not [bool](Test-KIWinApp -PackageRoot $PackageRoot -TargetRoot $rootC -VersionProbeOverride $probe061).passed)
    }
    if ($checks.wrongVersion.Values -contains $false) { $fail.Add('wrongVersion: ' + ($checks.wrongVersion | ConvertTo-Json -Compress)) }

    # === 8: resolver -- tampered package (checksum mismatch) -> integrity error ===========
    $rootTamper = New-KIWinAppTestRoot 'rootTamper'
    $pathsT = Install-KIWinAppFixture -TargetRoot $rootTamper
    Add-Content -LiteralPath (Join-Path $pathsT.packageRoot 'libSkiaSharp.dll') -Value 'tampered'
    $tamperThrew = $false; $tamperMessage = ''
    try { Resolve-KIStackWinApp -KIStackRoot $rootTamper -VersionProbeOverride $probe061 | Out-Null }
    catch { $tamperThrew = $true; $tamperMessage = [string]$_.Exception.Message }
    $checks.tamperedPackage = [ordered]@{
        threw = $tamperThrew
        mentionsIntegrity = ($tamperMessage -match '(?i)Paketintegrit')
        auditAlsoFails = (-not [bool](Test-KIWinApp -PackageRoot $PackageRoot -TargetRoot $rootTamper -VersionProbeOverride $probe061).passed)
    }
    if ($checks.tamperedPackage.Values -contains $false) { $fail.Add('tamperedPackage: ' + ($checks.tamperedPackage | ConvertTo-Json -Compress)) }

    # === 9: alternative KIStackRoot -- isolated provisioning + resolution =================
    $rootD = New-KIWinAppTestRoot 'rootD'
    $pathsD = Install-KIWinAppFixture -TargetRoot $rootD
    $resolvedD = Resolve-KIStackWinApp -KIStackRoot $rootD -VersionProbeOverride $probe061
    $checks.alternativeRoot = [ordered]@{
        resolvedFromRootD = ([bool]$resolvedD.resolved -and ([string]$resolvedD.executablePath -eq (Join-Path ([IO.Path]::GetFullPath($rootD)) 'tools\winapp\current\winapp.exe')))
        rootAStillIndependentlyResolves = ([string](Resolve-KIStackWinApp -KIStackRoot $rootA -VersionProbeOverride $probe061).executablePath -eq $expectedExeA)
        noHardcodedCDriveRoot = ($pathsD.installRoot -ne $pathsA.installRoot -and $pathsD.installRoot.StartsWith([IO.Path]::GetFullPath($rootD), [StringComparison]::OrdinalIgnoreCase))
    }
    if ($checks.alternativeRoot.Values -contains $false) { $fail.Add('alternativeRoot: ' + ($checks.alternativeRoot | ConvertTo-Json -Compress)) }

    # === 10: NO production dependency on user PATH / WindowsApps / WinGet =================
    $decoyLocalAppData = New-KIWinAppTestRoot 'decoyLocalAppData'
    New-Item -ItemType Directory -Path (Join-Path $decoyLocalAppData 'Microsoft\WindowsApps') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $decoyLocalAppData 'Microsoft\WindowsApps\winapp.exe') -Value 'DECOY' -Encoding ascii -NoNewline
    $savedPath = $env:PATH; $savedLocalAppData = $env:LOCALAPPDATA
    $prodIgnoresDecoyThrew = $false
    try {
        $env:PATH = ''
        $env:LOCALAPPDATA = $decoyLocalAppData
        try { Resolve-KIStackWinApp -KIStackRoot $rootEmpty -VersionProbeOverride $probe061 | Out-Null }
        catch { $prodIgnoresDecoyThrew = $true }
        $devFallback = Resolve-KIStackWinApp -KIStackRoot $rootEmpty -VersionProbeOverride $probe061 -AllowDevelopmentFallback
    } finally {
        $env:PATH = $savedPath
        $env:LOCALAPPDATA = $savedLocalAppData
    }
    $resolverSource = Get-Content -LiteralPath (Join-Path $PackageRoot 'WinApp.Resolver.psm1') -Raw
    $fallbackFnBody = ($resolverSource -split 'function Resolve-KIStackWinAppDevelopmentFallback', 2)[1]
    $mainFnBody = (($resolverSource -split 'function Resolve-KIStackWinApp ', 2)[1] -split 'function Resolve-KIStackWinAppDevelopmentFallback', 2)[0]
    $dispatcherSource = Get-Content -LiteralPath (Join-Path $PackageRoot 'Invoke-KIStackWinApp.ps1') -Raw
    $dispatcherParamBlock = ($dispatcherSource -split '\)\s*\r?\n', 2)[0]
    $checks.noUserPathDependency = [ordered]@{
        productionIgnoresDecoyAndThrows = $prodIgnoresDecoyThrew
        developmentFallbackFindsDecoy = ([bool]$devFallback.resolved -and [string]$devFallback.resolutionMethod -eq 'development-fallback')
        fallbackLookupsOnlyInGatedFunction = (
            ($mainFnBody -notmatch 'Microsoft\\WindowsApps') -and ($mainFnBody -notmatch 'where\.exe winapp') -and
            ($mainFnBody -notmatch 'Get-Command \$name') -and
            ($fallbackFnBody -match 'Microsoft\\WindowsApps') -and ($fallbackFnBody -match 'where\.exe winapp')
        )
        dispatcherExposesNoSeams = (
            ($dispatcherParamBlock -notmatch 'SkipVersionProbe') -and ($dispatcherParamBlock -notmatch 'SkipChecksumVerification') -and
            ($dispatcherParamBlock -notmatch 'AllowDevelopmentFallback') -and ($dispatcherParamBlock -notmatch 'ArtifactFileOverride') -and
            ($dispatcherParamBlock -notmatch 'SourceManifestOverride') -and ($dispatcherParamBlock -notmatch 'VersionProbeOverride')
        )
    }
    if ($checks.noUserPathDependency.Values -contains $false) { $fail.Add('noUserPathDependency: ' + ($checks.noUserPathDependency | ConvertTo-Json -Compress)) }

    # === 11: acquisition fails closed on a SHA256 mismatch (no partial provisioning) ======
    $rootBad = New-KIWinAppTestRoot 'rootBad'
    $artBad = New-KIWinAppFakeArtifact -Label 'Bad'
    $ovBad = New-KIWinAppOverrideManifest -Artifact $artBad -Sha256Override ('a' * 64)
    $badThrew = $false; $badMessage = ''
    try { Install-KIWinApp -PackageRoot $PackageRoot -TargetRoot $rootBad -Action 'Install' -ArtifactFileOverride $artBad.path -SourceManifestOverride $ovBad -VersionProbeOverride $probe061 | Out-Null }
    catch { $badThrew = $true; $badMessage = [string]$_.Exception.Message }
    $pathsBad = Get-KIWinAppPaths -TargetRoot $rootBad
    $checks.acquisitionFailsClosed = [ordered]@{
        threw = $badThrew
        mentionsSha256 = ($badMessage -match '(?i)SHA256')
        noMarkerWritten = (-not (Test-Path -LiteralPath $pathsBad.marker -PathType Leaf))
        noPackageLeftBehind = (-not (Test-Path -LiteralPath $pathsBad.packageRoot -PathType Container))
        cachedArtifactRejected = (-not (Test-Path -LiteralPath (Join-Path $pathsBad.downloadCache 'winappcli-x64.zip') -PathType Leaf))
    }
    if ($checks.acquisitionFailsClosed.Values -contains $false) { $fail.Add('acquisitionFailsClosed: ' + ($checks.acquisitionFailsClosed | ConvertTo-Json -Compress)) }

    # === 12: hardened layout -- winapp.exe MUST be exactly at the package root =============
    #        (a) resolver: winapp.exe only in a subdirectory -> fail closed
    $rootSub = New-KIWinAppTestRoot 'rootSub'
    $pathsSub = Install-KIWinAppFixture -TargetRoot $rootSub
    New-Item -ItemType Directory -Path (Join-Path $pathsSub.packageRoot 'bin') -Force | Out-Null
    Move-Item -LiteralPath (Join-Path $pathsSub.packageRoot 'winapp.exe') -Destination (Join-Path $pathsSub.packageRoot 'bin\winapp.exe') -Force
    New-KIWinAppChecksums -PackageRoot $pathsSub.packageRoot -ChecksumFile $pathsSub.checksums | Out-Null
    $subThrew = $false; $subMessage = ''
    try { Resolve-KIStackWinApp -KIStackRoot $rootSub -VersionProbeOverride $probe061 | Out-Null }
    catch { $subThrew = $true; $subMessage = [string]$_.Exception.Message }

    #        (b) resolver: a SECOND winapp.exe under a subdirectory -> fail closed
    $rootDup = New-KIWinAppTestRoot 'rootDup'
    $pathsDup = Install-KIWinAppFixture -TargetRoot $rootDup
    New-Item -ItemType Directory -Path (Join-Path $pathsDup.packageRoot 'extra') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $pathsDup.packageRoot 'winapp.exe') -Destination (Join-Path $pathsDup.packageRoot 'extra\winapp.exe') -Force
    New-KIWinAppChecksums -PackageRoot $pathsDup.packageRoot -ChecksumFile $pathsDup.checksums | Out-Null
    $dupThrew = $false; $dupMessage = ''
    try { Resolve-KIStackWinApp -KIStackRoot $rootDup -VersionProbeOverride $probe061 | Out-Null }
    catch { $dupThrew = $true; $dupMessage = [string]$_.Exception.Message }

    #        (c) install: an upstream ZIP with winapp.exe only in a subdirectory -> fail closed
    $rootBadZipSub = New-KIWinAppTestRoot 'rootBadZipSub'
    $artSub = New-KIWinAppFakeArtifact -Label 'Sub' -ExecutableOnlyInSubdir
    $badSubThrew = $false; $badSubMessage = ''
    try { Install-KIWinApp -PackageRoot $PackageRoot -TargetRoot $rootBadZipSub -Action 'Install' -ArtifactFileOverride $artSub.path -SourceManifestOverride (New-KIWinAppOverrideManifest -Artifact $artSub) -VersionProbeOverride $probe061 | Out-Null }
    catch { $badSubThrew = $true; $badSubMessage = [string]$_.Exception.Message }

    #        (d) install: an upstream ZIP with a SECOND winapp.exe -> fail closed
    $rootBadZipDup = New-KIWinAppTestRoot 'rootBadZipDup'
    $artDup = New-KIWinAppFakeArtifact -Label 'Dup' -SecondExecutableInSubdir
    $badDupThrew = $false; $badDupMessage = ''
    try { Install-KIWinApp -PackageRoot $PackageRoot -TargetRoot $rootBadZipDup -Action 'Install' -ArtifactFileOverride $artDup.path -SourceManifestOverride (New-KIWinAppOverrideManifest -Artifact $artDup) -VersionProbeOverride $probe061 | Out-Null }
    catch { $badDupThrew = $true; $badDupMessage = [string]$_.Exception.Message }

    $checks.hardenedExecutableLayout = [ordered]@{
        resolverRejectsExeOnlyInSubdir = ($subThrew -and $subMessage -match '(?i)nicht direkt im Paket-Root')
        resolverRejectsSecondExe = ($dupThrew -and $dupMessage -match "(?i)Zweite 'winapp.exe'")
        installRejectsExeOnlyInSubdir = ($badSubThrew -and $badSubMessage -match '(?i)nicht direkt im Paket-Root' -and -not (Test-Path -LiteralPath (Get-KIWinAppPaths -TargetRoot $rootBadZipSub).marker))
        installRejectsSecondExe = ($badDupThrew -and $badDupMessage -match "(?i)Zweite 'winapp.exe'" -and -not (Test-Path -LiteralPath (Get-KIWinAppPaths -TargetRoot $rootBadZipDup).marker))
    }
    if ($checks.hardenedExecutableLayout.Values -contains $false) { $fail.Add('hardenedExecutableLayout: ' + ($checks.hardenedExecutableLayout | ConvertTo-Json -Compress)) }

    # === 13: required upstream files -- libSkiaSharp.dll and winapp.pdb ====================
    $rootNoSkia = New-KIWinAppTestRoot 'rootNoSkia'
    $pathsNoSkia = Install-KIWinAppFixture -TargetRoot $rootNoSkia
    Remove-Item -LiteralPath (Join-Path $pathsNoSkia.packageRoot 'libSkiaSharp.dll') -Force
    New-KIWinAppChecksums -PackageRoot $pathsNoSkia.packageRoot -ChecksumFile $pathsNoSkia.checksums | Out-Null
    $noSkiaThrew = $false; $noSkiaMessage = ''
    try { Resolve-KIStackWinApp -KIStackRoot $rootNoSkia -VersionProbeOverride $probe061 | Out-Null }
    catch { $noSkiaThrew = $true; $noSkiaMessage = [string]$_.Exception.Message }

    $rootNoPdb = New-KIWinAppTestRoot 'rootNoPdb'
    $pathsNoPdb = Install-KIWinAppFixture -TargetRoot $rootNoPdb
    Remove-Item -LiteralPath (Join-Path $pathsNoPdb.packageRoot 'winapp.pdb') -Force
    New-KIWinAppChecksums -PackageRoot $pathsNoPdb.packageRoot -ChecksumFile $pathsNoPdb.checksums | Out-Null
    $noPdbThrew = $false; $noPdbMessage = ''
    try { Resolve-KIStackWinApp -KIStackRoot $rootNoPdb -VersionProbeOverride $probe061 | Out-Null }
    catch { $noPdbThrew = $true; $noPdbMessage = [string]$_.Exception.Message }

    # install: an upstream ZIP missing libSkiaSharp.dll -> fail closed
    $rootZipNoSkia = New-KIWinAppTestRoot 'rootZipNoSkia'
    $artNoSkia = New-KIWinAppFakeArtifact -Label 'NoSkia' -OmitLibSkiaSharp
    $zipNoSkiaThrew = $false
    try { Install-KIWinApp -PackageRoot $PackageRoot -TargetRoot $rootZipNoSkia -Action 'Install' -ArtifactFileOverride $artNoSkia.path -SourceManifestOverride (New-KIWinAppOverrideManifest -Artifact $artNoSkia) -VersionProbeOverride $probe061 | Out-Null }
    catch { $zipNoSkiaThrew = $true }

    $checks.requiredUpstreamFiles = [ordered]@{
        resolverRejectsMissingLibSkiaSharp = ($noSkiaThrew -and $noSkiaMessage -match '(?i)erwartete Upstream-Dateien' -and $noSkiaMessage -match 'libSkiaSharp\.dll')
        resolverRejectsMissingPdb = ($noPdbThrew -and $noPdbMessage -match '(?i)erwartete Upstream-Dateien' -and $noPdbMessage -match 'winapp\.pdb')
        installRejectsMissingLibSkiaSharp = ($zipNoSkiaThrew -and -not (Test-Path -LiteralPath (Get-KIWinAppPaths -TargetRoot $rootZipNoSkia).marker))
    }
    if ($checks.requiredUpstreamFiles.Values -contains $false) { $fail.Add('requiredUpstreamFiles: ' + ($checks.requiredUpstreamFiles | ConvertTo-Json -Compress)) }

    $passed = $fail.Count -eq 0
    [pscustomobject]@{ passed = $passed; checks = $checks; failures = @($fail) } | ConvertTo-Json -Depth 12
    if (-not $passed) { throw 'WinApp-Regression fehlgeschlagen.' }
} finally {
    try { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

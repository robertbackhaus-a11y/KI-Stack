Set-StrictMode -Version Latest

# KI-Stack WinApp Resolver -- the single production entry point a later Desktop-Control
# wrapper uses to obtain a trusted path to winapp.exe.
#
# Contract (non-negotiable):
#   Production resolution yields EXACTLY the central, verified path
#     <KIStackRoot>\tools\winapp\current\winapp.exe
#   and nothing else. Concretely:
#   1. central path only -- <KIStackRoot>\tools\winapp\current\ must exist
#   2. verify the provisioned version -- VERSION stamp == expected (0.6.1)
#   3. verify the package / executable:
#        - SHA256SUMS.txt still matches every extracted file (covers winapp.pdb too)
#        - EXACTLY one winapp.exe, DIRECTLY at the package root -- a second winapp.exe
#          anywhere under current\ is fail closed; winapp.exe only in a subdirectory is fail
#          closed
#        - the required upstream files (winapp.exe, libSkiaSharp.dll, winapp.pdb) are present
#   4. live `winapp.exe --version` == expected (0.6.1)
#   5. clear, actionable error when winapp is not (correctly) provisioned
#
# There is NO automatic production fallback to Get-Command / where.exe / %LOCALAPPDATA%\
# Microsoft\WindowsApps / WinGet Links / WinGet Packages / the interactive user PATH / an App
# Execution Alias. That fallback exists ONLY behind the explicit -AllowDevelopmentFallback
# switch, which is for local development and test harnesses only. Production Desktop-Control
# code must never receive that switch (nor -VersionProbeOverride).

function Get-KIWinAppResolverPaths {
    param([Parameter(Mandatory)][string]$KIStackRoot)
    if ([string]::IsNullOrWhiteSpace($KIStackRoot)) { throw 'KIStackRoot darf nicht leer sein.' }
    if (-not [IO.Path]::IsPathFullyQualified($KIStackRoot)) { throw "KIStackRoot muss ein absoluter Pfad sein: $KIStackRoot" }
    $root = [IO.Path]::GetFullPath($KIStackRoot)
    $installRoot = [IO.Path]::Combine($root, 'tools', 'winapp')
    $packageRoot = [IO.Path]::Combine($installRoot, 'current')
    [pscustomobject]@{
        kiStackRoot  = $root
        installRoot  = $installRoot
        packageRoot  = $packageRoot
        # THE binding production path -- no search, ever.
        executablePath = [IO.Path]::Combine($packageRoot, 'winapp.exe')
        versionStamp = [IO.Path]::Combine($installRoot, 'VERSION')
        marker       = [IO.Path]::Combine($installRoot, 'installation.json')
        checksums    = [IO.Path]::Combine($installRoot, 'SHA256SUMS.txt')
    }
}

function Get-KIWinAppPackageExecutableState {
    # No recursive "best match" -- the executable MUST be exactly <PackageRoot>\winapp.exe, and
    # there must be no other winapp.exe anywhere under PackageRoot.
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
    [pscustomobject]@{ ok = $ok; executablePath = $resolvedExe; rootExecutablePresent = $rootExePresent; additionalExecutables = $additional; reason = $reason }
}

function Test-KIWinAppPackageChecksums {
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

function Resolve-KIStackWinApp {
    <#
    .SYNOPSIS
        Resolve a trusted winapp.exe from the central KI-Stack provisioning path only
        (<KIStackRoot>\tools\winapp\current\winapp.exe). No search, no PATH/WindowsApps/WinGet
        fallback in production.
    .OUTPUTS
        On success: [pscustomobject] resolved=$true, executablePath, version,
        reportedExecutableVersion, packageRoot, resolutionMethod='central-kistack-tools'.
        On failure: throws a clear "winapp ist nicht (korrekt) provisioniert" error -- unless
        -AllowDevelopmentFallback is set (development/test only).
    #>
    [CmdletBinding()]
    param(
        [string]$KIStackRoot = 'C:\KI-Stack',
        [string]$ExpectedVersion = '0.6.1',
        [string]$ExecutableName = 'winapp.exe',
        [string[]]$RequiredPackageFiles = @('winapp.exe', 'libSkiaSharp.dll', 'winapp.pdb'),
        # DEVELOPMENT / TEST ONLY -- never set by production Desktop-Control code. Only when the
        # central path yields nothing does this permit a PATH / WindowsApps / WinGet lookup.
        [switch]$AllowDevelopmentFallback,
        # INTERNAL TEST SEAM ONLY (Test-KIStackWinApp.ps1 has no runnable winapp.exe). A real
        # caller never passes this; the real `winapp.exe --version` probe then runs unchanged.
        [scriptblock]$VersionProbeOverride
    )
    $paths = Get-KIWinAppResolverPaths -KIStackRoot $KIStackRoot

    # 1. central path only
    if (-not (Test-Path -LiteralPath $paths.packageRoot -PathType Container)) {
        if ($AllowDevelopmentFallback) { return (Resolve-KIStackWinAppDevelopmentFallback -ExpectedVersion $ExpectedVersion -ExecutableName $ExecutableName -Reason "zentraler Pfad fehlt: $($paths.packageRoot)") }
        throw "winapp ist nicht zentral provisioniert. Erwartet unter '$($paths.packageRoot)'. Fuehre den KI-Stack Complete Installer bzw. Reconcile aus (Komponente 'winapp')."
    }

    # 2. verify the provisioned version
    if (-not (Test-Path -LiteralPath $paths.versionStamp -PathType Leaf)) {
        if ($AllowDevelopmentFallback) { return (Resolve-KIStackWinAppDevelopmentFallback -ExpectedVersion $ExpectedVersion -ExecutableName $ExecutableName -Reason 'VERSION-Stempel fehlt') }
        throw "winapp-Provisionierung ist unvollstaendig: VERSION-Stempel fehlt unter '$($paths.versionStamp)'. Reconcile der Komponente 'winapp' erforderlich."
    }
    $stamped = (Get-Content -LiteralPath $paths.versionStamp -Raw).Trim()
    if ($stamped -ne $ExpectedVersion) {
        throw "winapp-Provisionierung hat die falsche Version: '$stamped' statt '$ExpectedVersion' ('$($paths.versionStamp)'). Reconcile der Komponente 'winapp' erforderlich."
    }

    # 3a. package integrity (always -- covers winapp.pdb as well)
    if (-not (Test-KIWinAppPackageChecksums -PackageRoot $paths.packageRoot -ChecksumFile $paths.checksums)) {
        throw "winapp-Paketintegritaet ist verletzt (SHA256SUMS.txt stimmt nicht mit dem Inhalt von '$($paths.packageRoot)' ueberein). Reconcile/Repair der Komponente 'winapp' erforderlich."
    }

    # 3b. exactly one winapp.exe, directly at the package root
    $exeState = Get-KIWinAppPackageExecutableState -PackageRoot $paths.packageRoot -ExecutableName $ExecutableName
    if (-not $exeState.ok) {
        switch ($exeState.reason) {
            'root-executable-missing' { throw "'$ExecutableName' liegt nicht direkt im Paket-Root (fail closed). Verbindlich ist '$($paths.executablePath)'. Reconcile/Repair der Komponente 'winapp' erforderlich." }
            'additional-executable'   { throw "Zweite '$ExecutableName' im provisionierten winapp-Paket gefunden (fail closed): $($exeState.additionalExecutables -join '; '). Reconcile/Repair der Komponente 'winapp' erforderlich." }
            default                   { throw "winapp-Paketlayout ist ungueltig ('$($exeState.reason)'). Reconcile/Repair der Komponente 'winapp' erforderlich." }
        }
    }

    # 3c. required upstream files present
    $missing = @($RequiredPackageFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $paths.packageRoot $_) -PathType Leaf) })
    if ($missing.Count -gt 0) {
        throw "Im provisionierten winapp-Paket fehlen erwartete Upstream-Dateien (fail closed): $($missing -join ', '). Reconcile/Repair der Komponente 'winapp' erforderlich."
    }

    # 4. live --version probe (always in production; overridable only for this component's tests)
    $reportedVersion = $null
    if ($null -ne $VersionProbeOverride) {
        $clean = ([string](& $VersionProbeOverride $exeState.executablePath)) -replace "`e\[[0-?]*[ -/]*[@-~]", ''
        if ($clean -match '(\d+\.\d+\.\d+)') { $reportedVersion = $Matches[1] }
    } else {
        try {
            $raw = @(& $exeState.executablePath --version 2>&1)
            $exit = $LASTEXITCODE
            $global:LASTEXITCODE = 0
            $clean = (($raw | ForEach-Object { [string]$_ }) -join "`n") -replace "`e\[[0-?]*[ -/]*[@-~]", ''
            if ($exit -eq 0 -and $clean -match '(\d+\.\d+\.\d+)') { $reportedVersion = $Matches[1] }
        } catch { $reportedVersion = $null }
    }
    if ($reportedVersion -ne $ExpectedVersion) {
        throw "winapp meldet Version '$reportedVersion', erwartet '$ExpectedVersion' ('$($exeState.executablePath)'). Reconcile/Repair der Komponente 'winapp' erforderlich."
    }

    [pscustomobject][ordered]@{
        resolved = $true
        executablePath = $exeState.executablePath
        version = $ExpectedVersion
        reportedExecutableVersion = $reportedVersion
        packageRoot = $paths.packageRoot
        installRoot = $paths.installRoot
        resolutionMethod = 'central-kistack-tools'
    }
}

function Resolve-KIStackWinAppDevelopmentFallback {
    # DEVELOPMENT / TEST ONLY -- never a production code path. Reached only when
    # Resolve-KIStackWinApp was called with -AllowDevelopmentFallback AND the central path
    # yielded nothing usable. Consults, in order: Get-Command, %LOCALAPPDATA%\Microsoft\
    # WindowsApps, where.exe, WinGet Links.
    [CmdletBinding()]
    param([string]$ExpectedVersion = '0.6.1', [string]$ExecutableName = 'winapp.exe', [string]$Reason = '')
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('winapp.exe', 'winapp')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd) { $candidates.Add([string]($cmd.Path ?? $cmd.Source)) | Out-Null }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winapp.exe')) | Out-Null
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\winapp.exe')) | Out-Null
    }
    try { foreach ($p in @(& where.exe winapp 2>$null)) { $candidates.Add([string]$p) | Out-Null } } catch {}
    foreach ($candidate in @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [pscustomobject][ordered]@{
                resolved = $true
                executablePath = [IO.Path]::GetFullPath($candidate)
                version = $ExpectedVersion
                reportedExecutableVersion = $null
                packageRoot = $null
                installRoot = $null
                resolutionMethod = 'development-fallback'
                developmentFallbackReason = $Reason
            }
        }
    }
    throw "winapp konnte auch ueber den Development-Fallback nicht aufgeloest werden ($Reason)."
}

Export-ModuleMember -Function Resolve-KIStackWinApp, Resolve-KIStackWinAppDevelopmentFallback, Get-KIWinAppResolverPaths, Get-KIWinAppPackageExecutableState, Test-KIWinAppPackageChecksums

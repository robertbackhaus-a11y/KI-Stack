Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-KIStackSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-KIStackJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$InputObject
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $text = ($InputObject | ConvertTo-Json -Depth 100) + "`n"
    [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($false))
}

function Test-KIStackAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-KIStackPowerShell7 {
    $candidates = [Collections.Generic.List[string]]::new()
    if ($env:ProgramW6432) { [void]$candidates.Add((Join-Path $env:ProgramW6432 'PowerShell\7\pwsh.exe')) }
    if ($env:ProgramFiles) { [void]$candidates.Add((Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')) }
    try {
        $resolved = (Get-Command pwsh.exe -ErrorAction Stop).Source
        if ($resolved) { [void]$candidates.Add($resolved) }
    } catch {}
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'PowerShell 7 wurde nicht gefunden.'
}

function Test-KIStackSafeRelativePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $normalized = $Path.Replace('\','/')
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $false }
    if ($normalized.IndexOf([char]0) -ge 0) { return $false }
    if ($normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:') {
        return $false
    }

    $validationPath = $normalized.TrimEnd([char]'/')
    if ([string]::IsNullOrWhiteSpace($validationPath)) { return $false }
    $invalidChars = [IO.Path]::GetInvalidFileNameChars()
    foreach ($segment in $validationPath.Split([char]'/')) {
        if ([string]::IsNullOrEmpty($segment)) { return $false }
        if ($segment -in @('.', '..')) { return $false }
        if ($segment.IndexOfAny($invalidChars) -ge 0) { return $false }
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ')) { return $false }
        if ($segment -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') {
            return $false
        }
    }
    return $true
}

function Expand-KIStackSafeZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    $fullDestination = [IO.Path]::GetFullPath($Destination)
    $separator = [IO.Path]::DirectorySeparatorChar
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    try {
        foreach ($entry in $archive.Entries) {
            $relative = $entry.FullName.Replace('\','/')
            if (-not (Test-KIStackSafeRelativePath -Path $relative)) {
                throw "Unsicherer ZIP-Pfad: $relative"
            }
            if (-not $seen.Add($relative)) {
                throw "Doppelter ZIP-Pfad: $relative"
            }

            $unixFileType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixFileType -eq 0xA000) {
                throw "Symbolischer Link im ZIP nicht zulässig: $relative"
            }

            $platformRelative = $relative.Replace([char]'/', $separator)
            $fullTarget = [IO.Path]::GetFullPath(
                [IO.Path]::Combine($fullDestination, $platformRelative)
            )
            $relativeFromDestination = [IO.Path]::GetRelativePath(
                $fullDestination,
                $fullTarget
            ).Replace('\','/')

            if (
                [IO.Path]::IsPathRooted($relativeFromDestination) -or
                $relativeFromDestination -eq '..' -or
                $relativeFromDestination.StartsWith(
                    '../',
                    [StringComparison]::Ordinal
                )
            ) {
                throw "ZIP-Pfad verlässt das Ziel: $relative"
            }

            if ([string]::IsNullOrEmpty($entry.Name)) {
                New-Item -ItemType Directory -Path $fullTarget -Force |
                    Out-Null
                continue
            }

            $parent = Split-Path -Parent $fullTarget
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force |
                    Out-Null
            }
            $input = $entry.Open()
            $output = [IO.File]::Open(
                $fullTarget,
                [IO.FileMode]::Create,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None
            )
            try {
                $input.CopyTo($output)
            } finally {
                $output.Dispose()
                $input.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function Test-KIStackSha256DirectoryManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ManifestPath,
        [switch]$ExactFileSet
    )
    $errors = [Collections.Generic.List[string]]::new()
    $expected = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $ManifestPath -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
            [void]$errors.Add("Ungültige SHA256-Zeile: $line")
            continue
        }
        $relative = $Matches[2].Replace('\\','/')
        if (-not (Test-KIStackSafeRelativePath -Path $relative)) {
            [void]$errors.Add("Unsicherer Manifestpfad: $relative")
            continue
        }
        if ($expected.Contains($relative)) {
            [void]$errors.Add("Doppelter Manifestpfad: $relative")
            continue
        }
        $expected[$relative] = $Matches[1].ToLowerInvariant()
    }
    foreach ($relative in $expected.Keys) {
        $path = Join-Path $Root ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [void]$errors.Add("Datei fehlt: $relative")
        } elseif ((Get-KIStackSha256 -Path $path) -ne $expected[$relative]) {
            [void]$errors.Add("SHA256 falsch: $relative")
        }
    }
    if ($ExactFileSet) {
        $actual = @(
            Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
                Where-Object {
                    [IO.Path]::GetFullPath($_.FullName) -ne
                    [IO.Path]::GetFullPath($ManifestPath)
                } |
                ForEach-Object {
                    [IO.Path]::GetRelativePath(
                        $Root,
                        $_.FullName
                    ).Replace('\','/')
                } |
                Sort-Object
        )
        $wanted = @(
            $expected.Keys |
                ForEach-Object { [string]$_ } |
                Sort-Object
        )
        $wantedSet = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        $actualSet = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($relative in $wanted) {
            [void]$wantedSet.Add($relative)
        }
        foreach ($relative in $actual) {
            [void]$actualSet.Add($relative)
        }
        foreach ($relative in $wanted) {
            if (-not $actualSet.Contains($relative)) {
                [void]$errors.Add(
                    "Manifestdatei fehlt im Ist-Dateisatz: $relative"
                )
            }
        }
        foreach ($relative in $actual) {
            if (-not $wantedSet.Contains($relative)) {
                [void]$errors.Add(
                    "Unerwartete Datei außerhalb des SHA256-Manifests: $relative"
                )
            }
        }
    }
    return [pscustomobject]@{ passed = ($errors.Count -eq 0); errors = @($errors); verified = $expected.Count }
}

function Test-KIStackAcceptancePackageIntegrity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackageRoot)
    $manifest = Join-Path $PackageRoot 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw 'SHA256SUMS.txt fehlt.' }
    $result = Test-KIStackSha256DirectoryManifest -Root $PackageRoot -ManifestPath $manifest -ExactFileSet
    if (-not $result.passed) { throw ('Paketintegrität fehlgeschlagen: ' + ($result.errors -join ' | ')) }
    return $result
}

function Test-KIStackRecoveryArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RecoveryZip,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$WorkRoot
    )
    $actual = Get-KIStackSha256 -Path $RecoveryZip
    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "Recovery-SHA256 falsch. Erwartet=$ExpectedSha256; Ist=$actual"
    }
    $extract = Join-Path $WorkRoot 'Recovery'
    Expand-KIStackSafeZip -ZipPath $RecoveryZip -Destination $extract
    $roots = @(Get-ChildItem -LiteralPath $extract -Directory)
    if ($roots.Count -ne 1) { throw 'Recovery-ZIP besitzt keine eindeutige Wurzel.' }
    $root = $roots[0].FullName
    $sums = Join-Path $root 'SHA256SUMS.txt'
    $topResult = Test-KIStackSha256DirectoryManifest -Root $root -ManifestPath $sums -ExactFileSet
    if (-not $topResult.passed) { throw ('Recovery-Inhalt ungültig: ' + ($topResult.errors -join ' | ')) }
    $release = Get-Content -LiteralPath (Join-Path $root 'RELEASE-MANIFEST.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
    $runtimeZip = Join-Path $root ('01-Runtime\' + [string]$release.runtime.name)
    if ((Get-KIStackSha256 -Path $runtimeZip) -ne [string]$release.runtime.actualSha256) {
        throw 'Runtime-Core-SHA256 stimmt nicht mit dem Recovery-Manifest überein.'
    }
    $runtimeExtract = Join-Path $WorkRoot 'Runtime'
    Expand-KIStackSafeZip -ZipPath $runtimeZip -Destination $runtimeExtract
    $runtimeRoots = @(Get-ChildItem -LiteralPath $runtimeExtract -Directory)
    if ($runtimeRoots.Count -ne 1) { throw 'Runtime-Core besitzt keine eindeutige Wurzel.' }
    $runtimeSums = Join-Path $runtimeRoots[0].FullName 'SHA256SUMS.txt'
    $runtimeResult = Test-KIStackSha256DirectoryManifest -Root $runtimeRoots[0].FullName -ManifestPath $runtimeSums
    if (-not $runtimeResult.passed) { throw ('Runtime-Core intern ungültig: ' + ($runtimeResult.errors -join ' | ')) }
    $overlayRoot = Join-Path $root '02-Operational-Overlay'
    $overlayContentRoot = Join-Path $overlayRoot 'Content'
    if (-not (Test-Path -LiteralPath $overlayContentRoot -PathType Container)) {
        throw 'Overlay-Content-Verzeichnis fehlt.'
    }
    $overlayManifest = Get-Content -LiteralPath (Join-Path $overlayRoot 'CONTENT-MANIFEST.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
    $filesProperty = $overlayManifest.PSObject.Properties['files']
    if ($null -eq $filesProperty) {
        throw 'Overlay-Manifest enthält keine files-Liste.'
    }
    $overlayFiles = @($filesProperty.Value)
    $countProperty = $overlayManifest.PSObject.Properties['overlayFileCount']
    if ($null -eq $countProperty) {
        $countProperty = $overlayManifest.PSObject.Properties['fileCount']
    }
    $declaredOverlayFileCount = if ($null -ne $countProperty) {
        [int]$countProperty.Value
    } else {
        $overlayFiles.Count
    }
    if ($declaredOverlayFileCount -ne $overlayFiles.Count) {
        throw ("Overlay-Dateianzahl widersprüchlich. Manifest={0}; Dateien={1}" -f $declaredOverlayFileCount,$overlayFiles.Count)
    }
    $overlayErrors = [Collections.Generic.List[string]]::new()
    foreach ($record in $overlayFiles) {
        $relative = [string]$record.path
        if (-not (Test-KIStackSafeRelativePath -Path $relative)) { [void]$overlayErrors.Add("Unsicherer Overlaypfad: $relative"); continue }
        $source = Join-Path $overlayContentRoot $relative.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { [void]$overlayErrors.Add("Overlaydatei fehlt: $relative") }
        elseif ([int64](Get-Item -LiteralPath $source).Length -ne [int64]$record.size) { [void]$overlayErrors.Add("Overlaygröße falsch: $relative") }
        elseif ((Get-KIStackSha256 -Path $source) -ne [string]$record.sha256) { [void]$overlayErrors.Add("Overlay-SHA256 falsch: $relative") }
    }
    if ($overlayErrors.Count -gt 0) { throw ($overlayErrors -join ' | ') }
    return [pscustomobject]@{
        root = $root
        releaseManifest = $release
        overlayRoot = $overlayRoot
        overlayContentRoot = $overlayContentRoot
        overlayManifest = $overlayManifest
        overlayFileCount = $overlayFiles.Count
        runtimeVerifiedFiles = $runtimeResult.verified
        packageVerifiedFiles = $topResult.verified
    }
}

function Set-KIStackOperationalOverlay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OverlayRoot,
        [Parameter(Mandatory)]$OverlayManifest,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$BackupRoot,
        [switch]$AuditOnly
    )
    $changed = [Collections.Generic.List[object]]::new()
    $unchanged = [Collections.Generic.List[object]]::new()
    $drift = [Collections.Generic.List[object]]::new()
    foreach ($record in @($OverlayManifest.files)) {
        $relative = [string]$record.path
        $source = Join-Path $OverlayRoot ('Content\' + $relative.Replace('/', '\\'))
        $destination = Join-Path $TargetRoot ($relative.Replace('/', '\\'))
        $expected = [string]$record.sha256
        $current = if (Test-Path -LiteralPath $destination -PathType Leaf) { Get-KIStackSha256 -Path $destination } else { $null }
        if ($current -eq $expected) {
            [void]$unchanged.Add([pscustomobject]@{ path=$relative; sha256=$expected })
            continue
        }
        [void]$drift.Add([pscustomobject]@{ path=$relative; expectedSha256=$expected; actualSha256=$current })
        if ($AuditOnly) { continue }
        if (Test-Path -LiteralPath $destination) {
            $backup = Join-Path $BackupRoot ($relative.Replace('/', '\\'))
            $backupParent = Split-Path -Parent $backup
            New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
            Copy-Item -LiteralPath $destination -Destination $backup -Force
        }
        $parent = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $partial = $destination + '.acceptance-partial'
        Copy-Item -LiteralPath $source -Destination $partial -Force
        if ((Get-KIStackSha256 -Path $partial) -ne $expected) {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            throw "Kopierprüfung fehlgeschlagen: $relative"
        }
        Move-Item -LiteralPath $partial -Destination $destination -Force
        if ((Get-KIStackSha256 -Path $destination) -ne $expected) { throw "Zielprüfung fehlgeschlagen: $relative" }
        [void]$changed.Add([pscustomobject]@{ path=$relative; sha256=$expected })
    }
    $postErrors = [Collections.Generic.List[string]]::new()
    foreach ($record in @($OverlayManifest.files)) {
        $relative = [string]$record.path
        $destination = Join-Path $TargetRoot ($relative.Replace('/', '\\'))
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) { [void]$postErrors.Add("Fehlt: $relative") }
        elseif ((Get-KIStackSha256 -Path $destination) -ne [string]$record.sha256) { [void]$postErrors.Add("Falsch: $relative") }
    }
    return [pscustomobject]@{
        passed = ($postErrors.Count -eq 0)
        changed = @($changed)
        unchanged = @($unchanged)
        drift = @($drift)
        postErrors = @($postErrors)
        backupRoot = if ((Test-Path -LiteralPath $BackupRoot) -and $changed.Count -gt 0) { $BackupRoot } else { $null }
    }
}

function Invoke-KIStackManagedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string]$LogRoot,
        [Parameter(Mandatory)][string]$Name
    )
    New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
    $stdout = Join-Path $LogRoot ($Name + '.stdout.log')
    $stderr = Join-Path $LogRoot ($Name + '.stderr.log')
    Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    $timedOut = -not $completed
    if ($timedOut) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch {}
        $process.WaitForExit()
    }
    return [pscustomobject]@{
        name = $Name
        filePath = $FilePath
        arguments = @($ArgumentList)
        timedOut = $timedOut
        exitCode = if ($timedOut) { $null } else { $process.ExitCode }
        stdoutPath = $stdout
        stderrPath = $stderr
        stdout = if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue } else { '' }
        stderr = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue } else { '' }
    }
}

function Test-KIStackEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Endpoint,
        [int]$DeadlineSeconds = 120
    )
    $deadline = (Get-Date).AddSeconds($DeadlineSeconds)
    $attempts = 0
    $detail = ''
    $duration = [Diagnostics.Stopwatch]::StartNew()
    do {
        $attempts++
        try {
            $kind = [string]$Endpoint.kind
            $url = [string]$Endpoint.url
            if ($kind -in @('searxng','openai','json')) {
                $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 10 -ErrorAction Stop
                $ok = if ($kind -eq 'searxng') { $null -ne $response.PSObject.Properties['results'] }
                      elseif ($kind -eq 'openai') { $null -ne $response.PSObject.Properties['data'] }
                      else { $null -ne $response }
            } else {
                $response = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 10 -SkipHttpErrorCheck -ErrorAction Stop
                $ok = ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 500)
            }
            if ($ok) { $detail = 'Endpoint erreichbar und Antwortvertrag erfüllt.'; break }
            $detail = 'Antwortvertrag nicht erfüllt.'
        } catch { $ok = $false; $detail = $_.Exception.Message }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    $duration.Stop()
    return [pscustomobject]@{
        name = [string]$Endpoint.name
        kind = [string]$Endpoint.kind
        url = [string]$Endpoint.url
        reachable = [bool]$ok
        attempts = $attempts
        durationMs = [int64]$duration.ElapsedMilliseconds
        detail = $detail
    }
}

Export-ModuleMember -Function *

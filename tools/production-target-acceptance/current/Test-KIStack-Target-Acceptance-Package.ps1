[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$expectedPackageVersion = '1.0.10'
$packageVersion = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw -Encoding UTF8).Trim()
if ($packageVersion -ne $expectedPackageVersion) { throw "Falsche Paketversion. Erwartet=$expectedPackageVersion; Ist=$packageVersion" }
Import-Module (Join-Path $root 'Core\KIStack.TargetAcceptance.Core.psm1') -Force
$results = [Collections.Generic.List[object]]::new()
function Add-Result([string]$Name,[bool]$Passed,[string]$Detail) {
    [void]$results.Add([pscustomobject]@{name=$Name;passed=$Passed;detail=$Detail})
}
$work = Join-Path $env:TEMP ('KI-Stack-Acceptance-SelfTest-' + [guid]::NewGuid().ToString('N'))
try {
    Write-Host ("=== KI-Stack Target Acceptance Package Self-Test v{0} ===" -f $packageVersion)
    Add-Result 'Package identity' ($packageVersion -eq $expectedPackageVersion) ("Version={0}" -f $packageVersion)
    $integrity = Test-KIStackAcceptancePackageIntegrity -PackageRoot $root
    Add-Result 'Package SHA256 manifest' $true ("{0} files" -f $integrity.verified)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    function New-KIStackRegressionZip {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][object[]]$Entries
        )
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Force
        }
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        $archive = [IO.Compression.ZipArchive]::new(
            $stream,
            [IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        try {
            foreach ($record in $Entries) {
                $entry = $archive.CreateEntry([string]$record.name)
                if (-not [string]::IsNullOrEmpty([string]$record.content)) {
                    $writer = [IO.StreamWriter]::new(
                        $entry.Open(),
                        [Text.UTF8Encoding]::new($false)
                    )
                    try {
                        $writer.Write([string]$record.content)
                    } finally {
                        $writer.Dispose()
                    }
                }
            }
        } finally {
            $archive.Dispose()
            $stream.Dispose()
        }
    }

    $zipRegressionRoot = Join-Path $work 'ZipRegression'
    New-Item -ItemType Directory -Path $zipRegressionRoot -Force |
        Out-Null
    $nestedZip = Join-Path $zipRegressionRoot 'nested.zip'
    $nestedRelative = (
        'KI-Stack-Production-Recovery-v1.7.0-r7/' +
        '01-Runtime/' +
        'KI-Stack-Cutover-Execute-v1.6.3-core.zip'
    )
    New-KIStackRegressionZip -Path $nestedZip -Entries @(
        [pscustomobject]@{name=$nestedRelative;content='runtime-core'}
    )
    $nestedDestination = Join-Path $zipRegressionRoot 'NestedExtract'
    Expand-KIStackSafeZip -ZipPath $nestedZip -Destination $nestedDestination
    $nestedExtracted = Join-Path `
        $nestedDestination `
        $nestedRelative.Replace('/', '\')
    Add-Result `
        'Safe ZIP real nested recovery path accepted' `
        ((Test-Path -LiteralPath $nestedExtracted -PathType Leaf) -and (
            (Get-Content -LiteralPath $nestedExtracted -Raw -Encoding UTF8) -eq
            'runtime-core'
        )) `
        $nestedExtracted

    $unsafeCases = @(
        [pscustomobject]@{
            name='Safe ZIP traversal rejected'
            entry='../escape.txt'
            expected='Unsicherer ZIP-Pfad'
        },
        [pscustomobject]@{
            name='Safe ZIP absolute path rejected'
            entry='/absolute.txt'
            expected='Unsicherer ZIP-Pfad'
        },
        [pscustomobject]@{
            name='Safe ZIP ADS path rejected'
            entry='root/file.txt:stream'
            expected='Unsicherer ZIP-Pfad'
        },
        [pscustomobject]@{
            name='Safe ZIP Windows device path rejected'
            entry='root/CON.txt'
            expected='Unsicherer ZIP-Pfad'
        }
    )
    foreach ($case in $unsafeCases) {
        $caseZip = Join-Path `
            $zipRegressionRoot `
            (([guid]::NewGuid().ToString('N')) + '.zip')
        New-KIStackRegressionZip -Path $caseZip -Entries @(
            [pscustomobject]@{name=[string]$case.entry;content='blocked'}
        )
        $caseDestination = Join-Path `
            $zipRegressionRoot `
            ([guid]::NewGuid().ToString('N'))
        $casePassed = $false
        $caseDetail = ''
        try {
            Expand-KIStackSafeZip `
                -ZipPath $caseZip `
                -Destination $caseDestination
            $caseDetail = 'Unsicheres ZIP wurde unerwartet akzeptiert.'
        } catch {
            $caseDetail = $_.Exception.Message
            $casePassed = $caseDetail -match [regex]::Escape(
                [string]$case.expected
            )
        }
        Add-Result ([string]$case.name) $casePassed $caseDetail
    }

    $duplicateZip = Join-Path $zipRegressionRoot 'duplicate.zip'
    New-KIStackRegressionZip -Path $duplicateZip -Entries @(
        [pscustomobject]@{name='root/duplicate.txt';content='one'},
        [pscustomobject]@{name='root/duplicate.txt';content='two'}
    )
    $duplicatePassed = $false
    $duplicateDetail = ''
    try {
        Expand-KIStackSafeZip `
            -ZipPath $duplicateZip `
            -Destination (Join-Path $zipRegressionRoot 'DuplicateExtract')
        $duplicateDetail = 'Doppelter ZIP-Pfad wurde unerwartet akzeptiert.'
    } catch {
        $duplicateDetail = $_.Exception.Message
        $duplicatePassed = $duplicateDetail -match 'Doppelter ZIP-Pfad'
    }
    Add-Result `
        'Safe ZIP duplicate path rejected' `
        $duplicatePassed `
        $duplicateDetail

    $manifestRegressionRoot = Join-Path $work 'ManifestRegression'
    New-Item -ItemType Directory -Path $manifestRegressionRoot -Force |
        Out-Null
    $manifestRegressionFile = Join-Path $manifestRegressionRoot 'alpha.txt'
    [IO.File]::WriteAllText(
        $manifestRegressionFile,
        'alpha',
        [Text.UTF8Encoding]::new($false)
    )
    $manifestRegressionHash = Get-KIStackSha256 `
        -Path $manifestRegressionFile
    $manifestRegressionSums = Join-Path `
        $manifestRegressionRoot `
        'SHA256SUMS.txt'
    [IO.File]::WriteAllText(
        $manifestRegressionSums,
        ($manifestRegressionHash + ' *alpha.txt' + "`n"),
        [Text.UTF8Encoding]::new($false)
    )

    $manifestValid = Test-KIStackSha256DirectoryManifest `
        -Root $manifestRegressionRoot `
        -ManifestPath $manifestRegressionSums `
        -ExactFileSet
    Add-Result `
        'Exact manifest valid set accepted' `
        $manifestValid.passed `
        ($manifestValid.errors -join ' | ')

    $extraPath = Join-Path $manifestRegressionRoot 'extra.txt'
    [IO.File]::WriteAllText(
        $extraPath,
        'extra',
        [Text.UTF8Encoding]::new($false)
    )
    $manifestExtra = Test-KIStackSha256DirectoryManifest `
        -Root $manifestRegressionRoot `
        -ManifestPath $manifestRegressionSums `
        -ExactFileSet
    Add-Result `
        'Exact manifest extra file rejected' `
        (-not $manifestExtra.passed -and (
            ($manifestExtra.errors -join ' | ') -match
            'Unerwartete Datei'
        )) `
        ($manifestExtra.errors -join ' | ')
    Remove-Item -LiteralPath $extraPath -Force

    Remove-Item -LiteralPath $manifestRegressionFile -Force
    $manifestMissing = Test-KIStackSha256DirectoryManifest `
        -Root $manifestRegressionRoot `
        -ManifestPath $manifestRegressionSums `
        -ExactFileSet
    Add-Result `
        'Exact manifest missing file rejected' `
        (-not $manifestMissing.passed -and (
            ($manifestMissing.errors -join ' | ') -match
            'Datei fehlt|Manifestdatei fehlt'
        )) `
        ($manifestMissing.errors -join ' | ')

    [IO.File]::WriteAllText(
        $manifestRegressionFile,
        'tampered',
        [Text.UTF8Encoding]::new($false)
    )
    $manifestTampered = Test-KIStackSha256DirectoryManifest `
        -Root $manifestRegressionRoot `
        -ManifestPath $manifestRegressionSums `
        -ExactFileSet
    Add-Result `
        'Exact manifest hash drift rejected' `
        (-not $manifestTampered.passed -and (
            ($manifestTampered.errors -join ' | ') -match
            'SHA256 falsch'
        )) `
        ($manifestTampered.errors -join ' | ')
    $contract = Get-Content -LiteralPath (Join-Path $root 'Contract\ACCEPTANCE-CONTRACT.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
    $recovery = Test-KIStackRecoveryArtifact -RecoveryZip (Join-Path $root ('Recovery\' + [string]$contract.recoveryArtifact.name)) -ExpectedSha256 ([string]$contract.recoveryArtifact.sha256) -WorkRoot $work
    Add-Result 'Recovery artifact validation' $true ("Runtime={0}; Overlay={1}" -f $recovery.runtimeVerifiedFiles,$recovery.overlayFileCount)
    Add-Result 'No repository operations' (-not ((Get-Content -LiteralPath (Join-Path $root 'Invoke-KIStack-Target-Acceptance.ps1') -Raw) -match '(?im)^\s*(git|hg|svn)\s')) 'none'
    Add-Result 'Overlay file count' ([int]$recovery.overlayFileCount -eq 32) ([string]$recovery.overlayFileCount)
    $expectedOverlayContentRoot = [IO.Path]::GetFullPath((Join-Path $recovery.root '02-Operational-Overlay\Content'))
    $reportedOverlayContentRoot = [IO.Path]::GetFullPath([string]$recovery.overlayContentRoot)
    $contentRootMatches = [string]::Equals(
        $expectedOverlayContentRoot.TrimEnd('\'),
        $reportedOverlayContentRoot.TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase
    )
    Add-Result 'Recovery overlay Content root' (
        $contentRootMatches -and
        (Test-Path -LiteralPath $expectedOverlayContentRoot -PathType Container)
    ) ("Expected={0}; Reported={1}" -f $expectedOverlayContentRoot,$reportedOverlayContentRoot)
    if (-not $contentRootMatches) {
        throw ("Recovery overlay Content root mismatch. Expected={0}; Reported={1}" -f $expectedOverlayContentRoot,$reportedOverlayContentRoot)
    }
    $openWebUIStarter = Join-Path $expectedOverlayContentRoot 'modules\applications\Start-KIStack-OpenWebUI.cmd'
    if (-not (Test-Path -LiteralPath $openWebUIStarter -PathType Leaf)) {
        throw ("Open-WebUI-Starter fehlt im realen Overlay-Content: {0}" -f $openWebUIStarter)
    }
    $openWebUIText = Get-Content -LiteralPath $openWebUIStarter -Raw -Encoding UTF8
    Add-Result 'Open WebUI console launcher contract' (
        $openWebUIText -match '(?i)OPENWEBUI_LAUNCHER=.*open-webui\.exe' -and
        $openWebUIText -match '(?i)\"%OPENWEBUI_LAUNCHER%\"\s+serve' -and
        $openWebUIText -notmatch '(?i)-m\s+open_webui'
    ) 'open-webui.exe serve required; python -m open_webui forbidden'

    $comfyStarter = Join-Path $expectedOverlayContentRoot 'modules\comfyui\Start-KIStack-ComfyUI.cmd'
    if (-not (Test-Path -LiteralPath $comfyStarter -PathType Leaf)) {
        throw ("ComfyUI-Starter fehlt im realen Overlay-Content: {0}" -f $comfyStarter)
    }
    $comfyText = Get-Content -LiteralPath $comfyStarter -Raw -Encoding UTF8
    Add-Result 'ComfyUI default SQLite parent contract' (
        $comfyText -match '(?i)COMFY_DB_DIR=C:\\KI-Stack\\ComfyUI\\user' -and
        $comfyText -match '(?i)%COMFY_DB_DIR%'
    ) 'C:\KI-Stack\ComfyUI\user must be created before startup'

    $target = Join-Path $work 'SimulationTarget'
    $backup1 = Join-Path $work 'Backup1'
    $apply1 = Set-KIStackOperationalOverlay -OverlayRoot $recovery.overlayRoot -OverlayManifest $recovery.overlayManifest -TargetRoot $target -BackupRoot $backup1
    Add-Result 'Initial overlay apply' ($apply1.passed -and $apply1.changed.Count -eq 32) ("changed={0}" -f $apply1.changed.Count)
    $apply2 = Set-KIStackOperationalOverlay -OverlayRoot $recovery.overlayRoot -OverlayManifest $recovery.overlayManifest -TargetRoot $target -BackupRoot (Join-Path $work 'Backup2')
    Add-Result 'Idempotent overlay apply' ($apply2.passed -and $apply2.changed.Count -eq 0 -and $apply2.unchanged.Count -eq 32) ("unchanged={0}" -f $apply2.unchanged.Count)
    $first = [string]$recovery.overlayManifest.files[0].path
    $firstPath = Join-Path $target $first.Replace('/', '\\')
    [IO.File]::AppendAllText($firstPath, 'corruption', [Text.UTF8Encoding]::new($false))
    $backup3 = Join-Path $work 'Backup3'
    $apply3 = Set-KIStackOperationalOverlay -OverlayRoot $recovery.overlayRoot -OverlayManifest $recovery.overlayManifest -TargetRoot $target -BackupRoot $backup3
    $backupFile = Join-Path $backup3 $first.Replace('/', '\\')
    Add-Result 'Drift repair and backup' ($apply3.passed -and $apply3.changed.Count -eq 1 -and (Test-Path -LiteralPath $backupFile -PathType Leaf)) ("changed={0}; backup={1}" -f $apply3.changed.Count,$backupFile)

    $cmdFiles = @(Get-ChildItem -LiteralPath $root -Filter '*.cmd' -File)
    $cmdOk = $true
    foreach ($file in $cmdFiles) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $cmdOk = $false }
        for ($i=0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -eq 10 -and ($i -eq 0 -or $bytes[$i-1] -ne 13)) { $cmdOk = $false; break } }
    }
    Add-Result 'CMD encoding and CRLF' $cmdOk ("{0} files" -f $cmdFiles.Count)

    $failed = @($results | Where-Object { -not $_.passed })
    $report = [ordered]@{packageVersion=$packageVersion;testedAtUtc=[DateTime]::UtcNow.ToString('o');passed=($failed.Count -eq 0);checks=@($results);failed=@($failed | ForEach-Object {$_.name})}
    $report | ConvertTo-Json -Depth 20
    exit $(if($failed.Count -eq 0){0}else{1})
} catch {
    $report = [ordered]@{packageVersion=$packageVersion;testedAtUtc=[DateTime]::UtcNow.ToString('o');passed=$false;checks=@($results);failed=@('Unhandled exception');error=$_.Exception.Message}
    $report | ConvertTo-Json -Depth 20
    exit 1
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Direct, isolated tests of the REAL, generic Test-KICompletePayloadVersionContract /
# Get-KICompletePayloadEmbeddedVersion (CompleteInstaller.psm1) -- imported and called as-is,
# never copied or reimplemented. This is the build-gate that closes the real, reproduced 2.19.0
# packaging defect: Contracts/REQUIRED-PAYLOADS.json's `file`/`archiveRoot` for McpRuntime and
# DesktopControl still said v0.1.0 after those components' own COMPONENTS.json version and
# source VERSION file had already advanced to 0.2.0/0.1.1 -- the existing
# Test-KIStackRequiredPayloads.ps1 only checks that a uniquely-named zip file EXISTS, never that
# its name or its own embedded content actually matches the pinned component version.
#
# Scenarios 1-4 use a wholly synthetic "fake-component" (proving genericity -- no
# McpRuntime/DesktopControl-specific code path exists in the function under test). Scenarios 5-6
# run the exact same function against REAL, freshly-built McpRuntime/DesktopControl payload zips
# and the REAL Contracts/COMPONENTS.json + Contracts/REQUIRED-PAYLOADS.json.

Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force

$fail = [Collections.Generic.List[string]]::new()
$checks = [ordered]@{}
$scratchBase = Join-Path ([IO.Path]::GetTempPath()) ('KIPayloadVerContract-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $scratchBase -Force | Out-Null

function New-KIPVCZip {
    # Builds a minimal zip with the given entries (relative paths -> text content), optionally
    # prefixed by ArchiveRoot -- mirrors New-DeterministicArchive's own entry-naming shape.
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][hashtable]$Entries, [string]$ArchiveRoot)
    New-Item -ItemType Directory -Path (Split-Path -Parent $ZipPath) -Force | Out-Null
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::Open($ZipPath, [IO.FileMode]::CreateNew)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($relativePath in $Entries.Keys) {
                $entryName = if (-not [string]::IsNullOrWhiteSpace($ArchiveRoot)) { "$ArchiveRoot/$relativePath" } else { $relativePath }
                $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Fastest)
                $writer = [IO.StreamWriter]::new($entry.Open())
                try { $writer.Write([string]$Entries[$relativePath]) } finally { $writer.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

function New-KIPVCComponentContract {
    # A minimal, synthetic COMPONENTS.json-shaped object with exactly one component -- proves
    # the function under test works from the CONTRACT SHAPE alone, not from any hardcoded id.
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$PackageIdentityPath)
    [pscustomobject]@{
        components = @([pscustomobject]@{
            id = $Id
            version = $Version
            source = $Source
            packageIdentity = [pscustomobject]@{ kind = 'file'; path = $PackageIdentityPath }
        })
    }
}

try {
    # === 1: correct payload filename + correct internal VERSION -> pass =======================
    $z1 = Join-Path $scratchBase '1\Fake-Component-v1.2.3.zip'
    New-KIPVCZip -ZipPath $z1 -ArchiveRoot 'Fake-Component-v1.2.3' -Entries @{ 'VERSION' = '1.2.3' }
    $cc1 = New-KIPVCComponentContract -Id 'fake-component' -Version '1.2.3' -Source 'Payload/FakeComponent' -PackageIdentityPath 'tools/fake-component/current/VERSION'
    $pd1 = [pscustomobject]@{ key = 'FakeComponent'; source = 'tools/fake-component/current'; file = 'Fake-Component-v1.2.3.zip'; archiveRoot = 'Fake-Component-v1.2.3' }
    $r1 = Test-KICompletePayloadVersionContract -ComponentContract $cc1 -PayloadDefinition $pd1 -PayloadZipPath $z1
    $checks.correctNameAndVersionPasses = [ordered]@{ ok = [bool]$r1.ok; checkedFakeComponent = (@($r1.checkedComponents) -contains 'fake-component') }
    if ($checks.correctNameAndVersionPasses.Values -contains $false) { $fail.Add('correctNameAndVersionPasses failed: ' + ($r1.failures -join '; ')) }

    # === 2: stale filename/archiveRoot (old version) while the internal VERSION is already the
    #        NEW one -> fail (the exact real-world 2.19.0 defect shape) ========================
    $z2 = Join-Path $scratchBase '2\Fake-Component-v1.2.2.zip'
    New-KIPVCZip -ZipPath $z2 -ArchiveRoot 'Fake-Component-v1.2.2' -Entries @{ 'VERSION' = '1.2.3' }
    $cc2 = New-KIPVCComponentContract -Id 'fake-component' -Version '1.2.3' -Source 'Payload/FakeComponent' -PackageIdentityPath 'tools/fake-component/current/VERSION'
    $pd2 = [pscustomobject]@{ key = 'FakeComponent'; source = 'tools/fake-component/current'; file = 'Fake-Component-v1.2.2.zip'; archiveRoot = 'Fake-Component-v1.2.2' }
    $r2 = Test-KICompletePayloadVersionContract -ComponentContract $cc2 -PayloadDefinition $pd2 -PayloadZipPath $z2
    $checks.staleFilenameAtNewInternalVersionFails = [ordered]@{
        notOk = (-not [bool]$r2.ok)
        reasonMentionsFilename = (($r2.failures -join ' ') -match "REQUIRED-PAYLOADS\.json-Feld 'file'")
    }
    if ($checks.staleFilenameAtNewInternalVersionFails.Values -contains $false) { $fail.Add('staleFilenameAtNewInternalVersionFails failed: ' + ($r2.failures -join '; ')) }

    # === 3: wrong archiveRoot -- the payload zip's real entries live under a different prefix
    #        than REQUIRED-PAYLOADS.json declares -> fail (structural: entry not found) =========
    $z3 = Join-Path $scratchBase '3\Fake-Component-v1.2.3.zip'
    New-KIPVCZip -ZipPath $z3 -ArchiveRoot 'ActualRoot' -Entries @{ 'VERSION' = '1.2.3' }
    $cc3 = New-KIPVCComponentContract -Id 'fake-component' -Version '1.2.3' -Source 'Payload/FakeComponent' -PackageIdentityPath 'tools/fake-component/current/VERSION'
    $pd3 = [pscustomobject]@{ key = 'FakeComponent'; source = 'tools/fake-component/current'; file = 'Fake-Component-v1.2.3.zip'; archiveRoot = 'DifferentDeclaredRoot' }
    $r3 = Test-KICompletePayloadVersionContract -ComponentContract $cc3 -PayloadDefinition $pd3 -PayloadZipPath $z3
    $checks.wrongArchiveRootFails = [ordered]@{
        notOk = (-not [bool]$r3.ok)
        reasonMentionsUnreadableVersion = (($r3.failures -join ' ') -match 'konnte nicht gelesen werden')
    }
    if ($checks.wrongArchiveRootFails.Values -contains $false) { $fail.Add('wrongArchiveRootFails failed: ' + ($r3.failures -join '; ')) }

    # === 4: correct filename/archiveRoot, but the internal VERSION content itself is wrong =====
    $z4 = Join-Path $scratchBase '4\Fake-Component-v1.2.3.zip'
    New-KIPVCZip -ZipPath $z4 -ArchiveRoot 'Fake-Component-v1.2.3' -Entries @{ 'VERSION' = '1.2.2' }
    $cc4 = New-KIPVCComponentContract -Id 'fake-component' -Version '1.2.3' -Source 'Payload/FakeComponent' -PackageIdentityPath 'tools/fake-component/current/VERSION'
    $pd4 = [pscustomobject]@{ key = 'FakeComponent'; source = 'tools/fake-component/current'; file = 'Fake-Component-v1.2.3.zip'; archiveRoot = 'Fake-Component-v1.2.3' }
    $r4 = Test-KICompletePayloadVersionContract -ComponentContract $cc4 -PayloadDefinition $pd4 -PayloadZipPath $z4
    $checks.wrongInternalVersionFails = [ordered]@{
        notOk = (-not [bool]$r4.ok)
        reasonMentionsPayloadVersion = (($r4.failures -join ' ') -match "Payload enthaelt Version '1\.2\.2'")
    }
    if ($checks.wrongInternalVersionFails.Values -contains $false) { $fail.Add('wrongInternalVersionFails failed: ' + ($r4.failures -join '; ')) }

    # === 4b: a descriptive, non-version filename suffix (e.g. Cutover Runtime's own real
    #         '...-v1.6.16-core.zip', where '-core' disambiguates the payload variant and is
    #         never part of the version) must NOT be misread as part of the version -> pass.
    #         Real, reproduced regression: this exact shape once made the generic gate itself
    #         throw a false positive against the real Cutover Runtime payload. ==================
    $z4b = Join-Path $scratchBase '4b\Fake-Component-v1.6.16-core.zip'
    New-KIPVCZip -ZipPath $z4b -ArchiveRoot 'Fake-Component-v1.6.16' -Entries @{ 'VERSION' = '1.6.16' }
    $cc4b = New-KIPVCComponentContract -Id 'fake-component' -Version '1.6.16' -Source 'Payload/FakeComponent' -PackageIdentityPath 'tools/fake-component/current/VERSION'
    $pd4b = [pscustomobject]@{ key = 'FakeComponent'; source = 'tools/fake-component/current'; file = 'Fake-Component-v1.6.16-core.zip'; archiveRoot = 'Fake-Component-v1.6.16' }
    $r4b = Test-KICompletePayloadVersionContract -ComponentContract $cc4b -PayloadDefinition $pd4b -PayloadZipPath $z4b
    $checks.descriptiveFilenameSuffixNotMisreadAsVersion = [ordered]@{ ok = [bool]$r4b.ok }
    if (-not [bool]$r4b.ok) { $fail.Add('descriptiveFilenameSuffixNotMisreadAsVersion failed: ' + ($r4b.failures -join '; ')) }

    # === 5 & 6: the REAL fix, against REAL freshly-built McpRuntime/DesktopControl payloads and
    #        the REAL Contracts/COMPONENTS.json + Contracts/REQUIRED-PAYLOADS.json -- mirrors
    #        New-KIStackCompleteInstallerArchive.ps1's own build-one-payload shape exactly. ======
    function New-KIPVCRealPayload {
        param([Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)][object]$Definition, [Parameter(Mandatory)][string]$Destination)
        $build = Join-Path $Destination ('source-' + $Definition.key)
        Copy-Item -LiteralPath $SourceRoot -Destination $build -Recurse -Force
        Get-ChildItem -LiteralPath $build -Recurse -File -Filter '*.zip' -ErrorAction SilentlyContinue | Remove-Item -Force
        $sumsPath = Join-Path $build 'SHA256SUMS.txt'
        $lines = Get-ChildItem -LiteralPath $build -Recurse -File | Where-Object { $_.FullName -ne $sumsPath } | Sort-Object { [IO.Path]::GetRelativePath($build, $_.FullName).Replace('\', '/') } | ForEach-Object {
            $rel = [IO.Path]::GetRelativePath($build, $_.FullName).Replace('\', '/')
            "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) *$rel"
        }
        [IO.File]::WriteAllLines($sumsPath, $lines, [Text.ASCIIEncoding]::new())
        $zipPath = Join-Path $Destination $Definition.file
        New-KIPVCZip -ZipPath $zipPath -ArchiveRoot $Definition.archiveRoot -Entries (
            @(Get-ChildItem -LiteralPath $build -Recurse -File) | ForEach-Object -Begin { $h = @{} } -Process {
                $rel = [IO.Path]::GetRelativePath($build, $_.FullName).Replace('\', '/')
                $h[$rel] = [IO.File]::ReadAllText($_.FullName)
            } -End { $h }
        )
        $zipPath
    }

    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PackageRoot '..\..\..'))
    $realComponents = Get-Content -LiteralPath (Join-Path $PackageRoot 'Contracts/COMPONENTS.json') -Raw | ConvertFrom-Json -Depth 30
    $realPayloads = Get-Content -LiteralPath (Join-Path $PackageRoot 'Contracts/REQUIRED-PAYLOADS.json') -Raw | ConvertFrom-Json -Depth 30

    $mcpDefinition = @($realPayloads.payloads | Where-Object key -eq 'McpRuntime')[0]
    $mcpSourceRoot = Join-Path $repoRoot 'tools/mcp-runtime/current'
    $mcpZip = New-KIPVCRealPayload -SourceRoot $mcpSourceRoot -Definition $mcpDefinition -Destination (Join-Path $scratchBase 'mcpruntime')
    $mcpResult = Test-KICompletePayloadVersionContract -ComponentContract $realComponents -PayloadDefinition $mcpDefinition -PayloadZipPath $mcpZip
    $checks.realMcpRuntime020Passes = [ordered]@{
        ok = [bool]$mcpResult.ok
        checkedMcpRuntime = (@($mcpResult.checkedComponents) -contains 'mcp-runtime')
        declaredFileIsV020 = ([string]$mcpDefinition.file -eq 'KI-Stack-MCP-Runtime-v0.2.0.zip')
    }
    if ($checks.realMcpRuntime020Passes.Values -contains $false) { $fail.Add('realMcpRuntime020Passes failed: ' + ($mcpResult.failures -join '; ')) }

    $dcDefinition = @($realPayloads.payloads | Where-Object key -eq 'DesktopControl')[0]
    $dcSourceRoot = Join-Path $repoRoot 'tools/desktop-control/current'
    $dcZip = New-KIPVCRealPayload -SourceRoot $dcSourceRoot -Definition $dcDefinition -Destination (Join-Path $scratchBase 'desktopcontrol')
    $dcResult = Test-KICompletePayloadVersionContract -ComponentContract $realComponents -PayloadDefinition $dcDefinition -PayloadZipPath $dcZip
    $checks.realDesktopControl011Passes = [ordered]@{
        ok = [bool]$dcResult.ok
        checkedDesktopControl = (@($dcResult.checkedComponents) -contains 'desktop-control')
        declaredFileIsV011 = ([string]$dcDefinition.file -eq 'KI-Stack-Desktop-Control-v0.1.1.zip')
    }
    if ($checks.realDesktopControl011Passes.Values -contains $false) { $fail.Add('realDesktopControl011Passes failed: ' + ($dcResult.failures -join '; ')) }

    # === 6b: real Cutover Runtime contract -- the exact real-world case that exposed the
    #         '-core' false positive above; a minimal real payload proves the fix against the
    #         actual repository contract, not only a synthetic fixture. =========================
    $cutoverDefinition = @($realPayloads.payloads | Where-Object key -eq 'CutoverRuntime')[0]
    $cutoverComponent = @($realComponents.components | Where-Object id -eq 'cutover-runtime')[0]
    $cutoverVersion = [string]$cutoverComponent.version
    $cutoverZip = Join-Path $scratchBase 'cutoverruntime\CutoverProbe.zip'
    New-KIPVCZip -ZipPath $cutoverZip -ArchiveRoot $cutoverDefinition.archiveRoot -Entries @{ 'VERSION' = $cutoverVersion }
    $cutoverResult = Test-KICompletePayloadVersionContract -ComponentContract $realComponents -PayloadDefinition $cutoverDefinition -PayloadZipPath $cutoverZip
    $checks.realCutoverRuntimeCoreSuffixPasses = [ordered]@{
        ok = [bool]$cutoverResult.ok
        fileHasCoreSuffix = ([string]$cutoverDefinition.file -match '-core\.zip$')
        checkedCutoverRuntime = (@($cutoverResult.checkedComponents) -contains 'cutover-runtime')
    }
    if ($checks.realCutoverRuntimeCoreSuffixPasses.Values -contains $false) { $fail.Add('realCutoverRuntimeCoreSuffixPasses failed: ' + ($cutoverResult.failures -join '; ')) }

    # === 7: negative control on the REAL contract -- reverting to the old, stale filename/
    #        archiveRoot against the SAME real, freshly-built zip must fail (proves the gate
    #        would have caught the actual 2.19.0 defect before this fix). =======================
    $staleMcpDefinition = [pscustomobject]@{ key = 'McpRuntime'; source = $mcpDefinition.source; file = 'KI-Stack-MCP-Runtime-v0.1.0.zip'; archiveRoot = 'KI-Stack-MCP-Runtime-v0.1.0'; required = $true }
    $staleResult = Test-KICompletePayloadVersionContract -ComponentContract $realComponents -PayloadDefinition $staleMcpDefinition -PayloadZipPath $mcpZip
    $checks.negativeControlStaleMcpRuntimeFilenameFails = [ordered]@{ notOk = (-not [bool]$staleResult.ok) }
    if ($checks.negativeControlStaleMcpRuntimeFilenameFails.Values -contains $false) { $fail.Add('negativeControlStaleMcpRuntimeFilenameFails failed -- gate would not have caught the real defect') }

    $passed = $fail.Count -eq 0
    [pscustomobject]@{ passed = $passed; checks = $checks; failures = @($fail) } | ConvertTo-Json -Depth 12
    if (-not $passed) { throw 'Payload-Version-Contract-Regression fehlgeschlagen.' }
} finally {
    try { Remove-Item -LiteralPath $scratchBase -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

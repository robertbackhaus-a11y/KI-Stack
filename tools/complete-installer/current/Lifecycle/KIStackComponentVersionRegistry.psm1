Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Version/registry resolution for KI-Stack-own ("Klasse B") components. Root problem this
# closes: Update-KIStack-All.ps1's report always showed AvailableVersion=Unknown for every
# component that isn't OpenWebUI (PyPI) or the git-revision-pinned ComfyUI/Integration
# upstream check -- i.e. for every KI-Stack-authored bundle, even though a real, belastbare
# publish source exists for almost all of them (see below).
#
# Real, repository-history-verified finding this module encodes rather than assumes: this
# repository's many per-component GitHub release channels (e.g. openwebui-agents-v1.8.3,
# comfyui-v1.2.2, models-workflows-v1.4.9, openwebui-images-v1.9.2) stopped being cut in late
# July 2026 once the unified Complete Installer release train took over as the sole real
# distribution mechanism for every bundled component -- Complete Installer releases have kept
# incrementing every bundled component's version together ever since (verified: every Klasse-B
# component's VERSION file at the v2.12.0 tag exactly matches its current working-tree value).
# The authoritative PublishedVersion for a Klasse-B component is therefore what its own VERSION
# file (or manifest field) reads AT the commit tagged by the latest published Complete
# Installer release -- never the component's own legacy channel (stale/abandoned for most of
# them), and never the local working tree (that would leak an unpublished, in-progress
# SourceVersion into what a production target is told is "available").
#
# This module never installs, upgrades, or rolls back anything -- it only ever reads (a local
# repository file via GitHub's raw content endpoint, or a fixture) and classifies. The actual
# update decision (what New-KICompletePlan/Get-KIPinClassification act on) is unchanged; this
# adds a second, purely informational signal (status) alongside the existing installed-vs-
# pinned classification, never replacing it.

$script:KIStackVersionRegistryRepository = 'robertbackhaus-a11y/KI-Stack'

function Compare-KIStackSemVer {
    # Robust two-version comparison: strips a leading 'v', splits the numeric core from an
    # optional '-prerelease' suffix, pads missing core segments with 0 (so "1.9" == "1.9.0"),
    # compares the core numerically (never as strings -- "1.10.0" > "1.9.0", not the reverse),
    # and applies SemVer's own precedence rule for an equal core: a release (no prerelease) is
    # newer than any prerelease of the same core ("1.6.3" > "1.6.3-rc1"). Two different
    # prerelease labels on an equal core fall back to an ordinal string compare -- a reasonable,
    # explicitly-documented best effort, not a full SemVer prerelease-precedence implementation
    # (this repository's own prerelease tags are simple "-rcN" suffixes, never dotted
    # prerelease identifiers that would need field-by-field comparison).
    # Returns -1, 0, or 1. Throws only if a version string has no parseable numeric core at all.
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)

    function ConvertTo-KIStackSemVerParts {
        param([Parameter(Mandatory)][string]$Value)
        $trimmed = $Value.Trim()
        if ($trimmed.StartsWith('v') -or $trimmed.StartsWith('V')) { $trimmed = $trimmed.Substring(1) }
        $match = [regex]::Match($trimmed, '^(?<core>\d+(?:\.\d+){0,3})(?:-(?<prerelease>[0-9A-Za-z.-]+))?$')
        if (-not $match.Success) { throw "Nicht als SemVer interpretierbar: '$Value'" }
        $segments = @($match.Groups['core'].Value -split '\.' | ForEach-Object { [int]$_ })
        while ($segments.Count -lt 4) { $segments += 0 }
        [pscustomobject]@{
            segments = $segments
            prerelease = if ($match.Groups['prerelease'].Success) { $match.Groups['prerelease'].Value } else { $null }
        }
    }

    $l = ConvertTo-KIStackSemVerParts -Value $Left
    $r = ConvertTo-KIStackSemVerParts -Value $Right
    for ($i = 0; $i -lt 4; $i++) {
        if ($l.segments[$i] -ne $r.segments[$i]) { return [Math]::Sign($l.segments[$i] - $r.segments[$i]) }
    }
    if ($null -eq $l.prerelease -and $null -eq $r.prerelease) { return 0 }
    if ($null -eq $l.prerelease) { return 1 }   # release > prerelease of the same core
    if ($null -eq $r.prerelease) { return -1 }
    $ordinalCompare = [string]::Compare($l.prerelease, $r.prerelease, [StringComparison]::Ordinal)
    return [Math]::Sign($ordinalCompare)
}

function Get-KIStackLatestPublishedCompleteInstallerRelease {
    # Real, read-only GitHub lookup (gh CLI, already used elsewhere in this repository's
    # release tooling) for the most recently published (non-draft, non-prerelease unless
    # explicitly asked for) release whose assets actually contain a
    # KI-Stack-Complete-Installer-*.zip -- the same asset-shape discovery already used by
    # .github/workflows/release-attestation.yml, so "which releases count as a Complete
    # Installer release" is answered identically in both places without duplicating the
    # underlying gh/API calls themselves (one is a workflow step, this is a repository-side
    # PowerShell function; both apply the same asset-name regex). Never assumes the latest tag
    # by name/date alone -- a repository with many unrelated per-component releases interleaved
    # (verified: this one has exactly that) must not let e.g. "python-git-v1.1.5" or
    # "comfyui-v1.2.2" be mistaken for a Complete Installer release just for being more recent
    # by tag string.
    param([switch]$IncludePrerelease, [int]$TimeoutSeconds = 20, [int]$MaxReleasesToScan = 50, [hashtable]$Fixture)
    if ($Fixture) {
        # Indexer syntax ($Fixture['x']), never dot-property syntax, on a [hashtable] under
        # Set-StrictMode -Version Latest: unlike PSCustomObject, a hashtable's dot-property
        # access DOES throw PropertyNotFoundException for a key that simply isn't present (a
        # genuine PowerShell footgun -- verified directly; the caller's fixture is not required
        # to supply every optional key, e.g. 'reason' is normally omitted for a found=true stub).
        return [pscustomobject]@{ found = [bool]$Fixture['found']; tag = [string]$Fixture['tag']; reason = [string]$Fixture['reason'] }
    }
    try {
        $ghPath = Get-Command gh -ErrorAction SilentlyContinue
        if (-not $ghPath) { return [pscustomobject]@{ found = $false; tag = $null; reason = 'gh CLI nicht verfügbar (offline/nicht installiert).' } }
        # gh release list's --json does not support an "assets" field (verified against the gh
        # CLI version this repository actually uses) -- listing and per-release asset lookup are
        # therefore two separate, sequential gh calls, exactly mirroring
        # .github/workflows/release-attestation.yml's own two-step resolve (list candidates by
        # date, then gh release view <tag> --json assets to confirm the Complete Installer
        # shape) rather than assuming a combined query that this gh version cannot answer.
        $json = & gh release list --repo $script:KIStackVersionRegistryRepository --limit 100 --json tagName,isDraft,isPrerelease,publishedAt 2>$null
        # gh's own exit code is consumed by the check on the very next line and must never
        # survive past this function -- an expected, gracefully-handled failure here (no
        # network/no auth, exactly the shape a CI validation job without a GH_TOKEN produces)
        # would otherwise leave a stale non-zero $LASTEXITCODE sitting in the shared session-
        # global scope for every caller further up the stack (this is a real, reproduced defect:
        # scripts/Test-Repository.ps1 reported passed=true/37/37 while the pwsh.exe process still
        # exited 1, entirely due to this exact leak). Reset immediately after reading it, on both
        # the success and the failure branch, so a handled gh failure is never distinguishable
        # from a handled gh success by anything outside this function.
        $ghListFailed = ($LASTEXITCODE -ne 0)
        $global:LASTEXITCODE = 0
        if ($ghListFailed -or [string]::IsNullOrWhiteSpace($json)) { return [pscustomobject]@{ found = $false; tag = $null; reason = 'gh release list fehlgeschlagen (kein Netzwerk/keine Authentifizierung).' } }
        $releases = $json | ConvertFrom-Json -Depth 20
        $candidates = @($releases | Where-Object { (-not [bool]$_.isDraft) -and ($IncludePrerelease -or -not [bool]$_.isPrerelease) } |
            Sort-Object { [DateTime]$_.publishedAt } -Descending | Select-Object -First $MaxReleasesToScan)
        foreach ($candidate in $candidates) {
            $tag = [string]$candidate.tagName
            $assetJson = & gh release view $tag --repo $script:KIStackVersionRegistryRepository --json assets 2>$null
            $ghViewFailed = ($LASTEXITCODE -ne 0)
            $global:LASTEXITCODE = 0
            if ($ghViewFailed -or [string]::IsNullOrWhiteSpace($assetJson)) { continue }
            $assetNames = @(($assetJson | ConvertFrom-Json -Depth 20).assets | ForEach-Object name)
            if (@($assetNames -match '^KI-Stack-Complete-Installer-.+\.zip$').Count -gt 0) {
                return [pscustomobject]@{ found = $true; tag = $tag; reason = $null }
            }
        }
        return [pscustomobject]@{ found = $false; tag = $null; reason = "Kein veröffentlichter Complete-Installer-Release unter den letzten $($candidates.Count) Releases gefunden." }
    }
    catch {
        return [pscustomobject]@{ found = $false; tag = $null; reason = "Upstream-Prüfung fehlgeschlagen: $($_.Exception.Message)" }
    }
}

function Get-KIStackPublishedComponentVersion {
    # Reads exactly one component's own version value out of this repository's tree AT the
    # given published tag -- via GitHub's raw content endpoint (read-only, no locally cloned
    # source control checked out required; this must work identically whether run from this
    # repository or, in principle, from any host with outbound network access, since a deployed
    # KI-Stack target has no version-control metadata of its own at all). Never reads the local
    # working tree for this value -- see this module's header comment on Published vs Source
    # version.
    param(
        [Parameter(Mandatory)][object]$PackageIdentity,
        [Parameter(Mandatory)][string]$Tag,
        [int]$TimeoutSeconds = 15,
        [hashtable]$Fixture
    )
    if ($Fixture) {
        # Same indexer-syntax requirement as above (hashtable dot-access throws under
        # StrictMode for a genuinely absent key -- .ContainsKey is a method call and is fine).
        if ($Fixture.ContainsKey('error')) { return [pscustomobject]@{ found = $false; version = $null; reason = [string]$Fixture['error'] } }
        return [pscustomobject]@{ found = $true; version = [string]$Fixture['version']; reason = $null }
    }
    try {
        $kind = [string]$PackageIdentity.kind
        $rawBase = "https://raw.githubusercontent.com/$($script:KIStackVersionRegistryRepository)/$Tag"
        switch ($kind) {
            'file' {
                $text = Invoke-RestMethod -Uri "$rawBase/$([string]$PackageIdentity.path)" -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                $version = ([string]$text).Trim()
                if ([string]::IsNullOrWhiteSpace($version)) { throw 'Leere VERSION-Datei.' }
                return [pscustomobject]@{ found = $true; version = $version; reason = $null }
            }
            'jsonField' {
                $text = Invoke-RestMethod -Uri "$rawBase/$([string]$PackageIdentity.path)" -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                $obj = if ($text -is [string]) { $text | ConvertFrom-Json -Depth 20 } else { $text }
                $value = $obj.PSObject.Properties[[string]$PackageIdentity.field]
                if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value.Value)) { throw "Feld '$([string]$PackageIdentity.field)' fehlt oder ist leer." }
                return [pscustomobject]@{ found = $true; version = [string]$value.Value; reason = $null }
            }
            'jsonComposite' {
                $text = Invoke-RestMethod -Uri "$rawBase/$([string]$PackageIdentity.path)" -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                $obj = if ($text -is [string]) { $text | ConvertFrom-Json -Depth 20 } else { $text }
                $parts = @()
                foreach ($fieldName in @($PackageIdentity.fields)) {
                    $prop = $obj.PSObject.Properties[[string]$fieldName]
                    if ($null -eq $prop -or [string]::IsNullOrWhiteSpace([string]$prop.Value)) { throw "Feld '$fieldName' fehlt oder ist leer." }
                    $parts += [string]$prop.Value
                }
                $separator = if ($PackageIdentity.PSObject.Properties['separator']) { [string]$PackageIdentity.separator } else { '-' }
                return [pscustomobject]@{ found = $true; version = ($parts -join $separator); reason = $null }
            }
            default { throw "Unbekannter packageIdentity.kind: '$kind'" }
        }
    }
    catch {
        return [pscustomobject]@{ found = $false; version = $null; reason = "Veröffentlichte Version nicht lesbar: $($_.Exception.Message)" }
    }
}

function Resolve-KIStackComponentVersion {
    # Pure function -- no network, no disk access beyond what the caller already resolved into
    # its parameters. Combines InstalledVersion (already probed by the existing
    # Get-KICompleteInstalledVersion/probe contract in Contracts/COMPONENTS.json), the
    # component's versionSourceType/referenceComponent metadata, and an already-resolved
    # PublishedVersion (or a clear reason it could not be resolved) into the seven-value status
    # enum. Never treats VersionUnavailable as an error for a component whose versionSourceType
    # genuinely has no independent source (bundled-reference-only); for an own-version-file/
    # own-manifest-field component, VersionUnavailable means the lookup itself degraded
    # (offline, API error) -- reported plainly, never as a crash, never as a false
    # UpdateAvailable/UpToDate guess.
    param(
        [Parameter(Mandatory)][string]$ComponentId,
        [AllowNull()][AllowEmptyString()][string]$InstalledVersion,
        [Parameter(Mandatory)][string]$VersionSourceType,
        [AllowNull()][string]$PublishedVersion,
        [AllowNull()][string]$PublishedVersionSource,
        [bool]$PublishedVersionAvailable = $true
    )
    $result = [ordered]@{
        componentId = $ComponentId
        installedVersion = $InstalledVersion
        availableVersion = $PublishedVersion
        versionSource = $PublishedVersionSource
        status = 'Error'
    }

    if ($VersionSourceType -eq 'bundled-reference-only') {
        # No independent signal exists or is meaningful for this id at all (it rides on
        # another component's own resolution, applied by the caller before calling this
        # function again for the referenced id, or reported as-is by the caller). Reported
        # here as NotManaged-equivalent would be misleading (it IS managed, just not
        # independently observable) -- VersionUnavailable is the honest, correct answer, and
        # per the task's own explicit allowance this is not treated as a regression for a
        # component that structurally never had its own version to check.
        $result.status = 'VersionUnavailable'
        return [pscustomobject]$result
    }

    if (-not $PublishedVersionAvailable) {
        # Offline / API failure degrading the published-version lookup -- InstalledVersion is
        # still reported as-is (never hidden), no update-availability claim is made either way,
        # and this is never allowed to crash the caller.
        $result.status = 'VersionUnavailable'
        return [pscustomobject]$result
    }

    if ([string]::IsNullOrWhiteSpace($InstalledVersion)) {
        $result.status = 'NotInstalled'
        return [pscustomobject]$result
    }

    if ([string]::IsNullOrWhiteSpace($PublishedVersion)) {
        $result.status = 'VersionUnavailable'
        return [pscustomobject]$result
    }

    try {
        $cmp = Compare-KIStackSemVer -Left $InstalledVersion -Right $PublishedVersion
    }
    catch {
        $result.status = 'Error'
        $result.versionSource = "Vergleich fehlgeschlagen: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    $result.status = if ($cmp -eq 0) { 'UpToDate' } elseif ($cmp -gt 0) { 'NewerInstalled' } else { 'UpdateAvailable' }
    return [pscustomobject]$result
}

Export-ModuleMember -Function Compare-KIStackSemVer,Resolve-KIStackComponentVersion,Get-KIStackLatestPublishedCompleteInstallerRelease,Get-KIStackPublishedComponentVersion

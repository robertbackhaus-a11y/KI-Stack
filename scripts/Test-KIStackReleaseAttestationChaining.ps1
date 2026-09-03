[CmdletBinding()]
param([string]$RootPath = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Structural/static regression suite for the automatic release -> attestation chaining
# (.github/workflows/release-attestation.yml + attest-release.yml). GitHub Actions cannot be
# executed locally end to end, so this suite asserts the exact text/shape contract instead:
# trigger wiring, minimal permissions, dynamic (non-hardcoded) asset resolution, fail-closed
# behavior on missing artifacts, the re-verified SHA256/SBOM contract, the idempotency guard,
# and that no pull_request-shaped event can reach either workflow. Two negative controls at the
# bottom prove this suite would actually catch a regression in the two contracts the task calls
# out explicitly (trigger wiring, SBOM requirement), not merely restate that the current files
# look right.

$fail = [Collections.Generic.List[string]]::new()
$checks = [ordered]@{}

$attestPath = Join-Path $RootPath '.github/workflows/attest-release.yml'
$triggerPath = Join-Path $RootPath '.github/workflows/release-attestation.yml'
if (-not (Test-Path -LiteralPath $attestPath -PathType Leaf)) { throw "Missing: $attestPath" }
if (-not (Test-Path -LiteralPath $triggerPath -PathType Leaf)) { throw "Missing: $triggerPath" }
$attestText = Get-Content -LiteralPath $attestPath -Raw
$triggerText = Get-Content -LiteralPath $triggerPath -Raw

function Test-ReleaseAttestationChainingContract {
    # Pure function over the two workflow files' raw text so both the real files and the
    # negative-control patched copies below run through the exact same assertions.
    param([Parameter(Mandatory)][string]$AttestText, [Parameter(Mandatory)][string]$TriggerText)
    $c = [ordered]@{}

    $c.automaticTriggerConnectedToRelease = [ordered]@{
        releasePublishedTrigger = ($TriggerText -match '(?m)^\s*release:\s*$' -and $TriggerText -match '(?m)^\s*types:\s*\[published\]\s*$')
        callsReusableAttestWorkflow = ($TriggerText -match '(?m)^\s*uses:\s*\./\.github/workflows/attest-release\.yml\s*$')
    }

    $c.manualRecoveryPreserved = [ordered]@{
        workflowDispatchPresent = ($AttestText -match '(?m)^\s*workflow_dispatch:\s*$')
        allFourInputsRequired = (
            ($AttestText -match 'tag:\s*\n\s*description:[^\n]*\n\s*required:\s*true') -and
            ($AttestText -match 'zip_name:\s*\n\s*description:[^\n]*\n\s*required:\s*true') -and
            ($AttestText -match 'sidecar_name:\s*\n\s*description:[^\n]*\n\s*required:\s*true') -and
            ($AttestText -match 'sbom_name:\s*\n\s*description:[^\n]*\n\s*required:\s*true')
        )
    }

    $c.reusableWorkflowCallSingleImplementation = [ordered]@{
        workflowCallPresent = ($AttestText -match '(?m)^\s*workflow_call:\s*$')
        exactlyOneAttestJobName = (@([regex]::Matches($AttestText, [regex]::Escape('name: Attest final published ZIP and SBOM')))).Count -eq 1
        exactlyOneAttestJobKey = (@([regex]::Matches($AttestText, '(?m)^  attest:\s*$'))).Count -eq 1
    }

    $c.minimalPermissionsOnBothWorkflows = [ordered]@{
        attestPermissionsMinimal = (
            $AttestText -match '(?m)^permissions:\s*\n\s*contents:\s*read\s*\n\s*id-token:\s*write\s*\n\s*attestations:\s*write\s*$' -and
            $AttestText -notmatch '(?i)write-all'
        )
        triggerPermissionsMinimal = (
            $TriggerText -match '(?m)^permissions:\s*\n\s*contents:\s*read\s*\n\s*id-token:\s*write\s*\n\s*attestations:\s*write\s*$' -and
            $TriggerText -notmatch '(?i)write-all'
        )
    }

    $c.noPullRequestTrigger = [ordered]@{
        # Only a literal YAML trigger key counts as a regression here -- the word appearing in
        # an explanatory comment (e.g. documenting why pull_request can't reach this workflow)
        # must not itself trip this check.
        attestHasNoPrTrigger = ($AttestText -notmatch '(?m)^\s*pull_request(_target)?:')
        triggerHasNoPrTrigger = ($TriggerText -notmatch '(?m)^\s*pull_request(_target)?:')
    }

    $c.dynamicAssetResolutionNoHardcodedVersion = [ordered]@{
        regexBasedZipDiscovery = ($TriggerText -match [regex]::Escape('KI-Stack-Complete-Installer-.+\.zip'))
        derivesVersionFromAssetName = ($TriggerText -match 'KI-Stack-Complete-Installer-v\(\?<version>')
        readsVersionFromRepoFile = ($TriggerText -match [regex]::Escape("'tools/complete-installer/current/VERSION'"))
        noHardcodedSemverLiteral = (-not ([regex]::IsMatch($TriggerText, '\b\d+\.\d+\.\d+\b') -or [regex]::IsMatch($AttestText, '\b\d+\.\d+\.\d+\b')))
    }

    $c.failClosedOnMissingArtifacts = [ordered]@{
        missingSidecarThrows = ($TriggerText -match 'notcontains \$sidecarName.*\n?.*throw "FAIL-CLOSED')
        missingSbomThrows = ($TriggerText -match 'notcontains \$sbomName.*\n?.*throw "FAIL-CLOSED')
        ambiguousZipThrows = ($TriggerText -match 'zipCandidates\.Count -gt 1.*\n?.*throw "FAIL-CLOSED')
        versionMismatchThrows = ($TriggerText -match '\$assetVersion -ne \$repoVersion.*\n?.*throw "FAIL-CLOSED')
        missingVersionFileThrows = ($TriggerText -match 'Test-Path -LiteralPath \$versionFile\).*\n?.*throw "FAIL-CLOSED')
    }

    $c.sha256SbomContractReVerified = [ordered]@{
        rootPackageChecked = ($AttestText -match 'SPDXRef-Package')
        rootChecksumComparedToZip = ($AttestText -match '\$rootSha256 -ne \$actualZipSha256')
        sidecarCheckedFirst = ($AttestText -match 'sha256sum --check')
    }

    $c.idempotencyGuardPresent = [ordered]@{
        # Only attest-release.yml owns a concurrency group (see
        # noCollidingConcurrencyBetweenCallerAndReusableWorkflow below for why
        # release-attestation.yml must NOT also declare one). This still fully protects the
        # actual attestation work for both its entry points -- workflow_call from the trigger
        # workflow and a direct manual workflow_dispatch -- since both resolve to this exact
        # same group for the same tag.
        concurrencyGroupPerTag = ($AttestText -match '(?m)^\s*group:\s*attest-release-\$\{\{\s*inputs\.tag\s*\}\}')
        existingAttestationCountChecked = ($AttestText -match 'attestations/sha256:\$DIGEST')
        skipsOnlyWhenFullyAttested = ($AttestText -match '"\$COUNT" -ge 2')
    }

    $c.noCollidingConcurrencyBetweenCallerAndReusableWorkflow = [ordered]@{
        # release-attestation.yml's `attest` job invokes attest-release.yml via `uses:`
        # (workflow_call), which runs as a NESTED job inside the caller's own run -- not as an
        # independent run. If both workflows declared a top-level `concurrency:` group that
        # resolves to the same name for the same tag, the outer run would already hold that
        # group by the time its own nested job tried to acquire it again -- an unsatisfiable
        # self-wait that GitHub Actions detects and fails/cancels at job-scheduling time,
        # before the nested job is ever created (no logs). This is exactly what happened to
        # the real automatic v2.13.0 release attestation run (33739173060): `resolve`
        # succeeded, but `attest` was never created. Exactly ONE of the two workflows may own
        # the concurrency lock -- and it must be the reusable workflow, since that is the only
        # one reachable from both entry points (automatic workflow_call and manual
        # workflow_dispatch).
        exactlyOneWorkflowDeclaresTopLevelConcurrency = (
            (@([regex]::Matches($TriggerText, '(?m)^concurrency:\s*$'))).Count +
            (@([regex]::Matches($AttestText, '(?m)^concurrency:\s*$'))).Count
        ) -eq 1
        reusableWorkflowIsTheOneThatOwnsIt = ($AttestText -match '(?m)^concurrency:\s*$')
        triggerWorkflowDoesNotAlsoDeclareIt = ($TriggerText -notmatch '(?m)^concurrency:\s*$')
    }

    $c.scopeGuardForNonCompleteInstallerReleases = [ordered]@{
        skipsCleanlyWhenNoMatchingZip = ($TriggerText -match 'applicable=false' -and $TriggerText -match 'zipCandidates\.Count -eq 0')
        doesNotThrowOnUnrelatedRelease = ($TriggerText -match 'exit 0')
    }

    $c.repositoryGuardPresent = [ordered]@{
        pinnedToUpstreamRepo = ($TriggerText -match "if:\s*github\.repository == '[\w.-]+/[\w.-]+'")
    }

    $c
}

$checks = Test-ReleaseAttestationChainingContract -AttestText $attestText -TriggerText $triggerText
foreach ($group in $checks.Keys) {
    if ($checks[$group].Values -contains $false) {
        $fail.Add("$group failed: " + ($checks[$group] | ConvertTo-Json -Compress))
    }
}

# --- Negative Control A: remove the automatic trigger wiring, prove the suite catches it,
# then confirm the real file is green again (already asserted above, re-stated here for the
# report's explicit "trigger removed -> fails, restored -> green" narrative). --------------
$triggerTextNoAutoTrigger = $triggerText -replace '(?m)^on:\s*\n\s*release:\s*\n\s*types:\s*\[published\]\s*\n', "on:`n  workflow_dispatch:`n"
if ($triggerTextNoAutoTrigger -eq $triggerText) { throw 'Negative-Control-A-Patch griff nicht -- Testannahme verletzt (release/published-Trigger-Block nicht gefunden).' }
$negativeAChecks = Test-ReleaseAttestationChainingContract -AttestText $attestText -TriggerText $triggerTextNoAutoTrigger
$checks.negativeControlA_TriggerRemovalDetected = [ordered]@{
    patchedCopyFailsAutomaticTriggerCheck = ($negativeAChecks.automaticTriggerConnectedToRelease.Values -contains $false)
    originalFilePassesAutomaticTriggerCheck = ($checks.automaticTriggerConnectedToRelease.Values -notcontains $false)
}
if ($checks.negativeControlA_TriggerRemovalDetected.Values -contains $false) { $fail.Add('negativeControlA_TriggerRemovalDetected failed -- removing the release/published trigger was not detected, or the real file does not pass to begin with.') }

# --- Negative Control B: remove the SBOM requirement (the SBOM attest step and its input),
# prove the suite detects the asset contract is now incomplete, then confirm the real file is
# green again. ------------------------------------------------------------------------------
$attestTextNoSbom = $attestText -replace '(?s)\s*- name: Attest SPDX SBOM for exact ZIP bytes.*?sbom-path: release/\$\{\{ inputs\.sbom_name \}\}\r?\n', "`n"
$attestTextNoSbom = $attestTextNoSbom -replace '(?s)\s*- name: Verify SHA256 contract \(ZIP == Sidecar == SBOM root package\).*?SBOM root package \(\$actualZipSha256\)"\r?\n', "`n"
if ($attestTextNoSbom -eq $attestText) { throw 'Negative-Control-B-Patch griff nicht -- Testannahme verletzt (SBOM-Schritte im Workflow nicht gefunden).' }
$negativeBChecks = Test-ReleaseAttestationChainingContract -AttestText $attestTextNoSbom -TriggerText $triggerText
$checks.negativeControlB_SbomRequirementRemovalDetected = [ordered]@{
    patchedCopyFailsSbomContractCheck = ($negativeBChecks.sha256SbomContractReVerified.Values -contains $false)
    originalFilePassesSbomContractCheck = ($checks.sha256SbomContractReVerified.Values -notcontains $false)
}
if ($checks.negativeControlB_SbomRequirementRemovalDetected.Values -contains $false) { $fail.Add('negativeControlB_SbomRequirementRemovalDetected failed -- removing the SBOM contract step was not detected, or the real file does not pass to begin with.') }

# --- Negative Control C: reintroduce the exact colliding concurrency block on the caller
# workflow that caused the real automatic v2.13.0 release attestation run (33739173060) to
# fail -- a top-level `concurrency:` group on release-attestation.yml resolving to the same
# name attest-release.yml's own group already uses for the same tag. Prove the suite detects
# this exact regression, then confirm the real file is green again. -------------------------
$triggerTextReintroducedCollidingConcurrency = $triggerText -replace `
    '(?m)^(permissions:\s*\n\s*contents:\s*read\s*\n\s*id-token:\s*write\s*\n\s*attestations:\s*write\s*\n)', `
    "`$1`nconcurrency:`n  group: attest-release-`${{ github.event.release.tag_name }}`n  cancel-in-progress: false`n"
if ($triggerTextReintroducedCollidingConcurrency -eq $triggerText) { throw 'Negative-Control-C-Patch griff nicht -- Testannahme verletzt (permissions-Block im Trigger-Workflow nicht gefunden).' }
$negativeCChecks = Test-ReleaseAttestationChainingContract -AttestText $attestText -TriggerText $triggerTextReintroducedCollidingConcurrency
$checks.negativeControlC_CollidingConcurrencyReintroductionDetected = [ordered]@{
    patchedCopyFailsNoCollisionCheck = ($negativeCChecks.noCollidingConcurrencyBetweenCallerAndReusableWorkflow.Values -contains $false)
    originalFilePassesNoCollisionCheck = ($checks.noCollidingConcurrencyBetweenCallerAndReusableWorkflow.Values -notcontains $false)
}
if ($checks.negativeControlC_CollidingConcurrencyReintroductionDetected.Values -contains $false) { $fail.Add('negativeControlC_CollidingConcurrencyReintroductionDetected failed -- reintroducing the colliding concurrency group on the caller workflow was not detected, or the real file does not pass to begin with.') }

$passed = $fail.Count -eq 0
[pscustomobject]@{ passed = $passed; checks = $checks; failures = @($fail) } | ConvertTo-Json -Depth 12
if (-not $passed) { throw 'Release-Attestation-Chaining-Regression fehlgeschlagen.' }

# KI-Stack Complete Installer v2.6.0

Development release. Builds on the Greenfield-validated 2.5.0 base and completes RAG's remote-rollback validation: Rollback of all three mutating actions (Add, Replace, Remove) is now real target-system validated, not just Add.

- Complete Installer: 2.6.0
- RAG: 0.3.1 (patch: real-target-verified rollback completion, one bug fix)
- Other component versions: unchanged from 2.5.0; see the active-components table in the technical documentation

## Scope: RAG-module-only

No installer/build code changed in this cycle. `CompleteInstaller.psm1` and the payload/build pipeline are unmodified; only informational version literals and the RAG component's own installed-version marker were updated to match. 2.5.0's own Greenfield installation, reboot/resume, and RC-build-validation evidence therefore carries forward unchanged and was not re-run for this release.

## Verified with real target-system runs

Continuing the same live-target discipline used for 2.5.0's Execute and Add-Rollback validation:

- **Replace-Rollback**: Add → Replace → Rollback executed against a real, running OpenWebUI 0.11.0 instance. Verified at every step with real remote evidence (old content genuinely deleted after Replace, not merely detached; restored content after Rollback byte-verified against the original pre-Replace text). A repeated Rollback call confirmed as a clean, idempotent no-op.
- **Remove-Rollback**: Add → Remove → Rollback executed the same way. The removed content is restored remotely and locally with its original hash and byte content. A repeated Rollback call confirmed as a clean, idempotent no-op.
- All test artifacts (the isolated test Knowledge collection and local test fixture) were removed afterward through product-path means only; no manual database manipulation.

## Fix folded into this release

- **RAG Rollback retry, Replace/Remove restore path**: a dedicated partial-failure-then-retry regression test (mirroring the existing Add-path scenario) found that a partially-failed Replace/Remove Rollback could fail its own retry: it re-issued a remove call against remote content an earlier partial attempt had already deleted, and the real server correctly rejects that with HTTP 400. `Remove-RAGRemoteEntry` now treats an already-removed target as already-satisfied instead of propagating that error, matching the real server's own idempotent-delete semantics. Any other failure (5xx, network errors, etc.) still propagates normally. Verified with a negative control: reverting the fix reproduces exactly and only the new regression test's failure.

## Regression coverage documented

Four defects found and fixed during the 2.5.0 cycle, previously undocumented in the formal regression ledger, were added as named entries in `Validation/REGRESSION-COVERAGE.json` (REG-030 through REG-033): the PowerShell 5.1 `ConvertFrom-Json -Depth` and `Set-Content -Encoding utf8NoBOM` incompatibilities in the RAG mock test harness, the `Start-Process -ArgumentList` empty-string-drop, and the Models/Workflows `Receive-Artifact` HTTP 416 resume defect.

## Known manual follow-up

Unchanged from 2.5.0: without a supplied OpenWebUI administrator API key, the temporary Knowledge bootstrap-experiment rollback and the Code Interpreter connection configuration remain manual follow-up steps in OpenWebUI after installation (`CredentialRequiredForApiReadback` / `CredentialRequiredForApiConfiguration`).

The authoritative Complete Installer ZIP hash is published only in the adjacent `.sha256` sidecar and the GitHub Release description.

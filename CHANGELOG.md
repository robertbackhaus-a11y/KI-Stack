# Changelog

## Production Target Acceptance 1.0.8 — target-system validated

- Recorded `TARGET_SYSTEM_ACCEPTANCE_PASSED` from the sanitized target-system report.
- Published complete reusable source trees for Validation Gate 1.0.2, Target Acceptance 1.0.8 and Production Recovery 1.7.0-r5.
- Kept Recovery, Target Acceptance and Runtime Core ZIP binaries as release assets referenced by SHA-256 artifact contracts.
- Repaired two operational-overlay drift files and validated the remaining 30 files unchanged.
- Completed controlled stop/start and endpoint acceptance for SearXNG, Open WebUI, LM Studio and ComfyUI.
- Kept the accepted runtime version at Cutover 1.6.3; Production Recovery 1.7.0-r5 is not a runtime-version increment.

## Integration 1.5.7-rc1 — CMD lifecycle gate precision

- Keeps result/exitcode visible until one key is pressed.
- Restricts lifecycle checks to the exact `:Finish` label block.
- Prevents helper-function `exit /b 0` returns from causing false failures.

## Integration 1.5.6-rc1 — acknowledged result and release publisher repair

- Restores keypress-to-close behavior for successful and failed CMD runs.
- Replaces stale hard-coded release assets with the current bundle manifest.
- Validates every release asset before GitHub CLI invocation.

## Integration 1.5.5-rc1 — regression-hardened release candidate

- Fixes NUL-character removal from WSL distribution output.
- Adds a mandatory historical regression gate before every action.
- Preserves target-only GitHub snapshot architecture.

## Integration 1.5.4-rc1 — regression-hardened release candidate

- Fixes NUL-character removal from WSL distribution output.
- Adds a mandatory historical regression gate before every action.
- Preserves target-only GitHub snapshot architecture.

## Integration 1.5.3-rc1 — regression-hardened release candidate

- Fixes NUL-character removal from WSL distribution output.
- Adds a mandatory historical regression gate before every action.
- Preserves target-only GitHub snapshot architecture.

## Integration 1.5.2-rc1 — release candidate

- Returns an explicit four-endpoint Dry-Run contract.
- Validates SearXNG, Open WebUI, LM Studio and ComfyUI as named endpoints.
- Corrects Integration early-start emergency-log identity.
- Restores the explicit StrictMode-safe embedded GitHub wrapper exit code.

## Integration v1.5.1-rc1

- Correct Integration starter package validation and inherited launcher identities.

# KI-Stack Changelog

## Integration v1.5.1-rc1

- Enables WSL2/Debian and SearXNG as the seventh transacted Execute module.
- Adopts healthy existing SearXNG JSON endpoints and installs a pinned official fallback only when needed.
- Adds Open WebUI SearXNG environment integration, WSL keeper, health checks, and non-destructive rollback.

## Applications v1.4.10 — stable

- Promotes the unchanged LM Studio and Open WebUI 0.10.2 implementation using Production Target Acceptance 1.0.8 as the target-system evidence.
- Makes Git author publisher-contract checks StrictMode-safe by using non-expandable source literals.
- Prevents validator-side evaluation of `$GitAuthorName`, `$GitAuthorEmail`, and `$workPath`.
- Keeps repository-local Git identity validation and target-only snapshot publication.

## Applications v1.4.9-rc1

- Sets repository-local Git author name and email in the temporary clone.
- Validates both identity values before commit and annotated tag creation.
- Leaves global Git configuration unchanged.
- Resumes from all recognized previous tree stages.

## Applications v1.4.8-rc1

- Removes historical snapshot files from GitHub update bundles.
- Recognizes previous repository stages by Git tree hash only.
- Bundles and validates only the current target snapshot and current release assets.
- Propagates bundle validation failures through PowerShell and CMD exit codes.


- Fixes version validation and GitHub wrapper exit-code handling.

## Applications 1.4.6-rc1 — release candidate

- Fixes immutable historical snapshot handling in the GitHub update bundle.

## Applications 1.4.5-rc1 — release candidate

- Restores persistent CMD diagnostics by returning from the bootstrap with `exit /b`.
- Adds a complete start-chain regression across all three entry starters.

## Applications 1.4.4-rc1 — release candidate

- Repairs mixed 1.4.1/1.4.2 active version metadata.
- Aligns SelfTest contracts with the actual Python resolver implementation.
- Adds a stale active-version regression gate.

## Applications 1.4.3-rc1 — release candidate

- Repairs mixed 1.4.1/1.4.2 active version metadata.
- Aligns SelfTest contracts with the actual Python resolver implementation.
- Adds a stale active-version regression gate.

## Applications 1.4.2-rc1 — release candidate

- Fixes incomplete Applications Dry-Run transaction fixture.
- Corrects stale reference version assertions.
- Aligns Python resolution regression with the actual implementation.
- Repairs the embedded GitHub updater version/root mismatch.

## Applications 1.4.1-rc1 — release candidate

- Fixes optional Windows uninstall-registry properties under PowerShell StrictMode.
- Resolves and validates Python 3.11/3.12 explicitly.
- Prints the exact failed module and error for kernel exit code 30.
- Adds transaction-local Applications diagnostics.

## Applications 1.4.0-rc1 — release candidate

- Adds non-destructive LM Studio installation and validation.
- Pins Open WebUI to 0.10.2 in an isolated venv.
- Adds local start/stop scripts and transaction-aware rollback.
- Embeds GitHub update v0.3.0.

## Models / Workflows 1.3.7 — stable

- Promotes the target-system accepted FLUX2 model and workflow set to the required release profile.
- Classifies KREA and Pony as optional add-on profiles whose absent models do not block release validation.
- Corrects GitHub bundle snapshot classification.
- Keeps known failed historical snapshots as resume-only states.
- Embeds GitHub update v0.2.7.
- Runtime logic remains functionally unchanged from v1.3.6.

# Changelog

## Models / Workflows 1.3.6-rc1 — release candidate

- Replaces protected `$input` stream assignment with `$responseStream`.
- Updates the model-manifest regression contract to schema 1.1.
- Embeds GitHub update v0.2.6.

## Models / Workflows 1.3.5-rc1 — release candidate

- Removes UTF-8 BOM from every CMD starter and enforces CRLF.
- Fixes the invalid trailing comma in the starter required-path array.
- Runs native PowerShell parsing before importing the starter module.
- Adds end-to-end path checks for simple, double-nested and space-containing package paths.
- Includes the matching GitHub update directly in the delivered execute package.



## Models / Workflows 1.3.4-rc1 — release candidate

- Removes the external Preflight ZIP dependency by embedding a continuation input.
- Keeps explicit Preflight paths as an override.
- Includes the matching GitHub repository update in the delivered package.
- Retains native PowerShell AST, rollback, source-integrity and historical regression gates.


## Models / Workflows 1.3.3-rc1 — release candidate

- Corrects the Integration Dry-Run expectation from five modules to four integration endpoints.
- Derives expected endpoint count from the actual integration contract.
- Adds a permanent regression for the four endpoints SearXNG, Open WebUI, LM Studio and ComfyUI.
- Retains all historical starter, StrictMode, AST, rollback and source-integrity checks.

## ComfyUI 1.2.1 — stable

- Target-system validation completed successfully.
- Corrected the self-test source-literal interpolation regression.
- Retains pinned ComfyUI v0.28.0, CUDA 13.0 and RTX 5090 validation.
- Supersedes the v1.2.0 release candidate.

## ComfyUI 1.2.0-rc1 — release candidate

- Added complete ComfyUI module.
- Pinned the configured ComfyUI repository reference.
- Added isolated virtual environment and managed runtime starters.
- Added NVIDIA CUDA/PyTorch and device validation.
- Added centralized model, input, output and user paths.
- Added ComfyUI-specific rollback handling and regression checks.

## PythonGit 1.1.5 — stable

- Target-system validated Python/Git reference package.
- Full regression matrix through v1.1.5.

## Foundation / Runtime 1.0.9 — stable reference

- Frozen predecessor reference.

## 1.6.1

- Added final cutover, health and acceptance reporting.

## 1.6.2

- Fixed final validation and Cutover diagnostic regression contracts.

## 1.6.3

- Fixed GitHub repository validator manifest schema compatibility under StrictMode.

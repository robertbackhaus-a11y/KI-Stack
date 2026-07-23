# Changelog

## Models / Workflows 1.4.4 and Complete Installer 2.2.4

- Adds matched German and English technical documentation and operations/user guides.
- Documents architecture, lifecycle, model contracts, profile bindings, code capability, services, workflows, known limitations and release procedure without changing functional behavior.
- Adds the documentation index to repository and package readmes; model files remain external and both packages remain non-offline.

## Models / Workflows 1.4.2 and Complete Installer 2.2.2

- Adds the public `Start-KIStack-Model-Import.cmd` and `Import-KIStackExternalModels.ps1` entry points for one transactional import of all eight external models.
- Uses `ExternalModels` beside the extracted package by default and accepts an explicit `-SourcePath`; files are validated before a `.partial` copy is atomically moved into place.
- Returns `WaitingForUserAction` with exact filename, size, SHA256 and source path when manual models are absent, while preserving transaction resume and scoped rollback.
- Requires all eight models and all managed workflows before writing or accepting the Models / Workflows marker. Pony V6 XL retains fixed Civitai model version `290640`; no Git, commit or latest source is used.

## Models / Workflows 1.4.1 and Complete Installer 2.2.1

- Replaces personal positive defaults in the FLUX2, KREA, Pony SDXL and WAN 2.2 UI workflows with neutral landscape prompts without changing graph structure, negative prompts, models or technical parameters.
- Keeps the released FLUX2 OpenWebUI API workflow unchanged because it contains no personal default prompt.
- Marks the seven Hugging Face contracts as manual external dependencies instead of using Git commit hashes as installation sources; fixed Civitai model version `290640` remains the only automatic source among the eight optional models.
- Adds `ae.safetensors` to `externalManualDependencies`; model sizes and SHA256 contracts remain unchanged.

## Models / Workflows 1.4.0 and Complete Installer 2.2.0

- Adds the target-system-validated canonical KREA, Pony SDXL and WAN 2.2 workflows while preserving the approved FLUX2 UI and API workflows byte-for-byte.
- Pins eight external model contracts by immutable HTTPS source, file name, byte size, SHA256, license/redistribution status and relative target path.
- Reuses matching existing model files and acquires only missing external files; no model is embedded in Git or package ZIPs.
- Records 47,356,936,991 bytes of external model dependencies and explicitly keeps the Complete Installer non-offline and Git-free.
- Keeps superseded workflow duplicates, broken backups, archives and the OpenWebUI generation mapping outside the canonical workflow set.

## Persistent OpenWebUI images — Image Pack 1.9.1 and Complete Installer 2.1.3

- Registers generated PNG files through OpenWebUI's supported file store and attaches them to the assistant message with `chat:message:files`.
- Keeps the image visible and downloadable after chat reload without `/mnt/uploads`, absolute Windows paths or direct ComfyUI URLs.
- Updates only the embedded Image Pack in Complete Installer 2.1.3; Models / Workflows 1.3.8 and ComfyUI 1.2.2 remain unchanged.

## OpenWebUI Ballistics Pack 1.0.0 and Complete Installer 2.1.0

- Adds the exclusively bound OpenWebUI 0.10.2 profile `ki-stack-18bravo` (`18Bravo`) and tool `ki_stack_ballistics_calculator` for lawful sporting, hunting and engineering calculations.
- Pins `pyballistic` 2.2.0 by exact wheel name, byte size and SHA256 and uses only its pure-Python RK4 engine for G1/G7.
- Adds validated input/output/CSV/profile contracts, synthetic fixtures, explicit-save local profiles, backup and rollback without secrets or personal paths.
- Adds Ballistics Pack 1.0.0 as an optional, supported Complete Installer 2.1.0 component while preserving every 2.0.0 component and user data.

## System Cleanup Audit 1.0.0

- Adds a read-only inventory for plausible KI-Stack locations, relevant WSL distributions, tasks, firewall rules, environment variables, processes and ports.
- Protects the production root, repository, user data, models, workflows, current runtime and foreign Git worktrees through conservative classification.
- Produces a sanitized audit and SHA256-bound pending cleanup plan; Execute remains disabled until a separate explicit approval and irreversible deletion is not implemented.
- Validates classification, quarantine and rollback behavior only in isolated fixtures; no real file was moved or deleted.

## Git-free component payloads and Complete Installer 2.0.0

- Promotes ComfyUI 1.2.2 and Integration 1.5.9 with immutable file, size and SHA256 contracts and no Git dependency at package runtime.
- Migrates the healthy existing target by verified content without reinstalling models, workflows, user data or the working SearXNG runtime.
- Adds Complete Installer 2.0.0 with audit, install/reconcile, repair, validation, rollback, resume and centralized lifecycle entry points.
- Fresh installation is contract- and fixture-validated; physical validation is limited to the existing installation.

## OpenWebUI built-in Code Interpreter — Agent Pack 1.8.3

- Enables OpenWebUI's built-in Pyodide Code Interpreter with Native Function Calling for Allgemein and KI & IT-Technik; 18Bravo remains disabled.
- Keeps `knowledge=[]` and the existing single-purpose Image and Ballistics tool bindings; `execute_code` is not registered as a workspace tool.
- Complete Installer 2.1.2 applies the target-validated configuration transactionally with a private rollback backup.
- Complete Installer 2.1.2 now separates its pause-free read-only status core from the interactive desktop status starter, which remains visible until a key is pressed and reports the real exit code.
- Agent Pack and Complete Installer starters now enforce PowerShell 7 end-to-end, reject Windows PowerShell 5.1 before API work, and preserve exit codes without exposing SecureString API credentials.

## OpenWebUI direct image generation — Agent Pack 1.8.2 and Image Pack 1.9.0

- Adds exactly one managed OpenWebUI tool, `ki-stack-generate-image`, backed by the existing FLUX2 Klein 9B ComfyUI workflow.
- Supports prompt, `1:1`, `16:9` and `9:16` output plus an optional seed without downloading models or enabling optional KREA/Pony profiles.
- Updates both managed Agent Pack profiles to preserve only the registered KI-Stack Image Pack tool binding and remain unbound when the extension is absent.
- Provides deterministic package builders, SelfTest, DryRun, targeted backup, rollback and target validation sources.
- Target-system validation passed with real 512 x 512 and 768 x 432 PNG renders, non-image routing, invalid-ratio rejection, rollback, final reinstall and API readback.

## SearXNG runtime repair — Integration 1.5.8, Recovery r7, Target Acceptance 1.0.10, Agent Pack 1.8.1

- Repairs cold starts by using the installed Debian standard chain `valkey-server`, `uwsgi` and `nginx`; no nonexistent product-specific systemd unit is assumed.
- Replaces blind keeper PID trust with CIM identity checks and the stable `wsl.exe --exec sleep infinity` invocation.
- Prevents a parallel SearXNG installation when a standard configuration exists, and requires HTML plus nonempty JSON-search evidence.
- Validates cold start, stale-PID recovery, idempotent restart, partial uWSGI repair, controlled stop/start and all four production endpoints.
- Promotes Production Recovery `1.7.0-r7` to `TargetSystemAccepted` through Target Acceptance `1.0.10` against the final recovery artifact.
- Validates OpenWebUI Agent Pack `1.8.1` with Integration 1.5.8, duplicate-free profile readback, a technical chat and a real SearXNG-backed web-search chat.
- Supersedes the SearXNG runtime-evidence claims of r6/Target Acceptance 1.0.9 and Agent Pack 1.8.0 without deleting their historical release records.

## OpenWebUI Agent Pack 1.8.0 — stable and target-system validated

- Adds canonical definitions for exactly `KI & IT-Technik` and `Allgemein` with stable technical IDs.
- Uses the supported OpenWebUI 0.10.2 model create, update, readback and delete APIs with runtime-only Bearer authentication.
- Provides SelfTest, DryRun, idempotent install, affected-object backup, validation and rollback.
- Keeps model binding configurable and leaves knowledge bases, tools, skills, functions and other user content unchanged.
- Documents global SearXNG configuration as the web-search runtime dependency because 0.10.2 has no model-profile web-search field.
- Confirms idempotent Execute, affected-object backup and rollback, API readback, isolated resource scope and real chats including SearXNG-backed web search.

## Production Target Acceptance 1.0.9 — target-system validated

- Promoted Production Recovery `1.7.0-r6` to `TargetSystemAccepted` using the final deterministic recovery artifact.
- Reused the existing acceptance logic with the r6 artifact contract and Target Acceptance package `1.0.9`.
- Replaced personal LM Studio paths with portable runtime resolution and hardened controlled ComfyUI stop against process-exit races.
- Confirmed idempotence, drift repair with backup, controlled stop/start and SearXNG, Open WebUI 0.10.2, LM Studio and ComfyUI endpoints.
- Retained Production Recovery `1.7.0-r5` as the published and accepted predecessor.

## Production Target Acceptance 1.0.8 — target-system validated

- Recorded `TARGET_SYSTEM_ACCEPTANCE_PASSED` from the sanitized target-system report.
- Published complete reusable source trees for Validation Gate 1.0.2, Target Acceptance 1.0.8 and Production Recovery 1.7.0-r5.
- Kept Recovery, Target Acceptance and Runtime Core ZIP binaries as release assets referenced by SHA-256 artifact contracts.
- Repaired two operational-overlay drift files and validated the remaining 30 files unchanged.
- Completed controlled stop/start and endpoint acceptance for SearXNG, Open WebUI, LM Studio and ComfyUI.
- Kept the accepted runtime version at Cutover 1.6.3; Production Recovery 1.7.0-r5 is not a runtime-version increment.

## Integration 1.5.7 — stable

- Promotes the unchanged integration implementation using Production Target Acceptance 1.0.8 as the target-system evidence.
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
# Complete Installer 2.1.2 operations preparation

- Prepares a manual-start-only operating contract without changing Applications, Agent Pack, Image Pack, Ballistics Pack, Models / Workflows or ComfyUI content.
- Removes only positively identified KI-Stack autostarts, disables Debian `valkey-server`, `uwsgi` and `nginx` boot enablement while preserving central manual start, and creates managed Start, Stop and Status desktop shortcuts.
- Adds transaction-bound backup, readback and operations rollback. Final status is `TargetValidated` after the controlled cold-reboot acceptance.
- Removes the former OpenWebUI knowledge experiment as a dependency: all three managed profiles use `knowledge=[]`; no KI-Stack collection, imported file or RAG binding remains.

# Models / Workflows 1.3.8 and Complete Installer 2.1.1

- Replaces the incomplete synthetic FLUX2 UI graph with the ComfyUI-saved, target-system-accepted `KI-Stack-FLUX2-Text-to-Image-v1.3.8.json` workflow.
- Fixes `No link found in parent graph for id [11] slot [0] clip`; the complete graph has 6 nodes, 5 links, one sampling path, PreviewImage and SaveImage and passed manual user acceptance.
- Keeps the OpenWebUI API workflow byte-identical and documents the FP8 diffusion model, FP8-mixed Qwen encoder, FLUX2 VAE, Euler sampler, Flux2Scheduler and Guidance 1 contract.
- Defers KREA, Pony and ControlNet without placeholder workflows or automatic optional-model downloads.
- Complete Installer 2.1.1 upgrades only Models / Workflows 1.3.7 to 1.3.8 and preserves every other component and user-owned path.

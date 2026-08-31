# KI-Stack Complete Installer v2.13.0

Feature and real-target-validated release. Base: 2.12.0.

- Complete Installer: 2.13.0 (base: 2.12.0)
- Status: `ComponentIsolation_VersionRegistry_ReleaseAttestation_CodexLocalIsolatedHome_OpenWebUICredentialBootstrap_ResearchAgentWebSearchValidation`
- Component pins: ComfyUI 1.2.4, Models/Workflows 2.0.3, Applications 1.4.11, Integration 1.5.11, Cutover Runtime 1.6.14, Production Recovery 1.7.0-r7, Validation Gate 1.0.3, Target Acceptance 1.0.10, OpenWebUI Visual Pack 2.0.5, OpenWebUI Agent Pack 1.9.0, OpenWebUI Ballistics Pack 1.0.0, **Codex Local 0.2.1** (was 0.1.4), RAG 0.4.0.
- Repository validation (`scripts/Test-Repository.ps1`): 37/37 passed. PackageSelfTest: 28/28 passed. Deterministic double-build confirmed (byte-identical ZIP, same SHA256). SPDX-2.3 SBOM generated and cross-checked against the ZIP and its sidecar.

## Highlights

### Component isolation for the central updater

`Update-KIStack-All.ps1`'s single-component selection previously always fell through to a full `Invoke-KIStackCompleteInstaller -Mode Upgrade` batch run, which unconditionally also re-deploys the orchestrator/central-starter/Operations files and, whenever an OpenWebUI API token was supplied, the Knowledge-experiment rollback and Code-Interpreter-configuration steps -- independent of which single component was actually requested. `Contracts/COMPONENTS.json` now classifies every component into an explicit isolation class (self-contained "A", a component with a real dependency such as RAG-on-Integration "B", or "C" for components that must keep going through the full Complete Installer orchestrator). `KIStackUpdateIsolation.psm1` adds a pure planning function (`Resolve-KIStackUpdatePlan`) plus `Invoke-KIStackIsolatedComponentUpdate`, which calls a class A/B component's own, already self-contained install/backup/rollback entry point directly, without ever invoking the full orchestrator, and detects any dependency cycle up front rather than risking silent infinite recursion.

### Internal component version registry

`Update-KIStack-All.ps1`'s report previously always showed `AvailableVersion=Unknown` for every KI-Stack-authored ("Klasse B") component -- only OpenWebUI (PyPI) and the git-revision-pinned ComfyUI/Integration upstream checks ever resolved a real value. `KIStackComponentVersionRegistry.psm1` adds a second, purely informational signal: the authoritative published version for a Klasse-B component is read from its own `VERSION`/manifest field at the commit tagged by the latest published Complete Installer release (via GitHub's raw content endpoint, or a fixture in tests) -- never the component's own legacy, now-abandoned per-component release channel, and never the local working tree. This module never installs, upgrades, or rolls back anything; the existing installed-vs-pinned classification and update decision are unchanged.

### Automatic release attestation chaining

A new `release-attestation.yml` workflow reacts to `release: published`, independently re-verifies that the exact required Complete Installer assets (ZIP, SHA256 sidecar, SPDX SBOM) are actually present on that release, and then calls the existing, previously manual-only `attest-release.yml` via `workflow_call` -- sharing the identical attestation job/steps rather than duplicating them. `attest-release.yml` itself is unchanged in what it attests; it now also independently re-verifies the ZIP == sidecar == SBOM-root-package SHA256 contract against the actually-downloaded, published assets (the same contract already validated locally by `Test-Repository.ps1`), applied at a different point in the pipeline.

### Codex Local 0.2.1: isolated `CODEX_HOME`

Codex Local previously derived its working state from the ambient, shared `%USERPROFILE%\.codex` whenever no explicit override was set -- a real architecture defect, since pre-existing state there could influence (and was reproduced causing a wrong-model auto-download for) a managed, supposedly self-contained component. `CodexLocal.psm1` now computes its own isolated `CODEX_HOME` (`state/codex-local/codex-home` under the component's `TargetRoot`) purely as a function of `TargetRoot`, and sets it explicitly for every real invocation (the generated starter, `Get-KICodexVersion`, `Invoke-KICodexAnalysisAcceptance`, the npm install calls, and the Complete Installer's own compliance probe) -- never reading or depending on the ambient `$env:CODEX_HOME`.

Validated via `Test-KIStackCodexLocalIsolation.ps1` (fast, network-free, including a negative control proving a reversion would regain ambient influence, and a real byte-snapshot proof that the real `%USERPROFILE%\.codex` is untouched), `Test-KIStackCodexLocalOperationalization.ps1` (real npm/network lifecycle against a hostile foreign ambient `CODEX_HOME`), and a real production upgrade of the existing target from 0.1.4 to 0.2.1 followed by a real `codex exec` end-to-end call through the newly isolated home.

### OpenWebUI credential bootstrap

A new, DPAPI-backed local credential store (`KIStackOpenWebUICredential.psm1` plus `Initialize-/Test-/Remove-KIStackOpenWebUICredential.ps1`) lets an operator run a one-time interactive admin login against their own OpenWebUI instance, which mints a real, persistent API key (enabling `ENABLE_API_KEYS` via the official admin-config API first, since it defaults to disabled) and stores it encrypted -- never in plaintext, never in the repository -- via PowerShell's built-in DPAPI-backed `SecureString` conversion. `Start-KIStackCompleteInstaller.ps1` now resolves this stored credential first and only falls back to the original one-time interactive prompt when none is configured; this is purely additive. Real target validation: real admin signin, a real API key minted, and a real Knowledge collection created and read back through the real OpenWebUI 0.11.1 API, with no plaintext secret in the stored credential file and no foreign user or key touched.

### Research agent web search: root cause and real proof

Root-caused, precisely: native function-calling tool injection (`search_web`/`fetch_url`) in the real, installed OpenWebUI 0.11.1 source is gated on a non-empty `metadata.session_id` -- a plain Bearer-token API call without one never receives the tool at all, independent of the agent's own configuration. With a `session_id` present, both tool injection and the model's own tool-calling behavior are correct. OpenWebUI's own further automatic background-task execution of that tool call has a separate, real, reproducible stall after the initial `knowledge_search` step for non-browser callers -- documented as a genuine OpenWebUI-core limitation, not an Agent Pack or model defect, and out of scope to patch from this repository. No Agent Pack code change was required: `ki-stack-research`'s own provisioned fields were already correct. A complete, real, non-mocked end-to-end proof (real SearXNG query, real `fetch_url` call, correct final answer citing current, real data) was achieved by completing the standard OpenAI-compatible tool-calling round trip manually.

## Consolidation fixes

- **Desktop-shortcut isolation**: `Install-KICompleteOperations`/`Test-KICompleteOperations` called `[Environment]::GetFolderPath('Desktop')` unconditionally, so any fixture test driving the full orchestrator against an isolated `-TargetRoot` had no way to avoid writing real `.lnk` files onto the operator's real Desktop. A new optional `-DesktopPath` override (default: the real Desktop, unchanged for every production call site) closes this.
- **Start/status healthcheck false negatives**: the generated `Test-KIStack-Health.ps1` made exactly one immediate HTTP attempt per endpoint after a flat 5-second startup grace period -- insufficient for ComfyUI/OpenWebUI's genuine startup time. Each endpoint now gets its own bounded poll/retry budget (defaulting to the config's own `healthTimeoutSeconds`, previously declared but never read), while a genuinely never-starting component still fails cleanly and quickly.
- **Dead Codex Local status detection**: `Get-KIStackStatus.ps1` detected Codex Local via a global `PATH` lookup that the component's own managed-runtime contract deliberately never populates, so a genuinely healthy install was always reported as not found. Replaced with the real managed `node.exe`/`codex.js` paths plus the isolated `CODEX_HOME`.
- **WSL/SearXNG keeper**: reviewed and confirmed sound as-is -- the existing keeper is already de-duplication-safe (`Test-KeeperIdentity` re-verifies a recorded PID as a genuine matching `wsl.exe` process before starting a new one), `Stop-KIStack-SearXNG.ps1` deliberately terminates it, and no automatic restart after reboot is intended by design. No code change made; not a defect.

## Known limitations

- Windows Full Greenfield Acceptance, ComfyUI v0.34 Greenfield Acceptance, and a full platform acceptance pass are deferred to 2.15; the last fully regression- and real-target-validated full-platform state remains 2.10.0.
- OpenWebUI 0.11.1's own asynchronous background execution of a tool call genuinely stalls for non-browser/headless API callers (see "Research agent web search" above); this is a real, reproducible OpenWebUI-core limitation, not something this repository's code can fix. A plain, synchronous OpenAI-compatible tool-calling round trip (`session_id` set, no `chat_id`) remains fully functional and is the supported integration path for non-browser callers.
- `docs/releases/complete-installer-v2.12.0.md` does not exist even though Complete Installer `2.12.0` was genuinely published as a GitHub Release -- a pre-existing documentation gap from before this cycle, noted here rather than backfilled retroactively.

## Validation

- Full repository test suite (`scripts/Test-Repository.ps1`): 37/37 passed, current real count.
- Complete Installer `PackageSelfTest`: 28/28 passed against a freshly extracted build.
- Deterministic double-build: two independent builds of the 2.13.0 package produce byte-identical ZIPs (same size and SHA-256).
- The generated SBOM parses as valid JSON, reports `spdxVersion: SPDX-2.3`, and its root package checksum matches the built ZIP's SHA-256 exactly; the `.zip.sha256` sidecar matches the same ZIP; Codex Local is correctly reported as `0.2.1`.
- Real-target validation performed against the existing target (`C:\KI-Stack`) for the OpenWebUI credential bootstrap, the Codex Local 0.2.1 upgrade and isolated-`CODEX_HOME` end-to-end proof, and the research agent web-search round trip -- each summarized under its own heading above, with every side effect either fully reverted or left in its intended, permanent end state.

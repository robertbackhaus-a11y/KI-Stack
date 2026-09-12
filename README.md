> Current production acceptance: `production-target-acceptance-v1.0.10`

# KI-Stack

Transactional, modular Windows AI stack installer for PowerShell 7, Git, Python, ComfyUI, models, LM Studio, Open WebUI, WSL and SearXNG. Every module includes self-test, dry run, execute, transaction logging and rollback.

Project page and accompanying articles: [okami.de – Lokaler KI-Stack](https://www.okami.de/projekte/lokaler-ki-stack-sprachmodelle-bilder-videos-und-rag-auf-einem-system/)

## Current state

| Component | Version | Status |
|---|---:|---|
| Foundation / Runtime | 1.0.9 | Stable reference; target-system validated |
| Python / Git | 1.1.5 | Stable; target-system validated |
| ComfyUI | 1.2.4 | Stable component; transactional marker/readback. Reference/minimum supported version `v0.34.0` for reproducible Greenfield installs and reconciliation; an existing, supported newer installation is preserved, never auto-downgraded |
| Models / Workflows | 2.0.3 | Automatic revision-pinned model acquisition, including Nomic Q4_K_M, with optional verified cache/preload |
| Applications | 1.4.12 | Stable; LM Studio (competing Electron autostart removed before *and* after server start) and Open WebUI (`ReferenceVersion`/`MinimumSupportedVersion` `0.11.3`; any installed version from `0.11.3` up is supported, and a newer supported installation is always preserved, never auto-downgraded) |
| Integration | 1.5.12 | Stable component; immutable SearXNG revision plus tracked overlay; the OpenWebUI-with-search starter it regenerates on every reconcile now preserves an already-applied RAG embedding-prefix env-call line instead of silently erasing it; the WSL keeper now launches `sleep infinity` directly (no login shell) and its liveness is verified against the real in-Debian process, never a possibly-stale Windows launcher PID |
| Cutover runtime | 1.6.16 | Stable component; transaction-local continuation state; real-target-validated ComfyUI supported-version contract, v0.28.0-payload-overlay protection, the Open WebUI `0.11.1` reference-version bump, and the Integration RAG-starter-preservation fix above (see `docs/releases/complete-installer-v2.10.0.md` for the ComfyUI/Applications fixes carried forward) |
| Production recovery | 1.7.0-r7 | Target-system accepted; portable runtime resolution |
| Universal package Validation Gate | 1.0.3 | Activated on the target system |
| Production Target Acceptance | 1.0.10 | `TARGET_SYSTEM_ACCEPTANCE_PASSED` on 2026-07-21 |
| OpenWebUI Agent Pack | 1.9.0 | Stable; manages `ki-stack-it-technik`, `ki-stack-allgemein`, and `ki-stack-research`. MCP-enabled production profiles use the MCP Runtime for local terminal/host control where permitted; `ki-stack-research` deliberately remains without MCP terminal access and combines dynamically-bound local RAG Knowledge, SearXNG web search, and isolated Pyodide code interpretation. Native Memory is enabled for `ki-stack-it-technik` and `ki-stack-allgemein`, disabled for `ki-stack-research`; reconcile preserves permitted live/UI metadata and KI-Stack MCP bindings. |
| OpenWebUI Visual Pack | 2.0.5 | Stable; Z-Image and WAN2.2 tools with persistent MP4 attachments |
| OpenWebUI Ballistics Pack | 1.0.0 | Stable; `18Bravo` and solver target-system validated |
| Codex Local | 0.2.1 | Stable component; own isolated `CODEX_HOME` (never again the shared `%USERPROFILE%\.codex`), real target-validated via a login-to-upgrade-to-starter-to-`codex exec` end-to-end run |
| RAG | 0.4.0 | Stable component; Add/Replace/Remove (plus Skip for already-current sources) and Rollback of Add/Replace/Remove are all real target-system validated; adds project-scoped Knowledge collections alongside the existing global scope, each mapped to its own isolated OpenWebUI Knowledge collection |
| MCP Runtime | 0.1.0 | Stable primary terminal/host-control backend for MCP-enabled Open WebUI profiles; local Streamable HTTP endpoint on `127.0.0.1:8021`, twelve command/process/filesystem tools, DPAPI-protected credential, managed through the Complete Installer |
| Open Terminal | 0.1.1 | Stable component; local tool/terminal backend service for OpenWebUI (filesystem, PowerShell, WSL, Git, process/command execution) at `http://127.0.0.1:8000`, no Docker; started through the existing, already-managed KI-Stack Python/uv contract (deterministic managed-path resolution, never a bare PATH lookup); authenticated with a single persistent, DPAPI-protected local API key (never in the repository, never logged, reused unchanged across restarts); Install/Upgrade/Repair/Skip via the Complete Installer, Start/Stop/Status via the same central KI-Stack lifecycle commands as every other component; real-target validated, including a real Complete Installer run that left it `SkippedAlreadyCompliant` on a second pass. Connecting it to OpenWebUI itself still requires one manual, one-time tool-server registration (see "Open Terminal" below) |
| WinApp | 0.6.1 | Centrally managed Windows UI Automation base for Desktop Control; local component contract with no runtime service, port, or credential of its own |
| Desktop Control | 0.1.0 | Controlled Windows UIA layer on top of WinApp with Resolve -> Validate -> Act -> Re-observe -> Verify, policy/secret/evidence checks, and independently verified postconditions; MCP wiring is not yet activated in 2.18 |
| Complete Installer | 2.18.2 | Current published GitHub Release `v2.18.2`. Includes the 2.15 MCP Foundation, 2.16 autonomous Local Control, 2.17 native persistent Open WebUI Memory, and the 2.18 Desktop Control / WinApp foundation; also carries Component Isolation, the internal component version registry, automatic Release Attestation, secure OpenWebUI credential bootstrap, Codex Local `0.2.1`, RAG `0.4.0`, Open Terminal fallback support, deterministic builds, PackageSelfTest, and the validated installer/reconciliation hardening accumulated through this release. |
| System Cleanup Audit | 1.0.0 | Audit completed; cleanup plan pending explicit approval |

The repository tracks complete package sources. Built ZIP files are published as GitHub Release assets rather than committed to normal Git history.

## Documentation

- **[Start here: installation guide](docs/en/KI-Stack-Installation-Guide.md)**
- **[Hier beginnen: Installationsanleitung](docs/de/KI-Stack-Installationsanleitung.md)**
- [Technical documentation (English)](docs/en/KI-Stack-Technical-Documentation.md)
- [Technische Dokumentation (Deutsch)](docs/de/KI-Stack-Technische-Dokumentation.md)
- [Operations and user guide (English)](docs/en/KI-Stack-Operations-and-User-Guide.md)
- [Betriebs- und Benutzerhandbuch (Deutsch)](docs/de/KI-Stack-Betriebs-und-Benutzerhandbuch.md)
- [Manual model provisioning (English)](docs/en/KI-Stack-Manual-Model-Provisioning.md)
- [Manuelle Modellbereitstellung (Deutsch)](docs/de/KI-Stack-Manuelle-Modellbereitstellung.md)
- [ComfyUI model download guide (English)](docs/en/KI-Stack-Model-Download-Guide.md)
- [ComfyUI-Modell-Downloadanleitung (Deutsch)](docs/de/KI-Stack-Modell-Downloadanleitung.md)

## Package guarantees

Every executable package is designed to provide:

- self-test before execution;
- dry-run mode;
- explicit Execute confirmation;
- automatic UAC elevation where required;
- transaction and diagnostic logging;
- rollback handling;
- regression checks for every previously corrected defect.

## Repository layout

```text
scripts/                 Repository validation and release tooling
docs/                    Architecture, release records and regression registry
.github/workflows/       GitHub Actions validation and attestation workflows
production-release-manifest.json  Production recovery and acceptance status
tools/                  Reproducible component sources, including the Complete Installer
VERSION                  Repository/package line version
```

`tools/system-cleanup/current` provides a read-only, conservatively classified system inventory. Its generated cleanup plan is SHA256-bound and cannot execute without a separate explicit approval; version 1.0.0 performs no deletion.

## Validate locally

```powershell
pwsh -NoProfile -File .\scripts\Test-Repository.ps1
```

## Build a release archive

The Complete Installer is built from `tools/complete-installer/current`:

```powershell
pwsh -NoProfile -File .\tools\complete-installer\current\New-KIStackCompleteInstallerArchive.ps1
```

## Safety and licensing

Do not commit credentials, access tokens, private keys, personal transaction logs or machine-specific state. No open-source license has been selected yet; public visibility alone does not grant reuse rights.

Production Recovery `1.7.0-r7` is a recovery line, not a new runtime version; r5 remains its published predecessor. The current Cutover Runtime version is `1.6.16` (see the table above and `docs/releases/complete-installer-v2.10.0.md`).

## Production recovery and target acceptance

The repository includes complete reusable sources for Production Recovery `1.7.0-r7`, Universal Package Validation Gate `1.0.2`, and Production Target Acceptance `1.0.10`. ZIP binaries remain GitHub Release assets and are referenced by explicit artifact contracts. The published r5 state remains documented as the accepted predecessor.

## OpenWebUI Agent Pack

OpenWebUI Agent Pack `1.9.0` manages the KI-Stack workspace profiles through Open WebUI's supported HTTP API. Current profile policy is intentionally different by role:

- `ki-stack-it-technik` and `ki-stack-allgemein` use the MCP Runtime for local terminal/host control and have native Open WebUI Memory enabled.
- `ki-stack-18bravo` uses the MCP Runtime where required for its technical workflow, but native Memory remains disabled; Ballistics profile persistence keeps its explicit save-confirmation contract.
- `ki-stack-research` combines dynamically-bound local RAG Knowledge, SearXNG web search, and isolated Pyodide Code Interpreter; it deliberately has no MCP terminal binding and native Memory remains disabled.
- `roleplay` remains outside the managed Memory policy and otherwise unchanged by the 2.17 Memory work.

Agent Pack reconciliation preserves package-owned settings while retaining foreign/live Open WebUI metadata where the ownership contract allows it. MCP bindings added by the KI-Stack control architecture survive subsequent reconcile runs instead of being silently removed.

## MCP Runtime and Local Control

MCP Runtime `0.1.0`, introduced with KI-Stack 2.15, is the primary terminal and host-control path for MCP-enabled profiles. It runs locally on `127.0.0.1:8021` through Open WebUI's standard MCP tool-server mechanism and exposes the validated command, process, filesystem, search, and file-display tool surface.

KI-Stack 2.16 builds Local Control on this existing MCP runtime rather than adding a second Windows-control service. General Windows, WSL, process, file, service, registry, task, and application control uses the existing MCP tools, `run_command`, PowerShell, and the established KI-Stack lifecycle scripts. No additional Local-Control port, credential, or runtime is introduced.

## Native Memory

KI-Stack 2.17 uses Open WebUI's own local native Memory implementation instead of adding another memory service or vector/database backend.

Memory policy:

- enabled: `ki-stack-it-technik`, `ki-stack-allgemein`
- disabled: `ki-stack-18bravo`, `ki-stack-research`
- unmanaged by this contract: `roleplay`

Memory is stored in Open WebUI's `webui.db`, is user-scoped, and can be reused across chats and managed profiles for the same authenticated user. Chat-level activation still depends on Open WebUI's request/chat `features.memory=true` flag because Open WebUI 0.11.3 does not provide a persisted server-side default for that request flag.

The 2.17 database-protection contract adds an online SQLite backup using `VACUUM INTO`, integrity verification, and controlled restore tooling with a pre-restore safety backup, WAL/SHM handling, and post-restore health verification. A real online production backup was performed; no production database restore was performed.

## Open Terminal

Open Terminal `0.1.1` remains fully installed, supported, lifecycle-managed, and runnable, but since KI-Stack 2.15 it is no longer the default terminal/host-control integration for production MCP-enabled profiles. MCP Runtime is the primary path.

Open Terminal remains an explicit fallback and rollback option. It runs locally at `http://127.0.0.1:8000`, uses the managed Python/uv runtime, and authenticates with its own persistent DPAPI-protected local API key. Install/Upgrade/Repair/Skip and central Start/Stop/Status handling remain supported.

If the Open Terminal fallback is deliberately used through Open WebUI's legacy OpenAPI tool-server path, that registration remains a separate explicit configuration step; normal MCP-based KI-Stack operation does not depend on it.

## Known open items

- **Latency tracing**: a complete technical timing breakdown of OpenWebUI input -> prompt/tool assembly -> LM Studio request -> first token is still not implemented as a dedicated tracing facility. The LM Studio runtime-baseline check added in 2.15 covers only one previously identified latency-related setting and is not a replacement for end-to-end tracing.
- **Memory request default**: Open WebUI 0.11.3 has no persisted server-side default for `features.memory=true`; Memory therefore still depends on chat/request-side activation.
- **Open WebUI database operations**: online backup is real-target validated and controlled restore is acceptance-tested against a temporary database copy, but no production `webui.db` restore has been performed.
- **GUI/Desktop automation**: broad graphical desktop/application automation remains outside 2.17 and is planned for the next architecture stage.

## Supply-chain security

`main` is protected and accepts changes through pull requests with mandatory Gitleaks, PSScriptAnalyzer, Bandit and CodeQL checks. CI actions are pinned to full commit SHAs, and payload contracts verify SHA256 values by content. Each release provides an SPDX-2.3 SBOM and GitHub-verifiable build attestations; see [SECURITY.md](SECURITY.md) for the reporting process.

KI-Stack uses protected changes, mandatory static security checks, content-based SHA256 contracts, published SBOMs and verifiable build attestations. These records reduce supply-chain risk, but do not replace an independent security assessment and do not guarantee freedom from defects or backdoors.

```powershell
gh attestation verify .\<release>.zip --repo robertbackhaus-a11y/KI-Stack
gh attestation verify .\<release>.zip --repo robertbackhaus-a11y/KI-Stack --predicate-type https://spdx.dev/Document/v2.3
```

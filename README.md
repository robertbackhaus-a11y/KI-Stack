> Current production acceptance: `production-target-acceptance-v1.0.10`

# KI-Stack

Transactional, modular Windows AI stack installer for PowerShell 7, Git, Python, ComfyUI, models, LM Studio, Open WebUI, WSL and SearXNG. Every module includes self-test, dry run, execute, transaction logging and rollback.

Projektseite und begleitende Artikel: https://www.okami.de/category/howtos/ki-stack/

## Current state

| Component | Version | Status |
|---|---:|---|
| Foundation / Runtime | 1.0.9 | Stable reference; target-system validated |
| Python / Git | 1.1.5 | Stable; target-system validated |
| ComfyUI | 1.2.4 | Stable component; transactional marker/readback. Reference version `v0.28.0` for reproducible Greenfield installs; an existing, supported newer installation (e.g. `v0.34.0`) is preserved, never auto-downgraded |
| Models / Workflows | 2.0.3 | Automatic revision-pinned model acquisition, including Nomic Q4_K_M, with optional verified cache/preload |
| Applications | 1.4.11 | Stable; LM Studio (competing Electron autostart removed before *and* after server start) and Open WebUI (`ReferenceVersion` `0.11.1`, `MinimumSupportedVersion` `0.11.0`; any installed version from `0.11.0` up is supported, and a newer supported installation is always preserved, never auto-downgraded) |
| Integration | 1.5.11 | Stable component; immutable SearXNG revision plus tracked overlay; the OpenWebUI-with-search starter it regenerates on every reconcile now preserves an already-applied RAG embedding-prefix env-call line instead of silently erasing it |
| Cutover runtime | 1.6.14 | Stable component; transaction-local continuation state; real-target-validated ComfyUI supported-version contract, v0.28.0-payload-overlay protection, the Open WebUI `0.11.1` reference-version bump, and the Integration RAG-starter-preservation fix above (see `docs/releases/complete-installer-v2.10.0.md` for the ComfyUI/Applications fixes carried forward) |
| Production recovery | 1.7.0-r7 | Target-system accepted; portable runtime resolution |
| Universal package Validation Gate | 1.0.3 | Activated on the target system |
| Production Target Acceptance | 1.0.10 | `TARGET_SYSTEM_ACCEPTANCE_PASSED` on 2026-07-21 |
| OpenWebUI Agent Pack | 1.9.0 | Stable; three Heretic-only profiles (`ki-stack-it-technik`, `ki-stack-allgemein`, and the new `ki-stack-research` reference agent combining dynamically-bound local RAG knowledge with web search, isolated Pyodide code interpretation, and no shell/host/administrative access) with Visual Pack 2.0.5 bindings; reconcile now merges rather than replaces `meta` on update, so live/UI-added `capabilities`/`builtinTools`/`access_grants`/`profile_image_url` values on already-managed profiles survive a re-run instead of being silently overwritten |
| OpenWebUI Visual Pack | 2.0.5 | Stable; Z-Image and WAN2.2 tools with persistent MP4 attachments |
| OpenWebUI Ballistics Pack | 1.0.0 | Stable; `18Bravo` and solver target-system validated |
| Codex Local | 0.2.1 | Stable component; own isolated `CODEX_HOME` (never again the shared `%USERPROFILE%\.codex`), real target-validated via a login-to-upgrade-to-starter-to-`codex exec` end-to-end run |
| RAG | 0.4.0 | Stable component; Add/Replace/Remove (plus Skip for already-current sources) and Rollback of Add/Replace/Remove are all real target-system validated; adds project-scoped Knowledge collections alongside the existing global scope, each mapped to its own isolated OpenWebUI Knowledge collection |
| Complete Installer | 2.13.0 | Current repository/development state, not yet published as a GitHub Release: a secure, DPAPI-backed OpenWebUI credential bootstrap (one-time admin login, a long-lived API key, a central resolver, rotation/revoke), Codex Local `0.2.1` with an isolated `CODEX_HOME` and a real end-to-end proof, a real web-search proof for `ki-stack-research`, Component Isolation, an internal component version registry, an automatic Release Attestation chain, plus real consolidation fixes (test-run desktop-shortcut isolation, a bounded-retry start/status healthcheck, correct Codex Local status detection). Deterministic dual-build and PackageSelfTest reverified against this state. `2.12.0` (`KI-Stack-Complete-Installer-v2.12.0.zip`) remains the latest actually published [GitHub Release](https://github.com/robertbackhaus-a11y/KI-Stack/releases/tag/v2.12.0). |
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
package/                 Current complete package source
scripts/                 Repository validation and release tooling
docs/                    Architecture, release records and regression registry
.github/workflows/       GitHub Actions validation and controlled release workflow
release-manifest.json    Machine-readable status of the checked-out package
production-release-manifest.json  Production recovery and acceptance status
tools/                  Reproducible Validation Gate, Recovery and Acceptance sources
VERSION                  Repository/package line version
```

`tools/system-cleanup/current` provides a read-only, conservatively classified system inventory. Its generated cleanup plan is SHA256-bound and cannot execute without a separate explicit approval; version 1.0.0 performs no deletion.

## Validate locally

```powershell
pwsh -NoProfile -File .\scripts\Test-Repository.ps1
```

## Build a release archive

```powershell
pwsh -NoProfile -File .\scripts\New-ReleaseArchive.ps1
```

## Safety and licensing

Do not commit credentials, access tokens, private keys, personal transaction logs or machine-specific state. No open-source license has been selected yet; public visibility alone does not grant reuse rights.


Production Recovery `1.7.0-r7` is a recovery line, not a new runtime version; r5 remains its published predecessor. The current Cutover Runtime version is `1.6.14` (see the table above and `docs/releases/complete-installer-v2.10.0.md`).


## Applications v1.4.0-rc1

LM Studio and Open WebUI 0.10.2 are delivered as the sixth transaction-protected Execute module.


## Applications v1.4.3-rc1

Fixes StrictMode-safe LM Studio detection and exposes exact transaction failure causes.


## Applications v1.4.9-rc1

Sets repository-local Git author identity before commits and annotated tags without changing global Git configuration.


## Cutover release history

`cutover-v1.6.1-rc1` adds the final cutover and acceptance layer.


## Cutover corrective release history

`cutover-v1.6.2-rc1` fixes final validation and diagnostic regression contracts.


## Cutover release history (1.6.3, historical)

`cutover-v1.6.3-rc1` fixes release-manifest schema validation. Superseded by `1.6.13` (see the table above).

## Production recovery and target acceptance

The repository includes complete reusable sources for Production Recovery `1.7.0-r7`, Universal Package Validation Gate `1.0.2`, and Production Target Acceptance `1.0.10`. ZIP binaries remain GitHub Release assets and are referenced by explicit artifact contracts. The published r5 state remains documented as the accepted predecessor.

## OpenWebUI Agent Pack

OpenWebUI Agent Pack `1.9.0` manages three workspace models -- `KI & IT-Technik`, `Allgemein`, and the reference research agent `ki-stack-research` -- through the supported OpenWebUI HTTP API (`ReferenceVersion` `0.11.1`; `MinimumSupportedVersion` `0.11.0`; any newer supported installation is preserved, never auto-downgraded). `KI & IT-Technik`/`Allgemein` enable only the built-in browser-local Pyodide Code Interpreter capability and preserve only the registered Image Pack/Visual Pack tool bindings; `execute_code` is not a workspace tool ID. `ki-stack-research` instead binds exactly one dynamically-resolved local RAG Knowledge collection plus web search, has no Extension Tools bound at all, and explicitly denies `terminal` and every other unused native capability -- no shell, host filesystem, or administrative OpenWebUI access exists for any managed profile. Reconcile on an already-existing profile now merges rather than replaces `meta`: only package-declared fields (`toolIds`, `knowledge` where contractually owned, the prompt, etc.) are reasserted, while any other live/UI-added value on `capabilities`, `builtinTools`, `access_grants`, or `profile_image_url` survives untouched. Provisioning requires a real, externally-supplied OpenWebUI administrator API key (never extracted from the database, never committed to the repository); this is a known automation/bootstrap boundary, not a defect -- reconcile, idempotency, and knowledge binding are all independently verified via mocked-HTTP regression tests without it.

OpenWebUI Image Pack `1.10.0` continues to manage exactly one canonical tool, `ki-stack-generate-image`, through local ComfyUI 1.2.2. Its existing `generate_image` FLUX2 method is retained and the explicit `generate_pony_image` method adds Pony SDXL at 1024 × 1024, CLIP skip 2, 40 steps, CFG 3.1, `euler` and `normal`. Both paths persist images directly in the OpenWebUI chat. The pack downloads no models; the Pony checkpoint must already be installed. The Pony workflow and chat output were practically tested on the target, without claiming complete 1.10.0 target-system validation.

OpenWebUI Ballistics Pack `1.0.0` adds the exclusively bound `18Bravo` technical profile and `ki_stack_ballistics_calculator`. Its pinned `pyballistic` 2.2.0 RK4 core supports G1/G7 calculations without Git, compiled solver extensions, SciPy engine or chart extensions. It requires complete explicit inputs, stores profiles only after confirmation and is restricted to lawful sporting, hunting and engineering use.

Overall status: `TARGET_SYSTEM_ACCEPTANCE_PASSED`.

## Supply-chain security

`main` is protected and accepts changes through pull requests with mandatory Gitleaks, PSScriptAnalyzer, Bandit and CodeQL checks. CI actions are pinned to full commit SHAs, and payload contracts verify SHA256 values by content. Each release provides an SPDX-2.3 SBOM and GitHub-verifiable build attestations; see [SECURITY.md](SECURITY.md) for the reporting process.

KI-Stack uses protected changes, mandatory static security checks, content-based SHA256 contracts, published SBOMs and verifiable build attestations. These records reduce supply-chain risk, but do not replace an independent security assessment and do not guarantee freedom from defects or backdoors.

```powershell
gh attestation verify .\<release>.zip --repo robertbackhaus-a11y/KI-Stack
gh attestation verify .\<release>.zip --repo robertbackhaus-a11y/KI-Stack --predicate-type https://spdx.dev/Document/v2.3
```

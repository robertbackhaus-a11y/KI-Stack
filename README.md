> Current production acceptance: `production-target-acceptance-v1.0.10`

# KI-Stack

Transactional, modular Windows AI stack installer for PowerShell 7, Git, Python, ComfyUI, models, LM Studio, Open WebUI, WSL and SearXNG. Every module includes self-test, dry run, execute, transaction logging and rollback.

## Current state

| Component | Version | Status |
|---|---:|---|
| Foundation / Runtime | 1.0.9 | Stable reference; target-system validated |
| Python / Git | 1.1.5 | Stable; target-system validated |
| ComfyUI | 1.2.2 | Stable; Git-free content contract target-system validated |
| Models / Workflows | 1.4.8 | Central transactional ComfyUI and Heretic LM Studio external-model importer; bilingual provisioning documentation |
| Applications | 1.4.10 | Stable; LM Studio and Open WebUI 0.10.2 target-system accepted |
| Integration | 1.5.9 | Stable; Git-free SearXNG payload and repaired lifecycle target-system validated |
| Cutover runtime | 1.6.3 | Accepted runtime baseline |
| Production recovery | 1.7.0-r7 | Target-system accepted; portable runtime resolution |
| Universal package Validation Gate | 1.0.2 | Activated on the target system |
| Production Target Acceptance | 1.0.10 | `TARGET_SYSTEM_ACCEPTANCE_PASSED` on 2026-07-21 |
| OpenWebUI Agent Pack | 1.8.3 | Target validated; built-in Pyodide Code Interpreter for Allgemein and KI & IT-Technik |
| OpenWebUI Image Pack | 1.9.2 | Stable; direct FLUX2 generation target-system validated |
| OpenWebUI Ballistics Pack | 1.0.0 | Stable; `18Bravo` and solver target-system validated |
| Complete Installer | 2.2.8 | Enforces the external ComfyUI and Heretic LM Studio contracts before Models / Workflows compliance; bilingual documentation included |
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


The current repository runtime remains Cutover `1.6.3`. Production Recovery `1.7.0-r7` is a recovery line, not a new runtime version; r5 remains its published predecessor.


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


## Current accepted runtime

`cutover-v1.6.3-rc1` fixes release-manifest schema validation.

## Production recovery and target acceptance

The repository includes complete reusable sources for Production Recovery `1.7.0-r7`, Universal Package Validation Gate `1.0.2`, and Production Target Acceptance `1.0.10`. ZIP binaries remain GitHub Release assets and are referenced by explicit artifact contracts. The published r5 state remains documented as the accepted predecessor.

## OpenWebUI Agent Pack

OpenWebUI Agent Pack `1.8.3` manages exactly the workspace models `KI & IT-Technik` and `Allgemein` through the supported OpenWebUI 0.10.2 HTTP API. It enables only the built-in browser-local Pyodide Code Interpreter capability and preserves only the registered Image Pack tool binding. `execute_code` is not a workspace tool ID.

OpenWebUI Image Pack `1.9.2` manages exactly one canonical tool, `ki-stack-generate-image`, for direct generation through the existing FLUX2 Klein workflow and local ComfyUI 1.2.2. OpenWebUI 0.10.2 binds its required identifier-safe internal ID `ki_stack_generate_image`. The pack downloads no models and adds no KREA or Pony dependency.

OpenWebUI Ballistics Pack `1.0.0` adds the exclusively bound `18Bravo` technical profile and `ki_stack_ballistics_calculator`. Its pinned `pyballistic` 2.2.0 RK4 core supports G1/G7 calculations without Git, compiled solver extensions, SciPy engine or chart extensions. It requires complete explicit inputs, stores profiles only after confirmation and is restricted to lawful sporting, hunting and engineering use.

Overall status: `TARGET_SYSTEM_ACCEPTANCE_PASSED`.

## Supply-chain security

`main` is protected and accepts changes through pull requests with mandatory Gitleaks, PSScriptAnalyzer, Bandit and CodeQL checks. CI actions are pinned to full commit SHAs, and payload contracts verify SHA256 values by content. Each release provides an SPDX-2.3 SBOM and GitHub-verifiable build attestations; see [SECURITY.md](SECURITY.md) for the reporting process.

KI-Stack uses protected changes, mandatory static security checks, content-based SHA256 contracts, published SBOMs and verifiable build attestations. These records reduce supply-chain risk, but do not replace an independent security assessment and do not guarantee freedom from defects or backdoors.

```powershell
gh attestation verify .\<release>.zip --repo robertbackhaus-a11y/KI-Stack
gh attestation verify .\<release>.zip --repo robertbackhaus-a11y/KI-Stack --predicate-type https://spdx.dev/Document/v2.3
```

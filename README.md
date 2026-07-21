> Current production acceptance: `production-target-acceptance-v1.0.8`

# KI-Stack

Transactional, modular Windows AI stack installer for PowerShell 7, Git, Python, ComfyUI, models, LM Studio, Open WebUI, WSL and SearXNG. Every module includes self-test, dry run, execute, transaction logging and rollback.

## Current state

| Component | Version | Status |
|---|---:|---|
| Foundation / Runtime | 1.0.9 | Stable reference; target-system validated |
| Python / Git | 1.1.5 | Stable; target-system validated |
| ComfyUI | 1.2.1 | Stable; target-system validated |
| Models / Workflows | 1.3.7-rc1 | Release candidate |
| Applications | 1.4.10-rc1 | Release candidate; StrictMode-safe publisher contract |
| Integration | 1.5.7-rc1 | Release candidate; precise CMD finish-block lifecycle gate |
| Cutover runtime | 1.6.3 | Accepted runtime baseline |
| Production recovery | 1.7.0-r5 | Reconstructed and content-validated |
| Universal package Validation Gate | 1.0.2 | Activated on the target system |
| Production Target Acceptance | 1.0.8 | `TARGET_SYSTEM_ACCEPTANCE_PASSED` on 2026-07-21 |

The repository tracks complete package sources. Built ZIP files are published as GitHub Release assets rather than committed to normal Git history.

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


The current repository runtime remains Cutover `1.6.3`. Production Recovery `1.7.0-r5` is a recovery line, not a new runtime version.


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

The repository includes complete reusable sources for Production Recovery `1.7.0-r5`, Universal Package Validation Gate `1.0.2`, and Production Target Acceptance `1.0.8`. ZIP binaries remain GitHub Release assets and are referenced by explicit artifact contracts.

Overall status: `TARGET_SYSTEM_ACCEPTANCE_PASSED`.

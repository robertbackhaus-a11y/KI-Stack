> Current release candidate: `integration-v1.5.7-rc1`

# KI-Stack

Transactional, modular Windows AI stack installer for PowerShell 7, Git, Python, ComfyUI, models, LM Studio, Open WebUI, WSL and SearXNG. Every module includes self-test, dry run, execute, transaction logging and rollback.

## Current state

| Component | Version | Status |
|---|---:|---|
| Foundation / Runtime | 1.0.9 | Stable reference; target-system validated |
| Python / Git | 1.1.5 | Stable; target-system validated |
| ComfyUI | 1.2.1 | Stable; target-system validated |
| Models / Workflows | 1.3.7-rc1 | Release candidate |
| Applications | 1.4.9-rc1 | Release candidate; runtime already target-system validated, publisher correction |
| Integration | 1.5.7-rc1 | Release candidate; precise CMD finish-block lifecycle gate |

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


Current release candidate: `models-workflows-v1.3.7-rc1`.


## Applications v1.4.0-rc1

LM Studio and Open WebUI 0.10.2 are delivered as the sixth transaction-protected Execute module.


## Applications v1.4.3-rc1

Fixes StrictMode-safe LM Studio detection and exposes exact transaction failure causes.


## Applications v1.4.9-rc1

Sets repository-local Git author identity before commits and annotated tags without changing global Git configuration.

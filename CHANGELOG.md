## Models / Workflows 1.3.7-rc1 — release candidate

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

# Changelog

## PythonGit 1.1.5 — stable

- Added Python, virtual-environment, package-cache and repository structures.
- Enforced Git `core.longpaths` target state.
- Added pip upgrade and `uv` installation with `python -m uv` fallback.
- Added transaction-bound rollback journal.
- Consolidated all historical starter, elevation, self-test and configuration regressions.

## Foundation / Runtime 1.0.9 — stable reference

- Validated foundation target structure and required Windows runtimes.
- Corrected runtime-state compatibility, end-state validation, Windows Git version normalization and `$Matches` collision.

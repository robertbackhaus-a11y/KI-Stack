# KI-Stack OpenWebUI Ballistics Pack 1.0.0

Ballistics Pack 1.0.0 manages exactly profile `ki-stack-18bravo` (`18Bravo`) and tool `ki_stack_ballistics_calculator` through the validated OpenWebUI 0.10.2 HTTP API. The tool is bound only to this profile; `Allgemein` and `KI & IT-Technik` remain unchanged.

The solver payload is `pyballistic-2.2.0-py3-none-any.whl`, 132035 bytes, SHA256 `6a17eb8c40f9606ac5878b0a5d30575f7cc83cc549375e1371c100e2bdab36a4`, licensed LGPL-3.0-only and compatible with Python 3.9 or newer. The package selects `RK4IntegrationEngine`; optional compiled, SciPy and chart engines are excluded.

Status: `TargetSystemValidated` on 2026-07-22. Missing-input, G1/G7, invalid-input, non-ballistic, profile-confirmation, idempotence and rollback checks passed using synthetic fixtures. No raw OpenWebUI exports, API keys, backups, user profiles or personal paths are publishable.

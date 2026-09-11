# KI-Stack Complete Installer 2.18.2

`KI-Stack-Complete-Installer-v2.18.2.zip` is the current published Complete Installer package.

The current package provides the complete managed KI-Stack state through release 2.18.2. Its current architecture includes:

- Open WebUI `0.11.3` as reference/minimum supported version; supported newer installations are preserved and never automatically downgraded.
- ComfyUI `v0.34.0` as reference/minimum supported version; supported newer installations are preserved.
- Desktop Control 0.1.0 with central WinApp 0.6.1 as the controlled Windows UIA layer; semantic operations with policy, target, secret, audit, and independent postcondition verification. MCP wiring remains intentionally deferred in 2.18.
- Codex Local `0.2.1` with isolated `CODEX_HOME`.
- RAG `0.4.0` with global and project-scoped Knowledge collections.
- OpenWebUI Agent Pack `1.9.0`.
- OpenWebUI Visual Pack `2.0.5`.
- Ballistics Pack `1.0.0`.
- MCP Runtime `0.1.0` as the primary terminal/host-control backend for MCP-enabled profiles on `127.0.0.1:8021`.
- Local Control on the existing MCP Runtime, with no second Windows-control runtime, port, or credential.
- Open Terminal `0.1.0` remains fully managed and lifecycle-integrated as a supported fallback/rollback backend; MCP Runtime is the primary terminal/host-control path for production MCP-enabled profiles.
- Native Open WebUI Memory for the managed profiles defined by the Agent Pack policy.
- Central persistent Open WebUI credential bootstrap with DPAPI-protected local storage.
- Component Isolation, internal component version registry, deterministic release packaging, PackageSelfTest, and automatic Release Attestation.

Memory policy in the current package:

- enabled: `ki-stack-it-technik`, `ki-stack-allgemein`
- disabled: `ki-stack-18bravo`, `ki-stack-research`
- unmanaged by this contract: `roleplay`

The 2.17 database-protection contract includes online `webui.db` backup using SQLite `VACUUM INTO`, integrity validation, controlled restore tooling, pre-restore safety backup, WAL/SHM handling, and post-restore health verification.

Validation claims remain scope-specific. The last complete physical empty-target Windows Greenfield installation was performed with 2.4.0. Later releases through 2.18.2 add repository regression, deterministic package, component, upgrade/reconcile, and real-target acceptance evidence without claiming a newer complete Greenfield run.
- Heretic is the only chat LLM.
- Nomic is embedding-only.
- Z-Image uses only `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`.
- Active visual workflows are Z-Image Turbo and WAN2.2 T2V 14B with both LightX2V four-step LoRAs.
- Visual Pack is 2.0.5; Agent Pack is 1.9.0; Models / Workflows is 2.0.3.
- Missing models, including embedding-only `nomic-embed-text-v1.5.Q4_K_M.gguf`, are downloaded automatically. Valid targets and optional caches/preloads are reused only after size and SHA-256 verification. A partial download already at its expected final size is verified directly against that size/SHA256 contract and never re-requested over the network (a real Greenfield-run defect where this case triggered an HTTP 416 from the source has been fixed and reverified against a live target).
- Open WebUI API-dependent installer operations use the centralized persistent KI-Stack OpenWebUI credential. If no valid credential is available, dependent work is reported as controlled Pending/Blocked rather than using a separately maintained temporary administrator API key.
- `WaitingForUserAction` now means only that OpenWebUI and ComfyUI are both reachable but first login/API key is still missing. If OpenWebUI or ComfyUI stays unreachable beyond its bounded readiness wait, the installer fails with a real error instead of waiting indefinitely for a user action that cannot happen.
- Codex Local 0.2.1 is reproducibly connected through LM Studio. Node.js 24.14.0 and npm are provisioned as a portable, SHA256-verified module runtime; no global Node.js installation is required. The Windows build validation executes the installed CLI with the managed runtime before target approval. Waiting for LM Studio's local API server on a genuine first run now uses the same up-to-~120s window the managed starter itself is built for, and observes the starter's own exit code, instead of an independently-timed, shorter budget that could give up while the starter was still legitimately starting (a real defect reproduced during the 2.5.0 Greenfield run, fixed, regression-tested, and confirmed against the real target system).
- RAG 0.4.0 is installed as an independent module; sources remain controlled and ingestion is not started without approval. Audit, DryRun and Status are semantically distinct read-only modes; Execute (Add/Replace/Remove (plus Skip for already-current sources)) and Rollback of Add, Replace, and Remove are all real target-system validated, each including a repeated Rollback call confirmed idempotent. A real defect in the Rollback retry path (a partially-failed Replace/Remove Rollback could fail its own retry by re-issuing a remove call against remote content it had already deleted) was found via a dedicated partial-failure regression test and fixed; the removal is now treated as already-satisfied on retry, matching the real server's own behavior. The global OpenWebUI embedding configuration is changed idempotently with a credential-safe backup/restore contract.
- OpenWebUI receives the Nomic prefixes `search_document:` and `search_query:` at startup.
- LM Studio is installed through `winget`; the managed starter `Start-KIStack-LMStudio.cmd` brings up its local API server automatically, including on a first-ever Greenfield run where LM Studio's `lms` CLI is not yet available. Codex Local depends on this endpoint and the same starter is invoked before Codex Local is configured.
- SearXNG's local endpoint is adopted, not reinstalled, whenever an already-healthy instance is found — under either the Cutover Runtime's `ki-stack-searxng.service` or the Integration component's `uwsgi.service`, behind an `nginx` reverse proxy with `valkey-server` as its local store.
- Without a supplied OpenWebUI administrator API key, the temporary Knowledge bootstrap-experiment rollback (unrelated to the RAG module's own ingestion) and the Code Interpreter connection configuration remain manual follow-up steps after installation.
- The installer prints a console status line per step (`Running`, `Waiting`, `WaitingForUserAction`, `Completed`, `Failed`) with a timestamp, and a heartbeat at least every ~20-30s while an existing wait loop (such as the OpenWebUI readiness check) is still active, so a long-running step never looks stuck. There is no progress bar or invented percentage -- only the current step, elapsed runtime, and a short status description.

Verify the ZIP against its adjacent `.sha256` sidecar before extraction. The final ZIP hash is intentionally not embedded in this package.

See `Documentation/INSTALLATION.md` for installation, upgrade, lifecycle, SHA-256, resume, recovery, and rollback instructions.

# KI-Stack Complete Installer 2.5.0

KI-Stack Complete Installer 2.5.0 has passed a real, successful, complete Greenfield installation on a fresh empty Windows target (a Hyper-V VM with no prior KI-Stack state): every regular installer step completed, reboot/resume after first-time WSL activation was exercised and passed, and the installer exited with code 0. The two OpenWebUI content packs (Visual Pack, Agent Pack) ended this run in the documented `WaitingForUserAction` credential state because no OpenWebUI administrator API key was supplied by design -- this is expected, not an installation failure. RAG's Execute (Add) and Rollback (of Add) have both been verified against a live OpenWebUI 0.11.0 instance, including a repeated Rollback call confirmed as a clean, idempotent no-op; Rollback of Replace/Remove remains regression-validated only, via an extensive mocked test suite, and has not yet been exercised against a live target. During this Greenfield run a real defect was found and fixed in the Visual Models/Workflows download logic (a stale-but-complete partial download could trigger an HTTP 416 from the source) and reverified end to end against the same live target -- see the Visual Models/Workflows bullet below.

- Heretic is the only chat LLM.
- Nomic is embedding-only.
- Z-Image uses only `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`.
- Active visual workflows are Z-Image Turbo and WAN2.2 T2V 14B with both LightX2V four-step LoRAs.
- Visual Pack is 2.0.5; Agent Pack is 1.8.9; Models / Workflows is 2.0.3.
- Missing models, including embedding-only `nomic-embed-text-v1.5.Q4_K_M.gguf`, are downloaded automatically. Valid targets and optional caches/preloads are reused only after size and SHA-256 verification. A partial download already at its expected final size is verified directly against that size/SHA256 contract and never re-requested over the network (a real Greenfield-run defect where this case triggered an HTTP 416 from the source has been fixed and reverified against a live target).
- A temporary OpenWebUI administrator API key is held only in memory and is never stored.
- Codex Local 0.1.3 is reproducibly connected through LM Studio. Node.js 24.14.0 and npm are provisioned as a portable, SHA256-verified module runtime; no global Node.js installation is required. The Windows build validation executes the installed CLI with the managed runtime before target approval.
- RAG 0.3.0 is installed as an independent module; sources remain controlled and ingestion is not started without approval. Audit, DryRun and Status are semantically distinct read-only modes; Execute (Add/Query/Replace/Remove) and Rollback of Add are real target-system validated, including a repeated Rollback call confirmed idempotent; Rollback of Replace/Remove remains regression-tested only. The global OpenWebUI embedding configuration is changed idempotently with a credential-safe backup/restore contract.
- OpenWebUI receives the Nomic prefixes `search_document:` and `search_query:` at startup.
- LM Studio is installed through `winget`; the managed starter `Start-KIStack-LMStudio.cmd` brings up its local API server automatically, including on a first-ever Greenfield run where LM Studio's `lms` CLI is not yet available. Codex Local depends on this endpoint and the same starter is invoked before Codex Local is configured.
- SearXNG's local endpoint is adopted, not reinstalled, whenever an already-healthy instance is found — under either the Cutover Runtime's `ki-stack-searxng.service` or the Integration component's `uwsgi.service`, behind an `nginx` reverse proxy with `valkey-server` as its local store.
- Without a supplied OpenWebUI administrator API key, the temporary Knowledge bootstrap-experiment rollback (unrelated to the RAG module's own ingestion) and the Code Interpreter connection configuration remain manual follow-up steps after installation.

Verify the ZIP against its adjacent `.sha256` sidecar before extraction. The final ZIP hash is intentionally not embedded in this package.

See `Documentation/INSTALLATION.md` for installation, upgrade, lifecycle, SHA-256, resume, recovery, and rollback instructions.

# KI-Stack Complete Installer 2.4.0-rc9

Development build based on stable Complete Installer 2.3.2. This RC adds the Local Intelligence Extension and is not yet target-system approved.

- Heretic is the only chat LLM.
- Nomic is embedding-only.
- Z-Image uses only `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`.
- Active visual workflows are Z-Image Turbo and WAN2.2 T2V 14B with both LightX2V four-step LoRAs.
- Visual Pack is 2.0.5; Agent Pack is 1.8.9; Models / Workflows is 2.0.3.
- Missing models, including embedding-only `nomic-embed-text-v1.5.Q4_K_M.gguf`, are downloaded automatically. Valid targets and optional caches/preloads are reused only after size and SHA-256 verification.
- A temporary OpenWebUI administrator API key is held only in memory and is never stored.
- Codex Local 0.1.3 is reproducibly connected through LM Studio. Node.js 24.14.0 and npm are provisioned as a portable, SHA256-verified module runtime; no global Node.js installation is required. The Windows build validation executes the installed CLI with the managed runtime before target approval.
- RAG 0.2.0 is installed as an independent module; sources remain controlled and ingestion is not started without approval.
- OpenWebUI receives the Nomic prefixes `search_document:` and `search_query:` at startup.

Verify the ZIP against its adjacent `.sha256` sidecar before extraction. The final ZIP hash is intentionally not embedded in this package.

See `Documentation/INSTALLATION.md` for installation, upgrade, lifecycle, SHA-256, resume, recovery, and rollback instructions. The Greenfield contract was verified with source/package checks and small fixtures; a complete physical Greenfield installation on an empty target was not performed.

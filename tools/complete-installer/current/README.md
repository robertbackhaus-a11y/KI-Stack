# KI-Stack Complete Installer 2.3.1 Stable

Documentation-only patch over the functionally identical, TargetValidated 2.3.0 release.

- Heretic is the only chat LLM.
- Nomic is embedding-only.
- Z-Image uses only `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`.
- Active visual workflows are Z-Image Turbo and WAN2.2 T2V 14B with both LightX2V four-step LoRAs.
- Visual Pack is 2.0.5; Agent Pack is 1.8.9; Models / Workflows is 2.0.2.
- Missing models are downloaded automatically. Valid targets and optional caches/preloads are reused only after size and SHA-256 verification.
- A temporary OpenWebUI administrator API key is held only in memory and is never stored.

Verify the ZIP against its adjacent `.sha256` sidecar before extraction. The final ZIP hash is intentionally not embedded in this package.

See `Documentation/INSTALLATION.md` for installation, upgrade, lifecycle, SHA-256, resume, recovery, and rollback instructions. The Greenfield contract was verified with source/package checks and small fixtures; a complete physical Greenfield installation on an empty target was not performed.

# Complete Installer v2.3.1

Stable documentation-only patch over v2.3.0.

- Complete Installer: `2.3.1`
- OpenWebUI Visual Pack: `2.0.5`
- OpenWebUI Agent Pack: `1.8.9`
- Models / Workflows: `2.0.2`
- Validation Gate: `1.0.3`
- Cutover Runtime: `1.6.5`
- Functional validation: inherited unchanged from TargetValidated v2.3.0

The corrected documentation states that Heretic is chat-only, Nomic is embedding-only, the official Qwen artifact is Z-Image-only, and the active visual workflows are limited to Z-Image Turbo and WAN2.2 T2V 14B with both LightX2V four-step LoRAs.

Missing models are downloaded automatically from revision-pinned sources. Valid targets and optional caches/preloads are reused only after exact size and SHA-256 verification. Interrupted transfers support resume; incorrect size or hash fails. A temporary OpenWebUI administrator API key is never stored.

The Greenfield contract was verified with source/package checks and small local fixtures. A complete physical Greenfield installation on an empty target was not performed.

The final ZIP hash is published only in the adjacent SHA-256 sidecar and the GitHub Release description.

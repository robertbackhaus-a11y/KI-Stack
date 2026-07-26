# KI-Stack 2.3.1 technical documentation

KI-Stack is a transactional Windows local-AI stack. Complete Installer 2.3.1 is a documentation-only patch over the functionally identical, TargetValidated 2.3.0 release.

## Active components

| Component | Version |
|---|---:|
| Foundation / Runtime | 1.0.9 |
| Python / Git | 1.1.5 |
| ComfyUI | 1.2.4 |
| Models / Workflows | 2.0.2 |
| Applications | 1.4.10 |
| Integration | 1.5.10 |
| Cutover Runtime | 1.6.5 |
| Production Recovery | 1.7.0-r7 |
| Validation Gate | 1.0.3 |
| Target Acceptance | 1.0.10 |
| OpenWebUI Visual Pack | 2.0.5 |
| OpenWebUI Agent Pack | 1.8.9 |
| Complete Installer | 2.3.1 |

Heretic is the only selectable chat LLM. Nomic is embedding-only. Z-Image uses only `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`. Visual execution is limited to Z-Image Turbo and WAN2.2 T2V 14B with the high/low LightX2V four-step LoRAs.

## Model acquisition

The central versioned manifest contains revision-pinned sources, filenames, sizes, and SHA-256 values. A valid installed target is reused first, followed by an optional verified cache/preload. Missing files are downloaded automatically into transaction state, with Range resume where supported. Atomic activation occurs only after full size and SHA-256 verification. Network failure remains resumable; incorrect size or hash fails the component.

No model weights are embedded in Git or the Complete Installer ZIP. Preloads are optional and are not an installation prerequisite.

## Transactions and OpenWebUI

Installation and upgrade use component planning, scoped backups, journalled state, real-version readback, resume, recovery, and rollback. A component is recorded as completed only after successful deployment and readback. Rollback affects only the active transaction.

OpenWebUI Visual and Agent administration may request a temporary administrator API key as a hidden `SecureString`. It is used only in memory, is not written to reports, state, command lines, or environment files, and should be revoked afterwards.

MP4 output remains exactly one persistent file attachment through the native `files` event and `/api/v1/files/{id}/content`.

## Validation scope

The Greenfield acquisition contract, cache reuse, resume, network failure, size mismatch, hash mismatch, and atomic activation were verified with source/package checks and small local fixtures. A complete physical Greenfield installation on an empty target was not performed. Functional validation of Heretic, Nomic, Z-Image, WAN2.2, OpenWebUI attachments, and stack health is inherited unchanged from 2.3.0 because 2.3.1 changes documentation only.

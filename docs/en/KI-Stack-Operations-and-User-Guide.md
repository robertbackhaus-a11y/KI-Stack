# KI-Stack 2.3.2 operations and user guide

## Normal operation

- Install or upgrade: `Start-KIStack-Installer.cmd`
- Start the stack: `Start-KIStack.cmd`
- Stop the stack: `Stop-KIStack.cmd`
- Read-only status: `Status-KIStack.cmd`
- Interactive status: `Lifecycle\Status-KIStack-Interactive.cmd`

Use PowerShell 7. Keep package files together and do not run individual component installers manually.

## Models and workflows

Heretic is the only chat LLM; Nomic is embedding-only. Z-Image uses the official `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`. The only active visual workflows are Z-Image Turbo and WAN2.2 T2V 14B with both LightX2V four-step LoRAs. FLUX, Krea, Pony, WAN-5B/I2V, and legacy Image Pack workflows are not active.

Missing required models are downloaded automatically from revision-pinned sources. Valid targets and optional cache/preload files are reused only after size and SHA-256 verification. Interrupted transfers resume when supported. A wrong size or hash fails safely; no invalid file is activated.

## OpenWebUI

The Agent Pack is 1.8.9 and the Visual Pack is 2.0.5. A temporary OpenWebUI administrator API key may be requested during a Visual/Agent update. It is hidden, held only in memory, never saved, and should be revoked after use.

Images remain visible chat content. MP4 output remains exactly one persistent downloadable FileItem after reload through `/api/v1/files/{id}/content`.

## Transactions

Transaction state is stored under `C:\KI-Stack\state\complete-installer\<TransactionId>` and backups under `C:\KI-Stack\backups\complete-installer\<TransactionId>`.

- Resume: `Resume-KIStack-Installer.cmd <TransactionId>`
- Audit: `Start-KIStack-Audit.cmd`
- Validate: `Start-KIStack-Validate.cmd`
- Repair after diagnosis: `Start-KIStack-Repair.cmd`
- Rollback: `Start-KIStack-Rollback.cmd`

Resume continues at the first incomplete step. Recovery checks pending and failed transactions before planning a new installation. Rollback restores only files changed by the selected transaction. Existing compliant models and user-owned data are retained.

The Greenfield contract was verified with source/package checks and small download fixtures; a complete physical Greenfield installation on an empty target was not performed for this release.

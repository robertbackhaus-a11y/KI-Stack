# KI-Stack Complete Installer 2.3.1 – Installation and upgrade

This guide applies to the Stable package `KI-Stack-Complete-Installer-v2.3.1.zip`. Version 2.3.1 corrects documentation only; functional validation is inherited unchanged from 2.3.0.

## Download and SHA-256

Download the ZIP and `KI-Stack-Complete-Installer-v2.3.1.zip.sha256` from the same GitHub Release. The authoritative hash is provided only by the sidecar and the GitHub Release description.

```powershell
$zip = '.\KI-Stack-Complete-Installer-v2.3.1.zip'
$expected = ((Get-Content "$zip.sha256" -Raw) -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw 'SHA-256 mismatch.' }
```

Extract the ZIP only after successful verification.

## Installation and upgrade

1. Extract the entire package.
2. Run `Start-KIStack-Installer.cmd` with PowerShell 7 and confirm the single UAC prompt.
3. When Visual or Agent changes, enter a temporary OpenWebUI administrator API key through the hidden prompt. It is used only in memory, never stored, and should be revoked in OpenWebUI afterwards.
4. Wait for `Completed` or `SkippedAlreadyCompliant`.

The same transactional upgrade path handles Greenfield, upgrade, and repair planning. Existing models that match filename, size, and SHA-256 are reused. Missing models are downloaded automatically from revision-pinned sources. An optional cache or `ExternalModels` preload may be used but is never required. Partial downloads support resume; an incorrect size or SHA-256 produces `Failed`.

The Greenfield contract was verified through source, package, and small local download fixtures. A complete physical Greenfield installation on an empty target was not performed for this release.

## Model roles

- Heretic is the only chat LLM.
- Nomic is used only for embeddings.
- `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf` is used only by Z-Image.
- The only active visual workflows are Z-Image Turbo and WAN2.2 T2V 14B with both LightX2V four-step LoRAs.
- FLUX, Krea, Pony, WAN-5B/I2V, and legacy Image Pack contracts are not active.

## Start, stop, and status

- Start: `Start-KIStack.cmd`
- Stop: `Stop-KIStack.cmd`
- Status: `Status-KIStack.cmd`
- Interactive status: `Lifecycle\Status-KIStack-Interactive.cmd`

Status is read-only and does not start services.

## Resume, recovery, and rollback

Transactions are stored under `C:\KI-Stack\state\complete-installer\<TransactionId>` and backups under `C:\KI-Stack\backups\complete-installer\<TransactionId>`.

- Resume: `Resume-KIStack-Installer.cmd <TransactionId>`
- Read-only audit: `Start-KIStack-Audit.cmd`
- Read-only validation: `Start-KIStack-Validate.cmd`
- Repair after diagnosis: `Start-KIStack-Repair.cmd`
- Controlled rollback: `Start-KIStack-Rollback.cmd`

Resume skips completed or already-compliant steps. Recovery checks pending or failed transactions before a new plan. Rollback restores only changes belonging to that transaction from its backup; pre-existing compliant models and user data remain outside deletion scope.

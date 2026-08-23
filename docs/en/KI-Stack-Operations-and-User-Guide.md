# KI-Stack 2.4.0 operations and user guide

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

## LM Studio and Codex Local

LM Studio is installed through `winget` but its local API server is not started as part of that install by itself. The managed starter `Start-KIStack-LMStudio.cmd` brings the server up:

- If LM Studio's `lms` CLI is already available, the starter starts the server directly.
- On a machine where LM Studio has never run before, `lms` only becomes available after LM Studio's GUI has completed its own first-run setup. The starter launches the GUI once, waits (with a bounded timeout) for `lms` to appear, then starts the local API server and confirms it answers at `http://127.0.0.1:1234/v1/models`.

Codex Local requires that same endpoint to be reachable. The Complete Installer invokes the LM Studio starter before configuring Codex Local for this reason, so a normal installation does not require starting LM Studio by hand. If you ever need to start LM Studio's server manually — for example after stopping it — run `Start-KIStack-LMStudio.cmd` from `C:\KI-Stack\modules\applications`.

## SearXNG, nginx, and Valkey

SearXNG is reachable through nginx at `/searxng`, proxying to a local `uwsgi`-hosted instance, with `valkey-server` backing its local rate-limiter/session store. The service may run under the Cutover Runtime's own `ki-stack-searxng.service` unit or under the Integration component's generic `uwsgi.service` unit — both are recognized as a valid, already-serving installation. If one of them is already healthy, the Integration component adopts it rather than starting a second, port-conflicting instance.

## OpenWebUI

The Agent Pack is 1.8.9 and the Visual Pack is 2.0.5. A temporary OpenWebUI administrator API key may be requested during a Visual/Agent update. It is hidden, held only in memory, never saved, and should be revoked after use.

Images remain visible chat content. MP4 output remains exactly one persistent downloadable FileItem after reload through `/api/v1/files/{id}/content`.

## RAG / Knowledge ingestion

The RAG module (0.2.0) is installed automatically under `C:\KI-Stack\modules\rag` as part of a normal installation, and its OpenWebUI search-prefix environment is wired into the existing OpenWebUI starter. Installation only validates the module's own source contract and places its files — it does **not** ingest any documents, and no sources are configured by default (`Config/sources.json` ships as an empty allow-list).

To actually ingest content, add entries to `Config/sources.json` (schema: `Contracts/source.schema.json`) yourself, then run the module's own entry point from `C:\KI-Stack\modules\rag`:

```powershell
.\Invoke-KIStackRAG.ps1 -Mode Execute -ApiToken (Read-Host -AsSecureString)
```

Available modes are `Audit`, `DryRun`, `Execute`, `Status`, and `Rollback`; only `Audit`, `DryRun`, and `Status` are guaranteed never to mutate OpenWebUI. The API token is accepted only as a `SecureString` and is never stored.

This ingestion path (the `Execute`/`Rollback` modes against a live OpenWebUI Knowledge collection) has **not** been separately target-system verified beyond the module's own installation being exercised during a successful Greenfield run — treat it as functional but not fully target-validated, per the module's own README.

## Knowledge bootstrap and Code Interpreter follow-up

Without a supplied OpenWebUI administrator API key, two finalization steps are left as manual follow-up (reported in the installer's final summary as `CredentialRequiredForApiReadback` and `CredentialRequiredForApiConfiguration` respectively):

- Removing the temporary Knowledge bootstrap experiment (unrelated to the RAG module's own ingestion above).
- Configuring the OpenWebUI Code Interpreter connection.

Supply a temporary administrator API key on a later run to have the installer complete these automatically, or complete them by hand in OpenWebUI.

## Transactions

Transaction state is stored under `C:\KI-Stack\state\complete-installer\<TransactionId>` and backups under `C:\KI-Stack\backups\complete-installer\<TransactionId>`.

- Resume: `Resume-KIStack-Installer.cmd <TransactionId>`
- Audit: `Start-KIStack-Audit.cmd`
- Validate: `Start-KIStack-Validate.cmd`
- Repair after diagnosis: `Start-KIStack-Repair.cmd`
- Rollback: `Start-KIStack-Rollback.cmd`

Resume continues at the first incomplete step. Recovery checks pending and failed transactions before planning a new installation. Rollback restores only files changed by the selected transaction. Existing compliant models and user-owned data are retained.

A first-time WSL2 activation on a genuinely empty machine can require a Windows restart; the installer stops with exit code `31` and prints the transaction ID to resume with afterwards. This is a normal, resumable pause, not a failure.

## Troubleshooting

- **Installer reports `RESTART REQUIRED` / exit code 31**: restart Windows, then run `Resume-KIStack-Installer.cmd <TransactionId>` with the printed transaction ID.
- **LM Studio / Codex Local step fails with an unreachable endpoint**: check whether LM Studio's window is open and whether `%USERPROFILE%\.lmstudio\bin\lms.exe` exists; if LM Studio was just installed for the very first time, its own first-run setup can take longer than the starter's wait window on a slow machine — resume the transaction to retry.
- **SearXNG appears unreachable**: check `systemctl status ki-stack-searxng uwsgi nginx valkey-server` inside the WSL Debian distribution; either `ki-stack-searxng` or `uwsgi` being active and healthy on port 8888 is a valid, expected state.
- **A step reports `CredentialRequiredForApiReadback` or `CredentialRequiredForApiConfiguration`**: this is expected when no OpenWebUI administrator API key was supplied; see the Knowledge bootstrap and Code Interpreter follow-up section above.

The Greenfield contract has been verified with a complete, successful, physical installation on an empty target.

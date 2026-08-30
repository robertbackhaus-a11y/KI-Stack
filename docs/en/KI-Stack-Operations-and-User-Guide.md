# KI-Stack 2.12.0 operations and user guide

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

The Agent Pack is 1.9.0 and the Visual Pack is 2.0.5. The Agent Pack manages three workspace models: `KI & IT-Technik`, `Allgemein`, and the reference research agent `ki-stack-research` (dynamically-bound local RAG knowledge plus web search, isolated Pyodide code interpreter, no Extension Tools, no shell/host/administrative access -- see "RAG / Knowledge ingestion" below and the Agent Pack's own README for the full contract). A temporary OpenWebUI administrator API key may be requested during a Visual/Agent update. It is hidden, held only in memory, never saved, and should be revoked after use.

Images remain visible chat content. MP4 output remains exactly one persistent downloadable FileItem after reload through `/api/v1/files/{id}/content`.

## RAG / Knowledge ingestion

The RAG module (0.4.0) is installed automatically under `C:\KI-Stack\modules\rag` as part of a normal installation, and its OpenWebUI search-prefix environment is wired into the existing OpenWebUI starter. Installation only validates the module's own source contract and places its files — it does **not** ingest any documents, and no sources are configured by default (`Config/sources.json` ships as an empty allow-list).

To actually ingest content, add entries to `Config/sources.json` (schema: `Contracts/source.schema.json`) yourself, then run the module's own entry point from `C:\KI-Stack\modules\rag`:

```powershell
.\Invoke-KIStackRAG.ps1 -Mode Execute -ApiToken (Read-Host -AsSecureString)
```

Available modes are `Audit`, `DryRun`, `Execute`, `Status`, and `Rollback`; only `Audit`, `DryRun`, and `Status` are guaranteed never to mutate OpenWebUI. The API token is accepted only as a `SecureString` and is never stored. `Invoke-KIStackRAG.ps1` is a schedulable entry point: a terminating error propagates as a non-zero process exit code, so it composes into an external scheduler (e.g. Windows Task Scheduler) without a wrapper for unattended, periodic re-import.

`Execute` re-imports sources idempotently by SHA-256: an unchanged source is left alone (`Skip`), a changed source is deleted-then-recreated remotely (`Replace`), a new source is added (`Add`), and a source removed from `Config/sources.json` is removed remotely (`Remove`) -- a partial failure leaves already-committed sources untouched, so a retry only reprocesses what did not finish. `Execute`/`Rollback` (Add, Replace, Remove) have passed real target-system validation against a live OpenWebUI instance, each including a repeated `Rollback` call confirmed as a clean, idempotent no-op, and are additionally covered by an extensive mocked regression suite.

By default, all sources belong to one global Knowledge collection. `New-KIStackRAGProjectScope.ps1 -ProjectName <name>` creates an additional, fully isolated project scope (its own config/sources file pair, mapped to its own, separate OpenWebUI Knowledge collection) so a project's documents never surface in an unrelated global answer, and vice versa.

The reference research agent `ki-stack-research` (OpenWebUI Agent Pack, see "OpenWebUI" above) resolves the global RAG Knowledge collection dynamically by name at install/reconcile time -- never a hardcoded collection id. If that collection does not exist yet (RAG has never run `Execute` on this target), `ki-stack-research` is skipped entirely on that run rather than created with an empty knowledge binding; every other managed profile still completes normally in the same run.

## Knowledge bootstrap and Code Interpreter follow-up

Without a supplied OpenWebUI administrator API key, two finalization steps are left as manual follow-up (reported in the installer's final summary as `CredentialRequiredForApiReadback` and `CredentialRequiredForApiConfiguration` respectively):

- Removing the temporary Knowledge bootstrap experiment (unrelated to the RAG module's own ingestion above).
- Configuring the OpenWebUI Code Interpreter connection.

Supply a temporary administrator API key on a later run to have the installer complete these automatically, or complete them by hand in OpenWebUI.

## Maintenance: reconcile and repeated-run behavior

Running Upgrade/Repair/Audit again on an already-installed target is a normal, supported operation. As of Cutover Runtime 1.6.14 and OpenWebUI Agent Pack 1.9.0:

- **Integration's OpenWebUI-with-search starter regeneration no longer erases RAG's embedding-prefix line.** Integration unconditionally regenerates `Start-KIStack-OpenWebUI-WithSearch.cmd` on every Install/Upgrade/Repair pass; a real regression previously caused an already-applied RAG `call "...\OpenWebUI-RAG.env.cmd"` line to be silently dropped whenever Integration reconciled without RAG also running in the same transaction. That line is now preserved across every regeneration.
- **Agent Pack reconcile no longer replaces a managed profile's `meta` wholesale.** OpenWebUI's own model-update endpoint replaces `meta` rather than merging it; the Agent Pack now merges on the package's own side before every Create/Update, so a live/UI-added value on an already-managed profile's `capabilities`, `builtinTools`, `access_grants`, or `profile_image_url` survives a reconcile untouched, while only the fields the package actually owns (name, base model, system prompt, tool/knowledge bindings, etc.) are reasserted.
- **RAG re-import is idempotent.** Re-running `Execute` against unchanged sources produces no remote mutation (`Skip`); only genuinely added, changed, or removed sources are touched.
- **A missing `ki-stack-research` Knowledge collection is a controlled skip, not a broken installation.** If RAG's global Knowledge collection does not exist yet, the Agent Pack skips creating/updating `ki-stack-research` on that run (never with an empty knowledge binding) and completes every other managed profile normally; running RAG's own `Execute` first and then reconciling the Agent Pack again resolves it.

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

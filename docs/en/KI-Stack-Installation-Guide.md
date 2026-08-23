# KI-Stack Complete Installer 2.4.0 – Installation and upgrade

This guide applies to the Stable package `KI-Stack-Complete-Installer-v2.4.0.zip`. Version 2.4.0 has been verified with a complete, successful, physical Greenfield installation on an empty target: every step completed and the installer finished with exit code 0.

## Download and SHA-256

Download the ZIP and `KI-Stack-Complete-Installer-v2.4.0.zip.sha256` from the same GitHub Release. The authoritative hash is provided only by the sidecar and the GitHub Release description.

```powershell
$zip = '.\KI-Stack-Complete-Installer-v2.4.0.zip'
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

The same transactional upgrade path handles Greenfield, upgrade, and repair planning. Existing models that match filename, size, and SHA-256 are reused. Missing models, including `nomic-embed-text-v1.5.Q4_K_M.gguf`, are downloaded automatically from revision-pinned sources. An optional cache or `ExternalModels` preload may be used but is never required. Partial downloads support resume; an incorrect size or SHA-256 produces `Failed`.

## Windows restart during Foundation / WSL2 setup

The Foundation step activates WSL2 and provisions the Debian runtime used by ComfyUI, SearXNG, and related services. On a machine where WSL2 has never been enabled, Windows requires a restart to finish that activation. When this happens, the installer stops with exit code `31` and prints `WINDOWS-NEUSTART ERFORDERLICH` together with the transaction ID. This is a normal, resumable pause, not a failure — no rollback is triggered.

After the restart, continue the same transaction:

```powershell
Resume-KIStack-Installer.cmd <TransactionId>
```

Steps that already completed before the restart are re-verified and skipped; the installer continues with the next pending step.

## LM Studio

LM Studio is installed through `winget`. On a genuinely fresh (Greenfield) machine, LM Studio's own command-line tool `lms` does not exist yet — it is only published under `%USERPROFILE%\.lmstudio\bin` after LM Studio's GUI has been launched once and completed its own first-run setup.

The managed starter `Start-KIStack-LMStudio.cmd` accounts for this automatically:

- If `lms` is already available, it starts the local API server directly (`lms server start --port 1234 --bind 127.0.0.1`).
- On a first Greenfield run, it launches the LM Studio GUI once, waits (bounded, not indefinitely) for `lms` to appear, then starts the local API server and waits for it to answer at `http://127.0.0.1:1234/v1/models` before continuing.

Codex Local depends on this endpoint being reachable (see below) and the Complete Installer invokes the same managed starter for that reason before configuring Codex — you do not need to start LM Studio by hand during a normal installation.

## Codex Local

Codex Local requires a live LM Studio model endpoint at `http://127.0.0.1:1234/v1/models`. The installer ensures LM Studio is running (see above) before it configures the Codex Local profile; if the endpoint is still not reachable after the bounded wait, the step fails clearly rather than silently skipping the requirement.

## SearXNG, nginx, and Valkey

SearXNG's local search endpoint is served through `uwsgi` behind an `nginx` reverse proxy at `/searxng`, backed by `valkey-server` for the local rate-limiter/session store. The Cutover Runtime component can install its own dedicated `ki-stack-searxng.service`; the Integration component treats either that unit or its own generic `uwsgi.service` as a valid, already-serving SearXNG instance and adopts it instead of starting a second, port-conflicting installation.

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

## Manual follow-up: API credentials, Knowledge bootstrap, Code Interpreter

If no OpenWebUI administrator API key was supplied during installation, two finalization steps cannot run automatically and remain manual follow-up work:

- Removing the temporary Knowledge bootstrap experiment (unrelated to the RAG module's own ingestion, shown as `CredentialRequiredForApiReadback` in the installer's final summary).
- Configuring the OpenWebUI Code Interpreter connection (shown as `CredentialRequiredForApiConfiguration`).

Supply a temporary administrator API key on a later run (or the same run's hidden prompt) to have the installer complete these automatically; otherwise complete them by hand in OpenWebUI afterwards.

## Resume, recovery, and rollback

Transactions are stored under `C:\KI-Stack\state\complete-installer\<TransactionId>` and backups under `C:\KI-Stack\backups\complete-installer\<TransactionId>`.

- Resume: `Resume-KIStack-Installer.cmd <TransactionId>`
- Read-only audit: `Start-KIStack-Audit.cmd`
- Read-only validation: `Start-KIStack-Validate.cmd`
- Repair after diagnosis: `Start-KIStack-Repair.cmd`
- Controlled rollback: `Start-KIStack-Rollback.cmd`

Resume skips completed or already-compliant steps. Recovery checks pending or failed transactions before a new plan. Rollback restores only changes belonging to that transaction from its backup; pre-existing compliant models and user data remain outside deletion scope.

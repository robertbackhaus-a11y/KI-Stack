# Installation, upgrade, and operations

1. Verify `KI-Stack-Complete-Installer-v2.4.0.zip` against its adjacent `.sha256` sidecar with `Get-FileHash -Algorithm SHA256`.
2. Extract the package and run `Start-KIStack-Installer.cmd` with PowerShell 7.
3. If first-time WSL activation reports `RESTART REQUIRED` (exit code 31), restart Windows and run `Resume-KIStack-Installer.cmd <TransactionId>`. `WaitingForRestart` is resumable and does not trigger rollback.
4. Confirm UAC. If requested, enter a temporary OpenWebUI administrator API key through the hidden prompt; it is never stored and should be revoked afterwards.
5. Accept only `Completed` or `SkippedAlreadyCompliant`.

Models, including embedding-only `nomic-embed-text-v1.5.Q4_K_M.gguf`, are downloaded automatically from revision-pinned sources. Existing targets and optional caches/preloads are reused only after exact size and SHA-256 verification. Partial downloads support resume; invalid size or hash fails. No preload is required.

## LM Studio and Codex Local

LM Studio is installed through `winget` and its local API server is not started as part of that install. The managed starter `Start-KIStack-LMStudio.cmd` (under `C:\KI-Stack\modules\applications`) handles this: if LM Studio's `lms` CLI is already available it starts the server directly; on a first-ever Greenfield run, where `lms` is only published under `%USERPROFILE%\.lmstudio\bin` after LM Studio's GUI completes its own first-run setup, the starter launches the GUI once, waits (bounded) for `lms` to appear, then starts the server and confirms it answers at `http://127.0.0.1:1234/v1/models`.

Codex Local requires that same endpoint. The installer invokes the LM Studio starter immediately before configuring the Codex Local profile, so a normal installation does not require starting LM Studio by hand.

## SearXNG, nginx, and Valkey

SearXNG's local endpoint runs under `uwsgi` behind an `nginx` reverse proxy at `/searxng`, with `valkey-server` backing its local rate-limiter/session store. It may already be served by the Cutover Runtime's dedicated `ki-stack-searxng.service` or the Integration component's own `uwsgi.service`; either is recognized as a valid, already-serving instance and adopted instead of starting a second, port-conflicting installation.

## RAG / Knowledge ingestion

The RAG module (0.2.0) is installed automatically under `C:\KI-Stack\modules\rag`; installation only validates its source contract and places its files, and its OpenWebUI search-prefix environment is wired into the existing OpenWebUI starter. It does **not** ingest any documents, and no sources are configured by default (`Config/sources.json` ships as an empty allow-list). To ingest content, add entries to `Config/sources.json` yourself and run `Invoke-KIStackRAG.ps1 -Mode Execute -ApiToken <SecureString>` from that directory (modes: `Audit`, `DryRun`, `Execute`, `Status`, `Rollback`; the token is never stored). This `Execute`/`Rollback` ingestion path has not been separately target-system verified beyond the module's own installation.

## Manual follow-up: API credentials

Without a supplied OpenWebUI administrator API key, the temporary Knowledge bootstrap-experiment rollback (`CredentialRequiredForApiReadback`, unrelated to the RAG module's own ingestion above) and the Code Interpreter connection configuration (`CredentialRequiredForApiConfiguration`) remain manual follow-up steps in OpenWebUI after installation.

Lifecycle:

- Start: `Start-KIStack.cmd`
- Stop: `Stop-KIStack.cmd`
- Status: `Status-KIStack.cmd`
- Interactive status: `Lifecycle\Status-KIStack-Interactive.cmd`

Transactions are under `C:\KI-Stack\state\complete-installer\<TransactionId>` and backups under `C:\KI-Stack\backups\complete-installer\<TransactionId>`.

Codex Local exclusively uses the package-managed Node.js runtime under `C:\KI-Stack\modules\codex-local\runtime`. The official Node.js archive is verified by size and SHA256 before activation. A global Node.js/npm installation is neither required nor installed.

- Resume: `Resume-KIStack-Installer.cmd <TransactionId>`
- Audit: `Start-KIStack-Audit.cmd`
- Validate: `Start-KIStack-Validate.cmd`
- Repair: `Start-KIStack-Repair.cmd`
- Rollback: `Start-KIStack-Rollback.cmd`

Recovery checks pending and failed transactions before a new plan. Rollback restores only the selected transaction. Existing compliant models and user data are retained.

The Greenfield contract has been verified with a complete, successful, physical installation on an empty target: every step completed and the installer exited with code 0.

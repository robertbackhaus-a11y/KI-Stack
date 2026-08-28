# Installation, upgrade, and operations

1. Verify `KI-Stack-Complete-Installer-v2.7.0.zip` against its adjacent `.sha256` sidecar with `Get-FileHash -Algorithm SHA256`.
2. Extract the package and run `Start-KIStack-Installer.cmd` with PowerShell 7.
3. If first-time WSL activation reports `RESTART REQUIRED` (exit code 31), restart Windows and run `Resume-KIStack-Installer.cmd <TransactionId>`. `WaitingForRestart` is resumable and does not trigger rollback.
4. Confirm UAC. If the OpenWebUI Visual Pack step is not yet compliant, OpenWebUI opens in your default browser once it and ComfyUI are reachable: complete first login (create the admin account) or sign in, generate an API key under Settings -> Account -> API Keys, then return to the installer and press Enter to continue. Enter that key through the hidden prompt; it is held only in memory as a `SecureString`, never stored, and should be revoked afterwards. The existing Visual Pack install/validate path then runs with that key, and a final prompt asks for one real image test and one real video test in OpenWebUI before the step is accepted.
5. Accept only `Completed` or `SkippedAlreadyCompliant`.

Models, including embedding-only `nomic-embed-text-v1.5.Q4_K_M.gguf`, are downloaded automatically from revision-pinned sources. Existing targets and optional caches/preloads are reused only after exact size and SHA-256 verification. Partial downloads support resume; invalid size or hash fails. No preload is required.

## OpenWebUI Visual Pack: first login and API key

OpenWebUI and ComfyUI are each checked with a bounded readiness wait before this step runs. `WaitingForUserAction` is reported only when both are reachable but no API key has been entered yet -- resume by re-running the installer command once the key is ready. If OpenWebUI or ComfyUI stays unreachable beyond its readiness wait, the installer fails with a real error instead, since no user action can resolve a service that is not running.

## LM Studio and Codex Local

LM Studio is installed through `winget` and its local API server is not started as part of that install. The managed starter `Start-KIStack-LMStudio.cmd` (under `C:\KI-Stack\modules\applications`) handles this: if LM Studio's `lms` CLI is already available it starts the server directly; on a first-ever Greenfield run, where `lms` is only published under `%USERPROFILE%\.lmstudio\bin` after LM Studio's GUI completes its own first-run setup, the starter launches the GUI once, waits (bounded) for `lms` to appear, then starts the server and confirms it answers at `http://127.0.0.1:1234/v1/models`.

Codex Local requires that same endpoint. The installer invokes the LM Studio starter immediately before configuring the Codex Local profile, so a normal installation does not require starting LM Studio by hand. Codex Local's own wait for that endpoint treats the starter as the authoritative timeout contract: it waits at least as long as the starter's own genuine first-run window (up to ~120s) and observes the starter's process/exit code, so a real starter failure is reported immediately instead of the caller giving up on a shorter, independent timer while the starter is still legitimately starting.

## Updating OpenWebUI

Do not upgrade or downgrade OpenWebUI by hand with `pip` inside its venv, and do not run `pip install`/`pip uninstall` against it outside this contract. `Update-KIStack-OpenWebUI.cmd` (deployed to `C:\KI-Stack`) is the sole, binding entry point for changing OpenWebUI's installed version. It reads the target version from the single central `kernel-config.json` used by the Applications module -- there is no second, competing version source -- and reuses the existing managed venv (`C:\KI-Stack\python\venvs\openwebui`) in place; it never creates a second venv or a parallel OpenWebUI installation. Both directions go through the same contract: an upgrade and a downgrade are both just "install the pinned target version into the existing venv," followed by a managed stop/restart of the OpenWebUI process and a local healthcheck. If the target version is already installed, it reports `Skip` and changes nothing. If the update or the post-update healthcheck fails, it automatically rolls back to the previously installed version, re-verifies that version and its healthcheck, and then reports the original failure. Deployment of the underlying CutoverRuntime payload also keeps each persistent payload-type folder under `C:\KI-Stack\installer\complete\Payload\` unique -- a fresh deployment removes any stale or misplaced payload file for that type before copying in the current one, so `Update-KIStack-OpenWebUI.cmd` always resolves exactly one payload to read the target version from.

Real-target acceptance (`C:\KI-Stack`): `Skip` with the target version already installed -- PASS, no mutation. Controlled downgrade `0.11.0 -> 0.10.2` via this script -- PASS (managed venv only, stop/restart, healthcheck). Controlled upgrade back `0.10.2 -> 0.11.0` via this script -- PASS. Healthcheck after each step -- HTTP 200. Final installed version -- `0.11.0`, matching `kernel-config.json`.

## SearXNG, nginx, and Valkey

SearXNG's local endpoint runs under `uwsgi` behind an `nginx` reverse proxy at `/searxng`, with `valkey-server` backing its local rate-limiter/session store. It may already be served by the Cutover Runtime's dedicated `ki-stack-searxng.service` or the Integration component's own `uwsgi.service`; either is recognized as a valid, already-serving instance and adopted instead of starting a second, port-conflicting installation.

## RAG / Knowledge ingestion

The RAG module (0.3.1) is installed automatically under `C:\KI-Stack\modules\rag`; installation only validates its source contract and places its files, and its OpenWebUI search-prefix environment is wired into the existing OpenWebUI starter. It does **not** ingest any documents, and no sources are configured by default (`Config/sources.json` ships as an empty allow-list). To ingest content, add entries to `Config/sources.json` yourself and run `Invoke-KIStackRAG.ps1 -Mode Execute -ApiToken <SecureString>` from that directory (modes: `Audit`, `DryRun`, `Execute`, `Status`, `Rollback`; the token is never stored; `Audit`/`DryRun`/`Status` are read-only and never mutate the target). `Execute` (Add/Query/Replace/Remove) and `Rollback` of all three mutating actions (Add, Replace, Remove) have passed real target-system validation against a live OpenWebUI 0.11.0 instance, each including a repeated `Rollback` call confirmed as a clean, idempotent no-op. `Rollback` is additionally covered by an extensive mocked regression suite, including explicit partial-failure-then-retry coverage for the Replace/Remove restore path. Every `Execute` mutation of OpenWebUI's global embedding configuration is idempotent and backed up beforehand; automatic restore on failure or Rollback only happens when that backup provably held no credential value RAG could not save, otherwise the result reports `EmbeddingRestoreRequiresManualAction` instead of a destructive partial restore.

## Manual follow-up: API credentials

Without a supplied OpenWebUI administrator API key, the temporary Knowledge bootstrap-experiment rollback (`CredentialRequiredForApiReadback`, unrelated to the RAG module's own ingestion above) and the Code Interpreter connection configuration (`CredentialRequiredForApiConfiguration`) remain manual follow-up steps in OpenWebUI after installation.

Lifecycle:

- Start: `Start-KIStack.cmd`
- Stop: `Stop-KIStack.cmd`
- Status: `Status-KIStack.cmd`
- Interactive status: `Lifecycle\Status-KIStack-Interactive.cmd`
- Managed OpenWebUI update (upgrade or downgrade to the version pinned in `kernel-config.json`, with automatic rollback on failure): `Update-KIStack-OpenWebUI.cmd`

Transactions are under `C:\KI-Stack\state\complete-installer\<TransactionId>` and backups under `C:\KI-Stack\backups\complete-installer\<TransactionId>`.

Codex Local exclusively uses the package-managed Node.js runtime under `C:\KI-Stack\modules\codex-local\runtime`. The official Node.js archive is verified by size and SHA256 before activation. A global Node.js/npm installation is neither required nor installed.

- Resume: `Resume-KIStack-Installer.cmd <TransactionId>`
- Audit: `Start-KIStack-Audit.cmd`
- Validate: `Start-KIStack-Validate.cmd`
- Repair: `Start-KIStack-Repair.cmd`
- Rollback: `Start-KIStack-Rollback.cmd`

Recovery checks pending and failed transactions before a new plan. Rollback restores only the selected transaction. Existing compliant models and user data are retained.

The Greenfield contract has been verified with a complete, successful, physical installation on an empty target: every step completed and the installer exited with code 0.

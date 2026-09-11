# KI-Stack 2.18.1 operations and user guide

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

### Codex Local: install, update, repair, status

Codex Local wraps the `@openai/codex` CLI with its own managed Node.js runtime under `C:\KI-Stack\modules\codex-local` -- no system-wide Node/npm install, no global PATH changes. It supports the same Install/Upgrade/Repair/Validate/Rollback contract as every other isolated component, plus a dedicated `Status` action:

- **Install** requires LM Studio's endpoint reachable (the existing, hardened Greenfield contract -- it starts LM Studio itself via the managed starter above if needed) -- this proves the setup works end to end before completing. **Upgrade and Repair of an already-recorded installation never require this**: they only reconcile the Codex package itself (runtime, CLI version, marker), which does not need LM Studio running at that exact moment.
- **Isolated CODEX_HOME**: Codex Local runs against its own, isolated home at `C:\KI-Stack\state\codex-local\codex-home` -- never the real, shared `%USERPROFILE%\.codex` that any other Codex CLI usage on the machine would use. Every real invocation (the generated starter, `Status`/`Validate`, the Analysis/Audit acceptance call, and the Complete Installer's own Codex Local compliance check) sets `CODEX_HOME` explicitly for that one child process; none of them ever fall back to the ambient environment. This closes a real, previously-documented Architekturfund from the Greenfield-Cold-Start workstream: pre-existing state in a real, shared `~/.codex` was found to be the actual root cause of a reproduced wrong-model auto-download that the explicit `-m` model pin alone did not reliably prevent. Nothing is migrated out of the old shared location -- a Greenfield install gets a clean isolated home, and an existing installation initializes one fresh on its next real Install/Upgrade/Repair; the real, shared `%USERPROFILE%\.codex` (and any foreign Codex sessions/config/credentials in it) is never read, written, or deleted.
- **Preserve contract**: `C:\KI-Stack\state\codex-local\codex-home\ki-stack-local.config.toml` (sandbox/approval policy) and the workspace's `AGENTS.md` (agent working instructions) are written only if they do not already exist -- an Upgrade or Repair never overwrites a hand-edited copy of either. Everything else under `modules/codex-local` (the Node runtime, the npm-global Codex CLI install, the marker, the starter script) is fully managed and reconciled to the configured target on every real run.
- **Idempotent**: re-running Install/Upgrade/Repair against an already-compliant installation is a fast, no-op `SkippedAlreadyCompliant` -- no repeated npm/network work, no duplicated files.
- **Backup/Rollback**: every real, non-skipped run backs up the managed files, the marker, and the two preserve-contract files under `C:\KI-Stack\backups\codex-local\<timestamp>` before touching anything; a failure during that run restores this exact snapshot automatically.
- **Status** (`Invoke-KIStackCodexLocal.ps1 -Action Status`) reports `Installed`/`InstalledVersion`/`InstallPath`/`RuntimeReady`/`LMStudioEndpointConfigured`/`Healthy`/`Reason` plus one of four states: `NotInstalled`, `Broken` (the Codex package itself is damaged -- missing/corrupt managed files), `RuntimeUnavailable` (Codex Local is correctly installed, but LM Studio is not reachable right now -- never treated as broken), or `Healthy`. `AvailableVersion`/`VersionStatus` are intentionally not re-derived here -- the central `Update-KIStack-All.ps1` report already resolves those from the same registry every other internal component uses (see the section above); Status never duplicates that lookup.
- **Single-component update**: `Update-KIStack-All.ps1 -Component codex-local` only ever touches Codex Local -- no other component, no Complete Installer batch, no finalizer. Its post-action health check never requires LM Studio reachable either, for the same reason Upgrade/Repair do not.

### LM Studio + Codex Local: first install, first boot, recovery, restart

- **First install.** LM Studio is installed via `winget install --id ElementLabs.LMStudio --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity` -- fully non-interactive, no GUI dialog to accept by hand. This only installs the application; it does not yet start its API server or select a model.
- **First boot / headless API mode.** The managed starter (`Start-KIStack-LMStudio.cmd`) is what actually brings the API server up, on the very first run as much as on any later one: if the `lms` CLI is not yet resolvable (a true first boot -- `lms` is only written to `%USERPROFILE%\.lmstudio\bin` after LM Studio's own GUI completes its first-run setup), the starter launches the GUI once, waits up to ~90s for `lms` to appear, then runs `lms server start --port 1234 --bind 127.0.0.1` and confirms `GET http://127.0.0.1:1234/v1/models` answers before exiting 0. No manual GUI configuration step is required anywhere in this path.
- **Model contract.** The one supported chat model is `qwen3.6-27b-uncensored-heretic-v2-native-mtp-preserved` (`Contracts/PAYLOADS.json`'s `modelPolicy.chatModels`), backed by `Qwen3.6-27B-uncensored-heretic-v2-Native-MTP-Preserved-Q5_K_M.gguf` from a revision-pinned Hugging Face source, verified by exact size and SHA-256 before activation (`Contracts/PAYLOADS.json`'s `policy.automaticDownload`/`verifyBeforeActivation`) and placed into LM Studio's own standard model tree (`%USERPROFILE%\.lmstudio\models\<publisher>\<repo>\...`) -- never a separate KI-Stack-specific model directory.
- **Model loading is real but implicit.** Nothing in this codebase explicitly runs `lms load` for the chat model the way RAG's own module does for its embedding model (`Assert-RAGEmbeddingModelReady` in `KIStackRAG.psm1`) -- the chat model is expected to become ready through LM Studio's own just-in-time loading, triggered by the first real inference request. This worked reliably in a real, non-Greenfield test against the already-provisioned real model on this project's own RTX 5090 (see the Codex Local Greenfield workstream's final report), but it is a real, honestly-documented gap: Codex Local's own health check (`Test-KILMStudioEndpoint`) only verifies that `GET /v1/models` answers at all, never that the specific target chat model is loaded and ready -- a reachable-but-not-yet-loaded LM Studio still reports `Healthy`.
- **RuntimeUnavailable, never Broken.** If LM Studio is not reachable (not yet started, still loading, or genuinely not installed), Codex Local's own `Status` reports `RuntimeUnavailable` with a plain-language reason -- never `Broken`, and never a marker/config change. Starting LM Studio and re-running `Status` (no repair, no reinstall) returns to `Healthy` on its own.
- **Restart is not a one-shot state.** Stopping LM Studio's server and Codex Local's own (per-invocation, non-daemon) process, then starting both again through the same managed starters, reaches the same working, callable state again -- proven in this workstream's isolated fixture suite via a real stop/restart cycle.
- **Scope of the real evidence behind this section.** This project does not have a disposable Greenfield VM/snapshot available to it; a genuine "LM Studio was never installed on this machine before" first-boot proof was therefore not performed here (a real, already-installed LM Studio and a real, already-downloaded model on this project's own machine were used instead, for a real but non-Greenfield functional proof, and the Codex Local side of the contract was proven fresh in an isolated fixture). See the Codex Local Greenfield workstream's own final report for the exact, itemized boundary between what was proven for real and what remains a documented gap.

## SearXNG, nginx, and Valkey

SearXNG is reachable through nginx at `/searxng`, proxying to a local `uwsgi`-hosted instance, with `valkey-server` backing its local rate-limiter/session store. The service may run under the Cutover Runtime's own `ki-stack-searxng.service` unit or under the Integration component's generic `uwsgi.service` unit — both are recognized as a valid, already-serving installation. If one of them is already healthy, the Integration component adopts it rather than starting a second, port-conflicting instance.

## OpenWebUI

The Agent Pack is `1.9.0` and the Visual Pack is `2.0.5`.

Current managed-profile policy:

- `ki-stack-it-technik`: MCP Runtime enabled for local terminal/host control; native Open WebUI Memory enabled.
- `ki-stack-allgemein`: MCP Runtime enabled for local terminal/host control; native Open WebUI Memory enabled.
- `ki-stack-research`: dynamically-bound local RAG Knowledge, SearXNG web search, and isolated Pyodide Code Interpreter; no MCP terminal binding; native Memory disabled.
- `ki-stack-18bravo`: Ballistics profile with its technical MCP binding preserved; native Memory disabled.
- `roleplay`: outside the managed Memory policy.

Images remain visible chat content. MP4 output remains exactly one persistent downloadable FileItem after reload through `/api/v1/files/{id}/content`.

## MCP Runtime and Local Control

MCP Runtime `0.1.0` is the primary terminal and host-control backend for MCP-enabled KI-Stack profiles. It runs locally on `127.0.0.1:8021` through Open WebUI's MCP tool-server mechanism.

It exposes the managed tool surface for command execution, process control, filesystem operations, search, and file display. KI-Stack 2.16 builds Local Control on that same runtime rather than introducing another Windows-control service.

Operationally this means:

- use the normal Open WebUI profile;
- the profile invokes the registered MCP tools;
- general Windows/WSL/application work uses the existing MCP surface, especially `run_command`, PowerShell, and the KI-Stack lifecycle scripts;
- no second Local-Control port, runtime, or credential exists.

The MCP Runtime is installed and reconciled by the Complete Installer. Since 2.18, the central start (`Start-KIStack.cmd`) also covers MCP Runtime: it starts before Open WebUI and is proven healthy through the existing MCP health contract; if that fails, Open WebUI is not started. The central stop stops Open WebUI first, MCP Runtime last. A target without MCP Runtime installed is unaffected.

## Native Memory

KI-Stack 2.17 uses Open WebUI's own native Memory implementation.

Memory policy:

- enabled: `ki-stack-it-technik`, `ki-stack-allgemein`
- disabled: `ki-stack-18bravo`, `ki-stack-research`
- unmanaged by this contract: `roleplay`

Memory is user-scoped and stored in Open WebUI's `webui.db`. For the same authenticated user it may be reused across chats and managed profiles.

A chat/request must still activate Memory with `features.memory=true`; Open WebUI 0.11.3 does not provide a persisted server-side default for that request flag.

For database protection, 2.17 provides:

- online SQLite backup through `VACUUM INTO`;
- integrity validation of the resulting backup;
- controlled restore tooling;
- a mandatory pre-restore safety backup;
- WAL/SHM handling;
- post-restore health validation.

A real production online backup was performed. Controlled restore acceptance was performed against a temporary database copy; no production `webui.db` restore was performed.

## Open Terminal fallback

Open Terminal `0.1.0` remains installed, supported, lifecycle-managed, and available at `http://127.0.0.1:8000`, but it is no longer the default terminal/host-control path for production MCP-enabled profiles.

Use Open Terminal only as an explicit fallback or rollback path.

It continues to use:

- the managed KI-Stack Python/uv runtime;
- its persistent DPAPI-protected API key;
- bounded readiness checks;
- process-identity validation;
- central KI-Stack Start/Stop/Status handling.

If the fallback is deliberately used through Open WebUI's legacy OpenAPI tool-server integration, that registration remains a separate explicit configuration step. Normal MCP-based operation does not require it.
## OpenWebUI Credential Bootstrap

Administrative KI-Stack automation uses one centralized persistent Open WebUI credential.

`Initialize-KIStackOpenWebUICredential.ps1` performs the one-time interactive bootstrap:

- prompts for the Open WebUI administrator account;
- signs in through Open WebUI's supported API;
- enables API-key support where required;
- creates a persistent per-user API key;
- validates the key before storing anything.

The key is stored only DPAPI-encrypted under `C:\KI-Stack\state\openwebui\credential.json`. It is never stored in plaintext in the repository, build artifacts, command lines, reports, or logs.

Subsequent Complete Installer, Agent Pack, RAG, Knowledge, and Code Interpreter operations resolve and reuse the same credential automatically.

Supported credential operations:

- status: `Test-KIStackOpenWebUICredential.ps1`
- bootstrap/reuse: `Initialize-KIStackOpenWebUICredential.ps1`
- rotate: `Initialize-KIStackOpenWebUICredential.ps1 -Rotate`
- revoke: `Remove-KIStackOpenWebUICredential.ps1`

Rotation validates the replacement before superseding the previous working credential. Revoke removes only the KI-Stack-owned local credential and associated key.

If Open WebUI is unavailable, the credential is not falsely reported as invalid. If a usable administrator credential is missing, API-dependent work is reported as controlled Pending/Blocked instead of continuing unauthenticated.

### Research agent web search

`ki-stack-research` is managed as a research profile with dynamically-bound local RAG Knowledge, SearXNG-backed web search, and isolated Pyodide Code Interpreter.

The profile's package contract, tool bindings, and Knowledge binding are reconciled by the Agent Pack. Historical headless/API execution-path evidence from earlier Open WebUI releases remains documented in the corresponding release records; this current operations guide does not treat those earlier version-specific observations as the operating contract for Open WebUI 0.11.3.
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

## Credential-dependent finalization

Agent Pack, RAG/Knowledge wiring, and Code Interpreter configuration use the centralized Open WebUI credential described above.

With a valid stored credential, these steps are completed automatically during the supported installer/reconcile flow.

If the credential is missing, invalid, unavailable, or lacks administrator privileges, the affected API-dependent work is reported as controlled Pending/Blocked with diagnosis. Do not supply or maintain a separate temporary administrator API key as a normal operating procedure; bootstrap or repair the centralized KI-Stack credential instead.

## Maintenance: reconcile and repeated-run behavior

Running Upgrade/Repair/Audit again on an already-installed target is a normal, supported operation. As of Cutover Runtime 1.6.14 and OpenWebUI Agent Pack 1.9.0:

- **Integration's OpenWebUI-with-search starter regeneration no longer erases RAG's embedding-prefix line.** Integration unconditionally regenerates `Start-KIStack-OpenWebUI-WithSearch.cmd` on every Install/Upgrade/Repair pass; a real regression previously caused an already-applied RAG `call "...\OpenWebUI-RAG.env.cmd"` line to be silently dropped whenever Integration reconciled without RAG also running in the same transaction. That line is now preserved across every regeneration.
- **Agent Pack reconcile no longer replaces a managed profile's `meta` wholesale.** OpenWebUI's own model-update endpoint replaces `meta` rather than merging it; the Agent Pack now merges on the package's own side before every Create/Update, so a live/UI-added value on an already-managed profile's `capabilities`, `builtinTools`, `access_grants`, or `profile_image_url` survives a reconcile untouched, while only the fields the package actually owns (name, base model, system prompt, tool/knowledge bindings, etc.) are reasserted.
- **RAG re-import is idempotent.** Re-running `Execute` against unchanged sources produces no remote mutation (`Skip`); only genuinely added, changed, or removed sources are touched.
- **A missing `ki-stack-research` Knowledge collection is a controlled skip, not a broken installation.** If RAG's global Knowledge collection does not exist yet, the Agent Pack skips creating/updating `ki-stack-research` on that run (never with an empty knowledge binding) and completes every other managed profile normally; running RAG's own `Execute` first and then reconciling the Agent Pack again resolves it.

## Component isolation: selecting one component is not the same as running a batch

`Update-KIStack-All.ps1 -Component <id>` (one or more ids) resolves a structured plan before anything runs: `Resolve-KIStackUpdatePlan` (`Lifecycle/KIStackUpdateIsolation.psm1`) turns the selection into `Selected`, `Dependencies`, `Will update`, `Will preserve`, and `Cannot update`, and prints all five before asking for confirmation. `-CheckOnly` and a real run resolve the exact same plan -- a DryRun never shows a different outcome than what Execute would actually do.

- **Selection ≠ batch.** `openwebui-agent-pack`, `openwebui-visual-pack`, `openwebui-ballistics-pack`, `codex-local`, `rag`, `comfyui`, `models-workflows`, `integration`, and `validation-gate` each have their own self-contained install/backup/rollback entry point (`Invoke-KIStackIsolatedComponentUpdate`) and never invoke the full Complete-Installer transaction, its orchestrator/central-starter/Operations redeploy, or its unconditional Knowledge-experiment-rollback/Code-Interpreter steps. Selecting only one of them touches only that one component -- everything else is listed under `Will preserve` and is not read, probed for mutation, or written. `comfyui`'s isolated route re-checks for an existing, already-supported installation immediately before any mutation, so a newer, git-managed ComfyUI version is never reset back to the Greenfield reference version.
- **Dependencies are named, never silent.** `rag` requires `integration` (it reads and rewrites Integration's OpenWebUI-with-search starter); if Integration is not already compliant, it is listed under `Dependencies` and, if it also needs action, under `Will update` too -- never silently skipped and never silently left to a batch run to fix. Because Integration itself now updates in isolation, selecting `-Component rag` against a non-compliant target today resolves fully without any Complete-Installer batch: Integration first, then RAG, everything else untouched.
- **Components without an isolated path today** (the shared Foundation/Python-Git/Applications/Cutover-Runtime BuilderKernel execution, plus Production Recovery and Target Acceptance, neither of which has an independent installation path at all) still require the Complete-Installer batch route. Selecting one of them alone is refused (`Cannot update`, mode `Blocked`, exit code 1) whenever the real batch run would additionally touch some other, currently non-compliant component the selection never named -- the omitted component(s) are named explicitly in the refusal. Naming every affected component explicitly, or passing `-Component complete-installer` to authorize the real, full batch on purpose, both proceed.
- **Failure isolation.** If several components are planned in the same run and one fails, components already completed keep that status, the failed one is reported `Failed` with its own detail, and every component still queued behind it is reported `NotRun` (never silently omitted) rather than started.

## Component versions: installed, source, and published are three different things

`Update-KIStack-All.ps1`'s report used to show `AvailableVersion=Unknown` for every KI-Stack-own component (Agent Pack, Visual Pack, Ballistics Pack, RAG, Codex Local, Models/Workflows, Integration, Validation Gate, Cutover Runtime, and the components that ride on it) -- correct for a truly external upstream project, but not for a component this project itself versions and publishes. `Lifecycle/KIStackComponentVersionRegistry.psm1`, driven by new `Contracts/COMPONENTS.json` fields (`versionSourceType`, `packageIdentity`, `referenceComponent`), closes that gap for every component with a real, belastable source.

- **Three versions, never conflated.** **InstalledVersion** is what the existing probe (`VERSION` file, manifest field, or install marker) reads off the real target -- unchanged. **SourceVersion** is whatever a development checkout's own working tree currently has in that same file -- a purely local, in-progress value that is never shown to, or acted on by, a production target. **AvailableVersion/PublishedVersion** is what that same file reads AT the commit tagged by the most recently published Complete Installer GitHub release -- the actual, real distribution mechanism for every one of these components today (verified against this repository's own release history: the many per-component release channels stopped being cut once the unified Complete Installer release train took over, and every bundled component's version has moved in lockstep with it ever since).
- **Why not the working tree.** A development branch may have already bumped a component's own version ahead of what was last published (e.g. Agent Pack `1.9.1` in progress vs. `1.9.0` actually released). Reporting the working-tree value as "available" to a production target would offer an update that does not exist yet. AvailableVersion is therefore always read from the tagged release via GitHub's raw content API, never from a local file path.
- **Not every published release is a Complete Installer release.** This repository has published dozens of per-component releases (ComfyUI, Integration, Models/Workflows, OpenWebUI packs, Production Recovery, Python/Git, ...) under very inconsistent tag names over its history. The registry never assumes the newest tag by name or date is relevant -- it specifically looks for the most recent release whose assets include a `KI-Stack-Complete-Installer-*.zip`, then reads each component's own file inside that exact tagged commit. A Complete Installer release's own version number (e.g. `2.14.0`) is never mistaken for e.g. RAG's version (`0.4.0`) -- each component's value comes from its own named file, never from the release's own version string.
- **NewerInstalled / Preserve.** If InstalledVersion is newer than the currently published AvailableVersion, the status is `NewerInstalled`, exactly mirroring the existing OpenWebUI/ComfyUI preserve-newer-supported contract -- never treated as needing a downgrade.
- **Offline behavior.** If GitHub cannot be reached (no `gh` CLI, no network, API failure), AvailableVersion reports `VersionUnavailable` with a plain-text reason; InstalledVersion is still shown as probed, and no update is ever claimed to be available or not available on missing data. Components that structurally never had their own independent version (the shared Foundation/Python-Git/Applications/Cutover-Runtime execution unit, and Target Acceptance riding on Production Recovery) report `VersionUnavailable` too, by design, mirroring the status of the component whose bundle they actually ship inside -- their own version number is never compared against a differently-scaled reference number.
- **Purely additional.** This registry never changes what `Update-KIStack-All.ps1` actually updates -- that decision still comes entirely from the existing installed-vs-pinned compliance check. `packageAvailableVersion`/`packageVersionSource`/`packageVersionStatus` are new, purely informational report columns alongside the existing ones.

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
- **An Open WebUI API-dependent step reports a credential-related Pending/Blocked state**: run `Test-KIStackOpenWebUICredential.ps1`. If no valid credential exists, bootstrap it with `Initialize-KIStackOpenWebUICredential.ps1`; do not fall back to a separately maintained temporary API key.

The last complete, successful, physical Greenfield installation on an empty target was verified with Complete Installer 2.4.0. Later releases through 2.18.1 add regression, package, component, upgrade/reconcile, and real-target evidence but do not claim a newer complete empty-target Windows Greenfield run.

## Known open items

- **Latency tracing**: there is still no dedicated end-to-end timing breakdown for Open WebUI input -> prompt/tool assembly -> LM Studio request -> first token.
- **Memory request default**: Open WebUI 0.11.3 has no persisted server-side default for `features.memory=true`.
- **Production database restore**: online `webui.db` backup is real-target validated and controlled restore is acceptance-tested, but no production database restore has been performed.
- **GUI/Desktop automation**: broad graphical desktop/application automation is outside 2.18; the controlled Desktop Control layer is deliberately narrow and its MCP wiring is not yet activated.
- **Bootstrap phase without PowerShell 7**: the bootstrap path used when PowerShell 7 itself is missing has no live heartbeat display of its own and writes a structured `.bootstrap.jsonl` diagnostic log instead.

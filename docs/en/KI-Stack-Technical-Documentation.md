# KI-Stack 2.18.0 technical documentation

KI-Stack is a transactional Windows local-AI stack. Complete Installer `2.18.0` is the current published GitHub Release.

The validation record must be read by scope rather than as one interchangeable claim: the last complete physical Greenfield installation on an empty Windows target was performed and verified with 2.4.0; Complete Installer 2.10.0 remains the documented whole-stack regression plus real-target reference run; later releases added additional real-target, component, upgrade/reconcile, security, and package-validation evidence without claiming a newer full empty-target Windows Greenfield run.

The current 2.18 architecture includes the MCP Runtime introduced in 2.15 as the primary terminal/host-control path for MCP-enabled profiles, autonomous Local Control on that existing runtime from 2.16, and Open WebUI native persistent Memory plus database backup/restore protection from 2.17. Open Terminal remains installed and supported as an explicit fallback/rollback path. 2.18 adds, on top of that, the centrally managed Windows UI Automation base WinApp `0.6.1` and the controlled semantic UIA layer Desktop Control `0.1.0`.

## Active components

| Component | Version |
|---|---:|
| Foundation / Runtime | 1.0.9 |
| Python / Git | 1.1.5 |
| ComfyUI | 1.2.4 |
| Models / Workflows | 2.0.3 |
| Applications | 1.4.11 |
| Integration | 1.5.11 |
| Cutover Runtime | 1.6.14 |
| Codex Local | 0.2.1 |
| RAG | 0.4.0 |
| MCP Runtime | 0.1.0 |
| Open Terminal | 0.1.0 |
| WinApp | 0.6.1 |
| Desktop Control | 0.1.0 |
| Production Recovery | 1.7.0-r7 |
| Validation Gate | 1.0.3 |
| Target Acceptance | 1.0.10 |
| OpenWebUI Visual Pack | 2.0.5 |
| OpenWebUI Agent Pack | 1.9.0 |
| Complete Installer | 2.18.0 |

ComfyUI's reference and minimum supported version for reproducible Greenfield installs and reconciliation is `v0.34.0`; an existing, supported newer installation is preserved and never auto-downgraded. Open WebUI's `ReferenceVersion` and `MinimumSupportedVersion` are both `0.11.3` -- any installed version from `0.11.3` up is supported, and an existing, supported newer installation is preserved the same way, never auto-downgraded to the exact reference.

OpenWebUI Agent Pack `1.9.0` manages `ki-stack-it-technik`, `ki-stack-allgemein`, and `ki-stack-research`. MCP-enabled production profiles use MCP Runtime where terminal/host control is permitted. `ki-stack-research` deliberately has no MCP terminal binding and combines dynamically-bound local RAG Knowledge, SearXNG web search, and isolated Pyodide Code Interpreter. Native Open WebUI Memory is enabled for `ki-stack-it-technik` and `ki-stack-allgemein`, disabled for `ki-stack-research`; the Ballistics Pack keeps Memory disabled for `ki-stack-18bravo`. Reconcile preserves permitted live/UI metadata and KI-Stack MCP bindings rather than silently removing them. RAG `0.4.0` provides global and isolated project-scoped Knowledge collections.

Heretic is the only selectable chat LLM. Nomic is embedding-only. Z-Image uses only `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`. Visual execution is limited to Z-Image Turbo and WAN2.2 T2V 14B with the high/low LightX2V four-step LoRAs.


## Model acquisition

The central versioned manifest contains revision-pinned sources, filenames, sizes, and SHA-256 values. A valid installed target is reused first, followed by an optional verified cache/preload. Missing files are downloaded automatically into transaction state, with Range resume where supported. Atomic activation occurs only after full size and SHA-256 verification. Network failure remains resumable; incorrect size or hash fails the component.

No model weights are embedded in Git or the Complete Installer ZIP. Preloads are optional and are not an installation prerequisite.


## SearXNG, nginx, and Valkey

SearXNG's local search endpoint runs under `uwsgi` behind an `nginx` reverse proxy at `/searxng`, backed by `valkey-server` for the local rate-limiter/session store. Two independent installation paths exist for this service:

- The Cutover Runtime component can install a dedicated `ki-stack-searxng.service` systemd unit.
- The Integration component can install the generic `uwsgi.service` unit (the Debian package's own `apps-enabled` mechanism).

Both are treated as equally valid signals of an already-serving SearXNG instance. Before either path performs a fresh install, it probes the local backend directly; if a healthy instance already answers, that instance is adopted and no second, port-conflicting installation is started.


## LM Studio and Codex Local

LM Studio is installed through `winget`; its local API server is not started as part of that install. The managed starter `Start-KIStack-LMStudio.cmd` (generated under `C:\KI-Stack\modules\applications`) resolves LM Studio's `lms` CLI — either already on `PATH`/under `%USERPROFILE%\.lmstudio\bin`, or, on a first-ever run, by launching the GUI once and waiting (with a bounded timeout) for `lms` to be published there after LM Studio's own first-run setup — and then starts the local API server, confirming it answers at `http://127.0.0.1:1234/v1/models` before returning.

Codex Local depends on that same endpoint. The Complete Installer invokes the LM Studio starter immediately before configuring the Codex Local profile so the endpoint is live by the time Codex Local needs it; if it is still unreachable after the bounded wait, the step fails with a clear error rather than silently continuing.


## MCP Runtime and Local Control

MCP Runtime `0.1.0`, introduced with KI-Stack 2.15, is a self-contained Complete Installer component and the primary terminal/host-control backend for MCP-enabled Open WebUI profiles. It runs locally on `127.0.0.1:8021` through Open WebUI's standard MCP tool-server mechanism and exposes twelve validated tools for command execution, process control, filesystem operations, search, and file display.

KI-Stack 2.16 adds Local Control on top of that same runtime. It deliberately introduces no second Windows-control runtime, no additional port, and no additional credential. Windows, WSL, process, filesystem, service, registry, task, and application control uses the existing MCP surface, especially `run_command`, PowerShell, and the existing KI-Stack lifecycle scripts.


## Desktop Control and WinApp

WinApp `0.6.1` is the centrally managed Windows UI Automation base. Desktop Control `0.1.0` wraps that base as a controlled semantic UIA layer on top of it.

Every Desktop Control request follows the fixed sequence Resolve -> Validate -> Act -> Re-observe -> Verify. The target is resolved unambiguously before any action (exactly one window, exactly one element); policy, interactability, and secret-context checks run before that. A mutating operation counts as successful only when an independent postcondition is confirmed -- a CLI exit code alone is not sufficient.

Raw keyboard/mouse injection, arbitrary or unencapsulated WinApp execution, and unverified backend capabilities are not released.

The Complete Installer integrates WinApp and Desktop Control into reconciliation and payload parity. It introduces no new service, no new port, no new credential, and no new Windows-control service instance. Desktop Control MCP wiring is intentionally not yet activated in 2.18.

## Native Memory

KI-Stack 2.17 uses Open WebUI's native local Memory implementation instead of introducing a KI-Stack-specific memory service or separate vector/database backend.

Profile policy:

- Memory enabled: `ki-stack-it-technik`, `ki-stack-allgemein`
- Memory disabled: `ki-stack-18bravo`, `ki-stack-research`
- `roleplay`: outside the managed Memory policy

Memory is stored in Open WebUI's `webui.db`, is user-scoped, and can be reused across chats and profiles for the same authenticated user. Chat/request activation still depends on `features.memory=true`; Open WebUI 0.11.3 does not expose a persisted server-side default for that request flag.

2.17 also adds online SQLite database backup using `VACUUM INTO`, mandatory integrity validation, and controlled restore tooling with pre-restore safety backup, WAL/SHM handling, and post-restore health verification. A real online production backup was performed. Restore acceptance was performed against a controlled temporary database copy; no production database restore was performed.


## Open Terminal

Open Terminal `0.1.0` remains a self-contained, fully supported Complete Installer component. Since 2.15 it is no longer the default terminal/host-control integration for production MCP-enabled profiles; MCP Runtime is the primary path.

Open Terminal remains available as an explicit fallback and rollback path at `http://127.0.0.1:8000`. It uses the managed Python/uv runtime, its own persistent DPAPI-protected API key, bounded readiness checks, process-identity verification, and the central KI-Stack Start/Stop/Status lifecycle.

Using this fallback through Open WebUI's legacy OpenAPI tool-server path still requires a separate explicit registration. Normal MCP-based KI-Stack operation does not depend on that registration.

## Transactions and OpenWebUI

Installation and upgrade use component planning, scoped backups, journalled state, real-version readback, resume, recovery, and rollback. A component is recorded as completed only after successful deployment and readback. Rollback affects only the active transaction. A first-time WSL2 activation can require a Windows restart; the installer stops with exit code `31`, which is resumable and does not trigger rollback.

Administrative Open WebUI automation uses the centralized KI-Stack credential bootstrap. `Initialize-KIStackOpenWebUICredential.ps1` performs the one-time administrator sign-in, enables API-key support where required, mints and validates a persistent per-user API key, and stores it only DPAPI-encrypted under the KI-Stack state directory. Subsequent installer, Agent Pack, RAG, Knowledge, and Code Interpreter operations resolve that same credential without extracting secrets from Open WebUI's database and without persisting plaintext credentials.

A valid stored credential is reused automatically. Rotation validates the replacement before superseding the previous working credential; revoke removes only the KI-Stack-owned credential. If no usable credential exists, API-dependent work is reported as controlled Pending/Blocked rather than proceeding unauthenticated.

MP4 output remains exactly one persistent file attachment through the native `files` event and `/api/v1/files/{id}/content`.


## Validation scope

Validation evidence is intentionally scoped by what was actually exercised:

- **2.4.0**: last complete, physical Greenfield installation on an empty Windows target, including WSL2/Debian foundation setup, ComfyUI, LM Studio with managed local-server startup, SearXNG, Codex Local, and RAG.
- **2.10.0**: documented whole-stack regression plus real-target run on an existing system. The Complete Installer/Cutover Runtime transaction completed successfully, supported ComfyUI and Open WebUI installations were preserved, and LM Studio remained reachable after the transaction. See `docs/releases/complete-installer-v2.10.0.md`.
- **2.13.0**: deterministic source/package validation plus additional real-target proofs: OpenWebUI credential bootstrap, Codex Local `0.2.1` with isolated `CODEX_HOME` and a real login -> starter -> `codex exec` flow, and a real SearXNG-backed web-search tool-calling proof for `ki-stack-research`.
- **2.14.0**: real Complete Installer execution against an existing target with Open Terminal installed for real, visible elevated-run heartbeat, and a subsequent `SkippedAlreadyCompliant` result; deterministic build and PackageSelfTest were also confirmed.
- **2.15.0**: MCP Foundation validated on the real target, including production-profile MCP bindings, real MCP tool calls, rollback/fallback behavior, credential synchronization, and corrected Cutover Runtime compliance detection.
- **2.16.0**: real-target Local Control validation using the existing MCP Runtime, including filesystem, process, working-directory, Windows-query, application-control, and Ballistics MCP-binding preservation behavior.
- **2.17.0**: real native Memory add/search/delete acceptance, Agent Pack Memory/profile policy validation, real online `webui.db` backup while Open WebUI remained healthy, and controlled restore acceptance against a temporary database copy. Repository regression was 34/34 PASS.
- **2.18.0**: real Desktop Control end-to-end validation for `list_windows`, `inspect_window`, `find_element`, `get_properties`, `get_value`, `wait_for`, `set_value` (including an independent readback), `invoke` (including a fresh tree re-observation), and `focus` (including a focus readback), plus reconcile, repair, idempotency, and payload-parity evidence. No broad MCP integration claim.

These scopes are cumulative evidence, not interchangeable claims. In particular, no release after 2.4.0 has claimed or performed a new complete empty-target Windows Greenfield acceptance, and no production `webui.db` restore was performed in 2.17.

## Known open items

- **Latency tracing**: there is still no dedicated end-to-end timing breakdown for Open WebUI input -> prompt/tool assembly -> LM Studio request -> first token. The LM Studio runtime-baseline check added in 2.15 is not a replacement for full tracing.
- **Memory request default**: Open WebUI 0.11.3 has no persisted server-side default for `features.memory=true`.
- **Production database restore**: online `webui.db` backup is real-target validated and controlled restore is acceptance-tested, but no production database restore has been performed.
- **Desktop Control MCP wiring**: Desktop Control MCP wiring is not yet activated; UIA capabilities that are not released, or not yet production-validated, remain outside the contract.
- **Bootstrap phase without PowerShell 7**: `Bootstrap-KIStackPowerShell7.ps1`, used only when PowerShell 7 itself is absent, still has no live heartbeat display of its own and writes its structured `.bootstrap.jsonl` diagnostic log instead.

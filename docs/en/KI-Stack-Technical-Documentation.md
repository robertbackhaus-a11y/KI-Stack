# KI-Stack 2.15.0 technical documentation

KI-Stack is a transactional Windows local-AI stack. Complete Installer `2.15.0` is the current repository/development state (not yet published as a GitHub Release); `2.14.0` is the latest actually published GitHub Release. Complete Installer 2.10.0 remains the last state that was both regression- and real-target-validated end to end as a whole (see `docs/releases/complete-installer-v2.10.0.md`), and the last complete, physical Greenfield installation on an empty target was performed and verified in an earlier cycle (2.4.0). 2.13.0 itself adds several real, new real-target proofs over 2.12.0, though: a real Codex Local login-to-upgrade-to-starter-to-`codex exec` end-to-end run, a real OpenWebUI credential bootstrap validation (admin login, API key, DPAPI store), and a real web-search proof for `ki-stack-research` -- not a full Windows Greenfield proof (deliberately deferred to a future release), but substantially more real target coverage than 2.12.0. Since then, on the same still-unpublished development line, Open Terminal `0.1.0` was integrated as a real, target-validated Complete Installer component (see "Open Terminal" below), and the installer's live heartbeat, transcript live-view filtering, single final result summary, and `centralStarters` transaction-schema stability were all fixed and real-target verified. See "Validation scope" below.

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
| Open Terminal | 0.1.0 |
| Production Recovery | 1.7.0-r7 |
| Validation Gate | 1.0.3 |
| Target Acceptance | 1.0.10 |
| OpenWebUI Visual Pack | 2.0.5 |
| OpenWebUI Agent Pack | 1.9.0 |
| Complete Installer | 2.15.0 |

ComfyUI's reference and minimum supported version for reproducible Greenfield installs and reconciliation is `v0.34.0`; an existing, supported newer installation is preserved and never auto-downgraded. Open WebUI's `ReferenceVersion` and `MinimumSupportedVersion` are both `0.11.3` -- any installed version from `0.11.3` up is supported, and an existing, supported newer installation is preserved the same way, never auto-downgraded to the exact reference.

OpenWebUI Agent Pack `1.9.0` adds a third managed profile, `ki-stack-research`: a reference research agent combining a dynamically-bound local RAG Knowledge collection with web search and an isolated Pyodide code interpreter, no Extension Tools, and `terminal` plus every unused native capability explicitly denied -- no shell, host filesystem, or administrative OpenWebUI access exists for any managed profile. Reconcile on an already-managed profile now merges rather than replaces `meta`, so live/UI-added values on `capabilities`, `builtinTools`, `access_grants`, or `profile_image_url` survive a reconcile. RAG `0.4.0` adds project-scoped Knowledge collections alongside the existing global scope, each isolated to its own OpenWebUI Knowledge collection.

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

## Open Terminal

Open Terminal `0.1.0` is a self-contained ("isolation A") Complete Installer component, installed/upgraded/repaired/skipped the same way as Codex Local: its own `Invoke-KIStackOpenTerminal.ps1` entry point, own backup/rollback, own version probe (`modules/open-terminal/installation.json`). It runs `uvx open-terminal run --host 127.0.0.1 --port 8000 --cwd <managed-workspace>` (uv's own `tool run` shorthand), resolved deterministically under `C:\KI-Stack\python` -- the managed console script if present, otherwise `python.exe -m uv`, and only as a last resort a bare `uv`/`uv.exe` on `PATH` -- never assuming an unmanaged `uvx` is simply there. Process identity is verified by PID plus a live `Win32_Process` command-line match (never a bare PID lookup, since PIDs are reused by the OS) before Stop ever terminates anything, so it can never affect an unrelated process. Authentication is a single 256-bit random API key, generated once and stored DPAPI-encrypted (`ConvertFrom-SecureString`, current-user scope) under `C:\KI-Stack\state\open-terminal\credential.json` -- resolved back into the child process's own environment only at start time, never written to a file, script, or log in plaintext. Readiness is a bounded wait against `http://127.0.0.1:8000/openapi.json`, never an unbounded loop. Start/Stop/Status are additionally chained onto the Complete Installer's own root `Start-KIStack.cmd`/`Stop-KIStack.cmd`/`Get-KIStackStatus.ps1`, so it starts, stops, and reports alongside every other managed component without a separate workflow. OpenWebUI remains the sole user-facing frontend; connecting OpenWebUI to it still requires one manual, one-time OpenAPI tool-server registration (see the operations guide).

## Transactions and OpenWebUI

Installation and upgrade use component planning, scoped backups, journalled state, real-version readback, resume, recovery, and rollback. A component is recorded as completed only after successful deployment and readback. Rollback affects only the active transaction. A first-time WSL2 activation can require a Windows restart; the installer stops with exit code `31`, which is resumable and does not trigger rollback.

OpenWebUI Visual and Agent administration may request a temporary administrator API key as a hidden `SecureString`. It is used only in memory, is not written to reports, state, command lines, or environment files, and should be revoked afterwards. Without that key, the temporary Knowledge bootstrap-experiment rollback and the Code Interpreter connection configuration are left as manual follow-up (`CredentialRequiredForApiReadback` / `CredentialRequiredForApiConfiguration`).

MP4 output remains exactly one persistent file attachment through the native `files` event and `/api/v1/files/{id}/content`.

## Validation scope

The 2.10.0 release was regression-tested and then validated on a real, existing (non-Greenfield) target: the Complete Installer/Cutover Runtime transaction completed successfully, ComfyUI's existing, supported `v0.34.0` installation was preserved instead of being reset to the `v0.28.0` reference, Open WebUI's existing `0.11.1` installation was preserved the same way, and LM Studio's local API server remained reachable at `http://127.0.0.1:1234/v1/models` with the competing Windows autostart entry absent after the run. See `docs/releases/complete-installer-v2.10.0.md` for the full real-target record. The last complete, physical Greenfield installation on an empty target -- WSL2/Debian foundation setup, ComfyUI, LM Studio with automatic local-server startup, SearXNG service adoption, Codex Local, and RAG -- was performed and verified in an earlier cycle (2.4.0); no functional change since then invalidates that installation path.

Most recently, a real Complete Installer run against an existing, already-provisioned target completed with overall status `Completed` and exit code `0`, with the live heartbeat visible throughout: Open Terminal was installed for real, and a subsequent run against the same target correctly reported it `SkippedAlreadyCompliant`.

## Known open items

- **Latency analysis**: no technical breakdown yet of the real request path OpenWebUI input -> prompt/tool assembly -> LM Studio request -> first token.
- **Automatic OpenWebUI tool-server registration**: Open Terminal still requires a one-time manual registration under OpenWebUI's own Admin Settings -> Tools; this is not yet automated.
- **Bootstrap phase without PowerShell 7**: `Bootstrap-KIStackPowerShell7.ps1` (used only when PowerShell 7 itself is missing) has no live heartbeat display of its own -- it only writes a structured `.bootstrap.jsonl` diagnostic log. A known, accepted gap, not a 2.14 blocker.

2.13.0's validation combines a source-only build (deterministic dual-build, byte-identical ZIP/sidecar/SBOM-root SHA256, SPDX 2.3, a freshly-extracted PackageSelfTest) with several real real-target runs that 2.12.0 did not yet have: (1) a real OpenWebUI credential bootstrap (one-time admin login, a real API key, a DPAPI store, real status validation); (2) a real Codex Local `0.2.1` upgrade with an isolated `CODEX_HOME` and a real login-to-starter-to-`codex exec` end-to-end run; (3) a real web-search proof for `ki-stack-research` (the model correctly requests `search_web`/`fetch_url`, real SearXNG sources, a real final answer) -- with a precisely documented boundary at OpenWebUI's own automatic background execution for non-browser callers, not an Agent Pack or model defect. No credential is ever extracted from a database or stored in this repository. A full fresh Windows Greenfield proof remains deliberately deferred to a future release.

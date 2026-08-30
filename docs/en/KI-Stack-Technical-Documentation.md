# KI-Stack 2.12.0 technical documentation

KI-Stack is a transactional Windows local-AI stack. Complete Installer `2.12.0` is the current repository/development state (not yet published as a GitHub Release); Complete Installer 2.10.0 remains the last state that was both regression- and real-target-validated end to end (see `docs/releases/complete-installer-v2.10.0.md`), and the last complete, physical Greenfield installation on an empty target was performed and verified in an earlier cycle (2.4.0). 2.12.0's own validation is source-only plus mocked-HTTP regression coverage and a deterministic dual-build/PackageSelfTest proof -- see "Validation scope" below.

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
| Codex Local | 0.1.4 |
| RAG | 0.4.0 |
| Production Recovery | 1.7.0-r7 |
| Validation Gate | 1.0.3 |
| Target Acceptance | 1.0.10 |
| OpenWebUI Visual Pack | 2.0.5 |
| OpenWebUI Agent Pack | 1.9.0 |
| Complete Installer | 2.12.0 |

ComfyUI's reference version for reproducible Greenfield installs is `v0.28.0`; an existing, supported newer installation (e.g. `v0.34.0`) is preserved and never auto-downgraded. Open WebUI's `ReferenceVersion` is `0.11.1` and `MinimumSupportedVersion` is `0.11.0` -- any installed version from `0.11.0` up is supported, and an existing, supported newer installation is preserved the same way, never auto-downgraded to the exact reference.

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

## Transactions and OpenWebUI

Installation and upgrade use component planning, scoped backups, journalled state, real-version readback, resume, recovery, and rollback. A component is recorded as completed only after successful deployment and readback. Rollback affects only the active transaction. A first-time WSL2 activation can require a Windows restart; the installer stops with exit code `31`, which is resumable and does not trigger rollback.

OpenWebUI Visual and Agent administration may request a temporary administrator API key as a hidden `SecureString`. It is used only in memory, is not written to reports, state, command lines, or environment files, and should be revoked afterwards. Without that key, the temporary Knowledge bootstrap-experiment rollback and the Code Interpreter connection configuration are left as manual follow-up (`CredentialRequiredForApiReadback` / `CredentialRequiredForApiConfiguration`).

MP4 output remains exactly one persistent file attachment through the native `files` event and `/api/v1/files/{id}/content`.

## Validation scope

The 2.10.0 release was regression-tested and then validated on a real, existing (non-Greenfield) target: the Complete Installer/Cutover Runtime transaction completed successfully, ComfyUI's existing, supported `v0.34.0` installation was preserved instead of being reset to the `v0.28.0` reference, Open WebUI's existing `0.11.1` installation was preserved the same way, and LM Studio's local API server remained reachable at `http://127.0.0.1:1234/v1/models` with the competing Windows autostart entry absent after the run. See `docs/releases/complete-installer-v2.10.0.md` for the full real-target record. The last complete, physical Greenfield installation on an empty target -- WSL2/Debian foundation setup, ComfyUI, LM Studio with automatic local-server startup, SearXNG service adoption, Codex Local, and RAG -- was performed and verified in an earlier cycle (2.4.0); no functional change since then invalidates that installation path.

2.12.0's own validation is a source-only build: deterministic dual-build (byte-identical ZIP/sidecar/SBOM-root SHA256, SPDX 2.3) and a freshly-extracted PackageSelfTest (28/28), plus mocked-HTTP regression suites for the new/changed contracts (`ki-stack-research` provisioning and knowledge binding, the Agent-Pack reconcile field-ownership/preserve contract with a negative control, RAG project-scope separation, the Integration RAG-starter-preservation fix). No new real-target run was performed for 2.12.0; a real, authenticated multi-step chat end-to-end proof for `ki-stack-research` specifically requires an externally-supplied OpenWebUI administrator API key -- a known automation/bootstrap boundary, not a defect (no credential is ever extracted from the database or stored in this repository).

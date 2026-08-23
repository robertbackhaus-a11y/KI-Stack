# KI-Stack 2.4.0 technical documentation

KI-Stack is a transactional Windows local-AI stack. Complete Installer 2.4.0 has been verified with a complete, successful, physical Greenfield installation on an empty target.

## Active components

| Component | Version |
|---|---:|
| Foundation / Runtime | 1.0.9 |
| Python / Git | 1.1.5 |
| ComfyUI | 1.2.4 |
| Models / Workflows | 2.0.3 |
| Applications | 1.4.11 |
| Integration | 1.5.11 |
| Cutover Runtime | 1.6.10 |
| Codex Local | 0.1.3 |
| RAG | 0.2.0 |
| Production Recovery | 1.7.0-r7 |
| Validation Gate | 1.0.3 |
| Target Acceptance | 1.0.10 |
| OpenWebUI Visual Pack | 2.0.5 |
| OpenWebUI Agent Pack | 1.8.9 |
| Complete Installer | 2.4.0 |

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

The 2.4.0 release has been verified with a complete, successful, physical Greenfield installation on an empty target: every transaction step completed and the installer exited with code 0, including WSL2/Debian foundation setup, ComfyUI, LM Studio with automatic local-server startup, SearXNG service adoption, Codex Local, and RAG.

# KI-Stack Technical Documentation

**[Start here: installation guide](KI-Stack-Installation-Guide.md)**

## 1. Purpose and architecture

KI-Stack is a Windows-first, transactional local-AI stack. The repository provides reproducible source packages; release ZIPs are GitHub Release assets and are not committed. Runtime package acquisition is Git-free. Each managed change is planned, journalled and can be resumed or rolled back.

The supported topology is Windows for user entry points, LM Studio, ComfyUI and desktop shortcuts; WSL2/Debian for SearXNG and its `valkey-server`, `uwsgi` and `nginx` service chain. OpenWebUI runs locally and connects the profiles, tools, code capability, web search and image output.

## 2. Component matrix

| Component | Version / status | Release or contract | SHA256 / integrity record |
|---|---|---|---|
| Cutover runtime | 1.6.3, accepted baseline | `cutover-v1.6.3-rc1` | core `e387199493575131045c888ebbd4c1313bb985b13e3a1f72c3f99efe9bf2b85d` |
| ComfyUI | 1.2.2, target-system validated | embedded Complete payload | `tools/complete-installer/current/Contracts/PAYLOADS.json` |
| Models / Workflows | 1.4.5, documentation patch | `models-workflows-v1.4.5` | package `SHA256SUMS.txt`; models are external |
| Applications | 1.4.10, accepted | Cutover payload | package manifest contract |
| Integration / SearXNG | 1.5.9, target-system validated | embedded Complete payload | payload contract |
| Production Recovery | 1.7.0-r7, target-system accepted | `production-v1.7.0-r7` | `0b4b28c886f01939fb45a9d7f3ce9f5323f57a8208e42381088544afa5955c59` |
| Validation Gate | 1.0.2, active | production release | `a03dd59df2322bc37b763d8d16ff6127f04b969069a698b361e6c52099a7db81` |
| Target Acceptance | 1.0.10, passed | production release | `bbfe6e79438406fecbc301f8883a7b629ca0c1ff5736917c267c02ec79fce0d6` |
| OpenWebUI Agent Pack | 1.8.3, target validated | dedicated release | pack `SHA256SUMS.txt` |
| OpenWebUI Image Pack | 1.9.1, target validated | dedicated release | pack `SHA256SUMS.txt` |
| OpenWebUI Ballistics Pack | 1.0.0, target validated | dedicated release | pack `SHA256SUMS.txt` |
| Complete Installer | 2.2.5, documentation patch | `complete-v2.2.5` | package `SHA256SUMS.txt` |

`production-release-manifest.json`, each package `MANIFEST.json`, `SHA256SUMS.txt` and release sidecar are the authoritative integrity records. The target acceptance result is `TARGET_SYSTEM_ACCEPTANCE_PASSED`.

## 3. Directories and managed data

`package/` contains the runtime package source, modules, model and workflow manifests, public import entry points and the canonical workflows. `tools/complete-installer/current/` contains the complete orchestration source and embedded-payload contract. `tools/` holds reproducible Recovery, Validation Gate and Acceptance sources. `docs/` holds operational and release documentation. `_import/` is private, excluded from Git and never a release input.

Managed content includes package files, component markers, transaction state, configured workflow copies and known KI-Stack service configuration. User-owned models, workflows, chats, prompts, uploaded files, browser data, model caches, virtual environments and unrelated Git worktrees are not deletion targets. Models remain outside Git and release ZIPs.

## 4. Services, ports and health

LM Studio supplies its local OpenAI-compatible endpoint and `/v1/models`. OpenWebUI provides the local chat UI. SearXNG is checked by HTML and JSON search. ComfyUI is checked through its health/API endpoint. The status core reports each as Running, Stopped or Error, together with WSL keeper and Debian `valkey-server`, `uwsgi` and `nginx`. Local port assignments are read from the deployed configuration rather than assumed from documentation; status checks never start a component.

## 5. OpenWebUI profiles and integrations

`Allgemein` and `KI & IT-Technik` use native function calling, have `knowledge=[]`, use the built-in browser-local Pyodide Code Interpreter, and bind only `ki_stack_generate_image`. `18Bravo` has `knowledge=[]`, disables Code Interpreter and binds only `ki_stack_ballistics_calculator`. `execute_code` is a built-in capability, not a workspace tool ID.

The image tool sends the approved FLUX2 API workflow to ComfyUI and registers the produced image through OpenWebUI's file store. The chat retains an embedded image and a downloadable attachment after reload; it does not expose `/mnt/uploads`, Windows paths or ComfyUI paths. The ballistics tool remains restricted to lawful sporting, hunting and engineering calculations.

## 6. Workflows and model contracts

The required FLUX2 profile uses `flux-2-klein-9b-fp8.safetensors`, `qwen_3_8b_fp8mixed.safetensors` and `flux2-vae.safetensors`. Canonical workflows are the FLUX2 UI and API workflows, KREA Realism, Pony SDXL and WAN 2.2 Official. KREA requires four external files, Pony requires its fixed Civitai model-version-290640 contract, and WAN requires three external files. The full external-model contract totals 47,356,936,991 bytes and records filename, relative target, byte size, SHA256, license and acquisition mode in `package/Manifests/models.manifest.json`.

The central importer verifies target and source by filename, size and SHA256, uses a `.partial` copy followed by an atomic move, records a resumable transaction and rolls back only files from that transaction. Seven models require manual external provision; their `informationSource` identifies the publisher page only and is never an installable payload URL. Their trust anchors are publisher, exact filename, size and SHA256; mutable `resolve/main` URLs are not trusted by the importer. Pony is the sole automatic external acquisition through fixed Civitai model version 290640, followed by size and SHA256 verification. Git, commit-hash and `latest` acquisition are not used. The package is therefore not offline.

## 7. Transaction and lifecycle architecture

Install, upgrade, repair and import use explicit planning, backups, journal entries, scoped rollback and resume state. Already compliant content is retained. A missing manual model returns `WaitingForUserAction`, including its exact filename, size, SHA256 and source folder; it never writes a Completed or AlreadyCompliant marker.

All CMD starters resolve PowerShell 7 from `%ProgramFiles%\\PowerShell\\7\\pwsh.exe` first, then `where pwsh.exe`, and stop with exit code 70 if unavailable. Windows PowerShell is not a fallback. Start, Stop and read-only Status have separate entry points. Only the interactive desktop Status wrapper waits for a key; the status core and validation starter are pause-free. No KI-Stack Windows autostart, scheduled boot/logon task, Run/RunOnce entry or automatic Debian service enablement is required. Debian services remain manually startable.

## 8. Security, dependencies and limitations

API keys are requested interactively as `SecureString`, used only in memory and must be revoked in OpenWebUI after use. They are not command-line arguments, environment files, Git content or reports. No raw target report, personal path, test image, model binary, backup or private import data is publishable.

The Complete Installer is Git-free at runtime but not fully offline because model files are external and license-gated or manually provided. Fresh-install behavior is contract and fixture validated; physical target validation is for the existing installation. Production Recovery r7 and Target Acceptance 1.0.10 are pinned external references, not automatically overlaid.

## 9. Maintenance and release procedure

Change only the affected source and contract. Update version, manifests, reports, `SHA256SUMS.txt`, documentation and release notes together. Validate links and documentation parity, run the repository validator and `git diff --check`, build each affected package once, verify ZIP and sidecar SHA256, commit deliberately, push, publish the established asset count and verify the uploaded assets once. Do not place ZIPs or `_import/` content in Git.

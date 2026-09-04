# Architecture

## Design goals

KI-Stack is a modular Windows local-AI deployment framework. The Complete Installer discovers enabled components, plans a transaction, executes components against scoped backups, and rolls back on a terminating failure. Every component is independently installable, upgradable, repairable, and skippable; a component recorded as completed only after successful deployment and real-version readback.

## Layers and components

| Layer | Components |
|---|---|
| Frontend | OpenWebUI `0.11.3` -- the sole primary, user-facing frontend for the whole stack |
| LLM runtime | LM Studio, installed locally with a managed local API endpoint (`http://127.0.0.1:1234/v1`); local models only, no cloud dependency for normal stack operation |
| Visual | ComfyUI `v0.34.0`; Z-Image and Chroma1 image models; WAN video; OpenWebUI Visual Pack |
| RAG | Own RAG module, integrated into OpenWebUI's Knowledge feature; `nomic-embed-text-v1.5` embeddings; ChromaDB as the vector store; `search_document`/`search_query` embedding tasks; `source_file`/`chunk_index` chunk metadata |
| Agent / Tools | OpenWebUI Agent Pack; Codex Local; Open Terminal `0.1.0` -- a local tool/execution backend at `http://127.0.0.1:8000` (filesystem, PowerShell, WSL, Git, process execution) authenticated with a single persistent, DPAPI-protected local API key. OpenWebUI remains the interface; Open Terminal has no primary UI of its own |
| Integration | SearXNG, nginx, Valkey; WSL2/Debian where a component needs a Linux-side service |
| Lifecycle | Central `Start-KIStack.cmd`/`Stop-KIStack.cmd`/`Status-KIStack.cmd` cover every component, Open Terminal included; the Complete Installer manages Install/Upgrade/Repair/Skip per component; no Docker anywhere in the stack |
| Installer / Operations | Transactional Complete Installer: component/payload contracts, scoped backup and rollback, SHA-256/SBOM verification with a deterministic dual-build, a live heartbeat during elevated/UAC-confirmed runs, and a schema-stable `centralStarters` transaction contract |

See the [technical documentation](en/KI-Stack-Technical-Documentation.md) (German: [docs/de](de/KI-Stack-Technische-Dokumentation.md)) for the full, versioned component list and exact version pins, and the [operations guide](en/KI-Stack-Operations-and-User-Guide.md) for day-to-day usage of each lifecycle command.

## Cutover Runtime kernel module order

The Cutover Runtime component carries its own, narrower internal module kernel (distinct from the Complete Installer's component list above), fixed by `executeRelease.enabledModules` in its `kernel-config.json`:

1. Foundation
2. Runtime
3. PythonGit
4. ComfyUI
5. Applications
6. Integration
7. Cutover
99. Validation

Only modules listed in `executeRelease.enabledModules` execute; other module folders can be present as future building blocks without being part of a release.

## Package lifecycle

1. CMD bootstrap resolves PowerShell (falling back to a PowerShell-7 bootstrap path when PowerShell 7 itself is missing) and preserves diagnostics.
2. The starter validates package files and locates the newest supported preflight ZIP.
3. A self-test checks syntax, configuration, and known historical regressions.
4. A dry run produces a plan without mutating the target system; execute requires explicit confirmation and administrator rights.
5. The transaction is journalled to persistent state as each component runs, with a live heartbeat visible throughout.
6. A terminating failure triggers rollback using component state and the persistent journal; a resumable pause (for example, WSL2 requiring a Windows restart) stops with a specific exit code and a transaction ID to resume with instead of rolling back.

## Known open architecture items

- **Automatic OpenWebUI tool-server registration**: Open Terminal still requires a one-time manual registration under OpenWebUI's own Admin Settings -> Tools; wiring this up automatically is not yet designed.
- **Latency tracing**: no architectural trace yet of the real request path OpenWebUI input -> prompt/tool assembly -> LM Studio request -> first token; planned for after 2.14.

# KI-Stack Complete Installer 2.2.7

Version 2.2.7 preserves the target-validated operations and OpenWebUI/ComfyUI integration contracts and updates Models / Workflows to 1.4.7. Its public model-import starter delegates to the single transactional importer in the Models / Workflows payload, including the manual Heretic LM Studio contract.

## Documentation

**[Start here: installation guide](../../../docs/en/KI-Stack-Installation-Guide.md)**, **[Hier beginnen: Installationsanleitung](../../../docs/de/KI-Stack-Installationsanleitung.md)**, **[manual model provisioning](../../../docs/en/KI-Stack-Manual-Model-Provisioning.md)** and **[manuelle Modellbereitstellung](../../../docs/de/KI-Stack-Manuelle-Modellbereitstellung.md)** are the primary user paths. They define the same package, model, lifecycle, profile and safety contracts; no model file is embedded.

The existing-installation operations contract, Image Pack 1.9.2 chat attachment path and all five canonical workflows are target-system validated. Fresh-install behavior remains contract- and fixture-validated rather than physically bare-metal validated.

The former OpenWebUI knowledge-base experiment is not a KI-Stack dependency. The idempotent operations rollback inventories only clearly KI-Stack-named collections, writes a private metadata-only rollback record, enforces `knowledge=[]` on `ki-stack-allgemein`, `ki-stack-it-technik` and `ki-stack-18bravo`, and removes only the matched collection/file objects through OpenWebUI's supported API. It does not include or delete original Markdown sources, chats, prompts, tools, models or user-owned content.

Status: `TargetSystemValidatedExistingInstallation`. Fresh-install behavior is contract- and fixture-tested; physical validation is limited to an existing installation. ComfyUI 1.2.2 and Integration 1.5.9 use immutable file/size/SHA256 payload contracts without Git at package runtime.

The root starters provide audit, install/upgrade, repair, validation, rollback, start and stop without requiring users to browse subdirectories. One orchestration core creates resumable component transactions and preserves already compliant components. Production Recovery 1.7.0-r7 is an explicit repair and fallback source, never an automatic overlay over newer Agent Pack 1.8.3 or Image Pack 1.9.2 content.

`Validate-KIStack.cmd` and `Lifecycle/Get-KIStackStatus.ps1` are read-only and pause-free for automation. The desktop shortcut `KI-Stack Status` launches `Lifecycle/Show-KIStackStatus.ps1` directly with PowerShell 7; only this interactive wrapper displays the actual exit code and waits for a key. Its compact status covers LM Studio, `/v1/models`, OpenWebUI, SearXNG HTML and JSON search, ComfyUI, the WSL keeper, valkey-server, uwsgi and nginx.

All CMD entry points resolve PowerShell 7 from `%ProgramFiles%\PowerShell\7\pwsh.exe` first and then through `where pwsh.exe`. They abort with exit code 70 when PowerShell 7 is unavailable; Windows PowerShell is never a fallback. API keys remain interactive `SecureString` values and are never command-line arguments.

The package has no Git dependency for acquiring package payloads and contains no `.git` directory. Its embedded Cutover 1.6.3 core omits the superseded ComfyUI, Integration, Linux acquisition and historical test paths; ComfyUI 1.2.2 and Integration 1.5.9 exclusively replace them with verified payload archives. Production Recovery r7 and Target Acceptance 1.0.10 remain pinned external release references because their historical archives intentionally retain the accepted older runtime core. The package is not offline. Model files are never embedded: existing files are accepted only when size and SHA256 match. Pony V6 XL may be acquired automatically through fixed Civitai model version 290640; the seven manual external contracts contain only a publisher and an informational HTTPS page, never an installable payload URL. The importer never downloads those seven files. The eight KREA, Pony and WAN model contracts total 47,356,936,991 bytes. Their license and redistribution restrictions remain applicable; the Complete Installer does not redistribute them.

OpenWebUI 0.10.2 may require initial administrator setup in the browser. The transaction then enters `WaitingForUserAction`. A temporary API key is requested as a hidden `SecureString` immediately before Agent/Image reconciliation, used only in memory for both steps, cleared afterward, and must then be revoked.

No physically tested bare-metal fresh-install claim is made.

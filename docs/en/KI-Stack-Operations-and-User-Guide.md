# KI-Stack Operations and User Guide

## 1. Requirements and installation

Use supported Windows with WSL2/Debian, PowerShell 7, the approved local LM Studio, OpenWebUI and ComfyUI installation, sufficient disk capacity for 47,356,936,991 bytes of external models, and the applicable model licences. Extract the Complete Installer, keep its files together, and use its public starter for installation or upgrade. Do not run package scripts with Windows PowerShell. The package is Git-free at runtime but is not offline.

For an upgrade, stop the stack through the managed Stop shortcut, retain existing compliant files, run the installer, and follow any `WaitingForUserAction` request. Do not overwrite user models, workflows, chats or private data to force compliance.

## 2. External model provision

Put manually supplied model files directly in `ExternalModels` beside the extracted Models / Workflows package, or use another direct folder. Start the central importer with:

```cmd
Start-KIStack-Model-Import.cmd
```

To select another folder, pass all arguments unchanged to the CMD starter:

```cmd
Start-KIStack-Model-Import.cmd -SourcePath "D:\\ExternalModels"
```

The importer checks each existing target and candidate source by exact filename, byte size and SHA256. Correct targets are `AlreadyCompliant`. A verified source is copied as `.partial` and atomically moved. Missing manual models produce `WaitingForUserAction` with the exact required file, size, SHA256 and source folder; after placing the file there, run the same command again to resume. It never searches user directories as its sole source. Pony may use only its fixed Civitai model version 290640; no Git, commit or `latest` source is used.

## 3. Start, stop and status

Use desktop shortcuts `KI-Stack Start`, `KI-Stack Stop` and `KI-Stack Status`. Start launches the managed services; Stop centrally stops them. Status is read-only, needs no administrator elevation and reports LM Studio, `/v1/models`, OpenWebUI, SearXNG HTML/JSON, ComfyUI, WSL keeper, valkey-server, uwsgi and nginx as Running, Stopped or Error. The interactive Status window shows its exit code and remains open until a key is pressed. Status does not repair or start services.

Before a planned reboot, stop centrally. After reboot, confirm no KI-Stack process, listener, automatic service or stale PID exists before using Start. The stack has no required Windows autostart, boot/logon task, Run/RunOnce entry, startup-folder entry, LM Studio autostart, OpenWebUI autostart, ComfyUI autostart or WSL keeper autostart. Debian valkey-server, uwsgi and nginx are disabled for automatic startup but manually startable.

## 4. OpenWebUI

Open the locally configured OpenWebUI address shown by Status. Use `Allgemein` for general local assistance and `KI & IT-Technik` for technical work. Both have native function calling, `knowledge=[]`, only the image tool binding and the browser-local Pyodide Code Interpreter. Use `18Bravo` only for lawful sporting, hunting and engineering ballistics calculations; it has only the ballistics tool, no Code Interpreter and no knowledge binding.

The Code Interpreter is built into OpenWebUI: Pyodide, no Jupyter, Open Terminal, Docker, extra service or browser-restart file persistence. It cannot access Windows, shell or `C:\\KI-Stack`. Do not add `execute_code` as a normal tool ID. Revoke every temporary OpenWebUI API key immediately after administrative or validation work.

Web search uses SearXNG. If it fails, first use Status and inspect the SearXNG HTML and JSON results; do not create a duplicate service. Normal chats function without RAG because all managed profiles use `knowledge=[]`.

## 5. Image and workflow use

The `Allgemein` and `KI & IT-Technik` profiles use the same approved image binding. Generated FLUX2 images appear directly in the chat and retain a clickable download after reload. A valid chat result has no `/mnt/uploads`, Windows path or ComfyUI path.

Open ComfyUI through the locally configured address. Approved workflows are FLUX2 UI, FLUX2 API (used by OpenWebUI), KREA Realism, Pony SDXL and WAN 2.2 Official. Use only the model files named in the workflow and model contracts. The FLUX2 UI defaults to 512×512, batch 1, and its checked-in sampler values. KREA and Pony create images; WAN writes its video output to the workflow-defined video output. Do not install missing custom nodes or substitute unverified models.

## 6. Audit, validate, repair, resume and rollback

Use the public Complete Installer starters for Audit, Validate, Repair, Resume and Rollback. Audit and Validate are read-only. Repair is transactional and must be explicitly selected. Resume continues the recorded transaction after a missing dependency is provided. Rollback restores only backups from that transaction and removes only transaction-created files; it leaves pre-existing compliant models untouched. Read the transaction report before retrying a failed step.

For logs and diagnosis, use the reported transaction directory, package validation report and Status summary. Do not publish logs containing user paths, API keys, raw OpenWebUI exports, test images or backups. Typical safe resolutions are: install PowerShell 7 when a starter returns exit code 70; provide the exact missing model file to `ExternalModels`; use Repair only after reading the failure; use Rollback when a transaction reports an unresolved error; and verify a stopped service through Status before starting it.

## 7. Controlled stop and removal

For normal shutdown, use `KI-Stack Stop` and confirm Status shows no managed listeners or stale PID files. A full removal is a controlled maintenance operation: stop first, preserve user-owned models, workflows, chats, prompts, uploads, browser data and unrelated tools, then remove only explicitly identified KI-Stack managed content and transaction backups after review. Do not delete WSL distributions, user profiles or shared model directories as a generic uninstall action.

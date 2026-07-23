# Quick installation

This guide applies to the published **KI-Stack Complete Installer 2.2.5** package. It describes only files present in the package and flows verified from its sources. The normal functional entry point is `Start-KIStack-Installer.cmd`; the model, audit, validate, repair and rollback starters documented below are specialist paths.

## Step 1 – Download the package

1. Open the [complete-v2.2.5](https://github.com/robertbackhaus-a11y/KI-Stack/releases/tag/complete-v2.2.5) release.
2. Download `KI-Stack-Complete-Installer-v2.2.5.zip` and the `KI-Stack-Complete-Installer-v2.2.5.zip.sha256` sidecar from that same release page.
3. Verify the ZIP in PowerShell 7:

```powershell
Get-FileHash -LiteralPath .\KI-Stack-Complete-Installer-v2.2.5.zip -Algorithm SHA256
```

Expected SHA256 value: `43e24404dec62403588b057415bb30a609bf734bc3cbb3aee80ff05c1d7d057e`.

**Expected result:** The displayed `Hash` exactly matches this value and the sidecar file content. **Next step:** Extract only when it matches.

## Step 2 – Extract the package

Extract the ZIP to a short writable folder and open the top-level extracted package folder. It demonstrably contains:

```text
KI-Stack-Complete-Installer-v2.2.5/
├── Start-KIStack-Installer.cmd
├── Start-KIStack-Audit.cmd
├── Start-KIStack-Model-Import.cmd
├── Start-KIStack-Validate.cmd
├── Start-KIStack-Repair.cmd
├── Start-KIStack-Rollback.cmd
├── Start-KIStack.cmd
├── Stop-KIStack.cmd
├── ExternalModels/
└── README.md
```

The actual interactive status starter is `Lifecycle\Status-KIStack-Interactive.cmd`; there is no root `Start-KIStack-Status.cmd`. `README.de.md` is **not present** in the published ZIP. This is a documented package defect against the expected bilingual root layout; do not search subdirectories for a replacement.

**Expected result:** Every actual file listed above is visible. **Next step:** Provide models in `ExternalModels`.

## Step 3 – Provide models

Place files directly in `ExternalModels`; subdirectories are neither required nor accepted because the importer checks only `<SourcePath>\<fileName>`. The seven manual files are:

| Manual file | Target area |
|---|---|
| `flux1-krea-dev_fp8_scaled.safetensors` | `models\diffusion_models` |
| `clip_l.safetensors` | `models\text_encoders` |
| `t5xxl_fp16.safetensors` | `models\text_encoders` |
| `ae.safetensors` | `models\vae` |
| `umt5_xxl_fp8_e4m3fn_scaled.safetensors` | `models\text_encoders` |
| `wan2.2_ti2v_5B_fp16.safetensors` | `models\diffusion_models` |
| `wan2.2_vae.safetensors` | `models\vae` |

`ponyDiffusionV6XL_v6StartWithThisOne.safetensors` is the only automatically obtainable model; its contract uses only fixed Civitai model version `290640`. The seven manual contracts identify a publisher and informational HTTPS page only; those pages are not installable payload sources and the importer never downloads from them. All eight contracts verify file name, byte size and SHA256. The exact values are in `Payload\ModelsWorkflows\...\Manifests\models.manifest.json` or the package contract; use no other file or source.

Run the central import before installation:

```cmd
Start-KIStack-Model-Import.cmd
```

Another direct handoff folder is demonstrably supported:

```cmd
Start-KIStack-Model-Import.cmd -SourcePath "D:\KI-Modelle"
```

`Start-KIStack-Installer.cmd` does not itself launch the public model importer. Therefore run this import first whenever models are absent or newly supplied. `AlreadyCompliant` means every checked target model already matches exactly. `WaitingForUserAction` names the file, expected byte size, SHA256 and source folder; place the file there directly and continue with the emitted resume instruction. An existing file with incorrect size or SHA256 remains invalid and is not imported.

**Expected result:** `Completed` or `AlreadyCompliant`; `WaitingForUserAction` when manual files are missing. **Next step:** Start the installer after success; provide the missing file when waiting.

## Step 4 – Start installation

1. Open the top-level package folder in Explorer.
2. Use `Start-KIStack-Installer.cmd`.
3. Do not start individual module scripts manually.

The starter demonstrably calls `Invoke-KIStackCompleteInstaller.ps1 -Mode Upgrade`. It plans components and checks PowerShell 7, package payloads, administrator status, ports and existing-component compliance. Managed components include Cutover Runtime, ComfyUI, Models/Workflows, Integration, OpenWebUI Agent/Image and optional Ballistics; already compliant content is skipped.

`Start-KIStack-Installer.cmd` starts the provided PowerShell 7 entry point. That entry point requests UAC exactly once when needed, prevents an elevation loop and propagates the exit code. Confirm the UAC prompt.

Required user input can include initial OpenWebUI sign-in or a temporary administrator API key. The key must be entered only hidden as a `SecureString`, never stored in files or command lines, and then revoked in OpenWebUI. A successful flow returns `Completed`; `SkippedAlreadyCompliant` means every component was already compliant. Transaction files are under `C:\KI-Stack\state\complete-installer\<TransactionId>\`; backups are under `C:\KI-Stack\backups\complete-installer\<TransactionId>\`.

**Next step on error:** Read the transaction file first, then use Resume, Validate, Repair or Rollback only as described below.

## Step 5 – Interruption and resume

`Resume-KIStack-Installer.cmd` is the public Resume starter. Without an argument it clearly asks for the TransactionId; alternatively use this complete invocation:

```powershell
& .\Invoke-KIStackCompleteInstaller.ps1 -Mode Upgrade -TransactionId "<TransactionId>" -Resume
```

`<TransactionId>` is in `C:\KI-Stack\state\complete-installer\<TransactionId>\transaction.json`; the matching resume file is `resume.json` in the same folder. The resume code reads `transaction.json`, skips `Completed` and `SkippedAlreadyCompliant`, and continues at the first open step. For model import, the importer emits this form:

```powershell
.\Import-KIStackExternalModels.ps1 -SourcePath "<SourcePath>" -TransactionId "<TransactionId>" -Resume
```

For `WaitingForUserAction`, first sign in to OpenWebUI or provide the required model source. When Agent or Image must change, the already elevated process asks exactly once for the temporary API key as a hidden `SecureString` and uses it only in memory for both steps. If both are already compliant, no prompt occurs. Revoke every temporary key in OpenWebUI after permitted use.

**Expected result:** Completed steps remain skipped and the next open step continues. **Next step:** Validate after completion.

## Step 6 – Validate installation

Start `Start-KIStack-Validate.cmd` by double-click or from a PowerShell 7 console in the package folder:

```powershell
& .\Start-KIStack-Validate.cmd
```

The starter calls `-Mode Validate`. It read-only checks configured health endpoints for LM Studio (`/v1/models`), ComfyUI, OpenWebUI, SearXNG HTML and SearXNG JSON search, plus operations. A successful JSON status contains `health` and `operations` without errors. An error status does not repair automatically: inspect Status and the transaction first.

According to the current code, the Validate starter writes no dedicated report path; its output is sent to the console. Installer transactions and logs are under `C:\KI-Stack\state\complete-installer` and `C:\KI-Stack\logs\complete-installer`.

**Next step:** Start the stack, or select Audit/Repair/Rollback on errors.

## Step 7 – Use KI-Stack

Start: `Start-KIStack.cmd`. Stop: `Stop-KIStack.cmd`. The actual interactive status starter is `Lifecycle\Status-KIStack-Interactive.cmd`; the installed **KI-Stack Status** desktop shortcut starts `Lifecycle\Show-KIStackStatus.ps1` with PowerShell 7 and remains visible until a key is pressed. The intended desktop shortcuts are **KI-Stack Start**, **KI-Stack Stop** and **KI-Stack Status**.

Verified local interfaces:

| Interface | Address |
|---|---|
| OpenWebUI | `http://127.0.0.1:8080` |
| LM Studio API | `http://127.0.0.1:1234/v1/models` |
| ComfyUI | `http://127.0.0.1:8188` |
| SearXNG | `http://localhost/searxng/` |

**Expected result:** Status shows Running, Stopped or Error and starts nothing. **Next step:** Open OpenWebUI or ComfyUI.

## Step 8 – Upgrade

Extract the new package, make models compliant first with `Start-KIStack-Model-Import.cmd` when needed, then use `Start-KIStack-Installer.cmd` as administrator. The plan reads existing component markers; `AlreadyCompliant`/`SkippedAlreadyCompliant` means matching existing content is retained. User models, workflows, chats, prompts, uploads and other user data are not deleted as upgrade targets. `ExternalModels` is needed again only when a manual model contract is absent or no longer matches exactly.

## Step 9 – Troubleshooting

| Display or error | Meaning | Exact starter to run | Next step |
|---|---|---|---|
| PowerShell 7 missing / exit code 70 | `pwsh.exe` was not found | None | Install PowerShell 7, then rerun the same starter. |
| Administrator rights required | Upgrade/Repair needs an elevated process | `Start-KIStack-Installer.cmd` | Open PowerShell 7 or CMD as administrator and run the starter there. |
| WSL2 or Debian missing | Preflight cannot check the Linux service chain | `Start-KIStack-Audit.cmd` | Read Audit output; provide WSL2/Debian, do not alter package modules manually. |
| Model missing | Manual contract is absent from the direct source folder | `Start-KIStack-Model-Import.cmd` | Put the exact file in `ExternalModels` and repeat import. |
| Model SHA256 incorrect | File does not meet the contract | `Start-KIStack-Model-Import.cmd` | Remove/replace the incorrect file; do not force an import. |
| `WaitingForUserAction` | A model or OpenWebUI action remains open | Resume command from Step 5 | Meet the requirement and continue with the same TransactionId. |
| Interrupted transaction | `transaction.json` contains open steps | Resume command from Step 5 | Read the report, then resume; rollback for an unsolvable error. |
| Validation failed | Health or operations failed | `Start-KIStack-Validate.cmd` | Check Status; do not assume automatic repair. |
| Service or port unavailable | Status/health check reports Stopped or Error | `Lifecycle\Status-KIStack-Interactive.cmd` | Read Status; use `Start-KIStack.cmd` only for deliberate startup. |
| Repair required | Managed state is damaged | `Start-KIStack-Repair.cmd` | **Warning:** Use only after Audit/transaction review and as administrator. |
| Rollback required | An active transaction must be reverted | `Start-KIStack-Rollback.cmd` | **Warning:** Only the current Complete Installer operation is rolled back; read the report first. |

## Operating matrix

| Purpose | File | Start method | Administrator rights | When to use |
|---|---|---|---|---|
| Install/upgrade | `Start-KIStack-Installer.cmd` | elevated Explorer/console start | Yes | Normal installation path after model import. |
| Model audit/import | `Start-KIStack-Model-Import.cmd` | double-click or console; arguments supported | Required for target changes | Before installation when models are missing. |
| Audit | `Start-KIStack-Audit.cmd` | double-click or console | No | Read-only inventory and plan. |
| Validate | `Start-KIStack-Validate.cmd` | double-click or console | No | Read-only health and operations check. |
| Repair | `Start-KIStack-Repair.cmd` | elevated console | Yes | Only after diagnosis. |
| Rollback | `Start-KIStack-Rollback.cmd` | elevated console | Yes | Only for controlled reversion. |
| Start | `Start-KIStack.cmd` | double-click or console | Depends on installed lifecycle | Deliberate central startup. |
| Stop | `Stop-KIStack.cmd` | double-click or console | Depends on installed lifecycle | Controlled central stop. |
| Status | `Lifecycle\Status-KIStack-Interactive.cmd` | double-click | No | Read-only status with a visible window. |
| Self-test | `Start-KIStack-Complete-Installer-SelfTest.cmd` | console | No | Package-development check, not the normal user path. |

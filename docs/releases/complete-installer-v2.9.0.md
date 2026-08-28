# KI-Stack Complete Installer v2.9.0

Regression- and real-target-validated.

- Complete Installer: 2.9.0 (base: 2.8.0)
- Status: `ReplayComponent_TargetValidated`
- Other component versions: unchanged from 2.8.0 (ComfyUI 1.2.4, Visual Models/Workflows 2.0.3, OpenWebUI Agent Pack 1.8.9, OpenWebUI Visual Pack 2.0.5, Codex Local 0.1.4, RAG 0.3.1) -- no other component payload changed in this cycle.
- PackageSelfTest: 28/28 passed; repository validation: passed

## Scope: complete-installer-orchestrator-only

No other component's payload changed in this cycle. The only change is a new, explicit `-ReplayComponent` contract on the Complete Installer's own planning/orchestration layer.

## ReplayComponent: deliberately re-running an already-compliant component

2.8.0 documented a known limitation: the guided OpenWebUI first-login cutover could not be re-triggered end-to-end on a target where the Visual Pack was already compliant, since no existing contract allowed forcing a compliant step to run again without deleting real files or changing a pinned component version.

`-ReplayComponent <component-id>` (accepted by `Invoke-KIStackCompleteInstaller.ps1` and `Start-KIStackCompleteInstaller.ps1`, threaded through `New-KICompletePlan`) closes this gap. A component named there is planned with `plannedMode='Replay'` instead of `'Skip'` when it is already compliant, and re-runs its existing install/validate/backup path exactly as a normal install or upgrade would -- there is no separate replay implementation. Only `openwebui-visual-pack` and `openwebui-agent-pack` are permitted; an unknown component ID or one not on this allow-list throws before any plan step is built or anything is mutated. Normal `Upgrade`/`Repair`/`Skip` behavior for every other component, and for a permitted component when `-ReplayComponent` is not given, is unchanged. Nothing is deleted and no pinned component version is changed to manufacture artificial non-compliance, and selecting one component never cascades to re-run a dependent one. `New-KICompletePlan`'s `alreadyCompliant` field keeps its original, honest raw-compliance meaning; a new `hasReplay` field is combined with it to gate `Invoke-KIStackCompleteInstaller`'s already-compliant short-circuit so a requested replay is never silently skipped.

Validation: `Test-KIStackReplayComponent.ps1` -- compliant+no-replay stays `Skip`; compliant+replay resolves to `Replay` without affecting sibling components (no implicit recursion to a dependent component); an unknown component ID and a known-but-not-permitted component ID each throw before any mutation; a genuinely non-compliant component's normal `Upgrade` path is unaffected; the early-return guard is statically confirmed wired to `hasReplay`; and the guided OpenWebUI cutover is demonstrably entered when a step arrives with `plannedMode='Replay'`. Full existing regression suite (all prior Complete Installer tests) unaffected.

## Real-target acceptance

Performed against the existing real target (`C:\KI-Stack`), via an interactive, administrator-elevated run of `Start-KIStackCompleteInstaller.ps1 -ReplayComponent openwebui-visual-pack` against the already-compliant real Visual Pack installation:

- `plannedMode` resolved to **`Replay`**.
- Real browser-based first-login/API-key flow: **PASS** -- OpenWebUI opened in the default browser, admin login/creation and API-key generation completed interactively.
- `apiKeyStored: false` -- the key was held only in memory as a `SecureString` and never persisted.
- Existing Visual Pack install/validate path: **PASS**.
- A real backup was created (`C:\KI-Stack\backups\openwebui-visual-pack\...\visual-pack.backup.json`).
- Requested real image test: **PASS**.
- Requested real video test: **PASS**.
- Transaction status: **`Completed`**.
- OpenWebUI healthcheck: **HTTP 200**.
- ComfyUI healthcheck: **HTTP 200**.
- No second venv, no other unexpected mutation of the target.

This closes the 2.8.0 guided-cutover First-Install acceptance boundary: the flow has now been demonstrated end-to-end against a real, already-compliant target, without deleting any file or changing any pinned component version.

## Known manual follow-up

Unchanged from prior releases: without a supplied OpenWebUI administrator API key, the temporary Knowledge bootstrap-experiment rollback and the Code Interpreter connection configuration remain manual follow-up steps in OpenWebUI after installation (`CredentialRequiredForApiReadback` / `CredentialRequiredForApiConfiguration`).



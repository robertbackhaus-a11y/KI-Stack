# KI-Stack Complete Installer v2.8.0

- Complete Installer: 2.8.0 (base: 2.7.0)
- Status: `OpenWebUICutover_Heartbeat_ManagedUpdate_TargetValidated`
- Other component versions: unchanged from 2.7.0 (ComfyUI 1.2.4, Visual Models/Workflows 2.0.3, OpenWebUI Agent Pack 1.8.9, OpenWebUI Visual Pack 2.0.5, Codex Local 0.1.4, RAG 0.3.1) -- no other component payload changed in this cycle.
- PackageSelfTest: 28/28 passed; repository validation: passed

## Scope: complete-installer-orchestrator-only

No other component's payload changed in this cycle. All changes are scoped to the Complete Installer package's own orchestration, console UX, and deployment hygiene.

## Guided OpenWebUI first-login cutover

After OpenWebUI and ComfyUI are confirmed reachable (each with a bounded readiness wait), the installer opens OpenWebUI in the default browser and guides the user through first login/admin creation and API-key generation in the console, then waits for explicit confirmation before reading the key -- held only in memory as a `SecureString`, never stored -- and continuing the existing Visual Pack install/validate path unchanged. A final confirmation gate asks for one real image test and one real video test in OpenWebUI before the cutover counts as complete.

`WaitingForUserAction` now means only that OpenWebUI and ComfyUI are both reachable but first login/API key is still missing. If either service stays unreachable beyond its bounded readiness wait, the installer fails with a real error instead of waiting indefinitely for a user action that cannot happen.

Validation: `Test-KIStackOpenWebUIVisualPackCutover.ps1` -- reachable-with-no-key Skip path, OpenWebUI-unreachable-after-budget error, ComfyUI-unreachable error, and the successful token path all pass.

## Installer progress / heartbeat

The installer now prints a console status line per step (`Running`, `Waiting`, `WaitingForUserAction`, `Completed`, `Failed`) with a timestamp, and a heartbeat at least every ~20-30s while an existing wait loop (such as the OpenWebUI readiness check) is still active, so a long-running step never looks stuck. No progress bar or invented percentage -- only the current step, elapsed runtime, and a short status description. No new sleeps or polling were introduced; the heartbeat is emitted only from within already-existing wait loops and at existing step-start/step-end transitions.

Validation: `Test-KIStackInstallerHeartbeat.ps1` -- a short step produces no heartbeat, a long step produces exactly one due heartbeat with elapsed runtime, `WaitingForUserAction`/`Completed`/`Failed` each print exactly once, and static source markers confirm the helper is actually wired into the step loop, its failure handler, and the OpenWebUI readiness loop.

## Managed OpenWebUI update

OpenWebUI's installed version is no longer changed by hand with `pip` inside its venv. `Update-KIStack-OpenWebUI.cmd` (deployed to `C:\KI-Stack`) is the sole entry point: it reads the target version from the same central `kernel-config.json` the Applications module uses, reuses the existing managed venv in place for both upgrade and downgrade via the same contract, performs a managed stop/restart of the OpenWebUI process, and runs a local healthcheck. Already at the target version reports `Skip` and changes nothing. A failed update or a failed post-update healthcheck automatically rolls back to the previously installed version, re-verifies that version and its healthcheck, and then reports the original failure. No new venv or parallel OpenWebUI installation is ever created.

Validation: `Test-KIStackOpenWebUIManagedUpdate.ps1` -- Skip, successful upgrade, successful downgrade, install-failure rollback, and healthcheck-failure rollback all pass against fixtures.

## Payload deployment hygiene

`Install-KICompleteOrchestrator` previously copied the current package into `installer/complete` with `Copy-Item -Force`, which only adds or overwrites files and never removes a destination file whose name no longer exists in the source. Over repeated real deployments this accumulated stale and even foreign, misplaced payload zips per payload-type folder, eventually causing `Expand-KICompletePayload` to fail with "Payload ist mehrdeutig" since it requires exactly one zip per type. Before the existing copy step, each payload-type folder under the source's `Payload/` directory is now reconciled to remove any destination file not present by name in the current source folder, so exactly the current payload remains after the copy. No blanket deletion of `installer/complete`, and no change to backups/state/logs outside the payload tree.

Validation: `Test-KIStackPayloadDeploymentHygiene.ps1` -- empty destination, stale-version removal (with the pre-cleanup state still backed up), foreign-payload removal without affecting a sibling payload type, and a repeated identical run being idempotent all pass.

## RC13 fixture recovery testability fix

`Resolve-KICompleteFailedTransactionState` unconditionally called `Test-KICompleteIntegrationCompliant`/`Test-KICompleteCodexLocalCompliant`, which depend on real runtime/WSL state a test fixture cannot provide, causing `Test-RC13FailedStateRecovery.ps1` to fail with "Fehlgeschlagene Transaktion ist nicht recoverbar" despite byte-identical version strings on both sides of the comparison. The function now accepts the same optional `FixtureState` bypass `New-KICompletePlan` already used for the identical compliance-check class, skipping those two live-environment checks only when a fixture is supplied. No real invocation ever passes `FixtureState`, so real-target compliance behavior is unchanged -- confirmed by a negative-control run that reproduces the exact original real-path failure without it. No functional/product-behavior change.

## Real-target acceptance

Performed against the existing real target (`C:\KI-Stack`), via two real administrator-elevated Complete Installer Upgrade runs with `kernel-config.json` temporarily retargeted and reverted afterward (byte-identical to the committed source when done):

- Managed update Skip (target version already installed): **PASS**, no mutation.
- Controlled downgrade `0.11.0 -> 0.10.2` via `Update-KIStack-OpenWebUI.cmd`: **PASS**, managed venv only, no second venv created.
- Controlled upgrade back `0.10.2 -> 0.11.0` via the same script: **PASS**.
- Healthcheck after every step: **HTTP 200**.
- Payload uniqueness: `C:\KI-Stack\installer\complete\Payload\CutoverRuntime` held 5 accumulated historical/misplaced zips before the fix; a real Upgrade run afterward reduced it to exactly one, and `Expand-KICompletePayload -Name CutoverRuntime` resolved unambiguously on every subsequent real run.
- No manual `pip install`/`pip uninstall` was run outside `Update-KIStack-OpenWebUI.cmd` at any point.
- Final installed OpenWebUI version: `0.11.0`, matching `kernel-config.json`.

## Known limitation: guided cutover First-Install acceptance boundary

The guided OpenWebUI first-login cutover was **not** re-triggered end-to-end against the real target in this cycle. `openwebui-visual-pack` and `openwebui-agent-pack` were both already compliant on `C:\KI-Stack` (confirmed via a read-only Audit-mode plan), so `plannedMode` resolves to `Skip` and the guided flow's own code path never executes. No existing Force/Repair/Replay contract can re-trigger an already-compliant step without deleting real files or changing a pinned component version, and neither was done deliberately to avoid risking the existing production Visual Pack installation. This is a **First-Install acceptance boundary, not a release blocker**: the flow is fully covered by `Test-KIStackOpenWebUIVisualPackCutover.ps1`, and its building blocks (readiness checks, `SecureString` handling, the underlying Visual Pack install/validate path) are independently real-target proven elsewhere in this cycle and in prior releases.

## Known manual follow-up

Unchanged from prior releases: without a supplied OpenWebUI administrator API key, the temporary Knowledge bootstrap-experiment rollback and the Code Interpreter connection configuration remain manual follow-up steps in OpenWebUI after installation (`CredentialRequiredForApiReadback` / `CredentialRequiredForApiConfiguration`).

The authoritative Complete Installer ZIP and its SHA256 sidecar are published with this GitHub Release.
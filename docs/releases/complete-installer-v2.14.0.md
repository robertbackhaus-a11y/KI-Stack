# KI-Stack Complete Installer v2.14.0

Feature and real-target-validated release. Base: 2.13.0.

- Complete Installer: 2.14.0 (base: 2.13.0)
- Status: `ComponentIsolation_VersionRegistry_ReleaseAttestation_CodexLocalIsolatedHome_OpenWebUICredentialBootstrap_ResearchAgentWebSearchValidation`
- Component pins: ComfyUI 1.2.4 (upstream reference/minimum `v0.34.0`), Models/Workflows 2.0.3, Applications 1.4.11 (Open WebUI reference/minimum `0.11.3`), Integration 1.5.11, Cutover Runtime 1.6.14, Production Recovery 1.7.0-r7, Validation Gate 1.0.3, Target Acceptance 1.0.10, OpenWebUI Visual Pack 2.0.5, OpenWebUI Agent Pack 1.9.0, OpenWebUI Ballistics Pack 1.0.0, Codex Local 0.2.1, RAG 0.4.0, **Open Terminal 0.1.0 (new)**.
- Repository validation (`scripts/Test-Repository.ps1`): 33/33 passed. PackageSelfTest: 28/28 passed against a freshly extracted build. Deterministic double-build confirmed (byte-identical ZIP, same SHA256). SPDX-2.3 SBOM generated and cross-checked against the ZIP and its sidecar.

## Summary

2.14.0 adds Open Terminal as a new, real, target-validated Complete Installer component, and fixes three real defects in the installer's own console UX and transaction schema that were found while operating it against a real target: a heartbeat that stayed silent during a UAC-elevated run, unfiltered internal transcript noise reaching the live view, and a `centralStarters` field that could collapse out of its documented array shape. No other component's payload changed in this cycle.

## New: Open Terminal

Open Terminal `0.1.0` is integrated as a self-contained ("isolation A") Complete Installer component, installed/upgraded/repaired/skipped the same way as Codex Local: its own `Invoke-KIStackOpenTerminal.ps1` entry point, own backup/rollback, and own version probe (`modules/open-terminal/installation.json`).

- **Runtime**: it runs `uvx open-terminal run --host 127.0.0.1 --port 8000 --cwd <managed-workspace>` (uv's own `tool run` shorthand), resolved deterministically under `C:\KI-Stack\python` -- the managed console script if present, otherwise `python.exe -m uv`, and only as a last resort a bare `uv`/`uv.exe` on `PATH` -- never assuming an unmanaged `uvx` is simply there. No Docker is involved.
- **Process safety**: Stop verifies process identity by PID plus a live `Win32_Process` command-line match (never a bare PID lookup, since PIDs are reused by the OS), so it can never affect an unrelated process.
- **Authentication**: a single 256-bit random API key, generated once and stored DPAPI-encrypted (`ConvertFrom-SecureString`, current-user scope) under `C:\KI-Stack\state\open-terminal\credential.json` -- resolved into the child process's own environment only at start time, never written to a file, script, or log in plaintext, and reused unchanged across restarts, upgrades, and repairs.
- **Readiness**: a bounded wait against `http://127.0.0.1:8000/openapi.json`, never an unbounded loop.
- **Lifecycle**: Start/Stop/Status are chained onto the Complete Installer's own root `Start-KIStack.cmd`/`Stop-KIStack.cmd`/`Get-KIStackStatus.ps1`, so it starts, stops, and reports alongside every other managed component without a separate workflow.
- **Frontend boundary**: OpenWebUI remains the sole user-facing frontend; connecting OpenWebUI to Open Terminal still requires one manual, one-time OpenAPI tool-server registration under OpenWebUI's own Admin Settings -> Tools (automatic registration is not yet implemented -- see "Known open items" below).

## Versions

- Open WebUI: reference/minimum supported version `0.11.3` (both fields now equal; an existing, supported newer installation is preserved, never auto-downgraded).
- ComfyUI: reference/minimum supported version `v0.34.0` (both fields now equal; an existing, supported newer installation is preserved, never auto-downgraded).
- Open Terminal: `0.1.0` (new component).

## Installer UX

- **Live heartbeat during UAC/elevated runs**: the generated `Start-KIStackCompleteInstaller.ps1` transcript previously buffered its own step-status output while running elevated, so a UAC-elevated execution showed nothing in the live console until the very end even though the underlying `Write-KICompleteStepStatus`/`Write-KICompleteStepHeartbeatIfDue` heartbeat was already being written correctly to the transcript file. The elevated launch path now streams that transcript live instead of only reading it back after the child process exits.
- **Transcript-noise filter**: the elevated live view previously surfaced internal transcript scaffolding (PowerShell transcript header/footer lines, `**********************`-style markers) alongside the real step-status lines, and the final result JSON could appear twice (once live, once again from the completed transcript). The live view is now filtered to real step-status/heartbeat lines, and the final result JSON is emitted exactly once.

## Schema fix: `centralStarters` stable array

The `centralStarters` field in the transaction record could previously collapse out of its documented JSON-array shape -- serializing as a bare object for exactly one entry, or as a wrongly nested array for a differently-shaped input -- because PowerShell's array-unwrapping behavior was not defended against at the write site. `centralStarters` is now always written as a genuine JSON array for zero, one, or many entries, verified against all three shapes.

## Validation

- Full repository test suite (`scripts/Test-Repository.ps1`): 33/33 passed, current real count.
- Complete Installer `PackageSelfTest`: 28/28 passed against a freshly extracted build.
- Deterministic double-build: two independent builds of the 2.14.0 package produce byte-identical ZIPs (same size and SHA-256).
- Real-target validation: a real Complete Installer run against an existing, already-provisioned target (`C:\KI-Stack`) completed with overall status `Completed` and exit code `0`, with the live heartbeat visible throughout. Open Terminal was installed for real as part of that run, and a subsequent run against the same target correctly reported it `SkippedAlreadyCompliant`.

## Known open items

- **Automatic OpenWebUI tool-server registration**: Open Terminal still requires a one-time manual registration under OpenWebUI's own Admin Settings -> Tools; this is not yet automated.
- **Latency tracing**: no technical breakdown yet of the real request path OpenWebUI input -> prompt/tool assembly -> LM Studio request -> first token; planned after 2.14.
- **PowerShell-7 bootstrap first hop**: `Bootstrap-KIStackPowerShell7.ps1` (used only when PowerShell 7 itself is missing) has no live heartbeat display of its own -- it only writes a structured `.bootstrap.jsonl` diagnostic log. A known, accepted gap, not a 2.14 blocker.
- Windows Full Greenfield Acceptance, ComfyUI v0.34 Greenfield Acceptance, and a full platform acceptance pass remain deferred to 2.15; the last fully regression- and real-target-validated full-platform state remains 2.10.0.

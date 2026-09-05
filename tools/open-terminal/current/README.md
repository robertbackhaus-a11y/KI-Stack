# KI-Stack Open Terminal

**Status (2.15, Phase 7): DEPRECATED as the default terminal/host-control path.** `tools/mcp-runtime/current`
(native MCP over `streamable-http`, registered as `server:mcp:ki-stack-mcp-runtime` in Open WebUI's
`tool_server.connections`) is now the default for all newly migrated profiles
(`ki-stack-it-technik`, `ki-stack-18bravo`, `roleplay`, `ki-stack-allgemein`, 2.15 Phase 6). This
component **remains fully installed, supported, and runnable** as an explicit, deactivatable
fallback for 2.15 — `terminal_server.connections`, `terminal_event_handler`, and
`build_terminal_file_tool_result` are **not** being removed this release. No new
terminal/host-control functionality will be added here going forward; the one exception is the
narrow, already-applied `SyncRegistrationCredential` fix (Phase 7, Section 6 below) for a real,
found credential-drift bug in the existing registration, not a new capability. Full legacy removal
is deferred to a future release, not 2.15.

Managed local integration for [Open Terminal](https://github.com/), started locally (no Docker)
via `uv`/`uvx` and bound to `127.0.0.1:8000`:

```
uvx open-terminal run --host 127.0.0.1 --port 8000 --cwd <managed-working-directory>
```

## Prerequisite

`uv`/`uvx` must already be installed and on `PATH` (see https://astral.sh/uv). KI-Stack does not
install or bundle `uv` itself.

## API key

A cryptographically random `OPEN_TERMINAL_API_KEY` is generated once, on first setup, and
persisted DPAPI-encrypted (Windows Data Protection API, current-user scope) under
`state/open-terminal/credential.json` -- never in the repository, never in plaintext on disk,
never logged. Every later start reuses the same key; it is never rotated automatically.

**Known bug, found and fixed 2.15 Phase 6/7: registration credential drift.** The one-time,
manual `terminal_server.connections` registration under Open WebUI's Admin Settings -> Tools
records the API key as a plain string at registration time. If this component's own DPAPI
credential is ever regenerated out-of-band (observed once, cause not conclusively identified --
possibly correlated with an unrelated service restart during 2.15 Phase 5), the registered key
goes stale and every real tool call fails with `HTTP 401 Invalid API key`, while the component
itself remains healthy and reachable. `Action SyncRegistrationCredential` (added Phase 7) detects
and repairs exactly this: it finds the `terminal_server.connections` entry matching this
component's own configured port, and if its `key` differs from the real, current DPAPI
credential, updates **only** that one field via Read-Modify-Write -- every other field on that
entry, and every other entry in the list, is left byte-for-byte unchanged. If no matching
registration exists at all, it reports that cleanly (registration itself is still a manual,
one-time step, unchanged by this fix). Never logs or returns the plaintext key. This is a real,
narrow bug fix, not new terminal/host-control functionality (see the deprecation notice above).

## Usage

```powershell
# One-time setup (creates the API key, the managed workspace, and the starter/stopper scripts)
pwsh -File Invoke-KIStackOpenTerminal.ps1 -Action Install -TargetRoot C:\KI-Stack

# Start / Stop / Status
pwsh -File Invoke-KIStackOpenTerminal.ps1 -Action Start  -TargetRoot C:\KI-Stack
pwsh -File Invoke-KIStackOpenTerminal.ps1 -Action Stop   -TargetRoot C:\KI-Stack
pwsh -File Invoke-KIStackOpenTerminal.ps1 -Action Status -TargetRoot C:\KI-Stack
```

Start/Stop are also chained (best-effort, additive) onto the Complete Installer's own root
`Start-KIStack.cmd` / `Stop-KIStack.cmd`, and Status is reported by the central
`Get-KIStackStatus.ps1` (`Status-KIStack.cmd`) alongside every other managed component.

## OpenWebUI connection

Register Open Terminal as an OpenAPI tool server in OpenWebUI's Admin Settings -> Tools, using
`http://127.0.0.1:8000` and the persisted API key. Because the key is generated once and reused
across every later KI-Stack restart, this registration only ever needs to be done once.

## Known open points

- Not yet wired into the Complete Installer's transactional `-Mode Install/Upgrade/Repair`
  component dispatcher (`Contracts/COMPONENTS.json` + `CompleteInstaller.psm1`'s isolated
  executor) -- today, Open Terminal is installed via its own `Invoke-KIStackOpenTerminal.ps1
  -Action Install`, not automatically as part of an overall Complete Installer run.
- No automatic OpenWebUI tool-server registration (deliberate -- see the module's own
  documentation on reusing existing credential/config paths instead of new credential
  manipulation).

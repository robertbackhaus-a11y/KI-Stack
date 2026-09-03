# KI-Stack Open Terminal

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

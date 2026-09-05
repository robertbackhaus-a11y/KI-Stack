Set-StrictMode -Version Latest

# KI-Stack MCP Runtime -- managed local process integration (no Docker), Phase 1 of the 2.15
# MCP concept (docs/proposals/2.15-mcp-foundation.md).
#
# Architecture rule (explicit, non-negotiable): this module owns ONLY installation, lifecycle,
# configuration, and Open-WebUI registration of a native MCP server. It is NOT a tool-execution
# or proxy layer between Open WebUI and the MCP server -- Open WebUI's own native MCP client
# (open_webui/utils/middleware.py connect_mcp_server()) talks directly to the MCP server this
# module starts. No tool call ever passes through KI-Stack code at runtime.
#
# The MCP server itself is Open Terminal's existing FastAPI app, exposed via FastMCP's
# OpenAPIProvider -- started through Scripts/mcp_launcher.py, NOT the bare `open-terminal mcp`
# CLI, because Phase 0 proved that bare invocation is 401-broken for every real tool call
# (FastMCP's internal ASGI bridge client carries no Authorization header by default; see the
# launcher script's own header comment and docs/proposals/2.15-mcp-foundation.md). The launcher
# is a startup-time configuration fix, not a runtime proxy: it configures the bridge client once,
# at process start, and never touches an individual tool call afterwards.
#
# This module owns three separate concerns, each modeled on an existing, real KI-Stack pattern
# rather than a new one (mirrors tools/open-terminal/current/OpenTerminal.psm1's own header):
#   - Credential persistence: DPAPI-encrypted local store under state/mcp-runtime/credential.json,
#     the exact same ConvertFrom-SecureString/ConvertTo-SecureString (Windows DPAPI, CurrentUser
#     scope, no -Key) pattern OpenTerminal.psm1 and Lifecycle/KIStackOpenWebUICredential.psm1
#     already use. This is a SEPARATE key from Open Terminal's own OPEN_TERMINAL_API_KEY (the
#     production Open Terminal on port 8000 is never touched by this module) -- generated once,
#     reused on every later start, never rotated implicitly, never logged.
#   - Process identity: PID-file + Win32_Process CommandLine verification, the exact pattern
#     OpenTerminal.psm1's Test-KIOpenTerminalProcessIdentity already establishes.
#   - Package install/backup/rollback: the same Copy-*BackupItem / rollback.json / restore-on-
#     failure shape OpenTerminal.psm1's Install-KIOpenTerminal already establishes for a
#     self-contained ("isolation A") Complete Installer component.
#
# Open-WebUI registration is new territory (Phase 0 confirmed no automated tool_server.connections
# registration script exists anywhere in the repo yet): `tool_server.connections` has no
# single-entry endpoint, only whole-list GET/POST (open_webui/routers/configs.py). Every
# registration/deregistration here is Read-Modify-Write: fetch the full list, find-or-replace
# ONLY the entry whose info.id equals this module's fixed identifier
# ($config.toolServerId, "ki-stack-mcp-runtime"), and write the full list back unchanged
# otherwise -- so a foreign MCP/OpenAPI tool-server entry a user registered by hand is never
# touched, merged, or deleted by this module.

function Read-KIMcpRuntimeJson {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 50
}

function Write-KIMcpRuntimeJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = $Path + '.tmp'
    $Value | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function New-KIMcpRuntimeDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Get-KIMcpRuntimeConfig {
    param([string]$PackageRoot = $PSScriptRoot)
    Read-KIMcpRuntimeJson (Join-Path $PackageRoot 'Config/mcp-runtime.config.json')
}

function Get-KIMcpRuntimePaths {
    # Derives every path from a PathContext-validated TargetRoot (Complete Installer's
    # Runtime/KIStackPathContext.psm1, New-KICompletePathContext) -- never a hardcoded string.
    # Open Terminal itself does not use PathContext (it has its own local, equally pure
    # TargetRoot-derivation function); this module deliberately does, per the 2.15 Phase-1
    # decision to use PathContext for new Isolation-A modules going forward. PathContext's own
    # ModuleRoot/TargetRoot properties are used; StateRoot is NOT (that property is
    # Complete-Installer's own internal transaction-state root, a different concept) -- this
    # module's own state lives under TargetRoot/state/mcp-runtime, the same sibling-of-modules
    # convention OpenTerminal.psm1 already uses for its own state.
    param([string]$TargetRoot = 'C:\KI-Stack')
    # Vendored, not referenced across into tools/complete-installer/current/Runtime/ -- Category
    # A's own isolation contract requires this package to work when staged/extracted completely
    # on its own (no sibling complete-installer tree guaranteed to exist on the target), which a
    # relative cross-package reference cannot: it only happened to work in every test run so far
    # because CompleteInstaller.psm1 (which imports the real KIStackPathContext.psm1) was already
    # loaded in the SAME session beforehand, masking the gap -- a fresh process invocation (e.g.
    # this module's own generated Start/Stop .cmd, which always launches a brand-new pwsh with
    # nothing pre-imported) proved it broken. Vendor/KIStackPathContext.psm1 is an exact copy of
    # tools/complete-installer/current/Runtime/KIStackPathContext.psm1; re-sync if that source
    # changes.
    $pathContextModule = Join-Path $PSScriptRoot 'Vendor/KIStackPathContext.psm1'
    if (-not (Get-Command New-KICompletePathContext -ErrorAction SilentlyContinue)) {
        Import-Module $pathContextModule -Force -ErrorAction Stop
    }
    $context = New-KICompletePathContext -TargetRoot $TargetRoot -Mutating
    $moduleRoot = Join-Path $context.ModuleRoot 'mcp-runtime'
    $stateRoot = Join-Path $context.TargetRoot 'state/mcp-runtime'
    [pscustomobject]@{
        targetRoot = $context.TargetRoot
        moduleRoot = $moduleRoot
        stateRoot = $stateRoot
        marker = Join-Path $moduleRoot 'installation.json'
        starter = Join-Path $moduleRoot 'Start-KIStack-McpRuntime.cmd'
        stopper = Join-Path $moduleRoot 'Stop-KIStack-McpRuntime.cmd'
        credentialFile = Join-Path $stateRoot 'credential.json'
        pidFile = Join-Path $stateRoot 'mcp-runtime.pid'
        # Deliberately inside this package's own state area, never the repository, never a
        # user's own working directory -- mirrors Open Terminal's own workspace isolation.
        workspace = Join-Path $stateRoot 'workspace'
    }
}

# --- Credential (own MCP-server API key; separate from Open Terminal's production key) -------

function ConvertFrom-KIMcpRuntimeSecureStringTransient {
    param([Parameter(Mandatory)][Security.SecureString]$Value)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function New-KIMcpRuntimeApiKeySecure {
    param([int]$Bytes = 32)
    $buffer = [byte[]]::new($Bytes)
    [Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
    try {
        $hex = -join ($buffer | ForEach-Object { $_.ToString('x2') })
        ConvertTo-SecureString -String $hex -AsPlainText -Force
    } finally {
        [Array]::Clear($buffer, 0, $buffer.Length)
    }
}

function Save-KIMcpRuntimeCredential {
    param([Parameter(Mandatory)][Security.SecureString]$ApiKey, [string]$TargetRoot = 'C:\KI-Stack')
    $paths = Get-KIMcpRuntimePaths -TargetRoot $TargetRoot
    New-KIMcpRuntimeDirectory $paths.stateRoot
    $encrypted = $ApiKey | ConvertFrom-SecureString
    $existingCreatedAtUtc = $null
    if (Test-Path -LiteralPath $paths.credentialFile -PathType Leaf) {
        try { $existingCreatedAtUtc = [string](Read-KIMcpRuntimeJson $paths.credentialFile).createdAtUtc } catch {}
    }
    $record = [ordered]@{
        schemaVersion = '1.0'
        protectedForUserSid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
        machineName = $env:COMPUTERNAME
        createdAtUtc = if ([string]::IsNullOrWhiteSpace($existingCreatedAtUtc)) { [DateTime]::UtcNow.ToString('o') } else { $existingCreatedAtUtc }
        encryptedApiKey = $encrypted
        containsSecrets = $false
    }
    Write-KIMcpRuntimeJson $paths.credentialFile $record
    [pscustomobject]@{ passed = $true; path = $paths.credentialFile; mutatesTarget = $true }
}

function Get-KIMcpRuntimeCredential {
    param([string]$TargetRoot = 'C:\KI-Stack')
    $paths = Get-KIMcpRuntimePaths -TargetRoot $TargetRoot
    if (-not (Test-Path -LiteralPath $paths.credentialFile -PathType Leaf)) { return $null }
    try {
        $record = Read-KIMcpRuntimeJson $paths.credentialFile
        $secure = [string]$record.encryptedApiKey | ConvertTo-SecureString
        [pscustomobject]@{ apiKey = $secure; createdAtUtc = [string]$record.createdAtUtc; decryptionFailed = $false }
    } catch {
        [pscustomobject]@{ apiKey = $null; decryptionFailed = $true; reason = 'Credential-Store nicht entschlüsselbar (falscher Benutzer-/Maschinenkontext oder beschädigt).' }
    }
}

function Assert-KIMcpRuntimeApiKey {
    param([string]$TargetRoot = 'C:\KI-Stack', [int]$Bytes = 32)
    $existing = Get-KIMcpRuntimeCredential -TargetRoot $TargetRoot
    if ($null -ne $existing -and -not [bool]$existing.decryptionFailed) { return @{ credential = $existing; created = $false } }
    $newKey = New-KIMcpRuntimeApiKeySecure -Bytes $Bytes
    Save-KIMcpRuntimeCredential -ApiKey $newKey -TargetRoot $TargetRoot | Out-Null
    $newKey = $null
    @{ credential = (Get-KIMcpRuntimeCredential -TargetRoot $TargetRoot); created = $true }
}

# --- Process identity / lifecycle --------------------------------------------------------------

function Test-KIMcpRuntimeProcessIdentity {
    # A PID number alone is never trusted -- the live process's own Name and CommandLine must
    # still match what this module itself would have started (mcp_launcher.py + this port),
    # exactly OpenTerminal.psm1's Test-KIOpenTerminalProcessIdentity pattern. `uv run --with ...
    # python <script>` resolves, per Phase 0's own observed process tree, to a final python.exe
    # (never a bare uv.exe/uvx.exe as the leaf), so python.exe is included here unlike Open
    # Terminal's own allow-list.
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$WorkspacePath,
        [string[]]$AllowedNames = @('uv.exe', 'uvx.exe', 'python.exe')
    )
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if ($null -eq $proc) { return $false }
    if ($proc.Name -notin $AllowedNames) { return $false }
    $commandLine = [string]$proc.CommandLine
    return ($commandLine -match '(?i)mcp_launcher\.py') -and
           ($commandLine -match [regex]::Escape([string]$Port)) -and
           ($commandLine -match [regex]::Escape($WorkspacePath))
}

function Get-KIMcpRuntimeTrackedProcessId {
    param([Parameter(Mandatory)][object]$Paths, [Parameter(Mandatory)][object]$Config, [string[]]$AllowedNames = @('uv.exe', 'uvx.exe', 'python.exe'))
    if (-not (Test-Path -LiteralPath $Paths.pidFile -PathType Leaf)) { return $null }
    $raw = (Get-Content -LiteralPath $Paths.pidFile -Raw).Trim()
    if ($raw -notmatch '^\d+$') { return $null }
    $candidate = [int]$raw
    if (Test-KIMcpRuntimeProcessIdentity -ProcessId $candidate -Port ([int]$Config.port) -WorkspacePath $Paths.workspace -AllowedNames $AllowedNames) { return $candidate }
    return $null
}

function Resolve-KIMcpRuntimeManagedUv {
    # Same deterministic, TargetRoot-bound uv resolution contract as
    # OpenTerminal.psm1's Resolve-KIOpenTerminalManagedUv -- reused verbatim in spirit (not
    # imported, since OpenTerminal.psm1 does not export it as a cross-module API surface, but the
    # exact same three-step order: managed binary, managed python -m uv, PATH fallback).
    param([Parameter(Mandatory)][string]$TargetRoot)
    $managedPythonRoot = Join-Path $TargetRoot 'python'
    $managedUvScript = Join-Path $managedPythonRoot 'Scripts\uv.exe'
    if (Test-Path -LiteralPath $managedUvScript -PathType Leaf) {
        return [pscustomobject]@{ found = $true; invocation = 'managed-binary'; command = $managedUvScript; argumentsPrefix = @() }
    }
    $managedPython = Join-Path $managedPythonRoot 'python.exe'
    if (Test-Path -LiteralPath $managedPython -PathType Leaf) {
        $null = & $managedPython -m uv --version 2>$null
        if ($LASTEXITCODE -eq 0) {
            $global:LASTEXITCODE = 0
            return [pscustomobject]@{ found = $true; invocation = 'managed-python-module'; command = $managedPython; argumentsPrefix = @('-m', 'uv') }
        }
        $global:LASTEXITCODE = 0
    }
    $pathUv = Get-Command 'uv.exe' -ErrorAction SilentlyContinue
    if (-not $pathUv) { $pathUv = Get-Command 'uv' -ErrorAction SilentlyContinue }
    if ($pathUv) { return [pscustomobject]@{ found = $true; invocation = 'path-fallback-binary'; command = $pathUv.Source; argumentsPrefix = @() } }
    [pscustomobject]@{ found = $false; invocation = $null; command = $null; argumentsPrefix = @() }
}

function Assert-KIMcpRuntimeManagedUv {
    param([Parameter(Mandatory)][string]$TargetRoot)
    $resolved = Resolve-KIMcpRuntimeManagedUv -TargetRoot $TargetRoot
    if (-not [bool]$resolved.found) {
        throw "Verwaltetes uv wurde unter '$TargetRoot' nicht gefunden. MCP Runtime setzt die von Foundation/Python-Git bereits verwaltete uv-Installation voraus -- KI-Stack installiert hier keine zweite, unabhängige uv-/Python-Installation."
    }
    $resolved
}

function Get-KIMcpRuntimeStartArguments {
    # `uv run --with open-terminal[mcp] python <launcher> <host> <port> <workspace>` -- resolves
    # the [mcp] extra on demand (Phase 0 finding: not installed by default), never installs a
    # second, separate copy of open-terminal itself.
    param([Parameter(Mandatory)][object]$Config, [Parameter(Mandatory)][string]$LauncherPath, [Parameter(Mandatory)][string]$WorkspacePath, [string[]]$ArgumentsPrefix = @())
    @($ArgumentsPrefix) + @(
        'run', '--with', [string]$Config.packageSpec, 'python', $LauncherPath,
        [string]$Config.host, [string][int]$Config.port, $WorkspacePath
    )
}

function Test-KIMcpRuntimeHealthy {
    # No /openapi.json-equivalent readiness endpoint exists for a native MCP server (Phase 0
    # finding). The only meaningful readiness signal is a real MCP protocol round-trip:
    # initialize + list_tools. Shells out to the SAME `mcp` Python client library Open WebUI
    # itself uses (open_webui/utils/mcp/client.py), via the Open-WebUI venv's own python.exe --
    # never a bare TCP-port check, which would pass even for a process that is up but 401-broken.
    param([Parameter(Mandatory)][object]$Config, [Parameter(Mandatory)][Security.SecureString]$ApiKey, [int]$RequestTimeoutSeconds = 5, [string]$OpenWebUIPythonExe = 'C:\KI-Stack\python\venvs\openwebui\Scripts\python.exe')
    $uri = "http://$($Config.host):$($Config.port)/mcp"
    if (-not (Test-Path -LiteralPath $OpenWebUIPythonExe -PathType Leaf)) {
        return [pscustomobject]@{ reachable = $false; uri = $uri; error = "Open-WebUI-Python nicht gefunden unter $OpenWebUIPythonExe (fuer den MCP-Health-Check benoetigt)." }
    }
    $plainKey = ConvertFrom-KIMcpRuntimeSecureStringTransient -Value $ApiKey
    $checkScript = @'
import asyncio, sys, json
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

async def main():
    url, key, timeout = sys.argv[1], sys.argv[2], float(sys.argv[3])
    headers = {"Authorization": f"Bearer {key}"}
    async with asyncio.timeout(timeout):
        async with streamablehttp_client(url, headers=headers) as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools = await session.list_tools()
                print(json.dumps({"ok": True, "toolCount": len(tools.tools)}))

asyncio.run(main())
'@
    $tempScript = [IO.Path]::GetTempFileName() + '.py'
    try {
        [IO.File]::WriteAllText($tempScript, $checkScript, [Text.UTF8Encoding]::new($false))
        $output = & $OpenWebUIPythonExe $tempScript $uri $plainKey $RequestTimeoutSeconds 2>&1
        $exitCode = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        if ($exitCode -eq 0) {
            $parsed = $output | Select-Object -Last 1 | ConvertFrom-Json
            [pscustomobject]@{ reachable = [bool]$parsed.ok; uri = $uri; toolCount = [int]$parsed.toolCount }
        } else {
            [pscustomobject]@{ reachable = $false; uri = $uri; error = ($output -join "`n") }
        }
    } finally {
        $plainKey = $null
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
}

function Wait-KIMcpRuntimeHealthy {
    param([Parameter(Mandatory)][object]$Config, [Parameter(Mandatory)][Security.SecureString]$ApiKey, [Diagnostics.Process]$Process)
    $timeoutSeconds = [int]$Config.health.timeoutSeconds
    $intervalSeconds = [int]$Config.health.intervalSeconds
    $requestTimeoutSeconds = [int]$Config.health.requestTimeoutSeconds
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    do {
        $probe = Test-KIMcpRuntimeHealthy -Config $Config -ApiKey $ApiKey -RequestTimeoutSeconds $requestTimeoutSeconds
        if ([bool]$probe.reachable) { return [pscustomobject]@{ passed = $true; probe = $probe } }
        if ($null -ne $Process -and $Process.HasExited) {
            return [pscustomobject]@{ passed = $false; probe = $probe; reason = "MCP-Runtime-Prozess wurde vorzeitig mit Exitcode $($Process.ExitCode) beendet." }
        }
        Start-Sleep -Seconds $intervalSeconds
    } while ((Get-Date) -lt $deadline)
    [pscustomobject]@{ passed = $false; probe = $probe; reason = "MCP Runtime ist nach $timeoutSeconds Sekunden unter $($probe.uri) nicht erreichbar (Timeout)." }
}

function Start-KIMcpRuntime {
    # Idempotent: an identity-verified, already-healthy MCP Runtime process returns
    # AlreadyRunning instead of starting a second instance on the same port.
    param(
        [string]$PackageRoot = $PSScriptRoot,
        [string]$TargetRoot = 'C:\KI-Stack',
        [string[]]$AllowedProcessNames = @('uv.exe', 'uvx.exe', 'python.exe'),
        [object]$ConfigOverride = $null
    )
    $config = if ($null -ne $ConfigOverride) { $ConfigOverride } else { Get-KIMcpRuntimeConfig -PackageRoot $PackageRoot }
    $paths = Get-KIMcpRuntimePaths -TargetRoot $TargetRoot
    New-KIMcpRuntimeDirectory $paths.stateRoot
    New-KIMcpRuntimeDirectory $paths.workspace

    $ensured = Assert-KIMcpRuntimeApiKey -TargetRoot $TargetRoot -Bytes ([int]$config.apiKeyBytes)

    $trackedId = Get-KIMcpRuntimeTrackedProcessId -Paths $paths -Config $config -AllowedNames $AllowedProcessNames
    if ($null -ne $trackedId) {
        $probe = Test-KIMcpRuntimeHealthy -Config $config -ApiKey $ensured.credential.apiKey -RequestTimeoutSeconds ([int]$config.health.requestTimeoutSeconds)
        if ([bool]$probe.reachable) { return [pscustomobject]@{ passed = $true; status = 'AlreadyRunning'; processId = $trackedId; endpoint = $probe.uri; mutatesTarget = $false } }
    } elseif (Test-Path -LiteralPath $paths.pidFile -PathType Leaf) {
        Remove-Item -LiteralPath $paths.pidFile -Force -ErrorAction SilentlyContinue
    }

    $managedUv = Assert-KIMcpRuntimeManagedUv -TargetRoot $TargetRoot
    $launcherPath = Join-Path $PackageRoot 'Scripts/mcp_launcher.py'
    $resolvedArguments = Get-KIMcpRuntimeStartArguments -Config $config -LauncherPath $launcherPath -WorkspacePath $paths.workspace -ArgumentsPrefix $managedUv.argumentsPrefix

    $plainKey = $null
    $previousEnv = $env:OPEN_TERMINAL_API_KEY
    $process = $null
    try {
        # Set only on THIS process's own environment, immediately before the child is started
        # (Start-Process children inherit the parent's environment block) -- never written to
        # any file, script, or log. Restored/cleared in `finally` unconditionally. Reuses the
        # OPEN_TERMINAL_API_KEY variable name because Open Terminal's own FastAPI app (imported
        # in-process by mcp_launcher.py) reads that exact variable at import time -- this is NOT
        # the production Open Terminal instance on port 8000, it is a second, independent
        # in-process copy of the same FastAPI app, bound to this module's own port and its own
        # separately-generated key.
        $plainKey = ConvertFrom-KIMcpRuntimeSecureStringTransient -Value $ensured.credential.apiKey
        $env:OPEN_TERMINAL_API_KEY = $plainKey
        $process = Start-Process -FilePath $managedUv.command -ArgumentList $resolvedArguments -WindowStyle Hidden -PassThru
    } finally {
        $env:OPEN_TERMINAL_API_KEY = $previousEnv
        $plainKey = $null
    }
    # `$process.Id` is only the immediate `uv run --with ... python <script>` launcher PID.
    # Verified live (2026-09-05 Phase-1 validation gate): for THIS invocation shape, uv
    # re-execs/reparents into a different, new leaf python.exe PID that actually binds the
    # port and outlives the launcher -- unlike Open Terminal's own `uv tool run open-terminal
    # run` shape, whose top-level PID does stay stable. Trusting `$process.Id` here left a
    # real, still-listening server process untracked and unstoppable (found: stored PID 15040,
    # actual port-owning PID 14424, both real, simultaneously alive, provably different).
    # Fix: once the health check proves the server is actually listening, resolve and persist
    # the PID that genuinely owns $config.port -- never the launcher's own PID. Identity
    # verification (Test-KIMcpRuntimeProcessIdentity) already checks CommandLine content, not
    # just PID existence, so this does not weaken the "no bare PID trust" guarantee -- it
    # fixes WHICH pid gets that verification applied in the first place.
    Set-Content -LiteralPath $paths.pidFile -Value ([string]$process.Id) -Encoding ascii

    $health = Wait-KIMcpRuntimeHealthy -Config $config -ApiKey $ensured.credential.apiKey -Process $process
    if (-not [bool]$health.passed) {
        if (-not $process.HasExited) { try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch {} }
        Remove-Item -LiteralPath $paths.pidFile -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ passed = $false; status = 'Failed'; reason = $health.reason; processId = $process.Id; mutatesTarget = $true }
    }

    $realProcessId = $process.Id
    $portOwner = Get-NetTCPConnection -LocalPort ([int]$config.port) -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty OwningProcess
    if ($null -ne $portOwner -and (Test-KIMcpRuntimeProcessIdentity -ProcessId $portOwner -Port ([int]$config.port) -WorkspacePath $paths.workspace -AllowedNames $AllowedProcessNames)) {
        $realProcessId = $portOwner
    }
    Set-Content -LiteralPath $paths.pidFile -Value ([string]$realProcessId) -Encoding ascii

    [pscustomobject]@{ passed = $true; status = 'Started'; processId = $realProcessId; endpoint = $health.probe.uri; toolCount = $health.probe.toolCount; apiKeyCreated = [bool]$ensured.created; mutatesTarget = $true }
}

function Stop-KIMcpRuntime {
    # Stops ONLY the identity-verified, KI-Stack-tracked MCP Runtime process -- never a pauschal
    # process-name sweep. A missing or stale PID file is treated as "already stopped", never an
    # error (mirrors OpenTerminal.psm1's Stop-KIOpenTerminal exactly).
    param([string]$PackageRoot = $PSScriptRoot, [string]$TargetRoot = 'C:\KI-Stack', [string[]]$AllowedProcessNames = @('uv.exe', 'uvx.exe', 'python.exe'), [object]$ConfigOverride = $null)
    $config = if ($null -ne $ConfigOverride) { $ConfigOverride } else { Get-KIMcpRuntimeConfig -PackageRoot $PackageRoot }
    $paths = Get-KIMcpRuntimePaths -TargetRoot $TargetRoot
    $trackedId = Get-KIMcpRuntimeTrackedProcessId -Paths $paths -Config $config -AllowedNames $AllowedProcessNames
    if (Test-Path -LiteralPath $paths.pidFile -PathType Leaf) { Remove-Item -LiteralPath $paths.pidFile -Force -ErrorAction SilentlyContinue }
    if ($null -eq $trackedId) { return [pscustomobject]@{ passed = $true; status = 'AlreadyStopped'; mutatesTarget = $false } }
    Stop-Process -Id $trackedId -Force -ErrorAction Stop
    [pscustomobject]@{ passed = $true; status = 'Stopped'; processId = $trackedId; mutatesTarget = $true }
}

function Get-KIMcpRuntimeStatus {
    # Read-only. Never includes the API key.
    param([string]$PackageRoot = $PSScriptRoot, [string]$TargetRoot = 'C:\KI-Stack', [string[]]$AllowedProcessNames = @('uv.exe', 'uvx.exe', 'python.exe'), [object]$ConfigOverride = $null)
    $config = if ($null -ne $ConfigOverride) { $ConfigOverride } else { Get-KIMcpRuntimeConfig -PackageRoot $PackageRoot }
    $paths = Get-KIMcpRuntimePaths -TargetRoot $TargetRoot
    $endpoint = "http://$($config.host):$($config.port)/mcp"
    $trackedId = Get-KIMcpRuntimeTrackedProcessId -Paths $paths -Config $config -AllowedNames $AllowedProcessNames
    if ($null -eq $trackedId) {
        return [pscustomobject][ordered]@{ passed = $true; state = 'Stopped'; endpoint = $endpoint; processId = $null; healthCheck = 'NotApplicable'; mutatesTarget = $false }
    }
    $credential = Get-KIMcpRuntimeCredential -TargetRoot $TargetRoot
    if ($null -eq $credential -or [bool]$credential.decryptionFailed) {
        return [pscustomobject][ordered]@{ passed = $true; state = 'Running'; endpoint = $endpoint; processId = $trackedId; healthCheck = 'CredentialUnavailable'; mutatesTarget = $false }
    }
    $probe = Test-KIMcpRuntimeHealthy -Config $config -ApiKey $credential.apiKey -RequestTimeoutSeconds ([int]$config.health.requestTimeoutSeconds)
    $state = if ([bool]$probe.reachable) { 'Running' } else { 'Failed' }
    [pscustomobject][ordered]@{
        passed = $true
        state = $state
        endpoint = $endpoint
        processId = $trackedId
        healthCheck = if ([bool]$probe.reachable) { 'Reachable' } else { 'Unreachable' }
        mutatesTarget = $false
    }
}

# --- Backup / rollback (Install-KIOpenTerminal shape, verbatim) --------------------------------

function Copy-KIMcpRuntimeBackupItem {
    param([string]$Path, [string]$BackupRoot, [string]$Name)
    $entry = [ordered]@{ path = $Path; name = $Name; existed = (Test-Path -LiteralPath $Path); isDirectory = (Test-Path -LiteralPath $Path -PathType Container) }
    if ($entry.existed) { Copy-Item -LiteralPath $Path -Destination (Join-Path $BackupRoot $Name) -Recurse:$entry.isDirectory -Force }
    $entry
}

function Restore-KIMcpRuntimeBackup {
    param([Parameter(Mandatory)][string]$BackupPath)
    $backup = Read-KIMcpRuntimeJson $BackupPath
    $backupRoot = Split-Path -Parent $BackupPath
    foreach ($entry in @($backup.items)) {
        $path = [string]$entry.path
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        if ([bool]$entry.existed) {
            $parent = Split-Path -Parent $path
            New-KIMcpRuntimeDirectory $parent
            Copy-Item -LiteralPath (Join-Path $backupRoot ([string]$entry.name)) -Destination $path -Recurse:([bool]$entry.isDirectory) -Force
        }
    }
    [pscustomobject]@{ passed = $true; status = 'Completed'; backupPath = $BackupPath }
}

function Get-KIMcpRuntimeStarterScriptContent {
    param([Parameter(Mandatory)][string]$InvokeScriptPath, [Parameter(Mandatory)][string]$TargetRoot, [Parameter(Mandatory)][string]$Action)
    "@echo off`r`nsetlocal`r`nset `"PWSH=`"`r`nif exist `"%ProgramFiles%\PowerShell\7\pwsh.exe`" set `"PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe`"`r`nif not defined PWSH for /f `"delims=`" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH set `"PWSH=%%~fI`"`r`nif not defined PWSH (echo FEHLER: PowerShell 7 wurde nicht gefunden.& exit /b 70)`r`n`"%PWSH%`" -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$InvokeScriptPath`" -Action $Action -TargetRoot `"$TargetRoot`"`r`nexit /b %ERRORLEVEL%`r`n"
}

function Test-KIMcpRuntime {
    # Install-time compliance (Audit/Validate): package files + credential present and
    # functional. Deliberately never requires the server process itself to be running --
    # that is Get-KIMcpRuntimeStatus's job (mirrors Test-KIOpenTerminal / Get-KIOpenTerminalStatus).
    param([string]$PackageRoot = $PSScriptRoot, [string]$TargetRoot = 'C:\KI-Stack', [switch]$SkipUvCheck)
    $config = Get-KIMcpRuntimeConfig -PackageRoot $PackageRoot
    $paths = Get-KIMcpRuntimePaths -TargetRoot $TargetRoot
    $marker = $null
    if (Test-Path -LiteralPath $paths.marker -PathType Leaf) { try { $marker = Read-KIMcpRuntimeJson $paths.marker } catch {} }
    $markerMatches = ($null -ne $marker) -and ([string]$marker.version -eq [string]$config.version)
    $starterPresent = Test-Path -LiteralPath $paths.starter -PathType Leaf
    $stopperPresent = Test-Path -LiteralPath $paths.stopper -PathType Leaf
    $workspacePresent = Test-Path -LiteralPath $paths.workspace -PathType Container
    $credential = Get-KIMcpRuntimeCredential -TargetRoot $TargetRoot
    $credentialOk = ($null -ne $credential) -and (-not [bool]$credential.decryptionFailed)
    $uvOk = $true
    if (-not $SkipUvCheck) { $uvOk = [bool](Resolve-KIMcpRuntimeManagedUv -TargetRoot $TargetRoot).found }
    [pscustomobject]@{
        passed = ($markerMatches -and $starterPresent -and $stopperPresent -and $workspacePresent -and $credentialOk -and $uvOk)
        componentVersion = if ($null -ne $marker) { [string]$marker.version } else { $null }
        expectedComponentVersion = [string]$config.version
        starterPresent = $starterPresent; stopperPresent = $stopperPresent; workspacePresent = $workspacePresent
        credentialConfigured = $credentialOk; uvAvailable = $uvOk
        paths = $paths; mutatesTarget = $false
    }
}

function Install-KIMcpRuntime {
    # Serves Install, Upgrade, and Repair alike -- a same-version re-run is a safe no-op via the
    # SkippedAlreadyCompliant fast path (Install-KIOpenTerminal's exact reconcile contract).
    param(
        [string]$PackageRoot = $PSScriptRoot,
        [string]$TargetRoot,
        [ValidateSet('Install', 'Upgrade', 'Repair')][string]$Action = 'Install',
        [switch]$DryRun,
        [switch]$SkipUvCheck
    )
    $config = Get-KIMcpRuntimeConfig -PackageRoot $PackageRoot
    if ([string]::IsNullOrWhiteSpace($TargetRoot)) { $TargetRoot = [string]$config.targetRoot }
    $paths = Get-KIMcpRuntimePaths -TargetRoot $TargetRoot
    if ($DryRun) { return [pscustomobject]@{ passed = $true; status = 'DryRun'; action = $Action; plan = [pscustomobject]@{ moduleRoot = $paths.moduleRoot; stateRoot = $paths.stateRoot }; mutatesTarget = $false } }

    $existing = Test-KIMcpRuntime -PackageRoot $PackageRoot -TargetRoot $TargetRoot -SkipUvCheck:$SkipUvCheck
    if ($existing.passed) { return [pscustomobject]@{ passed = $true; status = 'SkippedAlreadyCompliant'; action = $Action; marker = (Read-KIMcpRuntimeJson $paths.marker); mutatesTarget = $false } }

    if (-not $SkipUvCheck) { Assert-KIMcpRuntimeManagedUv -TargetRoot $TargetRoot | Out-Null }

    New-KIMcpRuntimeDirectory $paths.moduleRoot
    New-KIMcpRuntimeDirectory $paths.stateRoot
    New-KIMcpRuntimeDirectory $paths.workspace
    $backupRoot = Join-Path $TargetRoot ('backups/mcp-runtime/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff'))
    New-KIMcpRuntimeDirectory $backupRoot
    $items = @()
    foreach ($definition in @(
        @{ path = $paths.marker; name = 'installation.json' }, @{ path = $paths.starter; name = 'Start-KIStack-McpRuntime.cmd' },
        @{ path = $paths.stopper; name = 'Stop-KIStack-McpRuntime.cmd' }
    )) { $items += @(Copy-KIMcpRuntimeBackupItem -Path $definition.path -BackupRoot $backupRoot -Name $definition.name) }
    $backupPath = Join-Path $backupRoot 'rollback.json'
    Write-KIMcpRuntimeJson $backupPath ([ordered]@{ schemaVersion = '1.0'; createdAtUtc = [DateTime]::UtcNow.ToString('o'); targetRoot = $TargetRoot; items = $items })

    try {
        $invokeScript = Join-Path $PackageRoot 'Invoke-KIStackMcpRuntime.ps1'
        [IO.File]::WriteAllText($paths.starter, (Get-KIMcpRuntimeStarterScriptContent -InvokeScriptPath $invokeScript -TargetRoot $TargetRoot -Action 'Start'), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($paths.stopper, (Get-KIMcpRuntimeStarterScriptContent -InvokeScriptPath $invokeScript -TargetRoot $TargetRoot -Action 'Stop'), [Text.UTF8Encoding]::new($false))
        Assert-KIMcpRuntimeApiKey -TargetRoot $TargetRoot -Bytes ([int]$config.apiKeyBytes) | Out-Null
        $marker = [ordered]@{ schemaVersion = '1.0'; version = [string]$config.version; host = [string]$config.host; port = [int]$config.port; installedAtUtc = [DateTime]::UtcNow.ToString('o') }
        Write-KIMcpRuntimeJson $paths.marker $marker
        $readback = Test-KIMcpRuntime -PackageRoot $PackageRoot -TargetRoot $TargetRoot -SkipUvCheck:$SkipUvCheck
        if (-not $readback.passed) { throw 'MCP-Runtime-Readback nach Installation ist fehlgeschlagen.' }
        $resultStatus = switch ($Action) { 'Upgrade' { 'Upgraded' }; 'Repair' { 'Repaired' }; default { 'Installed' } }
        [pscustomobject]@{ passed = $true; status = $resultStatus; action = $Action; marker = $marker; backupPath = $backupPath; readback = $readback; mutatesTarget = $true }
    } catch {
        $rollbackStatus = 'Failed'
        try { $rollback = Restore-KIMcpRuntimeBackup -BackupPath $backupPath; $rollbackStatus = [string]$rollback.status } catch {}
        $_.Exception.Data['KIStackRollbackStatus'] = $rollbackStatus
        $_.Exception.Data['KIStackBackupPath'] = $backupPath
        throw
    }
}

function Restore-KIMcpRuntime {
    param([Parameter(Mandatory)][string]$BackupPath, [string]$PackageRoot = $PSScriptRoot, [string]$TargetRoot = 'C:\KI-Stack')
    Restore-KIMcpRuntimeBackup -BackupPath $BackupPath
}

function Uninstall-KIMcpRuntime {
    # Stops the process (if running), unregisters ONLY this module's own Open-WebUI tool-server
    # entry (never touches any other entry -- see Unregister-KIMcpRuntimeOpenWebUI), then removes
    # this module's own module/state trees. Never touches Open Terminal's production install.
    param([string]$PackageRoot = $PSScriptRoot, [string]$TargetRoot = 'C:\KI-Stack')
    $paths = Get-KIMcpRuntimePaths -TargetRoot $TargetRoot
    $stopResult = Stop-KIMcpRuntime -PackageRoot $PackageRoot -TargetRoot $TargetRoot
    $unregisterResult = $null
    try { $unregisterResult = Unregister-KIMcpRuntimeOpenWebUI -PackageRoot $PackageRoot -TargetRoot $TargetRoot } catch { $unregisterResult = [pscustomobject]@{ passed = $false; error = $_.Exception.Message } }
    foreach ($path in @($paths.moduleRoot, $paths.stateRoot)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
    }
    [pscustomobject]@{ passed = $true; status = 'Uninstalled'; stopResult = $stopResult; unregisterResult = $unregisterResult; mutatesTarget = $true }
}

# --- Open-WebUI registration (Read-Modify-Write against tool_server.connections) --------------
#
# tool_server.connections has NO single-entry endpoint (Phase 1 research finding,
# open_webui/routers/configs.py): GET/POST /api/v1/configs/tool_servers always reads/writes the
# WHOLE list. Every function below therefore does a full read, finds-or-replaces ONLY the entry
# whose `info.id` equals $config.toolServerId ("ki-stack-mcp-runtime", the fixed, stable
# identifier this module owns -- ToolServerConnection.info is a schema-free dict, extra='allow',
# so this is a safe place to store an owned identifier), and writes the full list back --
# foreign entries (including the existing, separate, manually-registered `terminal_server.
# connections` entry, a DIFFERENT config key entirely, and any other MCP/OpenAPI tool server a
# user registered by hand) are always carried through byte-for-byte unmodified.

function Get-KIMcpRuntimeOpenWebUIAdminHeaders {
    # Reuses the EXISTING, already-bootstrapped Open-WebUI admin credential store
    # (Lifecycle/KIStackOpenWebUICredential.psm1, Get-KIStackOpenWebUICredential) -- this module
    # creates no new Open-WebUI credential of its own, it only ever reads what Open Terminal's own
    # bootstrap (Test-KIStackOpenWebUICredentialBootstrap.ps1) already established.
    param([string]$TargetRoot = 'C:\KI-Stack')
    # Vendored for the same self-containment reason as Get-KIMcpRuntimePaths above --
    # Vendor/KIStackOpenWebUICredential.psm1 is an exact copy of
    # tools/complete-installer/current/Lifecycle/KIStackOpenWebUICredential.psm1; re-sync if that
    # source changes.
    $credModule = Join-Path $PSScriptRoot 'Vendor/KIStackOpenWebUICredential.psm1'
    if (-not (Get-Command Get-KIStackOpenWebUICredential -ErrorAction SilentlyContinue)) {
        Import-Module $credModule -Force -ErrorAction Stop
    }
    $credential = Get-KIStackOpenWebUICredential -TargetRoot $TargetRoot
    if ($null -eq $credential) { throw 'Kein Open-WebUI-Admin-API-Key im lokalen Credential-Store gefunden (Lifecycle/KIStackOpenWebUICredential.psm1). Bootstrap zuerst mit dessen eigenem Initialize-/Bootstrap-Pfad.' }
    $plain = ConvertFrom-KIMcpRuntimeSecureStringTransient -Value $credential.apiKey
    try {
        @{ Authorization = "Bearer $plain"; 'Content-Type' = 'application/json' }
    } finally {
        $plain = $null
    }
}

function Get-KIMcpRuntimeOpenWebUIToolServerEntry {
    # Pure function: given this module's own config + the MCP server's own DPAPI-stored key,
    # returns exactly the ToolServerConnection object this module owns -- factored out so the
    # real registration payload is directly, deterministically testable without an HTTP call
    # (same testability pattern OpenTerminal.psm1's Get-KIOpenTerminalStartArguments already
    # establishes for a real start contract).
    param([Parameter(Mandatory)][object]$Config, [Parameter(Mandatory)][Security.SecureString]$McpApiKey)
    $plain = ConvertFrom-KIMcpRuntimeSecureStringTransient -Value $McpApiKey
    try {
        [ordered]@{
            url = "http://$($Config.host):$($Config.port)/mcp"
            path = ''
            type = 'mcp'
            auth_type = 'bearer'
            key = $plain
            config = [ordered]@{ access_grants = @(); enable = $true }
            info = [ordered]@{ id = [string]$Config.toolServerId; managedBy = 'KI-STACK-MCP-RUNTIME' }
        }
    } finally {
        $plain = $null
    }
}

function Register-KIMcpRuntimeOpenWebUI {
    # Idempotent: re-running with an unchanged endpoint/key is a no-op status (Unchanged), a
    # changed endpoint/key updates only this module's own entry (Updated), and a first-time call
    # appends it without touching anything else (Registered). Never deletes or reorders any
    # foreign entry.
    param([string]$PackageRoot = $PSScriptRoot, [string]$TargetRoot = 'C:\KI-Stack', [string]$OpenWebUIEndpoint = '', [object]$ConfigOverride = $null)
    $config = if ($null -ne $ConfigOverride) { $ConfigOverride } else { Get-KIMcpRuntimeConfig -PackageRoot $PackageRoot }
    if ([string]::IsNullOrWhiteSpace($OpenWebUIEndpoint)) { $OpenWebUIEndpoint = [string]$config.openWebUIEndpoint }
    $credential = Get-KIMcpRuntimeCredential -TargetRoot $TargetRoot
    if ($null -eq $credential -or [bool]$credential.decryptionFailed) { throw 'MCP-Runtime-Credential nicht verfuegbar -- zuerst Install/Start ausfuehren.' }
    $desiredEntry = Get-KIMcpRuntimeOpenWebUIToolServerEntry -Config $config -McpApiKey $credential.apiKey
    $headers = Get-KIMcpRuntimeOpenWebUIAdminHeaders -TargetRoot $TargetRoot

    $current = Invoke-RestMethod -Uri "$OpenWebUIEndpoint/api/v1/configs/tool_servers" -Headers $headers -TimeoutSec 15
    $existingList = @($current.TOOL_SERVER_CONNECTIONS)
    $ownIndex = -1
    for ($i = 0; $i -lt $existingList.Count; $i++) {
        if (($existingList[$i].info.id) -eq [string]$config.toolServerId) { $ownIndex = $i; break }
    }
    $status = 'Registered'
    if ($ownIndex -ge 0) {
        $unchanged = ($existingList[$ownIndex].url -eq $desiredEntry.url) -and ($existingList[$ownIndex].key -eq $desiredEntry.key)
        if ($unchanged) { return [pscustomobject]@{ passed = $true; status = 'Unchanged'; toolServerId = [string]$config.toolServerId; mutatesTarget = $false } }
        $existingList[$ownIndex] = $desiredEntry
        $status = 'Updated'
    } else {
        $existingList += , $desiredEntry
    }
    $payload = @{ TOOL_SERVER_CONNECTIONS = $existingList } | ConvertTo-Json -Depth 20
    Invoke-RestMethod -Uri "$OpenWebUIEndpoint/api/v1/configs/tool_servers" -Method Post -Headers $headers -Body $payload -TimeoutSec 15 | Out-Null
    [pscustomobject]@{ passed = $true; status = $status; toolServerId = [string]$config.toolServerId; foreignEntriesPreserved = ($existingList.Count - 1); mutatesTarget = $true }
}

function Unregister-KIMcpRuntimeOpenWebUI {
    # Removes ONLY the entry whose info.id matches this module's own toolServerId. A missing
    # entry (never registered, or already removed) is NotRegistered, never an error.
    param([string]$PackageRoot = $PSScriptRoot, [string]$TargetRoot = 'C:\KI-Stack', [string]$OpenWebUIEndpoint = '', [object]$ConfigOverride = $null)
    $config = if ($null -ne $ConfigOverride) { $ConfigOverride } else { Get-KIMcpRuntimeConfig -PackageRoot $PackageRoot }
    if ([string]::IsNullOrWhiteSpace($OpenWebUIEndpoint)) { $OpenWebUIEndpoint = [string]$config.openWebUIEndpoint }
    $headers = Get-KIMcpRuntimeOpenWebUIAdminHeaders -TargetRoot $TargetRoot
    $current = Invoke-RestMethod -Uri "$OpenWebUIEndpoint/api/v1/configs/tool_servers" -Headers $headers -TimeoutSec 15
    $existingList = @($current.TOOL_SERVER_CONNECTIONS)
    $filtered = @($existingList | Where-Object { $_.info.id -ne [string]$config.toolServerId })
    if ($filtered.Count -eq $existingList.Count) { return [pscustomobject]@{ passed = $true; status = 'NotRegistered'; mutatesTarget = $false } }
    $payload = @{ TOOL_SERVER_CONNECTIONS = $filtered } | ConvertTo-Json -Depth 20
    Invoke-RestMethod -Uri "$OpenWebUIEndpoint/api/v1/configs/tool_servers" -Method Post -Headers $headers -Body $payload -TimeoutSec 15 | Out-Null
    [pscustomobject]@{ passed = $true; status = 'Unregistered'; foreignEntriesPreserved = $filtered.Count; mutatesTarget = $true }
}

function Test-KIMcpRuntimeOpenWebUIRegistration {
    # Read-only check: does Open WebUI currently know about this module's own tool-server entry?
    param([string]$PackageRoot = $PSScriptRoot, [string]$TargetRoot = 'C:\KI-Stack', [string]$OpenWebUIEndpoint = '', [object]$ConfigOverride = $null)
    $config = if ($null -ne $ConfigOverride) { $ConfigOverride } else { Get-KIMcpRuntimeConfig -PackageRoot $PackageRoot }
    if ([string]::IsNullOrWhiteSpace($OpenWebUIEndpoint)) { $OpenWebUIEndpoint = [string]$config.openWebUIEndpoint }
    $headers = Get-KIMcpRuntimeOpenWebUIAdminHeaders -TargetRoot $TargetRoot
    $current = Invoke-RestMethod -Uri "$OpenWebUIEndpoint/api/v1/configs/tool_servers" -Headers $headers -TimeoutSec 15
    $existingList = @($current.TOOL_SERVER_CONNECTIONS)
    $ownEntry = $existingList | Where-Object { $_.info.id -eq [string]$config.toolServerId } | Select-Object -First 1
    [pscustomobject]@{ passed = $true; registered = ($null -ne $ownEntry); entry = $ownEntry; mutatesTarget = $false }
}

Export-ModuleMember -Function *

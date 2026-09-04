Set-StrictMode -Version Latest

# KI-Stack Open Terminal -- managed local process integration (no Docker).
#
# Open Terminal is started locally as: uvx open-terminal run --host <host> --port <port>
# --cwd <managed-working-directory>, authenticated via OPEN_TERMINAL_API_KEY. This module owns
# three separate concerns, each modeled on an existing, real KI-Stack pattern rather than a new
# one:
#   - Credential persistence: DPAPI-encrypted local store under state/open-terminal/credential.json,
#     the exact same ConvertFrom-SecureString/ConvertTo-SecureString (Windows DPAPI, CurrentUser
#     scope, no -Key) pattern Lifecycle/KIStackOpenWebUICredential.psm1 already uses for the
#     OpenWebUI API key. Generated once, reused on every later start -- never rotated implicitly,
#     never logged, never written to a starter script in plaintext.
#   - Process identity: PID-file + Win32_Process CommandLine verification, the exact pattern
#     tools/integration/current/Runtime/Start-KIStack-SearXNG.ps1 / Stop-KIStack-SearXNG.ps1
#     already use for their own managed WSL keeper process -- a PID alone is never trusted (PIDs
#     get reused); Stop only ever acts on a process whose live command line still matches what
#     this module itself started.
#   - Package install/backup/rollback: the same Copy-*BackupItem / rollback.json / restore-on-
#     failure shape tools/codex-local/current/CodexLocal.psm1's Install-KICodexLocal already
#     establishes for a self-contained ("isolation A") Complete Installer component.

function Read-KIOpenTerminalJson {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 50
}

function Write-KIOpenTerminalJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = $Path + '.tmp'
    $Value | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function New-KIOpenTerminalDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Get-KIOpenTerminalConfig {
    param([string]$PackageRoot = $PSScriptRoot)
    Read-KIOpenTerminalJson (Join-Path $PackageRoot 'Config/open-terminal.config.json')
}

function Get-KIOpenTerminalPaths {
    param([string]$TargetRoot = 'C:\KI-Stack')
    $moduleRoot = Join-Path $TargetRoot 'modules/open-terminal'
    $stateRoot = Join-Path $TargetRoot 'state/open-terminal'
    [pscustomobject]@{
        moduleRoot = $moduleRoot
        stateRoot = $stateRoot
        marker = Join-Path $moduleRoot 'installation.json'
        starter = Join-Path $moduleRoot 'Start-KIStack-OpenTerminal.cmd'
        stopper = Join-Path $moduleRoot 'Stop-KIStack-OpenTerminal.cmd'
        credentialFile = Join-Path $stateRoot 'credential.json'
        pidFile = Join-Path $stateRoot 'open-terminal.pid'
        # Open Terminal's own --cwd. Deliberately inside this package's state area (never the
        # repository, never a user's own working directory) -- mirrors codex-local's isolated
        # codexHome: a pure function of TargetRoot, never ambient environment.
        workspace = Join-Path $stateRoot 'workspace'
    }
}

function ConvertFrom-KIOpenTerminalSecureStringTransient {
    # The only place in this module allowed to hold the plaintext API key in a variable.
    # Callers must use the result immediately and then null the variable -- never store it,
    # never log it, never Write-Host it.
    param([Parameter(Mandatory)][Security.SecureString]$Value)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function New-KIOpenTerminalApiKeySecure {
    # Cryptographically random API key, returned only as a SecureString -- never as plaintext,
    # never written to output. Hex-encoded (no characters that need shell/env-var escaping).
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

function Save-KIOpenTerminalCredential {
    # DPAPI-encrypted (ConvertFrom-SecureString, CurrentUser scope) -- never plaintext, never in
    # the repository, never in a build artifact. Only decryptable by the same Windows user
    # profile on the same machine that created it.
    param(
        [Parameter(Mandatory)][Security.SecureString]$ApiKey,
        [string]$TargetRoot = 'C:\KI-Stack'
    )
    $paths = Get-KIOpenTerminalPaths -TargetRoot $TargetRoot
    New-KIOpenTerminalDirectory $paths.stateRoot
    $encrypted = $ApiKey | ConvertFrom-SecureString
    $existingCreatedAtUtc = $null
    if (Test-Path -LiteralPath $paths.credentialFile -PathType Leaf) {
        try { $existingCreatedAtUtc = [string](Read-KIOpenTerminalJson $paths.credentialFile).createdAtUtc } catch {}
    }
    $record = [ordered]@{
        schemaVersion = '1.0'
        protectedForUserSid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
        machineName = $env:COMPUTERNAME
        createdAtUtc = if ([string]::IsNullOrWhiteSpace($existingCreatedAtUtc)) { [DateTime]::UtcNow.ToString('o') } else { $existingCreatedAtUtc }
        encryptedApiKey = $encrypted
        containsSecrets = $false
    }
    Write-KIOpenTerminalJson $paths.credentialFile $record
    [pscustomobject]@{ passed = $true; path = $paths.credentialFile; mutatesTarget = $true }
}

function Get-KIOpenTerminalCredential {
    # Returns $null when genuinely NotConfigured (no store file yet) -- never throws for that.
    # Returns .apiKey as a SecureString only; .decryptionFailed=$true on a wrong user/machine or
    # a corrupted store (never surfaces the raw .NET exception).
    param([string]$TargetRoot = 'C:\KI-Stack')
    $paths = Get-KIOpenTerminalPaths -TargetRoot $TargetRoot
    if (-not (Test-Path -LiteralPath $paths.credentialFile -PathType Leaf)) { return $null }
    try {
        $record = Read-KIOpenTerminalJson $paths.credentialFile
        $secure = [string]$record.encryptedApiKey | ConvertTo-SecureString
        [pscustomobject]@{ apiKey = $secure; createdAtUtc = [string]$record.createdAtUtc; decryptionFailed = $false }
    } catch {
        [pscustomobject]@{ apiKey = $null; decryptionFailed = $true; reason = 'Credential-Store nicht entschlüsselbar (falscher Benutzer-/Maschinenkontext oder beschädigt).' }
    }
}

function Assert-KIOpenTerminalApiKey {
    # Idempotent "ensure a key exists" -- generates ONE new key only when none is present yet
    # (first setup / first start), reuses whatever already exists on every later call. Never
    # rotates. Returns the (possibly newly created) credential as from Get-KIOpenTerminalCredential.
    param([string]$TargetRoot = 'C:\KI-Stack', [int]$Bytes = 32)
    $existing = Get-KIOpenTerminalCredential -TargetRoot $TargetRoot
    if ($null -ne $existing -and -not [bool]$existing.decryptionFailed) { return @{ credential = $existing; created = $false } }
    $newKey = New-KIOpenTerminalApiKeySecure -Bytes $Bytes
    Save-KIOpenTerminalCredential -ApiKey $newKey -TargetRoot $TargetRoot | Out-Null
    $newKey = $null
    @{ credential = (Get-KIOpenTerminalCredential -TargetRoot $TargetRoot); created = $true }
}

function Test-KIOpenTerminalProcessIdentity {
    # A PID number alone is never trusted (PIDs are reused by the OS) -- the live process's own
    # Name and CommandLine must still match what this module itself would have started, exactly
    # the verification Start-KIStack-SearXNG.ps1's Test-KeeperIdentity already applies to its own
    # managed WSL keeper process.
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$WorkspacePath,
        # uvx ships as its own binary (uvx.exe) as well as via `uv tool run` / `uv run` -- accept
        # either real launcher name, never a bare heuristic on PID existence alone. Overridable
        # ONLY so Test-KIStackOpenTerminal.ps1 can exercise this exact identity logic end to end
        # against a real (non-uvx-named) local test process -- never overridden by any real caller.
        [string[]]$AllowedNames = @('uvx.exe', 'uv.exe')
    )
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if ($null -eq $proc) { return $false }
    if ($proc.Name -notin $AllowedNames) { return $false }
    $commandLine = [string]$proc.CommandLine
    return ($commandLine -match '(?i)open-terminal') -and
           ($commandLine -match [regex]::Escape("--port $Port") -or $commandLine -match [regex]::Escape("--port=$Port")) -and
           ($commandLine -match [regex]::Escape($WorkspacePath))
}

function Get-KIOpenTerminalTrackedProcessId {
    # Reads the PID file and returns the live, identity-verified process id, or $null. Never
    # mutates the PID file itself (callers that find a stale one decide whether to clean it up).
    param([Parameter(Mandatory)][object]$Paths, [Parameter(Mandatory)][object]$Config, [string[]]$AllowedNames = @('uvx.exe', 'uv.exe'))
    if (-not (Test-Path -LiteralPath $Paths.pidFile -PathType Leaf)) { return $null }
    $raw = (Get-Content -LiteralPath $Paths.pidFile -Raw).Trim()
    if ($raw -notmatch '^\d+$') { return $null }
    $candidate = [int]$raw
    if (Test-KIOpenTerminalProcessIdentity -ProcessId $candidate -Port ([int]$Config.port) -WorkspacePath $Paths.workspace -AllowedNames $AllowedNames) { return $candidate }
    return $null
}

function Test-KIOpenTerminalHealthy {
    # Single, non-looping health probe against /openapi.json -- the contracted readiness
    # signal. Never throws; returns a plain reachable/unreachable verdict.
    param([Parameter(Mandatory)][object]$Config, [int]$RequestTimeoutSeconds = 5)
    $uri = "http://$($Config.host):$($Config.port)$($Config.health.path)"
    try {
        $response = Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec $RequestTimeoutSeconds -UseBasicParsing -ErrorAction Stop
        [pscustomobject]@{ reachable = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400); statusCode = [int]$response.StatusCode; uri = $uri }
    } catch {
        [pscustomobject]@{ reachable = $false; statusCode = $null; uri = $uri; error = $_.Exception.Message }
    }
}

function Wait-KIOpenTerminalHealthy {
    # Bounded wait: polls Test-KIOpenTerminalHealthy every intervalSeconds up to timeoutSeconds
    # total. Never waits forever -- always returns a clear passed/failed verdict, and fails fast
    # if the just-started process has already exited (never waits out the full timeout for a
    # process that is provably already dead).
    param(
        [Parameter(Mandatory)][object]$Config,
        [Diagnostics.Process]$Process
    )
    $timeoutSeconds = [int]$Config.health.timeoutSeconds
    $intervalSeconds = [int]$Config.health.intervalSeconds
    $requestTimeoutSeconds = [int]$Config.health.requestTimeoutSeconds
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    do {
        $probe = Test-KIOpenTerminalHealthy -Config $Config -RequestTimeoutSeconds $requestTimeoutSeconds
        if ([bool]$probe.reachable) { return [pscustomobject]@{ passed = $true; probe = $probe } }
        if ($null -ne $Process -and $Process.HasExited) {
            return [pscustomobject]@{ passed = $false; probe = $probe; reason = "Open-Terminal-Prozess wurde vorzeitig mit Exitcode $($Process.ExitCode) beendet." }
        }
        Start-Sleep -Seconds $intervalSeconds
    } while ((Get-Date) -lt $deadline)
    [pscustomobject]@{ passed = $false; probe = $probe; reason = "Open Terminal ist nach $timeoutSeconds Sekunden unter $($probe.uri) nicht erreichbar (Timeout)." }
}

function Resolve-KIOpenTerminalManagedUv {
    # Deterministic, TargetRoot-bound uv resolution -- reuses the exact managed uv contract
    # Foundation/Python-Git already establishes and enforces
    # (tools/cutover-runtime/current/Modules/03-PythonGit/KIModulePythonGit.psm1's
    # Test-KIUvAvailable / Get-KIPythonGitState: kernel-config.json's pythonEnvironment.root
    # under TargetRoot, bootstrapUv=true, `python -m pip install --upgrade uv`, and a hard
    # `throw` there if uv ends up available neither as a command nor as a Python module).
    # NEVER assumes a bare `uvx` on PATH -- `uvx TOOL ARGS...` is uv's own documented shorthand
    # for `uv tool run TOOL -- ARGS...`, so resolving `uv` itself (whichever of the two
    # invocation shapes below is real) is sufficient and never requires a separate `uvx` script
    # to exist. Checked in order of determinism, never silently falling back past a real check:
    #   1. The managed uv console-script sitting next to the managed Python's own Scripts dir
    #      under THIS TargetRoot (the real, on-disk artifact `pip install uv` produces there).
    #   2. The managed Python interpreter under THIS TargetRoot, invoked as `python -m uv` --
    #      Foundation/Python-Git's own documented fallback shape when no separate console
    #      script exists.
    #   3. PATH (`Get-Command`) -- tolerated only as a last resort, for a target whose managed
    #      Python root genuinely differs from the KI-Stack default; never the first or only path
    #      tried, so this never silently masks a genuinely missing Foundation/Python-Git
    #      prerequisite with an unrelated PATH binary.
    # Never installs uv itself -- that responsibility belongs exclusively to Foundation/
    # Python-Git; duplicating it here would be a second, independent uv/Python installation.
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

function Assert-KIOpenTerminalManagedUv {
    # Fail-closed, actionable error naming the real prerequisite (Foundation/Python-Git's own
    # managed uv contract) -- never a bare "uvx not found", and never an attempt to install uv
    # itself from here.
    param([Parameter(Mandatory)][string]$TargetRoot)
    $resolved = Resolve-KIOpenTerminalManagedUv -TargetRoot $TargetRoot
    if (-not [bool]$resolved.found) {
        throw "Verwaltetes uv wurde unter '$TargetRoot' nicht gefunden (weder als Skript unter python\Scripts\uv.exe noch als 'python -m uv', noch auf PATH). Open Terminal setzt die von Foundation/Python-Git bereits verwaltete uv-Installation voraus (tools/cutover-runtime/current/Modules/03-PythonGit/KIModulePythonGit.psm1, kernel-config.json pythonEnvironment.bootstrapUv=true) -- KI-Stack installiert hier keine zweite, unabhängige uv-/Python-Installation."
    }
    $resolved
}

function Get-KIOpenTerminalStartArguments {
    # The exact, real start contract: uvx open-terminal run --host <host> --port <port>
    # --cwd <managed-working-directory> -- expressed via the resolved managed uv's own
    # ArgumentsPrefix (empty for a real uv/uv.exe binary, @('-m','uv') for the python-module
    # fallback) followed by uv's own `tool run open-terminal` shorthand for `uvx open-terminal`.
    # Factored out as its own pure function so the real argument contract is directly,
    # deterministically unit-testable without spawning a process (the same testability pattern
    # CodexLocal.psm1's Get-KICodexStarterScriptContent already establishes for a generated
    # script's exact content).
    param([Parameter(Mandatory)][object]$Config, [Parameter(Mandatory)][string]$WorkspacePath, [string[]]$ArgumentsPrefix = @())
    @($ArgumentsPrefix) + @('tool', 'run', 'open-terminal', 'run', '--host', [string]$Config.host, '--port', [string][int]$Config.port, '--cwd', $WorkspacePath)
}

function Start-KIOpenTerminal {
    # Idempotent: if an identity-verified Open Terminal process is already tracked and healthy,
    # returns AlreadyRunning instead of starting a second instance on the same port.
    param(
        [string]$PackageRoot = $PSScriptRoot,
        [string]$TargetRoot = 'C:\KI-Stack',
        # Test-only seam (see Test-KIStackOpenTerminal.ps1): substitutes the launched executable
        # and its arguments so the real PID-tracking/identity/health-wait code paths can be
        # exercised against a fake local HTTP stub instead of the real `uvx open-terminal`
        # package -- never used, and never needed, by any real caller. When omitted, production
        # behavior (real managed uv, real Get-KIOpenTerminalStartArguments contract) is unchanged.
        [string]$CommandOverride = '',
        [string[]]$ArgumentsOverride = $null,
        [string[]]$AllowedProcessNames = @('uv.exe', 'python.exe'),
        # Test-only seam: inject a config object (e.g. pinned to a free ephemeral port) instead
        # of reading Config/open-terminal.config.json -- never used by any real caller, which
        # always gets the real, on-disk package configuration.
        [object]$ConfigOverride = $null
    )
    $config = if ($null -ne $ConfigOverride) { $ConfigOverride } else { Get-KIOpenTerminalConfig -PackageRoot $PackageRoot }
    $paths = Get-KIOpenTerminalPaths -TargetRoot $TargetRoot
    New-KIOpenTerminalDirectory $paths.stateRoot
    New-KIOpenTerminalDirectory $paths.workspace

    $trackedId = Get-KIOpenTerminalTrackedProcessId -Paths $paths -Config $config -AllowedNames $AllowedProcessNames
    if ($null -ne $trackedId) {
        $probe = Test-KIOpenTerminalHealthy -Config $config -RequestTimeoutSeconds ([int]$config.health.requestTimeoutSeconds)
        if ([bool]$probe.reachable) { return [pscustomobject]@{ passed = $true; status = 'AlreadyRunning'; processId = $trackedId; endpoint = $probe.uri; mutatesTarget = $false } }
    } elseif (Test-Path -LiteralPath $paths.pidFile -PathType Leaf) {
        # Stale PID file (process gone or identity no longer matches) -- clean it up before
        # starting a fresh instance, exactly as Start-KIStack-SearXNG.ps1 does for its keeper.
        Remove-Item -LiteralPath $paths.pidFile -Force -ErrorAction SilentlyContinue
    }

    $resolvedCommand = $null
    $resolvedArguments = $null
    if ([string]::IsNullOrWhiteSpace($CommandOverride)) {
        $managedUv = Assert-KIOpenTerminalManagedUv -TargetRoot $TargetRoot
        $resolvedCommand = $managedUv.command
        $resolvedArguments = Get-KIOpenTerminalStartArguments -Config $config -WorkspacePath $paths.workspace -ArgumentsPrefix $managedUv.argumentsPrefix
    } else {
        $resolvedCommand = $CommandOverride
    }
    $ensured = Assert-KIOpenTerminalApiKey -TargetRoot $TargetRoot -Bytes ([int]$config.apiKeyBytes)
    $plainKey = $null
    $previousEnv = $env:OPEN_TERMINAL_API_KEY
    $process = $null
    try {
        # The key is set only on THIS process's own environment, immediately before the child is
        # started (Start-Process children inherit the parent's environment block) -- never
        # written into any file, script, or log. Restored/cleared in `finally` unconditionally.
        $plainKey = ConvertFrom-KIOpenTerminalSecureStringTransient -Value $ensured.credential.apiKey
        $env:OPEN_TERMINAL_API_KEY = $plainKey
        $arguments = if ($null -ne $ArgumentsOverride) { $ArgumentsOverride } else { $resolvedArguments }
        $process = Start-Process -FilePath $resolvedCommand -ArgumentList $arguments -WindowStyle Hidden -PassThru
    } finally {
        $env:OPEN_TERMINAL_API_KEY = $previousEnv
        $plainKey = $null
    }
    Set-Content -LiteralPath $paths.pidFile -Value ([string]$process.Id) -Encoding ascii

    $health = Wait-KIOpenTerminalHealthy -Config $config -Process $process
    if (-not [bool]$health.passed) {
        # Never leave a broken process silently tracked as "started" -- best-effort stop, clear
        # failure status, never an infinite wait, never a silently-swallowed error.
        if (-not $process.HasExited) { try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch {} }
        Remove-Item -LiteralPath $paths.pidFile -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ passed = $false; status = 'Failed'; reason = $health.reason; processId = $process.Id; mutatesTarget = $true }
    }
    [pscustomobject]@{ passed = $true; status = 'Started'; processId = $process.Id; endpoint = $health.probe.uri; apiKeyCreated = [bool]$ensured.created; mutatesTarget = $true }
}

function Stop-KIOpenTerminal {
    # Stops ONLY the identity-verified, KI-Stack-tracked Open Terminal process -- never a
    # pauschal `Stop-Process -Name uvx`/python/uv sweep. A missing or stale PID file is treated
    # as "already stopped", never an error.
    param([string]$PackageRoot = $PSScriptRoot, [string]$TargetRoot = 'C:\KI-Stack', [string[]]$AllowedProcessNames = @('uvx.exe', 'uv.exe'), [object]$ConfigOverride = $null)
    $config = if ($null -ne $ConfigOverride) { $ConfigOverride } else { Get-KIOpenTerminalConfig -PackageRoot $PackageRoot }
    $paths = Get-KIOpenTerminalPaths -TargetRoot $TargetRoot
    $trackedId = Get-KIOpenTerminalTrackedProcessId -Paths $paths -Config $config -AllowedNames $AllowedProcessNames
    if (Test-Path -LiteralPath $paths.pidFile -PathType Leaf) { Remove-Item -LiteralPath $paths.pidFile -Force -ErrorAction SilentlyContinue }
    if ($null -eq $trackedId) { return [pscustomobject]@{ passed = $true; status = 'AlreadyStopped'; mutatesTarget = $false } }
    Stop-Process -Id $trackedId -Force -ErrorAction Stop
    [pscustomobject]@{ passed = $true; status = 'Stopped'; processId = $trackedId; mutatesTarget = $true }
}

function Get-KIOpenTerminalStatus {
    # Read-only. Never includes the API key. State: Running (tracked + healthy) / Failed
    # (tracked but not answering /openapi.json) / Stopped (nothing tracked).
    param([string]$PackageRoot = $PSScriptRoot, [string]$TargetRoot = 'C:\KI-Stack', [string[]]$AllowedProcessNames = @('uvx.exe', 'uv.exe'), [object]$ConfigOverride = $null)
    $config = if ($null -ne $ConfigOverride) { $ConfigOverride } else { Get-KIOpenTerminalConfig -PackageRoot $PackageRoot }
    $paths = Get-KIOpenTerminalPaths -TargetRoot $TargetRoot
    $endpoint = "http://$($config.host):$($config.port)"
    $trackedId = Get-KIOpenTerminalTrackedProcessId -Paths $paths -Config $config -AllowedNames $AllowedProcessNames
    if ($null -eq $trackedId) {
        return [pscustomobject][ordered]@{ passed = $true; state = 'Stopped'; endpoint = $endpoint; processId = $null; healthCheck = 'NotApplicable'; mutatesTarget = $false }
    }
    $probe = Test-KIOpenTerminalHealthy -Config $config -RequestTimeoutSeconds ([int]$config.health.requestTimeoutSeconds)
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

function Copy-KIOpenTerminalBackupItem {
    param([string]$Path, [string]$BackupRoot, [string]$Name)
    $entry = [ordered]@{ path = $Path; name = $Name; existed = (Test-Path -LiteralPath $Path); isDirectory = (Test-Path -LiteralPath $Path -PathType Container) }
    if ($entry.existed) { Copy-Item -LiteralPath $Path -Destination (Join-Path $BackupRoot $Name) -Recurse:$entry.isDirectory -Force }
    $entry
}

function Restore-KIOpenTerminalBackup {
    param([Parameter(Mandatory)][string]$BackupPath)
    $backup = Read-KIOpenTerminalJson $BackupPath
    $backupRoot = Split-Path -Parent $BackupPath
    foreach ($entry in @($backup.items)) {
        $path = [string]$entry.path
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        if ([bool]$entry.existed) {
            $parent = Split-Path -Parent $path
            New-KIOpenTerminalDirectory $parent
            Copy-Item -LiteralPath (Join-Path $backupRoot ([string]$entry.name)) -Destination $path -Recurse:([bool]$entry.isDirectory) -Force
        }
    }
    [pscustomobject]@{ passed = $true; status = 'Completed'; backupPath = $BackupPath }
}

function Get-KIOpenTerminalStarterScriptContent {
    # No API key is ever embedded here -- the starter only ever invokes this package's own
    # Start action, which resolves the key from the DPAPI-protected store at run time.
    param([Parameter(Mandatory)][string]$InvokeScriptPath, [Parameter(Mandatory)][string]$TargetRoot, [Parameter(Mandatory)][string]$Action)
    "@echo off`r`nsetlocal`r`nset `"PWSH=`"`r`nif exist `"%ProgramFiles%\PowerShell\7\pwsh.exe`" set `"PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe`"`r`nif not defined PWSH for /f `"delims=`" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH set `"PWSH=%%~fI`"`r`nif not defined PWSH (echo FEHLER: PowerShell 7 wurde nicht gefunden.& exit /b 70)`r`n`"%PWSH%`" -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$InvokeScriptPath`" -Action $Action -TargetRoot `"$TargetRoot`"`r`nexit /b %ERRORLEVEL%`r`n"
}

function Test-KIOpenTerminal {
    # Install-time compliance (Audit/Validate): package files + credential present and
    # functional. Deliberately never requires the server process itself to be running --
    # that is Get-KIOpenTerminalStatus's job (mirrors codex-local's Test-KICodexLocal /
    # Get-KICodexStatus split, where LM Studio reachability is likewise a separate runtime
    # concern from package compliance).
    param([string]$PackageRoot = $PSScriptRoot, [string]$TargetRoot = 'C:\KI-Stack', [switch]$SkipUvCheck)
    $config = Get-KIOpenTerminalConfig -PackageRoot $PackageRoot
    $paths = Get-KIOpenTerminalPaths -TargetRoot $TargetRoot
    $marker = $null
    if (Test-Path -LiteralPath $paths.marker -PathType Leaf) { try { $marker = Read-KIOpenTerminalJson $paths.marker } catch {} }
    $markerMatches = ($null -ne $marker) -and ([string]$marker.version -eq [string]$config.version)
    $starterPresent = Test-Path -LiteralPath $paths.starter -PathType Leaf
    $stopperPresent = Test-Path -LiteralPath $paths.stopper -PathType Leaf
    $workspacePresent = Test-Path -LiteralPath $paths.workspace -PathType Container
    $credential = Get-KIOpenTerminalCredential -TargetRoot $TargetRoot
    $credentialOk = ($null -ne $credential) -and (-not [bool]$credential.decryptionFailed)
    $uvOk = $true
    if (-not $SkipUvCheck) { $uvOk = [bool](Resolve-KIOpenTerminalManagedUv -TargetRoot $TargetRoot).found }
    [pscustomobject]@{
        passed = ($markerMatches -and $starterPresent -and $stopperPresent -and $workspacePresent -and $credentialOk -and $uvOk)
        componentVersion = if ($null -ne $marker) { [string]$marker.version } else { $null }
        expectedComponentVersion = [string]$config.version
        starterPresent = $starterPresent; stopperPresent = $stopperPresent; workspacePresent = $workspacePresent
        credentialConfigured = $credentialOk; uvAvailable = $uvOk
        paths = $paths; mutatesTarget = $false
    }
}

function Install-KIOpenTerminal {
    # Serves Install, Upgrade, and Repair alike (same reconcile-to-config-defined-target-version
    # contract codex-local's Install-KICodexLocal already establishes). A same-version re-run is
    # a safe no-op via the SkippedAlreadyCompliant fast path -- no unnecessary reinstall, no key
    # rotation.
    param(
        [string]$PackageRoot = $PSScriptRoot,
        [string]$TargetRoot,
        [ValidateSet('Install', 'Upgrade', 'Repair')][string]$Action = 'Install',
        [switch]$DryRun,
        # Test-only escape hatch (mirrors CodexLocal.psm1's own -SkipEndpoint on Test-KICodexLocal):
        # skips the real Foundation/Python-Git managed-uv prerequisite check so this function's
        # own Install/Upgrade/Repair/Skip/Backup/Rollback reconciliation logic can be tested
        # without a real managed Python tree on disk. Never used by any real caller -- a real
        # Install/Upgrade/Repair always requires the real, real managed uv to be present.
        [switch]$SkipUvCheck
    )
    $config = Get-KIOpenTerminalConfig -PackageRoot $PackageRoot
    if ([string]::IsNullOrWhiteSpace($TargetRoot)) { $TargetRoot = [string]$config.targetRoot }
    $paths = Get-KIOpenTerminalPaths -TargetRoot $TargetRoot
    if ($DryRun) { return [pscustomobject]@{ passed = $true; status = 'DryRun'; action = $Action; plan = [pscustomobject]@{ moduleRoot = $paths.moduleRoot; stateRoot = $paths.stateRoot }; mutatesTarget = $false } }

    $existing = Test-KIOpenTerminal -PackageRoot $PackageRoot -TargetRoot $TargetRoot -SkipUvCheck:$SkipUvCheck
    if ($existing.passed) { return [pscustomobject]@{ passed = $true; status = 'SkippedAlreadyCompliant'; action = $Action; marker = (Read-KIOpenTerminalJson $paths.marker); mutatesTarget = $false } }

    # Fail closed, and fail BEFORE touching anything on disk, when the one real external
    # prerequisite (Foundation/Python-Git's own managed uv) is missing -- never a half-installed
    # component, never a second, independent uv/Python installation.
    if (-not $SkipUvCheck) { Assert-KIOpenTerminalManagedUv -TargetRoot $TargetRoot | Out-Null }

    New-KIOpenTerminalDirectory $paths.moduleRoot
    New-KIOpenTerminalDirectory $paths.stateRoot
    New-KIOpenTerminalDirectory $paths.workspace
    $backupRoot = Join-Path $TargetRoot ('backups/open-terminal/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff'))
    New-KIOpenTerminalDirectory $backupRoot
    $items = @()
    foreach ($definition in @(
        @{ path = $paths.marker; name = 'installation.json' }, @{ path = $paths.starter; name = 'Start-KIStack-OpenTerminal.cmd' },
        @{ path = $paths.stopper; name = 'Stop-KIStack-OpenTerminal.cmd' }
    )) { $items += @(Copy-KIOpenTerminalBackupItem -Path $definition.path -BackupRoot $backupRoot -Name $definition.name) }
    $backupPath = Join-Path $backupRoot 'rollback.json'
    Write-KIOpenTerminalJson $backupPath ([ordered]@{ schemaVersion = '1.0'; createdAtUtc = [DateTime]::UtcNow.ToString('o'); targetRoot = $TargetRoot; items = $items })

    try {
        $invokeScript = Join-Path $PackageRoot 'Invoke-KIStackOpenTerminal.ps1'
        [IO.File]::WriteAllText($paths.starter, (Get-KIOpenTerminalStarterScriptContent -InvokeScriptPath $invokeScript -TargetRoot $TargetRoot -Action 'Start'), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($paths.stopper, (Get-KIOpenTerminalStarterScriptContent -InvokeScriptPath $invokeScript -TargetRoot $TargetRoot -Action 'Stop'), [Text.UTF8Encoding]::new($false))
        # First setup creates the persistent API key exactly once; Upgrade/Repair of an already-
        # keyed target reuses it unchanged (Assert-KIOpenTerminalApiKey never rotates).
        Assert-KIOpenTerminalApiKey -TargetRoot $TargetRoot -Bytes ([int]$config.apiKeyBytes) | Out-Null
        $marker = [ordered]@{ schemaVersion = '1.0'; version = [string]$config.version; host = [string]$config.host; port = [int]$config.port; installedAtUtc = [DateTime]::UtcNow.ToString('o') }
        Write-KIOpenTerminalJson $paths.marker $marker
        $readback = Test-KIOpenTerminal -PackageRoot $PackageRoot -TargetRoot $TargetRoot -SkipUvCheck:$SkipUvCheck
        if (-not $readback.passed) { throw 'Open-Terminal-Readback nach Installation ist fehlgeschlagen.' }
        $resultStatus = switch ($Action) { 'Upgrade' { 'Upgraded' }; 'Repair' { 'Repaired' }; default { 'Installed' } }
        [pscustomobject]@{ passed = $true; status = $resultStatus; action = $Action; marker = $marker; backupPath = $backupPath; readback = $readback; mutatesTarget = $true }
    } catch {
        $rollbackStatus = 'Failed'
        try { $rollback = Restore-KIOpenTerminalBackup -BackupPath $backupPath; $rollbackStatus = [string]$rollback.status } catch {}
        $_.Exception.Data['KIStackRollbackStatus'] = $rollbackStatus
        $_.Exception.Data['KIStackBackupPath'] = $backupPath
        throw
    }
}

function Restore-KIOpenTerminal {
    param([Parameter(Mandatory)][string]$BackupPath, [string]$PackageRoot = $PSScriptRoot, [string]$TargetRoot = 'C:\KI-Stack')
    Restore-KIOpenTerminalBackup -BackupPath $BackupPath
}

Export-ModuleMember -Function *

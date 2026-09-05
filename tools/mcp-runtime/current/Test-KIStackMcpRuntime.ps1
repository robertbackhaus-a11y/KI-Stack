#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$TargetRoot = 'C:\KI-Stack',
    [string]$OpenWebUIEndpoint = 'http://127.0.0.1:8080',
    [string]$OpenWebUIPythonExe = 'C:\KI-Stack\python\venvs\openwebui\Scripts\python.exe',
    # Ad-hoc "collect failure strings" self-test, the same pattern
    # tools/comfyui/current/Test-KIStackComfyUI.ps1 and tools/rag/current/Test-KIStackRAG.ps1
    # already use -- no repo-wide generic per-module validation-gate framework exists yet
    # (Phase 1 research finding). Covers the 13-point Phase-1 validation gate.
    #
    # IMPORTANT (Phase 0 finding, docs/proposals/2.15-mcp-foundation.md): a real Open-WebUI
    # agent test MUST use stream:true. A test that sends stream:false and then finds the tool
    # never got called is not a MCP-Runtime defect -- OpenWebUI's own non_streaming_chat_
    # response_handler does not run the tool-execution loop at all for ANY tool type in that
    # mode. Point 12 below sends stream:true explicitly, for exactly this reason.
    [switch]$SkipCleanup
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'McpRuntime.psm1') -Force

$failures = [Collections.Generic.List[string]]::new()
$checks = [Collections.Generic.List[object]]::new()
function Add-KIMcpRuntimeCheck {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    [void]$checks.Add([pscustomobject]@{ name = $Name; passed = $Passed; detail = $Detail })
    if (-not $Passed) { [void]$failures.Add("$Name : $Detail") }
    Write-Host ("[{0}] {1} - {2}" -f $(if ($Passed) { 'OK' } else { 'FAIL' }), $Name, $Detail)
}

$testFilePath = $null
$testProcessId = $null

try {
    # 1. MCP-Server laeuft (Start, idempotent)
    $startResult = Start-KIMcpRuntime -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot
    Add-KIMcpRuntimeCheck 'MCP-Server startet/laeuft' ([bool]$startResult.passed) "status=$($startResult.status) endpoint=$($startResult.endpoint)"

    # 2. Health Check erfolgreich
    $credential = Get-KIMcpRuntimeCredential -TargetRoot $TargetRoot
    $config = Get-KIMcpRuntimeConfig -PackageRoot $PSScriptRoot
    $health = Test-KIMcpRuntimeHealthy -Config $config -ApiKey $credential.apiKey -OpenWebUIPythonExe $OpenWebUIPythonExe
    Add-KIMcpRuntimeCheck 'Health Check (MCP initialize+list_tools)' ([bool]$health.reachable) "toolCount=$($health.toolCount)"

    # 3. Open WebUI kennt die Connection (Register, dann Status)
    $registerResult = Register-KIMcpRuntimeOpenWebUI -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -OpenWebUIEndpoint $OpenWebUIEndpoint
    Add-KIMcpRuntimeCheck 'Open-WebUI-Registrierung (idempotent)' ([bool]$registerResult.passed) "status=$($registerResult.status)"
    $regStatus = Test-KIMcpRuntimeOpenWebUIRegistration -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -OpenWebUIEndpoint $OpenWebUIEndpoint
    Add-KIMcpRuntimeCheck 'Open WebUI kennt die Connection' ([bool]$regStatus.registered) "toolServerId=$($config.toolServerId)"

    # 4. Tool Discovery erfolgreich (bereits ueber Health-Check-toolCount indirekt belegt, hier explizit erneut pruefen)
    Add-KIMcpRuntimeCheck 'Tool Discovery (>0 Tools gefunden)' ([int]$health.toolCount -gt 0) "toolCount=$($health.toolCount)"

    # 5-11: run_command / Exitcode / write_file / read_file / Prozess starten / get_process_status / kill_process
    # -- ueber einen direkten MCP-Client-Aufruf gegen den gerade gestarteten Server, NICHT ueber
    # OpenWebUI (das ist Punkt 12) -- isoliert die MCP-Runtime-Komponente selbst von der
    # OpenWebUI-Integration, exakt wie Phase-0s Stufe-1/Stufe-2-Trennung.
    $plainKey = ConvertFrom-KIMcpRuntimeSecureStringTransient -Value $credential.apiKey
    $testFilePath = 'validation_gate_test.txt'
    $mcpTestScript = @'
import asyncio, json, sys
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

async def call(session, name, args):
    r = await session.call_tool(name, args)
    text = "".join(c.text for c in r.content if hasattr(c, "text"))
    return json.loads(text) if text.strip().startswith("{") else text

async def main():
    url, key = sys.argv[1], sys.argv[2]
    headers = {"Authorization": f"Bearer {key}"}
    results = {}
    async with streamablehttp_client(url, headers=headers) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            r = await call(session, "run_command", {"command": "echo VALIDATION_GATE_OK", "wait": 5})
            results["run_command"] = r
            results["exit_code"] = r.get("exit_code")
            results["write_file"] = await call(session, "write_file", {"path": "validation_gate_test.txt", "content": "VALIDATION_GATE_FILE_OK"})
            results["read_file"] = await call(session, "read_file", {"path": "validation_gate_test.txt"})
            long_running = await call(session, "run_command", {"command": "ping -n 20 127.0.0.1"})
            results["process_id"] = long_running.get("id")
            results["get_process_status"] = await call(session, "get_process_status", {"process_id": long_running.get("id")})
            results["kill_process"] = await call(session, "kill_process", {"process_id": long_running.get("id")})
    print(json.dumps(results))

asyncio.run(main())
'@
    $tempScript = [IO.Path]::GetTempFileName() + '.py'
    try {
        [IO.File]::WriteAllText($tempScript, $mcpTestScript, [Text.UTF8Encoding]::new($false))
        $mcpOutput = & $OpenWebUIPythonExe $tempScript $health.uri $plainKey 2>&1
        $mcpExit = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        if ($mcpExit -eq 0) {
            $parsed = ($mcpOutput | Select-Object -Last 1) | ConvertFrom-Json
            Add-KIMcpRuntimeCheck 'run_command funktioniert' ($null -ne $parsed.run_command) ''
            Add-KIMcpRuntimeCheck 'Exitcode korrekt (0)' ([int]$parsed.exit_code -eq 0) "exit_code=$($parsed.exit_code)"
            Add-KIMcpRuntimeCheck 'write_file funktioniert' ($null -ne $parsed.write_file) ''
            Add-KIMcpRuntimeCheck 'read_file funktioniert' (([string]$parsed.read_file.content) -match 'VALIDATION_GATE_FILE_OK') ''
            Add-KIMcpRuntimeCheck 'Prozess kann gestartet werden' (-not [string]::IsNullOrWhiteSpace([string]$parsed.process_id)) "process_id=$($parsed.process_id)"
            Add-KIMcpRuntimeCheck 'get_process_status funktioniert' ($null -ne $parsed.get_process_status) ''
            Add-KIMcpRuntimeCheck 'kill_process funktioniert' ([string]$parsed.kill_process.status -eq 'killed') "status=$($parsed.kill_process.status)"
            $testProcessId = [string]$parsed.process_id
        } else {
            foreach ($name in @('run_command funktioniert', 'Exitcode korrekt (0)', 'write_file funktioniert', 'read_file funktioniert', 'Prozess kann gestartet werden', 'get_process_status funktioniert', 'kill_process funktioniert')) {
                Add-KIMcpRuntimeCheck $name $false ("MCP-Testskript fehlgeschlagen: " + ($mcpOutput -join ' '))
            }
        }
    } finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
        $plainKey = $null
    }

    # 12. OpenWebUI-Agententest ausdruecklich mit stream:true (Phase-0-Erkenntnis, siehe Header)
    $adminHeaders = Get-KIMcpRuntimeOpenWebUIAdminHeaders -TargetRoot $TargetRoot
    $profileId = 'mcp-runtime-validation-gate-test'
    $profilePayload = @{
        id = $profileId
        name = 'MCP Runtime Validation Gate Test'
        base_model_id = 'qwen3.6-27b-uncensored-heretic-v2-native-mtp-preserved'
        params = @{ system = 'Test-Profil fuer das MCP-Runtime Validation Gate.'; function_calling = 'native' }
        meta = @{
            description = 'Wegwerf-Testprofil, ausschliesslich fuer das mcp-runtime Validation Gate.'
            capabilities = @{ web_search = $false; image_generation = $false; code_interpreter = $false; memory = $false; file_upload = $false; terminal = $false }
            toolIds = @("server:mcp:$($config.toolServerId)")
            skillIds = @(); functionIds = @()
        }
        access_grants = @(); is_active = $true
    } | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri "$OpenWebUIEndpoint/api/v1/models/create" -Method Post -Headers $adminHeaders -Body $profilePayload -TimeoutSec 15 | Out-Null

    $chatPayload = @{ chat = @{ title = 'mcp-runtime-validation-gate'; models = @($profileId); messages = @(); history = @{ messages = @{}; currentId = $null } } } | ConvertTo-Json -Depth 10
    $chat = Invoke-RestMethod -Uri "$OpenWebUIEndpoint/api/v1/chats/new" -Method Post -Headers $adminHeaders -Body $chatPayload -TimeoutSec 15
    $userMsgId = [guid]::NewGuid().ToString(); $assistantMsgId = [guid]::NewGuid().ToString()
    $chatCompletionBody = @{
        model = $profileId; chat_id = $chat.id; session_id = 'validation-gate-session'; parent_id = $null; id = $assistantMsgId
        stream = $true  # MUST be true -- see header comment
        background_tasks = @{ title_generation = $false; tags_generation = $false; follow_up_generation = $false }
        features = @{}; tool_ids = @("server:mcp:$($config.toolServerId)")
        user_message = @{ id = $userMsgId; role = 'user'; content = "Fuehre 'echo VALIDATION_GATE_AGENT_OK' aus und nenne den Exitcode." }
        messages = @(@{ id = $userMsgId; role = 'user'; content = "Fuehre 'echo VALIDATION_GATE_AGENT_OK' aus und nenne den Exitcode." })
    } | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri "$OpenWebUIEndpoint/api/chat/completions" -Method Post -Headers $adminHeaders -Body $chatCompletionBody -TimeoutSec 30 | Out-Null

    $agentDone = $false
    for ($i = 0; $i -lt 24; $i++) {
        Start-Sleep -Seconds 5
        $chatState = Invoke-RestMethod -Uri "$OpenWebUIEndpoint/api/v1/chats/$($chat.id)" -Headers $adminHeaders -TimeoutSec 15
        $assistantMessage = $chatState.chat.history.messages.$assistantMsgId
        if ($null -ne $assistantMessage -and [bool]$assistantMessage.done) { $agentDone = $true; break }
    }
    Add-KIMcpRuntimeCheck 'OpenWebUI-Agententest (stream:true) abgeschlossen' $agentDone "chat_id=$($chat.id)"

    if (-not $SkipCleanup) {
        Invoke-RestMethod -Uri "$OpenWebUIEndpoint/api/v1/chats/$($chat.id)" -Method Delete -Headers $adminHeaders -TimeoutSec 15 -ErrorAction SilentlyContinue | Out-Null
        Invoke-RestMethod -Uri "$OpenWebUIEndpoint/api/v1/models/model/delete" -Method Post -Headers $adminHeaders -Body (@{ id = $profileId } | ConvertTo-Json) -TimeoutSec 15 -ErrorAction SilentlyContinue | Out-Null
    }
} finally {
    # 13. Cleanup hinterlaesst keinen zusaetzlichen Prozess und keine Testdateien
    if (-not $SkipCleanup) {
        try { Unregister-KIMcpRuntimeOpenWebUI -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot -OpenWebUIEndpoint $OpenWebUIEndpoint | Out-Null } catch {}
        try { Stop-KIMcpRuntime -PackageRoot $PSScriptRoot -TargetRoot $TargetRoot | Out-Null } catch {}
        $paths = Get-KIMcpRuntimePaths -TargetRoot $TargetRoot
        if ($testFilePath -and (Test-Path -LiteralPath (Join-Path $paths.workspace $testFilePath))) {
            Remove-Item -LiteralPath (Join-Path $paths.workspace $testFilePath) -Force -ErrorAction SilentlyContinue
        }
        $cleanupOk = -not (Get-Command Get-KIMcpRuntimeTrackedProcessId -ErrorAction SilentlyContinue | ForEach-Object {
            $c = Get-KIMcpRuntimeConfig -PackageRoot $PSScriptRoot
            [bool](Get-KIMcpRuntimeTrackedProcessId -Paths $paths -Config $c)
        })
        Add-KIMcpRuntimeCheck 'Cleanup: kein verwaister Prozess' $cleanupOk ''
    }
}

$result = [pscustomobject]@{
    passed = ($failures.Count -eq 0)
    version = (Get-Content (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
    checks = $checks
    failures = @($failures)
}
$result | ConvertTo-Json -Depth 20
if (-not $result.passed) { exit 1 }

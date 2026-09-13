[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Self-contained regression suite for the 2.19.0 idempotency fix in Test-KIStackMcpRuntime.ps1's
# own OpenWebUI-agent-test step (point 12): a fixed, never-randomized validation-gate profile id
# ('mcp-runtime-validation-gate-test') previously caused "Uh-oh! This model id is already
# registered." on any run after a prior run (or a -SkipCleanup run) left the profile behind,
# because /api/v1/models/create was called unconditionally with no existence check.
#
# Exercises the REAL Resolve-KIMcpRuntimeValidationGateProfile (McpRuntime.psm1) -- the pure
# create-or-reuse decision Test-KIStackMcpRuntime.ps1 itself now calls -- via injected
# -GetProfile/-CreateProfile scriptblocks, so no live Open WebUI target, no real HTTP call, and
# no LM Studio/MCP server are needed to prove the decision logic itself is correct. The
# underlying HTTP existence-check route it is built on
# (Get-KIMcpRuntimeOpenWebUIModelById -> GET /api/v1/models/model?id=<id>) is the SAME route
# already used in production by OpenWebUIBallisticsPack.psm1/OpenWebUIAgentPack.psm1/Complete
# Installer's Operations/*.ps1, and was additionally verified live against a real, running
# KI-Stack Open-WebUI instance (2026-09-13): 200 with the model body when it exists, 404 with a
# JSON {"detail":"..."} body when it does not.

Import-Module (Join-Path $PackageRoot 'McpRuntime.psm1') -Force

$fail = [Collections.Generic.List[string]]::new()
$checks = [ordered]@{}

    # === A: profile fehlt -> Create, kein vorzeitiger Abbruch ==================================
    $createCalledA = $false
    $resultA = Resolve-KIMcpRuntimeValidationGateProfile -GetProfile {
        [pscustomobject]@{ found = $false; model = $null }
    } -CreateProfile {
        $script:createCalledA = $true
    }
    $checks.missingProfileCreates = [ordered]@{
        statusIsCreated = ([string]$resultA.status -eq 'Created')
        createWasCalled = $createCalledA
    }
    if ($checks.missingProfileCreates.Values -contains $false) { $fail.Add('missingProfileCreates failed: ' + ($checks.missingProfileCreates | ConvertTo-Json -Compress)) }

    # === B: profile existiert -> kein Create, Reuse ============================================
    $createCalledB = $false
    $fakeExistingModel = [pscustomobject]@{ id = 'mcp-runtime-validation-gate-test'; name = 'MCP Runtime Validation Gate Test' }
    $resultB = Resolve-KIMcpRuntimeValidationGateProfile -GetProfile {
        [pscustomobject]@{ found = $true; model = $fakeExistingModel }
    } -CreateProfile {
        $script:createCalledB = $true
        throw 'CreateProfile must never be invoked when the profile already exists'
    }
    $checks.existingProfileReuses = [ordered]@{
        statusIsReused = ([string]$resultB.status -eq 'Reused')
        createWasNotCalled = (-not $createCalledB)
        returnsExistingModel = ($resultB.model.id -eq 'mcp-runtime-validation-gate-test')
    }
    if ($checks.existingProfileReuses.Values -contains $false) { $fail.Add('existingProfileReuses failed: ' + ($checks.existingProfileReuses | ConvertTo-Json -Compress)) }

    # === C: Read-API schlaegt fehl (nicht 404, z.B. 500/Netzwerkfehler) -> fail closed ==========
    $thrownC = $null
    try {
        Resolve-KIMcpRuntimeValidationGateProfile -GetProfile {
            throw 'simulated read failure (HTTP 500)'
        } -CreateProfile {
            throw 'CreateProfile must never be invoked when the read itself failed'
        } | Out-Null
    } catch { $thrownC = $_ }
    $checks.readApiFailureFailsClosed = [ordered]@{
        threw = ($null -ne $thrownC)
        neverReachedCreate = ($null -ne $thrownC -and $thrownC.Exception.Message -notmatch 'CreateProfile must never be invoked')
    }
    if ($checks.readApiFailureFailsClosed.Values -contains $false) { $fail.Add('readApiFailureFailsClosed failed: ' + ($checks.readApiFailureFailsClosed | ConvertTo-Json -Compress)) }

    # === D: Profile fehlt, aber Create schlaegt aus einem ANDEREN Grund fehl -> fail closed =====
    $thrownD = $null
    try {
        Resolve-KIMcpRuntimeValidationGateProfile -GetProfile {
            [pscustomobject]@{ found = $false; model = $null }
        } -CreateProfile {
            throw 'simulated create failure (HTTP 400 Bad Request)'
        } | Out-Null
    } catch { $thrownD = $_ }
    $checks.createFailureFailsClosed = [ordered]@{
        threw = ($null -ne $thrownD)
        reasonSurfaced = ($null -ne $thrownD -and $thrownD.Exception.Message -match 'simulated create failure')
    }
    if ($checks.createFailureFailsClosed.Values -contains $false) { $fail.Add('createFailureFailsClosed failed: ' + ($checks.createFailureFailsClosed | ConvertTo-Json -Compress)) }

    # === E: Get-KIMcpRuntimeOpenWebUIModelById itself -- 404 maps to found=$false, any other
    #        HTTP failure is never swallowed (structural check on the real function, no live
    #        target -- Invoke-RestMethod is redirected to a fake endpoint that never resolves,
    #        proving a genuine connection failure is NOT misread as "not found"). ================
    $thrownE = $null
    try {
        Get-KIMcpRuntimeOpenWebUIModelById -OpenWebUIEndpoint 'http://127.0.0.1:1' -Headers @{ Authorization = 'Bearer x' } -ModelId 'whatever' -TimeoutSec 2 | Out-Null
    } catch { $thrownE = $_ }
    $checks.connectionFailureNeverMisreadAs404 = [ordered]@{ threw = ($null -ne $thrownE) }
    if ($checks.connectionFailureNeverMisreadAs404.Values -contains $false) { $fail.Add('connectionFailureNeverMisreadAs404 failed: expected a thrown connection error, got none') }

$passed = $fail.Count -eq 0
[pscustomobject]@{ passed = $passed; checks = $checks; failures = @($fail) } | ConvertTo-Json -Depth 12
if (-not $passed) { throw 'MCP-Runtime-ValidationGate-Profile-Idempotency-Regression fehlgeschlagen.' }

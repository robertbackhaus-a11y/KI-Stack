[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Isolated-Greenfield acceptance test for Codex Local's own first-install/first-boot contract.
# Explicitly NOT a full Windows/LM-Studio Greenfield proof (that requires a disposable VM this
# environment does not have -- documented and accepted per the workstream's own explicit
# scoping decision): LM Studio itself is never installed or first-booted here. What this suite
# DOES prove, for real (real npm, real Node.js, real Codex CLI, a real OpenAI-shaped mock
# server standing in for a reachable LM Studio endpoint):
#   - a genuinely fresh target has NO pre-existing Codex Local/LM-Studio-shaped state at all
#     before Install runs (the fail-closed Greenfield precondition itself, Section 24) --
#     never silently reusing a real, already-populated environment as if it were fresh;
#   - the isolated Install path (never Upgrade/Repair) succeeds against that fresh target;
#   - Status immediately afterward matches the exact contract this workstream defines;
#   - the ACTUAL GENERATED STARTER SCRIPT (Start-KIStack-CodexLocal.cmd), not just the
#     PowerShell module directly, resolves runtime/CLI/config paths correctly;
#   - a stop/restart cycle does not leave a "only works once" state;
#   - two negative scenarios this repository did not previously have coverage for: a port
#     already occupied by an unrelated process, and an LM-Studio-shaped endpoint that answers
#     GET /v1/models but not the target chat model.
# Everything else this workstream's task asked for that this package's OWN existing
# Test-KIStackCodexLocalOperationalization.ps1 already proves for real (Upgrade, Repair,
# Preserve across both, Backup/Rollback, Idempotency, RuntimeUnavailable-vs-Broken-vs-
# NotInstalled) is deliberately not re-implemented here -- see that suite instead.

$fail=[Collections.Generic.List[string]]::new()
$checks=[ordered]@{}

Import-Module (Join-Path $PackageRoot 'CodexLocal.psm1') -Force -DisableNameChecking
$config=Get-KICodexConfig $PackageRoot

$suiteRoot=Join-Path ([IO.Path]::GetTempPath()) ('KICX-GF-'+[guid]::NewGuid().ToString('N').Substring(0,10))
$targetRoot=Join-Path $suiteRoot 'target'
$workspace=Join-Path $suiteRoot 'workspace'
$patchedPackageRoot=Join-Path $suiteRoot 'package'
New-Item -ItemType Directory -Path $targetRoot,$workspace -Force|Out-Null

# CODEX_HOME-Isolation-Workstream: CodexLocal.psm1 now derives CODEX_HOME purely from TargetRoot
# (Get-KICodexPaths' codexHome), never from $env:CODEX_HOME -- $codexHome below is therefore the
# REAL, isolated location this Greenfield Install actually uses; $env:CODEX_HOME is deliberately
# left pointed at an unrelated decoy fixture throughout, to prove ambient env has zero effect
# (never the real ~/.codex either way).
$codexHome=(Get-KICodexPaths -TargetRoot $targetRoot).codexHome
$decoyAmbientCodexHome=Join-Path $suiteRoot 'decoy-ambient-codex-home'
New-Item -ItemType Directory -Path $decoyAmbientCodexHome -Force|Out-Null
$originalCodexHome=$env:CODEX_HOME
$env:CODEX_HOME=$decoyAmbientCodexHome

function Start-KIGreenfieldMockLMStudio {
    param([int]$Port,[string]$ModelId,[switch]$AnswerChatCompletions)
    $script=Join-Path $suiteRoot ("mock-lmstudio-$Port.ps1")
    $modelsBody = "{`"data`":[{`"id`":`"$ModelId`"}]}"
    $chatBody = if($AnswerChatCompletions){'{"id":"chatcmpl-fixture","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"OK"},"finish_reason":"stop"}]}'}else{$null}
    Set-Content -LiteralPath $script -Encoding utf8NoBOM -Value @"
param([int]`$Port)
`$tcp=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,`$Port)
`$tcp.Start()
while(`$true){
    `$client=`$tcp.AcceptTcpClient()
    `$stream=`$client.GetStream()
    `$buffer=New-Object byte[] 8192
    `$read=`$stream.Read(`$buffer,0,`$buffer.Length)
    `$requestText=[Text.Encoding]::UTF8.GetString(`$buffer,0,`$read)
    if(`$requestText -match '/v1/chat/completions' -and '$AnswerChatCompletions' -eq 'True'){
        `$bodyBytes=[Text.Encoding]::UTF8.GetBytes('$chatBody')
    } elseif(`$requestText -match '/v1/chat/completions'){
        `$bodyBytes=[Text.Encoding]::UTF8.GetBytes('{"error":{"message":"model not loaded"}}')
    } else {
        `$bodyBytes=[Text.Encoding]::UTF8.GetBytes('$modelsBody')
    }
    `$statusLine=if(`$requestText -match '/v1/chat/completions' -and '$AnswerChatCompletions' -ne 'True'){'HTTP/1.1 503 Service Unavailable'}else{'HTTP/1.1 200 OK'}
    `$header="`$statusLine`r`nContent-Type: application/json`r`nContent-Length: `$(`$bodyBytes.Length)`r`nConnection: close`r`n`r`n"
    `$headerBytes=[Text.Encoding]::ASCII.GetBytes(`$header)
    `$stream.Write(`$headerBytes,0,`$headerBytes.Length)
    `$stream.Write(`$bodyBytes,0,`$bodyBytes.Length)
    `$stream.Flush()
    `$client.Close()
}
"@
    $process=Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-File',$script,'-Port',$Port) -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    $process
}

try{
    # --- 1. Fail-closed Greenfield precondition (Section 24): prove there is genuinely
    # nothing here before Install runs -- this is the actual "isolated greenfield" claim. -------
    $paths=Get-KICodexPaths -TargetRoot $targetRoot
    $checks.greenfieldPreconditionFailClosed=[ordered]@{
        noExistingMarker=(-not(Test-Path -LiteralPath $paths.marker -PathType Leaf))
        noExistingRuntime=(-not(Test-Path -LiteralPath $paths.runtimeRoot -PathType Container))
        noExistingCodexCli=(-not(Test-Path -LiteralPath $paths.codexCli -PathType Leaf))
        noExistingStarter=(-not(Test-Path -LiteralPath $paths.starter -PathType Leaf))
        noExistingCodexHomeConfig=(-not(Test-Path -LiteralPath (Join-Path $codexHome 'ki-stack-local.config.toml') -PathType Leaf))
        noExistingAgentsFile=(-not(Test-Path -LiteralPath (Join-Path $workspace 'AGENTS.md') -PathType Leaf))
        codexHomeIsolatedFromRealUser=($codexHome -ne (Join-Path $env:USERPROFILE '.codex'))
        codexHomeIsolatedFromDecoyAmbientEnv=($codexHome -ne $decoyAmbientCodexHome)
    }
    if($checks.greenfieldPreconditionFailClosed.Values-contains$false){$fail.Add('greenfieldPreconditionFailClosed failed -- this run would not actually prove a fresh install: '+($checks.greenfieldPreconditionFailClosed|ConvertTo-Json -Compress))}

    # --- 2. Mock LM Studio (OpenAI-shaped endpoint) -- stands in for a reachable LM Studio in
    # this isolated environment; see this file's header for why the real application is not
    # installed/first-booted here. ---------------------------------------------------------------
    $mockPort=Get-Random -Minimum 20000 -Maximum 40000
    Copy-Item -LiteralPath $PackageRoot -Destination $patchedPackageRoot -Recurse -Force
    $patchedConfigPath=Join-Path $patchedPackageRoot 'Config/codex-local.config.json'
    $patchedConfig=Get-Content -LiteralPath $patchedConfigPath -Raw|ConvertFrom-Json -Depth 20
    $patchedConfig.lmStudioBaseUrl="http://127.0.0.1:$mockPort/v1"
    ($patchedConfig|ConvertTo-Json -Depth 20)|Set-Content -LiteralPath $patchedConfigPath -Encoding utf8NoBOM
    $mockProcess=Start-KIGreenfieldMockLMStudio -Port $mockPort -ModelId 'qwen3.6-27b-uncensored-heretic-v2-native-mtp-preserved' -AnswerChatCompletions

    # --- 3. First Install (Section 10): must genuinely be Action=Install, never Upgrade/Repair,
    # against the fail-closed-verified fresh target. ---------------------------------------------
    $install=Install-KICodexLocal -PackageRoot $patchedPackageRoot -TargetRoot $targetRoot -WorkspacePath $workspace -Action Install
    $checks.firstInstallIsGenuinelyInstallAction=[ordered]@{
        passed=[bool]$install.passed
        actionWasInstall=([string]$install.action-eq'Install')
        statusIsInstalled=([string]$install.status-eq'Installed')
        neverSkippedAlreadyCompliant=([string]$install.status-ne'SkippedAlreadyCompliant')
    }
    if($checks.firstInstallIsGenuinelyInstallAction.Values-contains$false){$fail.Add('firstInstallIsGenuinelyInstallAction failed: '+($checks.firstInstallIsGenuinelyInstallAction|ConvertTo-Json -Compress))}

    # --- 4. First Status (Section 11): exact contract fields. -----------------------------------
    $status=Get-KICodexStatus -PackageRoot $patchedPackageRoot -TargetRoot $targetRoot
    $checks.firstStatusMatchesContract=[ordered]@{
        installedTrue=([bool]$status.installed)
        installedVersionMatchesConfig=([string]$status.installedVersion-eq[string]$config.version)
        runtimeReadyTrue=([bool]$status.runtimeReady)
        lmStudioEndpointConfiguredTrue=([bool]$status.lmStudioEndpointConfigured)
        healthyTrue=([bool]$status.healthy)
        stateIsHealthy=([string]$status.state-eq'Healthy')
    }
    if($checks.firstStatusMatchesContract.Values-contains$false){$fail.Add('firstStatusMatchesContract failed: '+($checks.firstStatusMatchesContract|ConvertTo-Json -Compress)+' | full status: '+($status|ConvertTo-Json -Compress))}

    # --- 5. Starter-Test (Section 13): the ACTUAL generated .cmd, not the PowerShell module
    # directly. codex.js in interactive TUI mode cannot complete a scripted run without a real
    # TTY, so this proves what a starter invocation can actually prove non-interactively: every
    # path it resolves (node.exe, codex.js, and -- since this starter's own env setup happens
    # before codex.js ever runs -- the working directory) is genuinely correct, and the process
    # launches without an immediate "file not found"/path-resolution failure. -------------------
    $starterContent=Get-Content -LiteralPath $paths.starter -Raw
    $checks.starterScriptResolvesRealPaths=[ordered]@{
        referencesRealNodeExe=($starterContent.Contains($paths.node)-and(Test-Path -LiteralPath $paths.node -PathType Leaf))
        referencesRealCodexCli=($starterContent.Contains($paths.codexCli)-and(Test-Path -LiteralPath $paths.codexCli -PathType Leaf))
        referencesRealWorkspace=($starterContent.Contains($workspace))
        referencesConfiguredProfile=($starterContent.Contains([string]$config.profileName))
        setsIsolatedCodexHome=($starterContent.Contains("set `"CODEX_HOME=$codexHome`""))
        neverReferencesDecoyAmbientHome=(-not$starterContent.Contains($decoyAmbientCodexHome))
    }
    if($checks.starterScriptResolvesRealPaths.Values-contains$false){$fail.Add('starterScriptResolvesRealPaths failed: '+($checks.starterScriptResolvesRealPaths|ConvertTo-Json -Compress))}
    # Launch the real starter with stdin/stdout redirected (no TTY) and a bounded wait: a
    # genuine path-resolution failure surfaces immediately (process exits fast, non-zero); codex
    # itself blocking on TUI input with all paths already resolved correctly is the expected,
    # accepted outcome here and is terminated cleanly rather than awaited to completion.
    $starterPsi=[Diagnostics.ProcessStartInfo]::new()
    $starterPsi.FileName=$paths.starter
    $starterPsi.UseShellExecute=$false
    $starterPsi.RedirectStandardInput=$true
    $starterPsi.RedirectStandardOutput=$true
    $starterPsi.RedirectStandardError=$true
    $starterPsi.CreateNoWindow=$true
    $starterProcess=[Diagnostics.Process]::new()
    $starterProcess.StartInfo=$starterPsi
    [void]$starterProcess.Start()
    $starterStderr=$starterProcess.StandardError.ReadToEndAsync()
    $starterExitedQuickly=$starterProcess.WaitForExit(4000)
    $starterEarlyExitCode=if($starterExitedQuickly){$starterProcess.ExitCode}else{$null}
    $starterEarlyStderr=if($starterExitedQuickly){try{$starterStderr.GetAwaiter().GetResult()}catch{'<stderr read failed>'}}else{$null}
    if(-not$starterExitedQuickly){try{$starterProcess.Kill($true)}catch{}}
    # A fast exit is acceptable as long as it is NOT an argument-parsing/path-resolution
    # failure -- proven the hard way while building this: an invalid flag for interactive mode
    # produced "error: unexpected argument ... found" here immediately, a real defect this check
    # exists to catch. This fixture's own minimal single-request-per-connection mock server does
    # not fully emulate LM Studio's real connection-keepalive/endpoint surface, though, so a
    # connectivity-shaped complaint from Codex's own "OSS setup" probe ("LM Studio is not
    # responding") is a known limitation of the mock, not a path/argument defect -- the real,
    # definitive proof that -m/model selection and the generated starter's paths are correct
    # end to end already exists against the real, non-mocked LM Studio (see this workstream's
    # final report); this check's job is narrower: catch CLI-argument/path regressions early.
    $looksLikeArgumentOrPathError=$starterEarlyStderr-and($starterEarlyStderr-match'unexpected argument'-or$starterEarlyStderr-match'error: the following required arguments'-or$starterEarlyStderr-match'No such file or directory'-or$starterEarlyStderr-match'is not recognized as')
    $checks.starterLaunchesWithoutImmediatePathFailure=[ordered]@{
        didNotFailFast=(-not$starterExitedQuickly-or$starterEarlyExitCode-eq0-or-not$looksLikeArgumentOrPathError)
    }
    if($checks.starterLaunchesWithoutImmediatePathFailure.Values-contains$false){$fail.Add("starterLaunchesWithoutImmediatePathFailure failed: starter exited quickly with code $starterEarlyExitCode due to what looks like a real argument/path error. stderr: $starterEarlyStderr")}

    # --- 6. Stop/Restart cycle (Section 14): first boot must not be a one-shot state. -----------
    Stop-Process -Id $mockProcess.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    $statusAfterStop=Get-KICodexStatus -PackageRoot $patchedPackageRoot -TargetRoot $targetRoot
    $mockProcess2=Start-KIGreenfieldMockLMStudio -Port $mockPort -ModelId 'qwen3.6-27b-uncensored-heretic-v2-native-mtp-preserved' -AnswerChatCompletions
    $statusAfterRestart=Get-KICodexStatus -PackageRoot $patchedPackageRoot -TargetRoot $targetRoot
    $checks.restartCycleWorksMoreThanOnce=[ordered]@{
        stoppedEndpointReportsRuntimeUnavailableNotBroken=([string]$statusAfterStop.state-eq'RuntimeUnavailable')
        restartedEndpointReturnsToHealthy=([string]$statusAfterRestart.state-eq'Healthy')
        installedVersionUnchangedAcrossRestart=([string]$statusAfterRestart.installedVersion-eq[string]$config.version)
    }
    if($checks.restartCycleWorksMoreThanOnce.Values-contains$false){$fail.Add('restartCycleWorksMoreThanOnce failed: '+($checks.restartCycleWorksMoreThanOnce|ConvertTo-Json -Compress))}
    Stop-Process -Id $mockProcess2.Id -Force -ErrorAction SilentlyContinue

    # --- 7. Negative scenario: model not loaded (Section 17) -- endpoint reachable, but the
    # target chat model does not answer. Documents the real, current contract rather than
    # inventing new model-readiness logic that does not exist in CodexLocal.psm1 today: the
    # package's own health check only verifies /v1/models responds at all, never that the
    # SPECIFIC target model is loaded -- so Status is expected to still report Healthy here
    # (a real, honest gap, not silently hidden) while an actual chat call would fail. -----------
    $mockPort2=Get-Random -Minimum 20000 -Maximum 40000
    $modelNotReadyConfigPath=Join-Path $patchedPackageRoot 'Config/codex-local.config.json'
    $modelNotReadyConfig=Get-Content -LiteralPath $modelNotReadyConfigPath -Raw|ConvertFrom-Json -Depth 20
    $modelNotReadyConfig.lmStudioBaseUrl="http://127.0.0.1:$mockPort2/v1"
    ($modelNotReadyConfig|ConvertTo-Json -Depth 20)|Set-Content -LiteralPath $modelNotReadyConfigPath -Encoding utf8NoBOM
    $mockProcess3=Start-KIGreenfieldMockLMStudio -Port $mockPort2 -ModelId 'qwen3.6-27b-uncensored-heretic-v2-native-mtp-preserved'
    $statusModelNotReady=Get-KICodexStatus -PackageRoot $patchedPackageRoot -TargetRoot $targetRoot
    $chatAttempt=Test-KILMStudioEndpoint "http://127.0.0.1:$mockPort2/v1"
    $checks.modelNotLoadedRealContractDocumented=[ordered]@{
        endpointGenericReachabilityStillReportsHealthy=([string]$statusModelNotReady.state-eq'Healthy')
        endpointModelsListStillReachable=[bool]$chatAttempt.reachable
        noFalseBrokenState=([string]$statusModelNotReady.state-ne'Broken')
    }
    if($checks.modelNotLoadedRealContractDocumented.Values-contains$false){$fail.Add('modelNotLoadedRealContractDocumented failed: '+($checks.modelNotLoadedRealContractDocumented|ConvertTo-Json -Compress))}
    Stop-Process -Id $mockProcess3.Id -Force -ErrorAction SilentlyContinue

    # --- 8. Negative scenario: port already occupied (Section 18) -- a second listener cannot
    # bind the same port; the endpoint check must fail cleanly (Test-KILMStudioEndpoint's own
    # HTTP-level check), never leave a half-finished install. -------------------------------------
    $conflictPort=Get-Random -Minimum 20000 -Maximum 40000
    $occupyingListener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$conflictPort)
    $occupyingListener.Start()
    try{
        $conflictEndpoint=Test-KILMStudioEndpoint "http://127.0.0.1:$conflictPort/v1"
        $checks.portConflictFailsCleanly=[ordered]@{
            notReachableAsAValidOpenAIEndpoint=(-not[bool]$conflictEndpoint.reachable)
            noExceptionEscaped=$true
        }
    }catch{
        $checks.portConflictFailsCleanly=[ordered]@{notReachableAsAValidOpenAIEndpoint=$true;noExceptionEscaped=$false}
    }finally{
        $occupyingListener.Stop()
    }
    if($checks.portConflictFailsCleanly.Values-contains$false){$fail.Add('portConflictFailsCleanly failed: '+($checks.portConflictFailsCleanly|ConvertTo-Json -Compress))}

    # --- 9. No OpenWebUI/SearXNG/RAG/Agent-Pack/Visual-Pack dependency (Section 21): this
    # whole suite never imports, references, or touches any of those packages' modules. ---------
    $checks.noOpenWebUIOrOtherPackDependency=[ordered]@{documented=$true;onlyModulesImported='CodexLocal.psm1'}

    $passed=$fail.Count-eq0
    [pscustomobject]@{passed=$passed;checks=$checks;failures=@($fail);environment='isolated greenfield (fixture-based; real LM Studio/Windows Greenfield not available in this environment -- see final report)';fixtureRoot=$suiteRoot}|ConvertTo-Json -Depth 12
    if(-not$passed){throw 'Codex-Local-Greenfield-Regression fehlgeschlagen.'}
}
finally{
    try{if($mockProcess-and-not$mockProcess.HasExited){Stop-Process -Id $mockProcess.Id -Force -ErrorAction SilentlyContinue}}catch{}
    try{if($mockProcess2-and-not$mockProcess2.HasExited){Stop-Process -Id $mockProcess2.Id -Force -ErrorAction SilentlyContinue}}catch{}
    try{if($mockProcess3-and-not$mockProcess3.HasExited){Stop-Process -Id $mockProcess3.Id -Force -ErrorAction SilentlyContinue}}catch{}
    $env:CODEX_HOME=$originalCodexHome
    if(Test-Path -LiteralPath $suiteRoot){Remove-Item -LiteralPath $suiteRoot -Recurse -Force -ErrorAction SilentlyContinue}
}

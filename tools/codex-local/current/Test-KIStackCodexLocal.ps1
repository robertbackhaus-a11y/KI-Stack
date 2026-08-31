#Requires -Version 7.0
[CmdletBinding()]param([string]$PackageRoot=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$failures=[Collections.Generic.List[string]]::new()
$required=@('VERSION','Config/codex-local.config.json','Templates/AGENTS.md','CodexLocal.psm1','Invoke-KIStackCodexLocal.ps1','MANIFEST.json','SHA256SUMS.txt')
foreach($path in $required){
    if(-not(Test-Path -LiteralPath (Join-Path $PackageRoot $path) -PathType Leaf)){$failures.Add("Fehlt: $path")}
}
$config=Get-Content -LiteralPath (Join-Path $PackageRoot 'Config/codex-local.config.json') -Raw|ConvertFrom-Json
$version=(Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim()
if($version-ne'0.2.1'-or$config.version-ne$version){$failures.Add('Versionsvertrag inkonsistent.')}
if($config.codexPackage-ne'@openai/codex'-or$config.codexVersion-ne'0.145.0'){$failures.Add('Codex-Paketvertrag inkonsistent.')}
if($config.localProvider-ne'lmstudio'){$failures.Add('LM-Studio-Providervertrag fehlt.')}
if($config.sandboxMode-ne'workspace-write'){$failures.Add('Workspace-write-Vertrag fehlt.')}
# Real Greenfield finding (Codex-Local-Greenfield-Workstream): --oss mode with no explicit
# model resolves to Codex's own built-in default OSS model, not whatever LM Studio happens to
# have loaded -- reproduced live as an unwanted ~12GB download of an unrelated model. chatModel
# must match Contracts/PAYLOADS.json's modelPolicy.chatModels[0] exactly -- never a second,
# independently-chosen model name.
if([string]::IsNullOrWhiteSpace([string]$config.chatModel)){$failures.Add('Chat-Modell-Vertrag fehlt (verhindert ungewollten Auto-Download eines falschen Modells).')}
$payloadsContractPath=Join-Path $PackageRoot '../../complete-installer/current/Contracts/PAYLOADS.json'
if(Test-Path -LiteralPath $payloadsContractPath -PathType Leaf){
    $payloadsContract=Get-Content -LiteralPath $payloadsContractPath -Raw|ConvertFrom-Json -Depth 20
    $authoritativeChatModel=[string]@($payloadsContract.modelPolicy.chatModels)[0]
    if([string]$config.chatModel-ne$authoritativeChatModel){$failures.Add("Chat-Modell weicht vom Complete-Installer-Vertrag ab: '$($config.chatModel)' <> '$authoritativeChatModel'.")}
}
# The configured workspace (a deployed KI-Stack target) is deliberately never a git repository,
# so codex's default "not inside a trusted directory" refusal would otherwise block every real
# invocation -- reproduced live, fixed via an explicit --skip-git-repo-check.
if(-not[bool]$config.skipGitRepoCheck){$failures.Add('skipGitRepoCheck-Vertrag fehlt (Zielarbeitsbereich ist absichtlich kein Git-Repository).')}
# Real Architekturfund (CODEX_HOME-Isolation-Workstream): Codex Local darf standardmäßig nicht
# mehr das mit jeder anderen realen Codex-CLI-Nutzung geteilte %USERPROFILE%\.codex verwenden --
# reproduziert live als eigentliche Ursache eines wiederkehrenden Fehl-Downloads, den die -m-
# Korrektur allein nicht zuverlässig verhinderte. codexHome muss innerhalb des bestehenden
# Codex-Local-State-Bereichs liegen (keine neue globale User-Hierarchie).
$expectedCodexHome=Join-Path ([string]$config.stateRoot) 'codex-home'
if([string]::IsNullOrWhiteSpace([string]$config.codexHome)){$failures.Add('codexHome-Vertrag fehlt (verhindert Rückfall auf das geteilte %USERPROFILE%\.codex).')}
elseif([string]$config.codexHome-ne$expectedCodexHome){$failures.Add("codexHome liegt nicht im bestehenden Codex-Local-State-Bereich: '$([string]$config.codexHome)' <> '$expectedCodexHome'.")}
if($config.nodeRuntime.version-ne'24.14.0'){$failures.Add('Node.js-Versionsvertrag fehlt.')}
if($config.nodeRuntime.url-ne'https://nodejs.org/dist/v24.14.0/node-v24.14.0-win-x64.zip'){$failures.Add('Offizielle Node.js-Quelle fehlt.')}
if([long]$config.nodeRuntime.sizeBytes-ne36217529){$failures.Add('Node.js-Größenvertrag fehlt.')}
if($config.nodeRuntime.sha256-ne'313fa40c0d7b18575821de8cb17483031fe07d95de5994f6f435f3b345f85c66'){$failures.Add('Node.js-SHA256-Vertrag fehlt.')}

$modulePath=Join-Path $PackageRoot 'CodexLocal.psm1'
$module=[IO.File]::ReadAllText($modulePath)
foreach($marker in @(
    'New-KICodexDirectory $paths.moduleRoot',
    'node_modules/npm/bin/npm-cli.js',
    'node_modules/@openai/codex/bin/codex.js',
    'Invoke-KIManagedNodeScript',
    'Test-KINodeArchiveContract',
    'Restore-KICodexBackup',
    "KIStackRollbackStatus",
    "secondRunReused",
    'Ensure-KILMStudioEndpointReachable',
    'modules/applications/Start-KIStack-LMStudio.cmd',
    '--skip-git-repo-check',
    'RedirectStandardInput',
    'StandardInput.Close()',
    'codexHome=Join-Path $stateRoot ''codex-home''',
    'Get-KICodexStarterScriptContent',
    "psi.Environment['CODEX_HOME']",
    '-CodexHome $paths.codexHome'
)){
    if(-not$module.Contains($marker)){$failures.Add("Codex-Ausführungsvertrag fehlt: $marker")}
}
foreach($forbidden in @('npm-global/codex.cmd','runtime/npm.cmd','PathSeparator+$originalPath','Get-Command node','Get-Command npm','Get-Command codex',"if([string]::IsNullOrWhiteSpace(`$env:CODEX_HOME)){Join-Path `$env:USERPROFILE '.codex'}")){
    if($module.Contains($forbidden)){$failures.Add("Globaler Runtime-Fallback gefunden: $forbidden")}
}

Import-Module $modulePath -Force
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('KICX-S-'+[guid]::NewGuid().ToString('N').Substring(0,8))
try{
    New-Item -ItemType Directory -Path $fixtureRoot -Force|Out-Null
    $fixture=Join-Path $fixtureRoot 'fixture.bin'
    [IO.File]::WriteAllBytes($fixture,[byte[]](1,2,3,4))
    $fixtureHash=(Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash.ToLowerInvariant()
    $contract=[pscustomobject]@{sizeBytes=4;sha256=$fixtureHash}
    if(-not(Test-KINodeArchiveContract -ArchivePath $fixture -Contract $contract).passed){$failures.Add('Gültige Archivfixture wurde abgelehnt.')}
    $wrongSize=[pscustomobject]@{sizeBytes=5;sha256=$fixtureHash}
    if((Test-KINodeArchiveContract -ArchivePath $fixture -Contract $wrongSize).reason-ne'SizeMismatch'){$failures.Add('Falsche Archivgröße wurde nicht erkannt.')}
    $wrongHash=[pscustomobject]@{sizeBytes=4;sha256=('0'*64)}
    if((Test-KINodeArchiveContract -ArchivePath $fixture -Contract $wrongHash).reason-ne'HashMismatch'){$failures.Add('Falscher Archivhash wurde nicht erkannt.')}
    if((Test-KINodeArchiveContract -ArchivePath (Join-Path $fixtureRoot 'missing.zip') -Contract $contract).reason-ne'Missing'){$failures.Add('Fehlendes Archiv wurde nicht erkannt.')}
    $nested=Join-Path $fixtureRoot 'missing/parents/modules/codex-local'
    New-KICodexDirectory $nested
    if(-not(Test-Path -LiteralPath $nested -PathType Container)){$failures.Add('Elternverzeichnisse wurden nicht erzeugt.')}
}finally{
    if(Test-Path -LiteralPath $fixtureRoot){Remove-Item -LiteralPath $fixtureRoot -Recurse -Force}
}

# --- Ensure-KILMStudioEndpointReachable: managed-starter regression --------
# Endpoint down -> managed starter invoked -> endpoint becomes reachable -> success.
# Reuses the real Applications-module starter path/contract
# (modules/applications/Start-KIStack-LMStudio.cmd); the starter fixture here
# stands in for the real LM Studio launcher and deliberately answers only
# after a short delay, so the test also proves the retry loop -- not just a
# single immediate check -- is what makes this pass.
$starterFixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('KICX-LM-'+[guid]::NewGuid().ToString('N').Substring(0,8))
try{
    $appsModuleRoot=Join-Path $starterFixtureRoot 'modules/applications'
    New-Item -ItemType Directory -Path $appsModuleRoot -Force|Out-Null
    $port=Get-Random -Minimum 20000 -Maximum 40000
    $starterCmd=Join-Path $appsModuleRoot 'Start-KIStack-LMStudio.cmd'
    $mockServerScript=Join-Path $appsModuleRoot 'mock-lmstudio-server.ps1'
    # Raw TcpListener (not HttpListener): avoids http.sys URL-ACL/namespace
    # reservation requirements that a non-admin process would otherwise hit.
    Set-Content -LiteralPath $mockServerScript -Encoding utf8NoBOM -Value @'
param([int]$Port)
$tcp=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
$tcp.Start()
Start-Sleep -Milliseconds 800
$client=$tcp.AcceptTcpClient()
$stream=$client.GetStream()
$bodyBytes=[Text.Encoding]::UTF8.GetBytes('{"data":[{"id":"test-model"}]}')
$header="HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
$headerBytes=[Text.Encoding]::ASCII.GetBytes($header)
$stream.Write($headerBytes,0,$headerBytes.Length)
$stream.Write($bodyBytes,0,$bodyBytes.Length)
$stream.Flush()
Start-Sleep -Milliseconds 200
$client.Close()
$tcp.Stop()
'@
    Set-Content -LiteralPath $starterCmd -Encoding ascii -Value @(
        '@echo off'
        "start `"`" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"%~dp0mock-lmstudio-server.ps1`" -Port $port"
    )
    $endpointBefore=Test-KILMStudioEndpoint "http://127.0.0.1:$port/v1"
    if([bool]$endpointBefore.reachable){$failures.Add('LM-Studio-Fixture-Endpoint war unerwartet bereits erreichbar vor Starterlauf.')}
    $result=Ensure-KILMStudioEndpointReachable -TargetRoot $starterFixtureRoot -BaseUrl "http://127.0.0.1:$port/v1" -RetryCount 10 -RetryDelaySeconds 1
    if(-not [bool]$result.reachable){$failures.Add('Ensure-KILMStudioEndpointReachable meldete Endpoint nach Starterlauf weiterhin als nicht erreichbar.')}
    # No starter present -> no second start mechanism invented, existing not-reachable result is returned unchanged.
    $noStarterRoot=Join-Path $starterFixtureRoot 'no-starter'
    New-Item -ItemType Directory -Path $noStarterRoot -Force|Out-Null
    $resultNoStarter=Ensure-KILMStudioEndpointReachable -TargetRoot $noStarterRoot -BaseUrl "http://127.0.0.1:$port/v1" -RetryCount 1 -RetryDelaySeconds 1
    if([bool]$resultNoStarter.reachable){$failures.Add('Ensure-KILMStudioEndpointReachable meldete Erreichbarkeit ohne vorhandenen Starter.')}
}finally{
    if(Test-Path -LiteralPath $starterFixtureRoot){Remove-Item -LiteralPath $starterFixtureRoot -Recurse -Force}
}

# --- Ensure-KILMStudioEndpointReachable: 2.7.0 regression -- the caller's
# own retry budget must not be shorter than the managed starter's genuine
# first-run contract (reproduced live during a Greenfield run: the old
# default of 30*2s=60s gave up while the starter's up-to-~120s first-run GUI
# wait was still legitimately in progress). Two parts, neither of which
# sleeps anywhere near the real 120s window:
#
# Part A is a static assertion on the actual shipped defaults (zero sleep,
# fully deterministic): reverting the fix's parameter defaults makes this
# fail immediately, which is this scenario's negative control.
$moduleSource=[IO.File]::ReadAllText($modulePath)
if($moduleSource-match'function Ensure-KILMStudioEndpointReachable[\s\S]*?\[int\]\$RetryCount=(?<count>\d+)[\s\S]*?\[int\]\$RetryDelaySeconds=(?<delay>\d+)'){
    $shippedBudget=[int]$Matches.count*[int]$Matches.delay
    if($shippedBudget-lt120){
        $failures.Add("Ensure-KILMStudioEndpointReachable-Standardbudget beträgt nur $($shippedBudget)s -- kleiner als das legitime bis zu 120s-Zeitfenster des verwalteten Starters (90s CLI-Warten + 30s Endpoint-Warten in KIModuleApplications.psm1).")
    }
} else {
    $failures.Add('Ensure-KILMStudioEndpointReachable: RetryCount-/RetryDelaySeconds-Standardwerte konnten nicht aus dem Quelltext ermittelt werden.')
}

# Part B proves the starter-process-awareness this fix adds, without
# racing real network timing (a single failed-connection check on this
# module was measured to itself take up to ~2s here, which would make any
# wall-clock "starts up slower than budget X but faster than budget Y"
# simulation an unreliable, environment-dependent race -- exactly what
# "deterministisch mocken" rules out). Part A above already deterministically
# locks in the actual shipped budget; Part B only needs to prove the starter
# process's own exit code is observed correctly, in both directions.
$timingFixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('KICX-LMTIME-'+[guid]::NewGuid().ToString('N').Substring(0,8))
try{
    # B2: the starter itself fails fast (non-zero exit) -- must be surfaced
    # immediately (short elapsed time, starterExitCode present), never
    # silently outlived by continued polling for the rest of the budget.
    $failRoot=Join-Path $timingFixtureRoot 'fail/modules/applications'
    New-Item -ItemType Directory -Path $failRoot -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $failRoot 'Start-KIStack-LMStudio.cmd') -Encoding ascii -Value @('@echo off','exit /b 1')
    $failTargetRoot=Join-Path $timingFixtureRoot 'fail'
    $failPort=Get-Random -Minimum 20000 -Maximum 40000
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $failResult=Ensure-KILMStudioEndpointReachable -TargetRoot $failTargetRoot -BaseUrl "http://127.0.0.1:$failPort/v1" -RetryCount 15 -RetryDelaySeconds 1
    $sw.Stop()
    if([bool]$failResult.reachable){$failures.Add('B2: ein sofort fehlschlagender Starter meldete fälschlich Erreichbarkeit.')}
    if(-not$failResult.PSObject.Properties['starterExitCode'] -or $failResult.starterExitCode-ne1){$failures.Add('B2: der Exitcode eines fehlschlagenden Starters wurde nicht erkannt/gemeldet -- Fehler wurde verschluckt.')}
    if($sw.Elapsed.TotalSeconds-gt6){$failures.Add("B2: die Erkennung des Starter-Fehlschlags dauerte $($sw.Elapsed.TotalSeconds)s -- das volle Wartebudget wurde ausgeschöpft statt sofort auf den Exitcode zu reagieren.")}

    # B3: a genuine timeout (starter exits 0 having done nothing, endpoint
    # never comes up) must still fail -- the new exit-code awareness must
    # not turn a real timeout into a false success.
    $timeoutRoot=Join-Path $timingFixtureRoot 'timeout/modules/applications'
    New-Item -ItemType Directory -Path $timeoutRoot -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $timeoutRoot 'Start-KIStack-LMStudio.cmd') -Encoding ascii -Value @('@echo off')
    $timeoutTargetRoot=Join-Path $timingFixtureRoot 'timeout'
    $timeoutPort=Get-Random -Minimum 20000 -Maximum 40000
    $timeoutResult=Ensure-KILMStudioEndpointReachable -TargetRoot $timeoutTargetRoot -BaseUrl "http://127.0.0.1:$timeoutPort/v1" -RetryCount 2 -RetryDelaySeconds 1
    if([bool]$timeoutResult.reachable){$failures.Add('B3: ein echter Timeout (Endpoint wird nie erreichbar) wurde fälschlich als Erfolg gemeldet.')}
}finally{
    if(Test-Path -LiteralPath $timingFixtureRoot){Remove-Item -LiteralPath $timingFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue}
}

foreach($file in Get-ChildItem -LiteralPath $PackageRoot -Recurse -File|Where-Object Extension -in '.ps1','.psm1'){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){$failures.Add("$($file.Name): $(@($errors).Message -join '; ')")}
}
$result=[pscustomobject]@{passed=($failures.Count-eq0);version=[string]$config.version;checks=13;failures=@($failures);mutatesTarget=$false}
$result|ConvertTo-Json -Depth 20
if(-not$result.passed){exit 1}

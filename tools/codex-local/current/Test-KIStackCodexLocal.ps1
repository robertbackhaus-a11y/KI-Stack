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
if($version-ne'0.1.3'-or$config.version-ne$version){$failures.Add('Versionsvertrag inkonsistent.')}
if($config.codexPackage-ne'@openai/codex'-or$config.codexVersion-ne'0.145.0'){$failures.Add('Codex-Paketvertrag inkonsistent.')}
if($config.localProvider-ne'lmstudio'){$failures.Add('LM-Studio-Providervertrag fehlt.')}
if($config.sandboxMode-ne'workspace-write'){$failures.Add('Workspace-write-Vertrag fehlt.')}
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
    'modules/applications/Start-KIStack-LMStudio.cmd'
)){
    if(-not$module.Contains($marker)){$failures.Add("Codex-Ausführungsvertrag fehlt: $marker")}
}
foreach($forbidden in @('npm-global/codex.cmd','runtime/npm.cmd','PathSeparator+$originalPath','Get-Command node','Get-Command npm','Get-Command codex')){
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

foreach($file in Get-ChildItem -LiteralPath $PackageRoot -Recurse -File|Where-Object Extension -in '.ps1','.psm1'){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){$failures.Add("$($file.Name): $(@($errors).Message -join '; ')")}
}
$result=[pscustomobject]@{passed=($failures.Count-eq0);version=[string]$config.version;checks=12;failures=@($failures);mutatesTarget=$false}
$result|ConvertTo-Json -Depth 20
if(-not$result.passed){exit 1}

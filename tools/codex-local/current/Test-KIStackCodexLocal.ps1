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
    "secondRunReused"
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

foreach($file in Get-ChildItem -LiteralPath $PackageRoot -Recurse -File|Where-Object Extension -in '.ps1','.psm1'){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){$failures.Add("$($file.Name): $(@($errors).Message -join '; ')")}
}
$result=[pscustomobject]@{passed=($failures.Count-eq0);version=[string]$config.version;checks=12;failures=@($failures);mutatesTarget=$false}
$result|ConvertTo-Json -Depth 20
if(-not$result.passed){exit 1}

Set-StrictMode -Version Latest

function Read-KICodexJson {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 100
}

function Write-KICodexJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$Value)
    $parent=Split-Path -Parent $Path
    if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    $temporary=$Path+'.tmp'
    $Value|ConvertTo-Json -Depth 100|Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-KICodexConfig {
    param([string]$PackageRoot=$PSScriptRoot)
    Read-KICodexJson (Join-Path $PackageRoot 'Config/codex-local.config.json')
}

function New-KICodexDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if(-not(Test-Path -LiteralPath $Path -PathType Container)){
        New-Item -ItemType Directory -Path $Path -Force|Out-Null
    }
}

function Get-KICodexPaths {
    param([string]$TargetRoot='C:\KI-Stack')
    $moduleRoot=Join-Path $TargetRoot 'modules/codex-local'
    $runtimeRoot=Join-Path $moduleRoot 'runtime'
    $npmPrefix=Join-Path $moduleRoot 'npm-global'
    [pscustomobject]@{
        moduleRoot=$moduleRoot
        runtimeRoot=$runtimeRoot
        node=Join-Path $runtimeRoot 'node.exe'
        npmCli=Join-Path $runtimeRoot 'node_modules/npm/bin/npm-cli.js'
        npmPrefix=$npmPrefix
        codexCli=Join-Path $npmPrefix 'node_modules/@openai/codex/bin/codex.js'
        marker=Join-Path $moduleRoot 'installation.json'
        starter=Join-Path $moduleRoot 'Start-KIStack-CodexLocal.cmd'
        stateRoot=Join-Path $TargetRoot 'state/codex-local'
        status=Join-Path $TargetRoot 'state/codex-local/status.json'
    }
}

function Invoke-KICodexProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments=@(),
        [string]$WorkingDirectory=''
    )
    if(-not(Test-Path -LiteralPath $FilePath -PathType Leaf)){throw "Verwaltete ausführbare Datei fehlt: $FilePath"}
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$FilePath
    $psi.UseShellExecute=$false
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    $psi.CreateNoWindow=$true
    if(-not[string]::IsNullOrWhiteSpace($WorkingDirectory)){$psi.WorkingDirectory=$WorkingDirectory}
    foreach($argument in $Arguments){[void]$psi.ArgumentList.Add([string]$argument)}
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=$psi
    try{
        if(-not$process.Start()){throw "Prozess konnte nicht gestartet werden: $FilePath"}
        $stdout=$process.StandardOutput.ReadToEnd()
        $stderr=$process.StandardError.ReadToEnd()
        $process.WaitForExit()
        [pscustomobject]@{
            exitCode=$process.ExitCode
            stdout=$stdout
            stderr=$stderr
            output=@(($stdout,$stderr)|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
        }
    }finally{$process.Dispose()}
}

function Invoke-KIManagedNodeScript {
    param(
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Arguments=@(),
        [string]$WorkingDirectory=''
    )
    if(-not(Test-Path -LiteralPath $ScriptPath -PathType Leaf)){throw "Verwaltetes Node.js-Skript fehlt: $ScriptPath"}
    Invoke-KICodexProcess -FilePath $NodePath -Arguments (@($ScriptPath)+@($Arguments)) -WorkingDirectory $WorkingDirectory
}

function Test-KINodeArchiveContract {
    param([Parameter(Mandatory)][string]$ArchivePath,[Parameter(Mandatory)][object]$Contract)
    if(-not(Test-Path -LiteralPath $ArchivePath -PathType Leaf)){
        return [pscustomobject]@{passed=$false;reason='Missing';path=$ArchivePath}
    }
    $size=(Get-Item -LiteralPath $ArchivePath).Length
    if($size-ne[long]$Contract.sizeBytes){
        return [pscustomobject]@{passed=$false;reason='SizeMismatch';path=$ArchivePath;actualSize=$size;expectedSize=[long]$Contract.sizeBytes}
    }
    $hash=(Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if($hash-ne([string]$Contract.sha256).ToLowerInvariant()){
        return [pscustomobject]@{passed=$false;reason='HashMismatch';path=$ArchivePath;actualSha256=$hash;expectedSha256=[string]$Contract.sha256}
    }
    [pscustomobject]@{passed=$true;reason='Valid';path=$ArchivePath;actualSize=$size;actualSha256=$hash}
}

function Get-KIManagedNodeArchive {
    param(
        [Parameter(Mandatory)][object]$Contract,
        [Parameter(Mandatory)][string]$DownloadRoot,
        [string]$SuppliedArchive=''
    )
    New-KICodexDirectory $DownloadRoot
    $archivePath=Join-Path $DownloadRoot ([string]$Contract.archive)
    if(-not[string]::IsNullOrWhiteSpace($SuppliedArchive)){
        $supplied=Test-KINodeArchiveContract -ArchivePath $SuppliedArchive -Contract $Contract
        if(-not$supplied.passed){throw "Bereitgestelltes Node.js-Archiv verletzt den Vertrag: $($supplied.reason)."}
        if([IO.Path]::GetFullPath($SuppliedArchive)-ne[IO.Path]::GetFullPath($archivePath)){
            Copy-Item -LiteralPath $SuppliedArchive -Destination ($archivePath+'.partial') -Force
            Move-Item -LiteralPath ($archivePath+'.partial') -Destination $archivePath -Force
        }
    }
    $validation=Test-KINodeArchiveContract -ArchivePath $archivePath -Contract $Contract
    if($validation.passed){return [pscustomobject]@{path=$archivePath;downloaded=$false;validation=$validation}}
    if($validation.reason-ne'Missing'){Remove-Item -LiteralPath $archivePath -Force}
    $temporary=$archivePath+'.partial'
    if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}
    try{
        Invoke-WebRequest -Uri ([string]$Contract.url) -OutFile $temporary -UseBasicParsing -TimeoutSec 600
        $validation=Test-KINodeArchiveContract -ArchivePath $temporary -Contract $Contract
        if(-not$validation.passed){throw "Heruntergeladenes Node.js-Archiv verletzt den Vertrag: $($validation.reason)."}
        Move-Item -LiteralPath $temporary -Destination $archivePath -Force
    }catch{
        if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}
        throw
    }
    [pscustomobject]@{path=$archivePath;downloaded=$true;validation=(Test-KINodeArchiveContract -ArchivePath $archivePath -Contract $Contract)}
}

function Install-KIManagedNodeRuntime {
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$TargetRoot,
        [string]$SuppliedArchive=''
    )
    $contract=$Config.nodeRuntime
    $paths=Get-KICodexPaths -TargetRoot $TargetRoot
    New-KICodexDirectory $paths.moduleRoot
    if((Test-Path -LiteralPath $paths.node -PathType Leaf)-and(Test-Path -LiteralPath $paths.npmCli -PathType Leaf)){
        $versionResult=Invoke-KICodexProcess -FilePath $paths.node -Arguments @('--version')
        if($versionResult.exitCode-eq0-and$versionResult.stdout.Trim()-eq('v'+[string]$contract.version)){
            return [pscustomobject]@{runtimeRoot=$paths.runtimeRoot;node=$paths.node;npmCli=$paths.npmCli;downloaded=$false;reused=$true}
        }
    }
    $downloadRoot=Join-Path $TargetRoot 'state/codex-local/downloads'
    $archive=Get-KIManagedNodeArchive -Contract $contract -DownloadRoot $downloadRoot -SuppliedArchive $SuppliedArchive
    $stage=Join-Path $downloadRoot ('node-stage-'+[guid]::NewGuid().ToString('N'))
    $replacement=Join-Path $paths.moduleRoot ('runtime-new-'+[guid]::NewGuid().ToString('N'))
    $prior=Join-Path $paths.moduleRoot ('runtime-prior-'+[guid]::NewGuid().ToString('N'))
    try{
        New-KICodexDirectory $stage
        Expand-Archive -LiteralPath $archive.path -DestinationPath $stage
        $sources=@(Get-ChildItem -LiteralPath $stage -Directory)
        if($sources.Count-ne1){throw "Node.js-Archivstruktur ist mehrdeutig; Verzeichnisse: $($sources.Count)."}
        $source=$sources[0]
        foreach($required in @('node.exe','node_modules/npm/bin/npm-cli.js')){
            if(-not(Test-Path -LiteralPath (Join-Path $source.FullName $required) -PathType Leaf)){throw "Node.js-Archivstruktur ist ungültig; fehlt: $required"}
        }
        Move-Item -LiteralPath $source.FullName -Destination $replacement
        if(Test-Path -LiteralPath $paths.runtimeRoot){Move-Item -LiteralPath $paths.runtimeRoot -Destination $prior}
        try{
            Move-Item -LiteralPath $replacement -Destination $paths.runtimeRoot
            $versionResult=Invoke-KICodexProcess -FilePath $paths.node -Arguments @('--version')
            if($versionResult.exitCode-ne0-or$versionResult.stdout.Trim()-ne('v'+[string]$contract.version)){throw 'Installierte Node.js-Version verletzt den Vertrag.'}
        }catch{
            if(Test-Path -LiteralPath $paths.runtimeRoot){Remove-Item -LiteralPath $paths.runtimeRoot -Recurse -Force}
            if(Test-Path -LiteralPath $prior){Move-Item -LiteralPath $prior -Destination $paths.runtimeRoot}
            throw
        }
        if(Test-Path -LiteralPath $prior){Remove-Item -LiteralPath $prior -Recurse -Force}
    }finally{
        foreach($path in @($stage,$replacement)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}
    }
    [pscustomobject]@{runtimeRoot=$paths.runtimeRoot;node=$paths.node;npmCli=$paths.npmCli;downloaded=[bool]$archive.downloaded;reused=$false}
}

function Get-KICodexVersion {
    param([string]$TargetRoot='C:\KI-Stack')
    $paths=Get-KICodexPaths -TargetRoot $TargetRoot
    if(-not(Test-Path -LiteralPath $paths.node -PathType Leaf)-or-not(Test-Path -LiteralPath $paths.codexCli -PathType Leaf)){return $null}
    $result=Invoke-KIManagedNodeScript -NodePath $paths.node -ScriptPath $paths.codexCli -Arguments @('--version')
    if($result.exitCode-ne0){return $null}
    $match=[regex]::Match($result.stdout,'(?<version>\d+\.\d+\.\d+)')
    if($match.Success){return $match.Groups['version'].Value}
    return $null
}

function Test-KILMStudioEndpoint {
    param([Parameter(Mandatory)][string]$BaseUrl)
    try{
        $result=Invoke-RestMethod -Uri ($BaseUrl.TrimEnd('/')+'/models') -Method Get -TimeoutSec 5 -ErrorAction Stop
        [pscustomobject]@{reachable=$true;modelCount=@($result.data).Count;models=@($result.data|ForEach-Object{[string]$_.id})}
    }catch{[pscustomobject]@{reachable=$false;modelCount=0;models=@();error=$_.Exception.Message}}
}

function Ensure-KILMStudioEndpointReachable {
    # The Applications module installs LM Studio without starting its local
    # server (see KIModuleApplications.psm1) and provides a managed starter,
    # Start-KIStack-LMStudio.cmd, for that purpose. codex-local needs the
    # server live; this reuses that exact starter contract (no second start
    # mechanism) instead of treating "installed but not yet started" -- a
    # state the Applications module itself validates as compliant -- as an
    # installation failure.
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$BaseUrl,
        [int]$RetryCount=30,
        [int]$RetryDelaySeconds=2
    )
    $endpoint=Test-KILMStudioEndpoint $BaseUrl
    if([bool]$endpoint.reachable){return $endpoint}
    $starterPath=Join-Path $TargetRoot 'modules/applications/Start-KIStack-LMStudio.cmd'
    if(-not(Test-Path -LiteralPath $starterPath -PathType Leaf)){return $endpoint}
    try{Start-Process -FilePath $starterPath -WindowStyle Hidden -ErrorAction Stop|Out-Null}catch{return $endpoint}
    for($attempt=0;$attempt -lt $RetryCount;$attempt++){
        Start-Sleep -Seconds $RetryDelaySeconds
        $endpoint=Test-KILMStudioEndpoint $BaseUrl
        if([bool]$endpoint.reachable){return $endpoint}
    }
    $endpoint
}

function Test-KICodexLocal {
    param([string]$PackageRoot=$PSScriptRoot,[string]$TargetRoot='C:\KI-Stack',[switch]$SkipEndpoint)
    $config=Get-KICodexConfig $PackageRoot
    $paths=Get-KICodexPaths -TargetRoot $TargetRoot
    $nodeVersion=$null
    if(Test-Path -LiteralPath $paths.node -PathType Leaf){
        $nodeResult=Invoke-KICodexProcess -FilePath $paths.node -Arguments @('--version')
        if($nodeResult.exitCode-eq0){$nodeVersion=$nodeResult.stdout.Trim().TrimStart('v')}
    }
    $version=Get-KICodexVersion -TargetRoot $TargetRoot
    $marker=$null
    if(Test-Path -LiteralPath $paths.marker -PathType Leaf){try{$marker=Read-KICodexJson $paths.marker}catch{}}
    $endpoint=if($SkipEndpoint){[pscustomobject]@{reachable=$null;skipped=$true}}else{Test-KILMStudioEndpoint ([string]$config.lmStudioBaseUrl)}
    $filesPresent=(Test-Path -LiteralPath $paths.npmCli -PathType Leaf)-and(Test-Path -LiteralPath $paths.codexCli -PathType Leaf)
    $markerMatches=$null-ne$marker-and[string]$marker.version-eq[string]$config.version-and[string]$marker.codexVersion-eq[string]$config.codexVersion
    [pscustomobject]@{
        passed=($nodeVersion-eq[string]$config.nodeRuntime.version-and$filesPresent-and$version-eq[string]$config.codexVersion-and$markerMatches-and($SkipEndpoint-or-not[bool]$config.requireModelEndpoint-or$endpoint.reachable))
        actualVersion=$version;expectedVersion=[string]$config.codexVersion;componentVersion=if($null-ne$marker){[string]$marker.version}else{$null};expectedComponentVersion=[string]$config.version
        paths=$paths;nodeRuntime=[ordered]@{command=$paths.node;actualVersion=$nodeVersion;expectedVersion=[string]$config.nodeRuntime.version;managed=$true}
        lmStudio=$endpoint;mutatesTarget=$false
    }
}

function Copy-KICodexBackupItem {
    param([string]$Path,[string]$BackupRoot,[string]$Name)
    $entry=[ordered]@{path=$Path;name=$Name;existed=(Test-Path -LiteralPath $Path);isDirectory=(Test-Path -LiteralPath $Path -PathType Container)}
    if($entry.existed){Copy-Item -LiteralPath $Path -Destination (Join-Path $BackupRoot $Name) -Recurse:$entry.isDirectory -Force}
    $entry
}

function Restore-KICodexBackup {
    param([Parameter(Mandatory)][string]$BackupPath)
    $backup=Read-KICodexJson $BackupPath
    $backupRoot=Split-Path -Parent $BackupPath
    foreach($entry in @($backup.items)){
        $path=[string]$entry.path
        if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}
        if([bool]$entry.existed){
            $parent=Split-Path -Parent $path
            New-KICodexDirectory $parent
            Copy-Item -LiteralPath (Join-Path $backupRoot ([string]$entry.name)) -Destination $path -Recurse:([bool]$entry.isDirectory) -Force
        }
    }
    [pscustomobject]@{passed=$true;status='Completed';backupPath=$BackupPath}
}

function Install-KICodexLocal {
    param(
        [string]$PackageRoot=$PSScriptRoot,
        [string]$TargetRoot,
        [string]$WorkspacePath,
        [switch]$DryRun,
        [string]$SuppliedNodeArchive=''
    )
    $config=Get-KICodexConfig $PackageRoot
    if([string]::IsNullOrWhiteSpace($TargetRoot)){$TargetRoot=[string]$config.targetRoot}
    if([string]::IsNullOrWhiteSpace($WorkspacePath)){throw 'WorkspacePath ist erforderlich.'}
    $resolvedWorkspace=(Resolve-Path -LiteralPath $WorkspacePath -ErrorAction Stop).Path
    $paths=Get-KICodexPaths -TargetRoot $TargetRoot
    $codexHome=if([string]::IsNullOrWhiteSpace($env:CODEX_HOME)){Join-Path $env:USERPROFILE '.codex'}else{[string]$env:CODEX_HOME}
    $profilePath=Join-Path $codexHome ([string]$config.profileName+'.config.toml')
    $agentsPath=Join-Path $resolvedWorkspace 'AGENTS.md'
    $plan=[pscustomobject]@{version=[string]$config.version;codexVersion=[string]$config.codexVersion;workspace=$resolvedWorkspace;agentsPath=$agentsPath;profilePath=$profilePath;moduleRoot=$paths.moduleRoot}
    if($DryRun){return [pscustomobject]@{passed=$true;status='DryRun';plan=$plan;mutatesTarget=$false}}
    $endpoint=Test-KILMStudioEndpoint ([string]$config.lmStudioBaseUrl)
    if([bool]$config.requireModelEndpoint-and-not[bool]$endpoint.reachable){
        $endpoint=Ensure-KILMStudioEndpointReachable -TargetRoot $TargetRoot -BaseUrl ([string]$config.lmStudioBaseUrl)
    }
    if([bool]$config.requireModelEndpoint-and-not[bool]$endpoint.reachable){throw 'LM Studio /v1/models ist nicht erreichbar.'}
    $existing=Test-KICodexLocal -PackageRoot $PackageRoot -TargetRoot $TargetRoot -SkipEndpoint
    if($existing.passed){return [pscustomobject]@{passed=$true;status='SkippedAlreadyCompliant';marker=(Read-KICodexJson $paths.marker);mutatesTarget=$false}}
    New-KICodexDirectory $paths.moduleRoot
    New-KICodexDirectory $paths.stateRoot
    $backupRoot=Join-Path $TargetRoot ('backups/codex-local/'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff'))
    New-KICodexDirectory $backupRoot
    $items=@()
    foreach($definition in @(
        @{path=$paths.runtimeRoot;name='runtime'},@{path=$paths.npmPrefix;name='npm-global'},
        @{path=$paths.marker;name='installation.json'},@{path=$paths.status;name='status.json'},
        @{path=$paths.starter;name='Start-KIStack-CodexLocal.cmd'},@{path=$profilePath;name='profile.config.toml'},@{path=$agentsPath;name='AGENTS.md'}
    )){$items+=@(Copy-KICodexBackupItem -Path $definition.path -BackupRoot $backupRoot -Name $definition.name)}
    $backupPath=Join-Path $backupRoot 'rollback.json'
    Write-KICodexJson $backupPath ([ordered]@{schemaVersion='2.0';createdAtUtc=[DateTime]::UtcNow.ToString('o');targetRoot=$TargetRoot;items=$items})
    try{
        $runtime=Install-KIManagedNodeRuntime -Config $config -TargetRoot $TargetRoot -SuppliedArchive $SuppliedNodeArchive
        New-KICodexDirectory $paths.npmPrefix
        $install=Invoke-KIManagedNodeScript -NodePath $runtime.node -ScriptPath $runtime.npmCli -Arguments @('install','--global','--prefix',$paths.npmPrefix,([string]$config.codexPackage+'@'+[string]$config.codexVersion),'--no-audit','--no-fund')
        if($install.exitCode-ne0){throw ('Codex-Installation fehlgeschlagen: '+($install.output-join' | '))}
        $actualVersion=Get-KICodexVersion -TargetRoot $TargetRoot
        if($actualVersion-ne[string]$config.codexVersion){throw "Codex-Version verletzt den Vertrag. Erwartet: $($config.codexVersion); Ist: $actualVersion"}
        New-KICodexDirectory (Split-Path -Parent $profilePath)
        $profile="oss_provider = `"lmstudio`"`r`nsandbox_mode = `"$([string]$config.sandboxMode)`"`r`napproval_policy = `"$([string]$config.approvalPolicy)`"`r`nproject_root_markers = [`".git`", `"AGENTS.md`"]`r`n"
        [IO.File]::WriteAllText($profilePath,$profile,[Text.UTF8Encoding]::new($false))
        Copy-Item -LiteralPath (Join-Path $PackageRoot 'Templates/AGENTS.md') -Destination $agentsPath -Force
        $start="@echo off`r`nchcp 65001 >nul`r`nsetlocal`r`npushd `"$resolvedWorkspace`"`r`n`"$($paths.node)`" `"$($paths.codexCli)`" --profile $([string]$config.profileName) --oss --local-provider lmstudio`r`nset `"RC=%ERRORLEVEL%`"`r`npopd`r`nexit /b %RC%`r`n"
        [IO.File]::WriteAllText($paths.starter,$start,[Text.UTF8Encoding]::new($false))
        $marker=[ordered]@{schemaVersion='2.0';version=[string]$config.version;codexVersion=[string]$config.codexVersion;nodeRuntimeVersion=[string]$config.nodeRuntime.version;nodeRuntimePath=$paths.runtimeRoot;npmPrefix=$paths.npmPrefix;workspace=$resolvedWorkspace;profilePath=$profilePath;agentsPath=$agentsPath;backupPath=$backupPath;installedAtUtc=[DateTime]::UtcNow.ToString('o')}
        Write-KICodexJson $paths.marker $marker
        Write-KICodexJson $paths.status $marker
        $readback=Test-KICodexLocal -PackageRoot $PackageRoot -TargetRoot $TargetRoot -SkipEndpoint
        if(-not$readback.passed){throw 'Codex-Local-Readback nach Installation ist fehlgeschlagen.'}
        [pscustomobject]@{passed=$true;status='Installed';marker=$marker;readback=$readback;mutatesTarget=$true}
    }catch{
        $rollbackStatus='Failed'
        try{$rollback=Restore-KICodexBackup -BackupPath $backupPath;$rollbackStatus=[string]$rollback.status}catch{}
        $_.Exception.Data['KIStackRollbackStatus']=$rollbackStatus
        $_.Exception.Data['KIStackBackupPath']=$backupPath
        throw
    }
}

function Test-KICodexArtifact {
    param(
        [string]$PackageRoot=$PSScriptRoot,
        [string]$NodeArchivePath='',
        [string]$TestRoot='',
        [switch]$KeepTestRoot
    )
    $ownsRoot=[string]::IsNullOrWhiteSpace($TestRoot)
    if($ownsRoot){
        $base=Join-Path ([IO.Path]::GetTempPath()) 'KICX'
        New-KICodexDirectory $base
        $TestRoot=Join-Path $base ([guid]::NewGuid().ToString('N').Substring(0,10))
    }
    try{
        New-KICodexDirectory $TestRoot
        $workspace=Join-Path $TestRoot 'ws'
        New-KICodexDirectory $workspace
        $config=Get-KICodexConfig $PackageRoot
        $originalRequire=$config.requireModelEndpoint
        $config.requireModelEndpoint=$false
        $runtime=Install-KIManagedNodeRuntime -Config $config -TargetRoot $TestRoot -SuppliedArchive $NodeArchivePath
        $paths=Get-KICodexPaths -TargetRoot $TestRoot
        New-KICodexDirectory $paths.npmPrefix
        $install=Invoke-KIManagedNodeScript -NodePath $runtime.node -ScriptPath $runtime.npmCli -Arguments @('install','--global','--prefix',$paths.npmPrefix,([string]$config.codexPackage+'@'+[string]$config.codexVersion),'--no-audit','--no-fund')
        if($install.exitCode-ne0){throw ('Codex-Artefaktinstallation fehlgeschlagen: '+($install.output-join' | '))}
        $actual=Get-KICodexVersion -TargetRoot $TestRoot
        if($actual-ne[string]$config.codexVersion){throw "Realer Codex-CLI-Test fehlgeschlagen. Erwartet: $($config.codexVersion); Ist: $actual"}
        $secondRuntime=Install-KIManagedNodeRuntime -Config $config -TargetRoot $TestRoot -SuppliedArchive $NodeArchivePath
        if(-not$secondRuntime.reused){throw 'Der zweite Runtime-Lauf hat den konformen Bestand nicht wiederverwendet.'}
        [pscustomobject]@{passed=$true;expectedVersion=[string]$config.codexVersion;actualVersion=$actual;versionOutput="codex-cli $actual";nodeVersion=[string]$config.nodeRuntime.version;secondRunReused=$true;testRoot=$TestRoot;mutatesTarget=$false}
    }finally{
        if($ownsRoot-and-not$KeepTestRoot-and(Test-Path -LiteralPath $TestRoot)){Remove-Item -LiteralPath $TestRoot -Recurse -Force}
    }
}

function Invoke-KICodexAnalysisAcceptance {
    param([string]$PackageRoot=$PSScriptRoot,[Parameter(Mandatory)][string]$WorkspacePath,[string]$TargetRoot='C:\KI-Stack')
    $config=Get-KICodexConfig $PackageRoot
    $paths=Get-KICodexPaths -TargetRoot $TargetRoot
    if(-not(Test-Path -LiteralPath $paths.codexCli -PathType Leaf)){throw 'Verwaltete Codex-CLI wurde nicht gefunden.'}
    $resolved=(Resolve-Path -LiteralPath $WorkspacePath -ErrorAction Stop).Path
    $prompt='Analysiere diesen KI-Stack-Dateibestand ausschließlich lesend. Nenne reale Module, Manifeste, Tests und Integrationspunkte für Codex Local und RAG. Verändere keine Datei. Gib am Ende ANALYSIS_ONLY aus.'
    $result=Invoke-KIManagedNodeScript -NodePath $paths.node -ScriptPath $paths.codexCli -WorkingDirectory $resolved -Arguments @('--profile',[string]$config.profileName,'exec','--oss','--local-provider','lmstudio','--sandbox','read-only',$prompt)
    [pscustomobject]@{passed=($result.exitCode-eq0-and$result.stdout-match'ANALYSIS_ONLY');exitCode=$result.exitCode;output=$result.output;mutatesTarget=$false}
}

function Restore-KICodexLocal {
    param([Parameter(Mandatory)][string]$BackupPath,[string]$PackageRoot=$PSScriptRoot,[string]$TargetRoot='C:\KI-Stack')
    Restore-KICodexBackup -BackupPath $BackupPath
}

Export-ModuleMember -Function *

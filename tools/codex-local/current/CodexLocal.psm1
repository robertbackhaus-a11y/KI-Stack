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
    $stateRoot=Join-Path $TargetRoot 'state/codex-local'
    [pscustomobject]@{
        moduleRoot=$moduleRoot
        runtimeRoot=$runtimeRoot
        node=Join-Path $runtimeRoot 'node.exe'
        npmCli=Join-Path $runtimeRoot 'node_modules/npm/bin/npm-cli.js'
        npmPrefix=$npmPrefix
        codexCli=Join-Path $npmPrefix 'node_modules/@openai/codex/bin/codex.js'
        marker=Join-Path $moduleRoot 'installation.json'
        starter=Join-Path $moduleRoot 'Start-KIStack-CodexLocal.cmd'
        stateRoot=$stateRoot
        status=Join-Path $stateRoot 'status.json'
        # KI-Stack's own, isolated Codex runtime home -- deliberately INSIDE this package's
        # existing state area, never %USERPROFILE%\.codex (real Architekturfund from the
        # Greenfield-Cold-Start workstream: that shared, ambient location is used by any other
        # real Codex CLI usage on the machine, and pre-existing state there was proven to be the
        # actual root cause of a real, reproduced wrong-model auto-download that the explicit -m
        # flag alone could not fully prevent). Purely a function of TargetRoot -- never reads
        # $env:CODEX_HOME or %USERPROFILE% -- so it can never silently fall back to the shared
        # global location, and no new global user-level hierarchy is created.
        codexHome=Join-Path $stateRoot 'codex-home'
    }
}

function Get-KICodexStarterScriptContent {
    # Extracted so the generated starter's exact content (isolated CODEX_HOME set before Codex
    # ever runs, explicit -m pinning the contracted chat model, working directory) is directly,
    # deterministically unit-testable without a real npm install -- the same testability pattern
    # KIModuleApplications.psm1's Get-KILMStudioStarterScriptContent already established for the
    # LM Studio starter.
    param(
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$CodexCliPath,
        [Parameter(Mandatory)][string]$ProfileName,
        [Parameter(Mandatory)][string]$ChatModel,
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$WorkspacePath
    )
    # CODEX_HOME is set via `set` in this generated .cmd itself -- not merely relied upon from
    # the caller's ambient environment -- so a real end user double-clicking/launching this
    # starter directly always gets the isolated, KI-Stack-owned home, regardless of whatever
    # %CODEX_HOME% (if anything) happens to be set in their own shell/profile.
    # -m/--skip-git-repo-check: see the identical, extensively-verified comment in
    # Install-KICodexLocal below -- both real, reproduced requirements (wrong-model
    # auto-download / exec-only flag), not a style preference.
    "@echo off`r`nchcp 65001 >nul`r`nsetlocal`r`nset `"CODEX_HOME=$CodexHome`"`r`npushd `"$WorkspacePath`"`r`n`"$NodePath`" `"$CodexCliPath`" --profile $ProfileName --oss --local-provider lmstudio -m $ChatModel`r`nset `"RC=%ERRORLEVEL%`"`r`npopd`r`nexit /b %RC%`r`n"
}

function Invoke-KICodexProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments=@(),
        [string]$WorkingDirectory='',
        # When supplied, this is set as the CHILD process's own CODEX_HOME environment variable
        # only -- it never touches this PowerShell session's own $env:CODEX_HOME, so it can never
        # leak into any other, unrelated invocation. This is the actual, real isolation mechanism
        # for every codex.js call this module makes directly (Get-KICodexVersion,
        # Invoke-KICodexAnalysisAcceptance): without it, the child inherits whatever ambient
        # CODEX_HOME the calling process happens to have (or none, in which case Codex's own CLI
        # falls back to the shared %USERPROFILE%\.codex) -- exactly the real, reproduced
        # Architekturfund this parameter exists to close off. Harmless to pass for callers that
        # do not read it at all (node --version, npm install, codex --version).
        [string]$CodexHome=''
    )
    if(-not(Test-Path -LiteralPath $FilePath -PathType Leaf)){throw "Verwaltete ausführbare Datei fehlt: $FilePath"}
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$FilePath
    $psi.UseShellExecute=$false
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    if(-not[string]::IsNullOrWhiteSpace($CodexHome)){$psi.Environment['CODEX_HOME']=$CodexHome}
    # RedirectStandardInput, then immediately closed after Start(), gives the child process a
    # real, immediate EOF on its own stdin -- without this, `codex exec` (which reads from
    # stdin whenever it is not a real TTY, appending it to the prompt, even when a prompt was
    # already given as an argument) blocks indefinitely waiting for input that this managed,
    # non-interactive invocation was never going to supply. Reproduced live: an otherwise
    # correctly-configured Invoke-KICodexAnalysisAcceptance call hung with near-zero CPU for
    # over ten minutes until this was added. Safe for every other caller of this function too
    # (npm install/--version, node --version, codex --version) -- none of them read stdin.
    $psi.RedirectStandardInput=$true
    $psi.CreateNoWindow=$true
    if(-not[string]::IsNullOrWhiteSpace($WorkingDirectory)){$psi.WorkingDirectory=$WorkingDirectory}
    foreach($argument in $Arguments){[void]$psi.ArgumentList.Add([string]$argument)}
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=$psi
    try{
        if(-not$process.Start()){throw "Prozess konnte nicht gestartet werden: $FilePath"}
        $process.StandardInput.Close()
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
        [string]$WorkingDirectory='',
        [string]$CodexHome=''
    )
    if(-not(Test-Path -LiteralPath $ScriptPath -PathType Leaf)){throw "Verwaltetes Node.js-Skript fehlt: $ScriptPath"}
    Invoke-KICodexProcess -FilePath $NodePath -Arguments (@($ScriptPath)+@($Arguments)) -WorkingDirectory $WorkingDirectory -CodexHome $CodexHome
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
    $result=Invoke-KIManagedNodeScript -NodePath $paths.node -ScriptPath $paths.codexCli -Arguments @('--version') -CodexHome $paths.codexHome
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
    #
    # The starter is the authoritative start/timeout contract, not this
    # function: on a genuine first run it legitimately needs up to ~120s
    # (KIModuleApplications.psm1's LmsWaitMaxAttempts*LmsWaitIntervalSeconds
    # = 90s waiting for the lms CLI to appear after LM Studio's very first
    # GUI launch, plus EndpointWaitMaxAttempts*EndpointWaitIntervalSeconds
    # = 30s waiting for the server it then starts to accept connections).
    # The default retry budget below is sized to that same window (plus
    # margin), and the starter's own process is tracked so its exit code is
    # never silently outlived by a shorter, independent poll -- reproduced
    # live during a Greenfield run: this function used to give up at 60s
    # while the starter's first-run GUI wait was still legitimately running.
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$BaseUrl,
        [int]$RetryCount=65,
        [int]$RetryDelaySeconds=2
    )
    $endpoint=Test-KILMStudioEndpoint $BaseUrl
    if([bool]$endpoint.reachable){return $endpoint}
    $starterPath=Join-Path $TargetRoot 'modules/applications/Start-KIStack-LMStudio.cmd'
    if(-not(Test-Path -LiteralPath $starterPath -PathType Leaf)){return $endpoint}
    try{$starterProcess=Start-Process -FilePath $starterPath -WindowStyle Hidden -PassThru -ErrorAction Stop}catch{return $endpoint}
    for($attempt=0;$attempt -lt $RetryCount;$attempt++){
        Start-Sleep -Seconds $RetryDelaySeconds
        $endpoint=Test-KILMStudioEndpoint $BaseUrl
        if([bool]$endpoint.reachable){return $endpoint}
        if($starterProcess.HasExited -and $starterProcess.ExitCode -ne 0){
            $endpoint|Add-Member -NotePropertyName starterExitCode -NotePropertyValue $starterProcess.ExitCode -Force
            return $endpoint
        }
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
    # The starter .cmd is a managed file too (Install-KICodexLocal (re)writes it on every real,
    # non-skipped run) -- without checking its presence here, a starter that goes missing or
    # gets corrupted after a successful install would never be detected as non-compliant, so
    # Install-KICodexLocal's own SkippedAlreadyCompliant fast-path would silently leave it
    # missing forever instead of ever reaching Repair's reconcile logic.
    $starterPresent=Test-Path -LiteralPath $paths.starter -PathType Leaf
    $markerMatches=$null-ne$marker-and[string]$marker.version-eq[string]$config.version-and[string]$marker.codexVersion-eq[string]$config.codexVersion
    [pscustomobject]@{
        passed=($nodeVersion-eq[string]$config.nodeRuntime.version-and$filesPresent-and$starterPresent-and$version-eq[string]$config.codexVersion-and$markerMatches-and($SkipEndpoint-or-not[bool]$config.requireModelEndpoint-or$endpoint.reachable))
        actualVersion=$version;expectedVersion=[string]$config.codexVersion;componentVersion=if($null-ne$marker){[string]$marker.version}else{$null};expectedComponentVersion=[string]$config.version
        paths=$paths;nodeRuntime=[ordered]@{command=$paths.node;actualVersion=$nodeVersion;expectedVersion=[string]$config.nodeRuntime.version;managed=$true}
        starterPresent=$starterPresent;lmStudio=$endpoint;mutatesTarget=$false
    }
}

function Get-KICodexStatus {
    # Read-only, no-network-required-for-package-facts status report. AvailableVersion/
    # VersionStatus (the published-vs-installed comparison) are deliberately NOT re-derived
    # here: that resolution already exists, real and tested, in
    # Lifecycle/KIStackComponentVersionRegistry.psm1 (tools/complete-installer/current), which
    # Update-KIStack-All.ps1's central report already uses for codex-local today. Re-implementing
    # the same GitHub lookup here would be a second, independently-maintained version-resolution
    # path (explicitly ruled out); importing that sibling package's module directly would not
    # even work in the real deployed isolated-execution model, where this package's payload is
    # expanded into its own temp directory without the complete-installer's Lifecycle folder
    # alongside it. AvailableVersion/VersionStatus are reported as "see the central updater" --
    # never guessed, never silently duplicated.
    param([string]$PackageRoot=$PSScriptRoot,[string]$TargetRoot='C:\KI-Stack')
    $reason=$null
    try{
        $config=Get-KICodexConfig $PackageRoot
    }catch{
        return [pscustomobject][ordered]@{
            passed=$false;state='Misconfigured';installed=$null;installedVersion=$null;availableVersion=$null;versionStatus='NotEvaluatedLocally'
            installPath=$null;runtimeReady=$false;lmStudioEndpointConfigured=$false;healthy=$false
            reason="Konfiguration konnte nicht gelesen werden: $($_.Exception.Message)";mutatesTarget=$false
        }
    }
    $lmStudioEndpointConfigured=-not[string]::IsNullOrWhiteSpace([string]$config.lmStudioBaseUrl)
    if($lmStudioEndpointConfigured){
        $parsedUri=$null
        if(-not[Uri]::TryCreate([string]$config.lmStudioBaseUrl,[UriKind]::Absolute,[ref]$parsedUri)){
            return [pscustomobject][ordered]@{
                passed=$false;state='Misconfigured';installed=$null;installedVersion=$null;availableVersion=$null;versionStatus='NotEvaluatedLocally'
                installPath=$null;runtimeReady=$false;lmStudioEndpointConfigured=$false;healthy=$false
                reason="lmStudioBaseUrl ist keine gültige absolute URL: '$([string]$config.lmStudioBaseUrl)'";mutatesTarget=$false
            }
        }
    }
    $paths=Get-KICodexPaths -TargetRoot $TargetRoot
    $marker=$null
    if(Test-Path -LiteralPath $paths.marker -PathType Leaf){try{$marker=Read-KICodexJson $paths.marker}catch{}}
    $installed=$null-ne$marker
    $installedVersion=if($installed){[string]$marker.version}else{$null}
    $filesPresent=(Test-Path -LiteralPath $paths.npmCli -PathType Leaf)-and(Test-Path -LiteralPath $paths.codexCli -PathType Leaf)
    $nodeOk=$false
    if(Test-Path -LiteralPath $paths.node -PathType Leaf){
        $nodeResult=Invoke-KICodexProcess -FilePath $paths.node -Arguments @('--version')
        $nodeOk=($nodeResult.exitCode-eq0-and$nodeResult.stdout.Trim()-eq('v'+[string]$config.nodeRuntime.version))
    }
    $actualCodexVersion=if($filesPresent){Get-KICodexVersion -TargetRoot $TargetRoot}else{$null}
    $runtimeReady=$installed-and$filesPresent-and$nodeOk-and($actualCodexVersion-eq[string]$config.codexVersion)
    $starterPresent=Test-Path -LiteralPath $paths.starter -PathType Leaf
    if(-not$installed){
        $state='NotInstalled';$reason='Codex Local ist auf diesem Ziel nicht installiert (kein Marker gefunden).'
    }elseif(-not$runtimeReady-or-not$starterPresent){
        $state='Broken'
        $brokenParts=@()
        if(-not$filesPresent){$brokenParts+='verwaltete Codex-CLI-Dateien fehlen'}
        if(-not$nodeOk){$brokenParts+='verwaltete Node.js-Runtime fehlt oder Version stimmt nicht'}
        if($null-ne$actualCodexVersion-and$actualCodexVersion-ne[string]$config.codexVersion){$brokenParts+="Codex-CLI-Version weicht ab (Ist: $actualCodexVersion, Soll: $([string]$config.codexVersion))"}
        if(-not$starterPresent){$brokenParts+='Starter-Skript fehlt'}
        $reason=($brokenParts-join'; ')
    }else{
        # Package itself is fully intact -- LM Studio being unreachable right now is a separate,
        # external runtime precondition (it may simply not be running yet), never a defect in
        # Codex Local's own installation.
        $endpoint=Test-KILMStudioEndpoint ([string]$config.lmStudioBaseUrl)
        if($lmStudioEndpointConfigured-and-not[bool]$endpoint.reachable){
            $state='RuntimeUnavailable';$reason="Codex Local ist korrekt installiert; LM Studio ist unter '$([string]$config.lmStudioBaseUrl)' aktuell nicht erreichbar."
        }else{
            $state='Healthy';$reason=$null
        }
    }
    [pscustomobject][ordered]@{
        # passed = "this Status command produced a reliable reading" (always true once we get
        # this far -- NotInstalled/Broken/RuntimeUnavailable are all valid, successfully
        # determined states, not command failures); healthy = the actual reported condition.
        passed=$true
        state=$state
        installed=$installed
        installedVersion=$installedVersion
        availableVersion=$null
        versionStatus='NotEvaluatedLocally'
        installPath=$paths.moduleRoot
        runtimeReady=[bool]$runtimeReady
        lmStudioEndpointConfigured=$lmStudioEndpointConfigured
        healthy=($state-eq'Healthy')
        reason=$reason
        mutatesTarget=$false
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
    # Serves Install, Upgrade, and Repair alike -- there is no technical difference in what
    # needs to happen (reconcile the managed payload to the config-defined target version,
    # never touch user-owned files) between "this is the first time" and "this target already
    # has an older/broken copy"; the existing SkippedAlreadyCompliant fast-path already makes a
    # same-version re-run a safe no-op regardless of which of the three was requested. -Action
    # exists so the isolated executor (matching comfyui/integration/validation-gate) can report
    # which one actually applied, and so a first-time Install can require a reachable LM Studio
    # endpoint (the existing, deliberately-hardened Greenfield contract -- unchanged) while an
    # Upgrade/Repair of an ALREADY-recorded installation never needs to (LM Studio is a runtime
    # dependency for USING Codex, not for reconciling the Codex package itself).
    param(
        [string]$PackageRoot=$PSScriptRoot,
        [string]$TargetRoot,
        [string]$WorkspacePath,
        [ValidateSet('Install','Upgrade','Repair')][string]$Action='Install',
        [switch]$DryRun,
        [string]$SuppliedNodeArchive=''
    )
    $config=Get-KICodexConfig $PackageRoot
    if([string]::IsNullOrWhiteSpace($TargetRoot)){$TargetRoot=[string]$config.targetRoot}
    if([string]::IsNullOrWhiteSpace($WorkspacePath)){throw 'WorkspacePath ist erforderlich.'}
    $resolvedWorkspace=(Resolve-Path -LiteralPath $WorkspacePath -ErrorAction Stop).Path
    $paths=Get-KICodexPaths -TargetRoot $TargetRoot
    # KI-Stack's own isolated Codex runtime home -- a pure function of TargetRoot (see
    # Get-KICodexPaths), deliberately NEVER derived from $env:CODEX_HOME or %USERPROFILE%.
    # Previously this read the ambient $env:CODEX_HOME (falling back to the real, shared
    # %USERPROFILE%\.codex when unset) -- real, reproduced Architekturfund from the Greenfield-
    # Cold-Start workstream: any other real Codex CLI usage on the machine shares that location,
    # and its pre-existing state was the actual root cause of a wrong-model auto-download that
    # survived the explicit -m fix alone. No migration out of the old shared location is
    # performed here, deliberately -- Greenfield gets a clean isolated home; an existing
    # KI-Stack installation gets one initialized fresh on its next real reconcile (Install/
    # Upgrade/Repair), never populated from foreign historical sessions.
    $codexHome=$paths.codexHome
    $profilePath=Join-Path $codexHome ([string]$config.profileName+'.config.toml')
    $agentsPath=Join-Path $resolvedWorkspace 'AGENTS.md'
    $plan=[pscustomobject]@{version=[string]$config.version;codexVersion=[string]$config.codexVersion;workspace=$resolvedWorkspace;agentsPath=$agentsPath;profilePath=$profilePath;moduleRoot=$paths.moduleRoot}
    if($DryRun){return [pscustomobject]@{passed=$true;status='DryRun';action=$Action;plan=$plan;mutatesTarget=$false}}
    # A previously-recorded installation (Upgrade/Repair territory) never needs LM Studio
    # reachable just to reconcile the Codex package itself -- only a genuine first-time Install
    # (no marker recorded yet at all) keeps the existing, hardened Greenfield contract that
    # proves the endpoint works end to end before completing.
    $hadExistingMarker=Test-Path -LiteralPath $paths.marker -PathType Leaf
    if($Action-eq'Install'-and-not$hadExistingMarker){
        $endpoint=Test-KILMStudioEndpoint ([string]$config.lmStudioBaseUrl)
        if([bool]$config.requireModelEndpoint-and-not[bool]$endpoint.reachable){
            $endpoint=Ensure-KILMStudioEndpointReachable -TargetRoot $TargetRoot -BaseUrl ([string]$config.lmStudioBaseUrl)
        }
        if([bool]$config.requireModelEndpoint-and-not[bool]$endpoint.reachable){
            $starterDetail=if($endpoint.PSObject.Properties['starterExitCode']){" Der verwaltete LM-Studio-Starter wurde mit Exitcode $($endpoint.starterExitCode) beendet."}else{''}
            throw "LM Studio /v1/models ist nicht erreichbar.$starterDetail"
        }
    }
    $existing=Test-KICodexLocal -PackageRoot $PackageRoot -TargetRoot $TargetRoot -SkipEndpoint
    if($existing.passed){return [pscustomobject]@{passed=$true;status='SkippedAlreadyCompliant';action=$Action;marker=(Read-KICodexJson $paths.marker);mutatesTarget=$false}}
    New-KICodexDirectory $paths.moduleRoot
    New-KICodexDirectory $paths.stateRoot
    # Controlled initialization of KI-Stack's own isolated Codex home -- created here,
    # unconditionally, on every real Install/Upgrade/Repair, exactly like moduleRoot/stateRoot
    # above. Never copies or migrates anything out of the real, shared %USERPROFILE%\.codex.
    New-KICodexDirectory $codexHome
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
        $install=Invoke-KIManagedNodeScript -NodePath $runtime.node -ScriptPath $runtime.npmCli -Arguments @('install','--global','--prefix',$paths.npmPrefix,([string]$config.codexPackage+'@'+[string]$config.codexVersion),'--no-audit','--no-fund') -CodexHome $codexHome
        if($install.exitCode-ne0){throw ('Codex-Installation fehlgeschlagen: '+($install.output-join' | '))}
        $actualVersion=Get-KICodexVersion -TargetRoot $TargetRoot
        if($actualVersion-ne[string]$config.codexVersion){throw "Codex-Version verletzt den Vertrag. Erwartet: $($config.codexVersion); Ist: $actualVersion"}
        New-KICodexDirectory (Split-Path -Parent $profilePath)
        # Preserve contract (managed vs. preserved): profile.config.toml and AGENTS.md are the
        # two files a user is expected to hand-edit after first install (sandbox/approval
        # policy; agent working instructions) -- written ONLY when genuinely absent, on Install
        # as much as on Upgrade/Repair, so a second Install call, an Upgrade, or a Repair never
        # overwrites a customization. Only the managed runtime/npm-global/marker/starter files
        # below are unconditionally reconciled to the config-defined target on every real call.
        if(-not(Test-Path -LiteralPath $profilePath -PathType Leaf)){
            $profile="oss_provider = `"lmstudio`"`r`nsandbox_mode = `"$([string]$config.sandboxMode)`"`r`napproval_policy = `"$([string]$config.approvalPolicy)`"`r`nproject_root_markers = [`".git`", `"AGENTS.md`"]`r`n"
            [IO.File]::WriteAllText($profilePath,$profile,[Text.UTF8Encoding]::new($false))
        }
        if(-not(Test-Path -LiteralPath $agentsPath -PathType Leaf)){
            Copy-Item -LiteralPath (Join-Path $PackageRoot 'Templates/AGENTS.md') -Destination $agentsPath -Force
        }
        # -m/--model is required as an explicit CLI argument, not merely a profile.toml
        # "model = ..." line -- verified directly: with only the profile setting, --oss mode
        # still resolved to Codex's own built-in default OSS model (openai/gpt-oss-20b) and, via
        # LM Studio's own auto-download-on-demand behavior, began pulling an unrelated ~12GB
        # model file neither the workspace root nor the -c chatModel contract asked for; the
        # explicit -m flag reliably pins the real, contracted Heretic chat model instead. -m is
        # a top-level Codex option (works interactively as much as under `exec`).
        # --skip-git-repo-check is deliberately NOT added here: verified directly that it is an
        # `exec`-subcommand-only flag ("error: unexpected argument '--skip-git-repo-check'
        # found") -- passing it to bare, interactive `codex` (what this starter runs) is a hard
        # parse error, not a relaxed trust check. The configured workspace (a deployed KI-Stack
        # target, C:\KI-Stack) is deliberately never a git repository, so interactive Codex's own
        # first-run trust prompt (a human answers a yes/no question, unlike exec mode's hard
        # refusal) is the correct, expected UX here -- see
        # Invoke-KICodexAnalysisAcceptance below for the `exec`-mode flag this applies to instead.
        # CODEX_HOME is written into the generated .cmd itself (see
        # Get-KICodexStarterScriptContent) -- a real end user launching this starter directly,
        # outside of any PowerShell session this module controls, still gets the isolated,
        # KI-Stack-owned home, never a silent fallback to whatever %CODEX_HOME% (if anything) is
        # ambient in their own shell.
        $start=Get-KICodexStarterScriptContent -NodePath $paths.node -CodexCliPath $paths.codexCli -ProfileName ([string]$config.profileName) -ChatModel ([string]$config.chatModel) -CodexHome $codexHome -WorkspacePath $resolvedWorkspace
        [IO.File]::WriteAllText($paths.starter,$start,[Text.UTF8Encoding]::new($false))
        $marker=[ordered]@{schemaVersion='2.0';version=[string]$config.version;codexVersion=[string]$config.codexVersion;nodeRuntimeVersion=[string]$config.nodeRuntime.version;nodeRuntimePath=$paths.runtimeRoot;npmPrefix=$paths.npmPrefix;workspace=$resolvedWorkspace;profilePath=$profilePath;agentsPath=$agentsPath;backupPath=$backupPath;installedAtUtc=[DateTime]::UtcNow.ToString('o')}
        Write-KICodexJson $paths.marker $marker
        Write-KICodexJson $paths.status $marker
        $readback=Test-KICodexLocal -PackageRoot $PackageRoot -TargetRoot $TargetRoot -SkipEndpoint
        if(-not$readback.passed){throw 'Codex-Local-Readback nach Installation ist fehlgeschlagen.'}
        $resultStatus=switch($Action){'Upgrade'{'Upgraded'};'Repair'{'Repaired'};default{'Installed'}}
        [pscustomobject]@{passed=$true;status=$resultStatus;action=$Action;marker=$marker;readback=$readback;mutatesTarget=$true}
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
        $install=Invoke-KIManagedNodeScript -NodePath $runtime.node -ScriptPath $runtime.npmCli -Arguments @('install','--global','--prefix',$paths.npmPrefix,([string]$config.codexPackage+'@'+[string]$config.codexVersion),'--no-audit','--no-fund') -CodexHome $paths.codexHome
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
    # -m/--skip-git-repo-check: see the identical comment on the generated starter in
    # Install-KICodexLocal -- both real, verified requirements (wrong-model auto-download /
    # "not inside a trusted directory" refusal), not a style preference. The prompt is
    # deliberately narrow (name exactly one real file) rather than an open-ended "analyze this
    # whole repository" task: verified directly that the latter can legitimately run for many
    # minutes on a large real workspace with a reasoning-enabled model, which is real work, not
    # a hang, but is a poor fit for an acceptance check that needs a bounded, reliable answer.
    param([string]$PackageRoot=$PSScriptRoot,[Parameter(Mandatory)][string]$WorkspacePath,[string]$TargetRoot='C:\KI-Stack')
    $config=Get-KICodexConfig $PackageRoot
    $paths=Get-KICodexPaths -TargetRoot $TargetRoot
    if(-not(Test-Path -LiteralPath $paths.codexCli -PathType Leaf)){throw 'Verwaltete Codex-CLI wurde nicht gefunden.'}
    $resolved=(Resolve-Path -LiteralPath $WorkspacePath -ErrorAction Stop).Path
    # AGENTS.md, not VERSION: guaranteed present in the configured workspace after Install
    # (Codex Local's own template, written by this same package) -- unlike a repository VERSION
    # file, which a deployed KI-Stack target's own root does not have at all.
    $prompt='Lies ausschließlich lesend die erste Zeile der Datei AGENTS.md im aktuellen Arbeitsverzeichnis und gib sie unverändert aus, gefolgt von ANALYSIS_ONLY auf einer eigenen Zeile. Verändere keine Datei.'
    $result=Invoke-KIManagedNodeScript -NodePath $paths.node -ScriptPath $paths.codexCli -WorkingDirectory $resolved -Arguments @('--profile',[string]$config.profileName,'exec','--oss','--local-provider','lmstudio','-m',[string]$config.chatModel,'--skip-git-repo-check','--sandbox','read-only',$prompt) -CodexHome $paths.codexHome
    [pscustomobject]@{passed=($result.exitCode-eq0-and$result.stdout-match'ANALYSIS_ONLY');exitCode=$result.exitCode;output=$result.output;mutatesTarget=$false}
}

function Restore-KICodexLocal {
    param([Parameter(Mandatory)][string]$BackupPath,[string]$PackageRoot=$PSScriptRoot,[string]$TargetRoot='C:\KI-Stack')
    Restore-KICodexBackup -BackupPath $BackupPath
}

Export-ModuleMember -Function *

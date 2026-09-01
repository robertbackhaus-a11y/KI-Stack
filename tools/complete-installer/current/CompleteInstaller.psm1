Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Runtime/KIStackPathContext.psm1') -Force -DisableNameChecking

function Read-KICompleteJson {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
}

function Write-KICompleteJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-KICompleteStepHeartbeat {
    # Central, reusable console status/heartbeat tracker for one installer step.
    # Callers announce one-shot state transitions with Write-KICompleteStepStatus
    # (Running-start, WaitingForUserAction, Completed, Failed -- printed exactly
    # once each) and, only inside an already-existing retry/wait loop, periodic
    # progress with Write-KICompleteStepHeartbeatIfDue (rate-limited to
    # IntervalSeconds so it never adds new sleeps or polling by itself).
    param([Parameter(Mandatory)][string]$StepLabel,[int]$IntervalSeconds=25)
    [pscustomobject]@{
        StepLabel=$StepLabel
        IntervalSeconds=$IntervalSeconds
        Stopwatch=[Diagnostics.Stopwatch]::StartNew()
        LastHeartbeatSeconds=0.0
        Announced=$false
    }
}

function Write-KICompleteStepStatus {
    param(
        [Parameter(Mandatory)]$Heartbeat,
        [Parameter(Mandatory)][ValidateSet('Running','Waiting','WaitingForUserAction','Completed','Failed')][string]$Status,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Heartbeat.Announced) { Write-Host ("[{0}]" -f $Heartbeat.StepLabel); $Heartbeat.Announced=$true }
    $Heartbeat.LastHeartbeatSeconds=$Heartbeat.Stopwatch.Elapsed.TotalSeconds
    Write-Host ("[{0}] {1} - {2}" -f (Get-Date).ToString('HH:mm:ss'),$Status,$Message)
}

function Write-KICompleteStepHeartbeatIfDue {
    param(
        [Parameter(Mandatory)]$Heartbeat,
        [Parameter(Mandatory)][ValidateSet('Running','Waiting')][string]$Status,
        [Parameter(Mandatory)][string]$Message
    )
    $elapsedSeconds=$Heartbeat.Stopwatch.Elapsed.TotalSeconds
    if (($elapsedSeconds-$Heartbeat.LastHeartbeatSeconds) -lt $Heartbeat.IntervalSeconds) { return }
    $Heartbeat.LastHeartbeatSeconds=$elapsedSeconds
    $runtime='{0:mm\:ss}' -f $Heartbeat.Stopwatch.Elapsed
    Write-Host ("[{0}] {1} - {2}, Laufzeit {3}" -f (Get-Date).ToString('HH:mm:ss'),$Status,$Message,$runtime)
}

function Clear-KICompleteStaleTransactionError {
    # A failed attempt sets a transaction-wide .error property (see the
    # catch block below). On -Resume that property is loaded back from the
    # persisted transaction.json; if the retry then succeeds nothing else
    # removes it, so a stale error string from the earlier failure would
    # otherwise still be present in the final Completed summary.
    param([Parameter(Mandatory)][object]$Transaction)
    if ($Transaction.PSObject.Properties['error']) { $Transaction.PSObject.Properties.Remove('error') }
    $Transaction
}

function Test-KICompleteAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-KICompletePackageRoot {
    param([string]$StartPath = $PSScriptRoot)
    $candidate = [IO.Path]::GetFullPath($StartPath)
    foreach ($depth in 0..2) {
        if ((Test-Path (Join-Path $candidate 'MANIFEST.json')) -and (Test-Path (Join-Path $candidate 'Payload'))) { return $candidate }
        $children = @(Get-ChildItem -LiteralPath $candidate -Directory -ErrorAction SilentlyContinue)
        if ($children.Count -ne 1) { break }
        $candidate = $children[0].FullName
    }
    throw 'Paketwurzel nicht gefunden; höchstens eine doppelte ZIP-Verschachtelung wird unterstützt.'
}

function Test-KICompleteShaContract {
    param([Parameter(Mandatory)][string]$Root,[string]$Contract = 'SHA256SUMS.txt')
    $errors = @()
    foreach ($line in Get-Content -LiteralPath (Join-Path $Root $Contract)) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') { $errors += "Invalid: $line"; continue }
        $path = Join-Path $Root $Matches[2].Replace('/',[IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $errors += "Missing: $($Matches[2])"; continue }
        if ((Get-FileHash $path -Algorithm SHA256).Hash -ne $Matches[1]) { $errors += "Mismatch: $($Matches[2])" }
    }
    [pscustomobject]@{ passed=($errors.Count -eq 0); errors=$errors }
}

function New-KICompleteKernelRuntimeConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$PathContext,
        [Parameter(Mandatory)][string]$BaseConfigPath,
        [Parameter(Mandatory)][string]$KernelTransactionId,
        [Parameter(Mandatory)][string]$KernelStateRoot
    )
    if ([string]::IsNullOrWhiteSpace([string]$PathContext.TransactionRoot)) { throw 'RuntimeConfig erfordert einen transaktionsgebundenen PathContext.' }
    $config = Read-KICompleteJson -Path $BaseConfigPath
    $target = [string]$PathContext.TargetRoot
    $modules = [string]$PathContext.ModuleRoot
    $python = [string]$PathContext.PythonRoot
    $data = [string]$PathContext.DataRoot
    $models = [IO.Path]::Combine($target,'models')
    $reports = [IO.Path]::Combine($target,'reports','cutover')
    $comfy = [IO.Path]::Combine($target,'ComfyUI')

    # Explicit Category-A mapping. System-, user-, WSL- and endpoint values remain
    # untouched from the product baseline.
    $config.stackRoot = $target
    $config.stateRoot = [string]$PathContext.StateRoot
    $config.logRoot = [string]$PathContext.LogRoot
    $config.cacheRoot = [IO.Path]::Combine($target,'cache')
    $config.backupRoot = [string]$PathContext.BackupRoot
    $config.moduleRoot = $modules
    $config.pythonEnvironment.root = $python
    $config.pythonEnvironment.venvRoot = [IO.Path]::Combine($python,'venvs')
    $config.pythonEnvironment.packageCache = [IO.Path]::Combine($target,'cache','python')
    $config.gitEnvironment.repositoryRoot = [IO.Path]::Combine($target,'repos')
    $config.gitEnvironment.safeDirectoryRoot = $target
    $config.comfyUI.root = $comfy
    $config.comfyUI.venv = [IO.Path]::Combine($python,'venvs','comfyui')
    $config.comfyUI.customNodesRoot = [IO.Path]::Combine($comfy,'custom_nodes')
    $config.comfyUI.modelsRoot = $models
    $config.comfyUI.moduleRoot = [IO.Path]::Combine($modules,'comfyui')
    $config.comfyUI.extraModelPathsConfig = [IO.Path]::Combine($modules,'comfyui','extra_model_paths.yaml')
    $config.comfyUI.inputDirectory = [IO.Path]::Combine($data,'comfyui','input')
    $config.comfyUI.outputDirectory = [IO.Path]::Combine($data,'comfyui','output')
    $config.comfyUI.userDirectory = [IO.Path]::Combine($data,'comfyui','user')
    $config.models.root = $models
    $config.models.workflowTargetRoot = [IO.Path]::Combine($data,'comfyui','user','default','workflows','KI-Stack')
    $config.models.integrationRoot = [IO.Path]::Combine($modules,'models-workflows')
    $config.models.installationMarker = [IO.Path]::Combine($modules,'models-workflows','installation.json')
    $importRoots = @($config.models.importSearchRoots)
    if ($importRoots.Count -lt 1) { throw 'Basiskonfiguration enthält keinen models.importSearchRoots-Eintrag.' }
    $importRoots[0] = $models
    $config.models.importSearchRoots = $importRoots
    $config.applications.moduleRoot = [IO.Path]::Combine($modules,'applications')
    $config.applications.installationMarker = [IO.Path]::Combine($modules,'applications','installation.json')
    $config.applications.openWebUI.venv = [IO.Path]::Combine($python,'venvs','openwebui')
    $config.applications.openWebUI.dataRoot = [IO.Path]::Combine($target,'OpenWebUI','data')
    $config.integration.moduleRoot = [IO.Path]::Combine($modules,'integration')
    $config.integration.installationMarker = [IO.Path]::Combine($modules,'integration','installation.json')
    $config.integration.keeperPidFile = [IO.Path]::Combine($modules,'integration','wsl-keeper.pid')
    $config.cutover.moduleRoot = [IO.Path]::Combine($modules,'cutover')
    $config.cutover.installationMarker = [IO.Path]::Combine($modules,'cutover','installation.json')
    $config.cutover.reportRoot = $reports
    $config.cutover.healthReportPath = [IO.Path]::Combine($reports,'Health-latest.json')
    $config.cutover.acceptanceReportPath = [IO.Path]::Combine($reports,'Acceptance-latest.json')
    $config.cutover.startScripts.searxng = [IO.Path]::Combine($modules,'integration','Start-KIStack-SearXNG.cmd')
    $config.cutover.startScripts.lmStudio = [IO.Path]::Combine($modules,'applications','Start-KIStack-LMStudio.cmd')
    $config.cutover.startScripts.openWebUI = [IO.Path]::Combine($modules,'integration','Start-KIStack-OpenWebUI-WithSearch.cmd')
    $config.cutover.startScripts.comfyUI = [IO.Path]::Combine($modules,'comfyui','Start-KIStack-ComfyUI.cmd')
    $config.cutover.stopScripts.applications = [IO.Path]::Combine($modules,'applications','Stop-KIStack-Applications.cmd')
    $config.cutover.stopScripts.searxng = [IO.Path]::Combine($modules,'integration','Stop-KIStack-SearXNG.cmd')
    $config.cutover.stopScripts.comfyUI = [IO.Path]::Combine($modules,'comfyui','Stop-KIStack-ComfyUI.cmd')
    $config.validation.acceptanceRoot = $reports
    $config.validation.latestReportPath = [IO.Path]::Combine($reports,'Acceptance-latest.json')
    $config | Add-Member -NotePropertyName targetRoot -NotePropertyValue $target -Force
    $config | Add-Member -NotePropertyName transactionId -NotePropertyValue $KernelTransactionId -Force
    $config | Add-Member -NotePropertyName pathContractVersion -NotePropertyValue ([string]$PathContext.PathContractVersion) -Force
    $config | Add-Member -NotePropertyName transactionRoot -NotePropertyValue ([string]$PathContext.TransactionRoot) -Force
    $config | Add-Member -NotePropertyName kernelStateRoot -NotePropertyValue $KernelStateRoot -Force
    $config
}

function Write-KICompleteKernelRuntimeConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$PathContext,
        [Parameter(Mandatory)][string]$BaseConfigPath,
        [Parameter(Mandatory)][string]$KernelTransactionId,
        [Parameter(Mandatory)][string]$KernelStateRoot
    )
    $config = New-KICompleteKernelRuntimeConfig -PathContext $PathContext -BaseConfigPath $BaseConfigPath -KernelTransactionId $KernelTransactionId -KernelStateRoot $KernelStateRoot
    $path = [IO.Path]::Combine([string]$PathContext.TransactionRoot,'kernel-runtime-config.json')
    $json = $config | ConvertTo-Json -Depth 100
    $temporaryPath = $path + '.tmp'
    [IO.File]::WriteAllText($temporaryPath,$json + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $path -Force
    [pscustomobject][ordered]@{ path=$path; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash; config=$config }
}

function ConvertTo-KICompleteProcessArgument {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value.Contains('"')) { throw 'Prozessargumente mit Anführungszeichen werden nicht unterstützt.' }
    if ($Value -match '\s') { return '"' + $Value + '"' }
    $Value
}

function Get-KICompleteComponentStatePath {
    param([Parameter(Mandatory)][object]$PathContext)
    [IO.Path]::Combine([string]$PathContext.StateRoot,'components.json')
}

function Get-KICompleteStoredVersion {
    param([Parameter(Mandatory)][object]$Component,[string]$TargetRoot,[object]$PathContext)
    if($null-eq$PathContext){$PathContext=New-KICompletePathContext -TargetRoot $TargetRoot -PackageRoot $PSScriptRoot}
    $completeMarker=Get-KICompleteComponentStatePath -PathContext $PathContext
    if(Test-Path $completeMarker){$state=Read-KICompleteJson $completeMarker;$entry=$state.components.PSObject.Properties[[string]$Component.id];if($null-ne$entry){return [string]$entry.Value}}
    return $null
}

function Get-KICompleteInstalledVersion {
    param([Parameter(Mandatory)][object]$Component,[Parameter(Mandatory)][string]$TargetRoot,[hashtable]$FixtureState)
    if ($null -ne $FixtureState -and $FixtureState.ContainsKey([string]$Component.id)) { return [string]$FixtureState[[string]$Component.id] }
    if ([bool]$Component.installable) {
        if(-not($Component.PSObject.Properties.Name-contains'probe')-or$null-eq$Component.probe){return $null}
        $probe=$Component.probe
        $path=Join-Path $TargetRoot ([string]$probe.path)
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
        if([string]$probe.type-eq'text'){return (Get-Content -LiteralPath $path -Raw).Trim()}
        if([string]$probe.type-eq'json'){
            $marker=Read-KICompleteJson $path
            foreach($field in @($probe.fields)){$property=$marker.PSObject.Properties[[string]$field];if($null-ne$property-and$property.Value){return [string]$property.Value}}
            return $null
        }
        throw "Unbekannter Komponenten-Probetyp: $($probe.type)"
    }
    $acceptancePath=Join-Path $TargetRoot 'modules/production-recovery/acceptance.json'
    $accepted=$null;if(Test-Path $acceptancePath){$accepted=Read-KICompleteJson $acceptancePath}
    if($accepted -and [bool]$accepted.passed -and [string]$accepted.recoveryRevision -eq 'r7'){
        # This map is the frozen, real-target-validated snapshot from the production-recovery r7
        # acceptance event, not a live mirror of Contracts/COMPONENTS.json's current pins -- it
        # must NOT be bumped in lockstep with a component's pin, or Get-KICompleteInstalledVersion
        # would report a pin bump as "already installed" without anything actually being
        # reconciled/reinstalled on the target. Confirmed empirically: bumping 'cutover-runtime'
        # here to match its new pin made New-KICompletePlan report it compliant/Skip even though
        # the real target's deployed Cutover Runtime kernel/modules (e.g. the LM-Studio starter)
        # were never actually refreshed, defeating the whole point of the version bump.
        $acceptedVersions=@{'foundation-runtime'='1.0.9';'python-git'='1.1.5';'cutover-runtime'='1.6.10';'production-recovery'='1.7.0-r7';'validation-gate'='1.0.3';'target-acceptance'='1.0.10'}
        if($acceptedVersions.ContainsKey([string]$Component.id)){return [string]$acceptedVersions[[string]$Component.id]}
    }
    switch ([string]$Component.id) {
        'foundation-runtime' { if (Test-Path (Join-Path $TargetRoot 'VERSION')) { return (Get-Content (Join-Path $TargetRoot 'VERSION') -Raw).Trim() } }
        'python-git' { if (Test-Path (Join-Path $TargetRoot 'modules/python-git/installation.json')) { return [string](Read-KICompleteJson (Join-Path $TargetRoot 'modules/python-git/installation.json')).version } }
        default {
            if ($Component.PSObject.Properties.Name -contains 'marker' -and $Component.marker) {
                $path = Join-Path $TargetRoot ([string]$Component.marker)
                if (Test-Path $path) { $marker=Read-KICompleteJson $path; foreach($name in @('version','releaseVersion','packageVersion')){if($marker.PSObject.Properties.Name -contains $name -and $marker.$name){return [string]$marker.$name}};if($marker.PSObject.Properties.Name -contains 'release' -and [string]$marker.release -match '-v(?<version>[0-9]+\.[0-9]+\.[0-9]+(?:-r[0-9]+)?)$'){return [string]$Matches.version} }
            }
        }
    }
    return $null
}

function Test-KICompleteModelsWorkflowsCompliant {
    param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$TargetRoot)
    $payloadContract=Read-KICompleteJson (Join-Path $PackageRoot 'Contracts/PAYLOADS.json')
    $authority=$payloadContract.modelContractAuthority
    $archiveFile=Join-Path $PackageRoot ([string]$authority.packagedArchive)
    if(-not(Test-Path -LiteralPath $archiveFile -PathType Leaf)){return $false}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($archiveFile)
    try{
        $manifestEntry=$archive.Entries|Where-Object{$_.FullName.EndsWith([string]$authority.packagedEntrySuffix,[StringComparison]::OrdinalIgnoreCase)}|Select-Object -First 1
        if(-not$manifestEntry){return $false}
        $reader=[IO.StreamReader]::new($manifestEntry.Open())
        try{$modelManifest=$reader.ReadToEnd()|ConvertFrom-Json -Depth 100}finally{$reader.Dispose()}
    }finally{$archive.Dispose()}
    if([string]$modelManifest.schemaVersion-ne[string]$authority.schemaVersion){return $false}
    $models=@($modelManifest.models)
    if($models.Count-ne9){return $false}
    foreach($model in $models){
        $target=Join-Path $TargetRoot ([string]$model.relativeTargetPath)
        if(-not(Test-Path -LiteralPath $target -PathType Leaf)){return $false}
        if((Get-Item -LiteralPath $target).Length-ne[long]$model.sizeBytes){return $false}
        if($model.PSObject.Properties.Name-contains'sha256'){
            if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()-ne[string]$model.sha256){return $false}
        }
    }
    $lmStudioHome=Join-Path $env:USERPROFILE ([string]$modelManifest.lmStudio.homeRelativeToUserProfile)
    foreach($file in @($modelManifest.lmStudio.files)){
        $target=Join-Path $lmStudioHome ([string]$file.relativeTargetPath)
        if(-not(Test-Path -LiteralPath $target -PathType Leaf)){return $false}
        if((Get-Item -LiteralPath $target).Length-ne[long]$file.sizeBytes){return $false}
        if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()-ne[string]$file.sha256){return $false}
    }
    $archive=[IO.Compression.ZipFile]::OpenRead($archiveFile)
    try{
        $workflowEntries=@($archive.Entries|Where-Object{$_.FullName-match'/Workflows/[^/]+\.json$'})
        if($workflowEntries.Count-ne2){return $false}
        foreach($entry in $workflowEntries){
            $target=Join-Path (Join-Path $TargetRoot 'data/comfyui/user/default/workflows/KI-Stack') ([IO.Path]::GetFileName($entry.FullName))
            if(Test-Path -LiteralPath $target -PathType Leaf){return $false}
        }
    }finally{$archive.Dispose()}
    return $true
}

function Test-KICompleteVisualPackCompliant {
    param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$TargetRoot)
    $payload=Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Payload/OpenWebUIVisualPack') -File -Filter '*.zip'|Select-Object -First 1
    if(-not$payload){return $false}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($payload.FullName)
    try{
        $entries=@($archive.Entries|Where-Object {$_.FullName-match'/UIWorkflow/[^/]+\.json$'})
        if($entries.Count-ne2){return $false}
        foreach($entry in $entries){
            $target=Join-Path $TargetRoot ('data/comfyui/user/default/workflows/'+[IO.Path]::GetFileName($entry.FullName))
            if(-not(Test-Path -LiteralPath $target -PathType Leaf)){return $false}
            $stream=$entry.Open()
            try{$expected=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()}finally{$stream.Dispose()}
            if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()-ne$expected){return $false}
            $graph=Get-Content -LiteralPath $target -Raw|ConvertFrom-Json -Depth 100
            if(@($graph.nodes).Count-lt1){return $false}
        }
    }finally{$archive.Dispose()}
    return $true
}

function Test-KICompleteCodexLocalCompliant {
    param([Parameter(Mandatory)][string]$TargetRoot,[string]$ExpectedComponentVersion='0.2.1',[string]$ExpectedCodexVersion='0.145.0',[string]$ExpectedNodeVersion='24.14.0')
    $root=Join-Path $TargetRoot 'modules/codex-local'
    $markerPath=Join-Path $root 'installation.json'
    $node=Join-Path $root 'runtime/node.exe'
    $npmCli=Join-Path $root 'runtime/node_modules/npm/bin/npm-cli.js'
    $codexCli=Join-Path $root 'npm-global/node_modules/@openai/codex/bin/codex.js'
    foreach($path in @($markerPath,$node,$npmCli,$codexCli)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $false}}
    try{
        $marker=Read-KICompleteJson $markerPath
        if([string]$marker.version-ne$ExpectedComponentVersion-or[string]$marker.codexVersion-ne$ExpectedCodexVersion-or[string]$marker.nodeRuntimeVersion-ne$ExpectedNodeVersion){return $false}
        $nodeOutput=@(& $node --version 2>&1);if($LASTEXITCODE-ne0-or($nodeOutput-join' ').Trim()-ne('v'+$ExpectedNodeVersion)){return $false}
        # CODEX_HOME-Isolation-Workstream: this package (Complete Installer) is deployed and
        # executed as its own isolated payload, never alongside tools/codex-local/current's own
        # CodexLocal.psm1 (see Get-KICodexPaths there) -- so the same isolated home is computed
        # inline here, purely from TargetRoot, and set for this ONE child process only, exactly
        # like CodexLocal.psm1's own Invoke-KICodexProcess does. Without this, `& $node $codexCli`
        # would inherit whatever ambient CODEX_HOME this orchestrator process happens to have (or
        # fall back to the shared %USERPROFILE%\.codex) -- the real, reproduced Architekturfund
        # this fix closes off for every real codex.js invocation site, not just CodexLocal.psm1's.
        $isolatedCodexHome=Join-Path $TargetRoot 'state/codex-local/codex-home'
        $originalCodexHomeForThisCall=$env:CODEX_HOME
        $env:CODEX_HOME=$isolatedCodexHome
        try{$codexOutput=@(& $node $codexCli --version 2>&1)}finally{$env:CODEX_HOME=$originalCodexHomeForThisCall}
        if($LASTEXITCODE-ne0){return $false}
        return ($codexOutput-join' ') -match ('(?<!\d)'+[regex]::Escape($ExpectedCodexVersion)+'(?!\d)')
    }catch{return $false}
}

function Test-KICompleteIntegrationCompliant {
    param([Parameter(Mandatory)][string]$TargetRoot,[string]$ExpectedComponentVersion='1.5.11')
    $root=Join-Path $TargetRoot 'modules/integration'
    $markerPath=Join-Path $root 'installation.json'
    # Must match tools/integration/current/Runtime/RUNTIME-CONTRACT.json 'files'.
    $runtimeFiles=@(
        'Start-KIStack-IntegratedStack.cmd','Start-KIStack-OpenWebUI-WithSearch.cmd',
        'Start-KIStack-SearXNG.cmd','Start-KIStack-SearXNG.ps1',
        'Stop-KIStack-IntegratedStack.cmd','Stop-KIStack-SearXNG.cmd','Stop-KIStack-SearXNG.ps1'
    )
    foreach($path in @($markerPath)+@($runtimeFiles|ForEach-Object{Join-Path $root $_})){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $false}}
    try{
        $marker=Read-KICompleteJson $markerPath
        if([string]$marker.version-ne$ExpectedComponentVersion){return $false}
    }catch{return $false}
    # diag14: a matching marker/runtime-files snapshot alone can't tell an
    # enabled-at-boot SearXNG apart from one only running because something
    # started it manually this session (e.g. the adopted-existing install
    # path). Without this, systemd not owning the service lifecycle goes
    # undetected until the next real cold start leaves nothing to bring the
    # services back up.
    # Either uwsgi.service or ki-stack-searxng.service (the sibling Cutover-
    # Runtime Integration module's unit) providing the SearXNG endpoint is a
    # valid, compliant state; valkey-server and nginx remain required either way.
    try{
        $core=@(& wsl.exe -d Debian -u root -- systemctl is-enabled valkey-server nginx 2>&1)
        $coreEnabled=(@($core|Where-Object{$_-eq'enabled'}).Count-eq2)
        $searxng=@(& wsl.exe -d Debian -u root -- systemctl is-enabled uwsgi ki-stack-searxng 2>&1)
        $searxngEnabled=(@($searxng|Where-Object{$_-eq'enabled'}).Count-ge1)
        return ($coreEnabled -and $searxngEnabled)
    }catch{return $false}
}

function Test-KICompleteComfyUICompliant {
    # Contracts/COMPONENTS.json's own 'comfyui' probe only reads the self-reported
    # modules/comfyui/installation.json marker, which cannot detect a real checkout drift if the
    # marker itself was never rewritten (e.g. after an out-of-band ComfyUI Manager update). This
    # adds a real, independent read of the actual repository, using the same "supported range, not
    # exact match" contract as the Cutover Runtime's own KIModuleComfyUI: a newer, still-supported
    # ComfyUI must not be reported non-compliant, but a genuine drift outside the supported range,
    # a wrong source, or a non-tag checkout must not be hidden behind a stale marker either. No
    # downgrade or other mutation happens here -- this only classifies the real state.
    #
    # Complete Installer's own executable sources must stay free of any direct source-control
    # tooling dependency (see scripts/Test-Repository.ps1's "Complete Installer Git-free runtime"
    # check) -- the actual repository read is delegated to the Cutover Runtime payload's own
    # KIModuleComfyUI.psm1, which already owns that logic and is real-target-tested there; this
    # function only imports and calls it, exactly like Update-KIStack-All.ps1 already delegates
    # its OpenWebUI version read to the same payload's KIModuleApplications.psm1.
    #
    # The CutoverRuntime payload MUST be sourced from the currently-executing package (-PackageRoot,
    # matching the already-established Test-KICompleteModelsWorkflowsCompliant/
    # Test-KICompleteVisualPackCompliant sibling-hook pattern) -- never from whatever happens to be
    # already deployed under $TargetRoot\installer\complete. That target-side copy reflects the
    # PREVIOUS run, not the one currently deciding whether to mutate, and can lack helpers this
    # exact probe depends on (e.g. an older CutoverRuntime without Get-KIComfyVersionSupportState).
    #
    # A probe that genuinely runs and reaches a real answer -- no marker, invalid repo, wrong
    # remote source, unsupported version -- legitimately returns $false; that is a real, determinate
    # "not compliant" result. A probe that CANNOT be evaluated at all (missing helper, broken
    # payload, unexpected exception) must never be silently folded into that same $false, because
    # here $false drives a mutating Upgrade/Repair. Fail closed instead: throw a clear, specific
    # error and let the caller abort without touching the target.
    param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$TargetRoot)
    $markerPath=Join-Path $TargetRoot 'modules/comfyui/installation.json'
    if(-not(Test-Path -LiteralPath $markerPath -PathType Leaf)){return $false}
    $extract=$null
    try{
        $extract=Join-Path ([IO.Path]::GetTempPath()) ('ki-complete-comfyui-compliance-'+[guid]::NewGuid().ToString('N'))
        $payloadRoot=Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'CutoverRuntime' -Destination $extract
        Import-Module (Join-Path $payloadRoot 'Modules/04-ComfyUI/KIModuleComfyUI.psm1') -Force -Global -DisableNameChecking
        $config=Read-KICompleteJson (Join-Path $payloadRoot 'Config/kernel-config.json')
        $probe=Get-Command git.exe -ErrorAction SilentlyContinue
        if(-not$probe){throw 'git.exe wurde nicht gefunden -- der reale ComfyUI-Repository-Zustand kann nicht ermittelt werden.'}
        $repositoryState=Get-KIComfyRepositoryState -Root (Join-Path $TargetRoot 'ComfyUI') -GitCommand $probe
        if(-not[bool]$repositoryState.valid){return $false}
        $expectedSource=ConvertTo-KIComfyNormalizedRepositoryUrl -Url ([string]$config.comfyUI.repository)
        if([string]$repositoryState.normalizedOrigin-ne$expectedSource){return $false}
        $versionSupport=Get-KIComfyVersionSupportState -InstalledTag $repositoryState.exactTag `
            -ReferenceVersion ([string]$config.comfyUI.ref) `
            -MinimumSupportedVersion ([string](Get-KICompleteOptionalConfigValue $config.comfyUI 'minimumSupportedVersion' ([string]$config.comfyUI.ref))) `
            -MaximumSupportedVersion ([string](Get-KICompleteOptionalConfigValue $config.comfyUI 'maximumSupportedVersion' $null))
        return [bool]$versionSupport.supported
    }
    catch{
        throw [InvalidOperationException]::new("ComfyUI-Compliance-Probe konnte nicht ausgewertet werden (PackageRoot='$PackageRoot'): $($_.Exception.Message)",$_.Exception)
    }
    finally{if($extract-and(Test-Path -LiteralPath $extract)){Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue}}
}

function Get-KICompleteOptionalConfigValue {
    param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name,[AllowNull()][object]$Default=$null)
    if($null-eq$Object){return $Default}
    $property=$Object.PSObject.Properties[$Name]
    if($null-ne$property-and$null-ne$property.Value){return $property.Value}
    return $Default
}

$script:KICompleteReplayableComponentIds=@('openwebui-visual-pack','openwebui-agent-pack')

function New-KICompletePlan {
    param([ValidateSet('Audit','Install','Upgrade','Repair','Validate')][string]$Mode,[string]$PackageRoot=$PSScriptRoot,[string]$TargetRoot='C:\KI-Stack',[object]$PathContext,[hashtable]$FixtureState,[switch]$EnableOpenWebUIBallistics,[string[]]$ReplayComponent=@())
    if($null-eq$PathContext){$PathContext=New-KICompletePathContext -TargetRoot $TargetRoot -PackageRoot $PackageRoot}
    $TargetRoot=[string]$PathContext.TargetRoot
    $contract = Read-KICompleteJson (Join-Path $PackageRoot 'Contracts/COMPONENTS.json')
    $knownComponentIds=@($contract.components|ForEach-Object{[string]$_.id})
    foreach($replayId in @($ReplayComponent|Select-Object -Unique)){
        if($knownComponentIds-notcontains$replayId){throw "Unbekannte Replay-Komponente: $replayId"}
        if($script:KICompleteReplayableComponentIds-notcontains$replayId){throw "Replay ist für diese Komponente nicht freigegeben: $replayId"}
    }
    $steps = foreach ($component in @($contract.components | Sort-Object order)) {
        if($component.psobject.Properties.Name-contains'optional'-and[bool]$component.optional-and-not$EnableOpenWebUIBallistics){continue}
        $installed = Get-KICompleteInstalledVersion $component $TargetRoot $FixtureState
        $stored = if($null-eq$FixtureState){Get-KICompleteStoredVersion -Component $component -PathContext $PathContext}else{$null}
        $compliant = $installed -eq [string]$component.version
        if([string]$component.id-eq'models-workflows'-and$null-eq$FixtureState){$compliant=$compliant-and(Test-KICompleteModelsWorkflowsCompliant -PackageRoot $PackageRoot -TargetRoot $TargetRoot)}
        if([string]$component.id-eq'openwebui-visual-pack'-and$null-eq$FixtureState){$compliant=$compliant-and(Test-KICompleteVisualPackCompliant -PackageRoot $PackageRoot -TargetRoot $TargetRoot)}
        if([string]$component.id-eq'codex-local'-and$null-eq$FixtureState){$compliant=$compliant-and(Test-KICompleteCodexLocalCompliant -TargetRoot $TargetRoot -ExpectedComponentVersion ([string]$component.version))}
        if([string]$component.id-eq'integration'-and$null-eq$FixtureState){$compliant=$compliant-and(Test-KICompleteIntegrationCompliant -TargetRoot $TargetRoot -ExpectedComponentVersion ([string]$component.version))}
        if([string]$component.id-eq'comfyui'-and$null-eq$FixtureState){$compliant=$compliant-and(Test-KICompleteComfyUICompliant -PackageRoot $PackageRoot -TargetRoot $TargetRoot)}
        $reconciliationNeeded=$compliant-and$stored-ne[string]$component.version
        $isReplaySelected=$compliant-and($ReplayComponent-contains[string]$component.id)
        # pinned-runtime-reference/recovery-reference components have no independent, real
        # per-target probe -- Get-KICompleteInstalledVersion falls back to the frozen
        # $acceptedVersions snapshot for them, so "compliant" here only means "matches that
        # static snapshot", never "verified on this target". If the pin changed since the last
        # recorded state (reconciliationNeeded), that must not be silently treated as Skip plus a
        # state-file-only catch-up the way it correctly is for a real, probe-verified component:
        # it needs the existing Upgrade dispatch (which already reaches these components' shared
        # kernel path) to actually run for real. Probe-based components are unaffected.
        $isUnverifiedReferenceKind=[string]$component.kind-in@('pinned-runtime-reference','recovery-reference')
        $forcesReconciliationUpgrade=$compliant-and$reconciliationNeeded-and$isUnverifiedReferenceKind-and$Mode-notin@('Audit','Validate')
        $plannedMode=if($Mode -eq 'Audit' -or $Mode -eq 'Validate'){$Mode}elseif($isReplaySelected){'Replay'}elseif($forcesReconciliationUpgrade){'Upgrade'}elseif($compliant){'Skip'}elseif($null-eq$installed-and$null-ne$stored){'Repair'}elseif($installed){'Upgrade'}else{'Install'}
        [pscustomobject][ordered]@{
            id=[string]$component.id; name=[string]$component.name; version=[string]$component.version
            plannedMode=$plannedMode
            initialState=[ordered]@{storedVersion=$stored;installedVersion=$installed;compliant=$compliant;reconciliationNeeded=$reconciliationNeeded}
            status=$(if($compliant-and-not$isReplaySelected-and-not$forcesReconciliationUpgrade-and$Mode-notin@('Audit','Validate')){'SkippedAlreadyCompliant'}else{'Planned'})
        }
    }
    $stateHasOrphans=$false
    if($null-eq$FixtureState){
        $statePath=Get-KICompleteComponentStatePath -PathContext $PathContext
        if(Test-Path -LiteralPath $statePath){
            $storedState=Read-KICompleteJson $statePath
            $plannedIds=@($steps|ForEach-Object{[string]$_.id})
            $stateHasOrphans=@($storedState.components.PSObject.Properties|Where-Object{$_.Name-notin$plannedIds}).Count-gt0
        }
    }
    [pscustomobject][ordered]@{schemaVersion='1.0';mode=$Mode;targetRoot=$TargetRoot;steps=@($steps);alreadyCompliant=(@($steps|Where-Object{-not $_.initialState.compliant}).Count -eq 0);stateHasOrphans=$stateHasOrphans;hasReplay=(@($steps|Where-Object{$_.plannedMode-eq'Replay'}).Count-gt0)}
}

function Write-KICompleteComponentMarker {
    param([Parameter(Mandatory)][object]$Component,[Parameter(Mandatory)][string]$TargetRoot)
    if(-not($Component.PSObject.Properties.Name-contains'probe')-or[string]$Component.probe.type-ne'json'){return}
    $path=Join-Path $TargetRoot ([string]$Component.probe.path)
    New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force|Out-Null
    Write-KICompleteJson $path ([ordered]@{schemaVersion='1.0';componentId=[string]$Component.id;version=[string]$Component.version;validatedAtUtc=[DateTime]::UtcNow.ToString('o')})
}

function Invoke-KICompleteVerifiedDeployment {
    param(
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [Parameter(Mandatory)][scriptblock]$Deploy,
        [Parameter(Mandatory)][scriptblock]$Readback,
        [Parameter(Mandatory)][scriptblock]$Rollback
    )
    try {
        $result=&$Deploy
        $actual=[string](&$Readback)
        if($actual-ne$ExpectedVersion){throw "Komponenten-Readback verletzt: erwartet=$ExpectedVersion; real=$actual"}
        [pscustomobject]@{passed=$true;result=$result;actualVersion=$actual;rollbackStatus='NotRequired'}
    }
    catch {
        $rollbackStatus='Failed'
        try{&$Rollback|Out-Null;$rollbackStatus='Completed'}catch{$rollbackStatus='Failed'}
        $_.Exception.Data['KIStackRollbackStatus']=$rollbackStatus
        throw
    }
}

function Update-KICompleteComponentState {
    param([Parameter(Mandatory)][object]$Plan,[string]$TargetRoot,[object]$PathContext,[Parameter(Mandatory)][string]$CompleteVersion)
    if($null-eq$PathContext){$PathContext=New-KICompletePathContext -TargetRoot $TargetRoot -PackageRoot $PSScriptRoot -Mutating}
    $versions=[ordered]@{}
    foreach($step in @($Plan.steps)){
        if(-not[bool]$step.initialState.compliant){throw "State-Reconciliation nur für real konforme Komponente erlaubt: $($step.id)"}
        $versions[[string]$step.id]=[string]$step.version
    }
    $path=Get-KICompleteComponentStatePath -PathContext $PathContext
    Write-KICompleteJson $path ([ordered]@{schemaVersion='1.0';status='ValidatedExistingInstallation';completeInstallerVersion=$CompleteVersion;validatedAtUtc=[DateTime]::UtcNow.ToString('o');components=$versions;evidence=[ordered]@{stateReconciledFromRealProbes=$true;containsSecrets=$false}})
    $path
}

function Test-KICompletePreflight {
    param([string]$PackageRoot=$PSScriptRoot,[string]$TargetRoot='C:\KI-Stack',[switch]$ReadOnly)
    $issues=@();$warnings=@()
    if($PSVersionTable.PSVersion.Major-lt7){$issues+='PowerShell 7 fehlt.'}
    if(-not[Environment]::Is64BitOperatingSystem){$issues+='64-Bit-Windows erforderlich.'}
    if(-not$ReadOnly-and-not(Test-KICompleteAdministrator)){$issues+='Administratorrechte erforderlich.'}
    $sha=Test-KICompleteShaContract $PackageRoot;if(-not$sha.passed){$issues+=@($sha.errors)}
    $drives=Get-PSDrive -Name ([IO.Path]::GetPathRoot($TargetRoot).TrimEnd('\').TrimEnd(':')) -ErrorAction SilentlyContinue
    if($drives-and$drives.Free-lt20GB){$warnings+='Weniger als 20 GB freier Speicher; externe Modelle benötigen deutlich mehr.'}
    $ports=@(1234,8188,8080,80)|ForEach-Object{[pscustomobject]@{port=$_;listeners=@(Get-NetTCPConnection -State Listen -LocalPort $_ -ErrorAction SilentlyContinue).Count}}
    [pscustomobject][ordered]@{passed=($issues.Count -eq 0);issues=$issues;warnings=$warnings;targetExists=(Test-Path $TargetRoot);ports=$ports;pwsh=$PSVersionTable.PSVersion.ToString();administrator=(Test-KICompleteAdministrator);mutatesTarget=$false}
}

function New-KICompleteTransaction {
    param([Parameter(Mandatory)][object]$Plan,[Parameter(Mandatory)][object]$PathContext)
    $TransactionId=[string]$PathContext.TransactionId
    if([string]::IsNullOrWhiteSpace($TransactionId)-or[string]::IsNullOrWhiteSpace([string]$PathContext.TransactionRoot)){throw 'PathContext muss eine gültige TransactionId enthalten.'}
    $tx=[ordered]@{
        schemaVersion='1.1';transactionId=$TransactionId;status='Planned';mode=$Plan.mode;createdAtUtc=[DateTime]::UtcNow.ToString('o')
        targetRoot=[string]$PathContext.TargetRoot;stateRoot=[string]$PathContext.StateRoot;transactionRoot=[string]$PathContext.TransactionRoot
        backupRoot=[string]$PathContext.BackupRoot;logRoot=[string]$PathContext.LogRoot;pathContractVersion=[string]$PathContext.PathContractVersion
        steps=@($Plan.steps|ForEach-Object{[ordered]@{name=$_.name;id=$_.id;version=$_.version;plannedMode=$_.plannedMode;startTime=$null;endTime=$null;initialState=$_.initialState;result=$null;backup=$null;rollbackStatus=$null;error=$null;exitCode=0;status=$_.status}})
    }
    $path=[IO.Path]::Combine([string]$PathContext.TransactionRoot,'transaction.json');Write-KICompleteJson $path $tx
    $resumePath=[IO.Path]::Combine([string]$PathContext.TransactionRoot,'resume.json')
    Write-KICompleteJson $resumePath ([ordered]@{schemaVersion='1.0';transactionId=$TransactionId;nextStep=0;completedSteps=@();containsSecrets=$false})
    [pscustomobject]@{transaction=$tx;path=$path;resumePath=$resumePath}
}

function Read-KICompleteTransactionForResume {
    param([Parameter(Mandatory)][object]$PathContext)
    $transactionId=[string]$PathContext.TransactionId
    if([string]::IsNullOrWhiteSpace($transactionId)){throw 'Resume erfordert TransactionId.'}
    $path=[IO.Path]::Combine([string]$PathContext.TransactionRoot,'transaction.json')
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){
        if(-not(Test-KICompleteSameRoot -First ([string]$PathContext.TargetRoot) -Second 'C:\KI-Stack')){throw 'Resume-Datei fehlt; Cross-Root-Legacy-Fallback ist nicht zulässig.'}
        $legacyPath=[IO.Path]::Combine([string]$PathContext.StateRoot,$transactionId,'transaction.json')
        if(-not(Test-Path -LiteralPath $legacyPath -PathType Leaf)){throw 'Resume-Datei fehlt.'}
        $path=$legacyPath
    }
    $transaction=Read-KICompleteJson $path
    if([string]$transaction.schemaVersion-eq'1.0'){
        if(-not(Test-KICompleteSameRoot -First ([string]$PathContext.TargetRoot) -Second 'C:\KI-Stack')){throw 'Schema-1.0-Resume ist nur am Legacy-Default-Root zulässig.'}
        return [pscustomobject]@{transaction=$transaction;path=$path;resumePath=[IO.Path]::Combine((Split-Path -Parent $path),'resume.json');legacy=$true}
    }
    if([string]$transaction.schemaVersion-ne'1.1'){throw "Nicht unterstützte Transaction-Schemaversion: $($transaction.schemaVersion)"}
    $expected=[ordered]@{targetRoot=$PathContext.TargetRoot;stateRoot=$PathContext.StateRoot;transactionRoot=$PathContext.TransactionRoot;backupRoot=$PathContext.BackupRoot;logRoot=$PathContext.LogRoot;pathContractVersion=$PathContext.PathContractVersion}
    foreach($name in $expected.Keys){
        $property=$transaction.PSObject.Properties[$name]
        if($null-eq$property-or-not[string]::Equals([string]$property.Value,[string]$expected[$name],[StringComparison]::OrdinalIgnoreCase)){throw "Transaction-Pfadmetadaten stimmen nicht mit dem aktuellen PathContext überein: $name"}
    }
    if(-not[string]::Equals([string]$transaction.transactionId,$transactionId,[StringComparison]::Ordinal)){throw 'TransactionId stimmt nicht mit dem aktuellen PathContext überein.'}
    [pscustomobject]@{transaction=$transaction;path=$path;resumePath=[IO.Path]::Combine((Split-Path -Parent $path),'resume.json');legacy=$false}
}

function Expand-KICompletePayload {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$PayloadName,
        [Parameter(Mandatory)][string]$Destination
    )
    $archives = @(Get-ChildItem -LiteralPath (Join-Path $PackageRoot ('Payload/' + $PayloadName)) -File -Filter '*.zip' -ErrorAction SilentlyContinue)
    if ($archives.Count -eq 0) { throw "Payload fehlt: $PayloadName" }
    if ($archives.Count -ne 1) { throw "Payload ist mehrdeutig: $PayloadName; gefunden: $($archives.Count)" }
    $archive=$archives[0]
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    Expand-Archive -LiteralPath $archive.FullName -DestinationPath $Destination
    $directories = @(Get-ChildItem -LiteralPath $Destination -Directory)
    $files = @(Get-ChildItem -LiteralPath $Destination -File)
    if ($directories.Count -eq 1 -and $files.Count -eq 0) { return $directories[0].FullName }
    $Destination
}

function Invoke-KICompleteJsonScript {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][hashtable]$Arguments
    )
    $output = & $Script @Arguments
    ($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100
}

function Invoke-KICompletePendingComponentRollback {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [string]$StateDirectory,
        [object]$PathContext
    )
    $transactionDirectory=if($null-ne$PathContext){[string]$PathContext.TransactionBaseRoot}else{$StateDirectory}
    if([string]::IsNullOrWhiteSpace($transactionDirectory)){throw 'TransactionBaseRoot fehlt.'}
    $recovered = @()
    $transactionDirectories = @(Get-ChildItem -LiteralPath $transactionDirectory -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($directory in $transactionDirectories) {
        $transactionPath = Join-Path $directory.FullName 'transaction.json'
        if (-not (Test-Path -LiteralPath $transactionPath -PathType Leaf)) { continue }
        $transaction = Read-KICompleteJson $transactionPath
        if ([string]$transaction.status -ne 'Failed') { continue }
        $step = @($transaction.steps | Where-Object {
            [string]$_.id -eq 'comfyui' -and [string]$_.status -eq 'Failed' -and
            [string]$_.rollbackStatus -notin @('Completed','NotRequired')
        } | Select-Object -First 1)
        if ($step.Count -ne 1) { continue }

        $backup = $null
        if ($step[0].result -and $step[0].result.install -and $step[0].result.install.backup) {
            $backup = [string]$step[0].result.install.backup
        }
        elseif ($step[0].backup) { $backup = [string]$step[0].backup }
        if ([string]::IsNullOrWhiteSpace($backup) -or -not (Test-Path -LiteralPath $backup -PathType Container)) { continue }

        $rollbackContract = Join-Path $backup 'rollback.json'
        if (Test-Path -LiteralPath $rollbackContract) {
            $records = @(Read-KICompleteJson $rollbackContract)
            foreach ($record in $records) {
                if ([IO.Path]::IsPathRooted([string]$record.path) -or [string]$record.path -match '(^|[\\/])\.\.([\\/]|$)') {
                    throw "Ausstehender Rollback enthält unsicheren Pfad: $($record.path)"
                }
                if ([bool]$record.existed -and -not (Test-Path -LiteralPath (Join-Path $backup ([string]$record.path)) -PathType Leaf)) {
                    throw "Ausstehendes Rollback-Backup ist unvollständig: $($record.path)"
                }
            }
        }

        $extract = Join-Path $transactionDirectory ('pending-rollback-' + [guid]::NewGuid().ToString('N'))
        try {
            $componentRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'ComfyUI' -Destination $extract
            $entry = Join-Path $componentRoot 'Invoke-KIStackComfyUI.ps1'
            $result = Invoke-KICompleteJsonScript -Script $entry -Arguments @{
                Action='Rollback'
                TargetRoot=(Join-Path $TargetRoot 'ComfyUI')
                BackupPath=$backup
            }
            if (-not [bool]$result.passed -or [string]$result.status -ne 'RolledBack') { throw 'Ausstehender ComfyUI-Rollback meldete keinen Erfolg.' }
            $stored = Get-KICompleteStoredVersion -Component ([pscustomobject]@{id='comfyui'}) -TargetRoot $TargetRoot -PathContext $PathContext
            $markerPath = Join-Path $TargetRoot 'modules/comfyui/installation.json'
            $markerVersion = if (Test-Path -LiteralPath $markerPath) { [string](Read-KICompleteJson $markerPath).version } else { $null }
            if ($stored -ne $markerVersion) { throw "Rollback-Readback inkonsistent: components.json=$stored; Marker=$markerVersion" }
            $step[0].rollbackStatus = 'Completed'
            $transaction | Add-Member -NotePropertyName recovery -NotePropertyValue ([ordered]@{
                recoveredBy='2.3.0-rc13';recoveredAtUtc=[DateTime]::UtcNow.ToString('o')
                component='comfyui';backup=$backup;records=[int]$result.records;readbackPassed=$true
            }) -Force
            Write-KICompleteJson $transactionPath $transaction
            $recovered += $transaction.transactionId
        }
        catch {
            $step[0].rollbackStatus = 'Failed'
            Write-KICompleteJson $transactionPath $transaction
            throw
        }
        finally {
            if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
        }
    }
    [pscustomobject]@{passed=$true;status=if($recovered.Count){'PendingRollbackCompleted'}else{'NoPendingRollback'};transactions=$recovered}
}

function Resolve-KICompleteFailedTransactionState {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [string]$StateDirectory,
        [object]$PathContext,
        [Parameter(Mandatory)][object]$ComponentContract,
        [hashtable]$FixtureState
    )
    $transactionDirectory=if($null-ne$PathContext){[string]$PathContext.TransactionBaseRoot}else{$StateDirectory}
    if([string]::IsNullOrWhiteSpace($transactionDirectory)){throw 'TransactionBaseRoot fehlt.'}
    $reconciled=@()
    $componentStatePath=if($null-ne$PathContext){Get-KICompleteComponentStatePath -PathContext $PathContext}else{Join-Path $StateDirectory 'components.json'}
    $componentState=if(Test-Path -LiteralPath $componentStatePath -PathType Leaf){Read-KICompleteJson $componentStatePath}else{$null}
    $validatedAtUtc=[DateTimeOffset]::MinValue
    if($null-ne$componentState-and$componentState.PSObject.Properties.Name-contains'validatedAtUtc'){
        try{$validatedAtUtc=([DateTimeOffset]$componentState.validatedAtUtc).ToUniversalTime()}catch{}
    }
    foreach($directory in @(Get-ChildItem -LiteralPath $transactionDirectory -Directory -ErrorAction SilentlyContinue|Sort-Object Name)){
        $path=Join-Path $directory.FullName 'transaction.json'
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){continue}
        $transaction=Read-KICompleteJson $path
        if([string]$transaction.status-ne'Failed'){continue}
        if($transaction.PSObject.Properties.Name-contains'rc14Recovery'-and[bool]$transaction.rc14Recovery.readbackPassed){continue}
        if($transaction.PSObject.Properties.Name-contains'failedStateRecovery'-and[bool]$transaction.failedStateRecovery.readbackPassed){continue}
        if($transaction.PSObject.Properties.Name-contains'createdAtUtc'){
            try{
                $createdAtUtc=([DateTimeOffset]$transaction.createdAtUtc).ToUniversalTime()
                if($createdAtUtc -le $validatedAtUtc){continue}
            }catch{}
        }
        $retained=@()
        $stateChanged=$false
        foreach($step in @($transaction.steps|Where-Object status -eq 'Completed')){
            if([string]$step.rollbackStatus -in @('Completed','NotRequiredRetainedVerified')){continue}
            $component=@($ComponentContract.components|Where-Object id -eq ([string]$step.id)|Select-Object -First 1)
            if($component.Count-ne1){throw "Recovery-Komponentenvertrag fehlt: $($step.id)"}
            $actual=Get-KICompleteInstalledVersion -Component $component[0] -TargetRoot $TargetRoot
            $actualCompliant=$actual-eq[string]$step.version
            if([string]$step.id-eq'codex-local'-and$null-eq$FixtureState){$actualCompliant=$actualCompliant-and(Test-KICompleteCodexLocalCompliant -TargetRoot $TargetRoot -ExpectedComponentVersion ([string]$step.version))}
            if([string]$step.id-eq'integration'-and$null-eq$FixtureState){$actualCompliant=$actualCompliant-and(Test-KICompleteIntegrationCompliant -TargetRoot $TargetRoot -ExpectedComponentVersion ([string]$step.version))}
            if([string]$step.id-eq'comfyui'-and$null-eq$FixtureState){$actualCompliant=$actualCompliant-and(Test-KICompleteComfyUICompliant -PackageRoot $PackageRoot -TargetRoot $TargetRoot)}
            if(-not$actualCompliant){throw "Fehlgeschlagene Transaktion ist nicht recoverbar: $($step.id); erwartet=$($step.version); real=$actual"}
            $step.rollbackStatus='NotRequiredRetainedVerified'
            $stateChanged=$true
            $retained+=@([ordered]@{id=[string]$step.id;version=[string]$step.version;actualVersion=$actual})
        }
        $failed=@($transaction.steps|Where-Object status -eq 'Failed')
        foreach($step in $failed){
            if([string]$step.rollbackStatus){continue}
            if($null-eq$step.result-and$null-eq$step.backup){$step.rollbackStatus='NotRequiredNoRecordedChange';$stateChanged=$true}
        }
        if($stateChanged){
            $existingRecovery=if($transaction.PSObject.Properties.Name-contains'recovery'){$transaction.recovery}else{$null}
            $transaction|Add-Member -NotePropertyName failedStateRecovery -NotePropertyValue ([ordered]@{
                recoveredBy='2.3.0';recoveredAtUtc=[DateTime]::UtcNow.ToString('o')
                strategy='RetainReadbackVerifiedComponents';retained=$retained
                priorRecovery=$existingRecovery;readbackPassed=$true
            }) -Force
            Write-KICompleteJson $path $transaction
            $reconciled+=@([string]$transaction.transactionId)
        }
    }
    [pscustomobject]@{passed=$true;status=if($reconciled.Count){'FailedTransactionStateRecovered'}else{'NoFailedTransactionState'};transactions=$reconciled}
}

function Install-KICompleteCentralStarters {
    param([string]$PackageRoot,[string]$TargetRoot,[string]$BackupRoot)
    $source=Join-Path $PackageRoot 'Lifecycle';$changed=@()
    foreach($name in @('Start-KIStack.cmd','Stop-KIStack.cmd','Stop-KIStack-Managed.ps1','Validate-KIStack.cmd','Get-KIStackStatus.ps1','Show-KIStackStatus.ps1','Status-KIStack-Interactive.cmd','Repair-KIStack.cmd','Update-KIStack-OpenWebUI.cmd','Update-KIStack-OpenWebUI.ps1','Update-KIStack-All.cmd','Update-KIStack-All.ps1')){
        $src=Join-Path $source $name;$dst=Join-Path $TargetRoot $name
        if((Test-Path $dst) -and ((Get-FileHash $src).Hash -eq (Get-FileHash $dst).Hash)){continue}
        if(Test-Path $dst){New-Item -ItemType Directory $BackupRoot -Force|Out-Null;Copy-Item $dst (Join-Path $BackupRoot $name) -Force}
        Copy-Item $src $dst -Force;$changed+=$name
    }
    $changed
}

function Remove-KICompleteLMStudioCompetingAutostart {
    # Shared, narrowly-scoped safety contract for the "no competing LM-Studio autostart" KI-Stack
    # policy: only ever removes an exact, expected LM Studio Run/RunOnce value (LM Studio.exe
    # --run-as-service, matched case-insensitively); anything else under the same value name is
    # left untouched and throws instead of being silently deleted. Reused by both
    # Install-KICompleteOperations (a Complete Installer Install/Upgrade/Repair transaction) and
    # the steady-state Start-KIStack-LMStudio.cmd starter, so compliance can no longer regress
    # silently between installer runs whenever LM Studio's own "start at login" preference
    # re-establishes this value on a later, ordinary LM Studio start.
    param([scriptblock]$OnBeforeRemove)
    $runLocations=@(
        @{path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';name='electron.app.LM Studio'},
        @{path='HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce';name='electron.app.LM Studio'},
        @{path='HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';name='electron.app.LM Studio'},
        @{path='HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce';name='electron.app.LM Studio'},
        @{path='HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';name='electron.app.LM Studio'},
        @{path='HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce';name='electron.app.LM Studio'}
    )
    $removed=@()
    foreach($entry in $runLocations){
        if(-not(Test-Path $entry.path)){continue};$properties=Get-ItemProperty -LiteralPath $entry.path -Name $entry.name -ErrorAction SilentlyContinue;$property=if($null-ne$properties){$properties.PSObject.Properties[$entry.name]}else{$null};$value=if($null-ne$property){$property.Value}else{$null}
        if($null-eq$value){continue};if([string]$value-notmatch'(?i)LM Studio(?:\.exe)?\s+--run-as-service'){throw "Nicht eindeutiger LM-Studio-Autostart wird nicht verändert: $value"}
        $foundEntry=[ordered]@{path=$entry.path;name=$entry.name;value=[string]$value}
        if($OnBeforeRemove){& $OnBeforeRemove $foundEntry}
        Remove-ItemProperty -LiteralPath $entry.path -Name $entry.name -Force
        $removed+=@($foundEntry)
    }
    [pscustomobject]@{removed=@($removed)}
}

function Install-KICompleteOperations {
    # DesktopPath: real production callers never pass this (empty -> the real, single Windows
    # Desktop folder for the current user, exactly as before). Real, reproduced Architekturfund
    # (2.13.0 consolidation workstream): a fixture/Greenfield test driving the full
    # Invoke-KIStackCompleteInstaller orchestrator against an isolated, disposable -TargetRoot
    # had NO way to avoid this function writing real .lnk files onto the REAL Desktop (only
    # pointing their TARGET at the disposable fixture path) -- [Environment]::GetFolderPath
    # ('Desktop') was never parameterized at all. This optional override exists solely so an
    # isolated test can redirect desktop-link creation into its own fixture directory instead.
    param([string]$TargetRoot,[string]$BackupRoot,[string]$DesktopPath='',[object]$PathContext)
    if($null-eq$PathContext){$PathContext=New-KICompletePathContext -TargetRoot $TargetRoot -PackageRoot $PSScriptRoot -DesktopPath $DesktopPath -Mutating}
    $state=[ordered]@{schemaVersion='1.0';createdAtUtc=[DateTime]::UtcNow.ToString('o');runValues=@();desktopLinks=@();systemdUnits=@();dockerContainers=@();changes=@()}
    New-Item -ItemType Directory -Path $BackupRoot -Force|Out-Null
    $backupPath=Join-Path $BackupRoot 'operations.backup.json';Write-KICompleteJson $backupPath $state
    $autostartResult=Remove-KICompleteLMStudioCompetingAutostart -OnBeforeRemove {
        param($foundEntry)
        $state.runValues+=@($foundEntry);Write-KICompleteJson $backupPath $state
    }
    foreach($removedEntry in $autostartResult.removed){$state.changes+=@("Run:$($removedEntry.name)")}
    if($autostartResult.removed.Count){Write-KICompleteJson $backupPath $state}
    $desktop=if([string]::IsNullOrWhiteSpace($DesktopPath)){[Environment]::GetFolderPath('Desktop')}else{$DesktopPath}
    if($desktop-ne[Environment]::GetFolderPath('Desktop')){New-Item -ItemType Directory -Path $desktop -Force|Out-Null}
    $shell=New-Object -ComObject WScript.Shell;$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
    foreach($link in @(@{name='KI-Stack starten.lnk';target='Start-KIStack.cmd'},@{name='KI-Stack stoppen.lnk';target='Stop-KIStack.cmd'},@{name='KI-Stack Status.lnk';target='Show-KIStackStatus.ps1';executable=$pwsh;arguments=('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $TargetRoot 'Show-KIStackStatus.ps1')+'"')})){
        $path=Join-Path $desktop $link.name
        if(Test-Path $path){$old=$shell.CreateShortcut($path);$state.desktopLinks+=@([ordered]@{path=$path;existed=$true;target=$old.TargetPath;workingDirectory=$old.WorkingDirectory;arguments=$old.Arguments})}else{$state.desktopLinks+=@([ordered]@{path=$path;existed=$false})};Write-KICompleteJson $backupPath $state
        $shortcut=$shell.CreateShortcut($path)
        $shortcut.TargetPath=if($link.ContainsKey('executable')){[string]$link.executable}else{Join-Path $TargetRoot $link.target}
        $shortcut.WorkingDirectory=$TargetRoot
        $shortcut.Arguments=if($link.ContainsKey('arguments')){[string]$link.arguments}else{''}
        $shortcut.Save();$state.changes+=@("Desktop:$($link.name)");Write-KICompleteJson $backupPath $state
    }
    if(Get-Command docker.exe -ErrorAction SilentlyContinue){
        foreach($id in @(& docker.exe ps -aq)){$inspect=& docker.exe inspect $id|ConvertFrom-Json -Depth 50;$c=$inspect[0];$owned=([string]$c.Name-match'(?i)ki.?stack|openwebui|searxng')-or([string]$c.Config.Image-match'(?i)ki.?stack|openwebui|searxng');if(-not$owned){continue};$policy=[string]$c.HostConfig.RestartPolicy.Name;$state.dockerContainers+=@([ordered]@{id=[string]$c.Id;name=[string]$c.Name;restartPolicy=$policy});if($policy-and$policy-ne'no'){$null=& docker.exe update --restart=no $c.Id;$state.changes+=@("Docker:$($c.Name)")}}
    }
    Write-KICompleteJson $backupPath $state
    Write-KICompleteJson (Join-Path ([string]$PathContext.StateRoot) 'operations-latest.json') ([ordered]@{schemaVersion='1.0';backupPath=$backupPath;appliedAtUtc=[DateTime]::UtcNow.ToString('o')})
    [pscustomobject]@{backupPath=$backupPath;desktop=$desktop;changes=@($state.changes)}
}

function Restore-KICompleteOperations {
    param([string]$TargetRoot,[string]$BackupPath,[object]$PathContext)
    if($null-eq$PathContext){$PathContext=New-KICompletePathContext -TargetRoot $TargetRoot -PackageRoot $PSScriptRoot -Mutating}
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        $pointer=Join-Path ([string]$PathContext.StateRoot) 'operations-latest.json';if(-not(Test-Path $pointer)){return [pscustomobject]@{status='NoOperationsBackup';restored=$false}}
        $BackupPath=[string](Read-KICompleteJson $pointer).backupPath
    }
    $backupPath=$BackupPath;$state=Read-KICompleteJson $backupPath;$shell=New-Object -ComObject WScript.Shell
    foreach($entry in @($state.runValues)){if(-not(Test-Path $entry.path)){New-Item $entry.path -Force|Out-Null};Set-ItemProperty -LiteralPath $entry.path -Name $entry.name -Value ([string]$entry.value)}
    foreach($entry in @($state.desktopLinks)){if([bool]$entry.existed){$s=$shell.CreateShortcut([string]$entry.path);$s.TargetPath=[string]$entry.target;$s.WorkingDirectory=[string]$entry.workingDirectory;$s.Arguments=[string]$entry.arguments;$s.Save()}elseif(Test-Path $entry.path){Remove-Item $entry.path -Force}}
    foreach($entry in @($state.systemdUnits)){if([bool]$entry.wasEnabled){$null=& wsl.exe -d Debian -u root -- systemctl enable ([string]$entry.unit) 2>&1}}
    foreach($entry in @($state.dockerContainers)){if([string]$entry.restartPolicy-and[string]$entry.restartPolicy-ne'no'){$null=& docker.exe update --restart=([string]$entry.restartPolicy) ([string]$entry.id)}}
    [pscustomobject]@{status='OperationsRestored';restored=$true;backupPath=$backupPath}
}

function Test-KICompleteOperations {
    # DesktopPath: see the identical parameter on Install-KICompleteOperations -- must resolve
    # to the SAME location that function used, so this readback check never inspects the real
    # Desktop when Install ran against an isolated fixture path instead.
    param([string]$TargetRoot,[string]$DesktopPath='')
    $issues=@();$runProperties=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'electron.app.LM Studio' -ErrorAction SilentlyContinue;$runProperty=if($null-ne$runProperties){$runProperties.PSObject.Properties['electron.app.LM Studio']}else{$null};if($null-ne$runProperty-and$runProperty.Value){$issues+='LM Studio Run-Autostart vorhanden.'}
    $shell=New-Object -ComObject WScript.Shell;$desktop=if([string]::IsNullOrWhiteSpace($DesktopPath)){[Environment]::GetFolderPath('Desktop')}else{$DesktopPath};$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source;foreach($link in @(@{name='KI-Stack starten.lnk';target=(Join-Path $TargetRoot 'Start-KIStack.cmd');arguments=''},@{name='KI-Stack stoppen.lnk';target=(Join-Path $TargetRoot 'Stop-KIStack.cmd');arguments=''},@{name='KI-Stack Status.lnk';target=$pwsh;arguments=('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $TargetRoot 'Show-KIStackStatus.ps1')+'"')})){$path=Join-Path $desktop $link.name;if(-not(Test-Path $path)){$issues+="Desktop-Link fehlt: $($link.name)";continue};$s=$shell.CreateShortcut($path);if($s.TargetPath-ne$link.target-or$s.WorkingDirectory-ne$TargetRoot-or$s.Arguments-ne$link.arguments){$issues+="Desktop-Link falsch: $($link.name)"}}
    # Either uwsgi.service or ki-stack-searxng.service (the sibling Cutover-
    # Runtime Integration module's unit) providing the SearXNG endpoint is a
    # valid, compliant state; valkey-server and nginx remain required either way.
    $units=@();if(Get-Command wsl.exe -ErrorAction SilentlyContinue){
        foreach($unit in @('valkey-server','nginx')){$enabled=((& wsl.exe -d Debian -u root -- systemctl is-enabled $unit 2>$null)-join'').Trim();$active=((& wsl.exe -d Debian -u root -- systemctl is-active $unit 2>$null)-join'').Trim();$units+=@([ordered]@{unit=$unit;enabled=$enabled;active=$active});if($enabled-ne'enabled'){$issues+="systemd-Autostart nicht aktiv: $unit ($enabled)"};if($active-ne'active'){$issues+="systemd-Dienst nicht aktiv: $unit ($active)"}}
        $searxngOk=$false
        foreach($unit in @('uwsgi','ki-stack-searxng')){$enabled=((& wsl.exe -d Debian -u root -- systemctl is-enabled $unit 2>$null)-join'').Trim();$active=((& wsl.exe -d Debian -u root -- systemctl is-active $unit 2>$null)-join'').Trim();$units+=@([ordered]@{unit=$unit;enabled=$enabled;active=$active});if($enabled-eq'enabled'-and$active-eq'active'){$searxngOk=$true}}
        if(-not$searxngOk){$issues+='systemd-SearXNG-Dienst nicht aktiv: weder uwsgi noch ki-stack-searxng'}
    }
    [pscustomobject]@{passed=($issues.Count-eq0);issues=$issues;desktop=$desktop;systemdUnits=$units}
}

function Install-KICompleteOrchestrator {
    param([string]$PackageRoot,[string]$TargetRoot,[string]$BackupRoot)
    $destination=Join-Path $TargetRoot 'installer/complete'
    if(Test-Path $destination){$backup=Join-Path $BackupRoot 'installer/complete';New-Item (Split-Path $backup -Parent) -ItemType Directory -Force|Out-Null;Copy-Item $destination $backup -Recurse -Force}
    New-Item $destination -ItemType Directory -Force|Out-Null
    # Copy-Item -Force below only adds/overwrites; it never removes a destination
    # file whose name no longer exists in the source. Without this pass, a stale
    # payload zip from an earlier version (or one misplaced under the wrong
    # payload-type folder) survives every future deployment, and
    # Expand-KICompletePayload then fails with "Payload ist mehrdeutig" because
    # it requires exactly one zip per payload type. Clean each payload-type
    # folder down to exactly the current source's file set before copying.
    $sourcePayloadRoot=Join-Path $PackageRoot 'Payload'
    if(Test-Path -LiteralPath $sourcePayloadRoot -PathType Container){
        $destinationPayloadRoot=Join-Path $destination 'Payload'
        foreach($sourceTypeDir in @(Get-ChildItem -LiteralPath $sourcePayloadRoot -Directory)){
            $destinationTypeDir=Join-Path $destinationPayloadRoot $sourceTypeDir.Name
            if(-not(Test-Path -LiteralPath $destinationTypeDir -PathType Container)){continue}
            $currentNames=@((Get-ChildItem -LiteralPath $sourceTypeDir.FullName -File).Name)
            foreach($existingFile in @(Get-ChildItem -LiteralPath $destinationTypeDir -File)){
                if($currentNames-notcontains$existingFile.Name){Remove-Item -LiteralPath $existingFile.FullName -Force}
            }
        }
    }
    Copy-Item (Join-Path $PackageRoot '*') $destination -Recurse -Force
    @('installer/complete')
}

function Install-KICompleteRAGModule {
    param([string]$ComponentRoot,[string]$TargetRoot,[string]$BackupRoot)
    $destination=Join-Path $TargetRoot 'modules/rag'
    $moduleBackup=Join-Path $BackupRoot 'module'
    $starter=Join-Path $TargetRoot 'modules/integration/Start-KIStack-OpenWebUI-WithSearch.cmd'
    $starterBackup=Join-Path $BackupRoot 'Start-KIStack-OpenWebUI-WithSearch.cmd'
    New-Item -ItemType Directory -Path $BackupRoot -Force|Out-Null
    if(Test-Path -LiteralPath $destination){
        Copy-Item -LiteralPath $destination -Destination $moduleBackup -Recurse -Force
    }
    if(-not(Test-Path -LiteralPath $starter -PathType Leaf)){throw 'OpenWebUI-Integrationsstarter fehlt; RAG-Startvertrag kann nicht gesetzt werden.'}
    Copy-Item -LiteralPath $starter -Destination $starterBackup -Force
    try{
        $preservedSources=$null
        $sourceConfig=Join-Path $destination 'Config/sources.json'
        if(Test-Path -LiteralPath $sourceConfig -PathType Leaf){$preservedSources=[IO.File]::ReadAllBytes($sourceConfig)}
        if(Test-Path -LiteralPath $destination){Remove-Item -LiteralPath $destination -Recurse -Force}
        Copy-Item -LiteralPath $ComponentRoot -Destination $destination -Recurse -Force
        if($null-ne$preservedSources){[IO.File]::WriteAllBytes((Join-Path $destination 'Config/sources.json'),$preservedSources)}
        $ragConfigPath=Join-Path $destination 'Config/rag.config.json'
        if(-not(Test-Path -LiteralPath $ragConfigPath -PathType Leaf)){throw 'RAG-Konfiguration fehlt; Prefix-Vertrag kann nicht gesetzt werden.'}
        $ragConfig=Get-Content -LiteralPath $ragConfigPath -Raw|ConvertFrom-Json
        $documentPrefix=[string]$ragConfig.documentPrefix
        $queryPrefix=[string]$ragConfig.queryPrefix
        if([string]::IsNullOrWhiteSpace($documentPrefix)-or[string]::IsNullOrWhiteSpace($queryPrefix)){throw 'RAG-Konfiguration enthält keine gültigen Embedding-Prefixe.'}
        $environmentPath=Join-Path $destination 'OpenWebUI-RAG.env.cmd'
        # rag.config.json is the single source of truth for these prefixes;
        # they are read from the installed component's own config rather
        # than duplicated as literals here (previously three independently
        # maintained copies of the same strings existed: this file, the RAG
        # config itself, and the RAG package's own self-test).
        $environment="@echo off`r`nset `"RAG_EMBEDDING_CONTENT_PREFIX=$documentPrefix`"`r`nset `"RAG_EMBEDDING_QUERY_PREFIX=$queryPrefix`"`r`n"
        [IO.File]::WriteAllText($environmentPath,$environment,[Text.Encoding]::ASCII)
        $starterText=[IO.File]::ReadAllText($starter)
        $callLine='call "'+$environmentPath+'"'
        if(-not$starterText.Contains($callLine)){
            $starterText=[regex]::Replace($starterText,'(?im)^@echo off\s*',("@echo off`r`n$callLine`r`n"),1)
            [IO.File]::WriteAllText($starter,$starterText.Replace("`r`n","`n").Replace("`n","`r`n"),[Text.Encoding]::ASCII)
        }
        Write-KICompleteJson (Join-Path $destination 'installation.json') ([ordered]@{
            schemaVersion='1.0';componentId='rag';version='0.4.0'
            openWebUIVersionContract='0.11.0';startEnvironment=$environmentPath
            installedAtUtc=[DateTime]::UtcNow.ToString('o')
        })
        [pscustomobject]@{passed=$true;backupPath=$BackupRoot;moduleRoot=$destination;startContractApplied=$true;sourcesPreserved=($null-ne$preservedSources)}
    }catch{
        if(Test-Path -LiteralPath $destination){Remove-Item -LiteralPath $destination -Recurse -Force}
        if(Test-Path -LiteralPath $moduleBackup){Copy-Item -LiteralPath $moduleBackup -Destination $destination -Recurse -Force}
        Copy-Item -LiteralPath $starterBackup -Destination $starter -Force
        $_.Exception.Data['KIStackRollbackStatus']='Completed'
        $_.Exception.Data['KIStackBackupPath']=$BackupRoot
        throw
    }
}

function Test-KICompleteDeploymentCompliant {
    param([string]$PackageRoot,[string]$TargetRoot)
    $destination=Join-Path $TargetRoot 'installer/complete'
    if(-not(Test-Path $destination)){return $false}
    foreach($file in Get-ChildItem $PackageRoot -Recurse -File){$relative=[IO.Path]::GetRelativePath($PackageRoot,$file.FullName);$target=Join-Path $destination $relative;if(-not(Test-Path $target)-or(Get-Item $target).Length-ne$file.Length-or(Get-FileHash $target -Algorithm SHA256).Hash-ne(Get-FileHash $file.FullName -Algorithm SHA256).Hash){return $false}}
    foreach($name in @('Start-KIStack.cmd','Stop-KIStack.cmd','Stop-KIStack-Managed.ps1','Validate-KIStack.cmd','Get-KIStackStatus.ps1','Show-KIStackStatus.ps1','Status-KIStack-Interactive.cmd','Repair-KIStack.cmd','Update-KIStack-OpenWebUI.cmd','Update-KIStack-OpenWebUI.ps1','Update-KIStack-All.cmd','Update-KIStack-All.ps1')){$source=Join-Path $PackageRoot ('Lifecycle/'+$name);$target=Join-Path $TargetRoot $name;if(-not(Test-Path $target)-or(Get-FileHash $source).Hash-ne(Get-FileHash $target).Hash){return $false}}
    return $true
}

function Invoke-KICompleteHealth {
    param([Parameter(Mandatory)][object]$Config)
    $results=foreach($endpoint in $Config.healthEndpoints){try{$r=Invoke-WebRequest -Uri ([string]$endpoint.url) -TimeoutSec ([int]$Config.timeouts.healthSeconds);$ok=$r.StatusCode -ge 200 -and $r.StatusCode -lt 400;if($endpoint.kind -eq 'search'){$j=$r.Content|ConvertFrom-Json;$ok=$ok -and @($j.results).Count -gt 0};[pscustomobject]@{name=$endpoint.name;passed=$ok;statusCode=$r.StatusCode}}catch{[pscustomobject]@{name=$endpoint.name;passed=$false;error=$_.Exception.Message}}}
    [pscustomobject]@{passed=(@($results|Where-Object{-not $_.passed}).Count -eq 0);results=@($results)}
}

function Invoke-KICompleteLifecycle {
    param([ValidateSet('Start','Stop')][string]$Action,[string]$TargetRoot='C:\KI-Stack')
    $script = Join-Path $TargetRoot ("modules/cutover/{0}-KIStack.cmd" -f $Action)
    if (-not (Test-Path $script)) { throw "Zentraler $Action-Einstieg fehlt: $script" }
    $p=Start-Process -FilePath $script -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "$Action fehlgeschlagen: Exitcode $($p.ExitCode)" }
    [pscustomobject]@{action=$Action;passed=$true;exitCode=$p.ExitCode}
}

function Invoke-KIStackCompleteInstaller {
    # DesktopPath: see Install-KICompleteOperations/Test-KICompleteOperations -- real production
    # callers never pass this (empty string keeps the real, single Windows Desktop folder).
    # Exists solely so an isolated fixture/Greenfield test can redirect desktop-link creation
    # into its own disposable directory instead of the real, current user's real Desktop.
    param([ValidateSet('Audit','Install','Upgrade','Repair','Validate','Rollback','Start','Stop')][string]$Mode='Audit',[string]$PackageRoot=$PSScriptRoot,[string]$TargetRoot='C:\KI-Stack',[string]$TransactionId,[switch]$Resume,[switch]$DryRun,[switch]$EnableOpenWebUIBallistics,[Security.SecureString]$OpenWebUIApiToken,[string[]]$ReplayComponent=@(),[string]$DesktopPath='')
    $PackageRoot = Get-KICompletePackageRoot $PackageRoot
    $transactionalMode=$Mode-in@('Install','Upgrade','Repair')-and-not$DryRun
    if($Resume-and[string]::IsNullOrWhiteSpace($TransactionId)){throw 'Resume erfordert TransactionId.'}
    if($transactionalMode-and[string]::IsNullOrWhiteSpace($TransactionId)){$TransactionId='KI-COMPLETE-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')}
    $pathContextArguments=@{TargetRoot=$TargetRoot;PackageRoot=$PackageRoot;DesktopPath=$DesktopPath;Mutating=($transactionalMode-or$Mode-eq'Rollback')}
    if(-not[string]::IsNullOrWhiteSpace($TransactionId)){$pathContextArguments.TransactionId=$TransactionId}
    $pathContext=New-KICompletePathContext @pathContextArguments
    $TargetRoot=[string]$pathContext.TargetRoot
    # Config.stateDirectory/backupDirectory/logDirectory remain package-format legacy fields.
    # New runs derive every CompleteInstaller-owned path exclusively from $pathContext.
    $config = Read-KICompleteJson (Join-Path $PackageRoot 'Config/complete-installer.config.json')
    $componentContract=Read-KICompleteJson (Join-Path $PackageRoot 'Contracts/COMPONENTS.json')
    if ($Mode -in @('Start','Stop')) { return Invoke-KICompleteLifecycle $Mode $TargetRoot }
    if ($Mode -eq 'Rollback') { return Restore-KICompleteOperations -TargetRoot $TargetRoot -PathContext $pathContext }
    $preflight = Test-KICompletePreflight -PackageRoot $PackageRoot -TargetRoot $TargetRoot -ReadOnly:($Mode -in @('Audit','Validate') -or $DryRun)
    if (-not $preflight.passed) { throw ('Preflight fehlgeschlagen: ' + ($preflight.issues -join '; ')) }
    $pendingRollback = if ($Mode -notin @('Audit','Validate') -and -not $DryRun -and -not $Resume) {
        $rollbackRecovery=Invoke-KICompletePendingComponentRollback -PackageRoot $PackageRoot -TargetRoot $TargetRoot -PathContext $pathContext
        $failedStateRecovery=Resolve-KICompleteFailedTransactionState -PackageRoot $PackageRoot -TargetRoot $TargetRoot -PathContext $pathContext -ComponentContract $componentContract
        [pscustomobject]@{passed=$true;status=if($rollbackRecovery.status-eq'PendingRollbackCompleted'-or$failedStateRecovery.status-eq'FailedTransactionStateRecovered'){'Recovered'}else{'NoPendingRecovery'};rollback=$rollbackRecovery;failedState=$failedStateRecovery}
    } else { [pscustomobject]@{passed=$true;status='NotApplicable';transactions=@()} }
    $plan = New-KICompletePlan -Mode $Mode -PackageRoot $PackageRoot -TargetRoot $TargetRoot -EnableOpenWebUIBallistics:$EnableOpenWebUIBallistics -ReplayComponent $ReplayComponent -PathContext $pathContext
    if ($Mode -eq 'Audit' -or $DryRun) { return [pscustomobject]@{version='2.13.0';mode=$Mode;preflight=$preflight;plan=$plan;operations=(Test-KICompleteOperations $TargetRoot -DesktopPath $DesktopPath);mutatesTarget=$false} }
    if ($Mode -eq 'Validate') { return [pscustomobject]@{version='2.13.0';mode='Validate';plan=$plan;health=(Invoke-KICompleteHealth $config);operations=(Test-KICompleteOperations $TargetRoot -DesktopPath $DesktopPath);mutatesTarget=$false} }
    if(-not$Resume -and $plan.alreadyCompliant -and -not[bool]$plan.hasReplay -and (Test-KICompleteDeploymentCompliant $PackageRoot $TargetRoot)-and(Test-KICompleteOperations $TargetRoot -DesktopPath $DesktopPath).passed){
        $needsReconciliation=@($plan.steps|Where-Object{$_.initialState.reconciliationNeeded}).Count-gt0-or[bool]$plan.stateHasOrphans
        $statePath=$null
        if($needsReconciliation){$statePath=Update-KICompleteComponentState -Plan $plan -PathContext $pathContext -CompleteVersion '2.13.0'}
        return [pscustomobject]@{version='2.13.0';mode=$Mode;status=if($needsReconciliation){'StateReconciled'}else{'SkippedAlreadyCompliant'};plan=$plan;statePath=$statePath;pendingRollback=$pendingRollback;transactionCreated=$false;backupCreated=$false;mutatesTarget=($needsReconciliation-or$pendingRollback.status-eq'Recovered')}
    }
    $state = [string]$pathContext.StateRoot
    if ($Resume) {
        $loaded=Read-KICompleteTransactionForResume -PathContext $pathContext
        $txPath=$loaded.path
        $resumePath=$loaded.resumePath
        $tx=$loaded.transaction
    }
    else {
        $created = New-KICompleteTransaction -Plan $plan -PathContext $pathContext
        $tx=$created.transaction; $txPath=$created.path; $resumePath=$created.resumePath; $TransactionId=$tx.transactionId
    }
    $tx.status='Running'; Write-KICompleteJson $txPath $tx
    $finalizationPhase = $null
    $operationsStarted = $false
    try {
        $cutoverExecuted = $false
        $index=0
        $currentStepHeartbeat=$null
        foreach ($step in @($tx.steps)) {
            $component=@($componentContract.components|Where-Object{[string]$_.id-eq[string]$step.id})|Select-Object -First 1
            if($null-eq$component){throw "Komponentenvertrag fehlt: $($step.id)"}
            Write-Host ("Schritt {0} von {1} – {2}" -f ($index+1),$tx.steps.Count,$step.name)
            if ($step.status -eq 'Completed' -or $step.status -eq 'SkippedAlreadyCompliant' -or $step.status -eq 'SkippedSupportedInstallation') {
                $resumeActual=Get-KICompleteInstalledVersion -Component $component -TargetRoot $TargetRoot
                $resumeCompliant=$resumeActual-eq[string]$step.version
                if([string]$step.id-eq'codex-local'){$resumeCompliant=$resumeCompliant-and(Test-KICompleteCodexLocalCompliant -TargetRoot $TargetRoot -ExpectedComponentVersion ([string]$step.version))}
                if([string]$step.id-eq'integration'){$resumeCompliant=$resumeCompliant-and(Test-KICompleteIntegrationCompliant -TargetRoot $TargetRoot -ExpectedComponentVersion ([string]$step.version))}
                if([string]$step.id-eq'comfyui'){$resumeCompliant=$resumeCompliant-and(Test-KICompleteComfyUICompliant -PackageRoot $PackageRoot -TargetRoot $TargetRoot)}
                if($resumeCompliant){$index++;continue}
                $step.status='Planned'
                $step.result=$null
                $step.rollbackStatus=$null
                $step.error="Resume-Readback erforderte erneutes Deployment; real=$resumeActual"
            }
            $step.startTime=[DateTime]::UtcNow.ToString('o'); $step.status='Running'; Write-KICompleteJson $txPath $tx
            $currentStepHeartbeat=New-KICompleteStepHeartbeat -StepLabel $step.name
            Write-KICompleteStepStatus -Heartbeat $currentStepHeartbeat -Status Running -Message ("Schritt {0} von {1} wird ausgeführt" -f ($index+1),$tx.steps.Count)
            if ($step.id -in @('foundation-runtime','python-git','applications','cutover-runtime')) {
                if (-not $cutoverExecuted) {
                    $extract = Join-Path ([string]$pathContext.PayloadRoot) 'CutoverRuntime'
                    $cutoverRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'CutoverRuntime' -Destination $extract
                    $kernel = Join-Path $cutoverRoot 'Invoke-KIStackBuilderKernel.ps1'
                    $preflightGenerator = Join-Path $cutoverRoot 'New-KIStackEmbeddedPreflight.ps1'
                    $preflight = Join-Path ([string]$pathContext.TempRoot) 'generated/Preflight-Continuation-v1.6.14.zip'
                    if (-not (Test-Path -LiteralPath $kernel -PathType Leaf) -or -not (Test-Path -LiteralPath $preflightGenerator -PathType Leaf)) {
                        throw 'Cutover-Kernel oder Preflight-Generator fehlt.'
                    }
                    $generatedPreflight = & $preflightGenerator -ProjectRoot $cutoverRoot -DestinationPath $preflight
                    if (-not (Test-Path -LiteralPath $generatedPreflight.path -PathType Leaf)) {
                        throw 'Der transaktionslokale Cutover-Preflight wurde nicht erzeugt.'
                    }
                    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
                    $cutoverState = Join-Path ([string]$pathContext.TempRoot) 'cutover-state'
                    $kernelTransactionId = $TransactionId + '-cutover'
                    $runtimeConfig = Write-KICompleteKernelRuntimeConfig -PathContext $pathContext -BaseConfigPath (Join-Path $cutoverRoot 'Config/kernel-config.json') -KernelTransactionId $kernelTransactionId -KernelStateRoot $cutoverState
                    if ($tx.PSObject.Properties['kernelRuntimeConfigSha256'] -and -not [string]::Equals([string]$tx.kernelRuntimeConfigSha256,[string]$runtimeConfig.sha256,[StringComparison]::OrdinalIgnoreCase)) {
                        throw 'Die deterministisch neu erzeugte Kernel-RuntimeConfig stimmt nicht mit der gespeicherten Transaktions-SHA256 überein.'
                    }
                    $tx | Add-Member -NotePropertyName kernelRuntimeConfigPath -NotePropertyValue ([string]$runtimeConfig.path) -Force
                    $tx | Add-Member -NotePropertyName kernelRuntimeConfigSha256 -NotePropertyValue ([string]$runtimeConfig.sha256) -Force
                    $tx | Add-Member -NotePropertyName kernelRuntimeConfigTransactionId -NotePropertyValue $kernelTransactionId -Force
                    Write-KICompleteJson $txPath $tx
                    $arguments = @(
                        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(ConvertTo-KICompleteProcessArgument $kernel),
                        '-PreflightPath',(ConvertTo-KICompleteProcessArgument $preflight),'-Mode','Execute','-StateDirectory',(ConvertTo-KICompleteProcessArgument $cutoverState),
                        '-TransactionId',$kernelTransactionId,'-RuntimeConfigPath',(ConvertTo-KICompleteProcessArgument ([string]$runtimeConfig.path)),
                        '-ExpectedTargetRoot',(ConvertTo-KICompleteProcessArgument ([string]$pathContext.TargetRoot)),'-ExpectedRuntimeConfigSha256',([string]$runtimeConfig.sha256),'-RollbackOnFailure',
                        '-ExecutionConfirmation','EXECUTE'
                    )
                    $cutoverTransactionPath=Join-Path $cutoverState (($TransactionId + '-cutover') + '/transaction.json')
                    if($Resume-and(Test-Path -LiteralPath $cutoverTransactionPath -PathType Leaf)){$arguments+='-Resume'}
                    $process = Start-Process -FilePath $pwsh -ArgumentList $arguments -Wait -PassThru -NoNewWindow
                    if ($process.ExitCode -eq 31) {
                        $kernelResultPath=Join-Path $cutoverState (($TransactionId + '-cutover') + '/kernel-result.json')
                        if(-not(Test-Path -LiteralPath $kernelResultPath -PathType Leaf)){throw 'Cutover-Kernel meldete RebootRequired ohne fortsetzbaren Ergebnisnachweis.'}
                        $kernelResult=Read-KICompleteJson $kernelResultPath
                        if([string]$kernelResult.status-ne'WaitingForRestart'-or-not[bool]$kernelResult.resumeAvailable){throw 'Cutover-Kernel meldete einen inkonsistenten RebootRequired-Status.'}
                        $step.status='WaitingForRestart'
                        $step.endTime=[DateTime]::UtcNow.ToString('o')
                        $step.exitCode=31
                        $step.result=@{orchestratedBy='CutoverRuntime public kernel';transactionId=($TransactionId + '-cutover');status='RebootRequired';resumeRequired=$true;kernelResultPath=$kernelResultPath;containsSecrets=$false}
                        $tx.status='WaitingForRestart'
                        Write-KICompleteJson $resumePath ([ordered]@{schemaVersion='1.0';transactionId=$TransactionId;nextStep=$index;status='WaitingForRestart';cutoverTransactionId=($TransactionId + '-cutover');completedSteps=@($tx.steps|Where-Object{$_.status -in @('Completed','SkippedAlreadyCompliant','SkippedSupportedInstallation')}|ForEach-Object id);containsSecrets=$false})
                        Write-KICompleteJson $txPath $tx
                        return $tx
                    }
                    if ($process.ExitCode -ne 0) {
                        $kernelFailure=[InvalidOperationException]::new("Cutover-Kernel fehlgeschlagen: Exitcode $($process.ExitCode)")
                        $kernelFailure.Data['KIStackExitCode']=[int]$process.ExitCode
                        throw $kernelFailure
                    }
                    $cutoverExecuted = $true
                }
                $step.result=@{orchestratedBy='CutoverRuntime public kernel';transactionId=($TransactionId + '-cutover');validated=$true}
            }
            elseif ($step.id -eq 'comfyui') {
                $action = if ($step.plannedMode -eq 'Repair') { 'Repair' } elseif ($step.plannedMode -eq 'Upgrade') { 'Upgrade' } else { 'Install' }
                # Defense in depth (does not replace the planning-time check above, or the
                # PackageRoot/fail-closed fixes to Test-KICompleteComfyUICompliant itself): re-verify
                # the real ComfyUI support status immediately before the one place that can actually
                # mutate ComfyUI source files, so a stale plan, a resumed transaction, or any future
                # planning-side regression can never reach Install-ComfyPayload -- the git-unaware
                # v0.28.0 reference-payload overlay -- against an existing, already-supported,
                # git-managed installation. Throws (fail closed, no mutation) if the probe itself
                # cannot be evaluated; see Test-KICompleteComfyUICompliant.
                if (Test-KICompleteComfyUICompliant -PackageRoot $PackageRoot -TargetRoot $TargetRoot) {
                    $step.result=@{skippedReason='ExistingSupportedInstallationProtected'}
                    $step.status='SkippedSupportedInstallation'
                }
                else {
                    $extract = Join-Path ([string]$pathContext.PayloadRoot) 'ComfyUI'
                    $componentRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'ComfyUI' -Destination $extract
                    $entry = Join-Path $componentRoot 'Invoke-KIStackComfyUI.ps1'
                    $result = Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action=$action;TargetRoot=(Join-Path $TargetRoot 'ComfyUI')}
                    try {
                        $validation = Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action='Validate';TargetRoot=(Join-Path $TargetRoot 'ComfyUI')}
                        $actual = Get-KICompleteInstalledVersion -Component $component -TargetRoot $TargetRoot
                        if (-not [bool]$validation.passed -or $actual -ne [string]$component.version) {
                            throw "ComfyUI-Readback verletzt: Payload=$([bool]$validation.passed); Marker=$actual; erwartet=$($component.version)"
                        }
                        $step.result=@{install=$result;validation=$validation;markerVersion=$actual}
                    }
                    catch {
                        $rollbackStatus = 'Failed'
                        try {
                            if ($result.changed -and $result.backup) {
                                $rollback = Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action='Rollback';TargetRoot=(Join-Path $TargetRoot 'ComfyUI');BackupPath=[string]$result.backup}
                                if ([bool]$rollback.passed) { $rollbackStatus='Completed' }
                            } else { $rollbackStatus='NotRequired' }
                        } catch { $rollbackStatus='Failed' }
                        $_.Exception.Data['KIStackRollbackStatus']=$rollbackStatus
                        $_.Exception.Data['KIStackBackupPath']=[string]$result.backup
                        throw
                    }
                }
            }
            elseif ($step.id -eq 'integration') {
                $extract = Join-Path ([string]$pathContext.PayloadRoot) 'Integration'
                $componentRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'Integration' -Destination $extract
                $entry = Join-Path $componentRoot 'Invoke-KIStackIntegration.ps1'
                $action = if ($step.plannedMode -eq 'Repair') { 'Repair' } elseif ($step.plannedMode -eq 'Upgrade') { 'Upgrade' } else { 'Install' }
                $result = Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action=$action}
                $validation = Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action='Validate'}
                if (-not [bool]$validation.passed) { throw 'Integration-Validierung fehlgeschlagen.' }
                $step.result=@{install=$result;validation=$validation}
            }
            elseif ($step.id -eq 'models-workflows') {
                $extract = Join-Path ([string]$pathContext.PayloadRoot) 'ModelsWorkflows'
                $componentRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'ModelsWorkflows' -Destination $extract
                $entry = Join-Path $componentRoot 'Import-KIStackExternalModels.ps1'
                $result = & $entry -Mode Install -SourcePath (Join-Path $PackageRoot 'ExternalModels') -TargetRoot $TargetRoot `
                    -StateRoot (Join-Path ([string]$pathContext.TempRoot) 'model-import') -TransactionId ($TransactionId + '-models')
                if (-not [bool]$result.passed) {
                    $step.status='WaitingForUserAction'
                    $waiting=@($result.results|Where-Object status -eq 'WaitingForNetwork'|ForEach-Object id)
                    $step.result=@{
                        reason='Externe Modellquelle ist nicht erreichbar; verifizierte Teildownloads bleiben fortsetzbar.'
                        waitingForNetwork=$waiting
                        resumable=[bool]$result.resumable
                        importResult=$result
                    }
                }
                else {
                    if (-not (Test-KICompleteModelsWorkflowsCompliant -PackageRoot $PackageRoot -TargetRoot $TargetRoot)) {
                        throw 'Modelle-/Workflow-Zielvalidierung fehlgeschlagen.'
                    }
                    $step.result=@{importResult=$result;validated=$true}
                }
            }
            elseif ($step.id -in @('openwebui-agent-pack','openwebui-visual-pack')) {
                if($null-eq$OpenWebUIApiToken){
                    $step.status='WaitingForUserAction'; $step.result=@{reason='OpenWebUI-Erstanmeldung oder temporärer API-Schlüssel erforderlich';apiKeyStored=$false}
                }
                else {
                    $payloadName=if($step.id-eq'openwebui-agent-pack'){'OpenWebUIAgentPack'}else{'OpenWebUIVisualPack'}
                    $payload=Get-ChildItem -LiteralPath (Join-Path $PackageRoot ('Payload/'+$payloadName)) -File -Filter '*.zip'|Select-Object -First 1
                    if(-not$payload){throw "Payload fehlt: $payloadName"}
                    $extract=Join-Path ([string]$pathContext.PayloadRoot) $payloadName
                    if(Test-Path -LiteralPath $extract){Remove-Item -LiteralPath $extract -Recurse -Force}
                    Expand-Archive -LiteralPath $payload.FullName -DestinationPath $extract
                    if($step.id-eq'openwebui-agent-pack'){
                        $module=Get-ChildItem -LiteralPath $extract -Recurse -File -Filter 'OpenWebUIAgentPack.psm1'|Select-Object -First 1
                        if(-not$module){throw 'Agent-Pack-Modul fehlt.'}
                        Import-Module $module.FullName -Force
                        $agentPackageRoot=Split-Path -Parent $module.FullName
                        $agentBackupDirectory=Join-Path ([string]$pathContext.TransactionBackupRoot) 'agent-pack'
                        New-Item -ItemType Directory -Path $agentBackupDirectory -Force|Out-Null
                        $agentMarkerPath=Join-Path $TargetRoot 'modules/openwebui-agent-pack/installation.json'
                        $agentMarkerBackup=Join-Path $agentBackupDirectory 'component-marker.backup.json'
                        [ordered]@{
                            existed=(Test-Path -LiteralPath $agentMarkerPath -PathType Leaf)
                            content=if(Test-Path -LiteralPath $agentMarkerPath -PathType Leaf){Get-Content -LiteralPath $agentMarkerPath -Raw}else{$null}
                        }|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $agentMarkerBackup -Encoding UTF8
                        $result=Install-OpenWebUIAgentPack -PackageRoot $agentPackageRoot -Endpoint ([string]$config.openWebUIEndpoint) -ApiToken $OpenWebUIApiToken -BaseModelId '' -BackupDirectory $agentBackupDirectory
                        $result|Add-Member -NotePropertyName markerBackupPath -NotePropertyValue $agentMarkerBackup -Force
                        $validation=Test-OpenWebUIAgentPack -PackageRoot $agentPackageRoot -Endpoint ([string]$config.openWebUIEndpoint) -ApiToken $OpenWebUIApiToken -BaseModelId ([string]$result.baseModelId)
                    }
                    else {
                        $installer=Get-ChildItem -LiteralPath $extract -Recurse -File -Filter 'Install-KIStack-OpenWebUI-VisualPack-v2.0.5.ps1'|Select-Object -First 1
                        if(-not$installer){throw 'Visual-Pack-Installer fehlt.'}
                        $result = & $installer.FullName -Action Install -KIStackRoot $TargetRoot -OpenWebUIEndpoint ([string]$config.openWebUIEndpoint) -ApiToken $OpenWebUIApiToken
                        if ($null -eq $result -or -not [bool]$result.passed -or [string]::IsNullOrWhiteSpace([string]$result.backupPath)) {
                            throw 'Visual-Pack-Installer lieferte keinen gültigen Installations-/Backupnachweis.'
                        }
                        $validation=[pscustomobject]@{passed=$true;failures=@()}
                    }
                    if(-not$validation.passed){throw ("$($step.name) Validierung fehlgeschlagen: "+($validation.failures-join'; '))}
                    Write-KICompleteComponentMarker -Component $component -TargetRoot $TargetRoot
                    $step.result=@{
                        backupPath=$result.backupPath
                        markerBackupPath=if($step.id-eq'openwebui-agent-pack'){[string]$result.markerBackupPath}else{$null}
                        apiKeyStored=$false
                        validated=$true
                    }
                }
            }
            elseif ($step.id -eq 'openwebui-ballistics-pack') {
                if($null-eq$OpenWebUIApiToken){$OpenWebUIApiToken=Read-Host 'Temporären OpenWebUI-Administrator-API-Key eingeben' -AsSecureString}
                $payload=Get-ChildItem (Join-Path $PackageRoot 'Payload/OpenWebUIBallisticsPack') -Filter '*.zip' -File|Select-Object -First 1;if(-not$payload){throw'Ballistics-Pack-Payload fehlt.'}
                $extract=Join-Path ([string]$pathContext.PayloadRoot) 'ballistics-package';if(Test-Path $extract){Remove-Item $extract -Recurse -Force};Expand-Archive $payload.FullName $extract
                $module=Get-ChildItem $extract -Filter 'OpenWebUIBallisticsPack.psm1' -Recurse -File|Select-Object -First 1;if(-not$module){throw'Ballistics-Pack-Modul fehlt.'};Import-Module $module.FullName -Force
                $packageRoot=Split-Path $module.FullName -Parent;$result=Install-OpenWebUIBallisticsPack $packageRoot ([string]$config.openWebUIEndpoint) $OpenWebUIApiToken '' (Join-Path ([string]$pathContext.TransactionBackupRoot) 'ballistics') $TargetRoot
                $step.result=$result;$step.backup=$result.backupPath
            }
            elseif ($step.id -eq 'codex-local') {
                $extract=Join-Path ([string]$pathContext.PayloadRoot) 'CodexLocal'
                $componentRoot=Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'CodexLocal' -Destination $extract
                $entry=Join-Path $componentRoot 'Invoke-KIStackCodexLocal.ps1'
                if(-not(Test-Path -LiteralPath $entry -PathType Leaf)){throw 'Codex-Local-Einstieg fehlt.'}
                $result=$null
                try{
                    $result=Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action='Install';TargetRoot=$TargetRoot;WorkspacePath=$TargetRoot}
                    if(-not[bool]$result.passed){throw 'Codex-Local-Installation fehlgeschlagen.'}
                    $validation=Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action='Validate';TargetRoot=$TargetRoot}
                    if(-not[bool]$validation.passed){throw 'Codex-Local-Validierung fehlgeschlagen.'}
                    $step.backup=[string]$result.marker.backupPath
                    $step.result=@{install=$result;validation=$validation;backupPath=[string]$result.marker.backupPath;validated=$true}
                }catch{
                    if($null -ne $result -and$null-ne$result.marker-and-not [string]::IsNullOrWhiteSpace([string]$result.marker.backupPath)){
                        $rollback=Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action='Rollback';BackupPath=[string]$result.marker.backupPath}
                        $_.Exception.Data['KIStackRollbackStatus']=if([bool]$rollback.passed){'Completed'}else{'Failed'}
                        $_.Exception.Data['KIStackBackupPath']=[string]$result.marker.backupPath
                    }
                    throw
                }
            }
            elseif ($step.id -eq 'rag') {
                $extract=Join-Path ([string]$pathContext.PayloadRoot) 'RAG'
                $componentRoot=Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'RAG' -Destination $extract
                $test=Join-Path $componentRoot 'Test-KIStackRAG.ps1'
                if(-not(Test-Path -LiteralPath $test -PathType Leaf)){throw 'RAG-Selbsttest fehlt.'}
                $validation=Invoke-KICompleteJsonScript -Script $test -Arguments @{PackageRoot=$componentRoot}
                if(-not[bool]$validation.passed){throw ('RAG-Quellvalidierung fehlgeschlagen: '+(@($validation.failures)-join'; '))}
                $backupRoot=Join-Path ([string]$pathContext.TransactionBackupRoot) 'rag'
                $result=Install-KICompleteRAGModule -ComponentRoot $componentRoot -TargetRoot $TargetRoot -BackupRoot $backupRoot
                $step.backup=$backupRoot
                $step.result=@{install=$result;validation=$validation;ingestionDeferred=$true;validated=$true}
            }
            elseif ($step.id -eq 'validation-gate') {
                $payload=Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Payload/ValidationGate') -File -Filter '*.zip'|Select-Object -First 1
                if(-not$payload){throw 'Validation-Gate-Payload fehlt.'}
                $extract=Join-Path ([string]$pathContext.PayloadRoot) 'ValidationGate'
                if(Test-Path -LiteralPath $extract){Remove-Item -LiteralPath $extract -Recurse -Force}
                Expand-Archive -LiteralPath $payload.FullName -DestinationPath $extract
                $installer=Get-ChildItem -LiteralPath $extract -Recurse -File -Filter 'Install-KIStack-ValidationGate.ps1'|Select-Object -First 1
                if(-not$installer){throw 'Öffentlicher Validation-Gate-Installer fehlt.'}
                $installRoot=Join-Path $TargetRoot 'Tools/PackageValidationGate'
                $backupRoot=Join-Path ([string]$pathContext.TransactionBackupRoot) 'validation-gate'
                $currentRoot=Join-Path $installRoot 'current'
                if(Test-Path -LiteralPath $currentRoot){
                    New-Item -ItemType Directory -Path $backupRoot -Force|Out-Null
                    Copy-Item -LiteralPath $currentRoot -Destination (Join-Path $backupRoot 'current') -Recurse -Force
                }
                try {
                    & $installer.FullName -InstallRoot $installRoot
                    if($LASTEXITCODE-ne0){throw "Validation-Gate-Installer Exitcode $LASTEXITCODE"}
                    $installedVersionPath=Join-Path $currentRoot 'VERSION'
                    if(-not(Test-Path -LiteralPath $installedVersionPath)-or(Get-Content -LiteralPath $installedVersionPath -Raw).Trim()-ne[string]$step.version){
                        throw 'Installierte Validation-Gate-Version stimmt nicht mit dem Komponentenvertrag überein.'
                    }
                }
                catch {
                    if(Test-Path -LiteralPath (Join-Path $backupRoot 'current')){
                        if(Test-Path -LiteralPath $currentRoot){Remove-Item -LiteralPath $currentRoot -Recurse -Force}
                        Copy-Item -LiteralPath (Join-Path $backupRoot 'current') -Destination $currentRoot -Recurse -Force
                    }
                    throw
                }
                $step.backup=$backupRoot
                $step.result=@{orchestratedBy='public Validation Gate installer';validated=$true;installedVersion=[string]$step.version;backupPath=$backupRoot}
            }
            elseif ($step.id -in @('foundation-runtime','python-git','applications','cutover-runtime','production-recovery','target-acceptance')) {
                $step.result=@{orchestratedBy='pinned non-installable reference';validated=$true}
            }
            else {
                throw "Kein öffentlicher Installationspfad für nicht-konforme Komponente: $($step.id)"
            }
            if ($step.status -ne 'WaitingForUserAction' -and $step.status -ne 'SkippedSupportedInstallation') {
                if([bool]$component.installable){
                    $actualVersion=Get-KICompleteInstalledVersion -Component $component -TargetRoot $TargetRoot
                    if($actualVersion-ne[string]$step.version){throw "Komponenten-Readback verletzt: $($step.id); erwartet=$($step.version); real=$actualVersion"}
                    if($null-eq$step.result){$step.result=@{}}
                    $step.result.actualVersion=$actualVersion
                }
                $step.status='Completed'
            }
            $step.endTime=[DateTime]::UtcNow.ToString('o'); $step.exitCode=0; $index++
            if($step.status-eq'WaitingForUserAction'){
                Write-KICompleteStepStatus -Heartbeat $currentStepHeartbeat -Status WaitingForUserAction -Message ([string]$step.result.reason)
            }else{
                Write-KICompleteStepStatus -Heartbeat $currentStepHeartbeat -Status Completed -Message ("{0} abgeschlossen" -f $step.name)
            }
            Write-KICompleteJson $resumePath ([ordered]@{schemaVersion='1.0';transactionId=$TransactionId;nextStep=$index;completedSteps=@($tx.steps|Where-Object{$_.status -in @('Completed','SkippedAlreadyCompliant','SkippedSupportedInstallation')}|ForEach-Object id);containsSecrets=$false})
            Write-KICompleteJson $txPath $tx
        }
        $backup=[string]$pathContext.TransactionBackupRoot
        $finalizationPhase = 'InstallOrchestrator'
        $orchestratorChanges=Install-KICompleteOrchestrator $PackageRoot $TargetRoot $backup
        $finalizationPhase = 'InstallCentralStarters'
        $starterChanges=Install-KICompleteCentralStarters $PackageRoot $TargetRoot $backup
        $finalizationPhase = 'InstallOperations'
        $operationsStarted = $true
        $operations=Install-KICompleteOperations $TargetRoot (Join-Path $backup 'operations') -DesktopPath $DesktopPath -PathContext $pathContext
        $finalizationPhase = 'RemoveKnowledgeExperiment'
        $knowledgeRollback=if($null-ne$OpenWebUIApiToken){& (Join-Path $PackageRoot 'Operations/Remove-KIStackKnowledgeExperiment.ps1') -Endpoint ([string]$config.openWebUIEndpoint) -ApiToken $OpenWebUIApiToken -BackupDirectory (Join-Path $backup 'knowledge-rollback')}else{[pscustomobject]@{status='CredentialRequiredForApiReadback';apiKeyStored=$false}}
        $finalizationPhase = 'SetCodeInterpreter'
        $codeInterpreter=if($null-ne$OpenWebUIApiToken){& (Join-Path $PackageRoot 'Operations/Set-KIStackCodeInterpreter.ps1') -Endpoint ([string]$config.openWebUIEndpoint) -ApiToken $OpenWebUIApiToken -BackupDirectory (Join-Path $backup 'code-interpreter')}else{[pscustomobject]@{status='CredentialRequiredForApiConfiguration';apiKeyStored=$false}}
        $finalizationPhase = 'WriteFinalState'
        $tx|Add-Member -NotePropertyName finalization -NotePropertyValue ([ordered]@{orchestratorFiles=$orchestratorChanges;centralStarters=$starterChanges;operations=$operations;knowledgeRollback=$knowledgeRollback;codeInterpreter=$codeInterpreter}) -Force
        $tx = Clear-KICompleteStaleTransactionError -Transaction $tx
        if (@($tx.steps|Where-Object{$_.status -eq 'WaitingForUserAction'}).Count) {$tx.status='WaitingForUserAction'} else {$tx.status='Completed'}
        $componentStatePath=Get-KICompleteComponentStatePath -PathContext $pathContext;$componentVersions=[ordered]@{}
        foreach($completed in @($tx.steps|Where-Object{$_.status-in@('Completed','SkippedAlreadyCompliant','SkippedSupportedInstallation')})){$componentVersions[[string]$completed.id]=[string]$completed.version}
        Write-KICompleteJson $componentStatePath ([ordered]@{schemaVersion='1.0';status=if($tx.status-eq'Completed'){'ValidatedExistingInstallation'}else{$tx.status};completeInstallerVersion='2.13.0';validatedAtUtc=[DateTime]::UtcNow.ToString('o');components=$componentVersions;evidence=[ordered]@{optionalBallisticsEnabled=[bool]$EnableOpenWebUIBallistics;manualStartupOnly=$true;containsSecrets=$false;containsPersonalPaths=$false;pendingRollback=$pendingRollback}})
        Write-KICompleteJson $txPath $tx; return $tx
    }
    catch {
        $failure = $_
        $tx | Add-Member -NotePropertyName error -NotePropertyValue $failure.Exception.Message -Force
        if (-not [string]::IsNullOrWhiteSpace([string]$finalizationPhase)) {
            $tx | Add-Member -NotePropertyName failedPhase -NotePropertyValue $finalizationPhase -Force
        }
        $runningStep = @($tx.steps | Where-Object status -eq 'Running' | Select-Object -First 1)
        if ($runningStep.Count -eq 1) {
            $runningStep[0].status = 'Failed'
            $runningStep[0].endTime = [DateTime]::UtcNow.ToString('o')
            $runningStep[0].exitCode = 1
            $runningStep[0].error = $failure.Exception.Message
            if ($failure.Exception.Data.Contains('KIStackRollbackStatus')) {
                $runningStep[0].rollbackStatus = [string]$failure.Exception.Data['KIStackRollbackStatus']
            }
            if ($failure.Exception.Data.Contains('KIStackBackupPath')) {
                $runningStep[0].backup = [string]$failure.Exception.Data['KIStackBackupPath']
            }
            $failureHeartbeat=if($null-ne$currentStepHeartbeat){$currentStepHeartbeat}else{New-KICompleteStepHeartbeat -StepLabel $runningStep[0].name}
            Write-KICompleteStepStatus -Heartbeat $failureHeartbeat -Status Failed -Message $failure.Exception.Message
        }
        if ($operationsStarted -and $finalizationPhase -eq 'InstallOperations') {
            try {
                $operationsRollback = Restore-KICompleteOperations -TargetRoot $TargetRoot -BackupPath (Join-Path $backup 'operations/operations.backup.json') -PathContext $pathContext
                $tx | Add-Member -NotePropertyName finalizationRollback -NotePropertyValue $operationsRollback -Force
            }
            catch {
                $tx | Add-Member -NotePropertyName finalizationRollback -NotePropertyValue ([ordered]@{status='Failed';error=$_.Exception.Message}) -Force
            }
        }
        elseif ($failure.Exception.Data.Contains('KIStackRollbackStatus')) {
            $tx | Add-Member -NotePropertyName finalizationRollback -NotePropertyValue ([ordered]@{
                status=[string]$failure.Exception.Data['KIStackRollbackStatus']
                backupPath=[string]$failure.Exception.Data['KIStackBackupPath']
            }) -Force
        }
        $agentStep=@($tx.steps|Where-Object{$_.id-eq'openwebui-agent-pack'-and$_.status-eq'Completed'-and$null-ne$_.result.backupPath}|Select-Object -First 1)
        if($agentStep.Count-eq1-and$null-ne$OpenWebUIApiToken){
            try{
                Restore-OpenWebUIAgentPack -Endpoint ([string]$config.openWebUIEndpoint) -ApiToken $OpenWebUIApiToken -BackupPath ([string]$agentStep[0].result.backupPath)
                $markerBackupPath=[string]$agentStep[0].result.markerBackupPath
                if(Test-Path -LiteralPath $markerBackupPath){
                    $markerBackup=Get-Content -LiteralPath $markerBackupPath -Raw|ConvertFrom-Json
                    $markerPath=Join-Path $TargetRoot 'modules/openwebui-agent-pack/installation.json'
                    if([bool]$markerBackup.existed){
                        New-Item -ItemType Directory -Path (Split-Path -Parent $markerPath) -Force|Out-Null
                        [IO.File]::WriteAllText($markerPath,[string]$markerBackup.content,[Text.UTF8Encoding]::new($false))
                    }
                    elseif(Test-Path -LiteralPath $markerPath){Remove-Item -LiteralPath $markerPath -Force}
                }
                $agentStep[0].rollbackStatus='Completed'
                $tx|Add-Member -NotePropertyName componentRollback -NotePropertyValue ([ordered]@{id='openwebui-agent-pack';status='Completed';backupPath=[string]$agentStep[0].result.backupPath}) -Force
            }
            catch{
                $agentStep[0].rollbackStatus='Failed'
                $tx|Add-Member -NotePropertyName componentRollback -NotePropertyValue ([ordered]@{id='openwebui-agent-pack';status='Failed';error=$_.Exception.Message}) -Force
            }
        }
        $tx.status='Failed'
        Write-KICompleteJson $txPath $tx
        throw
    }
    finally { $OpenWebUIApiToken=$null; [GC]::Collect() }
}

Export-ModuleMember -Function *

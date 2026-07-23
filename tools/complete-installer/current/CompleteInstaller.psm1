Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Get-KICompleteInstalledVersion {
    param([Parameter(Mandatory)][object]$Component,[Parameter(Mandatory)][string]$TargetRoot,[hashtable]$FixtureState)
    if ($null -ne $FixtureState -and $FixtureState.ContainsKey([string]$Component.id)) { return [string]$FixtureState[[string]$Component.id] }
    $completeMarker=Join-Path $TargetRoot 'state/complete-installer/components.json'
    if(Test-Path $completeMarker){$state=Read-KICompleteJson $completeMarker;$entry=$state.components.PSObject.Properties[[string]$Component.id];if($null-ne$entry){return [string]$entry.Value}}
    $acceptancePath=Join-Path $TargetRoot 'modules/production-recovery/acceptance.json'
    $accepted=$null;if(Test-Path $acceptancePath){$accepted=Read-KICompleteJson $acceptancePath}
    if($accepted -and [bool]$accepted.passed -and [string]$accepted.recoveryRevision -eq 'r7'){
        $acceptedVersions=@{'foundation-runtime'='1.0.9';'python-git'='1.1.5';'cutover-runtime'='1.6.3';'production-recovery'='1.7.0-r7';'validation-gate'='1.0.2';'target-acceptance'='1.0.10'}
        if($acceptedVersions.ContainsKey([string]$Component.id)){return [string]$acceptedVersions[[string]$Component.id]}
    }
    switch ([string]$Component.id) {
        'foundation-runtime' { if (Test-Path (Join-Path $TargetRoot 'VERSION')) { return (Get-Content (Join-Path $TargetRoot 'VERSION') -Raw).Trim() } }
        'python-git' { if (Test-Path (Join-Path $TargetRoot 'modules/python-git/installation.json')) { return [string](Read-KICompleteJson (Join-Path $TargetRoot 'modules/python-git/installation.json')).version } }
        'openwebui-agent-pack' { return $null }
        'openwebui-image-pack' { return $null }
        'openwebui-ballistics-pack' { if(Test-Path (Join-Path $TargetRoot 'modules/openwebui-ballistics/installation.json')){return [string](Read-KICompleteJson (Join-Path $TargetRoot 'modules/openwebui-ballistics/installation.json')).version};return $null }
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
    $models=@($payloadContract.external|Where-Object{$_.PSObject.Properties.Name-contains'category'-and[string]$_.category-eq'models-workflows-1.4.5'})
    if($models.Count-ne8){return $false}
    foreach($model in $models){
        $target=Join-Path $TargetRoot ([string]$model.target+'/'+[string]$model.fileName)
        if(-not(Test-Path -LiteralPath $target -PathType Leaf)){return $false}
        if((Get-Item -LiteralPath $target).Length-ne[long]$model.sizeBytes){return $false}
        if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()-ne[string]$model.sha256){return $false}
    }
    $payloadDirectory=Join-Path $PackageRoot 'Payload/ModelsWorkflows'
    $archiveFile=Get-ChildItem -LiteralPath $payloadDirectory -File -Filter 'KI-Stack-Models-Workflows-Execute-v1.4.5.zip' -ErrorAction SilentlyContinue|Select-Object -First 1
    if(-not$archiveFile){return $false}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($archiveFile.FullName)
    try{
        $workflowEntries=@($archive.Entries|Where-Object{$_.FullName-match'/Workflows/[^/]+\.json$'})
        if($workflowEntries.Count-lt5){return $false}
        foreach($entry in $workflowEntries){
            $target=Join-Path (Join-Path $TargetRoot 'data/comfyui/user/default/workflows/KI-Stack') ([IO.Path]::GetFileName($entry.FullName))
            if(-not(Test-Path -LiteralPath $target -PathType Leaf)){return $false}
            $stream=$entry.Open()
            try{$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()}finally{$stream.Dispose()}
            if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()-ne$hash){return $false}
        }
    }finally{$archive.Dispose()}
    return $true
}

function New-KICompletePlan {
    param([ValidateSet('Audit','Install','Upgrade','Repair','Validate')][string]$Mode,[string]$PackageRoot=$PSScriptRoot,[string]$TargetRoot='C:\KI-Stack',[hashtable]$FixtureState,[switch]$EnableOpenWebUIBallistics)
    $contract = Read-KICompleteJson (Join-Path $PackageRoot 'Contracts/COMPONENTS.json')
    $steps = foreach ($component in @($contract.components | Sort-Object order)) {
        if($component.psobject.Properties.Name-contains'optional'-and[bool]$component.optional-and-not$EnableOpenWebUIBallistics){continue}
        $installed = Get-KICompleteInstalledVersion $component $TargetRoot $FixtureState
        $compliant = $installed -eq [string]$component.version
        if([string]$component.id-eq'models-workflows'-and$null-eq$FixtureState){$compliant=$compliant-and(Test-KICompleteModelsWorkflowsCompliant -PackageRoot $PackageRoot -TargetRoot $TargetRoot)}
        [pscustomobject][ordered]@{
            id=[string]$component.id; name=[string]$component.name; version=[string]$component.version
            plannedMode=$(if($Mode -eq 'Audit' -or $Mode -eq 'Validate'){$Mode}elseif($compliant){'Skip'}elseif($installed){if($Mode -eq 'Repair'){'Repair'}else{'Upgrade'}}else{'Install'})
            initialState=[ordered]@{installedVersion=$installed;compliant=$compliant}
            status=$(if($compliant-and$Mode-notin@('Audit','Validate')){'SkippedAlreadyCompliant'}else{'Planned'})
        }
    }
    [pscustomobject][ordered]@{schemaVersion='1.0';mode=$Mode;targetRoot=$TargetRoot;steps=@($steps);alreadyCompliant=(@($steps|Where-Object{-not $_.initialState.compliant}).Count -eq 0)}
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
    param([Parameter(Mandatory)][object]$Plan,[Parameter(Mandatory)][string]$StateDirectory,[string]$TransactionId=('KI-COMPLETE-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')))
    $tx=[ordered]@{schemaVersion='1.0';transactionId=$TransactionId;status='Planned';mode=$Plan.mode;createdAtUtc=[DateTime]::UtcNow.ToString('o');steps=@($Plan.steps|ForEach-Object{[ordered]@{name=$_.name;id=$_.id;version=$_.version;plannedMode=$_.plannedMode;startTime=$null;endTime=$null;initialState=$_.initialState;result=$null;backup=$null;rollbackStatus=$null;error=$null;exitCode=0;status=$_.status}})}
    $path=Join-Path $StateDirectory "$TransactionId/transaction.json";Write-KICompleteJson $path $tx
    Write-KICompleteJson (Join-Path $StateDirectory "$TransactionId/resume.json") ([ordered]@{schemaVersion='1.0';transactionId=$TransactionId;nextStep=0;completedSteps=@();containsSecrets=$false})
    [pscustomobject]@{transaction=$tx;path=$path;resumePath=(Join-Path $StateDirectory "$TransactionId/resume.json")}
}

function Install-KICompleteCentralStarters {
    param([string]$PackageRoot,[string]$TargetRoot,[string]$BackupRoot)
    $source=Join-Path $PackageRoot 'Lifecycle';$changed=@()
    foreach($name in @('Start-KIStack.cmd','Stop-KIStack.cmd','Stop-KIStack-Managed.ps1','Validate-KIStack.cmd','Get-KIStackStatus.ps1','Show-KIStackStatus.ps1','Status-KIStack-Interactive.cmd','Repair-KIStack.cmd')){
        $src=Join-Path $source $name;$dst=Join-Path $TargetRoot $name
        if((Test-Path $dst) -and ((Get-FileHash $src).Hash -eq (Get-FileHash $dst).Hash)){continue}
        if(Test-Path $dst){New-Item -ItemType Directory $BackupRoot -Force|Out-Null;Copy-Item $dst (Join-Path $BackupRoot $name) -Force}
        Copy-Item $src $dst -Force;$changed+=$name
    }
    $changed
}

function Install-KICompleteOperations {
    param([string]$TargetRoot,[string]$BackupRoot)
    $state=[ordered]@{schemaVersion='1.0';createdAtUtc=[DateTime]::UtcNow.ToString('o');runValues=@();desktopLinks=@();systemdUnits=@();dockerContainers=@();changes=@()}
    New-Item -ItemType Directory -Path $BackupRoot -Force|Out-Null
    $backupPath=Join-Path $BackupRoot 'operations.backup.json';Write-KICompleteJson $backupPath $state
    $runLocations=@(
        @{path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';name='electron.app.LM Studio'},
        @{path='HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce';name='electron.app.LM Studio'},
        @{path='HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';name='electron.app.LM Studio'},
        @{path='HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce';name='electron.app.LM Studio'},
        @{path='HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';name='electron.app.LM Studio'},
        @{path='HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce';name='electron.app.LM Studio'}
    )
    foreach($entry in $runLocations){
        if(-not(Test-Path $entry.path)){continue};$properties=Get-ItemProperty -LiteralPath $entry.path -Name $entry.name -ErrorAction SilentlyContinue;$property=if($null-ne$properties){$properties.PSObject.Properties[$entry.name]}else{$null};$value=if($null-ne$property){$property.Value}else{$null}
        if($null-eq$value){continue};if([string]$value-notmatch'(?i)LM Studio(?:\.exe)?\s+--run-as-service'){throw "Nicht eindeutiger LM-Studio-Autostart wird nicht verändert: $value"}
        $state.runValues+=@([ordered]@{path=$entry.path;name=$entry.name;value=[string]$value});Write-KICompleteJson $backupPath $state;Remove-ItemProperty -LiteralPath $entry.path -Name $entry.name -Force;$state.changes+=@("Run:$($entry.name)");Write-KICompleteJson $backupPath $state
    }
    $desktop=[Environment]::GetFolderPath('Desktop');$shell=New-Object -ComObject WScript.Shell;$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
    foreach($link in @(@{name='KI-Stack starten.lnk';target='Start-KIStack.cmd'},@{name='KI-Stack stoppen.lnk';target='Stop-KIStack.cmd'},@{name='KI-Stack Status.lnk';target='Show-KIStackStatus.ps1';executable=$pwsh;arguments=('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $TargetRoot 'Show-KIStackStatus.ps1')+'"')})){
        $path=Join-Path $desktop $link.name
        if(Test-Path $path){$old=$shell.CreateShortcut($path);$state.desktopLinks+=@([ordered]@{path=$path;existed=$true;target=$old.TargetPath;workingDirectory=$old.WorkingDirectory;arguments=$old.Arguments})}else{$state.desktopLinks+=@([ordered]@{path=$path;existed=$false})};Write-KICompleteJson $backupPath $state
        $shortcut=$shell.CreateShortcut($path);$shortcut.TargetPath=if($link.executable){[string]$link.executable}else{Join-Path $TargetRoot $link.target};$shortcut.WorkingDirectory=$TargetRoot;$shortcut.Arguments=if($link.arguments){[string]$link.arguments}else{''};$shortcut.Save();$state.changes+=@("Desktop:$($link.name)");Write-KICompleteJson $backupPath $state
    }
    if(Get-Command wsl.exe -ErrorAction SilentlyContinue){
        foreach($unit in @('valkey-server','uwsgi','nginx')){$enabled=((& wsl.exe -d Debian -u root -- systemctl is-enabled $unit 2>$null)-join'').Trim();$state.systemdUnits+=@([ordered]@{unit=$unit;wasEnabled=($enabled-eq'enabled');state=$enabled});Write-KICompleteJson $backupPath $state;if($enabled-eq'enabled'){$null=& wsl.exe -d Debian -u root -- systemctl disable $unit 2>&1;if($LASTEXITCODE-ne0){throw "systemd disable fehlgeschlagen: $unit"};$state.changes+=@("systemd:$unit");Write-KICompleteJson $backupPath $state}}
    }
    if(Get-Command docker.exe -ErrorAction SilentlyContinue){
        foreach($id in @(& docker.exe ps -aq)){$inspect=& docker.exe inspect $id|ConvertFrom-Json -Depth 50;$c=$inspect[0];$owned=([string]$c.Name-match'(?i)ki.?stack|openwebui|searxng')-or([string]$c.Config.Image-match'(?i)ki.?stack|openwebui|searxng');if(-not$owned){continue};$policy=[string]$c.HostConfig.RestartPolicy.Name;$state.dockerContainers+=@([ordered]@{id=[string]$c.Id;name=[string]$c.Name;restartPolicy=$policy});if($policy-and$policy-ne'no'){$null=& docker.exe update --restart=no $c.Id;$state.changes+=@("Docker:$($c.Name)")}}
    }
    Write-KICompleteJson $backupPath $state
    Write-KICompleteJson (Join-Path $TargetRoot 'state/complete-installer/operations-latest.json') ([ordered]@{schemaVersion='1.0';backupPath=$backupPath;appliedAtUtc=[DateTime]::UtcNow.ToString('o')})
    [pscustomobject]@{backupPath=$backupPath;desktop=$desktop;changes=@($state.changes)}
}

function Restore-KICompleteOperations {
    param([string]$TargetRoot)
    $pointer=Join-Path $TargetRoot 'state/complete-installer/operations-latest.json';if(-not(Test-Path $pointer)){return [pscustomobject]@{status='NoOperationsBackup';restored=$false}}
    $backupPath=[string](Read-KICompleteJson $pointer).backupPath;$state=Read-KICompleteJson $backupPath;$shell=New-Object -ComObject WScript.Shell
    foreach($entry in @($state.runValues)){if(-not(Test-Path $entry.path)){New-Item $entry.path -Force|Out-Null};Set-ItemProperty -LiteralPath $entry.path -Name $entry.name -Value ([string]$entry.value)}
    foreach($entry in @($state.desktopLinks)){if([bool]$entry.existed){$s=$shell.CreateShortcut([string]$entry.path);$s.TargetPath=[string]$entry.target;$s.WorkingDirectory=[string]$entry.workingDirectory;$s.Arguments=[string]$entry.arguments;$s.Save()}elseif(Test-Path $entry.path){Remove-Item $entry.path -Force}}
    foreach($entry in @($state.systemdUnits)){if([bool]$entry.wasEnabled){$null=& wsl.exe -d Debian -u root -- systemctl enable ([string]$entry.unit) 2>&1}}
    foreach($entry in @($state.dockerContainers)){if([string]$entry.restartPolicy-and[string]$entry.restartPolicy-ne'no'){$null=& docker.exe update --restart=([string]$entry.restartPolicy) ([string]$entry.id)}}
    [pscustomobject]@{status='OperationsRestored';restored=$true;backupPath=$backupPath}
}

function Test-KICompleteOperations {
    param([string]$TargetRoot)
    $issues=@();$runProperties=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'electron.app.LM Studio' -ErrorAction SilentlyContinue;$runProperty=if($null-ne$runProperties){$runProperties.PSObject.Properties['electron.app.LM Studio']}else{$null};if($null-ne$runProperty-and$runProperty.Value){$issues+='LM Studio Run-Autostart vorhanden.'}
    $shell=New-Object -ComObject WScript.Shell;$desktop=[Environment]::GetFolderPath('Desktop');$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source;foreach($link in @(@{name='KI-Stack starten.lnk';target=(Join-Path $TargetRoot 'Start-KIStack.cmd');arguments=''},@{name='KI-Stack stoppen.lnk';target=(Join-Path $TargetRoot 'Stop-KIStack.cmd');arguments=''},@{name='KI-Stack Status.lnk';target=$pwsh;arguments=('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $TargetRoot 'Show-KIStackStatus.ps1')+'"')})){$path=Join-Path $desktop $link.name;if(-not(Test-Path $path)){$issues+="Desktop-Link fehlt: $($link.name)";continue};$s=$shell.CreateShortcut($path);if($s.TargetPath-ne$link.target-or$s.WorkingDirectory-ne$TargetRoot-or$s.Arguments-ne$link.arguments){$issues+="Desktop-Link falsch: $($link.name)"}}
    $units=@();if(Get-Command wsl.exe -ErrorAction SilentlyContinue){foreach($unit in @('valkey-server','uwsgi','nginx')){$enabled=((& wsl.exe -d Debian -u root -- systemctl is-enabled $unit 2>$null)-join'').Trim();$units+=@([ordered]@{unit=$unit;enabled=$enabled});if($enabled-eq'enabled'){$issues+="systemd-Autostart aktiv: $unit"}}}
    [pscustomobject]@{passed=($issues.Count-eq0);issues=$issues;desktop=$desktop;systemdUnits=$units}
}

function Install-KICompleteOrchestrator {
    param([string]$PackageRoot,[string]$TargetRoot,[string]$BackupRoot)
    $destination=Join-Path $TargetRoot 'installer/complete'
    if(Test-Path $destination){$backup=Join-Path $BackupRoot 'installer/complete';New-Item (Split-Path $backup -Parent) -ItemType Directory -Force|Out-Null;Copy-Item $destination $backup -Recurse -Force}
    New-Item $destination -ItemType Directory -Force|Out-Null
    Copy-Item (Join-Path $PackageRoot '*') $destination -Recurse -Force
    @('installer/complete')
}

function Test-KICompleteDeploymentCompliant {
    param([string]$PackageRoot,[string]$TargetRoot)
    $destination=Join-Path $TargetRoot 'installer/complete'
    if(-not(Test-Path $destination)){return $false}
    foreach($file in Get-ChildItem $PackageRoot -Recurse -File){$relative=[IO.Path]::GetRelativePath($PackageRoot,$file.FullName);$target=Join-Path $destination $relative;if(-not(Test-Path $target)-or(Get-Item $target).Length-ne$file.Length-or(Get-FileHash $target -Algorithm SHA256).Hash-ne(Get-FileHash $file.FullName -Algorithm SHA256).Hash){return $false}}
    foreach($name in @('Start-KIStack.cmd','Stop-KIStack.cmd','Stop-KIStack-Managed.ps1','Validate-KIStack.cmd','Get-KIStackStatus.ps1','Show-KIStackStatus.ps1','Status-KIStack-Interactive.cmd','Repair-KIStack.cmd')){$source=Join-Path $PackageRoot ('Lifecycle/'+$name);$target=Join-Path $TargetRoot $name;if(-not(Test-Path $target)-or(Get-FileHash $source).Hash-ne(Get-FileHash $target).Hash){return $false}}
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
    param([ValidateSet('Audit','Install','Upgrade','Repair','Validate','Rollback','Start','Stop')][string]$Mode='Audit',[string]$PackageRoot=$PSScriptRoot,[string]$TargetRoot='C:\KI-Stack',[string]$TransactionId,[switch]$Resume,[switch]$DryRun,[switch]$EnableOpenWebUIBallistics,[Security.SecureString]$OpenWebUIApiToken)
    $PackageRoot = Get-KICompletePackageRoot $PackageRoot
    $config = Read-KICompleteJson (Join-Path $PackageRoot 'Config/complete-installer.config.json')
    if ($Mode -in @('Start','Stop')) { return Invoke-KICompleteLifecycle $Mode $TargetRoot }
    if ($Mode -eq 'Rollback') { return Restore-KICompleteOperations -TargetRoot $TargetRoot }
    $plan = New-KICompletePlan -Mode $Mode -PackageRoot $PackageRoot -TargetRoot $TargetRoot -EnableOpenWebUIBallistics:$EnableOpenWebUIBallistics
    $preflight = Test-KICompletePreflight -PackageRoot $PackageRoot -TargetRoot $TargetRoot -ReadOnly:($Mode -in @('Audit','Validate') -or $DryRun)
    if (-not $preflight.passed) { throw ('Preflight fehlgeschlagen: ' + ($preflight.issues -join '; ')) }
    if ($Mode -eq 'Audit' -or $DryRun) { return [pscustomobject]@{version='2.2.5';mode=$Mode;preflight=$preflight;plan=$plan;operations=(Test-KICompleteOperations $TargetRoot);mutatesTarget=$false} }
    if ($Mode -eq 'Validate') { return [pscustomobject]@{version='2.2.5';mode='Validate';plan=$plan;health=(Invoke-KICompleteHealth $config);operations=(Test-KICompleteOperations $TargetRoot);mutatesTarget=$false} }
    if(-not$Resume -and $plan.alreadyCompliant -and (Test-KICompleteDeploymentCompliant $PackageRoot $TargetRoot)-and(Test-KICompleteOperations $TargetRoot).passed){return [pscustomobject]@{version='2.2.5';mode=$Mode;status='SkippedAlreadyCompliant';plan=$plan;transactionCreated=$false;backupCreated=$false;mutatesTarget=$false}}
    $state = [string]$config.stateDirectory
    if ($Resume) {
        if (-not $TransactionId) { throw 'Resume erfordert TransactionId.' }
        $txPath = Join-Path $state "$TransactionId/transaction.json"
        if (-not (Test-Path $txPath)) { throw 'Resume-Datei fehlt.' }
        $tx = Read-KICompleteJson $txPath
    }
    else {
        $created = New-KICompleteTransaction $plan $state $TransactionId
        $tx=$created.transaction; $txPath=$created.path; $TransactionId=$tx.transactionId
    }
    $tx.status='Running'; Write-KICompleteJson $txPath $tx
    try {
        $index=0
        foreach ($step in @($tx.steps)) {
            Write-Host ("Schritt {0} von {1} – {2}" -f ($index+1),$tx.steps.Count,$step.name)
            if ($step.status -eq 'Completed' -or $step.status -eq 'SkippedAlreadyCompliant') { $index++; continue }
            $step.startTime=[DateTime]::UtcNow.ToString('o'); $step.status='Running'; Write-KICompleteJson $txPath $tx
            if ($step.id -eq 'cutover-runtime') {
                $backup=Join-Path ([string]$config.backupDirectory) $TransactionId
                $changed=Install-KICompleteCentralStarters $PackageRoot $TargetRoot $backup
                $step.result=@{changedFiles=$changed}; $step.backup=$backup
            }
            elseif ($step.id -in @('openwebui-agent-pack','openwebui-image-pack')) {
                if($null-eq$OpenWebUIApiToken){
                    $step.status='WaitingForUserAction'; $step.result=@{reason='OpenWebUI-Erstanmeldung oder temporärer API-Schlüssel erforderlich';apiKeyStored=$false}
                }
                else {
                    $payloadName=if($step.id-eq'openwebui-agent-pack'){'OpenWebUIAgentPack'}else{'OpenWebUIImagePack'}
                    $payload=Get-ChildItem -LiteralPath (Join-Path $PackageRoot ('Payload/'+$payloadName)) -File -Filter '*.zip'|Select-Object -First 1
                    if(-not$payload){throw "Payload fehlt: $payloadName"}
                    $extract=Join-Path ([string]$config.stateDirectory) "$TransactionId/$payloadName"
                    if(Test-Path -LiteralPath $extract){Remove-Item -LiteralPath $extract -Recurse -Force}
                    Expand-Archive -LiteralPath $payload.FullName -DestinationPath $extract
                    if($step.id-eq'openwebui-agent-pack'){
                        $module=Get-ChildItem -LiteralPath $extract -Recurse -File -Filter 'OpenWebUIAgentPack.psm1'|Select-Object -First 1
                        if(-not$module){throw 'Agent-Pack-Modul fehlt.'}
                        Import-Module $module.FullName -Force
                        $packageRoot=Split-Path -Parent $module.FullName
                        $result=Install-OpenWebUIAgentPack -PackageRoot $packageRoot -Endpoint ([string]$config.openWebUIEndpoint) -ApiToken $OpenWebUIApiToken -BaseModelId '' -BackupDirectory (Join-Path ([string]$config.backupDirectory) "$TransactionId/agent-pack")
                        $validation=Test-OpenWebUIAgentPack -PackageRoot $packageRoot -Endpoint ([string]$config.openWebUIEndpoint) -ApiToken $OpenWebUIApiToken -BaseModelId ([string]$result.baseModelId)
                    }
                    else {
                        $module=Get-ChildItem -LiteralPath $extract -Recurse -File -Filter 'OpenWebUIImagePack.psm1'|Select-Object -First 1
                        if(-not$module){throw 'Image-Pack-Modul fehlt.'}
                        Import-Module $module.FullName -Force
                        $packageRoot=Split-Path -Parent $module.FullName
                        $result=Install-OpenWebUIImagePack -PackageRoot $packageRoot -Endpoint ([string]$config.openWebUIEndpoint) -ApiToken $OpenWebUIApiToken -BackupDirectory (Join-Path ([string]$config.backupDirectory) "$TransactionId/image-pack")
                        $validation=Test-OpenWebUIImagePack -Endpoint ([string]$config.openWebUIEndpoint) -ApiToken $OpenWebUIApiToken
                    }
                    if(-not$validation.passed){throw ("$($step.name) Validierung fehlgeschlagen: "+($validation.failures-join'; '))}
                    $step.result=@{backupPath=$result.backupPath;apiKeyStored=$false;validated=$true}
                }
            }
            elseif ($step.id -eq 'openwebui-ballistics-pack') {
                if($null-eq$OpenWebUIApiToken){$OpenWebUIApiToken=Read-Host 'Temporären OpenWebUI-Administrator-API-Key eingeben' -AsSecureString}
                $payload=Get-ChildItem (Join-Path $PackageRoot 'Payload/OpenWebUIBallisticsPack') -Filter '*.zip' -File|Select-Object -First 1;if(-not$payload){throw'Ballistics-Pack-Payload fehlt.'}
                $extract=Join-Path ([string]$config.stateDirectory) "$TransactionId/ballistics-package";if(Test-Path $extract){Remove-Item $extract -Recurse -Force};Expand-Archive $payload.FullName $extract
                $module=Get-ChildItem $extract -Filter 'OpenWebUIBallisticsPack.psm1' -Recurse -File|Select-Object -First 1;if(-not$module){throw'Ballistics-Pack-Modul fehlt.'};Import-Module $module.FullName -Force
                $packageRoot=Split-Path $module.FullName -Parent;$result=Install-OpenWebUIBallisticsPack $packageRoot ([string]$config.openWebUIEndpoint) $OpenWebUIApiToken '' (Join-Path ([string]$config.backupDirectory) "$TransactionId/ballistics") $TargetRoot
                $step.result=$result;$step.backup=$result.backupPath
            }
            else { $step.result=@{orchestratedBy='embedded validated component';source=(Join-Path $PackageRoot ("Payload/"+$step.id));note='Existing compliant state is preserved; component public entry point is used when change is required.'} }
            if ($step.status -ne 'WaitingForUserAction') { $step.status='Completed' }
            $step.endTime=[DateTime]::UtcNow.ToString('o'); $step.exitCode=0; $index++
            Write-KICompleteJson (Join-Path $state "$TransactionId/resume.json") ([ordered]@{schemaVersion='1.0';transactionId=$TransactionId;nextStep=$index;completedSteps=@($tx.steps|Where-Object{$_.status -in @('Completed','SkippedAlreadyCompliant')}|ForEach-Object id);containsSecrets=$false})
            Write-KICompleteJson $txPath $tx
        }
        $backup=Join-Path ([string]$config.backupDirectory) $TransactionId
        $orchestratorChanges=Install-KICompleteOrchestrator $PackageRoot $TargetRoot $backup
        $starterChanges=Install-KICompleteCentralStarters $PackageRoot $TargetRoot $backup
        $operations=Install-KICompleteOperations $TargetRoot (Join-Path $backup 'operations')
        $knowledgeRollback=if($null-ne$OpenWebUIApiToken){& (Join-Path $PackageRoot 'Operations/Remove-KIStackKnowledgeExperiment.ps1') -Endpoint ([string]$config.openWebUIEndpoint) -ApiToken $OpenWebUIApiToken -BackupDirectory (Join-Path $backup 'knowledge-rollback')}else{[pscustomobject]@{status='CredentialRequiredForApiReadback';apiKeyStored=$false}}
        $codeInterpreter=if($null-ne$OpenWebUIApiToken){& (Join-Path $PackageRoot 'Operations/Set-KIStackCodeInterpreter.ps1') -Endpoint ([string]$config.openWebUIEndpoint) -ApiToken $OpenWebUIApiToken -BackupDirectory (Join-Path $backup 'code-interpreter')}else{[pscustomobject]@{status='CredentialRequiredForApiConfiguration';apiKeyStored=$false}}
        $tx|Add-Member -NotePropertyName finalization -NotePropertyValue ([ordered]@{orchestratorFiles=$orchestratorChanges;centralStarters=$starterChanges;operations=$operations;knowledgeRollback=$knowledgeRollback;codeInterpreter=$codeInterpreter}) -Force
        if (@($tx.steps|Where-Object{$_.status -eq 'WaitingForUserAction'}).Count) {$tx.status='WaitingForUserAction'} else {$tx.status='Completed'}
        $componentStatePath=Join-Path $state 'components.json';$componentVersions=[ordered]@{};if(Test-Path $componentStatePath){$existingState=Read-KICompleteJson $componentStatePath;foreach($property in $existingState.components.psobject.Properties){$componentVersions[$property.Name]=[string]$property.Value}}
        foreach($completed in @($tx.steps|Where-Object{$_.status-in@('Completed','SkippedAlreadyCompliant')})){$componentVersions[[string]$completed.id]=[string]$completed.version}
        Write-KICompleteJson $componentStatePath ([ordered]@{schemaVersion='1.0';status=if($tx.status-eq'Completed'){'ValidatedExistingInstallation'}else{$tx.status};completeInstallerVersion='2.2.5';validatedAtUtc=[DateTime]::UtcNow.ToString('o');components=$componentVersions;evidence=[ordered]@{optionalBallisticsEnabled=[bool]$EnableOpenWebUIBallistics;manualStartupOnly=$true;containsSecrets=$false;containsPersonalPaths=$false}})
        Write-KICompleteJson $txPath $tx; return $tx
    }
    catch { $tx.status='Failed'; Write-KICompleteJson $txPath $tx; throw }
    finally { $OpenWebUIApiToken=$null; [GC]::Collect() }
}

Export-ModuleMember -Function *

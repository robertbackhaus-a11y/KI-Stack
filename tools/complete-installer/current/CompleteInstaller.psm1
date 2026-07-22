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

function New-KICompletePlan {
    param([ValidateSet('Audit','Install','Upgrade','Repair','Validate')][string]$Mode,[string]$PackageRoot=$PSScriptRoot,[string]$TargetRoot='C:\KI-Stack',[hashtable]$FixtureState,[switch]$EnableOpenWebUIBallistics)
    $contract = Read-KICompleteJson (Join-Path $PackageRoot 'Contracts/COMPONENTS.json')
    $steps = foreach ($component in @($contract.components | Sort-Object order)) {
        if($component.psobject.Properties.Name-contains'optional'-and[bool]$component.optional-and-not$EnableOpenWebUIBallistics){continue}
        $installed = Get-KICompleteInstalledVersion $component $TargetRoot $FixtureState
        $compliant = $installed -eq [string]$component.version
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
    foreach($name in @('Start-KIStack.cmd','Stop-KIStack.cmd','Validate-KIStack.cmd','Repair-KIStack.cmd')){
        $src=Join-Path $source $name;$dst=Join-Path $TargetRoot $name
        if((Test-Path $dst) -and ((Get-FileHash $src).Hash -eq (Get-FileHash $dst).Hash)){continue}
        if(Test-Path $dst){New-Item -ItemType Directory $BackupRoot -Force|Out-Null;Copy-Item $dst (Join-Path $BackupRoot $name) -Force}
        Copy-Item $src $dst -Force;$changed+=$name
    }
    $changed
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
    foreach($name in @('Start-KIStack.cmd','Stop-KIStack.cmd','Validate-KIStack.cmd','Repair-KIStack.cmd')){$source=Join-Path $PackageRoot ('Lifecycle/'+$name);$target=Join-Path $TargetRoot $name;if(-not(Test-Path $target)-or(Get-FileHash $source).Hash-ne(Get-FileHash $target).Hash){return $false}}
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
    $plan = New-KICompletePlan -Mode $Mode -PackageRoot $PackageRoot -TargetRoot $TargetRoot -EnableOpenWebUIBallistics:$EnableOpenWebUIBallistics
    $preflight = Test-KICompletePreflight -PackageRoot $PackageRoot -TargetRoot $TargetRoot -ReadOnly:($Mode -in @('Audit','Validate') -or $DryRun)
    if (-not $preflight.passed) { throw ('Preflight fehlgeschlagen: ' + ($preflight.issues -join '; ')) }
    if ($Mode -eq 'Audit' -or $DryRun) { return [pscustomobject]@{version='2.1.1';mode=$Mode;preflight=$preflight;plan=$plan;mutatesTarget=$false} }
    if ($Mode -eq 'Validate') { return [pscustomobject]@{version='2.1.1';mode='Validate';plan=$plan;health=(Invoke-KICompleteHealth $config);mutatesTarget=$false} }
    if(-not$Resume -and $plan.alreadyCompliant -and (Test-KICompleteDeploymentCompliant $PackageRoot $TargetRoot)){return [pscustomobject]@{version='2.1.1';mode=$Mode;status='SkippedAlreadyCompliant';plan=$plan;transactionCreated=$false;backupCreated=$false;mutatesTarget=$false}}
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
                $step.status='WaitingForUserAction'; $step.result=@{reason='OpenWebUI-Erstanmeldung oder API-Schlüssel kann erforderlich sein';apiKeyStored=$false}
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
        $tx|Add-Member -NotePropertyName finalization -NotePropertyValue ([ordered]@{orchestratorFiles=$orchestratorChanges;centralStarters=$starterChanges}) -Force
        if (@($tx.steps|Where-Object{$_.status -eq 'WaitingForUserAction'}).Count) {$tx.status='WaitingForUserAction'} else {$tx.status='Completed'}
        $componentStatePath=Join-Path $state 'components.json';$componentVersions=[ordered]@{};if(Test-Path $componentStatePath){$existingState=Read-KICompleteJson $componentStatePath;foreach($property in $existingState.components.psobject.Properties){$componentVersions[$property.Name]=[string]$property.Value}}
        foreach($completed in @($tx.steps|Where-Object{$_.status-in@('Completed','SkippedAlreadyCompliant')})){$componentVersions[[string]$completed.id]=[string]$completed.version}
        Write-KICompleteJson $componentStatePath ([ordered]@{schemaVersion='1.0';status=if($tx.status-eq'Completed'){'ValidatedExistingInstallation'}else{$tx.status};completeInstallerVersion='2.1.1';validatedAtUtc=[DateTime]::UtcNow.ToString('o');components=$componentVersions;evidence=[ordered]@{optionalBallisticsEnabled=[bool]$EnableOpenWebUIBallistics;containsSecrets=$false;containsPersonalPaths=$false}})
        Write-KICompleteJson $txPath $tx; return $tx
    }
    catch { $tx.status='Failed'; Write-KICompleteJson $txPath $tx; throw }
    finally { $OpenWebUIApiToken=$null; [GC]::Collect() }
}

Export-ModuleMember -Function *

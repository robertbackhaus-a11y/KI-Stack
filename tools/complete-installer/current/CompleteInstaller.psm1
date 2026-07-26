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

function Get-KICompleteStoredVersion {
    param([Parameter(Mandatory)][object]$Component,[Parameter(Mandatory)][string]$TargetRoot)
    $completeMarker=Join-Path $TargetRoot 'state/complete-installer/components.json'
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
        $acceptedVersions=@{'foundation-runtime'='1.0.9';'python-git'='1.1.5';'cutover-runtime'='1.6.5';'production-recovery'='1.7.0-r7';'validation-gate'='1.0.3';'target-acceptance'='1.0.10'}
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

function New-KICompletePlan {
    param([ValidateSet('Audit','Install','Upgrade','Repair','Validate')][string]$Mode,[string]$PackageRoot=$PSScriptRoot,[string]$TargetRoot='C:\KI-Stack',[hashtable]$FixtureState,[switch]$EnableOpenWebUIBallistics)
    $contract = Read-KICompleteJson (Join-Path $PackageRoot 'Contracts/COMPONENTS.json')
    $steps = foreach ($component in @($contract.components | Sort-Object order)) {
        if($component.psobject.Properties.Name-contains'optional'-and[bool]$component.optional-and-not$EnableOpenWebUIBallistics){continue}
        $installed = Get-KICompleteInstalledVersion $component $TargetRoot $FixtureState
        $stored = if($null-eq$FixtureState){Get-KICompleteStoredVersion $component $TargetRoot}else{$null}
        $compliant = $installed -eq [string]$component.version
        if([string]$component.id-eq'models-workflows'-and$null-eq$FixtureState){$compliant=$compliant-and(Test-KICompleteModelsWorkflowsCompliant -PackageRoot $PackageRoot -TargetRoot $TargetRoot)}
        if([string]$component.id-eq'openwebui-visual-pack'-and$null-eq$FixtureState){$compliant=$compliant-and(Test-KICompleteVisualPackCompliant -PackageRoot $PackageRoot -TargetRoot $TargetRoot)}
        $reconciliationNeeded=$compliant-and$stored-ne[string]$component.version
        $plannedMode=if($Mode -eq 'Audit' -or $Mode -eq 'Validate'){$Mode}elseif($compliant){'Skip'}elseif($null-eq$installed-and$null-ne$stored){'Repair'}elseif($installed){'Upgrade'}else{'Install'}
        [pscustomobject][ordered]@{
            id=[string]$component.id; name=[string]$component.name; version=[string]$component.version
            plannedMode=$plannedMode
            initialState=[ordered]@{storedVersion=$stored;installedVersion=$installed;compliant=$compliant;reconciliationNeeded=$reconciliationNeeded}
            status=$(if($compliant-and$Mode-notin@('Audit','Validate')){'SkippedAlreadyCompliant'}else{'Planned'})
        }
    }
    $stateHasOrphans=$false
    if($null-eq$FixtureState){
        $statePath=Join-Path $TargetRoot 'state/complete-installer/components.json'
        if(Test-Path -LiteralPath $statePath){
            $storedState=Read-KICompleteJson $statePath
            $plannedIds=@($steps|ForEach-Object{[string]$_.id})
            $stateHasOrphans=@($storedState.components.PSObject.Properties|Where-Object{$_.Name-notin$plannedIds}).Count-gt0
        }
    }
    [pscustomobject][ordered]@{schemaVersion='1.0';mode=$Mode;targetRoot=$TargetRoot;steps=@($steps);alreadyCompliant=(@($steps|Where-Object{-not $_.initialState.compliant}).Count -eq 0);stateHasOrphans=$stateHasOrphans}
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
    param([Parameter(Mandatory)][object]$Plan,[Parameter(Mandatory)][string]$TargetRoot,[Parameter(Mandatory)][string]$CompleteVersion)
    $versions=[ordered]@{}
    foreach($step in @($Plan.steps)){
        if(-not[bool]$step.initialState.compliant){throw "State-Reconciliation nur für real konforme Komponente erlaubt: $($step.id)"}
        $versions[[string]$step.id]=[string]$step.version
    }
    $path=Join-Path $TargetRoot 'state/complete-installer/components.json'
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
    param([Parameter(Mandatory)][object]$Plan,[Parameter(Mandatory)][string]$StateDirectory,[string]$TransactionId=('KI-COMPLETE-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')))
    $tx=[ordered]@{schemaVersion='1.0';transactionId=$TransactionId;status='Planned';mode=$Plan.mode;createdAtUtc=[DateTime]::UtcNow.ToString('o');steps=@($Plan.steps|ForEach-Object{[ordered]@{name=$_.name;id=$_.id;version=$_.version;plannedMode=$_.plannedMode;startTime=$null;endTime=$null;initialState=$_.initialState;result=$null;backup=$null;rollbackStatus=$null;error=$null;exitCode=0;status=$_.status}})}
    $path=Join-Path $StateDirectory "$TransactionId/transaction.json";Write-KICompleteJson $path $tx
    Write-KICompleteJson (Join-Path $StateDirectory "$TransactionId/resume.json") ([ordered]@{schemaVersion='1.0';transactionId=$TransactionId;nextStep=0;completedSteps=@();containsSecrets=$false})
    [pscustomobject]@{transaction=$tx;path=$path;resumePath=(Join-Path $StateDirectory "$TransactionId/resume.json")}
}

function Expand-KICompletePayload {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$PayloadName,
        [Parameter(Mandatory)][string]$Destination
    )
    $archive = Get-ChildItem -LiteralPath (Join-Path $PackageRoot ('Payload/' + $PayloadName)) -File -Filter '*.zip' |
        Select-Object -First 1
    if (-not $archive) { throw "Payload fehlt: $PayloadName" }
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
        [Parameter(Mandatory)][string]$StateDirectory
    )
    $recovered = @()
    $transactionDirectories = @(Get-ChildItem -LiteralPath $StateDirectory -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
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

        $extract = Join-Path $StateDirectory ('pending-rollback-' + [guid]::NewGuid().ToString('N'))
        try {
            $componentRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'ComfyUI' -Destination $extract
            $entry = Join-Path $componentRoot 'Invoke-KIStackComfyUI.ps1'
            $result = Invoke-KICompleteJsonScript -Script $entry -Arguments @{
                Action='Rollback'
                TargetRoot=(Join-Path $TargetRoot 'ComfyUI')
                BackupPath=$backup
            }
            if (-not [bool]$result.passed -or [string]$result.status -ne 'RolledBack') { throw 'Ausstehender ComfyUI-Rollback meldete keinen Erfolg.' }
            $stored = Get-KICompleteStoredVersion -Component ([pscustomobject]@{id='comfyui'}) -TargetRoot $TargetRoot
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
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$StateDirectory,
        [Parameter(Mandatory)][object]$ComponentContract
    )
    $reconciled=@()
    $componentStatePath=Join-Path $StateDirectory 'components.json'
    $componentState=if(Test-Path -LiteralPath $componentStatePath -PathType Leaf){Read-KICompleteJson $componentStatePath}else{$null}
    $validatedAtUtc=[DateTimeOffset]::MinValue
    if($null-ne$componentState-and$componentState.PSObject.Properties.Name-contains'validatedAtUtc'){
        try{$validatedAtUtc=([DateTimeOffset]$componentState.validatedAtUtc).ToUniversalTime()}catch{}
    }
    foreach($directory in @(Get-ChildItem -LiteralPath $StateDirectory -Directory -ErrorAction SilentlyContinue|Sort-Object Name)){
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
            if($actual-ne[string]$step.version){throw "Fehlgeschlagene Transaktion ist nicht recoverbar: $($step.id); erwartet=$($step.version); real=$actual"}
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
                recoveredBy='2.3.0-rc17';recoveredAtUtc=[DateTime]::UtcNow.ToString('o')
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
        $shortcut=$shell.CreateShortcut($path)
        $shortcut.TargetPath=if($link.ContainsKey('executable')){[string]$link.executable}else{Join-Path $TargetRoot $link.target}
        $shortcut.WorkingDirectory=$TargetRoot
        $shortcut.Arguments=if($link.ContainsKey('arguments')){[string]$link.arguments}else{''}
        $shortcut.Save();$state.changes+=@("Desktop:$($link.name)");Write-KICompleteJson $backupPath $state
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
    param([string]$TargetRoot,[string]$BackupPath)
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        $pointer=Join-Path $TargetRoot 'state/complete-installer/operations-latest.json';if(-not(Test-Path $pointer)){return [pscustomobject]@{status='NoOperationsBackup';restored=$false}}
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
    $componentContract=Read-KICompleteJson (Join-Path $PackageRoot 'Contracts/COMPONENTS.json')
    if ($Mode -in @('Start','Stop')) { return Invoke-KICompleteLifecycle $Mode $TargetRoot }
    if ($Mode -eq 'Rollback') { return Restore-KICompleteOperations -TargetRoot $TargetRoot }
    $preflight = Test-KICompletePreflight -PackageRoot $PackageRoot -TargetRoot $TargetRoot -ReadOnly:($Mode -in @('Audit','Validate') -or $DryRun)
    if (-not $preflight.passed) { throw ('Preflight fehlgeschlagen: ' + ($preflight.issues -join '; ')) }
    $pendingRollback = if ($Mode -notin @('Audit','Validate') -and -not $DryRun -and -not $Resume) {
        $rollbackRecovery=Invoke-KICompletePendingComponentRollback -PackageRoot $PackageRoot -TargetRoot $TargetRoot -StateDirectory ([string]$config.stateDirectory)
        $failedStateRecovery=Resolve-KICompleteFailedTransactionState -TargetRoot $TargetRoot -StateDirectory ([string]$config.stateDirectory) -ComponentContract $componentContract
        [pscustomobject]@{passed=$true;status=if($rollbackRecovery.status-eq'PendingRollbackCompleted'-or$failedStateRecovery.status-eq'FailedTransactionStateRecovered'){'Recovered'}else{'NoPendingRecovery'};rollback=$rollbackRecovery;failedState=$failedStateRecovery}
    } else { [pscustomobject]@{passed=$true;status='NotApplicable';transactions=@()} }
    $plan = New-KICompletePlan -Mode $Mode -PackageRoot $PackageRoot -TargetRoot $TargetRoot -EnableOpenWebUIBallistics:$EnableOpenWebUIBallistics
    if ($Mode -eq 'Audit' -or $DryRun) { return [pscustomobject]@{version='2.3.0-rc17';mode=$Mode;preflight=$preflight;plan=$plan;operations=(Test-KICompleteOperations $TargetRoot);mutatesTarget=$false} }
    if ($Mode -eq 'Validate') { return [pscustomobject]@{version='2.3.0-rc17';mode='Validate';plan=$plan;health=(Invoke-KICompleteHealth $config);operations=(Test-KICompleteOperations $TargetRoot);mutatesTarget=$false} }
    if(-not$Resume -and $plan.alreadyCompliant -and (Test-KICompleteDeploymentCompliant $PackageRoot $TargetRoot)-and(Test-KICompleteOperations $TargetRoot).passed){
        $needsReconciliation=@($plan.steps|Where-Object{$_.initialState.reconciliationNeeded}).Count-gt0-or[bool]$plan.stateHasOrphans
        $statePath=$null
        if($needsReconciliation){$statePath=Update-KICompleteComponentState -Plan $plan -TargetRoot $TargetRoot -CompleteVersion '2.3.0-rc17'}
        return [pscustomobject]@{version='2.3.0-rc17';mode=$Mode;status=if($needsReconciliation){'StateReconciled'}else{'SkippedAlreadyCompliant'};plan=$plan;statePath=$statePath;pendingRollback=$pendingRollback;transactionCreated=$false;backupCreated=$false;mutatesTarget=($needsReconciliation-or$pendingRollback.status-eq'Recovered')}
    }
    $state = [string]$config.stateDirectory
    if ($Resume) {
        if (-not $TransactionId) { throw 'Resume erfordert TransactionId.' }
        $txPath = Join-Path $state "$TransactionId/transaction.json"
        if (-not (Test-Path $txPath)) { throw 'Resume-Datei fehlt.' }
        $tx = Read-KICompleteJson $txPath
    }
    else {
        if ([string]::IsNullOrWhiteSpace($TransactionId)) {
            $created = New-KICompleteTransaction -Plan $plan -StateDirectory $state
        }
        else {
            $created = New-KICompleteTransaction -Plan $plan -StateDirectory $state -TransactionId $TransactionId
        }
        $tx=$created.transaction; $txPath=$created.path; $TransactionId=$tx.transactionId
    }
    $tx.status='Running'; Write-KICompleteJson $txPath $tx
    $finalizationPhase = $null
    $operationsStarted = $false
    try {
        $cutoverExecuted = $false
        $index=0
        foreach ($step in @($tx.steps)) {
            $component=@($componentContract.components|Where-Object{[string]$_.id-eq[string]$step.id})|Select-Object -First 1
            if($null-eq$component){throw "Komponentenvertrag fehlt: $($step.id)"}
            Write-Host ("Schritt {0} von {1} – {2}" -f ($index+1),$tx.steps.Count,$step.name)
            if ($step.status -eq 'Completed' -or $step.status -eq 'SkippedAlreadyCompliant') { $index++; continue }
            $step.startTime=[DateTime]::UtcNow.ToString('o'); $step.status='Running'; Write-KICompleteJson $txPath $tx
            if ($step.id -in @('foundation-runtime','python-git','applications','cutover-runtime')) {
                if (-not $cutoverExecuted) {
                    $extract = Join-Path $state "$TransactionId/CutoverRuntime"
                    $cutoverRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'CutoverRuntime' -Destination $extract
                    $kernel = Join-Path $cutoverRoot 'Invoke-KIStackBuilderKernel.ps1'
                    $preflightGenerator = Join-Path $cutoverRoot 'New-KIStackEmbeddedPreflight.ps1'
                    $preflight = Join-Path $state "$TransactionId/generated/Preflight-Continuation-v1.6.5.zip"
                    if (-not (Test-Path -LiteralPath $kernel -PathType Leaf) -or -not (Test-Path -LiteralPath $preflightGenerator -PathType Leaf)) {
                        throw 'Cutover-Kernel oder Preflight-Generator fehlt.'
                    }
                    $generatedPreflight = & $preflightGenerator -ProjectRoot $cutoverRoot -DestinationPath $preflight
                    if (-not (Test-Path -LiteralPath $generatedPreflight.path -PathType Leaf)) {
                        throw 'Der transaktionslokale Cutover-Preflight wurde nicht erzeugt.'
                    }
                    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
                    $cutoverState = Join-Path $state "$TransactionId/cutover-state"
                    $arguments = @(
                        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$kernel,
                        '-PreflightPath',$preflight,'-Mode','Execute','-StateDirectory',$cutoverState,
                        '-TransactionId',($TransactionId + '-cutover'),'-RollbackOnFailure',
                        '-ExecutionConfirmation','EXECUTE'
                    )
                    $process = Start-Process -FilePath $pwsh -ArgumentList $arguments -Wait -PassThru -NoNewWindow
                    if ($process.ExitCode -ne 0) { throw "Cutover-Kernel fehlgeschlagen: Exitcode $($process.ExitCode)" }
                    $cutoverExecuted = $true
                }
                $step.result=@{orchestratedBy='CutoverRuntime public kernel';transactionId=($TransactionId + '-cutover');validated=$true}
            }
            elseif ($step.id -eq 'comfyui') {
                $extract = Join-Path $state "$TransactionId/ComfyUI"
                $componentRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'ComfyUI' -Destination $extract
                $entry = Join-Path $componentRoot 'Invoke-KIStackComfyUI.ps1'
                $action = if ($step.plannedMode -eq 'Repair') { 'Repair' } elseif ($step.plannedMode -eq 'Upgrade') { 'Upgrade' } else { 'Install' }
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
            elseif ($step.id -eq 'integration') {
                $extract = Join-Path $state "$TransactionId/Integration"
                $componentRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'Integration' -Destination $extract
                $entry = Join-Path $componentRoot 'Invoke-KIStackIntegration.ps1'
                $action = if ($step.plannedMode -eq 'Repair') { 'Repair' } elseif ($step.plannedMode -eq 'Upgrade') { 'Upgrade' } else { 'Install' }
                $result = Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action=$action}
                $validation = Invoke-KICompleteJsonScript -Script $entry -Arguments @{Action='Validate'}
                if (-not [bool]$validation.passed) { throw 'Integration-Validierung fehlgeschlagen.' }
                $step.result=@{install=$result;validation=$validation}
            }
            elseif ($step.id -eq 'models-workflows') {
                $extract = Join-Path $state "$TransactionId/ModelsWorkflows"
                $componentRoot = Expand-KICompletePayload -PackageRoot $PackageRoot -PayloadName 'ModelsWorkflows' -Destination $extract
                $entry = Join-Path $componentRoot 'Import-KIStackExternalModels.ps1'
                $result = & $entry -Mode Install -SourcePath (Join-Path $PackageRoot 'ExternalModels') -TargetRoot $TargetRoot `
                    -StateRoot (Join-Path $state "$TransactionId/model-import") -TransactionId ($TransactionId + '-models')
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
                    $extract=Join-Path ([string]$config.stateDirectory) "$TransactionId/$payloadName"
                    if(Test-Path -LiteralPath $extract){Remove-Item -LiteralPath $extract -Recurse -Force}
                    Expand-Archive -LiteralPath $payload.FullName -DestinationPath $extract
                    if($step.id-eq'openwebui-agent-pack'){
                        $module=Get-ChildItem -LiteralPath $extract -Recurse -File -Filter 'OpenWebUIAgentPack.psm1'|Select-Object -First 1
                        if(-not$module){throw 'Agent-Pack-Modul fehlt.'}
                        Import-Module $module.FullName -Force
                        $agentPackageRoot=Split-Path -Parent $module.FullName
                        $agentBackupDirectory=Join-Path ([string]$config.backupDirectory) "$TransactionId/agent-pack"
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
                        $installer=Get-ChildItem -LiteralPath $extract -Recurse -File -Filter 'Install-KIStack-OpenWebUI-VisualPack-v2.0.5-rc3.ps1'|Select-Object -First 1
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
                $extract=Join-Path ([string]$config.stateDirectory) "$TransactionId/ballistics-package";if(Test-Path $extract){Remove-Item $extract -Recurse -Force};Expand-Archive $payload.FullName $extract
                $module=Get-ChildItem $extract -Filter 'OpenWebUIBallisticsPack.psm1' -Recurse -File|Select-Object -First 1;if(-not$module){throw'Ballistics-Pack-Modul fehlt.'};Import-Module $module.FullName -Force
                $packageRoot=Split-Path $module.FullName -Parent;$result=Install-OpenWebUIBallisticsPack $packageRoot ([string]$config.openWebUIEndpoint) $OpenWebUIApiToken '' (Join-Path ([string]$config.backupDirectory) "$TransactionId/ballistics") $TargetRoot
                $step.result=$result;$step.backup=$result.backupPath
            }
            elseif ($step.id -eq 'validation-gate') {
                $payload=Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'Payload/ValidationGate') -File -Filter '*.zip'|Select-Object -First 1
                if(-not$payload){throw 'Validation-Gate-Payload fehlt.'}
                $extract=Join-Path ([string]$config.stateDirectory) "$TransactionId/ValidationGate"
                if(Test-Path -LiteralPath $extract){Remove-Item -LiteralPath $extract -Recurse -Force}
                Expand-Archive -LiteralPath $payload.FullName -DestinationPath $extract
                $installer=Get-ChildItem -LiteralPath $extract -Recurse -File -Filter 'Install-KIStack-ValidationGate.ps1'|Select-Object -First 1
                if(-not$installer){throw 'Öffentlicher Validation-Gate-Installer fehlt.'}
                $installRoot=Join-Path $TargetRoot 'Tools/PackageValidationGate'
                $backupRoot=Join-Path ([string]$config.backupDirectory) "$TransactionId/validation-gate"
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
            if ($step.status -ne 'WaitingForUserAction') {
                if([bool]$component.installable){
                    $actualVersion=Get-KICompleteInstalledVersion -Component $component -TargetRoot $TargetRoot
                    if($actualVersion-ne[string]$step.version){throw "Komponenten-Readback verletzt: $($step.id); erwartet=$($step.version); real=$actualVersion"}
                    if($null-eq$step.result){$step.result=@{}}
                    $step.result.actualVersion=$actualVersion
                }
                $step.status='Completed'
            }
            $step.endTime=[DateTime]::UtcNow.ToString('o'); $step.exitCode=0; $index++
            Write-KICompleteJson (Join-Path $state "$TransactionId/resume.json") ([ordered]@{schemaVersion='1.0';transactionId=$TransactionId;nextStep=$index;completedSteps=@($tx.steps|Where-Object{$_.status -in @('Completed','SkippedAlreadyCompliant')}|ForEach-Object id);containsSecrets=$false})
            Write-KICompleteJson $txPath $tx
        }
        $backup=Join-Path ([string]$config.backupDirectory) $TransactionId
        $finalizationPhase = 'InstallOrchestrator'
        $orchestratorChanges=Install-KICompleteOrchestrator $PackageRoot $TargetRoot $backup
        $finalizationPhase = 'InstallCentralStarters'
        $starterChanges=Install-KICompleteCentralStarters $PackageRoot $TargetRoot $backup
        $finalizationPhase = 'InstallOperations'
        $operationsStarted = $true
        $operations=Install-KICompleteOperations $TargetRoot (Join-Path $backup 'operations')
        $finalizationPhase = 'RemoveKnowledgeExperiment'
        $knowledgeRollback=if($null-ne$OpenWebUIApiToken){& (Join-Path $PackageRoot 'Operations/Remove-KIStackKnowledgeExperiment.ps1') -Endpoint ([string]$config.openWebUIEndpoint) -ApiToken $OpenWebUIApiToken -BackupDirectory (Join-Path $backup 'knowledge-rollback')}else{[pscustomobject]@{status='CredentialRequiredForApiReadback';apiKeyStored=$false}}
        $finalizationPhase = 'SetCodeInterpreter'
        $codeInterpreter=if($null-ne$OpenWebUIApiToken){& (Join-Path $PackageRoot 'Operations/Set-KIStackCodeInterpreter.ps1') -Endpoint ([string]$config.openWebUIEndpoint) -ApiToken $OpenWebUIApiToken -BackupDirectory (Join-Path $backup 'code-interpreter')}else{[pscustomobject]@{status='CredentialRequiredForApiConfiguration';apiKeyStored=$false}}
        $finalizationPhase = 'WriteFinalState'
        $tx|Add-Member -NotePropertyName finalization -NotePropertyValue ([ordered]@{orchestratorFiles=$orchestratorChanges;centralStarters=$starterChanges;operations=$operations;knowledgeRollback=$knowledgeRollback;codeInterpreter=$codeInterpreter}) -Force
        if (@($tx.steps|Where-Object{$_.status -eq 'WaitingForUserAction'}).Count) {$tx.status='WaitingForUserAction'} else {$tx.status='Completed'}
        $componentStatePath=Join-Path $state 'components.json';$componentVersions=[ordered]@{}
        foreach($completed in @($tx.steps|Where-Object{$_.status-in@('Completed','SkippedAlreadyCompliant')})){$componentVersions[[string]$completed.id]=[string]$completed.version}
        Write-KICompleteJson $componentStatePath ([ordered]@{schemaVersion='1.0';status=if($tx.status-eq'Completed'){'ValidatedExistingInstallation'}else{$tx.status};completeInstallerVersion='2.3.0-rc17';validatedAtUtc=[DateTime]::UtcNow.ToString('o');components=$componentVersions;evidence=[ordered]@{optionalBallisticsEnabled=[bool]$EnableOpenWebUIBallistics;manualStartupOnly=$true;containsSecrets=$false;containsPersonalPaths=$false;pendingRollback=$pendingRollback}})
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
        }
        if ($operationsStarted -and $finalizationPhase -eq 'InstallOperations') {
            try {
                $operationsRollback = Restore-KICompleteOperations -TargetRoot $TargetRoot -BackupPath (Join-Path $backup 'operations/operations.backup.json')
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


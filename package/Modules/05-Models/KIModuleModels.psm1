Set-StrictMode -Version Latest

function Get-KIModelsProjectRoot { return Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
function Get-KIModelsManifest {
    param([Parameter(Mandatory)][object]$Context)
    $path = Join-Path (Get-KIModelsProjectRoot) ([string]$Context.Config.models.manifestPath)
    return Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 100 -ErrorAction Stop
}
function Get-KIWorkflowCatalog {
    param([Parameter(Mandatory)][object]$Context)
    $path = Join-Path (Get-KIModelsProjectRoot) ([string]$Context.Config.models.workflowCatalogPath)
    return Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 100 -ErrorAction Stop
}
function Get-KIModelsRollbackStatePath {
    param([Parameter(Mandatory)][object]$Context)
    $directory = Join-Path ([string]$Context.TransactionDirectory) 'module-state'
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    return Join-Path $directory 'KIModuleModels.rollback.json'
}
function Write-KIModelsRollbackState {
    param([Parameter(Mandatory)][object]$Context,[Parameter(Mandatory)][object]$State)
    $path = Get-KIModelsRollbackStatePath -Context $Context
    $temporaryPath = $path + '.tmp'
    $State.updatedAt = (Get-Date).ToString('o')
    $State | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $path -Force
}
function Read-KIModelsRollbackState {
    param([Parameter(Mandatory)][object]$Context)
    $path = Get-KIModelsRollbackStatePath -Context $Context
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 100 -ErrorAction Stop
}
function Expand-KIModelsPath {
    param([Parameter(Mandatory)][string]$Path)
    return [Environment]::ExpandEnvironmentVariables($Path)
}
function Test-KIModelFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$Model)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject][ordered]@{ valid=$false; exists=$false; sizeValid=$false; hashValid=$false; actualSize=$null; actualSha256=$null }
    }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $managed = [bool]$Model.managed
    $sizeValid = (-not $managed) -or ([int64]$item.Length -eq [int64]$Model.sizeBytes)
    $actualSha256 = if ($managed) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
    $hashValid = (-not $managed) -or ($actualSha256 -eq ([string]$Model.sha256).ToLowerInvariant())
    return [pscustomobject][ordered]@{ valid=($sizeValid -and $hashValid); exists=$true; sizeValid=$sizeValid; hashValid=$hashValid; actualSize=[int64]$item.Length; actualSha256=$actualSha256 }
}
function Get-KIModelTargetPath {
    param([Parameter(Mandatory)][object]$Context,[Parameter(Mandatory)][object]$Model)
    return Join-Path (Join-Path ([string]$Context.Config.models.root) ([string]$Model.targetDirectory)) ([string]$Model.fileName)
}
function Find-KIExistingModelCandidate {
    param([Parameter(Mandatory)][object]$Context,[Parameter(Mandatory)][object]$Model,[Parameter(Mandatory)][string]$TargetPath)
    foreach ($configuredRoot in @($Context.Config.models.importSearchRoots)) {
        if (-not $configuredRoot) { continue }
        $root = Expand-KIModelsPath -Path ([string]$configuredRoot)
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $candidates = @(Get-ChildItem -LiteralPath $root -Filter ([string]$Model.fileName) -File -Recurse -ErrorAction SilentlyContinue)
        foreach ($candidate in $candidates) {
            if ($candidate.FullName -eq $TargetPath) { continue }
            $state = Test-KIModelFile -Path $candidate.FullName -Model $Model
            if ([bool]$state.valid) { return $candidate.FullName }
        }
    }
    return $null
}
function ConvertFrom-KISecureString {
    param([Parameter(Mandatory)][Security.SecureString]$SecureValue)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}
function Get-KIHuggingFaceToken {
    param([Parameter(Mandatory)][object]$Context)
    foreach ($name in @('HF_TOKEN','HUGGING_FACE_HUB_TOKEN')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    $tokenPath = Expand-KIModelsPath -Path ([string]$Context.Config.models.huggingFaceTokenFile)
    if (Test-Path -LiteralPath $tokenPath -PathType Leaf) {
        $secure = Import-Clixml -LiteralPath $tokenPath -ErrorAction Stop
        if ($secure -isnot [Security.SecureString]) { throw "Ungültige Hugging-Face-Tokenablage: $tokenPath" }
        return ConvertFrom-KISecureString -SecureValue $secure
    }
    if (-not [bool]$Context.Config.models.allowInteractiveHuggingFaceToken) { return $null }
    Write-Host ''
    Write-Host 'FLUX.2 Klein 9B ist bei Hugging Face zugriffsgeschützt.' -ForegroundColor Yellow
    Write-Host 'Die BFL-Lizenzbedingungen müssen im eigenen Hugging-Face-Konto akzeptiert sein.' -ForegroundColor Yellow
    $secureToken = Read-Host 'Hugging-Face Read-Token eingeben (wird nicht angezeigt)' -AsSecureString
    if ($secureToken.Length -eq 0) { return $null }
    $parent = Split-Path -Parent $tokenPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $secureToken | Export-Clixml -LiteralPath $tokenPath -Force
    return ConvertFrom-KISecureString -SecureValue $secureToken
}
function Invoke-KIResumableHttpDownload {
    param([Parameter(Mandatory)][object]$Context,[Parameter(Mandatory)][object]$Model,[Parameter(Mandatory)][string]$Destination,[string]$Token)
    $partialPath = $Destination + '.partial'
    $retryCount = [int]$Context.Config.models.downloadRetryCount
    $bufferSize = [int]$Context.Config.models.downloadBufferBytes
    for ($attempt=1; $attempt -le $retryCount; $attempt++) {
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $true
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromHours(12)
        try {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,[string]$Model.source)
            $request.Headers.UserAgent.ParseAdd('KI-Stack-Models-Workflows/1.4.1')
            if (-not [string]::IsNullOrWhiteSpace($Token)) { $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$Token) }
            $offset = if (Test-Path -LiteralPath $partialPath -PathType Leaf) { (Get-Item -LiteralPath $partialPath).Length } else { 0 }
            if ($offset -gt 0) { $request.Headers.Range = [Net.Http.Headers.RangeHeaderValue]::new([int64]$offset,$null) }
            $response = $client.Send($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead)
            if ([int]$response.StatusCode -in @(401,403)) { throw 'Zugriff verweigert. Lizenzannahme und Hugging-Face-Token prüfen.' }
            $response.EnsureSuccessStatusCode()
            $append = ($offset -gt 0 -and [int]$response.StatusCode -eq 206)
            if (-not $append) { $offset = 0 }
            $mode = if ($append) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
            $responseStream = $response.Content.ReadAsStream()
            $output = [IO.FileStream]::new($partialPath,$mode,[IO.FileAccess]::Write,[IO.FileShare]::None,$bufferSize,$true)
            try {
                $buffer = [byte[]]::new($bufferSize)
                $downloaded = [int64]$offset
                $lastPercent = -1
                while (($read = $responseStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                    $output.Write($buffer,0,$read); $downloaded += $read
                    $percent = [int][Math]::Floor(($downloaded * 100.0) / [int64]$Model.sizeBytes)
                    if ($percent -ge ($lastPercent + 5)) { Write-Host ('  {0}: {1} %' -f [string]$Model.fileName,[Math]::Min(100,$percent)); $lastPercent=$percent }
                }
            }
            finally { $output.Dispose(); $responseStream.Dispose(); $response.Dispose(); $request.Dispose() }
            $state = Test-KIModelFile -Path $partialPath -Model $Model
            if (-not [bool]$state.valid) { throw ('Prüfsumme oder Größe stimmt nicht: {0}' -f [string]$Model.fileName) }
            Move-Item -LiteralPath $partialPath -Destination $Destination -Force
            return
        }
        catch {
            if ($attempt -ge $retryCount) { throw }
            Write-Host ('Downloadversuch {0} fehlgeschlagen; neuer Versuch: {1}' -f $attempt,$_.Exception.Message) -ForegroundColor Yellow
            Start-Sleep -Seconds ([Math]::Min(30,5*$attempt))
        }
        finally { $client.Dispose(); $handler.Dispose() }
    }
}
function Install-KIManagedFile {
    param([Parameter(Mandatory)][object]$Context,[Parameter(Mandatory)][object]$RollbackState,[Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination)
    $existing = Test-Path -LiteralPath $Destination -PathType Leaf
    $previous = if ($existing) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($Destination)) } else { $null }
    $RollbackState.files = @($RollbackState.files) + @([pscustomobject][ordered]@{path=$Destination;existedBefore=$existing;previousContentBase64=$previous})
    Write-KIModelsRollbackState -Context $Context -State $RollbackState
    $parent=Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null; $RollbackState.createdDirectories=@($RollbackState.createdDirectories)+@($parent); Write-KIModelsRollbackState -Context $Context -State $RollbackState }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}
function Test-KIModuleModels {
    param([Parameter(Mandatory)][object]$Context)
    try {
        $manifest=Get-KIModelsManifest -Context $Context; $catalog=Get-KIWorkflowCatalog -Context $Context
        $issues=[Collections.Generic.List[string]]::new()
        foreach($model in @($manifest.models | Where-Object { [bool]$_.enabled })) {
            if ([string]::IsNullOrWhiteSpace([string]$model.fileName) -or [string]::IsNullOrWhiteSpace([string]$model.targetDirectory)) { [void]$issues.Add("Ungültiger Modelleintrag: $($model.id)") }
            if ([bool]$model.managed) {
                if ([string]$model.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or [int64]$model.sizeBytes -le 0 -or [string]$model.source -notmatch '^https://') { [void]$issues.Add("Unvollständige Integritätsdaten: $($model.id)") }
            }
        }
        foreach($workflow in @($catalog.workflows)) {
            $source=Join-Path (Join-Path (Get-KIModelsProjectRoot) ([string]$Context.Config.models.workflowSourceRoot)) ([string]$workflow.file)
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { [void]$issues.Add("Workflow fehlt: $($workflow.file)") }
            else { try { $null=Get-Content -LiteralPath $source -Raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop } catch { [void]$issues.Add("Workflow-JSON ungültig: $($workflow.file)") } }
        }
        return [pscustomobject][ordered]@{success=($issues.Count -eq 0);skipped=$false;message=if($issues.Count -eq 0){'Modell- und Workflowmanifeste geprüft.'}else{$issues -join ' | '};data=[pscustomobject][ordered]@{issues=@($issues);modelCount=@($manifest.models).Count;workflowCount=@($catalog.workflows).Count}}
    } catch { return [pscustomobject][ordered]@{success=$false;skipped=$false;message=$_.Exception.Message;data=$null} }
}
function Install-KIModuleModels {
    param([Parameter(Mandatory)][object]$Context)
    $manifest=Get-KIModelsManifest -Context $Context; $catalog=Get-KIWorkflowCatalog -Context $Context
    $modelRoot=[string]$Context.Config.models.root; $workflowSource=Join-Path (Get-KIModelsProjectRoot) ([string]$Context.Config.models.workflowSourceRoot); $workflowTarget=[string]$Context.Config.models.workflowTargetRoot
    $targets=@($Context.Config.models.directories | ForEach-Object { Join-Path $modelRoot ([string]$_) }) + @($workflowTarget,[string]$Context.Config.models.integrationRoot)
    if ($Context.Mode -eq 'DryRun') {
        return [pscustomobject][ordered]@{success=$true;skipped=$false;message='Dry-Run: Modelle und Workflows wurden vollständig geplant.';data=[pscustomobject][ordered]@{wouldCreate=$targets;requiredDownloads=@($manifest.models | Where-Object {[bool]$_.required} | ForEach-Object  fileName);workflowFiles=@($catalog.workflows | ForEach-Object  file);createdByTransaction=@()}}
    }
    $markerPath=[string]$Context.Config.models.installationMarker
    $markerCompliant=$false
    if(Test-Path -LiteralPath $markerPath -PathType Leaf){try{$existingMarker=Get-Content -LiteralPath $markerPath -Raw|ConvertFrom-Json -Depth 100;$markerCompliant=[string]$existingMarker.release-eq'KI-Stack-Models-Workflows-Execute-v1.4.1'}catch{$markerCompliant=$false}}
    $workflowCompliant=$markerCompliant
    if($workflowCompliant){foreach($workflow in @($catalog.workflows)){$source=Join-Path $workflowSource ([string]$workflow.file);$destination=Join-Path $workflowTarget ([string]$workflow.file);if(-not(Test-Path -LiteralPath $destination -PathType Leaf)-or(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash-ne(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash){$workflowCompliant=$false;break}}}
    if($workflowCompliant){return [pscustomobject][ordered]@{success=$true;skipped=$true;message='AlreadyCompliant';data=[pscustomobject][ordered]@{release='KI-Stack-Models-Workflows-Execute-v1.4.1';modelsDownloaded=$false;workflowsChanged=$false}}}
    $rollback=[pscustomobject][ordered]@{schemaVersion='1.0';transactionId=[string]$Context.Transaction.transactionId;createdAt=(Get-Date).ToString('o');updatedAt=(Get-Date).ToString('o');createdDirectories=@();createdModels=@();files=@();rollbackCompletedAt=$null;rollbackIssues=@()}
    Write-KIModelsRollbackState -Context $Context -State $rollback
    foreach($target in $targets){if (-not (Test-Path -LiteralPath $target)){New-Item -ItemType Directory -Path $target -Force | Out-Null;$rollback.createdDirectories=@($rollback.createdDirectories)+@($target);Write-KIModelsRollbackState -Context $Context -State $rollback}}
    foreach($workflow in @($catalog.workflows)){
        $source=Join-Path $workflowSource ([string]$workflow.file);$destination=Join-Path $workflowTarget ([string]$workflow.file)
        Install-KIManagedFile -Context $Context -RollbackState $rollback -Source $source -Destination $destination
        if($workflow.PSObject.Properties.Name -contains 'mapping' -and $workflow.mapping){$mappingSource=Join-Path $workflowSource ([string]$workflow.mapping);$mappingDestination=Join-Path $workflowTarget ([string]$workflow.mapping);Install-KIManagedFile -Context $Context -RollbackState $rollback -Source $mappingSource -Destination $mappingDestination}
    }
    $token=$null;$modelResults=[Collections.Generic.List[object]]::new()
    foreach($model in @($manifest.models | Where-Object {[bool]$_.enabled})){
        $target=Get-KIModelTargetPath -Context $Context -Model $model;$state=Test-KIModelFile -Path $target -Model $model
        if([bool]$state.exists -and -not [bool]$state.valid -and [bool]$model.managed){throw "Vorhandene Modelldatei ist ungültig und wird nicht überschrieben: $target"}
        if([bool]$state.valid){[void]$modelResults.Add([pscustomobject][ordered]@{id=$model.id;status='Reused';path=$target});continue}
        $candidate=Find-KIExistingModelCandidate -Context $Context -Model $model -TargetPath $target
        if($candidate){Copy-Item -LiteralPath $candidate -Destination $target -Force;$rollback.createdModels=@($rollback.createdModels)+@($target);Write-KIModelsRollbackState -Context $Context -State $rollback;[void]$modelResults.Add([pscustomobject][ordered]@{id=$model.id;status='Imported';path=$target;source=$candidate});continue}
        if(-not [bool]$model.managed){[void]$modelResults.Add([pscustomobject][ordered]@{id=$model.id;status='OptionalMissing';path=$target});continue}
        if($model.PSObject.Properties.Name -contains 'manualExternal' -and [bool]$model.manualExternal){[void]$modelResults.Add([pscustomobject][ordered]@{id=$model.id;status='ManualExternalRequired';path=$target;reference=[string]$model.manualReference});continue}
        if(-not [bool]$Context.Config.models.downloadsEnabled){if([bool]$model.required){throw "Pflichtmodell fehlt und Downloads sind deaktiviert: $($model.fileName)"};continue}
        if([bool]$model.gated -and [string]::IsNullOrWhiteSpace($token)){$token=Get-KIHuggingFaceToken -Context $Context;if([string]::IsNullOrWhiteSpace($token)){throw "Hugging-Face-Token für das Pflichtmodell fehlt: $($model.fileName)"}}
        Write-Host ("Modell wird aus offizieller Quelle geladen: {0}" -f [string]$model.fileName) -ForegroundColor Cyan
        Invoke-KIResumableHttpDownload -Context $Context -Model $model -Destination $target -Token $(if([bool]$model.gated){$token}else{$null})
        $rollback.createdModels=@($rollback.createdModels)+@($target);Write-KIModelsRollbackState -Context $Context -State $rollback
        [void]$modelResults.Add([pscustomobject][ordered]@{id=$model.id;status='Downloaded';path=$target})
    }
    $marker=[pscustomobject][ordered]@{managedBy='KI-STACK-MODELS-WORKFLOWS-MANAGED';release='KI-Stack-Models-Workflows-Execute-v1.4.1';installedAt=(Get-Date).ToString('o');transactionId=[string]$Context.Transaction.transactionId;models=@($modelResults);workflows=@($catalog.workflows | ForEach-Object  file)}
    $markerTemp=Join-Path ([string]$Context.TransactionDirectory) 'models-installation.json';$marker | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $markerTemp -Encoding UTF8
    Install-KIManagedFile -Context $Context -RollbackState $rollback -Source $markerTemp -Destination ([string]$Context.Config.models.installationMarker)
    return [pscustomobject][ordered]@{success=$true;skipped=$false;message='Modelle und Workflows wurden installiert.';data=[pscustomobject][ordered]@{models=@($modelResults);workflowCount=@($catalog.workflows).Count;rollbackStatePath=(Get-KIModelsRollbackStatePath -Context $Context)}}
}
function Validate-KIModuleModels {
    param([Parameter(Mandatory)][object]$Context)
    if($Context.Mode -eq 'DryRun'){return [pscustomobject][ordered]@{success=$true;skipped=$false;message='Dry-Run: Modell- und Workflowzielzustand ist planbar.';data=$null}}
    $manifest=Get-KIModelsManifest -Context $Context;$catalog=Get-KIWorkflowCatalog -Context $Context;$issues=[Collections.Generic.List[string]]::new();$availability=[Collections.Generic.List[object]]::new()
    foreach($model in @($manifest.models | Where-Object {[bool]$_.enabled})){$path=Get-KIModelTargetPath -Context $Context -Model $model;$state=Test-KIModelFile -Path $path -Model $model;[void]$availability.Add([pscustomobject][ordered]@{id=$model.id;required=[bool]$model.required;available=[bool]$state.valid;path=$path});if([bool]$model.required -and -not [bool]$state.valid){[void]$issues.Add("Pflichtmodell ungültig oder fehlend: $($model.fileName)")}}
    $target=[string]$Context.Config.models.workflowTargetRoot
    foreach($workflow in @($catalog.workflows)){$path=Join-Path $target ([string]$workflow.file);if (-not (Test-Path -LiteralPath $path -PathType Leaf)){[void]$issues.Add("Workflow fehlt: $($workflow.file)");continue};try{$wf=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop} catch {[void]$issues.Add("Workflow ungültig: $($workflow.file)")}}
    $apiPath=Join-Path $target 'FLUX2-Klein-9B-OpenWebUI-API-FLAT.json'
    if(Test-Path -LiteralPath $apiPath){$api=Get-Content -LiteralPath $apiPath -Raw | ConvertFrom-Json -Depth 100;foreach($node in @('92','87','84','85')){if($api.PSObject.Properties.Name -notcontains $node){[void]$issues.Add("Open-WebUI-API-Node fehlt: $node")}};if($api.'92'.inputs.PSObject.Properties.Name -notcontains 'text'){[void]$issues.Add('Prompt-Key text in Node 92 fehlt.')}}
    $marker=[string]$Context.Config.models.installationMarker;if (-not (Test-Path -LiteralPath $marker -PathType Leaf)){[void]$issues.Add('Installationsmarker fehlt.')}else{try{$m=Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json -Depth 100;if([string]$m.managedBy -ne 'KI-STACK-MODELS-WORKFLOWS-MANAGED'){[void]$issues.Add('Installationsmarker ist nicht verwaltet.')}} catch {[void]$issues.Add('Installationsmarker ist ungültig.')}}
    return [pscustomobject][ordered]@{success=($issues.Count -eq 0);skipped=$false;message=if($issues.Count -eq 0){'Pflichtmodelle und Workflows vollständig validiert.'}else{$issues -join ' | '};data=[pscustomobject][ordered]@{issues=@($issues);availability=@($availability)}}
}
function Rollback-KIModuleModels {
    param([Parameter(Mandatory)][object]$Context)
    if($Context.Mode -eq 'DryRun'){return [pscustomobject][ordered]@{success=$true;skipped=$true;message='Dry-Run: Kein Modell-Rollback erforderlich.';data=$null}}
    $state=Read-KIModelsRollbackState -Context $Context;if(-not $state){return [pscustomobject][ordered]@{success=$true;skipped=$true;message='Kein Modell-Rollbackjournal vorhanden.';data=$null}}
    $issues=[Collections.Generic.List[string]]::new()
    foreach($entry in @($state.files) | Sort-Object {([string]$_.path).Length} -Descending){try{if([bool]$entry.existedBefore){[IO.File]::WriteAllBytes([string]$entry.path,[Convert]::FromBase64String([string]$entry.previousContentBase64))}elseif(Test-Path -LiteralPath ([string]$entry.path)){Remove-Item -LiteralPath ([string]$entry.path) -Force}} catch {[void]$issues.Add($_.Exception.Message)}}
    foreach($path in @($state.createdModels)){try{if(Test-Path -LiteralPath ([string]$path)){Remove-Item -LiteralPath ([string]$path) -Force}} catch {[void]$issues.Add($_.Exception.Message)}}
    foreach($path in @($state.createdDirectories) | Sort-Object {([string]$_).Length} -Descending){try{if(Test-Path -LiteralPath ([string]$path)){if(@(Get-ChildItem -LiteralPath ([string]$path) -Force -ErrorAction SilentlyContinue).Count -eq 0){Remove-Item -LiteralPath ([string]$path) -Force}}} catch {[void]$issues.Add($_.Exception.Message)}}
    $state.rollbackCompletedAt=(Get-Date).ToString('o');$state.rollbackIssues=@($issues);Write-KIModelsRollbackState -Context $Context -State $state
    return [pscustomobject][ordered]@{success=($issues.Count -eq 0);skipped=$false;message=if($issues.Count -eq 0){'Modelle/Workflows-Rollback abgeschlossen.'}else{'Rollback mit Fehlern abgeschlossen.'};data=[pscustomobject][ordered]@{issues=@($issues)}}
}
Export-ModuleMember -Function *

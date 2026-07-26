[CmdletBinding()]
param(
    [ValidateSet('Preflight', 'Install', 'Validate', 'Rollback')]
    [string]$Action = 'Preflight',
    [string]$KIStackRoot = 'C:\KI-Stack',
    [string]$OpenWebUIEndpoint = 'http://127.0.0.1:8080',
    [string]$ComfyEndpoint = 'http://127.0.0.1:8188',
    [Security.SecureString]$ApiToken,
    [string]$BackupPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$version = '2.0.5-rc3'
$manager = 'KI-STACK-OPENWEBUI-VISUAL-PACK'
$imageToolId = 'ki_stack_generate_image'
$videoToolId = 'ki_stack_generate_video'
$profiles = @('ki-stack-it-technik', 'ki-stack-allgemein')
$packageRoot = $PSScriptRoot

function Write-Step {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function ConvertFrom-SecureToken {
    param([Parameter(Mandatory)][Security.SecureString]$Value)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Invoke-OpenWebUIApi {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('GET', 'POST', 'DELETE')][string]$Method = 'GET',
        [AllowNull()][object]$Body = $null
    )
    if ($null -eq $script:ApiToken) {
        throw 'OpenWebUI API-Key fehlt.'
    }
    $plain = ConvertFrom-SecureToken $script:ApiToken
    try {
        $parameters = @{
            Uri = $script:OpenWebUIEndpoint.TrimEnd('/') + $Path
            Method = $Method
            Headers = @{ Authorization = "Bearer $plain" }
            TimeoutSec = 120
        }
        if ($null -ne $Body) {
            $parameters.ContentType = 'application/json; charset=utf-8'
            $parameters.Body = $Body | ConvertTo-Json -Depth 50 -Compress
        }
        Invoke-RestMethod @parameters
    }
    finally {
        $plain = $null
    }
}

function Get-Tool {
    param([Parameter(Mandatory)][string]$Id)
    try {
        Invoke-OpenWebUIApi -Path "/api/v1/tools/id/$Id"
    }
    catch {
        if ($null -ne $_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) {
            return $null
        }
        throw
    }
}

function Get-Profile {
    param([Parameter(Mandatory)][string]$Id)
    try {
        Invoke-OpenWebUIApi -Path ("/api/v1/models/model?id=" + [Uri]::EscapeDataString($Id))
    }
    catch {
        if ($null -ne $_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) {
            return $null
        }
        throw
    }
}

function ConvertTo-ToolForm {
    param([Parameter(Mandatory)][object]$Tool)
    [ordered]@{
        id = [string]$Tool.id
        name = [string]$Tool.name
        content = [string]$Tool.content
        meta = $Tool.meta
        access_grants = @($Tool.access_grants)
    }
}

function ConvertTo-ProfileForm {
    param(
        [Parameter(Mandatory)][object]$Profile,
        [Parameter(Mandatory)][string[]]$ToolIds
    )
    $meta = [ordered]@{}
    $Profile.meta.PSObject.Properties | ForEach-Object {
        $meta[$_.Name] = $_.Value
    }
    $meta.toolIds = @($ToolIds)
    [ordered]@{
        id = [string]$Profile.id
        base_model_id = [string]$Profile.base_model_id
        name = [string]$Profile.name
        meta = $meta
        params = $Profile.params
        access_grants = @($Profile.access_grants)
        is_active = [bool]$Profile.is_active
    }
}

function New-ManagedToolForm {
    param([ValidateSet('image', 'video')][string]$Kind)
    if ($Kind -eq 'image') {
        $id = $script:imageToolId
        $name = 'KI-Stack Bildgenerierung'
        $canonical = 'ki-stack-generate-image'
        $description = 'Lokale Bildgenerierung ausschließlich mit Z-Image Turbo über ComfyUI.'
        $workflow = 'Z-Image-Turbo-OpenWebUI-API'
        $file = 'Tool\ki-stack-generate-image.py'
    }
    else {
        $id = $script:videoToolId
        $name = 'KI-Stack Videogenerierung'
        $canonical = 'ki-stack-generate-video'
        $description = 'Lokale Videogenerierung ausschließlich mit WAN2.2 T2V 14B über ComfyUI.'
        $workflow = 'WAN2.2-T2V-14B-OpenWebUI-API'
        $file = 'Tool\ki-stack-generate-video.py'
    }
    [ordered]@{
        id = $id
        name = $name
        content = Get-Content -LiteralPath (Join-Path $script:packageRoot $file) -Raw -Encoding UTF8
        meta = [ordered]@{
            description = $description
            manifest = [ordered]@{
                managedBy = $script:manager
                version = $script:version
                canonical_id = $canonical
                workflow = $workflow
            }
            has_user_valves = $false
        }
        access_grants = @()
    }
}

function Test-LocalContract {
    Write-Step 'Lokalen Zielvertrag pruefen'
    $root = [IO.Path]::GetFullPath($script:KIStackRoot)
    $requiredFiles = @(
        @{ Relative = 'models\diffusion_models\z_image_turbo_bf16.safetensors'; Bytes = 12309866400L },
        @{ Relative = 'models\text_encoders\Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf'; Bytes = 4280404800L },
        @{ Relative = 'models\vae\ae.safetensors'; Bytes = 335304388L },
        @{ Relative = 'models\diffusion_models\wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors'; Bytes = 14293923632L },
        @{ Relative = 'models\diffusion_models\wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors'; Bytes = 14293923632L },
        @{ Relative = 'models\text_encoders\umt5_xxl_fp8_e4m3fn_scaled.safetensors'; Bytes = 6735906897L },
        @{ Relative = 'models\vae\wan_2.1_vae.safetensors'; Bytes = 253815318L },
        @{ Relative = 'models\loras\Wan2.2_LightX2V_high_n54vv.safetensors'; Bytes = 1245752600L },
        @{ Relative = 'models\loras\Wan2.2_LightX2V_low_n54vv.safetensors'; Bytes = 1245752600L }
    )
    foreach ($contract in $requiredFiles) {
        $path = Join-Path $root $contract.Relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Modelldatei fehlt: $path"
        }
        $length = (Get-Item -LiteralPath $path).Length
        if ($length -ne $contract.Bytes) {
            throw "Modelldateigroesse verletzt: $path ($length statt $($contract.Bytes))"
        }
        Write-Host "OK: $($contract.Relative)"
    }

    $workflowContracts = @(
        @{ Name='Z-Image-Turbo-Uncensored.json'; Nodes=11; Model='Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf' },
        @{ Name='WAN2.2-T2V-14B-Uncensored-4Step.json'; Nodes=33; Model=$null }
    )
    foreach ($contract in $workflowContracts) {
        $path=Join-Path $script:packageRoot ('UIWorkflow\'+$contract.Name)
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "UI-Workflowquelle fehlt: $path"}
        $graph=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -Depth 100
        if(@($graph.nodes).Count-ne[int]$contract.Nodes){throw "UI-Workflow besitzt nicht die erwarteten Nodes: $($contract.Name)"}
        $raw=Get-Content -LiteralPath $path -Raw
        if($raw-match'OpenWebUI-API' -or $raw-match'(?i)huggingface\.co|resolve/(main|latest)|\?download=' -or $raw.Contains('Qwen3-4b-Uncensored-Z-Image-Engineer-V4-Q8_0.gguf')){throw "UI-Workflow enthält API-Prompt oder Downloadvertrag: $($contract.Name)"}
        if($contract.Model){
            $loaders=@($graph.nodes|Where-Object {$_.type -eq 'CLIPLoaderGGUF'})
            if($loaders.Count-ne1 -or [string]$loaders[0].widgets_values[0] -ne [string]$contract.Model){throw "Z-Image UI-Ladeknoten verwendet nicht exakt $($contract.Model)"}
        }
        Write-Host "OK: UIWorkflow\$($contract.Name)"
    }
}

function Get-UIWorkflowContracts {
    @(
        @{Name='Z-Image-Turbo-Uncensored.json';Nodes=11},
        @{Name='WAN2.2-T2V-14B-Uncensored-4Step.json';Nodes=33}
    )
}

function Install-UIWorkflows {
    foreach($contract in Get-UIWorkflowContracts){
        $source=Join-Path $script:packageRoot ('UIWorkflow\'+$contract.Name)
        $target=Join-Path $script:KIStackRoot ('data\comfyui\user\default\workflows\'+$contract.Name)
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force|Out-Null
        $temporary=$target+'.rc3.tmp'
        Copy-Item -LiteralPath $source -Destination $temporary -Force
        if((Get-FileHash $source -Algorithm SHA256).Hash-ne(Get-FileHash $temporary -Algorithm SHA256).Hash){throw "UI-Workflow Staging-Readback fehlgeschlagen: $($contract.Name)"}
        Move-Item -LiteralPath $temporary -Destination $target -Force
    }
}

function Test-InstalledUIWorkflows {
    foreach($contract in Get-UIWorkflowContracts){
        $source=Join-Path $script:packageRoot ('UIWorkflow\'+$contract.Name)
        $target=Join-Path $script:KIStackRoot ('data\comfyui\user\default\workflows\'+$contract.Name)
        if(-not(Test-Path -LiteralPath $target -PathType Leaf)){throw "Installierter UI-Workflow fehlt: $($contract.Name)"}
        if((Get-FileHash $source -Algorithm SHA256).Hash-ne(Get-FileHash $target -Algorithm SHA256).Hash){throw "Installierter UI-Workflow-Readback fehlgeschlagen: $($contract.Name)"}
        $graph=Get-Content -LiteralPath $target -Raw|ConvertFrom-Json -Depth 100
        if(@($graph.nodes).Count-ne[int]$contract.Nodes){throw "Installierter UI-Workflow ist leer oder unvollständig: $($contract.Name)"}
    }
}

function Test-ComfyContract {
    Write-Step 'ComfyUI-API-Vertrag pruefen'
    $requiredNodes = @(
        'KSampler', 'SaveImage', 'ModelSamplingAuraFlow', 'EmptySD3LatentImage',
        'CLIPLoaderGGUF', 'ConditioningZeroOut', 'CreateVideo', 'SaveVideo',
        'KSamplerAdvanced', 'EmptyHunyuanLatentVideo', 'LoraLoaderModelOnly',
        'ModelSamplingSD3', 'CLIPLoader', 'CLIPTextEncode', 'UNETLoader',
        'VAELoader', 'VAEDecode'
    )
    foreach ($node in $requiredNodes) {
        $uri = '{0}/object_info/{1}' -f $script:ComfyEndpoint.TrimEnd('/'), [Uri]::EscapeDataString($node)
        $response = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 30
        if ($null -eq $response.PSObject.Properties[$node]) {
            throw "ComfyUI-Node fehlt: $node"
        }
        Write-Host "OK: $node"
    }
    $saveVideo = Invoke-RestMethod -Method Get -Uri ($script:ComfyEndpoint.TrimEnd('/') + '/object_info/SaveVideo') -TimeoutSec 30
    $formatOptions = @($saveVideo.SaveVideo.input.required.format[1].options)
    $codecOptions = @($saveVideo.SaveVideo.input.required.codec[1].options)
    if ('mp4' -notin $formatOptions -or 'h264' -notin $codecOptions) {
        throw 'SaveVideo bietet den erforderlichen MP4/H.264-Vertrag nicht an.'
    }
}

function Test-OpenWebUIContract {
    Write-Step 'OpenWebUI-API und Agentenprofile pruefen'
    $health = Invoke-RestMethod -Method Get -Uri ($script:OpenWebUIEndpoint.TrimEnd('/') + '/health') -TimeoutSec 30
    if ($null -eq $health) {
        throw 'OpenWebUI-Healthcheck lieferte keine Antwort.'
    }
    foreach ($profileId in $script:profiles) {
        $profile = Get-Profile -Id $profileId
        if ($null -eq $profile) {
            throw "OpenWebUI-Agentenprofil fehlt: $profileId"
        }
        Write-Host "OK: $profileId"
    }
}

function New-Backup {
    $directory = Join-Path $script:KIStackRoot ('backups\openwebui-visual-pack\OWUI-VISUAL-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff'))
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $tools = @()
    foreach ($id in @($script:imageToolId, $script:videoToolId)) {
        $tool = Get-Tool -Id $id
        $tools += [ordered]@{
            id = $id
            existed = ($null -ne $tool)
            form = if ($null -ne $tool) { ConvertTo-ToolForm -Tool $tool } else { $null }
        }
    }
    $bindings = @()
    foreach ($id in $script:profiles) {
        $profile = Get-Profile -Id $id
        if ($null -eq $profile) {
            throw "OpenWebUI-Agentenprofil fehlt: $id"
        }
        $bindings += [ordered]@{ id = $id; toolIds = @($profile.meta.toolIds) }
    }
    $backup = [ordered]@{
        schemaVersion = '1.0'
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        manager = $script:manager
        tools = $tools
        profileBindings = $bindings
        uiWorkflows = @(
            foreach($contract in Get-UIWorkflowContracts){
                $target=Join-Path $script:KIStackRoot ('data\comfyui\user\default\workflows\'+$contract.Name)
                [ordered]@{name=$contract.Name;target=$target;existed=(Test-Path -LiteralPath $target -PathType Leaf);content=if(Test-Path -LiteralPath $target -PathType Leaf){Get-Content -LiteralPath $target -Raw}else{$null}}
            }
        )
    }
    $path = Join-Path $directory 'visual-pack.backup.json'
    $backup | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path -Encoding utf8
    $path
}

function Restore-Backup {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Backup fehlt: $Path"
    }
    $backup = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 50
    foreach($workflow in @($backup.uiWorkflows)){
        if([bool]$workflow.existed){
            New-Item -ItemType Directory -Path (Split-Path -Parent ([string]$workflow.target)) -Force|Out-Null
            [IO.File]::WriteAllText([string]$workflow.target,[string]$workflow.content,[Text.UTF8Encoding]::new($false))
        }elseif(Test-Path -LiteralPath ([string]$workflow.target)){
            Remove-Item -LiteralPath ([string]$workflow.target) -Force
        }
    }
    foreach ($entry in @($backup.tools)) {
        $current = Get-Tool -Id ([string]$entry.id)
        if ([bool]$entry.existed) {
            $apiPath = if ($null -eq $current) { '/api/v1/tools/create' } else { "/api/v1/tools/id/$($entry.id)/update" }
            $null = Invoke-OpenWebUIApi -Path $apiPath -Method POST -Body $entry.form
        }
        elseif ($null -ne $current) {
            $null = Invoke-OpenWebUIApi -Path "/api/v1/tools/id/$($entry.id)/delete" -Method DELETE
        }
    }
    foreach ($binding in @($backup.profileBindings)) {
        $profile = Get-Profile -Id ([string]$binding.id)
        if ($null -ne $profile) {
            $form = ConvertTo-ProfileForm -Profile $profile -ToolIds @($binding.toolIds)
            $null = Invoke-OpenWebUIApi -Path '/api/v1/models/model/update' -Method POST -Body $form
        }
    }
}

function Install-Tools {
    $backup = New-Backup
    try {
        Install-UIWorkflows
        foreach ($kind in @('image', 'video')) {
            $form = New-ManagedToolForm -Kind $kind
            $current = Get-Tool -Id ([string]$form.id)
            if ($null -ne $current) {
                $owner = [string]$current.meta.manifest.managedBy
                $acceptedOwners = @($script:manager)
                if ($kind -eq 'image') {
                    $acceptedOwners += 'KI-STACK-OPENWEBUI-IMAGE-PACK'
                }
                if ($owner -notin $acceptedOwners) {
                    throw "Tool-ID-Kollision: $($form.id) wird durch '$owner' verwaltet."
                }
            }
            $apiPath = if ($null -eq $current) { '/api/v1/tools/create' } else { "/api/v1/tools/id/$($form.id)/update" }
            $null = Invoke-OpenWebUIApi -Path $apiPath -Method POST -Body $form
            Write-Host "Installiert: $($form.id)"
        }

        foreach ($profileId in $script:profiles) {
            $profile = Get-Profile -Id $profileId
            if ($null -eq $profile) {
                throw "OpenWebUI-Agentenprofil fehlt: $profileId"
            }
            $preserved = @($profile.meta.toolIds | Where-Object {
                $_ -notin @($script:imageToolId, $script:videoToolId)
            })
            $targetIds = @($preserved + $script:imageToolId + $script:videoToolId | Select-Object -Unique)
            $form = ConvertTo-ProfileForm -Profile $profile -ToolIds $targetIds
            $null = Invoke-OpenWebUIApi -Path '/api/v1/models/model/update' -Method POST -Body $form
            Write-Host "Gebunden: $profileId"
        }
        $backup
    }
    catch {
        $installError = $_
        Write-Warning 'Installation fehlgeschlagen; der vorherige OpenWebUI-Stand wird wiederhergestellt.'
        try {
            Restore-Backup -Path $backup
            $installError.Exception.Data['KIStackRollbackStatus'] = 'Completed'
            $installError.Exception.Data['KIStackBackupPath'] = $backup
        }
        catch {
            throw "Visual-Pack-Installation fehlgeschlagen und Rollback fehlgeschlagen: $($installError.Exception.Message); Rollback: $($_.Exception.Message)"
        }
        throw $installError
    }
}

function Test-InstalledTools {
    Write-Step 'Installierten OpenWebUI-Zielstand validieren'
    $contracts = @(
        @{
            Id = $script:imageToolId
            Name = 'KI-Stack Bildgenerierung'
            Canonical = 'ki-stack-generate-image'
            Marker = 'generate_image'
            Forbidden = @()
        },
        @{
            Id = $script:videoToolId
            Name = 'KI-Stack Videogenerierung'
            Canonical = 'ki-stack-generate-video'
            Marker = 'generate_video'
            Forbidden = @()
        }
    )
    foreach ($contract in $contracts) {
        $tool = Get-Tool -Id $contract.Id
        if ($null -eq $tool) { throw "Tool fehlt: $($contract.Id)" }
        if ([string]$tool.name -ne $contract.Name) { throw "Tool-Name verletzt: $($contract.Id)" }
        if ([string]$tool.meta.manifest.managedBy -ne $script:manager) { throw "Tool-Owner verletzt: $($contract.Id)" }
        if ([string]$tool.meta.manifest.version -ne $script:version) { throw "Tool-Version verletzt: $($contract.Id)" }
        if ([string]$tool.meta.manifest.canonical_id -ne $contract.Canonical) { throw "Canonical-ID verletzt: $($contract.Id)" }
        if (-not ([string]$tool.content).Contains($contract.Marker)) { throw "Toolmethode fehlt: $($contract.Id)" }
        foreach ($forbidden in $contract.Forbidden) {
            if ([string]$tool.content -cmatch [regex]::Escape($forbidden)) {
                throw "Altverweis '$forbidden' im Tool $($contract.Id)"
            }
        }
        Write-Host "OK: $($contract.Id)"
    }
    foreach ($profileId in $script:profiles) {
        $profile = Get-Profile -Id $profileId
        $ids = @($profile.meta.toolIds)
        if ($script:imageToolId -notin $ids -or $script:videoToolId -notin $ids) {
            throw "Visual-Toolbindung fehlt: $profileId"
        }
        Write-Host "OK: $profileId"
    }
    $list = @(Invoke-OpenWebUIApi -Path '/api/v1/tools/')
    foreach ($id in @($script:imageToolId, $script:videoToolId)) {
        if (@($list | Where-Object { $_.id -eq $id }).Count -ne 1) {
            throw "Tool-Duplikat oder fehlender Toollisteneintrag: $id"
        }
    }
}

if ($null -eq $ApiToken) {
    $ApiToken = Read-Host 'Temporären OpenWebUI API-Key eingeben' -AsSecureString
}
$script:ApiToken = $ApiToken
$script:KIStackRoot = [IO.Path]::GetFullPath($KIStackRoot)
$script:OpenWebUIEndpoint = $OpenWebUIEndpoint
$script:ComfyEndpoint = $ComfyEndpoint

switch ($Action) {
    'Preflight' {
        Test-LocalContract
        Test-ComfyContract
        Test-OpenWebUIContract
        Write-Host ''
        Write-Host 'PREFLIGHT BESTANDEN. Es wurde nichts veraendert.' -ForegroundColor Green
    }
    'Install' {
        Test-LocalContract
        Test-ComfyContract
        Test-OpenWebUIContract
        $createdBackup = Install-Tools
        Test-InstalledUIWorkflows
        Test-InstalledTools
        Write-Host ''
        Write-Host 'INSTALLATION UND VALIDIERUNG BESTANDEN.' -ForegroundColor Green
        Write-Host "Rollback-Backup: $createdBackup"
        [pscustomobject]@{
            passed = $true
            backupPath = $createdBackup
            rollbackStatus = 'NotRequired'
            apiKeyStored = $false
        }
    }
    'Validate' {
        Test-LocalContract
        Test-ComfyContract
        Test-OpenWebUIContract
        Test-InstalledUIWorkflows
        Test-InstalledTools
        Write-Host ''
        Write-Host 'ZIELVALIDIERUNG BESTANDEN.' -ForegroundColor Green
    }
    'Rollback' {
        if ([string]::IsNullOrWhiteSpace($BackupPath)) {
            throw 'Rollback erfordert -BackupPath.'
        }
        Restore-Backup -Path $BackupPath
        Write-Host ''
        Write-Host 'ROLLBACK BESTANDEN.' -ForegroundColor Green
    }
}


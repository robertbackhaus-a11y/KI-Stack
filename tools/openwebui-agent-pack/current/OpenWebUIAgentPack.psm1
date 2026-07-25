Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-AgentPackSecureString {
    param([Parameter(Mandatory)][Security.SecureString]$SecureString)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Get-AgentPackPropertyValue {
    param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-AgentPackApiFailure {
    param(
        [Parameter(Mandatory)][object]$ErrorRecord,
        [AllowEmptyString()][string]$SensitiveValue = ''
    )
    $exception = Get-AgentPackPropertyValue -Object $ErrorRecord -Name 'Exception'
    $response = Get-AgentPackPropertyValue -Object $exception -Name 'Response'
    $statusValue = Get-AgentPackPropertyValue -Object $response -Name 'StatusCode'
    $numericStatus = if ($null -ne $statusValue) {
        $valueProperty = Get-AgentPackPropertyValue -Object $statusValue -Name 'value__'
        if ($null -ne $valueProperty) { [int]$valueProperty } else { try { [int]$statusValue } catch { $null } }
    } else {
        $data = Get-AgentPackPropertyValue -Object $exception -Name 'Data'
        if ($null -ne $data -and $data.Contains('AgentPackHttpStatus')) { [int]$data['AgentPackHttpStatus'] } else { $null }
    }
    $errorDetails = Get-AgentPackPropertyValue -Object $ErrorRecord -Name 'ErrorDetails'
    $detail = [string](Get-AgentPackPropertyValue -Object $errorDetails -Name 'Message')
    $message = [string](Get-AgentPackPropertyValue -Object $exception -Name 'Message')
    $typeName = if ($null -ne $exception) { $exception.GetType().FullName } else { '' }
    $combined = (($message,$detail | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' | ')
    if (-not [string]::IsNullOrEmpty($SensitiveValue)) { $combined = $combined.Replace($SensitiveValue,'<redacted>') }
    $combined = $combined -replace '(?i)Bearer\s+\S+','Bearer <redacted>' -replace '(?i)\bsk-[A-Za-z0-9._-]{10,}\b','<redacted>'
    $category = switch ($numericStatus) {
        401 { 'Unauthorized' }
        403 { 'Forbidden' }
        500 { 'ServerError' }
        default {
            if ($typeName -match 'Timeout|TaskCanceled' -or $combined -match '(?i)timed?\s*out|timeout') { 'Timeout' }
            elseif ($typeName -match 'Authentication|Tls|Ssl' -or $combined -match '(?i)\bTLS\b|\bSSL\b|certificate') { 'Tls' }
            elseif ($typeName -match 'Socket|HttpRequest' -or $combined -match '(?i)\bDNS\b|name.*resolve|connection|host.*known') { 'Connection' }
            elseif ($null -ne $numericStatus) { 'HttpError' }
            else { 'TransportError' }
        }
    }
    [pscustomobject]@{
        category=$category
        statusCode=$numericStatus
        hasResponse=($null -ne $response)
        technicalMessage=if([string]::IsNullOrWhiteSpace($combined)){$category}else{$combined}
        containsSecret=$false
    }
}

function Invoke-AgentPackApi {
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][Security.SecureString]$ApiToken,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('GET','POST','DELETE')][string]$Method = 'GET',
        [AllowNull()][object]$Body = $null
    )
    $plainToken = ConvertFrom-AgentPackSecureString -SecureString $ApiToken
    try {
        $parameters = @{
            Uri = $Endpoint.TrimEnd('/') + $Path
            Method = $Method
            Headers = @{ Authorization = "Bearer $plainToken" }
            TimeoutSec = 120
        }
        if ($null -ne $Body) {
            $parameters.ContentType = 'application/json; charset=utf-8'
            $parameters.Body = $Body | ConvertTo-Json -Depth 30 -Compress
        }
        try {
            return Invoke-RestMethod @parameters
        }
        catch {
            $failure = Get-AgentPackApiFailure -ErrorRecord $_ -SensitiveValue $plainToken
            $status = if ($null -ne $failure.statusCode) { " HTTP $($failure.statusCode)" } else { '' }
            $wrapped = [InvalidOperationException]::new("OpenWebUI-API-Fehler [$($failure.category)$status]: $($failure.technicalMessage)",$_.Exception)
            $wrapped.Data['AgentPackFailureCategory'] = [string]$failure.category
            if ($null -ne $failure.statusCode) { $wrapped.Data['AgentPackHttpStatus'] = [int]$failure.statusCode }
            throw $wrapped
        }
    }
    finally {
        $plainToken = $null
    }
}

function Invoke-AgentPackTransactionalOperation {
    param(
        [Parameter(Mandatory)][scriptblock]$Operation,
        [Parameter(Mandatory)][scriptblock]$Rollback,
        [AllowEmptyString()][string]$BackupPath=''
    )
    $state = [pscustomobject]@{changesStarted=$false}
    try {
        return & $Operation $state
    }
    catch {
        $failure = $_
        $rollbackStatus = if ([bool]$state.changesStarted) { 'Failed' } else { 'NotRequired' }
        if ([bool]$state.changesStarted) {
            try { &$Rollback; $rollbackStatus='Completed' } catch { $rollbackStatus='Failed' }
        }
        $failure.Exception.Data['KIStackRollbackStatus']=$rollbackStatus
        $failure.Exception.Data['KIStackBackupPath']=$BackupPath
        throw $failure
    }
}

function Get-AgentPackDefinitions {
    param([Parameter(Mandatory)][string]$PackageRoot)
    $files = @(
        Join-Path $PackageRoot 'Definitions\ki-stack-it-technik.json'
        Join-Path $PackageRoot 'Definitions\ki-stack-allgemein.json'
    )
    return @($files | ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 30 })
}

function Get-AgentPackOfferedModels {
    param([string]$Endpoint,[Security.SecureString]$ApiToken)
    $response = Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path '/api/v1/models'
    return @($response.data)
}

function Get-AgentPackOpenAIConfig {
    param([string]$Endpoint,[Security.SecureString]$ApiToken)
    return Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path '/openai/config'
}

function Get-AgentPackLmStudioConnectionIndex {
    param([Parameter(Mandatory)][object]$Config)
    $matches = [Collections.Generic.List[int]]::new()
    for ($index = 0; $index -lt @($Config.OPENAI_API_BASE_URLS).Count; $index++) {
        $url = ([string]$Config.OPENAI_API_BASE_URLS[$index]).TrimEnd('/')
        if ($url -in @('http://127.0.0.1:1234/v1','http://localhost:1234/v1')) { $matches.Add($index) }
    }
    if ($matches.Count -ne 1) {
        throw "Genau eine LM-Studio-Verbindung ist erforderlich; gefunden: $($matches.Count)."
    }
    return $matches[0]
}

function Set-AgentPackChatModelAllowList {
    param(
        [string]$Endpoint,
        [Security.SecureString]$ApiToken,
        [Parameter(Mandatory)][string]$BaseModelId
    )
    $config = Get-AgentPackOpenAIConfig -Endpoint $Endpoint -ApiToken $ApiToken
    $index = Get-AgentPackLmStudioConnectionIndex -Config $config
    $configs = [ordered]@{}
    foreach ($property in $config.OPENAI_API_CONFIGS.PSObject.Properties) { $configs[$property.Name] = $property.Value }
    $key = [string]$index
    $connection = [ordered]@{}
    if ($configs.Contains($key) -and $null -ne $configs[$key]) {
        foreach ($property in $configs[$key].PSObject.Properties) { $connection[$property.Name] = $property.Value }
    }
    $connection['enable'] = $true
    $connection['model_ids'] = @($BaseModelId)
    $configs[$key] = $connection
    $body = [ordered]@{
        ENABLE_OPENAI_API = [bool]$config.ENABLE_OPENAI_API
        OPENAI_API_BASE_URLS = @($config.OPENAI_API_BASE_URLS)
        OPENAI_API_KEYS = @($config.OPENAI_API_KEYS)
        OPENAI_API_CONFIGS = $configs
    }
    $null = Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path '/openai/config/update' -Method POST -Body $body
    $readback = Get-AgentPackOpenAIConfig -Endpoint $Endpoint -ApiToken $ApiToken
    $actual = @($readback.OPENAI_API_CONFIGS.$key.model_ids)
    if (($actual -join '|') -cne $BaseModelId) {
        throw "OpenWebUI-Chatmodell-Allowlist-Readback fehlgeschlagen: $($actual -join ', ')."
    }
    return [pscustomobject]@{ connectionIndex=$index; modelIds=$actual }
}

function Resolve-AgentPackBaseModel {
    param([object[]]$OfferedModels,[AllowEmptyString()][string]$BaseModelId)
    $usable = @($OfferedModels | Where-Object {
        [string]$_.id -eq 'qwen3.6-27b-uncensored-heretic-v2-native-mtp-preserved'
    })
    $availableIds = @($usable | ForEach-Object { [string]$_.id })
    if (-not [string]::IsNullOrWhiteSpace($BaseModelId)) {
        $selected = @($usable | Where-Object { [string]$_.id -eq $BaseModelId })
        if ($selected.Count -ne 1) {
            throw "BaseModelId '$BaseModelId' ist kein eindeutig angebotenes verwendbares Basismodell. Verfügbar: $($availableIds -join ', ')"
        }
        return $selected[0]
    }
    if ($usable.Count -ne 1) {
        throw "BaseModelId ist erforderlich, weil $($usable.Count) verwendbare Basismodelle angeboten werden. Verfügbar: $($availableIds -join ', ')"
    }
    return $usable[0]
}

function Get-AgentPackRegisteredExtensionToolIds {
    param([string]$Endpoint,[Security.SecureString]$ApiToken)
    $contracts = @(
        [ordered]@{ id='ki_stack_generate_image'; canonical='ki-stack-generate-image' },
        [ordered]@{ id='ki_stack_generate_video'; canonical='ki-stack-generate-video' }
    )
    $registered = [Collections.Generic.List[string]]::new()
    foreach ($contract in $contracts) {
        try {
            $tool = Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path ('/api/v1/tools/id/' + $contract.id)
            if ([string]$tool.id -ne $contract.id -or
                [string]$tool.meta.manifest.managedBy -ne 'KI-STACK-OPENWEBUI-VISUAL-PACK' -or
                [string]$tool.meta.manifest.version -ne '2.0.5-rc2' -or
                [string]$tool.meta.manifest.canonical_id -ne $contract.canonical) {
                throw "Visual-Tool-Vertrag verletzt: $($contract.id)"
            }
            $registered.Add($contract.id)
        }
        catch {
            $failure = Get-AgentPackApiFailure -ErrorRecord $_
            if ($failure.statusCode -eq 404) { continue }
            throw
        }
    }
    return @($registered)
}

function New-AgentPackModelForm {
    param([Parameter(Mandatory)][object]$Definition,[Parameter(Mandatory)][string]$BaseModelId,[string[]]$ExtensionToolIds=@())
    return [ordered]@{
        id = [string]$Definition.id
        base_model_id = $BaseModelId
        name = [string]$Definition.displayName
        meta = [ordered]@{
            description = [string]$Definition.description
            capabilities = [ordered]@{ code_interpreter = [bool]$Definition.codeInterpreter }
            knowledge = @()
            toolIds = @($ExtensionToolIds)
            skillIds = @()
            functionIds = @()
            managedBy = 'KI-STACK-OPENWEBUI-AGENT-PACK'
            agentPackVersion = '1.8.7'
        }
        params = [ordered]@{
            system = [string]$Definition.systemPrompt
            function_calling = 'native'
        }
        access_grants = @()
        is_active = $true
    }
}

function Get-AgentPackManagedModel {
    param([string]$Endpoint,[Security.SecureString]$ApiToken,[string]$Id)
    try {
        $encoded = [Uri]::EscapeDataString($Id)
        return Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path "/api/v1/models/model?id=$encoded"
    }
    catch {
        $failure = Get-AgentPackApiFailure -ErrorRecord $_
        if ($failure.statusCode -eq 404) { return $null }
        throw
    }
}

function ConvertTo-AgentPackBackupForm {
    param([Parameter(Mandatory)][object]$Model)
    return [ordered]@{
        id = [string]$Model.id
        base_model_id = [string]$Model.base_model_id
        name = [string]$Model.name
        meta = $Model.meta
        params = $Model.params
        access_grants = @($Model.access_grants)
        is_active = [bool]$Model.is_active
    }
}

function Backup-OpenWebUIAgentPack {
    [CmdletBinding()]
    param([string]$PackageRoot,[string]$Endpoint,[Security.SecureString]$ApiToken,[string]$BackupDirectory)
    New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    $entries = foreach ($definition in Get-AgentPackDefinitions -PackageRoot $PackageRoot) {
        $current = Get-AgentPackManagedModel -Endpoint $Endpoint -ApiToken $ApiToken -Id ([string]$definition.id)
        [ordered]@{
            id = [string]$definition.id
            existed = ($null -ne $current)
            model = if ($null -ne $current) { ConvertTo-AgentPackBackupForm -Model $current } else { $null }
        }
    }
    $openAIConfig = Get-AgentPackOpenAIConfig -Endpoint $Endpoint -ApiToken $ApiToken
    $connectionIndex = Get-AgentPackLmStudioConnectionIndex -Config $openAIConfig
    $connectionKey = [string]$connectionIndex
    $priorConfig = $openAIConfig.OPENAI_API_CONFIGS.PSObject.Properties[$connectionKey]
    $backup = [ordered]@{
        schemaVersion='1.1'
        createdAtUtc=[DateTime]::UtcNow.ToString('o')
        entries=@($entries)
        chatModelFilter=[ordered]@{
            connectionIndex=$connectionIndex
            existed=($null -ne $priorConfig)
            config=if($null -ne $priorConfig){$priorConfig.Value}else{$null}
        }
    }
    $path = Join-Path $BackupDirectory 'managed-models.backup.json'
    $backup | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Install-OpenWebUIAgentPack {
    [CmdletBinding()]
    param([string]$PackageRoot,[string]$Endpoint,[Security.SecureString]$ApiToken,[string]$BaseModelId,[string]$BackupDirectory)
    $offered = Get-AgentPackOfferedModels -Endpoint $Endpoint -ApiToken $ApiToken
    $baseModel = Resolve-AgentPackBaseModel -OfferedModels $offered -BaseModelId $BaseModelId
    $extensionToolIds = @(Get-AgentPackRegisteredExtensionToolIds -Endpoint $Endpoint -ApiToken $ApiToken)
    $backupPath = Backup-OpenWebUIAgentPack -PackageRoot $PackageRoot -Endpoint $Endpoint -ApiToken $ApiToken -BackupDirectory $BackupDirectory
    Invoke-AgentPackTransactionalOperation -BackupPath $backupPath -Rollback {
        Restore-OpenWebUIAgentPack -Endpoint $Endpoint -ApiToken $ApiToken -BackupPath $backupPath
    } -Operation {
        param($transactionState)
        $actions = foreach ($definition in Get-AgentPackDefinitions -PackageRoot $PackageRoot) {
            $form = New-AgentPackModelForm -Definition $definition -BaseModelId ([string]$baseModel.id) -ExtensionToolIds $extensionToolIds
            $current = Get-AgentPackManagedModel -Endpoint $Endpoint -ApiToken $ApiToken -Id ([string]$definition.id)
            if ($null -eq $current) {
                $null = Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path '/api/v1/models/create' -Method POST -Body $form
                $transactionState.changesStarted = $true
                [pscustomobject]@{ id=$definition.id; action='created' }
            }
            else {
                $null = Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path '/api/v1/models/model/update' -Method POST -Body $form
                $transactionState.changesStarted = $true
                [pscustomobject]@{ id=$definition.id; action='updated' }
            }
        }
        $filter = Set-AgentPackChatModelAllowList -Endpoint $Endpoint -ApiToken $ApiToken -BaseModelId ([string]$baseModel.id)
        $transactionState.changesStarted = $true
        return [pscustomobject]@{ baseModelId=[string]$baseModel.id; backupPath=$backupPath; actions=@($actions); chatModelFilter=$filter;rollbackStatus='NotRequired' }
    }
}

function Test-AgentPackSafeValue {
    param([string]$Text)
    return $Text -notmatch '(?i)sk-[a-z0-9]{20,}|C:\\Users\\[^<%]|C:\\\\Users\\\\[^<%]'
}

function Test-OpenWebUIAgentPack {
    [CmdletBinding()]
    param([string]$PackageRoot,[string]$Endpoint,[Security.SecureString]$ApiToken,[string]$BaseModelId)
    $failures = [Collections.Generic.List[string]]::new()
    $extensionToolIds = @(Get-AgentPackRegisteredExtensionToolIds -Endpoint $Endpoint -ApiToken $ApiToken)
    foreach ($definition in Get-AgentPackDefinitions -PackageRoot $PackageRoot) {
        $model = Get-AgentPackManagedModel -Endpoint $Endpoint -ApiToken $ApiToken -Id ([string]$definition.id)
        if ($null -eq $model) { $failures.Add("Fehlt: $($definition.id)"); continue }
        if ([string]$model.name -ne [string]$definition.displayName) { $failures.Add("Anzeigename: $($definition.id)") }
        if ([string]$model.base_model_id -ne $BaseModelId) { $failures.Add("Basismodell: $($definition.id)") }
        if (([string]$model.params.system).Replace("`r`n","`n") -cne ([string]$definition.systemPrompt).Replace("`r`n","`n")) { $failures.Add("System-Prompt: $($definition.id)") }
        if ([string]$model.params.function_calling -ne 'native') { $failures.Add("Function Calling: $($definition.id)") }
        if ([bool]$model.meta.capabilities.code_interpreter -ne [bool]$definition.codeInterpreter) { $failures.Add("Code Interpreter: $($definition.id)") }
        if ((@($model.meta.toolIds) -join '|') -ne ($extensionToolIds -join '|') -or @($model.meta.knowledge).Count -ne 0 -or @($model.meta.skillIds).Count -ne 0 -or @($model.meta.functionIds).Count -ne 0) { $failures.Add("Unerwünschte Bindung: $($definition.id)") }
        if (-not (Test-AgentPackSafeValue -Text ($model | ConvertTo-Json -Depth 30 -Compress))) { $failures.Add("Secret oder persönlicher Pfad: $($definition.id)") }
    }
    $listed = Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path '/api/v1/models/list?page=1'
    foreach ($definition in Get-AgentPackDefinitions -PackageRoot $PackageRoot) {
        $duplicates = @($listed.items | Where-Object { [string]$_.id -eq [string]$definition.id })
        if ($duplicates.Count -ne 1) { $failures.Add("Duplikatanzahl $($definition.id): $($duplicates.Count)") }
    }
    $config = Get-AgentPackOpenAIConfig -Endpoint $Endpoint -ApiToken $ApiToken
    $connectionIndex = Get-AgentPackLmStudioConnectionIndex -Config $config
    $connectionProperty = $config.OPENAI_API_CONFIGS.PSObject.Properties[[string]$connectionIndex]
    $allowed = if ($null -ne $connectionProperty) { @($connectionProperty.Value.model_ids) } else { @() }
    if (($allowed -join '|') -cne $BaseModelId) { $failures.Add("Chatmodell-Allowlist: $($allowed -join ', ')") }
    if ($allowed -match '(?i)nomic|embed') { $failures.Add('Nomic als Chatmodell auswählbar') }
    return [pscustomobject]@{ passed=($failures.Count -eq 0); failures=@($failures) }
}

function Restore-OpenWebUIAgentPack {
    [CmdletBinding()]
    param([string]$Endpoint,[Security.SecureString]$ApiToken,[string]$BackupPath)
    $backup = Get-Content -LiteralPath $BackupPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 30
    foreach ($entry in $backup.entries) {
        $current = Get-AgentPackManagedModel -Endpoint $Endpoint -ApiToken $ApiToken -Id ([string]$entry.id)
        if ([bool]$entry.existed) {
            $methodPath = if ($null -eq $current) { '/api/v1/models/create' } else { '/api/v1/models/model/update' }
            $null = Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path $methodPath -Method POST -Body $entry.model
        }
        elseif ($null -ne $current) {
            $null = Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path '/api/v1/models/model/delete' -Method POST -Body @{ id=[string]$entry.id }
        }
    }
    if ($null -ne $backup.chatModelFilter) {
        $config = Get-AgentPackOpenAIConfig -Endpoint $Endpoint -ApiToken $ApiToken
        $configs = [ordered]@{}
        foreach ($property in $config.OPENAI_API_CONFIGS.PSObject.Properties) { $configs[$property.Name] = $property.Value }
        $key = [string]$backup.chatModelFilter.connectionIndex
        if ([bool]$backup.chatModelFilter.existed) { $configs[$key] = $backup.chatModelFilter.config }
        else { $configs.Remove($key) }
        $body = [ordered]@{
            ENABLE_OPENAI_API = [bool]$config.ENABLE_OPENAI_API
            OPENAI_API_BASE_URLS = @($config.OPENAI_API_BASE_URLS)
            OPENAI_API_KEYS = @($config.OPENAI_API_KEYS)
            OPENAI_API_CONFIGS = $configs
        }
        $null = Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path '/openai/config/update' -Method POST -Body $body
    }
}

Export-ModuleMember -Function Invoke-AgentPackApi,Get-AgentPackApiFailure,Invoke-AgentPackTransactionalOperation,Backup-OpenWebUIAgentPack,Install-OpenWebUIAgentPack,Test-OpenWebUIAgentPack,Restore-OpenWebUIAgentPack,Get-AgentPackOfferedModels,Resolve-AgentPackBaseModel,Get-AgentPackOpenAIConfig,Get-AgentPackLmStudioConnectionIndex,Set-AgentPackChatModelAllowList

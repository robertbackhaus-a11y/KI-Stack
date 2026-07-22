Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-AgentPackSecureString {
    param([Parameter(Mandatory)][Security.SecureString]$SecureString)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
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
        return Invoke-RestMethod @parameters
    }
    finally {
        $plainToken = $null
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

function Resolve-AgentPackBaseModel {
    param([object[]]$OfferedModels,[AllowEmptyString()][string]$BaseModelId)
    $usable = @($OfferedModels | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.id) -and
        [string]$_.id -ne 'arena-model' -and
        [string]$_.id -notmatch '(?i)embedding'
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
    try {
        $tool = Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path '/api/v1/tools/id/ki_stack_generate_image'
        if ([string]$tool.id -eq 'ki_stack_generate_image' -and
            [string]$tool.meta.manifest.managedBy -eq 'KI-STACK-OPENWEBUI-IMAGE-PACK' -and
            [string]$tool.meta.manifest.version -eq '1.9.0' -and
            [string]$tool.meta.manifest.canonical_id -eq 'ki-stack-generate-image') { return @('ki_stack_generate_image') }
        return @()
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 404) { return @() }
        throw
    }
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
            agentPackVersion = '1.8.3'
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
        if ($_.Exception.Response.StatusCode.value__ -eq 404) { return $null }
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
    $backup = [ordered]@{ schemaVersion='1.0'; createdAtUtc=[DateTime]::UtcNow.ToString('o'); entries=@($entries) }
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
    $actions = foreach ($definition in Get-AgentPackDefinitions -PackageRoot $PackageRoot) {
        $form = New-AgentPackModelForm -Definition $definition -BaseModelId ([string]$baseModel.id) -ExtensionToolIds $extensionToolIds
        $current = Get-AgentPackManagedModel -Endpoint $Endpoint -ApiToken $ApiToken -Id ([string]$definition.id)
        if ($null -eq $current) {
            $null = Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path '/api/v1/models/create' -Method POST -Body $form
            [pscustomobject]@{ id=$definition.id; action='created' }
        }
        else {
            $null = Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path '/api/v1/models/model/update' -Method POST -Body $form
            [pscustomobject]@{ id=$definition.id; action='updated' }
        }
    }
    return [pscustomobject]@{ baseModelId=[string]$baseModel.id; backupPath=$backupPath; actions=@($actions) }
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
}

Export-ModuleMember -Function Invoke-AgentPackApi,Backup-OpenWebUIAgentPack,Install-OpenWebUIAgentPack,Test-OpenWebUIAgentPack,Restore-OpenWebUIAgentPack,Get-AgentPackOfferedModels,Resolve-AgentPackBaseModel

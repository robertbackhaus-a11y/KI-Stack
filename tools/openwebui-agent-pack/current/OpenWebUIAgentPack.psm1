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
        Join-Path $PackageRoot 'Definitions\ki-stack-research.json'
    )
    return @($files | ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 30 })
}

function Get-AgentPackRAGKnowledgeReference {
    # Resolves the real OpenWebUI Knowledge collection id for RAG's "global" scope, by
    # name, so a Research-Agent-style profile can bind local KI-Stack knowledge without
    # ever hardcoding a real collection id (that id is only assigned once RAG's own
    # Execute has actually run -- see tools/rag/current/KIStackRAG.psm1's
    # Get-RAGKnowledgeName/Get-RAGKnowledge). The expected collection NAME is read
    # directly from RAG's own deployed rag.config.json (the single source of truth for
    # that name) rather than duplicated as a second hardcoded literal here. If RAG was
    # never executed on this target (no such collection exists yet), this returns $null
    # and the caller leaves the profile's knowledge binding empty -- the same graceful,
    # conditional-binding pattern Get-AgentPackRegisteredExtensionToolIds already uses
    # for the optional Visual Pack tools, never a hard failure.
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][Security.SecureString]$ApiToken,
        [string]$RAGConfigPath = 'C:\KI-Stack\modules\rag\Config\rag.config.json'
    )
    if (-not (Test-Path -LiteralPath $RAGConfigPath -PathType Leaf)) { return $null }
    $ragConfig = Get-Content -LiteralPath $RAGConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 30
    $knowledgeName = [string]$ragConfig.knowledgeName
    if ([string]::IsNullOrWhiteSpace($knowledgeName)) { return $null }
    try {
        $response = Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path '/api/v1/knowledge/'
    }
    catch { return $null }
    $itemsProperty = $response.PSObject.Properties['items']
    $items = @(if ($null -ne $itemsProperty) { $itemsProperty.Value } elseif ($response -is [array]) { $response } else { @($response) })
    # An "items" property present but holding a JSON null (rather than an empty array)
    # yields a one-element array containing $null here; under StrictMode, `$_.name` on
    # that $null element throws PropertyNotFoundException instead of comparing false, so
    # null entries are filtered out before the name comparison rather than relied upon to
    # compare safely.
    $matches = @($items | Where-Object { $null -ne $_ } | Where-Object { [string]$_.name -eq $knowledgeName })
    if ($matches.Count -ne 1) { return $null }
    # A model's meta.knowledge entry must be the attachment shape OpenWebUI's own
    # get_attached_knowledge()/get_builtin_tools() require -- {type,id,name}, keyed on
    # (type,id) -- not a bare id string; a bare string is silently ignored (source-
    # confirmed against utils/tools.py get_attached_knowledge and models/models.py
    # strip_extracted_content_from_model_knowledge, both of which only accept dict items).
    return [pscustomobject]@{ type='collection'; id=[string]$matches[0].id; name=[string]$matches[0].name }
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
                [string]$tool.meta.manifest.version -ne '2.0.5' -or
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
    # ExtensionToolIds (Visual Pack image/video tools) are bound to every definition by
    # default, matching the pre-existing ki-stack-it-technik/ki-stack-allgemein contract
    # exactly (backward compatible). A definition can opt out via "extensionTools": false
    # (used by ki-stack-research, whose tool contract deliberately excludes image/video
    # generation). KnowledgeAttachments/capabilities/builtinTools are additive,
    # definition-driven overrides on top of the existing fixed shape -- a definition that
    # does not declare "capabilities"/"builtinTools" produces byte-identical output to
    # before this change. Each KnowledgeAttachments entry must already be the
    # {type,id,name} shape OpenWebUI's own knowledge-attachment code expects (see
    # Get-AgentPackRAGKnowledgeReference) -- a bare id string is silently ignored by
    # OpenWebUI itself, not merely a cosmetic mismatch.
    param(
        [Parameter(Mandatory)][object]$Definition,
        [Parameter(Mandatory)][string]$BaseModelId,
        [string[]]$ExtensionToolIds=@(),
        [object[]]$KnowledgeAttachments=@()
    )
    $allowExtensionTools = $true
    $extensionToolsProperty = $Definition.PSObject.Properties['extensionTools']
    if ($null -ne $extensionToolsProperty -and [bool]$extensionToolsProperty.Value -eq $false) { $allowExtensionTools = $false }

    # MCP-Server-Bindung (2.15 Phase 7): bound to every definition by default, exactly mirroring
    # ExtensionToolIds's own opt-out shape -- a definition declares "mcpBinding": false to
    # exclude it (ki-stack-research does, alongside its own "extensionTools": false, matching
    # its deliberate deny-listed capabilities.terminal:false security posture). This is the
    # KI-Stack-owned, already-registered mcp-runtime tool-server id (Contracts/COMPONENTS.json
    # mcp-runtime -> Config/mcp-runtime.config.json's own fixed toolServerId), never a
    # per-install-discovered value -- hardcoded here the same way managedBy/agentPackVersion
    # already are two lines below. Never treated as an "Extension Tool" (a separate concept,
    # Visual Pack's own image/video tools) -- its own dedicated flag, its own dedicated list.
    $allowMcpBinding = $true
    $mcpBindingProperty = $Definition.PSObject.Properties['mcpBinding']
    if ($null -ne $mcpBindingProperty -and [bool]$mcpBindingProperty.Value -eq $false) { $allowMcpBinding = $false }
    $mcpServerToolIds = if ($allowMcpBinding) { @('server:mcp:ki-stack-mcp-runtime') } else { @() }

    $capabilities = [ordered]@{ code_interpreter = [bool]$Definition.codeInterpreter }
    $capabilitiesProperty = $Definition.PSObject.Properties['capabilities']
    if ($null -ne $capabilitiesProperty -and $null -ne $capabilitiesProperty.Value) {
        foreach ($property in $capabilitiesProperty.Value.PSObject.Properties) { $capabilities[$property.Name] = $property.Value }
    }

    $meta = [ordered]@{
        description = [string]$Definition.description
        capabilities = $capabilities
        knowledge = @($KnowledgeAttachments)
        toolIds = @(@(if ($allowExtensionTools) { $ExtensionToolIds } else { @() }) + $mcpServerToolIds)
        skillIds = @()
        functionIds = @()
        managedBy = 'KI-STACK-OPENWEBUI-AGENT-PACK'
        agentPackVersion = '1.9.0'
    }
    $builtinToolsProperty = $Definition.PSObject.Properties['builtinTools']
    if ($null -ne $builtinToolsProperty -and $null -ne $builtinToolsProperty.Value) {
        $builtinTools = [ordered]@{}
        foreach ($property in $builtinToolsProperty.Value.PSObject.Properties) { $builtinTools[$property.Name] = $property.Value }
        $meta['builtinTools'] = $builtinTools
    }
    return [ordered]@{
        id = [string]$Definition.id
        base_model_id = $BaseModelId
        name = [string]$Definition.displayName
        meta = $meta
        params = [ordered]@{
            system = [string]$Definition.systemPrompt
            function_calling = 'native'
        }
        access_grants = @()
        is_active = $true
    }
}

function Merge-AgentPackObjectValueByKey {
    # Shallow, single-level, key-scoped merge for a JSON-object-shaped meta property
    # (meta.capabilities / meta.builtinTools): every key present on the live value is kept
    # unless the package's own managed value also declares that same key, in which case the
    # package's value wins -- deliberately, not accidentally: these two dict-valued meta
    # properties are where a live admin has been observed (real webui.db inspection,
    # ki-stack-it-technik/ki-stack-allgemein) adding extra keys via the OpenWebUI UI that the
    # Agent Pack's own definition never declared (e.g. an 11-key capabilities set, a
    # builtinTools.knowledge=false toggle). Those foreign keys are not something the package
    # has an opinion about and must survive a reconcile untouched. A key the definition DOES
    # declare is always package-owned and is reasserted on every reconcile even if live drift
    # changed it -- the same "managed attribute reverts on apply" semantics as Terraform.
    param([AllowNull()][object]$LiveValue,[Parameter(Mandatory)][System.Collections.IDictionary]$ManagedValue)
    $result = [ordered]@{}
    if ($LiveValue -is [Management.Automation.PSCustomObject]) {
        foreach ($property in $LiveValue.PSObject.Properties) { $result[$property.Name] = $property.Value }
    }
    elseif ($LiveValue -is [System.Collections.IDictionary]) {
        foreach ($key in $LiveValue.Keys) { $result[$key] = $LiveValue[$key] }
    }
    foreach ($key in $ManagedValue.Keys) { $result[$key] = $ManagedValue[$key] }
    return $result
}

function Resolve-AgentPackReconcileForm {
    # Applies the Agent-Pack field-ownership contract (see README.md "Agent-Pack-
    # Feldvertrag") before any create/update call actually goes out. Root cause this fixes:
    # OpenWebUI's real update_model_by_id() does not merge `meta` -- it replaces the object
    # wholesale except for the two fields it special-cases itself (profile_image_url,
    # base_model_id, and only when absent from the request). Sending New-AgentPackModelForm's
    # output directly on Update, as the module did before this fix, would silently destroy
    # any live-only state a real admin added outside the package process. This function
    # builds the actual outgoing form by starting from a full clone of the CURRENT live model
    # (nothing unknown is ever dropped) and then forcing only the fields the package
    # genuinely manages -- never a blind/deep merge, and never a full replace either. On
    # first create (CurrentModel is $null) there is no live state yet, so the generated form
    # is used as-is except for the same key-scoped merge logic applied against an empty base
    # (a no-op in that case).
    #
    # Ownership per field (Managed = package always wins; Merge = package owns only the keys
    # its own definition declares, foreign keys survive; Preserve = package never touches it):
    #   id, base_model_id, name                 -> Managed  (package identity/config)
    #   params.system, params.function_calling  -> Managed  (the prompt/behavior contract is
    #                                                         exactly what this package exists
    #                                                         to define and keep deterministic)
    #   meta.description, meta.toolIds,
    #   meta.skillIds, meta.functionIds,
    #   meta.managedBy, meta.agentPackVersion   -> Managed  (package-owned bookkeeping/lists)
    #   meta.capabilities, meta.builtinTools    -> Merge    (key-scoped, see
    #                                                         Merge-AgentPackObjectValueByKey)
    #   meta.knowledge                          -> Managed only for a definition that declares
    #                                               a knowledgeSource contract (currently only
    #                                               ki-stack-research); Preserve otherwise --
    #                                               a definition with no knowledge contract has
    #                                               no opinion on knowledge a live admin may
    #                                               have attached manually.
    #   meta.profile_image_url                  -> Preserve (never referenced here at all;
    #                                                         carried forward as part of the
    #                                                         live-meta clone, or simply absent
    #                                                         on first create)
    #   access_grants                           -> Preserve (visibility/sharing is out of the
    #                                                         Agent Pack's contract scope;
    #                                                         package default `[]` only applies
    #                                                         to a brand-new model)
    #   is_active                               -> Managed  (the package's install contract is
    #                                                         "this managed model exists and is
    #                                                         enabled")
    #   any other, unknown meta key             -> Preserve (survives via the live-meta clone;
    #                                                         this is what makes the fix work
    #                                                         for a foreign key the package has
    #                                                         never even heard of)
    param(
        [Parameter(Mandatory)][object]$GeneratedForm,
        [AllowNull()][object]$CurrentModel,
        [Parameter(Mandatory)][bool]$RequiresKnowledge
    )
    $liveMeta = if ($null -ne $CurrentModel) { $CurrentModel.meta } else { $null }
    $mergedMeta = [ordered]@{}
    if ($liveMeta -is [Management.Automation.PSCustomObject]) {
        foreach ($property in $liveMeta.PSObject.Properties) { $mergedMeta[$property.Name] = $property.Value }
    }
    $mergedMeta['description'] = $GeneratedForm.meta.description
    $mergedMeta['capabilities'] = Merge-AgentPackObjectValueByKey -LiveValue $mergedMeta['capabilities'] -ManagedValue $GeneratedForm.meta.capabilities
    $mergedMeta['toolIds'] = $GeneratedForm.meta.toolIds
    $mergedMeta['skillIds'] = $GeneratedForm.meta.skillIds
    $mergedMeta['functionIds'] = $GeneratedForm.meta.functionIds
    $mergedMeta['managedBy'] = $GeneratedForm.meta.managedBy
    $mergedMeta['agentPackVersion'] = $GeneratedForm.meta.agentPackVersion
    if ($GeneratedForm.meta.Contains('builtinTools')) {
        $mergedMeta['builtinTools'] = Merge-AgentPackObjectValueByKey -LiveValue $mergedMeta['builtinTools'] -ManagedValue $GeneratedForm.meta.builtinTools
    }
    # meta.knowledge: package-owned only for a definition that actually declares a knowledge
    # contract (always Replace there). For every other definition, an existing live model's
    # knowledge (a manually-attached collection, or nothing) survives completely untouched --
    # but a brand-new model with no knowledge contract still starts from the package's clean
    # default of zero knowledge, matching the pre-merge-fix create behavior, rather than
    # simply omitting the key.
    if ($RequiresKnowledge) { $mergedMeta['knowledge'] = $GeneratedForm.meta.knowledge }
    elseif ($null -eq $CurrentModel) { $mergedMeta['knowledge'] = @() }
    # meta.profile_image_url is intentionally never assigned here -- it is either carried
    # forward verbatim by the live-meta clone above, or (first create) simply absent.

    # The whole if/else must be wrapped in the outer @() -- wrapping only a branch's own
    # value (e.g. "else { @($GeneratedForm.access_grants) }") still collapses to $null when
    # that branch's array happens to be empty, because the assignment unwraps an if/else
    # expression's single-branch pipeline output before the inner @() ever applies.
    $accessGrants = @(if ($null -ne $CurrentModel) { $CurrentModel.access_grants } else { $GeneratedForm.access_grants })

    return [ordered]@{
        id = $GeneratedForm.id
        base_model_id = $GeneratedForm.base_model_id
        name = $GeneratedForm.name
        meta = $mergedMeta
        params = $GeneratedForm.params
        access_grants = $accessGrants
        is_active = $GeneratedForm.is_active
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
        $ragKnowledgeAttachment = $null
        $ragKnowledgeResolved = $false
        $actions = foreach ($definition in Get-AgentPackDefinitions -PackageRoot $PackageRoot) {
            $knowledgeAttachments = @()
            $requiresKnowledge = $false
            $knowledgeSourceProperty = $definition.PSObject.Properties['knowledgeSource']
            if ($null -ne $knowledgeSourceProperty -and [string]$knowledgeSourceProperty.Value -eq 'rag-global') {
                $requiresKnowledge = $true
                if (-not $ragKnowledgeResolved) {
                    $ragKnowledgeAttachment = Get-AgentPackRAGKnowledgeReference -Endpoint $Endpoint -ApiToken $ApiToken
                    $ragKnowledgeResolved = $true
                }
                if ($null -ne $ragKnowledgeAttachment) { $knowledgeAttachments = @($ragKnowledgeAttachment) }
            }
            # A definition that declares knowledgeSource is not optionally-knowledge-bound
            # the way the Visual Pack's extension tools are -- a "research" profile with
            # silently empty knowledge would misrepresent its own real capability. If the
            # expected RAG collection cannot be resolved, this one definition is skipped
            # entirely (no create, no update -- whatever state it was already in on the
            # target is left untouched) while every other definition still completes
            # normally; never a dummy/placeholder knowledge entry.
            if ($requiresKnowledge -and @($knowledgeAttachments).Count -eq 0) {
                [pscustomobject]@{ id=$definition.id; action='skipped'; reason='RAG-Knowledge-Collection nicht gefunden -- Research-Agent wird nicht ohne lokales Wissen angelegt oder aktualisiert.'; knowledgeBound=$false }
                continue
            }
            $form = New-AgentPackModelForm -Definition $definition -BaseModelId ([string]$baseModel.id) -ExtensionToolIds $extensionToolIds -KnowledgeAttachments $knowledgeAttachments
            $current = Get-AgentPackManagedModel -Endpoint $Endpoint -ApiToken $ApiToken -Id ([string]$definition.id)
            # Never send $form directly on Update: OpenWebUI replaces meta wholesale, so the
            # actual outgoing form must be the ownership-contract merge against the live
            # model (see Resolve-AgentPackReconcileForm) -- this is what preserves live-only
            # admin customization on already-managed profiles instead of silently wiping it.
            $reconcileForm = Resolve-AgentPackReconcileForm -GeneratedForm $form -CurrentModel $current -RequiresKnowledge $requiresKnowledge
            if ($null -eq $current) {
                $null = Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path '/api/v1/models/create' -Method POST -Body $reconcileForm
                $transactionState.changesStarted = $true
                [pscustomobject]@{ id=$definition.id; action='created'; knowledgeBound=(@($knowledgeAttachments).Count -gt 0) }
            }
            else {
                $null = Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path '/api/v1/models/model/update' -Method POST -Body $reconcileForm
                $transactionState.changesStarted = $true
                [pscustomobject]@{ id=$definition.id; action='updated'; knowledgeBound=(@($knowledgeAttachments).Count -gt 0) }
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
    $ragKnowledgeAttachment = $null
    $ragKnowledgeResolved = $false
    $skippedIds = [Collections.Generic.List[string]]::new()
    foreach ($definition in Get-AgentPackDefinitions -PackageRoot $PackageRoot) {
        $knowledgeSourceProperty = $definition.PSObject.Properties['knowledgeSource']
        $requiresKnowledge = ($null -ne $knowledgeSourceProperty -and [string]$knowledgeSourceProperty.Value -eq 'rag-global')
        if ($requiresKnowledge -and -not $ragKnowledgeResolved) {
            $ragKnowledgeAttachment = Get-AgentPackRAGKnowledgeReference -Endpoint $Endpoint -ApiToken $ApiToken
            $ragKnowledgeResolved = $true
        }
        $model = Get-AgentPackManagedModel -Endpoint $Endpoint -ApiToken $ApiToken -Id ([string]$definition.id)
        if ($null -eq $model) {
            # A definition requiring RAG knowledge that was never provisioned because the
            # expected collection does not exist yet is the correct, controlled skip state
            # (see Install-OpenWebUIAgentPack) -- not a readback failure. Any other missing
            # definition is a genuine failure.
            if ($requiresKnowledge -and $null -eq $ragKnowledgeAttachment) { $skippedIds.Add([string]$definition.id); continue }
            $failures.Add("Fehlt: $($definition.id)"); continue
        }
        if ([string]$model.name -ne [string]$definition.displayName) { $failures.Add("Anzeigename: $($definition.id)") }
        if ([string]$model.base_model_id -ne $BaseModelId) { $failures.Add("Basismodell: $($definition.id)") }
        if (([string]$model.params.system).Replace("`r`n","`n") -cne ([string]$definition.systemPrompt).Replace("`r`n","`n")) { $failures.Add("System-Prompt: $($definition.id)") }
        if ([string]$model.params.function_calling -ne 'native') { $failures.Add("Function Calling: $($definition.id)") }
        if ([bool]$model.meta.capabilities.code_interpreter -ne [bool]$definition.codeInterpreter) { $failures.Add("Code Interpreter: $($definition.id)") }

        $extensionToolsProperty = $definition.PSObject.Properties['extensionTools']
        $expectedExtensionToolIds = if ($null -ne $extensionToolsProperty -and [bool]$extensionToolsProperty.Value -eq $false) { @() } else { $extensionToolIds }
        $mcpBindingProperty = $definition.PSObject.Properties['mcpBinding']
        $expectedMcpToolIds = if ($null -ne $mcpBindingProperty -and [bool]$mcpBindingProperty.Value -eq $false) { @() } else { @('server:mcp:ki-stack-mcp-runtime') }
        $expectedToolIds = @($expectedExtensionToolIds) + @($expectedMcpToolIds)
        if ((@($model.meta.toolIds) -join '|') -ne ($expectedToolIds -join '|')) { $failures.Add("Unerwünschte Tool-Bindung: $($definition.id)") }
        if (@($model.meta.skillIds).Count -ne 0 -or @($model.meta.functionIds).Count -ne 0) { $failures.Add("Unerwünschte Skill-/Function-Bindung: $($definition.id)") }

        if ($requiresKnowledge) {
            if ($null -ne $ragKnowledgeAttachment) {
                # The ground truth is currently resolvable -- assert the exact expected
                # binding (also catches a stale/foreign knowledge id left over from before).
                $expectedKnowledgeIds = @([string]$ragKnowledgeAttachment.id)
                if ((@($model.meta.knowledge | ForEach-Object { [string]$_.id }) -join '|') -ne ($expectedKnowledgeIds -join '|')) { $failures.Add("Unerwünschte Knowledge-Bindung: $($definition.id)") }
            }
            # else: the model already exists (created while the collection was still
            # resolvable) but the collection cannot be resolved right now -- there is no
            # trustworthy ground truth to assert against this run, so the existing
            # knowledge binding is left unexamined rather than flagged as wrong.
        }
        # 2.17 Phase 1 fix: a definition with no knowledgeSource contract has meta.knowledge
        # under Preserve ownership per Resolve-AgentPackReconcileForm (see that function's own
        # field-ownership table) -- exactly like meta.capabilities/meta.builtinTools foreign
        # keys, a live-only knowledge attachment a real admin added outside the package
        # process is not something this package has an opinion about and must not fail
        # validation. Previously this `elseif` asserted the opposite (empty required),
        # contradicting reconcile's own documented contract and failing for real against
        # production the moment any such profile carried live-attached knowledge. No
        # assertion is made here at all now -- Preserve means no opinion, not "must be empty".

        $builtinToolsProperty = $definition.PSObject.Properties['builtinTools']
        if ($null -ne $builtinToolsProperty -and $null -ne $builtinToolsProperty.Value) {
            foreach ($property in $builtinToolsProperty.Value.PSObject.Properties) {
                $actualValue = $model.meta.builtinTools.($property.Name)
                if ([bool]$actualValue -ne [bool]$property.Value) { $failures.Add("builtinTools.$($property.Name): $($definition.id)") }
            }
        }
        if (-not (Test-AgentPackSafeValue -Text ($model | ConvertTo-Json -Depth 30 -Compress))) { $failures.Add("Secret oder persönlicher Pfad: $($definition.id)") }
    }
    $listed = Invoke-AgentPackApi -Endpoint $Endpoint -ApiToken $ApiToken -Path '/api/v1/models/list?page=1'
    foreach ($definition in Get-AgentPackDefinitions -PackageRoot $PackageRoot) {
        $expectedCount = if ($skippedIds.Contains([string]$definition.id)) { 0 } else { 1 }
        $duplicates = @($listed.items | Where-Object { [string]$_.id -eq [string]$definition.id })
        if ($duplicates.Count -ne $expectedCount) { $failures.Add("Duplikatanzahl $($definition.id): $($duplicates.Count)") }
    }
    $config = Get-AgentPackOpenAIConfig -Endpoint $Endpoint -ApiToken $ApiToken
    $connectionIndex = Get-AgentPackLmStudioConnectionIndex -Config $config
    $connectionProperty = $config.OPENAI_API_CONFIGS.PSObject.Properties[[string]$connectionIndex]
    $allowed = if ($null -ne $connectionProperty) { @($connectionProperty.Value.model_ids) } else { @() }
    if (($allowed -join '|') -cne $BaseModelId) { $failures.Add("Chatmodell-Allowlist: $($allowed -join ', ')") }
    if ($allowed -match '(?i)nomic|embed') { $failures.Add('Nomic als Chatmodell auswählbar') }
    return [pscustomobject]@{ passed=($failures.Count -eq 0); failures=@($failures); skipped=@($skippedIds) }
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

Export-ModuleMember -Function Invoke-AgentPackApi,Get-AgentPackApiFailure,Invoke-AgentPackTransactionalOperation,Backup-OpenWebUIAgentPack,Install-OpenWebUIAgentPack,Test-OpenWebUIAgentPack,Restore-OpenWebUIAgentPack,Get-AgentPackOfferedModels,Resolve-AgentPackBaseModel,Get-AgentPackOpenAIConfig,Get-AgentPackLmStudioConnectionIndex,Set-AgentPackChatModelAllowList,Get-AgentPackDefinitions,Get-AgentPackRAGKnowledgeReference,New-AgentPackModelForm,Get-AgentPackRegisteredExtensionToolIds,Get-AgentPackManagedModel,Merge-AgentPackObjectValueByKey,Resolve-AgentPackReconcileForm

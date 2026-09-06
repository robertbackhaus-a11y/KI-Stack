Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-BallisticsSecureString {
    param([Parameter(Mandatory)][Security.SecureString]$SecureString)
    $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)} finally {[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
}

function Invoke-BallisticsApi {
    param([string]$Endpoint,[Security.SecureString]$ApiToken,[string]$Path,[ValidateSet('GET','POST','DELETE')][string]$Method='GET',[AllowNull()][object]$Body=$null,[int]$TimeoutSec=120)
    $plain=ConvertFrom-BallisticsSecureString $ApiToken
    try {$p=@{Uri=$Endpoint.TrimEnd('/')+$Path;Method=$Method;Headers=@{Authorization="Bearer $plain"};TimeoutSec=$TimeoutSec};if($null-ne$Body){$p.ContentType='application/json; charset=utf-8';$p.Body=$Body|ConvertTo-Json -Depth 50 -Compress};Invoke-RestMethod @p} finally {$plain=$null}
}

function Get-BallisticsTool { param($Endpoint,$ApiToken) try {Invoke-BallisticsApi $Endpoint $ApiToken '/api/v1/tools/id/ki_stack_ballistics_calculator'} catch {if($_.Exception.Response.StatusCode.value__-eq404){return $null};throw} }
function Get-BallisticsModel { param($Endpoint,$ApiToken,$Id) try {Invoke-BallisticsApi $Endpoint $ApiToken ("/api/v1/models/model?id="+[Uri]::EscapeDataString($Id))} catch {if($_.Exception.Response.StatusCode.value__-eq404){return $null};throw} }
function Test-BallisticsToolOwned {param([object]$Tool) if($null-eq$Tool){return $false};$manifest=$Tool.meta.manifest;$managed=if($manifest.psobject.Properties.Name-contains'managed_by'){[string]$manifest.managed_by}else{''};return ($managed-eq'KI-STACK-OPENWEBUI-BALLISTICS-PACK'-or([string]$Tool.name-eq'KI-Stack Ballistikrechner'-and[string]$manifest.author-eq'KI-Stack'-and[string]$manifest.version-eq'1.0.0'-and[string]$Tool.content-match'KI-STACK-OPENWEBUI-BALLISTICS-PACK'))}

function ConvertTo-BallisticsModelForm {
    param([object]$Model)
    [ordered]@{id=[string]$Model.id;base_model_id=[string]$Model.base_model_id;name=[string]$Model.name;meta=$Model.meta;params=$Model.params;access_grants=@($Model.access_grants);is_active=[bool]$Model.is_active}
}

function New-BallisticsToolForm {
    param([string]$PackageRoot)
    [ordered]@{id='ki_stack_ballistics_calculator';name='KI-Stack Ballistikrechner';content=Get-Content (Join-Path $PackageRoot 'Tool/BallisticsCalculator.py') -Raw -Encoding UTF8;meta=[ordered]@{description='Lokaler Rechner für externe Ballistik, DOPE und Schießstandauswertung.';manifest=[ordered]@{managedBy='KI-STACK-OPENWEBUI-BALLISTICS-PACK';version='1.0.0';canonical_id='ki-stack-ballistics-calculator';solver='pyballistic 2.2.0';engine='RK4IntegrationEngine'};has_user_valves=$false};access_grants=@()}
}

function Get-BallisticsMcpToolIds {
    # MCP-Server-Bindung (2.16 Phase 3A): mirrors OpenWebUIAgentPack.psm1's own established
    # "mcpBinding" opt-out convention exactly (2.15 Phase 7) -- bound by default, a definition
    # declares "mcpBinding": false to exclude it. ki-stack-18bravo.json declares no such
    # property today, so this defaults to enabled, matching its real, already-registered live
    # state. Never treated as part of the ballistics-specific toolIds -- its own dedicated,
    # always-appended-last entry, exactly like Agent-Pack's own $mcpServerToolIds.
    param([object]$Definition)
    $allowMcpBinding = $true
    $mcpBindingProperty = $Definition.PSObject.Properties['mcpBinding']
    if ($null -ne $mcpBindingProperty -and [bool]$mcpBindingProperty.Value -eq $false) { $allowMcpBinding = $false }
    if ($allowMcpBinding) { @('server:mcp:ki-stack-mcp-runtime') } else { @() }
}

function New-BallisticsModelForm {
    param([string]$PackageRoot,[string]$BaseModelId)
    $d=Get-Content (Join-Path $PackageRoot 'Definitions/ki-stack-18bravo.json') -Raw|ConvertFrom-Json -Depth 30
    $mcpToolIds=@(Get-BallisticsMcpToolIds $d)
    [ordered]@{id=[string]$d.id;base_model_id=$BaseModelId;name=[string]$d.displayName;meta=[ordered]@{description=[string]$d.description;capabilities=[ordered]@{};knowledge=@();toolIds=@(@('ki_stack_ballistics_calculator')+$mcpToolIds);skillIds=@();functionIds=@();managedBy='KI-STACK-OPENWEBUI-BALLISTICS-PACK';ballisticsPackVersion='1.0.0'};params=[ordered]@{system=[string]$d.systemPrompt;function_calling='native'};access_grants=@();is_active=$true}
}

function Resolve-BallisticsBaseModel {
    param($Endpoint,$ApiToken,[string]$BaseModelId)
    $models=@((Invoke-BallisticsApi $Endpoint $ApiToken '/api/v1/models').data|Where-Object{$_.id-and$_.id-ne'arena-model'-and$_.id-notmatch'(?i)embedding'})
    if($BaseModelId){$match=@($models|Where-Object id -eq $BaseModelId);if($match.Count-ne1){throw"Basismodell nicht eindeutig verfügbar: $BaseModelId"};return [string]$match[0].id}
    if($models.Count-ne1){throw"BaseModelId erforderlich; angebotene Modelle: $(@($models.id)-join', ')"};[string]$models[0].id
}

function Test-BallisticsPayloads {
    param([string]$PackageRoot)
    $contract=Get-Content (Join-Path $PackageRoot 'Contracts/PAYLOADS.json') -Raw|ConvertFrom-Json
    $fail=@();foreach($p in $contract.payloads){$path=Join-Path $PackageRoot ('Payload/'+[string]$p.name);if(-not(Test-Path $path)){$fail+="Fehlt: $($p.name)";continue};if((Get-Item $path).Length-ne[long]$p.size){$fail+="Größe: $($p.name)"};if((Get-FileHash $path -Algorithm SHA256).Hash-ne[string]$p.sha256){$fail+="SHA256: $($p.name)"}}
    [pscustomobject]@{passed=($fail.Count-eq0);failures=$fail}
}

function Backup-OpenWebUIBallisticsPack {
    param($Endpoint,$ApiToken,[string]$BackupDirectory,[string]$PythonPath)
    New-Item -ItemType Directory -Path $BackupDirectory -Force|Out-Null
    $tool=Get-BallisticsTool $Endpoint $ApiToken;$model=Get-BallisticsModel $Endpoint $ApiToken 'ki-stack-18bravo'
    $general=@('ki-stack-allgemein','ki-stack-it-technik')|ForEach-Object{$m=Get-BallisticsModel $Endpoint $ApiToken $_;if($m){[ordered]@{id=$_.ToString();sha256=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($m|ConvertTo-Json -Depth 50 -Compress))))).ToLowerInvariant()}}}
    $installed=@{};foreach($name in @('pyballistic','Deprecated','wrapt')){$out=&$PythonPath -m pip show $name 2>$null;$version=@($out|Where-Object{$_-like'Version:*'})-replace'^Version:\s*','';$installed[$name]=if($version){$version[0]}else{$null}}
    $backup=[ordered]@{schemaVersion='1.0';createdAtUtc=[DateTime]::UtcNow.ToString('o');toolExisted=($null-ne$tool);tool=if($tool){[ordered]@{id=$tool.id;name=$tool.name;content=$tool.content;meta=$tool.meta;access_grants=@($tool.access_grants)}}else{$null};modelExisted=($null-ne$model);model=if($model){ConvertTo-BallisticsModelForm $model}else{$null};protectedModelHashes=@($general);pythonPackages=$installed;containsSecrets=$false}
    $path=Join-Path $BackupDirectory 'ballistics-pack.backup.json';$backup|ConvertTo-Json -Depth 50|Set-Content $path -Encoding UTF8;$path
}

function Install-BallisticsPythonRuntime {
    param([string]$PackageRoot,[string]$PythonPath)
    $payload=Test-BallisticsPayloads $PackageRoot;if(-not$payload.passed){throw($payload.failures-join'; ')}
    $wheels=@('wrapt-1.17.3-cp312-cp312-win_amd64.whl','Deprecated-1.2.18-py2.py3-none-any.whl','pyballistic-2.2.0-py3-none-any.whl')|ForEach-Object{Join-Path $PackageRoot ('Payload/'+$_)}
    &$PythonPath -m pip install --no-deps --disable-pip-version-check @wheels|Out-Null;if($LASTEXITCODE-ne0){throw'Installation des gepinnten Solver-Payloads fehlgeschlagen.'}
    $probe=&$PythonPath -c "import pyballistic; assert pyballistic.__version__=='2.2.0'; print(pyballistic.__version__)";if($LASTEXITCODE-ne0-or$probe.Trim()-ne'2.2.0'){throw'Solver-Readback fehlgeschlagen.'}
}

function Install-OpenWebUIBallisticsPack {
    param([string]$PackageRoot,[string]$Endpoint,[Security.SecureString]$ApiToken,[string]$BaseModelId,[string]$BackupDirectory,[string]$TargetRoot='C:\KI-Stack')
    $config=Get-Content (Join-Path $PackageRoot 'Config/ballistics-pack.config.json') -Raw|ConvertFrom-Json
    $python=[string]$config.pythonPath;$base=Resolve-BallisticsBaseModel $Endpoint $ApiToken $BaseModelId
    foreach($id in @('ki-stack-allgemein','ki-stack-it-technik')){if($null-eq(Get-BallisticsModel $Endpoint $ApiToken $id)){throw"Geschütztes Profil fehlt: $id"}}
    $currentTool=Get-BallisticsTool $Endpoint $ApiToken;$currentModel=Get-BallisticsModel $Endpoint $ApiToken 'ki-stack-18bravo'
    $markerPath=Join-Path $TargetRoot 'modules/openwebui-ballistics/installation.json';$markerOwned=$false;if(Test-Path $markerPath){$marker=Get-Content $markerPath -Raw|ConvertFrom-Json;$markerOwned=([string]$marker.managedBy-eq'KI-STACK-OPENWEBUI-BALLISTICS-PACK'-and[string]$marker.toolId-eq'ki_stack_ballistics_calculator')}
    if($currentTool-and-not(Test-BallisticsToolOwned $currentTool)-and-not$markerOwned){throw'Tool-ID-Kollision mit fremdem Objekt.'}
    if($currentModel){$owner=if($currentModel.meta.psobject.Properties.Name-contains'managedBy'){[string]$currentModel.meta.managedBy}else{''};if($owner-ne'KI-STACK-OPENWEBUI-BALLISTICS-PACK'){throw'Profil-ID-Kollision mit fremdem Objekt.'}}
    $backup=Backup-OpenWebUIBallisticsPack $Endpoint $ApiToken $BackupDirectory $python
    Install-BallisticsPythonRuntime $PackageRoot $python
    foreach($name in @('profiles','exports','backups')){New-Item -ItemType Directory -Path (Join-Path ([string]$config.dataRoot) $name) -Force|Out-Null}
    $toolForm=New-BallisticsToolForm $PackageRoot;$toolPath=if($currentTool){'/api/v1/tools/id/ki_stack_ballistics_calculator/update'}else{'/api/v1/tools/create'};$null=Invoke-BallisticsApi $Endpoint $ApiToken $toolPath POST $toolForm
    $modelForm=New-BallisticsModelForm $PackageRoot $base;$modelPath=if($currentModel){'/api/v1/models/model/update'}else{'/api/v1/models/create'};$null=Invoke-BallisticsApi $Endpoint $ApiToken $modelPath POST $modelForm
    $installRoot=[string]$config.installationRoot;New-Item -ItemType Directory $installRoot -Force|Out-Null;Copy-Item (Join-Path $PackageRoot '*') $installRoot -Recurse -Force
    [ordered]@{schemaVersion='1.0';version='1.0.0';managedBy='KI-STACK-OPENWEBUI-BALLISTICS-PACK';profileId='ki-stack-18bravo';toolId='ki_stack_ballistics_calculator';solver='pyballistic 2.2.0';installedAtUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content (Join-Path $installRoot 'installation.json') -Encoding UTF8
    [pscustomobject]@{version='1.0.0';baseModelId=$base;backupPath=$backup;toolAction=if($currentTool){'updated'}else{'created'};profileAction=if($currentModel){'updated'}else{'created'}}
}

function Test-OpenWebUIBallisticsPack {
    param($Endpoint,$ApiToken,[string]$PackageRoot)
    $fail=[Collections.Generic.List[string]]::new();$tool=Get-BallisticsTool $Endpoint $ApiToken;$model=Get-BallisticsModel $Endpoint $ApiToken 'ki-stack-18bravo'
    if(-not$tool){$fail.Add('Tool fehlt')}elseif(-not(Test-BallisticsToolOwned $tool)-or[string]$tool.meta.manifest.version-ne'1.0.0'){$fail.Add('Tool-Vertrag')}
    if(-not$model){$fail.Add('Profil fehlt')}else{
        if([string]$model.name-ne'18Bravo'){$fail.Add('Profilname')}
        # 2.16 Phase 3A: "exklusiv" heisst weiterhin "nur der Ballistikrechner plus, falls
        # mcpBinding nicht per Definition abgeschaltet ist, genau die eine MCP-Server-Bindung" --
        # nie ein zusaetzliches, unerwartetes drittes Tool und nie ein Duplikat.
        $definition=Get-Content (Join-Path $PackageRoot 'Definitions/ki-stack-18bravo.json') -Raw|ConvertFrom-Json -Depth 30
        $expectedToolIds=@(@('ki_stack_ballistics_calculator')+@(Get-BallisticsMcpToolIds $definition))
        $actualToolIds=@($model.meta.toolIds)
        $actualSorted=@($actualToolIds|Sort-Object)
        $expectedSorted=@($expectedToolIds|Sort-Object)
        $matches=($actualSorted.Count-eq$expectedSorted.Count)-and-not(@(Compare-Object $actualSorted $expectedSorted).Count)
        if(-not$matches){$fail.Add('Exklusive Toolbindung')}
        if($actualToolIds.Count-ne(@($actualToolIds|Select-Object -Unique).Count)){$fail.Add('Tool-ID-Duplikat im Profil')}
        if(@($model.meta.knowledge).Count){$fail.Add('Knowledge-Bindung')}
    }
    foreach($id in @('ki-stack-allgemein','ki-stack-it-technik')){$m=Get-BallisticsModel $Endpoint $ApiToken $id;if(@($m.meta.toolIds)-contains'ki_stack_ballistics_calculator'){$fail.Add("Unerwünschte Bindung: $id")}}
    $tools=Invoke-BallisticsApi $Endpoint $ApiToken '/api/v1/tools/';if(@($tools|Where-Object id -eq 'ki_stack_ballistics_calculator').Count-ne1){$fail.Add('Tool-Duplikat')}
    $models=Invoke-BallisticsApi $Endpoint $ApiToken '/api/v1/models/list?page=1';if(@($models.items|Where-Object id -eq 'ki-stack-18bravo').Count-ne1){$fail.Add('Profil-Duplikat')}
    [pscustomobject]@{passed=($fail.Count-eq0);failures=@($fail)}
}

function Restore-OpenWebUIBallisticsPack {
    param($Endpoint,$ApiToken,[string]$BackupPath,[string]$PythonPath='C:\KI-Stack\python\venvs\openwebui\Scripts\python.exe',[string]$TargetRoot='C:\KI-Stack')
    $b=Get-Content $BackupPath -Raw|ConvertFrom-Json -Depth 50
    if($b.modelExisted){$path=if(Get-BallisticsModel $Endpoint $ApiToken 'ki-stack-18bravo'){'/api/v1/models/model/update'}else{'/api/v1/models/create'};$null=Invoke-BallisticsApi $Endpoint $ApiToken $path POST $b.model}elseif(Get-BallisticsModel $Endpoint $ApiToken 'ki-stack-18bravo'){$null=Invoke-BallisticsApi $Endpoint $ApiToken '/api/v1/models/model/delete' POST @{id='ki-stack-18bravo'}}
    if($b.toolExisted){$path=if(Get-BallisticsTool $Endpoint $ApiToken){'/api/v1/tools/id/ki_stack_ballistics_calculator/update'}else{'/api/v1/tools/create'};$null=Invoke-BallisticsApi $Endpoint $ApiToken $path POST $b.tool}elseif(Get-BallisticsTool $Endpoint $ApiToken){$null=Invoke-BallisticsApi $Endpoint $ApiToken '/api/v1/tools/id/ki_stack_ballistics_calculator/delete' DELETE}
    foreach($name in @('pyballistic','Deprecated','wrapt')){if($null-eq$b.pythonPackages.$name){&$PythonPath -m pip uninstall -y $name|Out-Null;if($LASTEXITCODE-ne0){throw"Rollback des Python-Pakets fehlgeschlagen: $name"}}}
    if(-not$b.modelExisted-and-not$b.toolExisted){Remove-Item (Join-Path $TargetRoot 'modules/openwebui-ballistics') -Recurse -Force -ErrorAction SilentlyContinue}
}

Export-ModuleMember -Function *

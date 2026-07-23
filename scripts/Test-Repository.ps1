[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Add-Result {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $script:Results.Add([pscustomobject]@{ name=$Name; passed=$Passed; detail=$Detail }) | Out-Null
}

function Get-OptionalPropertyValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$DefaultValue = $null
    )
    if ($null -eq $InputObject) { return $DefaultValue }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function Resolve-ReleaseManifestVersion {
    param([Parameter(Mandatory)][object]$Manifest)
    $currentValue = [string](Get-OptionalPropertyValue -InputObject $Manifest -Name 'version' -DefaultValue '')
    $legacyValue = [string](Get-OptionalPropertyValue -InputObject $Manifest -Name 'packageVersion' -DefaultValue '')
    $hasCurrent = -not [string]::IsNullOrWhiteSpace($currentValue)
    $hasLegacy = -not [string]::IsNullOrWhiteSpace($legacyValue)
    if (-not $hasCurrent -and -not $hasLegacy) {
        return [pscustomobject][ordered]@{ success=$false; version=''; detail='Neither version nor packageVersion is present.' }
    }
    if ($hasCurrent -and $hasLegacy -and $currentValue -ne $legacyValue) {
        return [pscustomobject][ordered]@{ success=$false; version=''; detail=('Conflicting version fields: version={0}; packageVersion={1}' -f $currentValue,$legacyValue) }
    }
    return [pscustomobject][ordered]@{ success=$true; version=$(if($hasCurrent){$currentValue}else{$legacyValue}); detail=$(if($hasCurrent -and $hasLegacy){'current and legacy fields agree'}elseif($hasCurrent){'current version field'}else{'legacy packageVersion field'}) }
}

function Test-ReleaseManifestSchemaFixtures {
    $fixtures = @(
        [pscustomobject]@{ Name='CurrentVersionOnly'; Manifest=[pscustomobject]@{version='1.6.3'}; ExpectedSuccess=$true; ExpectedVersion='1.6.3' },
        [pscustomobject]@{ Name='LegacyPackageVersionOnly'; Manifest=[pscustomobject]@{packageVersion='1.6.3'}; ExpectedSuccess=$true; ExpectedVersion='1.6.3' },
        [pscustomobject]@{ Name='MatchingDualVersion'; Manifest=[pscustomobject]@{version='1.6.3';packageVersion='1.6.3'}; ExpectedSuccess=$true; ExpectedVersion='1.6.3' },
        [pscustomobject]@{ Name='ConflictingDualVersion'; Manifest=[pscustomobject]@{version='1.6.3';packageVersion='1.6.2'}; ExpectedSuccess=$false; ExpectedVersion='' },
        [pscustomobject]@{ Name='MissingVersionFields'; Manifest=[pscustomobject]@{releaseId='TEST'}; ExpectedSuccess=$false; ExpectedVersion='' }
    )
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($fixture in $fixtures) {
        $resolved = Resolve-ReleaseManifestVersion -Manifest $fixture.Manifest
        if ([bool]$resolved.success -ne [bool]$fixture.ExpectedSuccess -or [string]$resolved.version -ne [string]$fixture.ExpectedVersion) {
            [void]$failures.Add(('{0}: success={1}, version={2}, detail={3}' -f $fixture.Name,$resolved.success,$resolved.version,$resolved.detail))
        }
    }
    return [pscustomobject][ordered]@{ success=($failures.Count -eq 0); failures=@($failures); fixtureCount=$fixtures.Count }
}

function Test-CmdCrLf {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    for ($i=0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 10 -and ($i -eq 0 -or $bytes[$i-1] -ne 13)) { return $false }
    }
    return $true
}

$RootPath = [IO.Path]::GetFullPath($RootPath)
$Results = [Collections.Generic.List[object]]::new()
$excludedPathPattern = '[\\/](?:\.git|_import)[\\/]|[\\/]tools[\\/]production-recovery[\\/]current[\\/]04-Evidence[\\/]'

try {
    $required = @(
        'README.md','README.de.md','CHANGELOG.md','VERSION','release-manifest.json','production-release-manifest.json',
        'package/Config/kernel-config.json','package/Tests/Test-KIStackBuilderKernel.ps1',
        'scripts/Test-Repository.ps1','scripts/Test-PowerShell7Starters.ps1','scripts/New-ReleaseArchive.ps1',
        'docs/error-registry/REGRESSION-MATRIX.md',
        'tools/openwebui-agent-pack/current/VERSION',
        'tools/openwebui-agent-pack/current/MANIFEST.json',
        'tools/openwebui-agent-pack/current/Definitions/ki-stack-it-technik.json',
        'tools/openwebui-agent-pack/current/Definitions/ki-stack-allgemein.json',
        'tools/openwebui-agent-pack/current/OpenWebUIAgentPack.psm1',
        'tools/openwebui-agent-pack/current/Invoke-OpenWebUIAgentPack.ps1',
        'tools/openwebui-agent-pack/current/Test-OpenWebUIAgentPack.ps1',
        'tools/openwebui-image-pack/current/VERSION',
        'tools/openwebui-image-pack/current/MANIFEST.json',
        'tools/openwebui-image-pack/current/Config/image-pack.config.json',
        'tools/openwebui-image-pack/current/Tool/ki-stack-generate-image.py',
        'tools/openwebui-image-pack/current/Workflow/FLUX2-Klein-9B-OpenWebUI-API-FLAT.json',
        'tools/openwebui-image-pack/current/OpenWebUIImagePack.psm1',
        'tools/openwebui-image-pack/current/Invoke-OpenWebUIImagePack.ps1',
        'tools/openwebui-image-pack/current/Test-OpenWebUIImagePack.ps1',
        'tools/openwebui-image-pack/current/Test-OpenWebUIImagePackWorkflow.ps1',
        'tools/openwebui-image-pack/current/Test-OpenWebUIImagePackTarget.ps1',
        'tools/openwebui-image-pack/current/New-OpenWebUIImagePackArchive.ps1',
        'tools/openwebui-image-pack/current/Start-OpenWebUI-Image-Pack-Execute.cmd',
        'tools/openwebui-image-pack/current/Start-OpenWebUI-Image-Pack-DryRun.cmd',
        'tools/openwebui-image-pack/current/Start-OpenWebUI-Image-Pack-SelfTest.cmd',
        'tools/openwebui-image-pack/current/BUILD-REPORT.json',
        'tools/openwebui-image-pack/current/VALIDATION-REPORT.json',
        'tools/openwebui-image-pack/current/SHA256SUMS.txt'
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RootPath $_)) })
    Add-Result 'Required files' ($missing.Count -eq 0) ($(if($missing){$missing -join ', '}else{'complete'}))

    $jsonFiles = @(Get-ChildItem -LiteralPath $RootPath -Recurse -File -Filter '*.json' | Where-Object { $_.FullName -notmatch $excludedPathPattern })
    $jsonErrors = @()
    foreach ($file in $jsonFiles) {
        try { Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 100 | Out-Null }
        catch { $jsonErrors += "$($file.FullName): $($_.Exception.Message)" }
    }
    Add-Result 'JSON integrity' ($jsonErrors.Count -eq 0) ($(if($jsonErrors){$jsonErrors -join '; '}else{"$($jsonFiles.Count) files parsed"}))

    $psFiles = @(Get-ChildItem -LiteralPath $RootPath -Recurse -File | Where-Object { $_.Extension -in '.ps1','.psm1' -and $_.FullName -notmatch $excludedPathPattern })
    $parseErrors = @()
    foreach ($file in $psFiles) {
        $tokens=$null; $errors=$null
        [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors) | Out-Null
        foreach($err in @($errors)){ $parseErrors += "$($file.FullName): $($err.Message)" }
    }
    Add-Result 'PowerShell parser' ($parseErrors.Count -eq 0) ($(if($parseErrors){$parseErrors -join '; '}else{"$($psFiles.Count) files parsed"}))

    $cmdFiles = @(Get-ChildItem -LiteralPath $RootPath -Recurse -File -Filter '*.cmd' | Where-Object { $_.FullName -notmatch $excludedPathPattern })
    $badCmd = @($cmdFiles | Where-Object { -not (Test-CmdCrLf -Path $_.FullName) } | ForEach-Object FullName)
    $bomCmd = @($cmdFiles | Where-Object { $bytes=[IO.File]::ReadAllBytes($_.FullName); $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF } | ForEach-Object FullName)
    Add-Result 'CMD CRLF/BOM' ($badCmd.Count -eq 0 -and $bomCmd.Count -eq 0) ($(if($badCmd -or $bomCmd){'CRLF='+($badCmd -join ', ')+'; BOM='+($bomCmd -join ', ')}else{"$($cmdFiles.Count) files checked"}))

    $schemaFixtures = Test-ReleaseManifestSchemaFixtures
    Add-Result 'Release manifest schema compatibility' ([bool]$schemaFixtures.success) $(
        if ([bool]$schemaFixtures.success) { "$($schemaFixtures.fixtureCount) fixtures passed" }
        else { @($schemaFixtures.failures) -join '; ' }
    )

    $manifestPath = Join-Path $RootPath 'release-manifest.json'
    $configPath = Join-Path $RootPath 'package/Config/kernel-config.json'
    if ((Test-Path -LiteralPath $manifestPath -PathType Leaf) -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 100
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 100
        $resolvedVersion = Resolve-ReleaseManifestVersion -Manifest $manifest
        $manifestReleaseId = [string](Get-OptionalPropertyValue -InputObject $manifest -Name 'releaseId' -DefaultValue '')
        $configRelease = Get-OptionalPropertyValue -InputObject $config -Name 'executeRelease' -DefaultValue $null
        $configReleaseId = [string](Get-OptionalPropertyValue -InputObject $configRelease -Name 'releaseId' -DefaultValue '')
        $versionsOk = (
            [bool]$resolvedVersion.success -and
            [string]$resolvedVersion.version -eq [string]$config.kernelVersion -and
            -not [string]::IsNullOrWhiteSpace($manifestReleaseId) -and
            $manifestReleaseId -eq $configReleaseId
        )
        Add-Result 'Version consistency' $versionsOk "manifest=$($resolvedVersion.version)/$manifestReleaseId ($($resolvedVersion.detail)); config=$($config.kernelVersion)/$configReleaseId"
        $manifestModules = Get-OptionalPropertyValue -InputObject $manifest -Name 'enabledModules' -DefaultValue $null
        if ($null -eq $manifestModules) {
            $manifestModules = Get-OptionalPropertyValue -InputObject $configRelease -Name 'enabledModules' -DefaultValue @()
        }
        $enabledA=@($manifestModules | Sort-Object); $enabledB=@((Get-OptionalPropertyValue -InputObject $configRelease -Name 'enabledModules' -DefaultValue @()) | Sort-Object)
        $modulesOk = (($enabledA -join '|') -eq ($enabledB -join '|'))
        Add-Result 'Enabled modules' $modulesOk "manifest=$($enabledA -join ','); config=$($enabledB -join ',')"

        $packageName = [string](Get-OptionalPropertyValue -InputObject $manifest -Name 'packageName' -DefaultValue '')
        $packageDirectory = [string](Get-OptionalPropertyValue -InputObject $manifest -Name 'packageDirectory' -DefaultValue '')
        $releaseTag = [string](Get-OptionalPropertyValue -InputObject $manifest -Name 'tag' -DefaultValue '')
        $builderPath = Join-Path $RootPath 'scripts/New-ReleaseArchive.ps1'
        $builderSource = Get-Content -LiteralPath $builderPath -Raw
        $releaseContractOk = (
            $packageName -eq ('KI-Stack-Cutover-Execute-v{0}' -f $resolvedVersion.version) -and
            -not [string]::IsNullOrWhiteSpace($packageDirectory) -and
            (Test-Path -LiteralPath (Join-Path $RootPath $packageDirectory) -PathType Container) -and
            $releaseTag -eq ('cutover-v{0}-rc1' -f $resolvedVersion.version) -and
            $builderSource.Contains("PSObject.Properties['packageName']") -and
            $builderSource.Contains("PSObject.Properties['packageDirectory']") -and
            $builderSource.Contains('$packageSource')
        )
        Add-Result 'Release build contract' $releaseContractOk "packageName=$packageName; packageDirectory=$packageDirectory; tag=$releaseTag"
    }
    else {
        Add-Result 'Version consistency' $false 'release-manifest.json or package/Config/kernel-config.json is missing.'
        Add-Result 'Enabled modules' $false 'Version inputs are incomplete.'
        Add-Result 'Release build contract' $false 'Release inputs are incomplete.'
    }

    $liveReferenceFiles = @(
        Join-Path $RootPath 'package/README.md'
        Join-Path $RootPath 'package/Tests/Test-KIStackBuilderKernel.ps1'
        Join-Path $RootPath 'package/Tests/Test-KIStackHistoricalRegressions.ps1'
        Join-Path $RootPath 'package/Tests/Test-KIStackPathResolution.ps1'
    )
    $obsoleteReferencePattern = 'Start-(?:Validate|Publish)-GitHub-Update\.cmd|Invoke-IncludedGitHubUpdate\.ps1|KI-Stack-GitHub-Update-v0\.5\.3(?:\.zip)?'
    $obsoleteReferences = @()
    foreach ($file in $liveReferenceFiles) {
        $matches = [regex]::Matches((Get-Content -LiteralPath $file -Raw),$obsoleteReferencePattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($match in $matches) { $obsoleteReferences += ('{0}: {1}' -f $file,$match.Value) }
    }
    $packageReadme = Get-Content -LiteralPath (Join-Path $RootPath 'package/README.md') -Raw
    $referencesOk = $obsoleteReferences.Count -eq 0 -and $packageReadme.Contains('nicht Bestandteil dieses Runtime-Pakets')
    Add-Result 'Live file references' $referencesOk $(if($referencesOk){'obsolete GitHub package references removed and component absence documented'}else{$obsoleteReferences -join '; '})

    $runtimeVersion = (Get-Content -LiteralPath (Join-Path $RootPath 'VERSION') -Raw).Trim()
    $modelsVersion = [string](Get-Content -LiteralPath (Join-Path $RootPath 'package/Modules/05-Models/module.json') -Raw | ConvertFrom-Json).version
    $applicationsVersion = [string](Get-Content -LiteralPath (Join-Path $RootPath 'package/Modules/06-Applications/module.json') -Raw | ConvertFrom-Json).version
    $integrationVersion = (Get-Content -LiteralPath (Join-Path $RootPath 'tools/integration/current/VERSION') -Raw).Trim()
    $readmeEn = Get-Content -LiteralPath (Join-Path $RootPath 'README.md') -Raw
    $readmeDe = Get-Content -LiteralPath (Join-Path $RootPath 'README.de.md') -Raw
    $buildReport = Get-Content -LiteralPath (Join-Path $RootPath 'package/BUILD-REPORT.md') -Raw
    $documentationVersionsOk = (
        $readmeEn.Contains("| Models / Workflows | $modelsVersion |") -and
        $readmeEn.Contains("| Applications | $applicationsVersion |") -and
        $readmeEn.Contains("| Integration | $integrationVersion |") -and
        $readmeDe.Contains("| Modelle / Workflows | $modelsVersion |") -and
        $readmeDe.Contains("| Applications | $applicationsVersion |") -and
        $readmeDe.Contains("| Integration | $integrationVersion |") -and
        $buildReport.Contains("Ausgelieferter Stand: Cutover v$runtimeVersion")
    )
    Add-Result 'Documentation version consistency' $documentationVersionsOk "runtime=$runtimeVersion; models=$modelsVersion; applications=$applicationsVersion; integration=$integrationVersion"

    $fluxUiPath=Join-Path $RootPath 'package/Workflows/KI-Stack-FLUX2-Text-to-Image-v1.3.8.json'
    $fluxApiPath=Join-Path $RootPath 'package/Workflows/FLUX2-Klein-9B-OpenWebUI-API-FLAT.json'
    $fluxUiHash=if(Test-Path $fluxUiPath){(Get-FileHash $fluxUiPath -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}
    $fluxApiHash=if(Test-Path $fluxApiPath){(Get-FileHash $fluxApiPath -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}
    $fluxUi=if(Test-Path $fluxUiPath){Get-Content $fluxUiPath -Raw|ConvertFrom-Json -Depth 100}else{$null}
    $workflowCatalog=Get-Content (Join-Path $RootPath 'package/Manifests/workflows.catalog.json') -Raw|ConvertFrom-Json -Depth 100
    $modelsManifest=Get-Content (Join-Path $RootPath 'package/Manifests/models.manifest.json') -Raw|ConvertFrom-Json -Depth 100
    $canonicalWorkflowHashes=@{
        'KREA-Realism-Official-Template.json'='344dc0a177b625d7bdde5292771a5455951178d6d498649cbb40f4e690216e65'
        'PONY-SDXL-Control-QuickTest-v2.json'='7338036490ee1325062c75f10d89a46661cec6c43f17f5d1a035da5db2e68d40'
        'WAN2.2-5B-Official.json'='7d4195f7a67d01829dd8a3d4c54f9b5fc857399a6f246c5b555b5a66848f27e6'
    }
    $canonicalWorkflowOk=$true
    foreach($entry in $canonicalWorkflowHashes.GetEnumerator()){$path=Join-Path $RootPath ('package/Workflows/'+$entry.Key);if(-not(Test-Path $path)-or(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()-ne$entry.Value){$canonicalWorkflowOk=$false}}
    $externalModels=@($modelsManifest.models|Where-Object{$_.PSObject.Properties.Name-contains'profile'-and[string]$_.profile-in@('krea-realism','pony-sdxl','wan22-5b')})
    $manualExternalModels=@($externalModels|Where-Object{$_.PSObject.Properties.Name-contains'manualExternal'-and[bool]$_.manualExternal})
    $automaticExternalModels=@($externalModels|Where-Object{-not($_.PSObject.Properties.Name-contains'manualExternal')-or-not[bool]$_.manualExternal})
    $externalModelsOk=($externalModels.Count-eq8-and[long]($externalModels|Measure-Object sizeBytes -Sum).Sum-eq47356936991-and$manualExternalModels.Count-eq7-and$automaticExternalModels.Count-eq1-and[string]$automaticExternalModels[0].source-eq'https://civitai.com/api/download/models/290640'-and@($manualExternalModels|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_.source)-or[string]$_.manualReference-notmatch'^https://'-or[string]$_.sha256-notmatch'^[0-9a-f]{64}$'-or[long]$_.sizeBytes-le0-or[string]::IsNullOrWhiteSpace([string]$_.relativeTargetPath)}).Count-eq0)
    $fluxNodeIds=@($fluxUi.nodes.id);$fluxLinkIds=@($fluxUi.links|ForEach-Object{$_[0]})
    $fluxGraphChecks = @(
        ($modelsVersion -eq '1.4.2'),
        ($fluxUiHash -eq 'b0c90e9fd38a4948fe97bbd7e95b2100261dc69b335794ba6c7db2fe4ff539db'),
        ($fluxApiHash -eq '697ea261e1c62a8e32d775ee9cba5c5c5c3548c6bd082a63a84c71f53c3123a5'),
        $canonicalWorkflowOk,
        $externalModelsOk,
        (@($workflowCatalog.workflows).Count -eq 5),
        (@($fluxUi.nodes).Count -eq 6),
        (@($fluxUi.links).Count -eq 5),
        (@($fluxNodeIds | Group-Object | Where-Object Count -gt 1).Count -eq 0),
        (@($fluxLinkIds | Group-Object | Where-Object Count -gt 1).Count -eq 0),
        (@($fluxUi.nodes | Where-Object type -eq 'PreviewImage').Count -eq 1),
        (@($fluxUi.nodes | Where-Object { $_.type -eq 'SaveImage' -and $_.mode -eq 0 }).Count -eq 1)
    )
    $fluxGraphOk = $fluxGraphChecks -notcontains $false
    $modelImporterFilesOk=@('package/Import-KIStackExternalModels.ps1','package/Start-KIStack-Model-Import.cmd','package/ExternalModels/README.md','package/Tests/Test-KIStackExternalModelImport.ps1')|ForEach-Object{Test-Path -LiteralPath (Join-Path $RootPath $_)}
    $fluxGraphOk=$fluxGraphOk-and($modelImporterFilesOk-notcontains$false)
    Add-Result 'Models / Workflows 1.4.2 graph and external-model contract' $fluxGraphOk "ui=$fluxUiHash; api=$fluxApiHash; canonical=$canonicalWorkflowOk; importer=$($modelImporterFilesOk-notcontains$false); manualExternal=$($manualExternalModels.Count); automaticExternal=$($automaticExternalModels.Count); externalBytes=$([long]($externalModels|Measure-Object sizeBytes -Sum).Sum)"

    $agentRoot = Join-Path $RootPath 'tools/openwebui-agent-pack/current'
    $agentVersion = (Get-Content -LiteralPath (Join-Path $agentRoot 'VERSION') -Raw).Trim()
    $agentManifest = Get-Content -LiteralPath (Join-Path $agentRoot 'MANIFEST.json') -Raw | ConvertFrom-Json -Depth 30
    $agentConfig = Get-Content -LiteralPath (Join-Path $agentRoot 'Config/agent-pack.config.json') -Raw | ConvertFrom-Json -Depth 30
    $agentDefinitions = @(Get-ChildItem -LiteralPath (Join-Path $agentRoot 'Definitions') -File -Filter '*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 30 })
    $agentIds = @($agentDefinitions.id | Sort-Object)
    $agentSchemaOk = (
        $agentVersion -eq '1.8.3' -and $agentManifest.version -eq $agentVersion -and $agentConfig.version -eq $agentVersion -and $agentManifest.status -eq 'TargetValidated' -and
        ($agentIds -join '|') -eq 'ki-stack-allgemein|ki-stack-it-technik' -and
        @($agentDefinitions | Where-Object { $_.schemaVersion -ne '1.0' -or [string]::IsNullOrWhiteSpace([string]$_.systemPrompt) }).Count -eq 0 -and
        @($agentDefinitions | Where-Object { @($_.knowledge).Count -or @($_.toolIds).Count -or @($_.skillIds).Count -or @($_.functionIds).Count }).Count -eq 0
    )
    Add-Result 'OpenWebUI Agent Pack contract' $agentSchemaOk "version=$agentVersion; ids=$($agentIds -join ',')"

    $agentSumErrors = @()
    foreach ($line in Get-Content -LiteralPath (Join-Path $agentRoot 'SHA256SUMS.txt')) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') { $agentSumErrors += "Invalid line: $line"; continue }
        $target = Join-Path $agentRoot $Matches[2].Replace('/',[IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { $agentSumErrors += "Missing: $($Matches[2])"; continue }
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Matches[1].ToLowerInvariant()) { $agentSumErrors += "Mismatch: $($Matches[2])" }
    }
    Add-Result 'OpenWebUI Agent Pack SHA256' ($agentSumErrors.Count -eq 0) $(if($agentSumErrors){$agentSumErrors -join '; '}else{'all listed files verified'})

    $imageRoot = Join-Path $RootPath 'tools/openwebui-image-pack/current'
    $imageVersion = (Get-Content -LiteralPath (Join-Path $imageRoot 'VERSION') -Raw).Trim()
    $imageManifest = Get-Content -LiteralPath (Join-Path $imageRoot 'MANIFEST.json') -Raw | ConvertFrom-Json -Depth 30
    $imageConfig = Get-Content -LiteralPath (Join-Path $imageRoot 'Config/image-pack.config.json') -Raw | ConvertFrom-Json -Depth 30
    $agentExtension = @($agentManifest.registeredExtensions | Where-Object { $_.canonicalToolId -eq 'ki-stack-generate-image' -and $_.openWebUIToolId -eq 'ki_stack_generate_image' -and $_.managedBy -eq 'KI-STACK-OPENWEBUI-IMAGE-PACK' })
    $imageContractOk = $imageVersion -eq '1.9.1' -and $imageManifest.version -eq $imageVersion -and $imageConfig.version -eq $imageVersion -and $imageManifest.status -eq 'TargetSystemValidated' -and $imageManifest.managedTool.id -eq 'ki-stack-generate-image' -and $imageManifest.managedTool.openWebUIId -eq 'ki_stack_generate_image' -and $imageManifest.managedTool.managedBy -eq 'KI-STACK-OPENWEBUI-IMAGE-PACK' -and $agentExtension.Count -eq 1
    Add-Result 'OpenWebUI Image Pack contract' $imageContractOk "version=$imageVersion; tool=$($imageManifest.managedTool.id)"
    $imageSumErrors = @()
    foreach ($line in Get-Content -LiteralPath (Join-Path $imageRoot 'SHA256SUMS.txt')) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') { $imageSumErrors += "Invalid line: $line"; continue }
        $target = Join-Path $imageRoot $Matches[2].Replace('/',[IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { $imageSumErrors += "Missing: $($Matches[2])"; continue }
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Matches[1].ToLowerInvariant()) { $imageSumErrors += "Mismatch: $($Matches[2])" }
    }
    Add-Result 'OpenWebUI Image Pack SHA256' ($imageSumErrors.Count -eq 0) $(if($imageSumErrors){$imageSumErrors -join '; '}else{'all listed files verified'})

    $trackedFiles = @(& git -C $RootPath ls-files)
    $forbiddenImageArtifacts = @($trackedFiles | Where-Object {
        $_ -match '^(?:_import/|tools/openwebui-image-pack/current/(?:backups?|history|output)/)' -or
        $_ -match '^tools/openwebui-image-pack/current/.+\.(?:png|jpe?g|webp|gif|zip|pyc)$' -or
        $_ -match '^tools/openwebui-image-pack/current/.*/__pycache__/'
    })
    Add-Result 'OpenWebUI Image Pack repository artifacts' ($forbiddenImageArtifacts.Count -eq 0) $(if($forbiddenImageArtifacts){$forbiddenImageArtifacts -join ', '}else{'no rendered images, archives, backups, bytecode or private import files tracked'})

    $ballisticsRoot=Join-Path $RootPath 'tools/openwebui-ballistics-pack/current'
    $ballisticsVersion=(Get-Content (Join-Path $ballisticsRoot 'VERSION') -Raw).Trim()
    $ballisticsManifest=Get-Content (Join-Path $ballisticsRoot 'MANIFEST.json') -Raw|ConvertFrom-Json -Depth 30
    $ballisticsDefinition=Get-Content (Join-Path $ballisticsRoot 'Definitions/ki-stack-18bravo.json') -Raw|ConvertFrom-Json -Depth 30
    $ballisticsPayloads=Get-Content (Join-Path $ballisticsRoot 'Contracts/PAYLOADS.json') -Raw|ConvertFrom-Json -Depth 30
    $solverPayload=$ballisticsPayloads.payloads|Where-Object name -eq 'pyballistic-2.2.0-py3-none-any.whl'
    $ballisticsContractOk=$ballisticsVersion-eq'1.0.0'-and[string]$ballisticsManifest.version-eq$ballisticsVersion-and[string]$ballisticsDefinition.id-eq'ki-stack-18bravo'-and[string]$ballisticsDefinition.displayName-eq'18Bravo'-and(@($ballisticsDefinition.toolIds)-join'|')-eq'ki_stack_ballistics_calculator'-and[string]$solverPayload.sha256-eq'6a17eb8c40f9606ac5878b0a5d30575f7cc83cc549375e1371c100e2bdab36a4'
    Add-Result 'OpenWebUI Ballistics Pack contract' $ballisticsContractOk "version=$ballisticsVersion; profile=$($ballisticsDefinition.id); solver=$($ballisticsManifest.solver.package) $($ballisticsManifest.solver.version)"
    $ballisticsSumErrors=@();foreach($line in Get-Content (Join-Path $ballisticsRoot 'SHA256SUMS.txt')){if([string]::IsNullOrWhiteSpace($line)-or$line.StartsWith('#')){continue};if($line-notmatch'^([0-9a-fA-F]{64})\s+\*?(.+)$'){$ballisticsSumErrors+="Invalid: $line";continue};$file=Join-Path $ballisticsRoot $Matches[2].Replace('/',[IO.Path]::DirectorySeparatorChar);if(-not(Test-Path $file -PathType Leaf)){$ballisticsSumErrors+="Missing: $($Matches[2])";continue};if((Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()-ne$Matches[1].ToLowerInvariant()){$ballisticsSumErrors+="Mismatch: $($Matches[2])"}}
    Add-Result 'OpenWebUI Ballistics Pack SHA256' ($ballisticsSumErrors.Count-eq0) $(if($ballisticsSumErrors){$ballisticsSumErrors-join', '}else{'all listed files verified'})
    $forbiddenBallistics=@($trackedFiles|Where-Object{$_-match'^(?:_import/|tools/openwebui-ballistics-pack/current/(?:Payload|backups?|exports?|profiles?)/)'-or$_-match'^tools/openwebui-ballistics-pack/current/.+\.(?:whl|zip|pyc|csv)$'-or$_-match'/__pycache__/'})
    Add-Result 'OpenWebUI Ballistics Pack repository artifacts' ($forbiddenBallistics.Count-eq0) $(if($forbiddenBallistics){$forbiddenBallistics-join', '}else{'no wheels, archives, user data, bytecode or private imports tracked'})

    $gitFreePackages=@(
        @{name='ComfyUI';root='tools/comfyui/current';version='1.2.2'},
        @{name='Integration';root='tools/integration/current';version='1.5.9'},
        @{name='Complete Installer';root='tools/complete-installer/current';version='2.2.2'}
    )
    foreach($packageContract in $gitFreePackages){
        $packageRoot=Join-Path $RootPath $packageContract.root
        $version=(Get-Content (Join-Path $packageRoot 'VERSION') -Raw).Trim()
        $manifest=Get-Content (Join-Path $packageRoot 'MANIFEST.json') -Raw|ConvertFrom-Json -Depth 50
        $sumErrors=@()
        foreach($line in Get-Content (Join-Path $packageRoot 'SHA256SUMS.txt')){if([string]::IsNullOrWhiteSpace($line)){continue};if($line-notmatch'^([0-9a-fA-F]{64})\s+\*?(.+)$'){$sumErrors+="Invalid: $line";continue};$file=Join-Path $packageRoot $Matches[2].Replace('/',[IO.Path]::DirectorySeparatorChar);if(-not(Test-Path $file)){$sumErrors+="Missing: $($Matches[2])";continue};if((Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()-ne$Matches[1].ToLowerInvariant()){$sumErrors+="Mismatch: $($Matches[2])"}}
        Add-Result "$($packageContract.name) version and SHA256 contract" ($version-eq$packageContract.version-and[string]$manifest.version-eq$version-and$sumErrors.Count-eq0) "version=$version; status=$($manifest.status); errors=$($sumErrors -join ', ')"
    }
    $completeRoot=Join-Path $RootPath 'tools/complete-installer/current'
    $completeRequired=@('CompleteInstaller.psm1','Invoke-KIStackCompleteInstaller.ps1','Import-KIStackExternalModels.ps1','Start-KIStack-Model-Import.cmd','ExternalModels/README.md','Test-KIStackCompleteInstaller.ps1','Test-KIStackCompleteInstallerTarget.ps1','New-KIStackCompleteInstallerArchive.ps1','Contracts/COMPONENTS.json','Contracts/PAYLOADS.json','Contracts/TRANSACTION.schema.json','Contracts/RESUME.schema.json','Contracts/ROLLBACK.md','Start-KIStack-Installer.cmd','Start-KIStack-Audit.cmd','Start-KIStack-Repair.cmd','Start-KIStack-Validate.cmd','Start-KIStack-Rollback.cmd','Start-KIStack.cmd','Stop-KIStack.cmd')
    $completeMissing=@($completeRequired|Where-Object{-not(Test-Path (Join-Path $completeRoot $_))})
    Add-Result 'Complete Installer source completeness' ($completeMissing.Count-eq0) $(if($completeMissing){$completeMissing-join', '}else{'complete'})
    $completeComponents=Get-Content (Join-Path $completeRoot 'Contracts/COMPONENTS.json') -Raw|ConvertFrom-Json
    $completeVersionsOk=([string]($completeComponents.components|Where-Object id -eq 'comfyui').version -eq '1.2.2' -and [string]($completeComponents.components|Where-Object id -eq 'models-workflows').version -eq '1.4.2' -and [string]($completeComponents.components|Where-Object id -eq 'integration').version -eq '1.5.9'-and[string]($completeComponents.components|Where-Object id -eq 'openwebui-ballistics-pack').version-eq'1.0.0')
    Add-Result 'Complete Installer component versions' $completeVersionsOk 'ComfyUI=1.2.2; Models/Workflows=1.4.2; Integration=1.5.9; optional Ballistics=1.0.0'
    $completeExecutable=Get-ChildItem $completeRoot -Recurse -File|Where-Object{$_.Extension-in'.ps1','.psm1','.cmd'-and$_.Name-ne'Test-KIStackCompleteInstaller.ps1'}|ForEach-Object{Get-Content $_.FullName -Raw}
    $forbiddenRuntime=('(?im)\b'+'git'+'\s+(?:cl'+'one|check'+'out|pu'+'ll|fetch|rev-parse|describe)\b|\.'+'git'+'(?:[/\\]|\b)|\bor'+'igin\b|comm'+'it[- ]hash|tr'+'ee[- ]hash')
    Add-Result 'Complete Installer Git-free runtime' (-not(($completeExecutable-join"`n")-match$forbiddenRuntime)) 'no Git acquisition or metadata dependency in executable sources'
    $forbiddenCompleteArtifacts=@($trackedFiles|Where-Object{$_-match'^(?:_import/|tools/(?:comfyui|integration|complete-installer)/.+\.(?:zip|pyc)$)'-or$_-match'/__pycache__/'})
    Add-Result 'Git-free package repository artifacts' ($forbiddenCompleteArtifacts.Count-eq0) $(if($forbiddenCompleteArtifacts){$forbiddenCompleteArtifacts-join', '}else{'no private imports, ZIPs or bytecode tracked'})

    $sumsPath = Join-Path $RootPath 'package/SHA256SUMS.txt'
    $sumErrors=@()
    if (Test-Path $sumsPath) {
        foreach($line in Get-Content -LiteralPath $sumsPath) {
            if([string]::IsNullOrWhiteSpace($line)){continue}
            if($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$'){ $sumErrors += "Invalid line: $line"; continue }
            $expected=$Matches[1].ToLowerInvariant(); $relative=$Matches[2].Replace('/',[IO.Path]::DirectorySeparatorChar)
            $target=Join-Path (Join-Path $RootPath 'package') $relative
            if(-not(Test-Path -LiteralPath $target)){ $sumErrors += "Missing: $relative"; continue }
            $actual=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
            if($actual -ne $expected){ $sumErrors += "Mismatch: $relative" }
        }
    } else { $sumErrors += 'SHA256SUMS.txt missing' }
    Add-Result 'Package SHA256' ($sumErrors.Count -eq 0) ($(if($sumErrors){$sumErrors -join '; '}else{'all listed files verified'}))

    $secretPatterns = @('ghp_[A-Za-z0-9]{20,}','github_pat_[A-Za-z0-9_]{20,}','AKIA[0-9A-Z]{16}','-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----','sk-[A-Za-z0-9]{20,}')
    $secretHits=@()
    $textFiles=Get-ChildItem -LiteralPath $RootPath -Recurse -File | Where-Object { $_.Length -lt 5MB -and $_.Extension -in '.ps1','.psm1','.cmd','.json','.yml','.yaml','.md','.txt' -and $_.FullName -notmatch $excludedPathPattern }
    foreach($file in $textFiles){
        $text=Get-Content -LiteralPath $file.FullName -Raw
        foreach($pattern in $secretPatterns){ if($text -match $pattern){$secretHits += "$($file.FullName): $pattern"} }
    }
    Add-Result 'High-confidence secret scan' ($secretHits.Count -eq 0) ($(if($secretHits){$secretHits -join '; '}else{'no credential patterns found'}))

    $personalPathHits = @()
    $personalPathPatterns = @(
        '(?i)C:\\Users\\(?!%USERPROFILE%|<user>|username\\)[A-Za-z0-9._-]+',
        '(?i)C:\\\\Users\\\\(?!%USERPROFILE%|<user>|username\\\\)[A-Za-z0-9._-]+'
    )
    foreach ($file in $textFiles) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        foreach ($pattern in $personalPathPatterns) {
            foreach ($match in [regex]::Matches($text,$pattern)) { $personalPathHits += ('{0}: {1}' -f $file.FullName,$match.Value) }
        }
    }
    Add-Result 'Portable repository paths' ($personalPathHits.Count -eq 0) $(if($personalPathHits){$personalPathHits -join '; '}else{'no personal Windows profile paths found'})

    $validatorSource = Get-Content -LiteralPath $PSCommandPath -Raw
    $unsafeAggregation = [regex]::IsMatch(
        $validatorSource,
        '\$(?:failed|failedResults)\.name',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    Add-Result 'StrictMode failure-name aggregation' (-not $unsafeAggregation) $(
        if ($unsafeAggregation) {
            'Unsafe implicit collection property access was found.'
        }
        else {
            'Failure names are enumerated explicitly and empty lists are supported.'
        }
    )

    try {
        $powerShell7Report = (& (Join-Path $RootPath 'scripts/Test-PowerShell7Starters.ps1') -RepositoryRoot $RootPath | ConvertFrom-Json)
        Add-Result 'PowerShell 7 starter contract' ([bool]$powerShell7Report.passed) ("edition={0}; version={1}; cmdFiles={2}; WindowsPowerShellRejected={3}" -f $powerShell7Report.actualPSEdition,$powerShell7Report.actualPSVersion,$powerShell7Report.cmdFiles,$powerShell7Report.windowsPowerShellRejected)
    }
    catch { Add-Result 'PowerShell 7 starter contract' $false $_.Exception.Message }

    $invalidResults = @(
        $Results | Where-Object {
            $null -eq $_ -or
            $_.PSObject.Properties.Name -notcontains 'name' -or
            $_.PSObject.Properties.Name -notcontains 'passed' -or
            $_.PSObject.Properties.Name -notcontains 'detail'
        }
    )
    if ($invalidResults.Count -gt 0) {
        throw "Validator produced $($invalidResults.Count) malformed result object(s)."
    }

    $passedResults = @($Results | Where-Object { [bool]$_.passed })
    $failedResults = @($Results | Where-Object { -not [bool]$_.passed })
    $failedNames = @(
        $failedResults | ForEach-Object { [string]$_.name }
    )

    $report = [ordered]@{
        testedAtUtc = [DateTime]::UtcNow.ToString('o')
        root = $RootPath
        passed = ($failedResults.Count -eq 0)
        checksPassed = $passedResults.Count
        checksTotal = $Results.Count
        failedNames = $failedNames
        checks = $Results
    }
    $report | ConvertTo-Json -Depth 20
    if ($failedResults.Count -gt 0) {
        throw ('Repository validation failed: ' + ($failedNames -join ', '))
    }
    return
}
catch {
    [ordered]@{ testedAtUtc=[DateTime]::UtcNow.ToString('o'); root=$RootPath; passed=$false; fatalError=$_.Exception.Message; checks=$Results } | ConvertTo-Json -Depth 20
    throw
}

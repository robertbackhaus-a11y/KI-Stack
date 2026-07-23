[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageName,
    [Parameter(Mandatory)][string]$PackageVersion,
    [Parameter(Mandatory)][string]$ZipPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$ModelsManifestPath,
    [string]$ComponentsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-SpdxPackage {
    param([string]$Name,[string]$Id,[string]$Version,[string]$Supplier,[string]$License,[string]$Purpose,[string]$Comment,[string]$Sha256)
    [ordered]@{
        SPDXID = $Id
        name = $Name
        versionInfo = $Version
        supplier = $Supplier
        downloadLocation = 'NOASSERTION'
        filesAnalyzed = $false
        licenseConcluded = $License
        licenseDeclared = $License
        copyrightText = 'NOASSERTION'
        primaryPackagePurpose = $Purpose
        checksums = if ($Sha256) { @([ordered]@{ algorithm = 'SHA256'; checksumValue = $Sha256 }) } else { @() }
        comment = $Comment
    }
}

$zip = Get-Item -LiteralPath $ZipPath -ErrorAction Stop
$zipHash = (Get-FileHash -LiteralPath $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$rootId = 'SPDXRef-Package'
$packages = [System.Collections.Generic.List[object]]::new()
$relationships = [System.Collections.Generic.List[object]]::new()
$packages.Add((New-SpdxPackage -Name $PackageName -Id $rootId -Version $PackageVersion -Supplier 'Organization: KI-Stack' -License 'Apache-2.0' -Purpose 'APPLICATION' -Comment "Release ZIP; sizeBytes=$($zip.Length); externalModelsNotContained=true" -Sha256 $zipHash))

$included = @(
    [ordered]@{ name = 'KI-Stack package source'; version = $PackageVersion; license = 'Apache-2.0'; supplier = 'Organization: KI-Stack' },
    [ordered]@{ name = 'Third-party runtime components'; version = 'NOASSERTION'; license = 'NOASSERTION'; supplier = 'NOASSERTION' }
)
if ($ComponentsPath) {
    $components = (Get-Content -LiteralPath $ComponentsPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 30).components
    foreach ($component in $components) {
        $included += [ordered]@{ name = [string]$component.name; version = [string]$component.version; license = 'NOASSERTION'; supplier = 'NOASSERTION' }
    }
}
$index = 1
foreach ($component in $included) {
    $id = "SPDXRef-Included-$index"
    $packages.Add((New-SpdxPackage -Name $component.name -Id $id -Version $component.version -Supplier $component.supplier -License $component.license -Purpose 'APPLICATION' -Comment 'Included component; third-party license terms are recorded in THIRD_PARTY_NOTICES.md where applicable.' -Sha256 $null))
    $relationships.Add([ordered]@{ spdxElementId = $rootId; relationshipType = 'CONTAINS'; relatedSpdxElement = $id })
    $index++
}

$models = (Get-Content -LiteralPath $ModelsManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 30).models
$modelIndex = 1
foreach ($model in $models) {
    $id = "SPDXRef-ExternalModel-$modelIndex"
    $publisher = if ($model.PSObject.Properties['publisher'] -and $model.publisher) { [string]$model.publisher } else { 'NOASSERTION' }
    $relativePath = if ($model.PSObject.Properties['relativeTargetPath'] -and $model.relativeTargetPath) { [string]$model.relativeTargetPath } else { "models/$($model.targetDirectory)/$($model.fileName)" }
    $sourceKind = if ($model.PSObject.Properties['sourceKind'] -and $model.sourceKind) { [string]$model.sourceKind } else { 'external-payload-contract' }
    $infoSource = if ($model.PSObject.Properties['informationSource'] -and $model.informationSource) { [string]$model.informationSource } elseif ($model.PSObject.Properties['source'] -and $model.source) { [string]$model.source } else { 'NOASSERTION' }
    $comment = "NOT_CONTAINED_EXTERNAL_MODEL; publisher=$publisher; fileName=$($model.fileName); sizeBytes=$($model.sizeBytes); sha256=$($model.sha256); licenseStatus=$($model.license); relativeTargetPath=$relativePath; sourceKind=$sourceKind; informationSource=$infoSource"
    $packages.Add((New-SpdxPackage -Name ([string]$model.displayName) -Id $id -Version 'external' -Supplier ("Organization: " + $publisher) -License 'NOASSERTION' -Purpose 'OTHER' -Comment $comment -Sha256 ([string]$model.sha256)))
    $relationships.Add([ordered]@{ spdxElementId = $rootId; relationshipType = 'DEPENDS_ON'; relatedSpdxElement = $id })
    $modelIndex++
}

$sbom = [ordered]@{
    spdxVersion = 'SPDX-2.3'
    dataLicense = 'CC0-1.0'
    SPDXID = 'SPDXRef-DOCUMENT'
    name = "$PackageName-$PackageVersion"
    documentNamespace = "https://github.com/robertbackhaus-a11y/KI-Stack/sbom/$PackageVersion/$zipHash"
    creationInfo = [ordered]@{ created = '2000-01-01T00:00:00Z'; creators = @('Tool: KI-Stack deterministic SPDX generator') }
    documentDescribes = @($rootId)
    packages = @($packages)
    relationships = @($relationships)
    annotations = @([ordered]@{ annotationType = 'OTHER'; annotator = 'Tool: KI-Stack deterministic SPDX generator'; annotationDate = '2000-01-01T00:00:00Z'; comment = 'External models are dependencies only and are not contained in this release ZIP.' })
}

$json = $sbom | ConvertTo-Json -Depth 30
[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutputPath), $json + "`n", [System.Text.UTF8Encoding]::new($false))
[pscustomobject]@{ path = [System.IO.Path]::GetFullPath($OutputPath); zipSha256 = $zipHash; zipSizeBytes = $zip.Length; format = 'SPDX-2.3 JSON'; externalModels = $models.Count }

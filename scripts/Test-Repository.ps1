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

function Test-CmdCrLf {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    for ($i=0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 10 -and ($i -eq 0 -or $bytes[$i-1] -ne 13)) { return $false }
    }
    return $true
}

function Test-CompleteInstallerSbomReleaseContract {
    # Runs one real, local, source-only Complete Installer build into a disposable scratch
    # directory (never the repository's own tree, never the real target) and proves the
    # SBOM/release-pipeline contract end to end, so a future regression that drops the SBOM
    # generator call (as previously happened during the tools/-reorganization, fixed via
    # PR #49/#50) is caught here instead of only being discovered after publishing a release.
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $completeRoot = Join-Path $RepositoryRoot 'tools/complete-installer/current'
    $builder = Join-Path $completeRoot 'New-KIStackCompleteInstallerArchive.ps1'
    $version = (Get-Content -LiteralPath (Join-Path $completeRoot 'VERSION') -Raw).Trim()
    $scratchRoot = Join-Path ([IO.Path]::GetTempPath()) ('ki-stack-sbom-contract-' + [guid]::NewGuid().ToString('N'))
    $failures = [Collections.Generic.List[string]]::new()
    try {
        if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) { throw "Builder script missing: $builder" }
        New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null
        $result = & $builder -OutputDirectory $scratchRoot
        $zipPath = [string]$result.zip
        $sidecarPath = [string]$result.sidecar
        $sbomPath = [string]$result.sbom
        $expectedSbomName = "KI-Stack-Complete-Installer-v$version.spdx.json"
        if ([string]::IsNullOrWhiteSpace($zipPath) -or -not (Test-Path -LiteralPath $zipPath -PathType Leaf)) { $failures.Add("Build did not produce a ZIP: '$zipPath'") }
        if ([string]::IsNullOrWhiteSpace($sidecarPath) -or -not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) { $failures.Add("Build did not produce a SHA256 sidecar: '$sidecarPath'") }
        if ([string]::IsNullOrWhiteSpace($sbomPath) -or -not (Test-Path -LiteralPath $sbomPath -PathType Leaf)) {
            $failures.Add("Build did not produce an SBOM (SBOM generator call is missing or failed): '$sbomPath'")
        }
        elseif ([IO.Path]::GetFileName($sbomPath) -ne $expectedSbomName) {
            $failures.Add("SBOM filename contract violated: expected '$expectedSbomName', got '$([IO.Path]::GetFileName($sbomPath))'")
        }
        if ($failures.Count -eq 0) {
            $actualZipSha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $sidecarContent = (Get-Content -LiteralPath $sidecarPath -Raw).Trim()
            $sidecarSha256 = $null
            if ($sidecarContent -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
                $failures.Add("Sidecar has an unexpected format: '$sidecarContent'")
            }
            else {
                $sidecarSha256 = $Matches[1].ToLowerInvariant()
                if ($sidecarSha256 -ne $actualZipSha256) { $failures.Add("Sidecar SHA256 ($sidecarSha256) does not match the actual ZIP SHA256 ($actualZipSha256).") }
            }
            $sbomJson = $null
            try { $sbomJson = Get-Content -LiteralPath $sbomPath -Raw | ConvertFrom-Json -Depth 30 }
            catch { $failures.Add("SBOM is not valid JSON: $($_.Exception.Message)") }
            if ($null -ne $sbomJson) {
                if ([string]$sbomJson.spdxVersion -ne 'SPDX-2.3') { $failures.Add("spdxVersion is '$([string]$sbomJson.spdxVersion)', expected 'SPDX-2.3'.") }
                $rootPackages = @($sbomJson.packages | Where-Object { $_.SPDXID -eq 'SPDXRef-Package' })
                if ($rootPackages.Count -ne 1) {
                    $failures.Add("SBOM does not contain exactly one root package (SPDXRef-Package); found $($rootPackages.Count).")
                }
                else {
                    $rootChecksums = @($rootPackages[0].checksums | Where-Object { $_.algorithm -eq 'SHA256' })
                    if ($rootChecksums.Count -ne 1) {
                        $failures.Add('SBOM root package does not carry exactly one SHA256 checksum entry.')
                    }
                    else {
                        $rootSha256 = ([string]$rootChecksums[0].checksumValue).ToLowerInvariant()
                        if ($rootSha256 -ne $actualZipSha256) { $failures.Add("SBOM root package SHA256 ($rootSha256) does not match the actual ZIP SHA256 ($actualZipSha256).") }
                        if ($null -ne $sidecarSha256 -and $rootSha256 -ne $sidecarSha256) { $failures.Add("SBOM root package SHA256 ($rootSha256) does not match the sidecar SHA256 ($sidecarSha256).") }
                    }
                }
            }
        }
    }
    catch {
        $failures.Add("Build/validation threw: $($_.Exception.Message)")
    }
    finally {
        if (Test-Path -LiteralPath $scratchRoot) { Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
    [pscustomobject][ordered]@{ success = ($failures.Count -eq 0); failures = @($failures); version = $version }
}

$RootPath = [IO.Path]::GetFullPath($RootPath)
$Results = [Collections.Generic.List[object]]::new()
$excludedRelativePattern = '^(?:\.git|_import|dist)/|^tools/production-recovery/current/04-Evidence/'
function Test-RepositoryPathExcluded {
    param([Parameter(Mandatory)][string]$Path)
    [IO.Path]::GetRelativePath($RootPath,$Path).Replace('\','/') -match $excludedRelativePattern
}

try {
    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        throw "RootPath is not an existing directory: $RootPath"
    }
    $gitExecutable = (Get-Command git -ErrorAction Stop).Source
    $gitRoot = (& $gitExecutable -C $RootPath rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$gitRoot)) {
        throw "RootPath is not a Git checkout: $RootPath"
    }
    $gitRoot = [IO.Path]::GetFullPath(([string]$gitRoot).Trim())
    if (-not (Test-Path -LiteralPath (Join-Path $RootPath '.git'))) {
        throw "RootPath must expose the checkout's .git control path: $RootPath"
    }
    $gitTrackedFiles = @(
        & $gitExecutable -C $RootPath ls-files |
            ForEach-Object { ([string]$_).Replace('\','/') } |
            Where-Object { $_ -and $_ -notmatch $excludedRelativePattern } |
            Sort-Object -Unique
    )
    if ($LASTEXITCODE -ne 0 -or $gitTrackedFiles.Count -eq 0) {
        throw 'git ls-files returned no usable tracked repository inventory.'
    }
    $required = @(
        'README.md','README.de.md','CHANGELOG.md','VERSION','production-release-manifest.json',
        'scripts/Test-Repository.ps1','scripts/Test-TestRepositoryHarness.ps1',
        'scripts/Import-KIStackBuildPayload.ps1','scripts/Test-KIStackBuildPayloadImport.ps1',
        'scripts/Test-PowerShell7Starters.ps1',
        'docs/error-registry/REGRESSION-MATRIX.md',
        'tools/openwebui-agent-pack/current/VERSION',
        'tools/openwebui-agent-pack/current/MANIFEST.json',
        'tools/openwebui-agent-pack/current/Definitions/ki-stack-it-technik.json',
        'tools/openwebui-agent-pack/current/Definitions/ki-stack-allgemein.json',
        'tools/openwebui-agent-pack/current/OpenWebUIAgentPack.psm1',
        'tools/openwebui-agent-pack/current/Invoke-OpenWebUIAgentPack.ps1',
        'tools/openwebui-agent-pack/current/Test-OpenWebUIAgentPack.ps1',
        'tools/openwebui-visual-pack/current/MANIFEST.json',
        'tools/openwebui-visual-pack/current/Tool/ki-stack-generate-image.py',
        'tools/openwebui-visual-pack/current/Tool/ki-stack-generate-video.py',
        'tools/openwebui-visual-pack/current/Workflow/Z-Image-Turbo-OpenWebUI-API.json',
        'tools/openwebui-visual-pack/current/Workflow/WAN2.2-T2V-14B-OpenWebUI-API.json',
        'tools/openwebui-visual-pack/current/Test-KIStack-OpenWebUI-VisualPack-v2.0.5.ps1',
        'tools/openwebui-visual-pack/current/SHA256SUMS.txt'
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RootPath $_)) })
    Add-Result 'Required files' ($missing.Count -eq 0) ($(if($missing){$missing -join ', '}else{'complete'}))

    $expectedJson = @($gitTrackedFiles | Where-Object { [IO.Path]::GetExtension($_) -ieq '.json' })
    $jsonFiles = @($expectedJson | ForEach-Object { Get-Item -LiteralPath (Join-Path $RootPath $_) -ErrorAction Stop })
    $jsonErrors = @()
    foreach ($file in $jsonFiles) {
        try { Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 100 | Out-Null }
        catch { $jsonErrors += "$($file.FullName): $($_.Exception.Message)" }
    }
    Add-Result 'JSON integrity' ($jsonErrors.Count -eq 0) ($(if($jsonErrors){$jsonErrors -join '; '}else{"$($jsonFiles.Count) files parsed"}))

    $expectedPowerShell = @($gitTrackedFiles | Where-Object { [IO.Path]::GetExtension($_) -in '.ps1','.psm1' })
    $psFiles = @($expectedPowerShell | ForEach-Object { Get-Item -LiteralPath (Join-Path $RootPath $_) -ErrorAction Stop })
    $parseErrors = @()
    foreach ($file in $psFiles) {
        $tokens=$null; $errors=$null
        [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors) | Out-Null
        foreach($err in @($errors)){ $parseErrors += "$($file.FullName): $($err.Message)" }
    }
    Add-Result 'PowerShell parser' ($parseErrors.Count -eq 0) ($(if($parseErrors){$parseErrors -join '; '}else{"$($psFiles.Count) files parsed"}))

    $expectedCmd = @($gitTrackedFiles | Where-Object { [IO.Path]::GetExtension($_) -ieq '.cmd' })
    $cmdFiles = @($expectedCmd | ForEach-Object { Get-Item -LiteralPath (Join-Path $RootPath $_) -ErrorAction Stop })
    $badCmd = @($cmdFiles | Where-Object { -not (Test-CmdCrLf -Path $_.FullName) } | ForEach-Object FullName)
    $bomCmd = @($cmdFiles | Where-Object { $bytes=[IO.File]::ReadAllBytes($_.FullName); $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF } | ForEach-Object FullName)
    Add-Result 'CMD CRLF/BOM' ($badCmd.Count -eq 0 -and $bomCmd.Count -eq 0) ($(if($badCmd -or $bomCmd){'CRLF='+($badCmd -join ', ')+'; BOM='+($bomCmd -join ', ')}else{"$($cmdFiles.Count) files checked"}))
    $inventoryMinimum = [ordered]@{ json=100; powerShell=90; cmd=60 }
    $checkedJson = @($jsonFiles | ForEach-Object { [IO.Path]::GetRelativePath($RootPath,$_.FullName).Replace('\','/') } | Sort-Object)
    $checkedPowerShell = @($psFiles | ForEach-Object { [IO.Path]::GetRelativePath($RootPath,$_.FullName).Replace('\','/') } | Sort-Object)
    $checkedCmd = @($cmdFiles | ForEach-Object { [IO.Path]::GetRelativePath($RootPath,$_.FullName).Replace('\','/') } | Sort-Object)
    $inventoryMismatch = @(
        Compare-Object $expectedJson $checkedJson
        Compare-Object $expectedPowerShell $checkedPowerShell
        Compare-Object $expectedCmd $checkedCmd
    )
    $inventoryOk = (
        $jsonFiles.Count -ge $inventoryMinimum.json -and
        $psFiles.Count -ge $inventoryMinimum.powerShell -and
        $cmdFiles.Count -ge $inventoryMinimum.cmd -and
        $jsonFiles.Count -eq $expectedJson.Count -and
        $psFiles.Count -eq $expectedPowerShell.Count -and
        $cmdFiles.Count -eq $expectedCmd.Count -and
        $inventoryMismatch.Count -eq 0
    )
    Add-Result 'Repository file inventory' $inventoryOk (
        "source=git-ls-files; relativeToRootPath=true; " +
        "json=$($jsonFiles.Count)/tracked$($expectedJson.Count)/min$($inventoryMinimum.json); " +
        "powershell=$($psFiles.Count)/tracked$($expectedPowerShell.Count)/min$($inventoryMinimum.powerShell); " +
        "cmd=$($cmdFiles.Count)/tracked$($expectedCmd.Count)/min$($inventoryMinimum.cmd); " +
        "omitted=$($inventoryMismatch.Count)"
    )

    $buildRoots = @(
        'tools/comfyui/current',
        'tools/cutover-runtime/current',
        'tools/integration/current',
        'tools/models-workflows/current',
        'tools/openwebui-agent-pack/current',
        'tools/openwebui-ballistics-pack/current',
        'tools/openwebui-visual-pack/current',
        'tools/package-validation-gate/current',
        'tools/complete-installer/current'
    )
    $trackedLookup = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($path in $gitTrackedFiles) { [void]$trackedLookup.Add($path) }
    $untrackedBuildInputs = @(
        foreach ($buildRoot in $buildRoots) {
            $fullBuildRoot = Join-Path $RootPath $buildRoot
            if (-not (Test-Path -LiteralPath $fullBuildRoot -PathType Container)) {
                continue
            }
            foreach ($file in Get-ChildItem -LiteralPath $fullBuildRoot -Recurse -File -Force) {
                $relative = [IO.Path]::GetRelativePath($RootPath,$file.FullName).Replace('\','/')
                if (-not $trackedLookup.Contains($relative)) { $relative }
            }
        }
    )
    Add-Result 'Git tracked build inputs' ($untrackedBuildInputs.Count -eq 0) $(
        if ($untrackedBuildInputs) {
            'untracked build-root files: ' + (($untrackedBuildInputs | Sort-Object -Unique) -join ', ')
        }
        else {
            "trackedFiles=$($gitTrackedFiles.Count); buildRoots=$($buildRoots.Count); untrackedBuildInputs=0"
        }
    )

    # Authoritative sources for "does the documentation reflect reality": the active tools/*/current
    # source trees the Complete Installer actually builds from and pins (see
    # tools/complete-installer/current/Contracts/COMPONENTS.json and
    # tools/complete-installer/current/New-KIStackCompleteInstallerArchive.ps1). The separate,
    # long-frozen package/ + release-manifest.json + scripts/New-ReleaseArchive.ps1 Cutover-1.6.3
    # release track (and the schema-compatibility/version-consistency/enabled-modules/release-build-
    # contract/live-file-reference checks that used to validate it purely against itself) was
    # confirmed dead -- no active CI workflow, build, or attestation path ever consumed it -- and
    # has been removed outright rather than left to keep drifting from tools/cutover-runtime/current.
    $runtimeVersion = (Get-Content -LiteralPath (Join-Path $RootPath 'tools/cutover-runtime/current/VERSION') -Raw).Trim()
    $modelsVersion = (Get-Content -LiteralPath (Join-Path $RootPath 'tools/models-workflows/current/VERSION') -Raw).Trim()
    $completeComponentsForDocs = Get-Content -LiteralPath (Join-Path $RootPath 'tools/complete-installer/current/Contracts/COMPONENTS.json') -Raw | ConvertFrom-Json -Depth 30
    $applicationsVersion = [string]($completeComponentsForDocs.components | Where-Object id -eq 'applications').version
    $integrationVersion = (Get-Content -LiteralPath (Join-Path $RootPath 'tools/integration/current/VERSION') -Raw).Trim()
    $readmeEn = Get-Content -LiteralPath (Join-Path $RootPath 'README.md') -Raw
    $readmeDe = Get-Content -LiteralPath (Join-Path $RootPath 'README.de.md') -Raw
    $cutoverBuildReport = Get-Content -LiteralPath (Join-Path $RootPath 'tools/cutover-runtime/current/BUILD-REPORT.md') -Raw
    $documentationVersionsOk = (
        $readmeEn.Contains("| Models / Workflows | $modelsVersion |") -and
        $readmeEn.Contains("| Applications | $applicationsVersion |") -and
        $readmeEn.Contains("| Integration | $integrationVersion |") -and
        $readmeDe.Contains("| Modelle / Workflows | $modelsVersion |") -and
        $readmeDe.Contains("| Applications | $applicationsVersion |") -and
        $readmeDe.Contains("| Integration | $integrationVersion |") -and
        $cutoverBuildReport.Contains("KI-Stack Cutover v$runtimeVersion")
    )
    Add-Result 'Documentation version consistency' $documentationVersionsOk "runtime=$runtimeVersion; models=$modelsVersion; applications=$applicationsVersion; integration=$integrationVersion"

    $activeModelsRoot=Join-Path $RootPath 'tools/models-workflows/current'
    $activeManifest=Get-Content (Join-Path $activeModelsRoot 'Manifests/models.manifest.json') -Raw|ConvertFrom-Json -Depth 100
    $activePackageManifest=Get-Content (Join-Path $activeModelsRoot 'MANIFEST.json') -Raw|ConvertFrom-Json -Depth 20
    $activeWorkflows=@(Get-ChildItem (Join-Path $activeModelsRoot 'Workflows') -File -Filter '*.json')
    $allArtifacts=@($activeManifest.models)+@($activeManifest.lmStudio.files)
    $downloadContractsOk=(
        @($activeManifest.models).Count-eq9 -and
        [long]($activeManifest.models|Measure-Object sizeBytes -Sum).Sum-eq54994650267 -and
        $activeWorkflows.Count-eq2 -and
        @($activePackageManifest.publishedUiWorkflows).Count-eq0 -and
        @($activePackageManifest.internalApiPrompts).Count-eq2 -and
        @($allArtifacts|Where-Object{
            [string]$_.sha256-notmatch'^[0-9a-f]{64}$' -or
            [long]$_.sizeBytes-le0 -or
            @($_.sources).Count-lt1 -or
            @($_.sources|Where-Object{[string]$_-notmatch'^https://huggingface\.co/.+/resolve/[0-9a-f]{40}/'}).Count
        }).Count-eq0 -and
        @($activeManifest.models.fileName|Where-Object{$_-eq'Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf'}).Count-eq1
    )
    $modelImporterFilesOk=@(
        'tools/models-workflows/current/Import-KIStackExternalModels.ps1',
        'tools/models-workflows/current/Tests/Test-KIStackModelDownloadContract.ps1',
        'tools/models-workflows/current/Tests/TestRangeServer.ps1'
    )|ForEach-Object{Test-Path -LiteralPath (Join-Path $RootPath $_)}
    $downloadContractsOk=$downloadContractsOk-and($modelImporterFilesOk-notcontains$false)
    Add-Result 'Models / Workflows 2.0.3 Greenfield download contract' $downloadContractsOk "internalApiPrompts=$($activeWorkflows.Count); publishedUiWorkflows=$(@($activePackageManifest.publishedUiWorkflows).Count); visualModels=$(@($activeManifest.models).Count); artifacts=$($allArtifacts.Count); externalBytes=$([long]($activeManifest.models|Measure-Object sizeBytes -Sum).Sum)"

    $agentRoot = Join-Path $RootPath 'tools/openwebui-agent-pack/current'
    $agentVersion = (Get-Content -LiteralPath (Join-Path $agentRoot 'VERSION') -Raw).Trim()
    $agentManifest = Get-Content -LiteralPath (Join-Path $agentRoot 'MANIFEST.json') -Raw | ConvertFrom-Json -Depth 30
    $agentConfig = Get-Content -LiteralPath (Join-Path $agentRoot 'Config/agent-pack.config.json') -Raw | ConvertFrom-Json -Depth 30
    $agentDefinitions = @(Get-ChildItem -LiteralPath (Join-Path $agentRoot 'Definitions') -File -Filter '*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 30 })
    $agentIds = @($agentDefinitions.id | Sort-Object)
    $agentSchemaOk = (
        $agentVersion -eq '1.9.0' -and $agentManifest.version -eq $agentVersion -and $agentConfig.version -eq $agentVersion -and $agentManifest.status -eq 'StaticPendingValidation_TargetPending' -and
        ($agentIds -join '|') -eq 'ki-stack-allgemein|ki-stack-it-technik|ki-stack-research' -and
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

    $visualRoot = Join-Path $RootPath 'tools/openwebui-visual-pack/current'
    $visualManifest = Get-Content -LiteralPath (Join-Path $visualRoot 'MANIFEST.json') -Raw | ConvertFrom-Json -Depth 30
    $visualToolIds = @($visualManifest.managedTools.id | Sort-Object)
    $visualContractOk = (
        [string]$visualManifest.version -eq '2.0.5' -and
        ($visualToolIds -join '|') -eq 'ki_stack_generate_image|ki_stack_generate_video' -and
        [string]$visualManifest.properties.openWebUIFileItemContract -eq 'type=file,id,name,url,content_type,size,meta' -and
        [string]$visualManifest.properties.attachmentEvent -eq 'files' -and
        -not [bool]$visualManifest.properties.embedsUsedForMp4
    )
    Add-Result 'OpenWebUI Visual Pack contract' $visualContractOk "version=$($visualManifest.version); tools=$($visualToolIds -join ',')"
    $visualSumErrors = @()
    foreach ($line in Get-Content -LiteralPath (Join-Path $visualRoot 'SHA256SUMS.txt')) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') { $visualSumErrors += "Invalid line: $line"; continue }
        $target = Join-Path $visualRoot $Matches[2].Replace('/',[IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { $visualSumErrors += "Missing: $($Matches[2])"; continue }
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Matches[1].ToLowerInvariant()) { $visualSumErrors += "Mismatch: $($Matches[2])" }
    }
    Add-Result 'OpenWebUI Visual Pack SHA256' ($visualSumErrors.Count -eq 0) $(if($visualSumErrors){$visualSumErrors -join '; '}else{'all listed files verified'})

    $trackedFiles = @(Get-ChildItem -LiteralPath $RootPath -Recurse -File -Force |
        Where-Object {
            $relative=[IO.Path]::GetRelativePath($RootPath,$_.FullName).Replace('\','/')
            -not (Test-RepositoryPathExcluded $_.FullName) -and
            $relative -notmatch '^(?:_build|_validate)[^/]*/' -and
            $relative -notmatch '^tools/[^/]+/current/Payload/'
        } |
        ForEach-Object { [IO.Path]::GetRelativePath($RootPath,$_.FullName).Replace('\','/') })
    $forbiddenVisualArtifacts = @($trackedFiles | Where-Object {
        $_ -match '^(?:_import/|tools/openwebui-visual-pack/current/(?:backups?|history|output)/)' -or
        $_ -match '^tools/openwebui-visual-pack/current/.+\.(?:png|jpe?g|webp|gif|zip|pyc)$' -or
        $_ -match '^tools/openwebui-visual-pack/current/.*/__pycache__/'
    })
    Add-Result 'OpenWebUI Visual Pack repository artifacts' ($forbiddenVisualArtifacts.Count -eq 0) $(if($forbiddenVisualArtifacts){$forbiddenVisualArtifacts -join ', '}else{'no rendered media, archives, backups, bytecode or private import files present'})

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
        @{name='ComfyUI';root='tools/comfyui/current';version='1.2.4'},
        @{name='Integration';root='tools/integration/current';version='1.5.11'},
        @{name='Cutover Runtime';root='tools/cutover-runtime/current';version='1.6.14'},
        @{name='Complete Installer';root='tools/complete-installer/current';version='2.13.0'}
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
    $completeRequired=@('CompleteInstaller.psm1','Invoke-KIStackCompleteInstaller.ps1','Import-KIStackExternalModels.ps1','Start-KIStack-Model-Import.cmd','ExternalModels/README.md','Test-KIStackCompleteInstaller.ps1','Test-KIStackRequiredPayloads.ps1','New-KIStackCompleteInstallerArchive.ps1','Contracts/COMPONENTS.json','Contracts/PAYLOADS.json','Contracts/REQUIRED-PAYLOADS.json','Contracts/TRANSACTION.schema.json','Contracts/RESUME.schema.json','Contracts/ROLLBACK.md','Validation/VALIDATION-CONTRACT.json','Validation/REGRESSION-COVERAGE.json','Documentation/MODEL-CONTRACT.md','Documentation/MODELLVERTRAG.md','Start-KIStack-Installer.cmd','Start-KIStack-Audit.cmd','Start-KIStack-Repair.cmd','Start-KIStack-Validate.cmd','Start-KIStack-Rollback.cmd','Start-KIStack.cmd','Stop-KIStack.cmd')
    $completeMissing=@($completeRequired|Where-Object{-not(Test-Path (Join-Path $completeRoot $_))})
    Add-Result 'Complete Installer source completeness' ($completeMissing.Count-eq0) $(if($completeMissing){$completeMissing-join', '}else{'complete'})
    $completeComponents=Get-Content (Join-Path $completeRoot 'Contracts/COMPONENTS.json') -Raw|ConvertFrom-Json
    $completeVersionsOk=([string]($completeComponents.components|Where-Object id -eq 'comfyui').version -eq '1.2.4' -and [string]($completeComponents.components|Where-Object id -eq 'models-workflows').version -eq '2.0.3' -and [string]($completeComponents.components|Where-Object id -eq 'integration').version -eq '1.5.11'-and[string]($completeComponents.components|Where-Object id -eq 'cutover-runtime').version-eq'1.6.14'-and[string]($completeComponents.components|Where-Object id -eq 'openwebui-visual-pack').version-eq'2.0.5'-and[string]($completeComponents.components|Where-Object id -eq 'openwebui-ballistics-pack').version-eq'1.0.0'-and[string]($completeComponents.components|Where-Object id -eq 'openwebui-agent-pack').version-eq'1.9.0'-and[string]($completeComponents.components|Where-Object id -eq 'rag').version-eq'0.4.0')
    Add-Result 'Complete Installer component versions' $completeVersionsOk 'ComfyUI=1.2.4; Visual Models/Workflows=2.0.3; Integration=1.5.11; Cutover=1.6.14; Visual Pack=2.0.5; optional Ballistics=1.0.0; Agent Pack=1.9.0; RAG=0.4.0'
    $completeExecutable=Get-ChildItem $completeRoot -Recurse -File|Where-Object{$_.Extension-in'.ps1','.psm1','.cmd'-and$_.Name-ne'Test-KIStackCompleteInstaller.ps1'}|ForEach-Object{Get-Content $_.FullName -Raw}
    $forbiddenRuntime=('(?im)\b'+'git'+'\s+(?:cl'+'one|check'+'out|pu'+'ll|fetch|rev-parse|describe)\b|\.'+'git'+'(?:[/\\]|\b)|\bor'+'igin\b|comm'+'it[- ]hash|tr'+'ee[- ]hash')
    Add-Result 'Complete Installer Git-free runtime' (-not(($completeExecutable-join"`n")-match$forbiddenRuntime)) 'no Git acquisition or metadata dependency in executable sources'
    $forbiddenCompleteArtifacts=@($trackedFiles|Where-Object{$_-match'^(?:_import/|tools/(?:comfyui|integration|complete-installer)/.+\.(?:zip|pyc)$)'-or$_-match'/__pycache__/'})
    Add-Result 'Git-free package repository artifacts' ($forbiddenCompleteArtifacts.Count-eq0) $(if($forbiddenCompleteArtifacts){$forbiddenCompleteArtifacts-join', '}else{'no private imports, ZIPs or bytecode tracked'})

    $sbomContract = Test-CompleteInstallerSbomReleaseContract -RepositoryRoot $RootPath
    Add-Result 'Complete Installer SBOM/release pipeline contract' ([bool]$sbomContract.success) $(if($sbomContract.success){"version=$($sbomContract.version); ZIP/sidecar/SBOM root SHA256 consistent; spdxVersion=SPDX-2.3"}else{$sbomContract.failures -join '; '})

    $secretPatterns = @('ghp_[A-Za-z0-9]{20,}','github_pat_[A-Za-z0-9_]{20,}','AKIA[0-9A-Z]{16}','-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----','sk-[A-Za-z0-9]{20,}')
    $secretHits=@()
    $textFiles=Get-ChildItem -LiteralPath $RootPath -Recurse -File | Where-Object { $_.Length -lt 5MB -and $_.Extension -in '.ps1','.psm1','.cmd','.json','.yml','.yaml','.md','.txt' -and -not (Test-RepositoryPathExcluded $_.FullName) }
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

    try {
        $releaseAttestationReport = (& (Join-Path $RootPath 'scripts/Test-KIStackReleaseAttestationChaining.ps1') -RootPath $RootPath | ConvertFrom-Json)
        Add-Result 'Release attestation chaining contract' ([bool]$releaseAttestationReport.passed) $(if($releaseAttestationReport.passed){'automatic trigger, manual recovery, minimal permissions, fail-closed asset contract all verified'}else{($releaseAttestationReport.failures) -join '; '})
    }
    catch { Add-Result 'Release attestation chaining contract' $false $_.Exception.Message }

    try {
        $componentVersionRegistryReport = (& (Join-Path $RootPath 'tools/complete-installer/current/Test-KIStackComponentVersionRegistry.ps1') -PackageRoot (Join-Path $RootPath 'tools/complete-installer/current') | ConvertFrom-Json)
        Add-Result 'Component version registry contract' ([bool]$componentVersionRegistryReport.passed) $(if($componentVersionRegistryReport.passed){'SemVer comparison, resolver status coverage, published-version resolution and drift detection all verified'}else{($componentVersionRegistryReport.failures) -join '; '})
    }
    catch { Add-Result 'Component version registry contract' $false $_.Exception.Message }

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
    # This script is invoked two different ways: as the actual top-level process entry point
    # (GitHub Actions' "run: ./scripts/Test-Repository.ps1" step, and any direct
    # "pwsh -File" call), where pwsh propagates a still-set $LASTEXITCODE as the process's own
    # final exit code if nothing later overrides it -- and, in-process, via the call operator
    # (&) from scripts/Test-TestRepositoryHarness.ps1, where an "exit" statement here would
    # terminate that harness's entire host process outright instead of just returning control.
    # A real, reproduced defect on the first path: a validator earlier in this run
    # (Test-KIStackComponentVersionRegistry.ps1 -> Get-KIStackLatestPublishedCompleteInstallerRelease)
    # calls the native "gh" CLI and gracefully handles its failure (no GH_TOKEN in the plain
    # "Validate repository" CI job is the exact, real, reproduced case) -- but that native
    # command's own non-zero exit code was never required to be cleared by that caller, so it
    # can still be sitting in this shared, session-global $LASTEXITCODE right here even though
    # every one of this script's own checks passed. Resetting it explicitly, right before
    # falling off the end of this successful run (never via "exit", which is unsafe for the
    # second, in-process invocation path above), is what makes this script's own reported
    # "passed" result and the ACTUAL process exit code agree in every real invocation context --
    # never leaving that agreement to chance from whatever any native call anywhere in the
    # dependency tree happened to leave behind.
    $global:LASTEXITCODE = 0
    return
}
catch {
    [ordered]@{ testedAtUtc=[DateTime]::UtcNow.ToString('o'); root=$RootPath; passed=$false; fatalError=$_.Exception.Message; checks=$Results } | ConvertTo-Json -Depth 20
    throw
}

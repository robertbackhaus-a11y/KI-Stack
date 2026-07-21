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
        'scripts/Test-Repository.ps1','scripts/New-ReleaseArchive.ps1',
        'docs/error-registry/REGRESSION-MATRIX.md',
        'tools/openwebui-agent-pack/current/VERSION',
        'tools/openwebui-agent-pack/current/MANIFEST.json',
        'tools/openwebui-agent-pack/current/Definitions/ki-stack-it-technik.json',
        'tools/openwebui-agent-pack/current/Definitions/ki-stack-allgemein.json',
        'tools/openwebui-agent-pack/current/OpenWebUIAgentPack.psm1',
        'tools/openwebui-agent-pack/current/Invoke-OpenWebUIAgentPack.ps1',
        'tools/openwebui-agent-pack/current/Test-OpenWebUIAgentPack.ps1'
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
    $integrationVersion = [string](Get-Content -LiteralPath (Join-Path $RootPath 'package/Modules/07-Integration/module.json') -Raw | ConvertFrom-Json).version
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

    $agentRoot = Join-Path $RootPath 'tools/openwebui-agent-pack/current'
    $agentVersion = (Get-Content -LiteralPath (Join-Path $agentRoot 'VERSION') -Raw).Trim()
    $agentManifest = Get-Content -LiteralPath (Join-Path $agentRoot 'MANIFEST.json') -Raw | ConvertFrom-Json -Depth 30
    $agentConfig = Get-Content -LiteralPath (Join-Path $agentRoot 'Config/agent-pack.config.json') -Raw | ConvertFrom-Json -Depth 30
    $agentDefinitions = @(Get-ChildItem -LiteralPath (Join-Path $agentRoot 'Definitions') -File -Filter '*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 30 })
    $agentIds = @($agentDefinitions.id | Sort-Object)
    $agentSchemaOk = (
        $agentVersion -eq '1.8.1' -and $agentManifest.version -eq $agentVersion -and $agentConfig.version -eq $agentVersion -and
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

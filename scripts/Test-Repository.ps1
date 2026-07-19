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

$RootPath = [IO.Path]::GetFullPath($RootPath)
$Results = [Collections.Generic.List[object]]::new()

try {
    $required = @(
        'README.md','README.de.md','CHANGELOG.md','VERSION','release-manifest.json',
        'package/Config/kernel-config.json','package/Tests/Test-KIStackBuilderKernel.ps1',
        'scripts/Test-Repository.ps1','scripts/New-ReleaseArchive.ps1',
        'docs/error-registry/REGRESSION-MATRIX.md'
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RootPath $_)) })
    Add-Result 'Required files' ($missing.Count -eq 0) ($(if($missing){$missing -join ', '}else{'complete'}))

    $jsonFiles = @(Get-ChildItem -LiteralPath $RootPath -Recurse -File -Filter '*.json' | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })
    $jsonErrors = @()
    foreach ($file in $jsonFiles) {
        try { Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 100 | Out-Null }
        catch { $jsonErrors += "$($file.FullName): $($_.Exception.Message)" }
    }
    Add-Result 'JSON integrity' ($jsonErrors.Count -eq 0) ($(if($jsonErrors){$jsonErrors -join '; '}else{"$($jsonFiles.Count) files parsed"}))

    $psFiles = @(Get-ChildItem -LiteralPath $RootPath -Recurse -File | Where-Object { $_.Extension -in '.ps1','.psm1' -and $_.FullName -notmatch '[\\/]\.git[\\/]' })
    $parseErrors = @()
    foreach ($file in $psFiles) {
        $tokens=$null; $errors=$null
        [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors) | Out-Null
        foreach($err in @($errors)){ $parseErrors += "$($file.FullName): $($err.Message)" }
    }
    Add-Result 'PowerShell parser' ($parseErrors.Count -eq 0) ($(if($parseErrors){$parseErrors -join '; '}else{"$($psFiles.Count) files parsed"}))

    $cmdFiles = @(Get-ChildItem -LiteralPath $RootPath -Recurse -File -Filter '*.cmd' | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })
    $badCmd = @($cmdFiles | Where-Object { -not (Test-CmdCrLf -Path $_.FullName) } | ForEach-Object FullName)
    $bomCmd = @($cmdFiles | Where-Object { $bytes=[IO.File]::ReadAllBytes($_.FullName); $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF } | ForEach-Object FullName)
    Add-Result 'CMD CRLF/BOM' ($badCmd.Count -eq 0 -and $bomCmd.Count -eq 0) ($(if($badCmd -or $bomCmd){'CRLF='+($badCmd -join ', ')+'; BOM='+($bomCmd -join ', ')}else{"$($cmdFiles.Count) files checked"}))

    $manifestPath = Join-Path $RootPath 'release-manifest.json'
    $configPath = Join-Path $RootPath 'package/Config/kernel-config.json'
    if ((Test-Path $manifestPath) -and (Test-Path $configPath)) {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json -Depth 100
        $config = Get-Content $configPath -Raw | ConvertFrom-Json -Depth 100
        $versionsOk = ([string]$manifest.packageVersion -eq [string]$config.kernelVersion) -and ([string]$manifest.releaseId -eq [string]$config.executeRelease.releaseId)
        Add-Result 'Version consistency' $versionsOk "manifest=$($manifest.packageVersion)/$($manifest.releaseId); config=$($config.kernelVersion)/$($config.executeRelease.releaseId)"
        $enabledA=@($manifest.enabledModules | Sort-Object); $enabledB=@($config.executeRelease.enabledModules | Sort-Object)
        $modulesOk = (($enabledA -join '|') -eq ($enabledB -join '|'))
        Add-Result 'Enabled modules' $modulesOk "manifest=$($enabledA -join ','); config=$($enabledB -join ',')"
    }

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
    $textFiles=Get-ChildItem -LiteralPath $RootPath -Recurse -File | Where-Object { $_.Length -lt 5MB -and $_.Extension -in '.ps1','.psm1','.cmd','.json','.yml','.yaml','.md','.txt' -and $_.FullName -notmatch '[\\/]\.git[\\/]' }
    foreach($file in $textFiles){
        $text=Get-Content -LiteralPath $file.FullName -Raw
        foreach($pattern in $secretPatterns){ if($text -match $pattern){$secretHits += "$($file.FullName): $pattern"} }
    }
    Add-Result 'High-confidence secret scan' ($secretHits.Count -eq 0) ($(if($secretHits){$secretHits -join '; '}else{'no credential patterns found'}))

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

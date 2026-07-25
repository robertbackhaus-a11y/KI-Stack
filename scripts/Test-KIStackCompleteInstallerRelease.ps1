[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Test-ShaContract {
    param([Parameter(Mandatory)][string]$Root)
    $sumPath = Join-Path $Root 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $sumPath -PathType Leaf)) {
        throw "SHA256SUMS.txt missing: $Root"
    }
    $checked = 0
    foreach ($line in Get-Content -LiteralPath $sumPath) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
            throw "Invalid SHA256 line in ${sumPath}: $line"
        }
        $file = Join-Path $Root $Matches[2].Replace('/',[IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "SHA256 contract file missing: $file"
        }
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $Matches[1].ToLowerInvariant()) {
            throw "SHA256 mismatch: $file"
        }
        $checked++
    }
    $checked
}

function Invoke-PackageSelfTest {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$PackageRoot
    )
    $parameters = @(Get-Command $Script).Parameters.Keys
    Push-Location $PackageRoot
    try {
        if ($parameters -contains 'PackageRoot') {
            @(& $Script -PackageRoot $PackageRoot)
        }
        elseif ($parameters -contains 'Root') {
            @(& $Script -Root $PackageRoot)
        }
        else {
            @(& $Script)
        }
    }
    finally {
        Pop-Location
    }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ki-stack-complete-validation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    Expand-Archive -LiteralPath $PackagePath -DestinationPath $tempRoot
    $packageRoot = Get-ChildItem -LiteralPath $tempRoot -Directory | Select-Object -First 1
    if ($null -eq $packageRoot) { throw 'Package root missing after extraction.' }

    $checksumResults = @(
        [pscustomobject]@{ scope='complete'; entries=(Test-ShaContract -Root $packageRoot.FullName) }
    )
    $payloadRoots = @{}
    foreach ($payloadArchive in Get-ChildItem -LiteralPath (Join-Path $packageRoot.FullName 'Payload') -Recurse -File -Filter '*.zip') {
        $payloadName = Split-Path (Split-Path $payloadArchive.FullName -Parent) -Leaf
        $payloadDestination = Join-Path $tempRoot ('payload-' + $payloadName)
        Expand-Archive -LiteralPath $payloadArchive.FullName -DestinationPath $payloadDestination
        $directories = @(Get-ChildItem -LiteralPath $payloadDestination -Directory)
        $files = @(Get-ChildItem -LiteralPath $payloadDestination -File)
        $payloadRoot = if ($directories.Count -eq 1 -and $files.Count -eq 0) {
            $directories[0].FullName
        } else {
            $payloadDestination
        }
        $payloadRoots[$payloadName] = $payloadRoot
        $checksumResults += [pscustomobject]@{
            scope = $payloadName
            entries = Test-ShaContract -Root $payloadRoot
        }
    }

    $completeOutput = Invoke-PackageSelfTest `
        -Script (Join-Path $packageRoot.FullName 'Test-KIStackCompleteInstaller.ps1') `
        -PackageRoot $packageRoot.FullName
    $completeResult = (($completeOutput -join [Environment]::NewLine) | ConvertFrom-Json)
    if (-not $completeResult.passed) { throw 'Complete Installer self-test failed.' }

    $testMap = [ordered]@{
        ModelsWorkflows = 'Test-KIStackVisualModels.ps1'
        OpenWebUIVisualPack = 'Test-KIStack-OpenWebUI-VisualPack-v2.0.5-rc2.ps1'
        ComfyUI = 'Test-KIStackComfyUI.ps1'
        Integration = 'Test-KIStackIntegration.ps1'
        OpenWebUIAgentPack = 'Test-OpenWebUIAgentPack.ps1'
        OpenWebUIBallisticsPack = 'Test-OpenWebUIBallisticsPack.ps1'
        ValidationGate = 'Test-KIStack-Universal-ValidationGate.ps1'
    }
    $payloadTests = @()
    foreach ($payloadName in $testMap.Keys) {
        $payloadRoot = [string]$payloadRoots[$payloadName]
        $test = Get-ChildItem -LiteralPath $payloadRoot -Recurse -File -Filter $testMap[$payloadName] |
            Select-Object -First 1
        if ($null -eq $test) { throw "Payload self-test missing: $payloadName" }
        $output = Invoke-PackageSelfTest -Script $test.FullName -PackageRoot $payloadRoot
        $payloadTests += [pscustomobject]@{
            payload = $payloadName
            passed = $true
            output = (($output -join [Environment]::NewLine).Trim())
        }
    }

    $powerShellCount = 0
    foreach ($file in Get-ChildItem -LiteralPath $packageRoot.FullName -Recurse -File |
        Where-Object { $_.Extension -in '.ps1','.psm1' }) {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $file.FullName,
            [ref]$tokens,
            [ref]$errors
        )
        if (@($errors).Count -gt 0) {
            throw "PowerShell parser failure in $($file.FullName): $(@($errors).Message -join '; ')"
        }
        $powerShellCount++
    }

    $jsonCount = 0
    foreach ($file in Get-ChildItem -LiteralPath $packageRoot.FullName -Recurse -File -Filter '*.json') {
        try {
            $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 100
        }
        catch {
            throw "JSON parser failure in $($file.FullName): $($_.Exception.Message)"
        }
        $jsonCount++
    }

    $cmdCount = 0
    foreach ($file in Get-ChildItem -LiteralPath $packageRoot.FullName -Recurse -File -Filter '*.cmd') {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ([string]::IsNullOrWhiteSpace($text) -or $text -notmatch '(?i)(pwsh|powershell|cmd|wsl|start)') {
            throw "CMD starter contract invalid: $($file.FullName)"
        }
        $cmdCount++
    }

    Import-Module (Join-Path $packageRoot.FullName 'CompleteInstaller.psm1') -Force
    $componentContract = Get-Content `
        -LiteralPath (Join-Path $packageRoot.FullName 'Contracts\COMPONENTS.json') `
        -Raw | ConvertFrom-Json
    $fixture = @{}
    foreach ($component in $componentContract.components) {
        $isOptional = $component.PSObject.Properties.Name -contains 'optional' -and [bool]$component.optional
        if (-not $isOptional) {
            $fixture[[string]$component.id] = [string]$component.version
        }
    }
    $fixtureTarget = Join-Path $tempRoot 'isolated-fixture-target'
    $plan = New-KICompletePlan `
        -Mode Upgrade `
        -PackageRoot $packageRoot.FullName `
        -TargetRoot $fixtureTarget `
        -FixtureState $fixture
    $transaction = New-KICompleteTransaction `
        -Plan $plan `
        -StateDirectory (Join-Path $tempRoot 'resume-state') `
        -TransactionId 'fixture-resume'
    $resume = Get-Content -LiteralPath $transaction.resumePath -Raw | ConvertFrom-Json
    if ($resume.transactionId -ne 'fixture-resume' -or $resume.nextStep -ne 0 -or $resume.containsSecrets) {
        throw 'Resume fixture failed.'
    }
    $automaticTransaction = New-KICompleteTransaction `
        -Plan $plan `
        -StateDirectory (Join-Path $tempRoot 'automatic-transaction-state')
    if (
        [string]::IsNullOrWhiteSpace([string]$automaticTransaction.transaction.transactionId) -or
        [string]::IsNullOrWhiteSpace([string]$automaticTransaction.path) -or
        -not (Test-Path -LiteralPath $automaticTransaction.path -PathType Leaf) -or
        (Split-Path -Leaf (Split-Path -Parent $automaticTransaction.path)) -ne
            [string]$automaticTransaction.transaction.transactionId
    ) {
        throw 'Automatic transaction-id fixture failed.'
    }

    $rollbackTarget = Join-Path $tempRoot 'rollback-fixture'
    $rollbackState = Join-Path $rollbackTarget 'state\complete-installer'
    $rollbackBackup = Join-Path $tempRoot 'rollback-backup.json'
    New-Item -ItemType Directory -Path $rollbackState -Force | Out-Null
    [IO.File]::WriteAllText(
        $rollbackBackup,
        '{"schemaVersion":"1.0","runValues":[],"desktopLinks":[],"systemdUnits":[],"dockerContainers":[],"changes":[]}',
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $rollbackState 'operations-latest.json'),
        (@{schemaVersion='1.0';backupPath=$rollbackBackup} | ConvertTo-Json -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    $rollback = Restore-KICompleteOperations -TargetRoot $rollbackTarget
    if (-not $rollback.restored -or $rollback.status -ne 'OperationsRestored') {
        throw 'Rollback fixture failed.'
    }

    $comfyRoot = [string]$payloadRoots.ComfyUI
    $contentManifest = Get-Content `
        -LiteralPath (Join-Path $comfyRoot 'Payload\CONTENT-MANIFEST.json') `
        -Raw | ConvertFrom-Json
    $innerPayload = Get-ChildItem -LiteralPath (Join-Path $comfyRoot 'Payload') -File -Filter '*.zip' |
        Select-Object -First 1
    $innerArchive = [IO.Compression.ZipFile]::OpenRead($innerPayload.FullName)
    try {
        $entryIndex = @{}
        foreach ($entry in $innerArchive.Entries) {
            if ($entry.Name) { $entryIndex[$entry.FullName.Replace('\','/')] = $entry }
        }
        $contentChecked = 0
        foreach ($contractEntry in $contentManifest.files) {
            $entry = $entryIndex[[string]$contractEntry.path]
            if ($null -eq $entry) { throw "ComfyUI content missing: $($contractEntry.path)" }
            $stream = $entry.Open()
            try {
                $algorithm = [Security.Cryptography.SHA256]::Create()
                try {
                    $actual = [Convert]::ToHexString($algorithm.ComputeHash($stream)).ToLowerInvariant()
                }
                finally { $algorithm.Dispose() }
            }
            finally { $stream.Dispose() }
            if ($actual -ne [string]$contractEntry.sha256) {
                throw "ComfyUI content SHA256 mismatch: $($contractEntry.path)"
            }
            $contentChecked++
        }
    }
    finally { $innerArchive.Dispose() }

    [pscustomobject][ordered]@{
        package = $completeResult
        internalChecksums = $checksumResults
        payloadTests = $payloadTests
        powerShellFilesParsed = $powerShellCount
        jsonFilesParsed = $jsonCount
        cmdContracts = $cmdCount
        resumeFixture = $true
        rollbackFixture = $true
        comfyContentEntries = $contentChecked
        targetSystemAccessed = $false
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

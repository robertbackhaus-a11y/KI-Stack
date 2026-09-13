[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Direct, isolated tests of the REAL Test-KICompleteMcpRuntimePayloadParity (CompleteInstaller.psm1)
# -- imported and called as-is, never copied or reimplemented. Builds real Payload/McpRuntime/*.zip
# archives (this test's own throwaway ones, under a scratch installer root -- NEVER the real
# tools/complete-installer/current/Payload, and never left in the working tree) plus real deployed
# tools/mcp-runtime/current-shaped target directories, mirroring
# Test-KIStackMcpRuntimeCompleteInstallerIntegration.ps1's own real-zip style.

Import-Module (Join-Path $PackageRoot 'CompleteInstaller.psm1') -Force
$mcpRuntimeSourceRoot = [IO.Path]::GetFullPath((Join-Path $PackageRoot '..\..\mcp-runtime\current'))
Import-Module (Join-Path $mcpRuntimeSourceRoot 'McpRuntime.psm1') -Force

$fail = [Collections.Generic.List[string]]::new()
$checks = [ordered]@{}
$scratchBase = Join-Path ([IO.Path]::GetTempPath()) ('KIMRParity-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $scratchBase -Force | Out-Null

function New-KIMRParityZip {
    param([Parameter(Mandatory)][string]$SourceDir, [Parameter(Mandatory)][string]$ZipPath)
    New-Item -ItemType Directory -Path (Split-Path -Parent $ZipPath) -Force | Out-Null
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::Open($ZipPath, [IO.FileMode]::CreateNew)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $sep = [IO.Path]::DirectorySeparatorChar
            foreach ($file in Get-ChildItem -LiteralPath $SourceDir -Recurse -File) {
                $relative = ([IO.Path]::GetRelativePath($SourceDir, $file.FullName)).Replace($sep, [char]47)
                $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Fastest)
                $in = [IO.File]::OpenRead($file.FullName)
                $out = $entry.Open()
                try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

function Sync-KIMRParitySums {
    # Re-syncs a scratch copy's own SHA256SUMS.txt so mutation tests prove CROSS-TREE
    # (installer-payload vs. deployed-target) drift detection, never a corrupt-source scenario.
    param([Parameter(Mandatory)][string]$Root)
    $sumsPath = Join-Path $Root 'SHA256SUMS.txt'
    $lines = Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | Sort-Object FullName | ForEach-Object {
        $rel = ($_.FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/')
        "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) *$rel"
    }
    [IO.File]::WriteAllLines($sumsPath, $lines, [Text.UTF8Encoding]::new($false))
}

function New-KIMRParitySourceCopy {
    param([Parameter(Mandatory)][string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $mcpRuntimeSourceRoot -Force | Where-Object { $_.Name -ne 'Payload' } |
        Copy-Item -Destination $Destination -Recurse -Force
    Sync-KIMRParitySums -Root $Destination
    $Destination
}

try {
    $sourceDir = New-KIMRParitySourceCopy -Destination (Join-Path $scratchBase 'source')

    $installerRootA = Join-Path $scratchBase 'installer-a'
    New-KIMRParityZip -SourceDir $sourceDir -ZipPath (Join-Path $installerRootA 'Payload/McpRuntime/McpRuntime.zip')
    $deployedA = Join-Path $scratchBase 'deployed-a'
    Copy-Item -LiteralPath $sourceDir -Destination $deployedA -Recurse -Force

    # === A: installer payload == deployed current\ -> parity = true ===========================
    $checks.a_identicalPayloadAndDeployIsCompliant = [ordered]@{
        parity = [bool](Test-KICompleteMcpRuntimePayloadParity -PackageRoot $installerRootA -DeployedPackageRoot $deployedA)
    }
    if (-not [bool]$checks.a_identicalPayloadAndDeployIsCompliant.parity) { $fail.Add('a_identicalPayloadAndDeployIsCompliant failed: expected true') }

    # === B: one productive file in the INSTALLER PAYLOAD changed -> parity = false =============
    $sourceDirB = Join-Path $scratchBase 'source-b'
    Copy-Item -LiteralPath $sourceDir -Destination $sourceDirB -Recurse -Force
    Add-Content -LiteralPath (Join-Path $sourceDirB 'McpRuntime.psm1') -Value "# mutation-$([guid]::NewGuid().ToString('N'))" -Encoding utf8
    Sync-KIMRParitySums -Root $sourceDirB
    $installerRootB = Join-Path $scratchBase 'installer-b'
    New-KIMRParityZip -SourceDir $sourceDirB -ZipPath (Join-Path $installerRootB 'Payload/McpRuntime/McpRuntime.zip')
    $checks.b_changedProductiveFileInPayloadIsNonCompliant = [ordered]@{
        parity = [bool](Test-KICompleteMcpRuntimePayloadParity -PackageRoot $installerRootB -DeployedPackageRoot $deployedA)
    }
    if ([bool]$checks.b_changedProductiveFileInPayloadIsNonCompliant.parity) { $fail.Add('b_changedProductiveFileInPayloadIsNonCompliant failed: expected false') }

    # === C: a file is MISSING from the deployed target -> parity = false =======================
    $deployedC = Join-Path $scratchBase 'deployed-c'
    Copy-Item -LiteralPath $sourceDir -Destination $deployedC -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $deployedC 'Scripts/ki_desktop_control_tools.py') -Force
    $checks.c_missingTargetFileIsNonCompliant = [ordered]@{
        parity = [bool](Test-KICompleteMcpRuntimePayloadParity -PackageRoot $installerRootA -DeployedPackageRoot $deployedC)
    }
    if ([bool]$checks.c_missingTargetFileIsNonCompliant.parity) { $fail.Add('c_missingTargetFileIsNonCompliant failed: expected false') }

    # === D: an EXTRA, unexpected file exists in the deployed target -> parity = false ===========
    $deployedD = Join-Path $scratchBase 'deployed-d'
    Copy-Item -LiteralPath $sourceDir -Destination $deployedD -Recurse -Force
    Set-Content -LiteralPath (Join-Path $deployedD 'Scripts/unexpected-leftover.py') -Value '# leftover, must be dropped' -Encoding utf8
    $checks.d_extraTargetFileIsNonCompliant = [ordered]@{
        parity = [bool](Test-KICompleteMcpRuntimePayloadParity -PackageRoot $installerRootA -DeployedPackageRoot $deployedD)
    }
    if ([bool]$checks.d_extraTargetFileIsNonCompliant.parity) { $fail.Add('d_extraTargetFileIsNonCompliant failed: expected false') }

    # === E: VERSION differs between installer payload and the deployed target ==================
    # E1: Test-KICompleteMcpRuntimePayloadParity ALONE already reports false for this drift --
    #     VERSION is just another compared file, so a content mismatch there is caught by the
    #     exact same byte-for-byte mechanism as B.
    $sourceDirE = Join-Path $scratchBase 'source-e'
    Copy-Item -LiteralPath $sourceDir -Destination $sourceDirE -Recurse -Force
    Set-Content -LiteralPath (Join-Path $sourceDirE 'VERSION') -Value '9.9.9' -Encoding ascii -NoNewline
    $cfgPath = Join-Path $sourceDirE 'Config/mcp-runtime.config.json'
    $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
    $cfg.version = '9.9.9'
    ($cfg | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $cfgPath -Encoding utf8
    Sync-KIMRParitySums -Root $sourceDirE
    $installerRootE = Join-Path $scratchBase 'installer-e'
    New-KIMRParityZip -SourceDir $sourceDirE -ZipPath (Join-Path $installerRootE 'Payload/McpRuntime/McpRuntime.zip')
    $checks.e1_versionDriftAloneMakesPayloadParityFalse = [ordered]@{
        parity = [bool](Test-KICompleteMcpRuntimePayloadParity -PackageRoot $installerRootE -DeployedPackageRoot $deployedA)
    }
    if ([bool]$checks.e1_versionDriftAloneMakesPayloadParityFalse.parity) { $fail.Add('e1_versionDriftAloneMakesPayloadParityFalse failed: expected false') }

    # E2: the REAL, full contract (Test-KICompleteMcpRuntimeCompliant) -- a target genuinely
    # deployed at version 9.9.9 (self-consistent: source VERSION == config version, real
    # Install-KIMcpRuntime run, real lifecycle bookkeeping) must be reported non-compliant when
    # asked about a DIFFERENT expected version, and compliant when asked about its own actual
    # version -- the version-string gate runs before any payload/hash parity check at all.
    $targetRootE = Join-Path $scratchBase 'target-e'
    $installE = Install-KIMcpRuntime -PackageRoot $sourceDirE -TargetRoot $targetRootE -Action Install -SkipUvCheck
    $checks.e2_realContractVersionGate = [ordered]@{
        installOfTheDriftedSourceSucceededAtItsOwnVersion = [bool]$installE.passed
        complianceAgainstWrongExpectedVersionIsFalse = (-not [bool](Test-KICompleteMcpRuntimeCompliant -TargetRoot $targetRootE -ExpectedComponentVersion '0.1.0'))
        complianceAgainstItsOwnActualVersionIsTrue = [bool](Test-KICompleteMcpRuntimeCompliant -TargetRoot $targetRootE -ExpectedComponentVersion '9.9.9')
        complianceWithInstallerPackageRootAndWrongVersionStillFalse = (-not [bool](Test-KICompleteMcpRuntimeCompliant -TargetRoot $targetRootE -ExpectedComponentVersion '0.1.0' -InstallerPackageRoot $installerRootE))
    }
    if ($checks.e2_realContractVersionGate.Values -contains $false) { $fail.Add('e2_realContractVersionGate failed: ' + ($checks.e2_realContractVersionGate | ConvertTo-Json -Compress)) }

    $passed = $fail.Count -eq 0
    [pscustomobject]@{ passed = $passed; checks = $checks; failures = @($fail) } | ConvertTo-Json -Depth 12
    if (-not $passed) { throw 'MCP-Runtime-Payload-Parity-Regression fehlgeschlagen.' }
} finally {
    try { Remove-Item -LiteralPath $scratchBase -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

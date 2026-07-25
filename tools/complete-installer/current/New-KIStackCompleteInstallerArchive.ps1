[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'dist\complete-installer'),
    [string]$BuildCacheDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
$packageName = "KI-Stack-Complete-Installer-v$version"
$epoch = [DateTimeOffset]::Parse('2000-01-01T00:00:00Z')

function Update-SourceChecksums {
    param([Parameter(Mandatory)][string]$SourceRoot)
    $sumPath = Join-Path $SourceRoot 'SHA256SUMS.txt'
    $lines = Get-ChildItem -LiteralPath $SourceRoot -Recurse -File |
        Where-Object { $_.FullName -ne $sumPath } |
        Sort-Object { [IO.Path]::GetRelativePath($SourceRoot,$_.FullName).Replace('\','/') } |
        ForEach-Object {
            $relative = [IO.Path]::GetRelativePath($SourceRoot,$_.FullName).Replace('\','/')
            "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) *$relative"
        }
    [IO.File]::WriteAllLines($sumPath,$lines,[Text.ASCIIEncoding]::new())
}

function New-DeterministicArchive {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$Destination,
        [string]$ArchiveRoot
    )
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }
    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::Open($Destination,[IO.FileMode]::CreateNew)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
        try {
            foreach ($file in Get-ChildItem -LiteralPath $SourceRoot -Recurse -File |
                Sort-Object { [IO.Path]::GetRelativePath($SourceRoot,$_.FullName).Replace('\','/') }) {
                $relative = [IO.Path]::GetRelativePath($SourceRoot,$file.FullName).Replace('\','/')
                $entryName = if ([string]::IsNullOrWhiteSpace($ArchiveRoot)) {
                    $relative
                } else {
                    "$ArchiveRoot/$relative"
                }
                $entry = $archive.CreateEntry($entryName,[IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $epoch
                $input = [IO.File]::OpenRead($file.FullName)
                $output = $entry.Open()
                try { $input.CopyTo($output) }
                finally { $output.Dispose(); $input.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Initialize-GeneratedBuildPayloads {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$StateRoot
    )
    if ($Key -in @('ComfyUI','Integration')) {
        $contract = Join-Path $SourceRoot 'Payload\PAYLOAD-CONTRACT.json'
        $arguments=@{
            ContractPath=$contract
            OutputDirectory=(Join-Path $SourceRoot 'Payload')
            StateDirectory=(Join-Path $StateRoot $Key)
        }
        if($BuildCacheDirectory){$arguments.CacheDirectory=$BuildCacheDirectory}
        $result=& (Join-Path $repositoryRoot 'scripts\Import-KIStackBuildPayload.ps1') @arguments
        if(-not[bool]$result.passed){throw "Build payload $Key is $($result.status): $($result.message)"}
    }
}

$payloadDefinitions = @(
    [ordered]@{ key='ComfyUI'; source='tools/comfyui/current'; file='KI-Stack-ComfyUI-Execute-v1.2.4.zip'; root=$null },
    [ordered]@{ key='CutoverRuntime'; source='tools/cutover-runtime/current'; file='KI-Stack-Cutover-Execute-v1.6.4-core.zip'; root='KI-Stack-Cutover-Execute-v1.6.4' },
    [ordered]@{ key='Integration'; source='tools/integration/current'; file='KI-Stack-Integration-Execute-v1.5.10.zip'; root=$null },
    [ordered]@{ key='ModelsWorkflows'; source='tools/models-workflows/current'; file='KI-Stack-Visual-Models-Workflows-v2.0.1.zip'; root='KI-Stack-Visual-Models-Workflows-v2.0.1' },
    [ordered]@{ key='OpenWebUIAgentPack'; source='tools/openwebui-agent-pack/current'; file='KI-Stack-OpenWebUI-Agent-Pack-v1.8.6.zip'; root=$null },
    [ordered]@{ key='OpenWebUIBallisticsPack'; source='tools/openwebui-ballistics-pack/current'; file='KI-Stack-OpenWebUI-Ballistics-Pack-v1.0.0.zip'; root='KI-Stack-OpenWebUI-Ballistics-Pack-v1.0.0' },
    [ordered]@{ key='OpenWebUIVisualPack'; source='tools/openwebui-visual-pack/current'; file='KI-Stack-OpenWebUI-Visual-Pack-v2.0.5-rc2.zip'; root='KI-Stack-OpenWebUI-Visual-Pack-v2.0.5-rc2' },
    [ordered]@{ key='ValidationGate'; source='tools/package-validation-gate/current'; file='KI-Stack-Universal-Package-Validation-Gate-v1.0.3.zip'; root='KI-Stack-Universal-Package-Validation-Gate-v1.0.3' }
)

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ki-stack-complete-build-' + [guid]::NewGuid().ToString('N'))
$payloadRoot = Join-Path $tempRoot 'payloads'
$stage = Join-Path $tempRoot $packageName
New-Item -ItemType Directory -Path $payloadRoot,$stage -Force | Out-Null
try {
    foreach ($definition in $payloadDefinitions) {
        $source = Join-Path $repositoryRoot $definition.source
        if (-not (Test-Path -LiteralPath $source -PathType Container)) {
            throw "Payload source missing: $($definition.source)"
        }
        $buildSource = Join-Path $tempRoot ('source-' + $definition.key)
        Copy-Item -LiteralPath $source -Destination $buildSource -Recurse -Force
        Get-ChildItem -LiteralPath $buildSource -Recurse -File -Filter '*.zip' -ErrorAction SilentlyContinue |
            Remove-Item -Force
        Initialize-GeneratedBuildPayloads -Key $definition.key -SourceRoot $buildSource -StateRoot (Join-Path $tempRoot 'download-state')
        Update-SourceChecksums -SourceRoot $buildSource
        $payloadArchive = Join-Path $payloadRoot $definition.file
        New-DeterministicArchive -SourceRoot $buildSource -Destination $payloadArchive -ArchiveRoot $definition.root
        $destination = Join-Path $stage ('Payload\' + $definition.key)
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Copy-Item -LiteralPath $payloadArchive -Destination $destination
    }

    Update-SourceChecksums -SourceRoot $PSScriptRoot
    Get-ChildItem -LiteralPath $PSScriptRoot -Force |
        Where-Object { $_.Name -notin @('SHA256SUMS.txt','Payload') } |
        Copy-Item -Destination $stage -Recurse -Force
    Update-SourceChecksums -SourceRoot $stage

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $zipPath = Join-Path $OutputDirectory ($packageName + '.zip')
    New-DeterministicArchive -SourceRoot $stage -Destination $zipPath -ArchiveRoot $packageName
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $sidecar = $zipPath + '.sha256'
    [IO.File]::WriteAllText($sidecar,"$hash *$([IO.Path]::GetFileName($zipPath))`r`n",[Text.ASCIIEncoding]::new())
    [pscustomobject][ordered]@{
        version = $version
        zip = $zipPath
        sidecar = $sidecar
        sizeBytes = (Get-Item -LiteralPath $zipPath).Length
        sha256 = $hash
        payloads = @($payloadDefinitions.key)
        sourceOnlyBuild = $true
        targetSystemAccessed = $false
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

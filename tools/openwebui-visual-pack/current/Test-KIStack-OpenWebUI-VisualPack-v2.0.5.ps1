[CmdletBinding()]
param([string]$PackageRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$required = @(
    'Install-KIStack-OpenWebUI-VisualPack-v2.0.5.ps1',
    'Tool\ki-stack-generate-image.py',
    'Tool\ki-stack-generate-video.py',
    'Workflow\Z-Image-Turbo-OpenWebUI-API.json',
    'Workflow\WAN2.2-T2V-14B-OpenWebUI-API.json',
    'UIWorkflow\Z-Image-Turbo-Uncensored.json',
    'UIWorkflow\WAN2.2-T2V-14B-Uncensored-4Step.json',
    'Tests\test_visual_tools.py',
    'MANIFEST.json',
    'README.md',
    'SHA256SUMS.txt'
)
foreach ($relative in $required) {
    $path = Join-Path $PackageRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Paketdatei fehlt: $relative"
    }
}

$installerSource = Get-Content -LiteralPath (Join-Path $PackageRoot 'Install-KIStack-OpenWebUI-VisualPack-v2.0.5.ps1') -Raw
if (-not $installerSource.Contains("if (`$kind -eq 'image')") -or
    -not $installerSource.Contains("'KI-STACK-OPENWEBUI-IMAGE-PACK'") -or
    -not $installerSource.Contains("rollbackStatus = 'NotRequired'") -or
    -not $installerSource.Contains("KIStackRollbackStatus")) {
    throw 'Legacy-Image-Pack-Migration oder Backup-/Rollbackvertrag fehlt.'
}
$zUi=Get-Content -LiteralPath (Join-Path $PackageRoot 'UIWorkflow\Z-Image-Turbo-Uncensored.json') -Raw
$wanUi=Get-Content -LiteralPath (Join-Path $PackageRoot 'UIWorkflow\WAN2.2-T2V-14B-Uncensored-4Step.json') -Raw
foreach($ui in @($zUi,$wanUi)){
    $graph=$ui|ConvertFrom-Json -Depth 100
    if(@($graph.nodes).Count-lt1){throw 'Sichtbarer UI-Workflow besitzt keine Nodes.'}
    if($ui-match'(?i)huggingface\.co|resolve/(main|latest)|\?download=' -or $ui-match'OpenWebUI-API'){throw 'UI-Workflow enthält Download- oder API-Promptvertrag.'}
}
$zGraph=$zUi|ConvertFrom-Json -Depth 100
$zLoaders=@($zGraph.nodes|Where-Object {$_.type -eq 'CLIPLoaderGGUF'})
if($zLoaders.Count-ne1 -or [string]$zLoaders[0].widgets_values[0] -ne 'Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf' -or $zUi.Contains('Qwen3-4b-Uncensored-Z-Image-Engineer-V4-Q8_0.gguf')){throw 'Z-Image UI-Modellvertrag verletzt.'}

$sumPath = Join-Path $PackageRoot 'SHA256SUMS.txt'
foreach ($line in Get-Content -LiteralPath $sumPath) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -notmatch '^([0-9a-f]{64}) \*(.+)$') {
        throw "Ungueltige SHA256-Zeile: $line"
    }
    $expected = $Matches[1]
    $relative = $Matches[2].Replace('/', '\')
    $path = Join-Path $PackageRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Hashdatei fehlt: $relative"
    }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "SHA256 verletzt: $relative"
    }
}

$python = Get-Command python -ErrorAction Stop
& $python.Source -B -m unittest discover -s (Join-Path $PackageRoot 'Tests') -p 'test_*.py' -v
if ($LASTEXITCODE -ne 0) {
    throw "Python-Regressionstests fehlgeschlagen (Exitcode $LASTEXITCODE)."
}

Write-Host ''
Write-Host 'PAKET-SELBSTTEST BESTANDEN.' -ForegroundColor Green


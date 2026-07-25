[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

$roots = @(
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
$git = (Get-Command git -ErrorAction Stop).Source
$gitRoot = (& $git -C $RepositoryRoot rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath(([string]$gitRoot).Trim()).TrimEnd('\') -ine $RepositoryRoot.TrimEnd('\')) {
    throw "RepositoryRoot must be an exact Git checkout root: $RepositoryRoot"
}
$tracked = @(& $git -C $RepositoryRoot ls-files | ForEach-Object { ([string]$_).Replace('\','/') })
if ($LASTEXITCODE -ne 0 -or $tracked.Count -eq 0) { throw 'Tracked input inventory is empty.' }
$trackedLookup = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($path in $tracked) { [void]$trackedLookup.Add($path) }

$entries = foreach($relativeRoot in $roots){
    $root = Join-Path $RepositoryRoot $relativeRoot
    if(-not(Test-Path -LiteralPath $root -PathType Container)){throw "Build-Eingang fehlt: $relativeRoot"}
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force | Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($RepositoryRoot,$file.FullName).Replace('\','/')
        if (-not $trackedLookup.Contains($relative)) {
            throw "Untracked build input is forbidden: $relative"
        }
        [ordered]@{
            path = $relative
            size = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
}
$content = [ordered]@{
    schemaVersion = '1.0'
    packageVersion = '2.3.0-rc12'
    noGitContract = $true
    roots = $roots
    entries = @($entries)
}
$canonical = $content | ConvertTo-Json -Depth 20 -Compress
$manifestHash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))
).ToLowerInvariant()
$verificationEntries = Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File -Force |
    ForEach-Object {
        $relative=[IO.Path]::GetRelativePath($RepositoryRoot,$_.FullName).Replace('\','/')
        if($relative-match '^(?:\.git(?:/|$)|dist(?:/|$)|_import(?:/|$)|State(?:/|$))' -or $relative-match '^(?:_build|_validate)[^/]*/'){return}
        [ordered]@{
            path=$relative
            size=$_.Length
            sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    } | Sort-Object path
$verificationCanonical = (@($verificationEntries) | ConvertTo-Json -Depth 10 -Compress)
$verificationHash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($verificationCanonical))
).ToLowerInvariant()
$report = [ordered]@{
    schemaVersion = '1.0'
    packageVersion = '2.3.0-rc12'
    manifestSha256 = $manifestHash
    fileCount = @($entries).Count
    verificationSha256 = $verificationHash
    verificationFileCount = @($verificationEntries).Count
    roots = $roots
    entries = @($entries)
}
New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force|Out-Null
[IO.File]::WriteAllText($OutputPath,($report|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
$report

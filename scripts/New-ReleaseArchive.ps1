[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist')
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$RootPath=[IO.Path]::GetFullPath($RootPath)
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)

& (Join-Path $RootPath 'scripts/Test-Repository.ps1') -RootPath $RootPath

$manifest=Get-Content (Join-Path $RootPath 'release-manifest.json') -Raw | ConvertFrom-Json -Depth 100
$packageName=[string]$manifest.packageName
if([string]::IsNullOrWhiteSpace($packageName)){throw 'release-manifest.json does not define packageName.'}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('KI-Stack-Release-'+[guid]::NewGuid().ToString('N'))
$stage=Join-Path $tempRoot $packageName
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    Copy-Item -Path (Join-Path $RootPath 'package/*') -Destination $stage -Recurse -Force
    $sumFile=Join-Path $stage 'SHA256SUMS.txt'
    Remove-Item -LiteralPath $sumFile -Force -ErrorAction SilentlyContinue
    $lines=@()
    foreach($file in Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName){
        $relative=[IO.Path]::GetRelativePath($stage,$file.FullName).Replace('\\','/')
        $hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines += "$hash *$relative"
    }
    [IO.File]::WriteAllText($sumFile,($lines -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
    $zipPath=Join-Path $OutputDirectory ($packageName+'.zip')
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path $stage -DestinationPath $zipPath -CompressionLevel Optimal
    $zipHash=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($zipPath+'.sha256',"$zipHash *$([IO.Path]::GetFileName($zipPath))`n",[Text.UTF8Encoding]::new($false))
    Write-Host "Created: $zipPath"
    Write-Host "SHA256: $zipHash"
}
finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }

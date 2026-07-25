[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BuildManifestA,
    [Parameter(Mandatory)][string]$BuildManifestB,
    [Parameter(Mandatory)][string]$ZipA,
    [Parameter(Mandatory)][string]$ZipB,
    [Parameter(Mandatory)][string]$GateReport,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$TargetTransaction = '',
    [string]$TargetEvidencePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$a=Get-Content -LiteralPath $BuildManifestA -Raw|ConvertFrom-Json
$b=Get-Content -LiteralPath $BuildManifestB -Raw|ConvertFrom-Json
$gate=Get-Content -LiteralPath $GateReport -Raw|ConvertFrom-Json
$zipAHash=(Get-FileHash -LiteralPath $ZipA -Algorithm SHA256).Hash.ToLowerInvariant()
$zipBHash=(Get-FileHash -LiteralPath $ZipB -Algorithm SHA256).Hash.ToLowerInvariant()
$sideA=(Get-Content -LiteralPath ($ZipA+'.sha256') -Raw).Trim()
$sideB=(Get-Content -LiteralPath ($ZipB+'.sha256') -Raw).Trim()
$targetEvidence=if($TargetEvidencePath-and(Test-Path -LiteralPath $TargetEvidencePath)){
    Get-Content -LiteralPath $TargetEvidencePath -Raw|ConvertFrom-Json
}else{$null}
$report=[ordered]@{
    schemaVersion='1.0'
    packageVersion='2.3.0-rc12'
    sourceManifestSha256=[string]$a.manifestSha256
    sourceVerificationSha256=[string]$a.verificationSha256
    verificationCommit='not-applicable-no-git-contract'
    buildInputs=[ordered]@{
        a=[ordered]@{manifest=$BuildManifestA;sha256=[string]$a.manifestSha256;files=[int]$a.fileCount;verificationSha256=[string]$a.verificationSha256}
        b=[ordered]@{manifest=$BuildManifestB;sha256=[string]$b.manifestSha256;files=[int]$b.fileCount;verificationSha256=[string]$b.verificationSha256}
        identical=([string]$a.manifestSha256-eq[string]$b.manifestSha256)
        sourceVerificationIdentical=([string]$a.verificationSha256-eq[string]$b.verificationSha256)
    }
    reproducibility=[ordered]@{
        zipA=$ZipA;zipB=$ZipB
        sha256A=$zipAHash;sha256B=$zipBHash
        sizeA=(Get-Item -LiteralPath $ZipA).Length
        sizeB=(Get-Item -LiteralPath $ZipB).Length
        sidecarsIdentical=($sideA-eq$sideB)
        byteIdentical=($zipAHash-eq$zipBHash)
    }
    nativeGate=[ordered]@{report=$GateReport;status=[string]$gate.status;passed=[bool]$gate.passed;sha256=[string]$gate.sha256}
    target=[ordered]@{transaction=$TargetTransaction;evidence=$TargetEvidencePath;result=$targetEvidence}
}
New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force|Out-Null
[IO.File]::WriteAllText($OutputPath,($report|ConvertTo-Json -Depth 50),[Text.UTF8Encoding]::new($false))
$report

[CmdletBinding()]
param([string]$RepositoryRoot=(Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('KIStack-RC14-Download-'+[guid]::NewGuid().ToString('N'))
$server=$null
try{
    New-Item -ItemType Directory $fixture|Out-Null
    $artifact=Join-Path $fixture 'artifact.bin';$bytes=[byte[]](0..255);[IO.File]::WriteAllBytes($artifact,$bytes)
    $sha=(Get-FileHash $artifact -Algorithm SHA256).Hash.ToLowerInvariant();$port=Get-Random -Minimum 30000 -Maximum 45000;$ready=Join-Path $fixture 'ready'
    $server=Start-Process (Get-Command pwsh.exe).Source -ArgumentList @('-NoProfile','-File',('"{0}"'-f(Join-Path $PSScriptRoot 'Test-RC14DownloadServer.ps1')),'-Port',$port,'-ArtifactPath',('"{0}"'-f$artifact),'-ReadyPath',('"{0}"'-f$ready)) -PassThru -WindowStyle Hidden
    $deadline=[DateTime]::UtcNow.AddSeconds(10);while(-not(Test-Path $ready)){if([DateTime]::UtcNow-gt$deadline){throw'server timeout'};Start-Sleep -Milliseconds 50}
    function Invoke-Case([string]$Name,[string]$Path,[string]$ExpectedSha=$sha){
        $root=Join-Path $fixture $Name;$manifest=Join-Path $root 'manifest.json';New-Item -ItemType Directory $root -Force|Out-Null
        @{schemaVersion='fixture';models=@(@{id='fixture';fileName='artifact.bin';sizeBytes=256;sha256=$ExpectedSha;relativeTargetPath='models/fixture/artifact.bin';sources=@("http://127.0.0.1:$port/$Path")});lmStudio=@{relativeTargetDirectory='x';files=@()}}|ConvertTo-Json -Depth 8|Set-Content $manifest
        & (Join-Path $RepositoryRoot 'tools/models-workflows/current/Import-KIStackExternalModels.ps1') -Mode Install -ManifestPath $manifest -SourcePath (Join-Path $root 'cache') -TargetRoot (Join-Path $root 'target') -LmStudioTargetRoot (Join-Path $root 'lm') -StateRoot (Join-Path $root 'state') -TransactionId $Name
    }
    $resumeRoot=Join-Path $fixture 'no-range/state/downloads';New-Item -ItemType Directory $resumeRoot -Force|Out-Null;[IO.File]::WriteAllBytes((Join-Path $resumeRoot 'fixture.partial'),$bytes[0..31])
    $noRange=Invoke-Case 'no-range' 'no-range'
    if(-not$noRange.passed-or(Get-FileHash (Join-Path $fixture 'no-range/target/models/fixture/artifact.bin')).Hash.ToLowerInvariant()-ne$sha){throw'no-range restart failed'}
    $http=Invoke-Case 'http-error' 'error'
    if($http.passed-or$http.status-ne'WaitingForNetwork'-or-not$http.resumable){throw'HTTP error contract failed'}
    $target=Join-Path $fixture 'atomic/target/models/fixture/artifact.bin';New-Item -ItemType Directory (Split-Path $target -Parent) -Force|Out-Null;[IO.File]::WriteAllText($target,'original');$before=(Get-FileHash $target).Hash
    $failed=$false;try{$null=Invoke-Case 'atomic' 'no-range' ('0'*64)}catch{$failed=$true}
    if(-not$failed-or(Get-FileHash $target).Hash-ne$before){throw'atomic activation failed'}
    [pscustomobject]@{passed=$true;cases=@('server-without-range-restarts','http-error-resumable','atomic-activation-after-full-integrity-only')}|ConvertTo-Json
}
finally{
    if($server-and-not$server.HasExited){try{Invoke-WebRequest "http://127.0.0.1:$port/shutdown" -TimeoutSec 2|Out-Null}catch{};if(-not$server.HasExited){Stop-Process $server.Id -Force}}
    if(Test-Path $fixture){Remove-Item $fixture -Recurse -Force}
}

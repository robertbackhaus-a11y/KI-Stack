[CmdletBinding()]
param(
    [string]$RepositoryRoot=(Split-Path -Parent $PSScriptRoot),
    [string]$OutputDirectory='',
    [string]$BuildCacheDirectory=''
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition-ne'Core'-or$PSVersionTable.PSVersion.Major-lt7){throw 'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'}

$RepositoryRoot=(Resolve-Path -LiteralPath $RepositoryRoot).Path
$builder=Join-Path $RepositoryRoot 'tools\complete-installer\current\New-KIStackCompleteInstallerArchive.ps1'
if(-not(Test-Path -LiteralPath $builder -PathType Leaf)){throw "Complete-Installer-Builder fehlt: $builder"}
$version=(Get-Content -LiteralPath (Join-Path $RepositoryRoot 'tools\complete-installer\current\VERSION') -Raw).Trim()
if($version-ne'2.9.0'){throw "Unerwarteter Quellstand: $version"}
if([string]::IsNullOrWhiteSpace($OutputDirectory)){$OutputDirectory=Join-Path $RepositoryRoot 'dist\complete-installer-rc-validation'}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$runId='RC-BUILD-'+(Get-Date -Format 'yyyyMMdd-HHmmss')
$runRoot=Join-Path $OutputDirectory $runId
$build1=Join-Path $runRoot 'build-1'
$build2=Join-Path $runRoot 'build-2'
$shortExtract=Join-Path ([IO.Path]::GetTempPath()) ('KIPK'+[guid]::NewGuid().ToString('N').Substring(0,8))
$evidenceRoot=Join-Path $runRoot 'evidence'
$steps=[Collections.Generic.List[object]]::new()
$shortTarget=$null
$longTarget=$null
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Add-Step {
    param([string]$Name,[bool]$Passed,[object]$Details)
    $steps.Add([pscustomobject][ordered]@{name=$Name;passed=$Passed;details=$Details})
}
function Get-SingleRequiredItem {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,[Parameter(Mandatory)][string]$Description)
    $matches=@($Items)
    if($matches.Count-ne1){throw "$Description muss genau einmal vorhanden sein; gefunden: $($matches.Count)."}
    $matches[0]
}
function Get-TreeStateHash {
    param([string]$Root)
    if(-not(Test-Path -LiteralPath $Root)){return 'MISSING'}
    $builder=[Text.StringBuilder]::new()
    foreach($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue|Sort-Object FullName){
        [void]$builder.AppendLine(('{0}|{1}|{2}'-f[IO.Path]::GetRelativePath($Root,$file.FullName),$file.Length,$file.LastWriteTimeUtc.Ticks))
    }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($builder.ToString()))).ToLowerInvariant()
}
function Assert-ExecutionLogs {
    param([string]$BasePath)
    # NB: each concatenation must be parenthesized -- inside an @(...) array
    # literal, an unparenthesized "$BasePath+'.stderr.txt'" is parsed as two
    # separate elements ($BasePath and unary +'.stderr.txt'), silently
    # turning this 4-item list into 7 items, 3 of which are bare suffix
    # strings that can never exist as files. That is what actually produced
    # the "fehlend=3; leer=0" failures, not a real race or missing log.
    $required=@($BasePath,($BasePath+'.stderr.txt'),($BasePath+'.transcript.txt'),($BasePath+'.exitcode.txt'))
    $missing=@($required|Where-Object{-not(Test-Path -LiteralPath $_ -PathType Leaf)})
    $empty=@($required|Where-Object{(Test-Path -LiteralPath $_ -PathType Leaf)-and(Get-Item -LiteralPath $_).Length-eq0})
    if($missing.Count-or$empty.Count){throw "Execute-Protokollvertrag verletzt; fehlend=$($missing.Count); leer=$($empty.Count)"}
    [pscustomobject]@{passed=$true;files=@($required|ForEach-Object{[pscustomobject]@{path=$_;size=(Get-Item -LiteralPath $_).Length}});exitCode=((Get-Content -LiteralPath ($BasePath+'.exitcode.txt') -Raw).Trim())}
}

New-Item -ItemType Directory -Path $build1,$build2,$evidenceRoot,$shortExtract -Force|Out-Null
$result=$null
$targetBefore=Get-TreeStateHash 'C:\KI-Stack'
$oldNpmCache=$env:npm_config_cache
try{
    $env:npm_config_cache=Join-Path $runRoot 'npm-cache'
    $buildArguments=@{}
    if(-not[string]::IsNullOrWhiteSpace($BuildCacheDirectory)){$buildArguments.BuildCacheDirectory=[IO.Path]::GetFullPath($BuildCacheDirectory)}
    $first=&$builder -OutputDirectory $build1 @buildArguments
    Add-Step Build1 $true $first
    $second=&$builder -OutputDirectory $build2 @buildArguments
    Add-Step Build2 $true $second
    $sameHash=[string]$first.sha256-eq[string]$second.sha256
    $sameSize=[int64]$first.sizeBytes-eq[int64]$second.sizeBytes
    if(-not($sameHash-and$sameSize)){throw 'Die beiden Builds sind nicht deterministisch identisch.'}
    Add-Step DeterministicBuild $true ([ordered]@{build1Sha256=$first.sha256;build2Sha256=$second.sha256;build1SizeBytes=$first.sizeBytes;build2SizeBytes=$second.sizeBytes})

    $zipRead=[IO.Compression.ZipFile]::OpenRead([string]$first.zip)
    try{$entryCount=$zipRead.Entries.Count}finally{$zipRead.Dispose()}
    Add-Step ZipIntegrity ($entryCount-gt0) ([ordered]@{entries=$entryCount})
    Expand-Archive -LiteralPath $first.zip -DestinationPath $shortExtract -Force
    $packageRoot=Join-Path $shortExtract "KI-Stack-Complete-Installer-v$version"
    $selfTest=Join-Path $packageRoot 'Test-KIStackCompleteInstaller.ps1'
    $selfTestResult=&$selfTest -PackageRoot $packageRoot|Out-String
    Add-Step PackageSelfTest $true $selfTestResult.Trim()

    Import-Module (Join-Path $packageRoot 'CompleteInstaller.psm1') -Force
    $shaResult=Test-KICompleteShaContract -Root $packageRoot
    if(-not$shaResult.passed){throw ('Interne SHA256-Verträge fehlgeschlagen: '+($shaResult.errors-join'; '))}
    Add-Step InternalSHA256 $true $shaResult

    $payloadDirectory=Join-Path $packageRoot 'Payload\CodexLocal'
    $codexPayload=Get-SingleRequiredItem -Items @(Get-ChildItem -LiteralPath $payloadDirectory -Filter '*.zip' -File) -Description 'Codex-Local-Payload'
    $codexExtract=Join-Path $shortExtract 'cx'
    Expand-Archive -LiteralPath $codexPayload.FullName -DestinationPath $codexExtract -Force
    $codexEntry=Get-SingleRequiredItem -Items @(Get-ChildItem -LiteralPath $codexExtract -Filter 'Invoke-KIStackCodexLocal.ps1' -File -Recurse) -Description 'Codex-Local-Artefaktvalidator'
    $codexRoot=Split-Path -Parent $codexEntry.FullName
    Import-Module (Join-Path $codexRoot 'CodexLocal.psm1') -Force
    $codexConfig=Get-KICodexConfig -PackageRoot $codexRoot
    $vendorCache=if(-not[string]::IsNullOrWhiteSpace($BuildCacheDirectory)){[IO.Path]::GetFullPath($BuildCacheDirectory)}else{Join-Path $runRoot 'vendor-cache'}
    $nodeArchiveResult=Get-KIManagedNodeArchive -Contract $codexConfig.nodeRuntime -DownloadRoot $vendorCache
    $nodeArchive=[string]$nodeArchiveResult.path
    Add-Step VendorNodeArchive ([bool]$nodeArchiveResult.validation.passed) $nodeArchiveResult

    $shortTarget=Join-Path ([IO.Path]::GetTempPath()) ('KICX'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $shortJson=&$codexEntry.FullName -Action ArtifactValidate -NodeArchivePath $nodeArchive -TestRoot $shortTarget -KeepTestRoot|Out-String
    $shortArtifact=$shortJson|ConvertFrom-Json
    if(-not$shortArtifact.passed-or$shortArtifact.actualVersion-ne'0.145.0'-or-not$shortArtifact.secondRunReused){throw 'Der reale kurze Windows-Codex-CLI-Artefakttest ist fehlgeschlagen.'}
    Add-Step CodexArtifactWindowsExecution $true $shortArtifact

    $paths=Get-KICodexPaths -TargetRoot $shortTarget
    Move-Item -LiteralPath $paths.node -Destination ($paths.node+'.disabled')
    try{if($null-ne(Get-KICodexVersion -TargetRoot $shortTarget)){throw 'Nicht startbare CLI wurde nicht erkannt.'}}finally{Move-Item -LiteralPath ($paths.node+'.disabled') -Destination $paths.node}
    $originalCodex=[IO.File]::ReadAllBytes($paths.codexCli)
    try{
        [IO.File]::WriteAllText($paths.codexCli,'console.log("codex-cli 0.0.0");',[Text.UTF8Encoding]::new($false))
        if((Get-KICodexVersion -TargetRoot $shortTarget)-ne'0.0.0'){throw 'Abweichende CLI-Version wurde nicht erkannt.'}
    }finally{[IO.File]::WriteAllBytes($paths.codexCli,$originalCodex)}
    Add-Step CliFailureRegressions $true ([ordered]@{unstartableDetected=$true;wrongVersionDetected=$true})

    $longSource=Join-Path $runRoot ('intentionally-long-source-path-'+('segment-'*12)+'codex-payload')
    New-Item -ItemType Directory -Path (Split-Path -Parent $longSource) -Force|Out-Null
    Copy-Item -LiteralPath $codexRoot -Destination $longSource -Recurse -Force
    $longEntry=Join-Path $longSource 'Invoke-KIStackCodexLocal.ps1'
    $longTarget=Join-Path ([IO.Path]::GetTempPath()) ('KICL'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $longArtifact=(&$longEntry -Action ArtifactValidate -NodeArchivePath $nodeArchive -TestRoot $longTarget|Out-String)|ConvertFrom-Json
    if(-not$longArtifact.passed-or$longArtifact.actualVersion-ne'0.145.0'){throw 'Der lange Windows-Codex-Quellpfad ist fehlgeschlagen.'}
    Add-Step LongSourcePathWindowsExecution $true $longArtifact

    $missing=Test-KINodeArchiveContract -ArchivePath (Join-Path $runRoot 'missing-node.zip') -Contract $codexConfig.nodeRuntime
    $wrong=Join-Path $runRoot 'wrong-node.zip';[IO.File]::WriteAllBytes($wrong,[byte[]](1,2,3))
    $wrongResult=Test-KINodeArchiveContract -ArchivePath $wrong -Contract $codexConfig.nodeRuntime
    if($missing.reason-ne'Missing'-or$wrongResult.passed){throw 'Node-Archiv-Negativverträge sind fehlgeschlagen.'}
    try{Get-SingleRequiredItem -Items @() -Description 'Codex-Local-Payload'|Out-Null;throw 'Fehlende Payload wurde akzeptiert.'}catch{if($_.Exception.Message-notmatch'gefunden: 0'){throw}}
    try{Get-SingleRequiredItem -Items @('a','b') -Description 'Codex-Local-Payload'|Out-Null;throw 'Doppelte Payload wurde akzeptiert.'}catch{if($_.Exception.Message-notmatch'gefunden: 2'){throw}}
    Add-Step ArtifactFailureContracts $true ([ordered]@{missingNodeArchive=$true;wrongNodeArchive=$true;missingPayload=$true;duplicatePayload=$true;missingParentCoveredByRealArtifact=$true})

    $simulatedTarget=Join-Path $shortExtract 'simulated-empty-target'
    New-Item -ItemType Directory -Path $simulatedTarget -Force|Out-Null
    $audit=Invoke-KIStackCompleteInstaller -Mode Audit -PackageRoot $packageRoot -TargetRoot $simulatedTarget
    $dryRun=Invoke-KIStackCompleteInstaller -Mode Upgrade -PackageRoot $packageRoot -TargetRoot $simulatedTarget -DryRun
    if([bool]$audit.mutatesTarget-or[bool]$dryRun.mutatesTarget){throw 'Audit oder Dry Run meldet Zielmutation.'}
    Add-Step AuditDryRun $true ([ordered]@{auditMutatesTarget=$audit.mutatesTarget;dryRunMutatesTarget=$dryRun.mutatesTarget;dryRunPlanSteps=@($dryRun.plan.steps).Count})

    $loggingBase=Join-Path $runRoot 'execute-logging-probe.txt'
    & (Get-Command pwsh.exe -ErrorAction Stop).Source -NoProfile -File (Join-Path $packageRoot 'Start-KIStackCompleteInstaller.ps1') -LoggingProbe -LogPath $loggingBase
    if($LASTEXITCODE-ne0){throw "Elevated Logging-Probe Exitcode $LASTEXITCODE"}
    $logging=Assert-ExecutionLogs -BasePath $loggingBase
    try{Assert-ExecutionLogs -BasePath (Join-Path $runRoot 'missing-logs')|Out-Null;throw 'Fehlende Logs wurden akzeptiert.'}catch{if($_.Exception.Message-notmatch'Protokollvertrag verletzt'){throw}}
    Add-Step ElevatedExecutionLogging $true $logging

    $targetAfter=Get-TreeStateHash 'C:\KI-Stack'
    if($targetBefore-ne$targetAfter){throw 'Die Windows-Vorvalidierung hat C:\KI-Stack verändert.'}
    Add-Step RealTargetUnchanged $true ([ordered]@{before=$targetBefore;after=$targetAfter})

    $finalZip=Join-Path $OutputDirectory ([IO.Path]::GetFileName([string]$first.zip))
    $finalSidecar=$finalZip+'.sha256'
    Copy-Item -LiteralPath $first.zip -Destination $finalZip -Force
    Copy-Item -LiteralPath $first.sidecar -Destination $finalSidecar -Force
    $result=[pscustomobject][ordered]@{
        schemaVersion='2.0';runId=$runId;version=$version;status='WindowsArtifactValidated_TargetExecutionLocked'
        passed=$true;targetSystemMutated=$false
        package=[ordered]@{zip=$finalZip;sidecar=$finalSidecar;sizeBytes=$first.sizeBytes;sha256=$first.sha256}
        steps=$steps
    }
}catch{
    Add-Step Failure $false $_.Exception.ToString()
    $result=[pscustomobject][ordered]@{schemaVersion='2.0';runId=$runId;version=$version;status='Failed';passed=$false;targetSystemMutated=$false;error=$_.Exception.Message;steps=$steps}
}finally{
    $env:npm_config_cache=$oldNpmCache
    foreach($path in @($shortExtract,$shortTarget,$longTarget)){if($null-ne$path-and(Test-Path -LiteralPath $path)){Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue}}
}

$reportPath=Join-Path $evidenceRoot 'RC-BUILD-VALIDATION.json'
$result|ConvertTo-Json -Depth 60|Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM
$result|ConvertTo-Json -Depth 60
if(-not$result.passed){exit 1}

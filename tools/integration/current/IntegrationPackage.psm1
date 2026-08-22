Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Read-IntegrationJson { param([string]$Path) Get-Content $Path -Raw|ConvertFrom-Json -Depth 100 }
function Get-IntegrationRuntimeContract { param([string]$PackageRoot) Read-IntegrationJson (Join-Path $PackageRoot 'Runtime/RUNTIME-CONTRACT.json') }
function Test-IntegrationRuntime {
    param([string]$TargetRoot='C:\KI-Stack\modules\integration',[object]$Contract)
    if($null-eq$Contract){return $false}
    foreach($name in @($Contract.files)+@([string]$Contract.generatedMarker)){if(-not(Test-Path -LiteralPath (Join-Path $TargetRoot $name)-PathType Leaf)){return $false}}
    return $true
}
function Backup-IntegrationWindowsRuntime {
    param([string]$RuntimeRoot='C:\KI-Stack\modules\integration',[Parameter(Mandatory)][string]$BackupPath)
    $existed=Test-Path -LiteralPath $RuntimeRoot -PathType Container
    [pscustomobject]@{runtimeRoot=$RuntimeRoot;existed=$existed}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $BackupPath 'windows-runtime.json') -Encoding UTF8
    if($existed){Copy-Item -LiteralPath $RuntimeRoot -Destination (Join-Path $BackupPath 'windows-runtime') -Recurse -Force}
}
function Restore-IntegrationWindowsRuntime {
    param([Parameter(Mandatory)][string]$BackupPath)
    $metadataPath=Join-Path $BackupPath 'windows-runtime.json';if(-not(Test-Path -LiteralPath $metadataPath -PathType Leaf)){throw 'Integration Windows runtime backup metadata missing'}
    $metadata=Read-IntegrationJson $metadataPath;$runtimeRoot=[string]$metadata.runtimeRoot
    if(Test-Path -LiteralPath $runtimeRoot){Remove-Item -LiteralPath $runtimeRoot -Recurse -Force}
    if([bool]$metadata.existed){$saved=Join-Path $BackupPath 'windows-runtime';if(-not(Test-Path -LiteralPath $saved -PathType Container)){throw 'Integration Windows runtime backup missing'};New-Item -ItemType Directory -Path (Split-Path -Parent $runtimeRoot)-Force|Out-Null;Copy-Item -LiteralPath $saved -Destination $runtimeRoot -Recurse -Force}
}
# Readiness (diag10): local-only and deterministic, never executes a search
# and never depends on any external engine. It proves the local SearXNG app
# is up via its own liveness route (/healthz, no engine calls) plus its
# static /config route (instance/engine metadata, also no engine calls) to
# confirm the app answering on the port is actually SearXNG and not some
# other listener. This mirrors Linux/install-searxng-payload.sh's
# readiness_probe so both sides of the installer agree on what "ready" means.
function Test-IntegrationEndpoint {
    try {
        $healthz = Invoke-WebRequest 'http://localhost/searxng/healthz' -TimeoutSec 10 -UseBasicParsing
        if ($healthz.StatusCode -ne 200) { return $false }
        if (([string]$healthz.Content).Trim() -ne 'OK') { return $false }
        $config = Invoke-RestMethod 'http://localhost/searxng/config' -TimeoutSec 10
        if ($null -eq $config) { return $false }
        if ([string]::IsNullOrEmpty([string]$config.instance_name)) { return $false }
        if ([string]::IsNullOrEmpty([string]$config.version)) { return $false }
        if ($null -eq $config.engines) { return $false }
        return $true
    } catch { return $false }
}
# Optional FUNCTIONAL test, not an installation readiness gate. Runs a real
# search once, on demand, and never affects Test-IntegrationEndpoint /
# Test-IntegrationTarget / Install-IntegrationPayload's pass/fail outcome.
# Unreachable external engines are an expected, non-fatal result here.
function Test-IntegrationSearchFunctional {
    try {
        $json = Invoke-RestMethod 'http://localhost/searxng/search?q=ki-stack&format=json' -TimeoutSec 20
        return (($null -ne $json) -and ($json.PSObject.Properties['results']) -and (@($json.results) -is [array]))
    } catch { return $false }
}
function Test-IntegrationPayload {
    param([string]$PackageRoot)
    $contract=Read-IntegrationJson (Join-Path $PackageRoot 'Payload/PAYLOAD-CONTRACT.json');$path=Join-Path $PackageRoot ('Payload/'+$contract.output.fileName);$errors=@()
    if(-not(Test-Path $path)){$errors+='payload missing'}else{if((Get-Item $path).Length-ne$contract.output.sizeBytes){$errors+='size mismatch'};if((Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()-ne$contract.output.sha256){$errors+='SHA mismatch'}}
    [pscustomobject]@{passed=($errors.Count-eq0);errors=$errors;contract=$contract;path=$path}
}
function Test-IntegrationTarget { $runtimeContract=Get-IntegrationRuntimeContract $PSScriptRoot;[pscustomobject]@{passed=((Test-IntegrationEndpoint)-and(Test-IntegrationRuntime -Contract $runtimeContract));version='1.5.10';runtimeChain=@('wsl keeper','valkey-server','uwsgi','nginx');runtimeGitDependency=$false} }
function ConvertTo-IntegrationWslPath { param([string]$Path) (@(wsl.exe -d Debian --exec wslpath -u $Path)|Select-Object -Last 1).Trim() }
function Backup-IntegrationState {
    param([string]$BackupRoot='C:\KI-Stack\backups\integration-1.5.10')
    $directory=Join-Path $BackupRoot ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'));New-Item -ItemType Directory $directory -Force|Out-Null
    $archive=Join-Path $directory 'linux-state.tar.gz';$linuxArchive=ConvertTo-IntegrationWslPath $archive
    & wsl.exe -d Debian -u root --exec tar -czf $linuxArchive --ignore-failed-read /opt/ki-stack/integration/installation.json /etc/searxng/settings.yml /etc/uwsgi/apps-available/searxng.ini /etc/uwsgi/apps-enabled/searxng.ini /etc/nginx/default.d/searxng.conf
    if($LASTEXITCODE-ne0){throw"Integration backup failed: $LASTEXITCODE"}
    Backup-IntegrationWindowsRuntime -BackupPath $directory
    [pscustomobject]@{directory=$directory;archive=$archive}
}
function Restore-IntegrationState {
    param([string]$BackupPath)
    $archive=Join-Path $BackupPath 'linux-state.tar.gz';if(-not(Test-Path $archive)){throw'Integration backup missing'};$linuxArchive=ConvertTo-IntegrationWslPath $archive
    & wsl.exe -d Debian -u root --exec tar -xzf $linuxArchive -C /;if($LASTEXITCODE-ne0){throw"Integration rollback failed: $LASTEXITCODE"}
    Restore-IntegrationWindowsRuntime -BackupPath $BackupPath
    & wsl.exe -d Debian -u root --exec systemctl restart valkey-server uwsgi nginx
    [pscustomobject]@{passed=($LASTEXITCODE-eq0);status='RolledBack'}
}
function Assert-IntegrationPayloadExitCode {
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$BackupPath,
        [string]$DiagnosticLogPath,
        [scriptblock]$RestoreAction = { param($Path) Restore-IntegrationState $Path }
    )
    if($ExitCode-eq0){return}
    & $RestoreAction $BackupPath|Out-Null
    $suffix=if([string]::IsNullOrWhiteSpace($DiagnosticLogPath)){''}else{"; diagnosticLog=$DiagnosticLogPath"}
    throw "SearXNG payload install failed: $ExitCode$suffix"
}
function Write-IntegrationPayloadDiagnostic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Output,
        [string]$ExecutedCommand='unknown',
        [Parameter(Mandatory)][object]$Contract
    )
    $normalizedOutput=if($null-eq$Output){@()}else{@($Output|ForEach-Object{if($null-eq$_){''}else{[string]$_}})}
    $outputPresent=@($normalizedOutput|Where-Object{-not[string]::IsNullOrEmpty($_)}).Count-gt0
    $persistedOutput=if($outputPresent){@($normalizedOutput)}else{@('<empty>')}
    $diagnosticLine=@($normalizedOutput|Where-Object{$_ -like 'KI_STACK_PAYLOAD_DIAGNOSTIC|*'}|Select-Object -Last 1)
    $fields=@{}
    if($diagnosticLine.Count-eq1){
        foreach($part in ([string]$diagnosticLine[0] -split '\|')){
            if($part -match '^(?<name>[^=]+)=(?<value>.*)$'){$fields[$Matches.name]=$Matches.value}
        }
    }
    $upstream=$Contract.PSObject.Properties['upstream']
    $revision=if($null-ne$upstream-and$null-ne$upstream.Value.PSObject.Properties['revision']){[string]$upstream.Value.revision}else{'unknown'}
    $payloadId=if($null-ne$Contract.PSObject.Properties['payloadId']){[string]$Contract.payloadId}else{'unknown'}
    $record=[ordered]@{
        schemaVersion='1.0';capturedAtUtc=[DateTime]::UtcNow.ToString('o');step=if($fields.ContainsKey('step')){$fields.step}else{'unknown'}
        exitCode=$ExitCode;executedCommand=$ExecutedCommand;outputPresent=$outputPresent;output=$persistedOutput;payloadId=$payloadId;searxngRevision=$revision
        targetPaths=[ordered]@{root='/opt/ki-stack/searxng';source='/opt/ki-stack/searxng/src';venv='/opt/ki-stack/searxng/venv';marker='/opt/ki-stack/integration/installation.json';settings='/etc/searxng/settings.yml';uwsgi='/etc/uwsgi/apps-enabled/searxng.ini';nginx='/etc/nginx/default.d/searxng.conf'}
        internalCause=if($fields.ContainsKey('cause')){$fields.cause}else{'Payload exited without a structured internal cause.'}
        containsSecrets=$false
    }
    $record|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $Path -Encoding UTF8
    return $Path
}
function Write-IntegrationMarker {
    # diag11 fix: ensures the marker's parent directory exists (idempotent)
    # immediately before writing, then writes atomically via a temp file +
    # rename so a partial/corrupt marker can never be left behind.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    $directory=Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory|Out-Null
    $temp=Join-Path $directory ([IO.Path]::GetRandomFileName())
    Set-Content -LiteralPath $temp -Value $Content -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}
function Install-IntegrationRuntime {
    param([string]$PackageRoot,[string]$TargetRoot='C:\KI-Stack\modules\integration',[Parameter(Mandatory)][object]$Marker)
    $contract=Get-IntegrationRuntimeContract $PackageRoot;$sourceRoot=Join-Path $PackageRoot 'Runtime'
    New-Item -ItemType Directory -Path $TargetRoot -Force|Out-Null
    foreach($name in @($contract.files)){
        $source=Join-Path $sourceRoot $name;if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "Integration runtime source missing: $name"}
        $destination=Join-Path $TargetRoot $name;$temporary=$destination+'.tmp-'+[guid]::NewGuid().ToString('N')
        Copy-Item -LiteralPath $source -Destination $temporary -Force;Move-Item -LiteralPath $temporary -Destination $destination -Force
    }
    $markerPath=Join-Path $TargetRoot ([string]$contract.generatedMarker)
    Write-IntegrationMarker -Path $markerPath -Content ($Marker|ConvertTo-Json -Depth 20)
    if(-not(Test-IntegrationRuntime -TargetRoot $TargetRoot -Contract $contract)){throw 'Integration runtime readback failed.'}
    [pscustomobject]@{passed=$true;targetRoot=$TargetRoot;files=@($contract.files)+@([string]$contract.generatedMarker)}
}
function Install-IntegrationPayload {
    param([string]$PackageRoot)
    $test=Test-IntegrationPayload $PackageRoot;if(-not$test.passed){throw($test.errors-join'; ')};$backup=Backup-IntegrationState
    $script=Join-Path $PackageRoot 'Linux/install-searxng-payload.sh';$manifest=Join-Path $PackageRoot 'Payload/CONTENT-MANIFEST.json'
    $scriptLinux=ConvertTo-IntegrationWslPath $script;$payloadLinux=ConvertTo-IntegrationWslPath $test.path;$manifestLinux=ConvertTo-IntegrationWslPath $manifest
    $payloadCommand="wsl.exe -d Debian -u root --exec bash `"$scriptLinux`" `"$payloadLinux`" `"$manifestLinux`" $([string]$test.contract.output.sha256) $([string]$test.contract.upstream.revision)"
    $payloadOutput=@(& wsl.exe -d Debian -u root --exec bash $scriptLinux $payloadLinux $manifestLinux ([string]$test.contract.output.sha256) ([string]$test.contract.upstream.revision) 2>&1|ForEach-Object{[string]$_})
    $payloadExitCode=[int]$LASTEXITCODE
    foreach($line in $payloadOutput){Write-Host $line}
    $diagnosticLogPath=$null
    if($payloadExitCode-ne0){
        $diagnosticLogPath=Join-Path $PackageRoot 'SearXNG-payload-install.json'
        Write-IntegrationPayloadDiagnostic -Path $diagnosticLogPath -ExitCode $payloadExitCode -Output $payloadOutput -ExecutedCommand $payloadCommand -Contract $test.contract|Out-Null
    }
    Assert-IntegrationPayloadExitCode -ExitCode $payloadExitCode -BackupPath $backup.directory -DiagnosticLogPath $diagnosticLogPath
    try {
        $marker=[ordered]@{schemaVersion='1.0';managedBy='KI-STACK-INTEGRATION-MANAGED';version='1.5.10';release='KI-Stack-Integration-Execute-v1.5.10';installedAt=[DateTime]::UtcNow.ToString('o');distribution='Debian';searxngUrl='http://localhost/searxng';payloadId='KI-STACK-SEARXNG-SOURCE-2026.6.28';payloadSha256=[string]$test.contract.output.sha256;linuxMode='adopted-existing';runtimeGitDependency=$false}
        $runtime=Install-IntegrationRuntime -PackageRoot $PackageRoot -Marker $marker
        $result=Test-IntegrationTarget;if(-not[bool]$result.passed){throw 'Integration runtime or local SearXNG readback failed.'};$result|Add-Member backupPath $backup.directory;$result|Add-Member runtime $runtime;$result
    } catch {
        Restore-IntegrationState $backup.directory|Out-Null
        throw
    }
}
Export-ModuleMember -Function *

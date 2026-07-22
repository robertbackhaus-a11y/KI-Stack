Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Read-IntegrationJson { param([string]$Path) Get-Content $Path -Raw|ConvertFrom-Json -Depth 100 }
function Test-IntegrationEndpoint { try{$html=Invoke-WebRequest 'http://localhost/searxng/' -TimeoutSec 20;$json=Invoke-RestMethod 'http://localhost/searxng/search?q=ki-stack&format=json' -TimeoutSec 20;return ($html.StatusCode-eq200-and@($json.results).Count-gt0)}catch{return $false} }
function Test-IntegrationPayload {
    param([string]$PackageRoot)
    $contract=Read-IntegrationJson (Join-Path $PackageRoot 'Payload/PAYLOAD-CONTRACT.json');$path=Join-Path $PackageRoot ('Payload/'+$contract.fileName);$errors=@()
    if(-not(Test-Path $path)){$errors+='payload missing'}else{if((Get-Item $path).Length-ne$contract.sizeBytes){$errors+='size mismatch'};if((Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()-ne$contract.sha256){$errors+='SHA mismatch'}}
    [pscustomobject]@{passed=($errors.Count-eq0);errors=$errors;contract=$contract;path=$path}
}
function Test-IntegrationTarget { [pscustomobject]@{passed=(Test-IntegrationEndpoint);version='1.5.9';runtimeChain=@('wsl keeper','valkey-server','uwsgi','nginx');runtimeGitDependency=$false} }
function ConvertTo-IntegrationWslPath { param([string]$Path) (@(wsl.exe -d Debian --exec wslpath -u $Path)|Select-Object -Last 1).Trim() }
function Backup-IntegrationState {
    param([string]$BackupRoot='C:\KI-Stack\backups\integration-1.5.9')
    $directory=Join-Path $BackupRoot ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'));New-Item -ItemType Directory $directory -Force|Out-Null
    $archive=Join-Path $directory 'linux-state.tar.gz';$linuxArchive=ConvertTo-IntegrationWslPath $archive
    & wsl.exe -d Debian -u root --exec tar -czf $linuxArchive --ignore-failed-read /opt/ki-stack/integration/installation.json /etc/searxng/settings.yml /etc/uwsgi/apps-available/searxng.ini /etc/uwsgi/apps-enabled/searxng.ini /etc/nginx/default.d/searxng.conf
    if($LASTEXITCODE-ne0){throw"Integration backup failed: $LASTEXITCODE"}
    $windowsMarker='C:\KI-Stack\modules\integration\installation.json';if(Test-Path $windowsMarker){Copy-Item $windowsMarker (Join-Path $directory 'windows-installation.json') -Force}
    [pscustomobject]@{directory=$directory;archive=$archive}
}
function Restore-IntegrationState {
    param([string]$BackupPath)
    $archive=Join-Path $BackupPath 'linux-state.tar.gz';if(-not(Test-Path $archive)){throw'Integration backup missing'};$linuxArchive=ConvertTo-IntegrationWslPath $archive
    & wsl.exe -d Debian -u root --exec tar -xzf $linuxArchive -C /;if($LASTEXITCODE-ne0){throw"Integration rollback failed: $LASTEXITCODE"}
    $windowsBackup=Join-Path $BackupPath 'windows-installation.json';if(Test-Path $windowsBackup){Copy-Item $windowsBackup 'C:\KI-Stack\modules\integration\installation.json' -Force}
    & wsl.exe -d Debian -u root --exec systemctl restart valkey-server uwsgi nginx
    [pscustomobject]@{passed=($LASTEXITCODE-eq0);status='RolledBack'}
}
function Install-IntegrationPayload {
    param([string]$PackageRoot)
    $test=Test-IntegrationPayload $PackageRoot;if(-not$test.passed){throw($test.errors-join'; ')};$backup=Backup-IntegrationState
    $script=Join-Path $PackageRoot 'Linux/install-searxng-payload.sh';$manifest=Join-Path $PackageRoot 'Payload/CONTENT-MANIFEST.json'
    $scriptLinux=ConvertTo-IntegrationWslPath $script;$payloadLinux=ConvertTo-IntegrationWslPath $test.path;$manifestLinux=ConvertTo-IntegrationWslPath $manifest
    & wsl.exe -d Debian -u root --exec bash $scriptLinux $payloadLinux $manifestLinux ([string]$test.contract.sha256)
    if($LASTEXITCODE-ne0){Restore-IntegrationState $backup.directory|Out-Null;throw"SearXNG payload install failed: $LASTEXITCODE"}
    $marker='C:\KI-Stack\modules\integration\installation.json'
    [ordered]@{schemaVersion='1.0';managedBy='KI-STACK-INTEGRATION-MANAGED';version='1.5.9';release='KI-Stack-Integration-Execute-v1.5.9';installedAt=[DateTime]::UtcNow.ToString('o');distribution='Debian';searxngUrl='http://localhost/searxng';payloadId='KI-STACK-SEARXNG-SOURCE-2026.6.28';payloadSha256=[string]$test.contract.sha256;linuxMode='adopted-existing';runtimeGitDependency=$false}|ConvertTo-Json -Depth 10|Set-Content $marker -Encoding UTF8
    $result=Test-IntegrationTarget;$result|Add-Member backupPath $backup.directory;$result
}
Export-ModuleMember -Function *

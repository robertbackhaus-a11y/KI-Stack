[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=$PSScriptRoot; $fail=@()
$executables=@('IntegrationPackage.psm1','Invoke-KIStackIntegration.ps1','Linux/install-searxng-payload.sh')
$text=($executables|ForEach-Object{Get-Content(Join-Path $root $_)-Raw})-join"`n"
# ki-stack-searxng.service is deliberately referenced (not forbidden): it's
# the sibling Cutover-Runtime Integration module's unit name, recognized as
# an equally valid already-active SearXNG service to adopt instead of
# starting a second, port-conflicting install.
foreach ($pattern in @('(?i)\bgit(?:\.exe)?\b','(?i)\bclone\b','(?i)\bcheckout\b','(?i)\bpull\b','(?i)origin','(?i)\.git(?:[\\/]|\b)')) { if ($text -match $pattern) { $fail += "forbidden runtime pattern $pattern" } }
if ($text -notmatch '(?i)ki-stack-searxng') { $fail += 'missing ki-stack-searxng sibling-unit adoption contract' }
foreach ($required in @('valkey-server','uwsgi','nginx','wsl.exe','sha256sum','CONTENT-MANIFEST.json')) { if ($text -notmatch [regex]::Escape($required)) { $fail += "missing $required" } }
$contract=Get-Content (Join-Path $root 'Payload/PAYLOAD-CONTRACT.json') -Raw|ConvertFrom-Json
if ($contract.output.sha256 -notmatch '^[0-9a-f]{64}$' -or $contract.output.sizeBytes -le 0 -or $contract.upstream.sha256 -notmatch '^[0-9a-f]{64}$') { $fail += 'payload contract' }
if ($contract.upstream.revision -ne '357662d86dd225bf8f0bfe5cfaa45bed09aef788') { $fail += 'upstream revision pin changed unexpectedly' }
$linuxInstaller=Get-Content (Join-Path $root 'Linux/install-searxng-payload.sh') -Raw
if(-not($linuxInstaller.Contains('chdir=$SRC/searx')-and$linuxInstaller.Contains('module=searx.webapp')-and$linuxInstaller.Contains('pythonpath=$SRC'))-or$linuxInstaller.Contains('module=webapp')){$fail+='SearXNG uWSGI source/module contract'}
$healthDiagnostics=@('systemctl --no-pager --full status valkey-server uwsgi nginx','journalctl --no-pager -n 120 -u valkey-server -u uwsgi -u nginx','tail -n 120 /var/log/uwsgi/app/searxng.log','ss -ltnp','section=direct-backend','section=nginx')
foreach($diagnosticContract in $healthDiagnostics){if(-not$linuxInstaller.Contains($diagnosticContract)){$fail+="missing health diagnostic: $diagnosticContract"}}

# --- diag10: readiness must be local-only and deterministic ----------------
# diag9 root cause: readiness executed a REAL /search request, which fans
# out to external engines; 403/timeouts there saturated the installer's own
# listen queue after 60 retries and took down even diagnostic curls. The
# health check caused its own outage. Fixed readiness proves the app is up
# using only the local /healthz liveness+identity route, never /search, and
# never depends on an external engine being reachable. /config was tried as
# an additional identity signal but is itself subject to SearXNG's request
# limiter (live check: 429 on a freshly restarted instance), so hitting it
# from the 60x retry loop reproduced the same self-inflicted-outage class of
# bug as the original diag9 issue -- it is deliberately not used here.
if (-not $linuxInstaller.Contains('readiness_probe(){')) { $fail += 'local readiness_probe function missing' }
if (-not ($linuxInstaller.Contains('uwsgi_process_active') -and $linuxInstaller.Contains('port_socket_present') -and $linuxInstaller.Contains('local_http_endpoint_responds') -and $linuxInstaller.Contains('response_is_searxng_app'))) { $fail += 'readiness must check uWSGI process, port/socket, local HTTP endpoint, and app identity' }
if (-not $linuxInstaller.Contains("/healthz")) { $fail += 'readiness must use the local /healthz route' }
if ($loopMatchConfigCheck = ([regex]::Match($linuxInstaller, '(?s)^response_is_searxng_app\(\)\{.*?^\}', 'Multiline')).Value) { if ($loopMatchConfigCheck -match '/config') { $fail += 'REGRESSION: identity check hits rate-limited /config again (diag9-class bug reintroduced)' } }
# The retry loop text (between the readiness step marker and the failure branch)
# must never issue a real search request -- this is the exact diag9 regression.
$loopMatch = [regex]::Match($linuxInstaller, '(?s)STEP=local-readiness-readback.*?if \[ "\$READY" -ne 1 \]; then')
if (-not $loopMatch.Success) { $fail += 'local-readiness-readback retry loop not found' }
elseif ($loopMatch.Value -match 'search\?q=') { $fail += 'REGRESSION: readiness retry loop issues a /search request (diag9 reintroduced)' }
elseif ($loopMatch.Value -notmatch 'readiness_probe') { $fail += 'retry loop does not call readiness_probe' }
elseif ($loopMatch.Value -match 'optional_search_functional_probe') { $fail += 'optional functional probe must not run inside the retry loop' }
# The optional functional test must still exist, but strictly outside the gate.
if (-not $linuxInstaller.Contains('optional_search_functional_probe(){')) { $fail += 'optional search-functional probe missing' }
if (-not $linuxInstaller.Contains('search?q=ki-stack&format=json')) { $fail += 'optional search-functional probe lost its search-api check' }
$functionalProbeComment = $linuxInstaller -match 'Optional FUNCTIONAL test, not an installation readiness gate'
if (-not $functionalProbeComment) { $fail += 'optional functional probe must be documented as non-gating' }
if (-not (Test-Path (Join-Path $root 'Linux/Test-KIStackSearXNGReadiness.sh'))) { $fail += 'Linux/Test-KIStackSearXNGReadiness.sh regression harness missing from package' }

# --- diag10: live regression scenarios (best-effort; needs a bash runtime) -
# Runs the real Linux/Test-KIStackSearXNGReadiness.sh, which sources the
# actual production functions (no duplicated logic) and drives them against
# mock local HTTP servers to prove: (1) local app healthy + external engines
# unreachable => still ready, (2) process/port down => not ready, (3) wrong
# app on the port => not ready. Skipped (not failed) when no bash runtime is
# reachable from this host, since Test-KIStackIntegration.ps1 itself is a
# Windows-side packaging/contract validator.
$bashRunner = $null
if (Get-Command wsl.exe -ErrorAction SilentlyContinue) { $bashRunner = @{Exe='wsl.exe';Args=@('-d','Debian','--exec','bash')} }
elseif (Get-Command bash -ErrorAction SilentlyContinue) { $bashRunner = @{Exe='bash';Args=@()} }
if ($null -ne $bashRunner) {
    $harness = Join-Path $root 'Linux/Test-KIStackSearXNGReadiness.sh'
    $harnessForRunner=$harness
    if($bashRunner.Exe-eq'wsl.exe'){$harnessForRunner=(@(& wsl.exe -d Debian --exec wslpath -u $harness)|Select-Object -Last 1).Trim()}
    $harnessArgs = $bashRunner.Args + @($harnessForRunner)
    $output = & $bashRunner.Exe @harnessArgs 2>&1
    $exit = $LASTEXITCODE
    foreach($line in $output){Write-Host $line}
    if ($exit -ne 0) { $fail += 'live readiness regression scenarios failed (see Linux/Test-KIStackSearXNGReadiness.sh output above)' }
} else {
    Write-Host 'KI_STACK_READINESS_SELFTEST|skipped=no-bash-runtime-on-this-host'
}

Import-Module (Join-Path $root 'IntegrationPackage.psm1') -Force
$psm1Text = Get-Content (Join-Path $root 'IntegrationPackage.psm1') -Raw

# --- diag11: marker parent directory must be created idempotently ----------
# Root cause: Install-IntegrationPayload wrote 'C:\KI-Stack\modules\integration\installation.json'
# via Set-Content without ensuring 'C:\KI-Stack\modules\integration' existed
# first, so a greenfield install (that folder never created before) failed
# with "Could not find a part of the path ...". Fixed via the dedicated
# Write-IntegrationMarker helper, which New-Item -Force's the parent
# directory immediately before an atomic temp-file-then-rename write. This
# calls the REAL production function directly -- no duplicated logic.
if (-not $psm1Text.Contains('function Write-IntegrationMarker')) { $fail += 'Write-IntegrationMarker helper missing' }
$markerFnMatch = [regex]::Match($psm1Text, '(?s)function Write-IntegrationMarker \{.*?\n\}')
if ($markerFnMatch.Success -and $markerFnMatch.Value -notmatch 'New-Item -ItemType Directory -Force') { $fail += 'REGRESSION: Write-IntegrationMarker no longer ensures its parent directory exists (diag11 reintroduced)' }
if (-not ($psm1Text.Contains("Install-IntegrationRuntime -PackageRoot `$PackageRoot -RuntimeRoot (Join-Path `$TargetRoot 'modules/integration') -Marker `$marker") -and $psm1Text.Contains('Write-IntegrationMarker -Path $markerPath -Content'))) { $fail += 'Install-IntegrationPayload runtime deployment must bind TargetRoot and write its marker via Write-IntegrationMarker' }

$markerSelfTestRoot = Join-Path $env:TEMP ("ki-stack-marker-selftest-" + [guid]::NewGuid().ToString('N'))
try {
    # Scenario 1 (greenfield): parent directory does not exist beforehand.
    $greenfieldMarker = Join-Path $markerSelfTestRoot 'modules\integration\installation.json'
    if (Test-Path (Split-Path -Parent $greenfieldMarker)) { $fail += 'greenfield fixture setup invalid: parent already exists' }
    try {
        Write-IntegrationMarker -Path $greenfieldMarker -Content '{"schemaVersion":"1.0","mode":"greenfield-fixture"}'
        if (-not (Test-Path $greenfieldMarker)) { $fail += 'diag11 greenfield case: marker was not written when parent directory was missing' }
        elseif ((Get-Content $greenfieldMarker -Raw | ConvertFrom-Json).mode -ne 'greenfield-fixture') { $fail += 'diag11 greenfield case: marker content mismatch' }
    } catch { $fail += "diag11 greenfield case threw: $($_.Exception.Message)" }

    # Scenario 2 (existing): directory and a prior marker already exist.
    Write-IntegrationMarker -Path $greenfieldMarker -Content '{"schemaVersion":"1.0","mode":"existing-fixture"}'
    if (-not (Test-Path $greenfieldMarker)) { $fail += 'diag11 existing case: marker missing after re-write' }
    elseif ((Get-Content $greenfieldMarker -Raw | ConvertFrom-Json).mode -ne 'existing-fixture') { $fail += 'diag11 existing case: marker was not overwritten correctly' }

    # No leftover temp file from the atomic write should remain.
    $leftoverTemp = Get-ChildItem (Split-Path -Parent $greenfieldMarker) -File | Where-Object { $_.Name -ne 'installation.json' }
    if ($leftoverTemp) { $fail += "diag11: atomic write left a temp file behind: $($leftoverTemp.Name -join ', ')" }
} finally {
    Remove-Item -LiteralPath $markerSelfTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- diag13: complete Windows runtime deployment and rollback -------------
$runtimeContract=Get-IntegrationRuntimeContract $root
$expectedRuntime=@('Start-KIStack-IntegratedStack.cmd','Start-KIStack-OpenWebUI-WithSearch.cmd','Start-KIStack-SearXNG.cmd','Start-KIStack-SearXNG.ps1','Stop-KIStack-IntegratedStack.cmd','Stop-KIStack-SearXNG.cmd','Stop-KIStack-SearXNG.ps1')
if(@(Compare-Object $expectedRuntime @($runtimeContract.files)-SyncWindow 0).Count){$fail+='integration runtime contract file set'}
$runtimeFixtureRoot=Join-Path ([IO.Path]::GetTempPath())('ki-stack-integration-runtime-'+[guid]::NewGuid().ToString('N'))
$kiStackTarget=Join-Path $runtimeFixtureRoot 'Local AI/KI Stack';$runtimeTarget=Join-Path $kiStackTarget 'modules/integration';$runtimeBackup=Join-Path $runtimeFixtureRoot 'backup';New-Item -ItemType Directory $runtimeBackup -Force|Out-Null
try {
    Backup-IntegrationWindowsRuntime -RuntimeRoot $runtimeTarget -BackupPath $runtimeBackup
    $runtimeResult=Install-IntegrationRuntime -PackageRoot $root -RuntimeRoot $runtimeTarget -Marker ([ordered]@{version='1.5.11';release='KI-Stack-Integration-Execute-v1.5.11'})
    if(-not[bool]$runtimeResult.passed-or-not(Test-IntegrationRuntime -RuntimeRoot $runtimeTarget -Contract $runtimeContract)){$fail+='greenfield runtime deployment incomplete'}
    foreach($requiredStarter in @('Start-KIStack-SearXNG.cmd','Start-KIStack-OpenWebUI-WithSearch.cmd')){if(-not(Test-Path -LiteralPath (Join-Path $runtimeTarget $requiredStarter)-PathType Leaf)){$fail+="greenfield starter missing: $requiredStarter"}}
    $deployedWindowsContent=(Get-ChildItem -LiteralPath $runtimeTarget -File|Where-Object{$_.Extension-in@('.cmd','.ps1')}|ForEach-Object{Get-Content -LiteralPath $_.FullName -Raw})-join"`n"
    if($deployedWindowsContent.Contains('C:\KI-Stack')){$fail+='alternate-root runtime contains default-root fallback'}
    if(-not($deployedWindowsContent.Contains('%~dp0..')-and$deployedWindowsContent.Contains('Join-Path $PSScriptRoot'))){$fail+='runtime starters are not self-relative'}
    $applicationsRoot=Join-Path $kiStackTarget 'modules/applications';New-Item -ItemType Directory -Path $applicationsRoot -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $applicationsRoot 'Start-KIStack-OpenWebUI.cmd'),"@echo off`r`nexit /b 0`r`n",[Text.Encoding]::ASCII)
    $openWebUIOutput=@(& $env:ComSpec /D /C "`"$(Join-Path $runtimeTarget 'Start-KIStack-OpenWebUI-WithSearch.cmd')`"" 2>&1);if($LASTEXITCODE-ne0){$fail+="space-safe OpenWebUI starter resolution failed: $($openWebUIOutput-join' | ')"}
    $startScript=Join-Path $runtimeTarget 'Start-KIStack-SearXNG.ps1';Set-Content -LiteralPath $startScript -Value 'exit 0' -Encoding UTF8
    $startOutput=@(& $env:ComSpec /D /C "`"$(Join-Path $runtimeTarget 'Start-KIStack-SearXNG.cmd')`"" 2>&1);if($LASTEXITCODE-ne0){$fail+="Start-KIStack-SearXNG.cmd not callable: $($startOutput-join' | ')"}
    Restore-IntegrationWindowsRuntime -BackupPath $runtimeBackup
    if(Test-Path -LiteralPath $runtimeTarget){$fail+='greenfield runtime rollback did not remove new target'}

    New-Item -ItemType Directory $runtimeTarget -Force|Out-Null;Set-Content -LiteralPath (Join-Path $runtimeTarget 'installation.json') -Value '{"version":"old"}' -Encoding UTF8;Set-Content -LiteralPath (Join-Path $runtimeTarget 'Start-KIStack-SearXNG.cmd') -Value 'old starter' -Encoding ascii
    $upgradeBackup=Join-Path $runtimeFixtureRoot 'upgrade-backup';New-Item -ItemType Directory $upgradeBackup -Force|Out-Null;Backup-IntegrationWindowsRuntime -RuntimeRoot $runtimeTarget -BackupPath $upgradeBackup
    Install-IntegrationRuntime -PackageRoot $root -RuntimeRoot $runtimeTarget -Marker ([ordered]@{version='1.5.11';release='KI-Stack-Integration-Execute-v1.5.11'})|Out-Null
    Restore-IntegrationWindowsRuntime -BackupPath $upgradeBackup
    if((Get-Content (Join-Path $runtimeTarget 'Start-KIStack-SearXNG.cmd')-Raw).Trim()-ne'old starter'-or(Get-Content (Join-Path $runtimeTarget 'installation.json')-Raw)-notmatch'old'){$fail+='upgrade runtime rollback did not restore prior state'}

    $rootA=Join-Path $runtimeFixtureRoot 'Root A';$rootB=Join-Path $runtimeFixtureRoot 'Root B'
    $runtimeA=Join-Path $rootA 'modules/integration';$runtimeB=Join-Path $rootB 'modules/integration'
    Install-IntegrationRuntime -PackageRoot $root -RuntimeRoot $runtimeA -Marker ([ordered]@{version='1.5.11'})|Out-Null
    Install-IntegrationRuntime -PackageRoot $root -RuntimeRoot $runtimeB -Marker ([ordered]@{version='1.5.11'})|Out-Null
    foreach($pair in @(@{own=$rootA;foreign=$rootB;runtime=$runtimeA},@{own=$rootB;foreign=$rootA;runtime=$runtimeB})){
        $content=(Get-ChildItem -LiteralPath $pair.runtime -File|Where-Object{$_.Extension-in@('.cmd','.ps1')}|ForEach-Object{Get-Content -LiteralPath $_.FullName -Raw})-join"`n"
        if($content.Contains([string]$pair.foreign)-or$content.Contains('C:\KI-Stack')){$fail+='two-root runtime isolation failed'}
    }
} catch {$fail+="integration runtime fixture failed: $($_.Exception.Message)"}
finally{Remove-Item -LiteralPath $runtimeFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue}

# --- Test-IntegrationEndpoint must gate on local routes only ---------------
$endpointFnMatch = [regex]::Match($psm1Text, '(?s)function Test-IntegrationEndpoint \{.*?\n\}')
if (-not $endpointFnMatch.Success) { $fail += 'Test-IntegrationEndpoint function not found' }
else {
    $endpointFn = $endpointFnMatch.Value
    if ($endpointFn -notmatch '/healthz') { $fail += 'Test-IntegrationEndpoint must check /healthz' }
    if ($endpointFn -notmatch '/config') { $fail += 'Test-IntegrationEndpoint must check /config for app identity' }
    if ($endpointFn -match 'search\?q=') { $fail += 'REGRESSION: Test-IntegrationEndpoint (Windows-side readiness) issues a /search request (diag9 reintroduced)' }
}
if (-not $psm1Text.Contains('function Test-IntegrationSearchFunctional')) { $fail += 'Test-IntegrationSearchFunctional (optional, Windows-side) missing' }
$functionalFnMatch = [regex]::Match($psm1Text, '(?s)function Test-IntegrationSearchFunctional \{.*?\n\}')
if ($functionalFnMatch.Success -and $functionalFnMatch.Value -notmatch 'search\?q=') { $fail += 'Test-IntegrationSearchFunctional lost its search-api check' }

$restoreCalled=$false;$payloadFailure=$null;$diagnosticPath=Join-Path $root 'SearXNG-payload-install.fixture.json'
try {
    $diagnosticOutput=@('payload stdout','KI_STACK_PAYLOAD_DIAGNOSTIC|step=local-readiness-readback|exitCode=62|cause=local SearXNG readiness check failed after 60 attempts (last cause: local HTTP endpoint on port 8888 is not the SearXNG application)|revision=fixture-ref|root=/opt/ki-stack/searxng|src=/opt/ki-stack/searxng/src|venv=/opt/ki-stack/searxng/venv|marker=/opt/ki-stack/integration/installation.json')
    Write-IntegrationPayloadDiagnostic -Path $diagnosticPath -ExitCode 62 -Output $diagnosticOutput -ExecutedCommand 'fixture diagnostic command' -Contract $contract|Out-Null
    $diagnostic=Get-Content $diagnosticPath -Raw|ConvertFrom-Json -Depth 20
    if([string]$diagnostic.step-ne'local-readiness-readback'-or[int]$diagnostic.exitCode-ne62-or-not[bool]$diagnostic.outputPresent-or[string]$diagnostic.executedCommand-ne'fixture diagnostic command'-or[string]$diagnostic.internalCause-ne'local SearXNG readiness check failed after 60 attempts (last cause: local HTTP endpoint on port 8888 is not the SearXNG application)'-or[string]$diagnostic.searxngRevision-ne[string]$contract.upstream.revision-or@($diagnostic.output).Count-ne2){$fail+='persistent payload diagnostic mismatch'}
    Assert-IntegrationPayloadExitCode -ExitCode 62 -BackupPath 'fixture-backup' -DiagnosticLogPath $diagnosticPath -RestoreAction {param($Path)$script:restoreCalled=($Path-eq'fixture-backup')}
    $fail+='non-zero payload exit was accepted'
}
catch {
    $payloadFailure=$_
    if($_.Exception -is [Management.Automation.CommandNotFoundException]){$fail+='payload exit produced CommandNotFoundException'}
    if($_.Exception -isnot [Management.Automation.RuntimeException]){$fail+='payload exit did not produce RuntimeException'}
    if($_.Exception.Message-ne"SearXNG payload install failed: 62; diagnosticLog=$diagnosticPath"){$fail+="payload exit message mismatch: $($_.Exception.Message)"}
}
finally{Remove-Item -LiteralPath $diagnosticPath -Force -ErrorAction SilentlyContinue}
if(-not$restoreCalled){$fail+='payload failure did not invoke restore action'}
foreach($emptyCase in @(@{name='null';value=$null},@{name='empty-array';value=[string[]]@()},@{name='empty-string';value=[string[]]@('')})){
    try{
        $parameters=@{Path=$diagnosticPath;ExitCode=62;Output=$emptyCase.value;ExecutedCommand='empty-output diagnostic command';Contract=$contract}
        Write-IntegrationPayloadDiagnostic @parameters|Out-Null
        $emptyDiagnostic=Get-Content $diagnosticPath -Raw|ConvertFrom-Json -Depth 20
        if([bool]$emptyDiagnostic.outputPresent-or[string]$emptyDiagnostic.output-ne'<empty>'-or[int]$emptyDiagnostic.exitCode-ne62-or[string]$emptyDiagnostic.executedCommand-ne'empty-output diagnostic command'){$fail+="empty diagnostic persistence mismatch: $($emptyCase.name)"}
    }catch{$fail+="empty diagnostic threw: $($emptyCase.name): $($_.Exception.Message)"}
    finally{Remove-Item -LiteralPath $diagnosticPath -Force -ErrorAction SilentlyContinue}
}
$result=[ordered]@{passed=($fail.Count-eq0);version='1.5.11';checks=41;failures=$fail;payloadFailureType=if($payloadFailure){$payloadFailure.Exception.GetType().FullName}else{$null};payloadFailureMessage=if($payloadFailure){$payloadFailure.Exception.Message}else{$null}};$result|ConvertTo-Json -Depth 10
if ($fail.Count) { throw ($fail-join'; ') }

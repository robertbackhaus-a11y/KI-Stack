[CmdletBinding()]
param(
    [ValidateSet('Audit','Execute')][string]$Mode = 'Execute',
    [string]$TargetRoot = 'C:\KI-Stack',
    [switch]$Elevated
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$packageRoot = $PSScriptRoot
Import-Module (Join-Path $packageRoot 'Core\KIStack.TargetAcceptance.Core.psm1') -Force
$pwsh = Get-KIStackPowerShell7

if ($Mode -eq 'Execute' -and -not (Test-KIStackAdministrator)) {
    if ($Elevated) { throw 'Administratorrechte konnten nicht hergestellt werden.' }
    $arguments = @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
        '-File',('"' + $PSCommandPath.Replace('"','\"') + '"'),
        '-Mode',$Mode,
        '-TargetRoot',('"' + $TargetRoot.Replace('"','\"') + '"'),
        '-Elevated'
    ) -join ' '
    try {
        $process = Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        exit $process.ExitCode
    } catch {
        Write-Error ('Selbst-Elevation fehlgeschlagen oder abgebrochen: ' + $_.Exception.Message)
        exit 1223
    }
}

$transactionId = 'KI-STACK-ACCEPT-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$startedAt = [DateTime]::UtcNow
$workRoot = Join-Path $env:TEMP $transactionId
$logRoot = Join-Path $workRoot 'Logs'
$backupRoot = Join-Path 'C:\KI-Stack-Recovery-Backup' $transactionId
$reportRoot = Join-Path $TargetRoot 'reports\production-recovery'
$reportPath = Join-Path $reportRoot ($transactionId + '.json')
$latestPath = Join-Path $reportRoot 'Target-Acceptance-latest.json'
$markerPath = Join-Path $TargetRoot 'modules\production-recovery\acceptance.json'
$checks = [Collections.Generic.List[object]]::new()
$warnings = [Collections.Generic.List[string]]::new()
$overlay = $null

function Add-Check([string]$Name,[bool]$Passed,[bool]$Critical,[string]$Detail) {
    [void]$checks.Add([pscustomobject]@{ name=$Name; passed=$Passed; critical=$Critical; detail=$Detail })
    Write-Host ('[{0}] {1} - {2}' -f $(if($Passed){'OK'}else{'FAIL'}),$Name,$Detail)
}

try {
    New-Item -ItemType Directory -Path $workRoot,$logRoot -Force | Out-Null
    Write-Host "=== Paketintegrität prüfen ==="
    $packageIntegrity = Test-KIStackAcceptancePackageIntegrity -PackageRoot $packageRoot
    Add-Check 'Acceptance package integrity' $true $true ("{0} Dateien verifiziert" -f $packageIntegrity.verified)

    $contract = Get-Content -LiteralPath (Join-Path $packageRoot 'Contract\ACCEPTANCE-CONTRACT.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
    $recoveryZip = Join-Path $packageRoot ('Recovery\' + [string]$contract.recoveryArtifact.name)
    Write-Host "=== Recovery-Artefakt mehrstufig prüfen ==="
    $recovery = Test-KIStackRecoveryArtifact -RecoveryZip $recoveryZip -ExpectedSha256 ([string]$contract.recoveryArtifact.sha256) -WorkRoot $workRoot
    Add-Check 'Recovery artifact integrity' $true $true ("Paket={0}; Runtime={1}; Overlay={2}" -f $recovery.packageVerifiedFiles,$recovery.runtimeVerifiedFiles,$recovery.overlayFileCount)

    Write-Host "=== Zielsystem-Preflight ==="
    Add-Check 'Administrator' (Test-KIStackAdministrator) ($Mode -eq 'Execute') ($(if(Test-KIStackAdministrator){'erhöht'}else{'nur Audit möglich'}))
    $targetExists = Test-Path -LiteralPath $TargetRoot -PathType Container
    Add-Check 'Target root' $targetExists $true $TargetRoot
    Add-Check 'PowerShell 7' (Test-Path -LiteralPath $pwsh -PathType Leaf) $true $pwsh

    foreach ($relative in @($contract.requiredModels)) {
        $path = Join-Path $TargetRoot ([string]$relative).Replace('/', '\\')
        Add-Check ("Required model: " + [string]$relative) (Test-Path -LiteralPath $path -PathType Leaf) $true $path
    }

    $wslPath = $null
    try { $wslPath = (Get-Command wsl.exe -ErrorAction Stop).Source } catch {}
    Add-Check 'WSL executable' ($null -ne $wslPath) $true ($(if($wslPath){$wslPath}else{'nicht gefunden'}))
    $debianFound = $false; $wslList = ''
    if ($wslPath) {
        $wslProcess = Invoke-KIStackManagedProcess -FilePath $wslPath -ArgumentList @('-l','-q') -TimeoutSeconds 30 -LogRoot $logRoot -Name 'wsl-list'
        $wslList = ($wslProcess.stdout -replace "`0",'').Trim()
        $debianFound = @($wslList -split "`r?`n" | ForEach-Object { $_.Trim() }) -contains [string]$contract.distribution
    }
    Add-Check 'WSL distribution Debian' $debianFound $true $wslList

    $lmResolved = $false; $lmDetail = ''
    try {
        $candidates = [Collections.Generic.List[string]]::new()
        [void]$candidates.Add('C:\Program Files\LM Studio\LM Studio.exe')
        [void]$candidates.Add((Join-Path $env:USERPROFILE '.lmstudio\bin\lms.exe'))
        [void]$candidates.Add((Join-Path $env:USERPROFILE '.lmstudio\bin\lms.cmd'))
        foreach ($commandName in @('lms.exe','lms.cmd')) {
            try {
                $resolvedCommand = (Get-Command $commandName -ErrorAction Stop).Source
                if ($resolvedCommand) { [void]$candidates.Add($resolvedCommand) }
            } catch {}
        }
        $existing = @($candidates | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        $lmResolved = $existing.Count -gt 0
        $lmDetail = $existing -join '; '
    } catch { $lmDetail = $_.Exception.Message }
    Add-Check 'LM Studio executable or CLI' $lmResolved $true $lmDetail

    $criticalPreflightFailures = @($checks | Where-Object { $_.critical -and -not $_.passed })
    if ($criticalPreflightFailures.Count -gt 0) {
        throw ('Preflight fehlgeschlagen: ' + (($criticalPreflightFailures | ForEach-Object { $_.name }) -join ', '))
    }

    Write-Host "=== Operationalen Stand vergleichen und sichern ==="
    $overlay = Set-KIStackOperationalOverlay -OverlayRoot $recovery.overlayRoot -OverlayManifest $recovery.overlayManifest -TargetRoot $TargetRoot -BackupRoot $backupRoot -AuditOnly:($Mode -eq 'Audit')
    Add-Check 'Operational overlay final integrity' $overlay.passed $true ("Drift={0}; geändert={1}; unverändert={2}" -f $overlay.drift.Count,$overlay.changed.Count,$overlay.unchanged.Count)
    if ($Mode -eq 'Audit' -and $overlay.drift.Count -gt 0) {
        [void]$warnings.Add("Audit hat $($overlay.drift.Count) abweichende Dateien gefunden; keine Änderung vorgenommen.")
    }

    foreach ($relative in @($contract.requiredFiles)) {
        $path = Join-Path $TargetRoot ([string]$relative).Replace('/', '\\')
        Add-Check ("Required file after overlay: " + [string]$relative) (Test-Path -LiteralPath $path -PathType Leaf) $true $path
    }
    foreach ($marker in @($contract.requiredMarkers)) {
        $path = Join-Path $TargetRoot ([string]$marker.path).Replace('/', '\\')
        $ok = $false; $detail = $path
        try {
            $object = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
            $ok = ([string]$object.managedBy -eq [string]$marker.managedBy)
            $detail = if($ok){[string]$object.release}else{"managedBy falsch oder fehlt"}
        } catch { $detail = $_.Exception.Message }
        Add-Check ("Installation marker after overlay: " + [string]$marker.path) $ok $true $detail
    }
    $postOverlayFailures = @($checks | Where-Object { $_.critical -and -not $_.passed })
    if ($Mode -eq 'Execute' -and $postOverlayFailures.Count -gt 0) {
        throw ('Prüfung nach Overlay-Wiederherstellung fehlgeschlagen: ' + (($postOverlayFailures | ForEach-Object { $_.name }) -join ', '))
    }

    $stopResult = $null; $startResult = $null; $endpointResults = @()
    if ($Mode -eq 'Execute') {
        Write-Host "=== KI-Stack kontrolliert stoppen ==="
        $stopScript = Join-Path $TargetRoot 'modules\cutover\Stop-KIStack.ps1'
        $stopResult = Invoke-KIStackManagedProcess -FilePath $pwsh -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$stopScript) -TimeoutSeconds 120 -LogRoot $logRoot -Name 'stack-stop'
        Add-Check 'Controlled stack stop' (-not $stopResult.timedOut -and $stopResult.exitCode -eq 0) $true ("Exit={0}; Timeout={1}" -f $stopResult.exitCode,$stopResult.timedOut)
        Start-Sleep -Seconds 3

        Write-Host "=== KI-Stack starten ==="
        $startScript = Join-Path $TargetRoot 'modules\cutover\Start-KIStack.ps1'
        $startResult = Invoke-KIStackManagedProcess -FilePath $pwsh -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$startScript) -TimeoutSeconds 180 -LogRoot $logRoot -Name 'stack-start'
        $startCommandOk = -not $startResult.timedOut -and $startResult.exitCode -eq 0
        Add-Check 'Stack start command' $startCommandOk $false ("Exit={0}; Timeout={1}" -f $startResult.exitCode,$startResult.timedOut)
        if (-not $startCommandOk) { [void]$warnings.Add('Startkommando war nicht erfolgreich; die unabhängige Endpunktprüfung entscheidet über den Betriebszustand.') }

        Write-Host "=== Unabhängige Endpunktprüfung ==="
        foreach ($endpoint in @($contract.endpoints)) {
            $result = Test-KIStackEndpoint -Endpoint $endpoint -DeadlineSeconds 120
            $endpointResults += $result
            Add-Check ("Endpoint: " + $result.name) $result.reachable $true $result.detail
        }
    }

    $failedCritical = @($checks | Where-Object { $_.critical -and -not $_.passed })
    $passed = ($failedCritical.Count -eq 0)
    $report = [ordered]@{
        schemaVersion = '1.0'
        transactionId = $transactionId
        mode = $Mode
        startedAtUtc = $startedAt.ToString('o')
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
        passed = $passed
        productVersion = [string]$contract.productVersion
        recoveryRevision = [string]$contract.recoveryRevision
        recoveryArtifactSha256 = [string]$contract.recoveryArtifact.sha256
        targetRoot = $TargetRoot
        overlay = $overlay
        stop = $stopResult
        start = $startResult
        endpoints = @($endpointResults)
        checks = @($checks)
        failedCriticalChecks = @($failedCritical | ForEach-Object { $_.name })
        warnings = @($warnings)
        backupRoot = $overlay.backupRoot
        stackLeftRunning = ($Mode -eq 'Execute' -and $passed)
        runtimeCoreInstalledFromRecovery = $false
        recoveryArtifactValidatedOnTargetSystem = $passed
    }
    Write-KIStackJson -Path $reportPath -InputObject $report
    Write-KIStackJson -Path $latestPath -InputObject $report
    if ($passed -and $Mode -eq 'Execute') { Write-KIStackJson -Path $markerPath -InputObject $report }
    Write-Host ''
    Write-Host ('Zielsystemabnahme: ' + $(if($passed){'BESTANDEN'}else{'FEHLGESCHLAGEN'}))
    Write-Host ('Bericht: ' + $reportPath)
    if ($overlay.backupRoot) { Write-Host ('Backup: ' + $overlay.backupRoot) }
    exit $(if($passed){0}else{1})
} catch {
    $errorText = $_.Exception.Message
    try {
        $failure = [ordered]@{
            schemaVersion='1.0'; transactionId=$transactionId; mode=$Mode; startedAtUtc=$startedAt.ToString('o'); completedAtUtc=[DateTime]::UtcNow.ToString('o'); passed=$false; targetRoot=$TargetRoot; error=$errorText; checks=@($checks); warnings=@($warnings); overlay=$overlay; backupRoot=$(if(Test-Path -LiteralPath $backupRoot){$backupRoot}else{$null})
        }
        Write-KIStackJson -Path $reportPath -InputObject $failure
        Write-KIStackJson -Path $latestPath -InputObject $failure
    } catch {}
    Write-Error ('Zielsystemabnahme fehlgeschlagen: ' + $errorText)
    if (Test-Path -LiteralPath $reportPath) { Write-Host ('Bericht: ' + $reportPath) }
    exit 1
} finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

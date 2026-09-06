[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BackupPath,
    [string]$TargetRoot = 'C:\KI-Stack',
    [string]$DatabasePath,
    [string]$PythonExecutable,
    [string]$HealthBaseUrl = 'http://127.0.0.1:8080',
    [int]$HealthTimeoutSec = 60
)

# KI-Stack Open WebUI Database Restore (2.17 Phase 2)
#
# Always an explicit operator action -- never invoked automatically by install/reconcile.
# Restores exactly the file Backup-KIStackOpenWebUIDatabase.ps1 produces (a plain, complete
# SQLite file written via VACUUM INTO). Never deletes the source $BackupPath.
#
# Live-target vs. test-path behavior: the Open WebUI process stop/start + HTTP health-check
# only apply when the resolved destination database path is the REAL live target
# (<TargetRoot>\OpenWebUI\data\webui.db). Any other -DatabasePath (a temporary fixture used for
# a controlled restore acceptance test) is restored at the file level only -- no process on this
# machine is stopped or started, and no HTTP call is made. This is detected automatically (not a
# switch the caller must remember to set correctly), so a real target can never be restored
# without its service lifecycle by mistake.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'
}

function Resolve-KIStackWebUIRestorePython {
    param([string]$TargetRoot, [string]$Override)
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        if (-not (Test-Path -LiteralPath $Override -PathType Leaf)) { throw "PythonExecutable nicht gefunden: $Override" }
        return $Override
    }
    $venvPython = Join-Path $TargetRoot 'python\venvs\openwebui\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        throw "Open-WebUI-Python-venv nicht gefunden unter '$venvPython' -- keine sichere SQLite-Prüfung möglich."
    }
    $venvPython
}

function Test-KIStackWebUISQLiteIntegrity {
    param([string]$PythonExecutable, [string]$Path)
    $pyScript = @'
import sqlite3, sys, json
path = sys.argv[1]
con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
try:
    cur = con.cursor()
    cur.execute("PRAGMA integrity_check(1);")
    rows = [r[0] for r in cur.fetchall()]
    result = "ok" if rows == ["ok"] else "; ".join(rows)
    cur.execute("SELECT count(*) FROM sqlite_master WHERE type='table';")
    table_count = cur.fetchone()[0]
finally:
    con.close()
print(json.dumps({"integrityCheck": result, "tableCount": table_count}))
'@
    $tempPy = Join-Path ([IO.Path]::GetTempPath()) ("kistack-webui-restore-check-{0}.py" -f ([Guid]::NewGuid()))
    Set-Content -LiteralPath $tempPy -Value $pyScript -Encoding utf8NoBOM
    try {
        $raw = & $PythonExecutable $tempPy $Path 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $tempPy -Force -ErrorAction SilentlyContinue
    }
    if ($exitCode -ne 0) { return [pscustomobject]@{ ok = $false; integrityCheck = "SQLite konnte Datei nicht öffnen/lesen: $raw"; tableCount = 0 } }
    $parsed = $raw | ConvertFrom-Json -Depth 10
    [pscustomobject]@{ ok = ([string]$parsed.integrityCheck -eq 'ok'); integrityCheck = [string]$parsed.integrityCheck; tableCount = [int]$parsed.tableCount }
}

# 1. Validate the backup itself -- fail closed before touching anything.
if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
    throw "Backup nicht gefunden: $BackupPath"
}
$pythonExe = Resolve-KIStackWebUIRestorePython -TargetRoot $TargetRoot -Override $PythonExecutable
$backupIntegrity = Test-KIStackWebUISQLiteIntegrity -PythonExecutable $pythonExe -Path $BackupPath
if (-not $backupIntegrity.ok) {
    throw "Backup ist keine valide/intakte SQLite-Datenbank: $($backupIntegrity.integrityCheck)"
}

# 2. Validate hash against sidecar metadata, IF it exists (its absence is not itself a failure).
$metadataPath = "$BackupPath.json"
$metadataValidated = $false
$metadata = $null
if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -Depth 10
    $actualSha256 = (Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([string]$metadata.sha256 -ne $actualSha256) {
        throw "SHA256 der Backup-Datei stimmt nicht mit dem Metadaten-Sidecar überein -- Datei möglicherweise beschädigt oder ausgetauscht. Erwartet: $($metadata.sha256), tatsächlich: $actualSha256"
    }
    $metadataValidated = $true
}

# 3. Resolve destination and detect whether this is the real live target.
$resolvedDatabasePath = if ([string]::IsNullOrWhiteSpace($DatabasePath)) { Join-Path $TargetRoot 'OpenWebUI\data\webui.db' } else { $DatabasePath }
$canonicalLiveDatabasePath = Join-Path $TargetRoot 'OpenWebUI\data\webui.db'
$isLiveTarget = [string]::Equals(
    [IO.Path]::GetFullPath($resolvedDatabasePath),
    [IO.Path]::GetFullPath($canonicalLiveDatabasePath),
    [StringComparison]::OrdinalIgnoreCase
)

# 4. Pre-restore safety backup of whatever currently sits at the destination (if anything).
$preRestoreSafetyBackup = $null
if (Test-Path -LiteralPath $resolvedDatabasePath -PathType Leaf) {
    $safetyDir = Join-Path $TargetRoot 'backups\openwebui-database\pre-restore-safety'
    $backupScript = Join-Path $PSScriptRoot 'Backup-KIStackOpenWebUIDatabase.ps1'
    $preRestoreSafetyBackup = & $backupScript -TargetRoot $TargetRoot -DatabasePath $resolvedDatabasePath -BackupDirectory $safetyDir -PythonExecutable $pythonExe
}

# 5. Stop the live Open WebUI process ONLY for the real target -- same command-line-matching
#    pattern already used by the installed Stop-KIStack-Applications.ps1 (venv path token +
#    'open_webui' in the process command line), so this does not invent a second, divergent way
#    of finding the process.
$stoppedProcessCount = 0
if ($isLiveTarget) {
    $venvToken = (Join-Path $TargetRoot 'python\venvs\openwebui').ToLowerInvariant()
    $matchingProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $commandLine = [string]$_.CommandLine
        -not [string]::IsNullOrWhiteSpace($commandLine) -and
        $commandLine.ToLowerInvariant().Contains($venvToken) -and
        $commandLine.ToLowerInvariant().Contains('open_webui')
    })
    foreach ($processEntry in $matchingProcesses) {
        Stop-Process -Id ([int]$processEntry.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    $stoppedProcessCount = $matchingProcesses.Count
    if ($stoppedProcessCount -gt 0) { Start-Sleep -Seconds 2 }
}

# 6. Replace the database atomically (same-volume rename), handling stale -wal/-shm sidecars.
$restoreSucceeded = $false
$rolledBack = $false
try {
    $tempTarget = "$resolvedDatabasePath.restoring.tmp"
    if (Test-Path -LiteralPath $tempTarget) { Remove-Item -LiteralPath $tempTarget -Force }
    Copy-Item -LiteralPath $BackupPath -Destination $tempTarget -Force
    foreach ($sidecarSuffix in @('-wal', '-shm')) {
        $sidecarPath = "$resolvedDatabasePath$sidecarSuffix"
        if (Test-Path -LiteralPath $sidecarPath) { Remove-Item -LiteralPath $sidecarPath -Force }
    }
    Move-Item -LiteralPath $tempTarget -Destination $resolvedDatabasePath -Force

    # 7. Post-restore integrity check -- if this fails, auto-rollback to the pre-restore safety
    #    backup we just took, rather than leaving a known-broken database in place.
    $postRestoreIntegrity = Test-KIStackWebUISQLiteIntegrity -PythonExecutable $pythonExe -Path $resolvedDatabasePath
    if (-not $postRestoreIntegrity.ok) {
        if ($null -ne $preRestoreSafetyBackup) {
            Copy-Item -LiteralPath $preRestoreSafetyBackup.backupPath -Destination $resolvedDatabasePath -Force
            $rolledBack = $true
        }
        throw "Integritätsprüfung nach Restore fehlgeschlagen ($($postRestoreIntegrity.integrityCheck)) -- $(if ($rolledBack) { 'automatisch auf Pre-Restore-Sicherheitskopie zurückgesetzt.' } else { 'KEIN Rollback möglich, da keine Pre-Restore-Sicherheitskopie existierte.' })"
    }
    $restoreSucceeded = $true
} finally {
    # 8. Restart + health-check ONLY for the real live target, regardless of outcome above, so a
    #    stopped production service is never silently left down.
    $serviceHealth = $null
    if ($isLiveTarget) {
        $startScript = Join-Path $TargetRoot 'modules\applications\Start-KIStack-OpenWebUI.cmd'
        if (Test-Path -LiteralPath $startScript -PathType Leaf) {
            Start-Process -FilePath 'cmd.exe' -ArgumentList '/D', '/C', "start ""KI-Stack Open WebUI"" cmd.exe /D /K call ""$startScript""" -WindowStyle Hidden | Out-Null
        }
        $deadline = [DateTime]::UtcNow.AddSeconds($HealthTimeoutSec)
        $healthy = $false
        $dbHealthy = $false
        $lastReason = $null
        while ([DateTime]::UtcNow -lt $deadline -and -not ($healthy -and $dbHealthy)) {
            Start-Sleep -Seconds 2
            try {
                if (-not $healthy) {
                    $resp = Invoke-WebRequest -Uri "$HealthBaseUrl/health" -Method Get -TimeoutSec 5 -ErrorAction Stop
                    if ([int]$resp.StatusCode -eq 200) { $healthy = $true }
                }
                if ($healthy -and -not $dbHealthy) {
                    $respDb = Invoke-WebRequest -Uri "$HealthBaseUrl/health/db" -Method Get -TimeoutSec 5 -ErrorAction Stop
                    if ([int]$respDb.StatusCode -eq 200) { $dbHealthy = $true }
                }
            } catch { $lastReason = $_.Exception.Message }
        }
        $serviceHealth = [pscustomobject]@{ healthy = $healthy; dbHealthy = $dbHealthy; reason = if ($healthy -and $dbHealthy) { $null } else { $lastReason } }
    }
}

[pscustomobject][ordered]@{
    passed                  = $restoreSucceeded -and -not $rolledBack
    backupPath              = $BackupPath
    metadataValidated       = $metadataValidated
    backupIntegrityCheck    = $backupIntegrity.integrityCheck
    restoredTo              = $resolvedDatabasePath
    isLiveTarget            = $isLiveTarget
    preRestoreSafetyBackup  = if ($null -ne $preRestoreSafetyBackup) { $preRestoreSafetyBackup.backupPath } else { $null }
    rolledBack              = $rolledBack
    stoppedProcessCount     = $stoppedProcessCount
    serviceHealth           = $serviceHealth
    sourceBackupDeleted     = $false
}

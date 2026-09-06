[CmdletBinding()]
param(
    [string]$TargetRoot = 'C:\KI-Stack',
    [string]$DatabasePath,
    [string]$BackupDirectory,
    [int]$RetentionCount = 0,
    [switch]$Verify,
    [string]$PythonExecutable
)

# KI-Stack Open WebUI Database Backup (2.17 Phase 2)
#
# Method: SQLite's own "VACUUM INTO" statement, issued over a read-only connection opened
# through the standard library `sqlite3` module of the SAME Python venv Open WebUI itself runs
# under. This is the SQLite Online Backup mechanism referenced in
# OPENWEBUI-DATABASE-BACKUP-CONTRACT.md -- NOT a raw filesystem copy of webui.db.
#
# Why this is required, not merely preferred: the live target was confirmed (2.17 Phase 2,
# real verification) to run `PRAGMA journal_mode=WAL` continuously, with an always-open
# SQLAlchemy async engine connection pool (writes can occur at any moment). A plain
# `Copy-Item` of only webui.db can silently omit committed data still sitting in the -wal
# sidecar, or race a live checkpoint -- either way, an inconsistent snapshot. `VACUUM INTO`
# instead opens its own read transaction against the live database (exactly like any other
# concurrent reader; it never blocks or is blocked by Open WebUI's own writers in WAL mode)
# and writes a single, complete, internally consistent, freshly-vacuumed copy to a brand-new
# file. No stop of Open WebUI is required or performed.
#
# Fail-closed: if the venv Python / stdlib sqlite3 is unavailable, or VACUUM INTO fails for any
# reason, this script throws -- it never falls back to a raw file copy.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'
}

function Resolve-KIStackWebUIBackupPython {
    param([string]$TargetRoot, [string]$Override)
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        if (-not (Test-Path -LiteralPath $Override -PathType Leaf)) { throw "PythonExecutable nicht gefunden: $Override" }
        return $Override
    }
    $venvPython = Join-Path $TargetRoot 'python\venvs\openwebui\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        throw "Open-WebUI-Python-venv nicht gefunden unter '$venvPython' -- kein sicheres SQLite-Backup möglich (kein Fallback auf Rohkopie)."
    }
    $venvPython
}

$resolvedDatabasePath = if ([string]::IsNullOrWhiteSpace($DatabasePath)) { Join-Path $TargetRoot 'OpenWebUI\data\webui.db' } else { $DatabasePath }
if (-not (Test-Path -LiteralPath $resolvedDatabasePath -PathType Leaf)) {
    throw "Quelldatenbank nicht gefunden: $resolvedDatabasePath"
}

$resolvedBackupDirectory = if ([string]::IsNullOrWhiteSpace($BackupDirectory)) { Join-Path $TargetRoot 'backups\openwebui-database' } else { $BackupDirectory }
New-Item -ItemType Directory -Path $resolvedBackupDirectory -Force | Out-Null

$pythonExe = Resolve-KIStackWebUIBackupPython -TargetRoot $TargetRoot -Override $PythonExecutable

$timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$backupFileName = "webui-db-backup-$timestamp.sqlite3"
$backupFilePath = Join-Path $resolvedBackupDirectory $backupFileName
$metadataFilePath = "$backupFilePath.json"
if (Test-Path -LiteralPath $backupFilePath) { throw "Zielbackup existiert bereits (Namenskollision): $backupFilePath" }

# The backup step (VACUUM INTO) and the mandatory post-write integrity check both run in one
# short-lived Python process -- this is the SAME process that must not partially succeed: if
# either step fails, $LASTEXITCODE is non-zero and no trusted result is produced.
$pyScript = @'
import sqlite3, sys, json

src, dst, deep = sys.argv[1], sys.argv[2], sys.argv[3] == '1'

source_con = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
try:
    source_con.execute("VACUUM INTO ?", (dst,))
finally:
    source_con.close()

# Never trust the write alone -- re-open the freshly written file as an independent connection.
check_con = sqlite3.connect(f"file:{dst}?mode=ro", uri=True)
try:
    cur = check_con.cursor()
    cur.execute("PRAGMA integrity_check(%s);" % ("100" if deep else "1"))
    integrity_rows = [r[0] for r in cur.fetchall()]
    integrity_check = "ok" if integrity_rows == ["ok"] else "; ".join(integrity_rows)
    cur.execute("SELECT count(*) FROM sqlite_master WHERE type='table';")
    table_count = cur.fetchone()[0]

    table_row_counts = None
    if deep:
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
        names = [r[0] for r in cur.fetchall()]
        table_row_counts = {}
        for name in names:
            cur.execute(f'SELECT count(*) FROM "{name}"')
            table_row_counts[name] = cur.fetchone()[0]
finally:
    check_con.close()

print(json.dumps({
    "integrityCheck": integrity_check,
    "tableCount": table_count,
    "tableRowCounts": table_row_counts,
}))
'@
$tempPy = Join-Path ([IO.Path]::GetTempPath()) ("kistack-webui-backup-{0}.py" -f ([Guid]::NewGuid()))
Set-Content -LiteralPath $tempPy -Value $pyScript -Encoding utf8NoBOM
$verifyFlag = if ($Verify) { '1' } else { '0' }
try {
    $raw = & $pythonExe $tempPy $resolvedDatabasePath $backupFilePath $verifyFlag 2>&1
    $exitCode = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $tempPy -Force -ErrorAction SilentlyContinue
}
if ($exitCode -ne 0) {
    if (Test-Path -LiteralPath $backupFilePath) { Remove-Item -LiteralPath $backupFilePath -Force -ErrorAction SilentlyContinue }
    throw "VACUUM-INTO-Backup fehlgeschlagen (ExitCode $exitCode): $raw"
}
$verification = $raw | ConvertFrom-Json -Depth 20
if ([string]$verification.integrityCheck -ne 'ok') {
    Remove-Item -LiteralPath $backupFilePath -Force -ErrorAction SilentlyContinue
    throw "Backup-Integritätsprüfung fehlgeschlagen: $($verification.integrityCheck)"
}

$backupFileItem = Get-Item -LiteralPath $backupFilePath
$sha256 = (Get-FileHash -LiteralPath $backupFilePath -Algorithm SHA256).Hash.ToLowerInvariant()
$sourceSizeBytes = (Get-Item -LiteralPath $resolvedDatabasePath).Length

$openWebUIVersion = $null
try {
    $ver = & $pythonExe -c "import importlib.metadata as m; print(m.version('open-webui'))" 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($ver)) { $openWebUIVersion = $ver.Trim() }
} catch { $openWebUIVersion = $null }

$kiStackVersion = $null
$installerVersionFile = Join-Path $TargetRoot 'installer\complete\VERSION'
if (Test-Path -LiteralPath $installerVersionFile -PathType Leaf) {
    $kiStackVersion = (Get-Content -LiteralPath $installerVersionFile -Raw).Trim()
}

$createdAtUtc = [DateTime]::UtcNow.ToString('o')
$metadata = [ordered]@{
    schemaVersion     = '1.0'
    sourcePath        = $resolvedDatabasePath
    createdAtUtc      = $createdAtUtc
    backupMethod      = 'sqlite-vacuum-into'
    sourceSizeBytes   = $sourceSizeBytes
    backupSizeBytes   = $backupFileItem.Length
    sha256            = $sha256
    openWebUIVersion  = $openWebUIVersion
    kiStackVersion    = $kiStackVersion
    integrityCheck    = [string]$verification.integrityCheck
    tableCount        = [int]$verification.tableCount
    deepVerify        = [bool]$Verify
}
$tempMetadata = "$metadataFilePath.tmp"
$metadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tempMetadata -Encoding utf8NoBOM
Move-Item -LiteralPath $tempMetadata -Destination $metadataFilePath -Force

$deletedBackups = @()
if ($RetentionCount -gt 0) {
    $existing = @(Get-ChildItem -LiteralPath $resolvedBackupDirectory -Filter 'webui-db-backup-*.sqlite3' -File | Sort-Object Name -Descending)
    if ($existing.Count -gt $RetentionCount) {
        $toDelete = $existing | Select-Object -Skip $RetentionCount
        foreach ($old in $toDelete) {
            $oldMeta = "$($old.FullName).json"
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $oldMeta) { Remove-Item -LiteralPath $oldMeta -Force -ErrorAction SilentlyContinue }
            $deletedBackups += @($old.Name)
        }
    }
}

[pscustomobject][ordered]@{
    passed            = $true
    sourceDatabase    = $resolvedDatabasePath
    backupPath        = $backupFilePath
    metadataPath      = $metadataFilePath
    createdAtUtc      = $createdAtUtc
    sizeBytes         = $backupFileItem.Length
    sha256            = $sha256
    method            = 'sqlite-vacuum-into'
    verification      = [pscustomobject]@{ integrityCheck = [string]$verification.integrityCheck; tableCount = [int]$verification.tableCount; deep = [bool]$Verify; tableRowCounts = $verification.tableRowCounts }
    mutatesDatabase   = $false
    retention         = [pscustomobject]@{ requested = $RetentionCount; deleted = @($deletedBackups) }
}

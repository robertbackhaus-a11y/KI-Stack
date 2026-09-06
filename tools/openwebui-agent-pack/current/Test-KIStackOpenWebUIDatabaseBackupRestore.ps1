[CmdletBinding()]
param([string]$PythonExecutable)

# Offline regression for Backup-KIStackOpenWebUIDatabase.ps1 / Restore-KIStackOpenWebUIDatabase.ps1
# (2.17 Phase 2). Uses only temporary SQLite fixtures under a throwaway temp directory -- never
# touches C:\KI-Stack or any real webui.db. Both scripts under test are invoked with an explicit
# -DatabasePath override, so no fixture here is ever mistaken for the real live target (the
# restore script's own isLiveTarget auto-detection is exactly what this proves in Fall E below).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 ist erforderlich; Windows PowerShell wird nicht unterstützt.'
}

$fail = [Collections.Generic.List[string]]::new()
$packageRoot = $PSScriptRoot
$backupScript = Join-Path $packageRoot 'Backup-KIStackOpenWebUIDatabase.ps1'
$restoreScript = Join-Path $packageRoot 'Restore-KIStackOpenWebUIDatabase.ps1'

if ([string]::IsNullOrWhiteSpace($PythonExecutable)) {
    $PythonExecutable = 'C:\KI-Stack\python\venvs\openwebui\Scripts\python.exe'
}
if (-not (Test-Path -LiteralPath $PythonExecutable -PathType Leaf)) {
    throw "Test-Fixture-Python nicht gefunden: $PythonExecutable (per -PythonExecutable überschreibbar)."
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("kistack-webui-backup-test-{0}" -f ([Guid]::NewGuid()))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$fixtureDb = Join-Path $tempRoot 'fixture.db'
$backupDir = Join-Path $tempRoot 'backups'

function New-KIStackTestFixtureDb {
    param([string]$Path, [string]$Value)
    $py = @'
import sqlite3, sys
path, value = sys.argv[1], sys.argv[2]
con = sqlite3.connect(path)
con.execute("CREATE TABLE foo(id INTEGER PRIMARY KEY, val TEXT)")
con.execute("INSERT INTO foo(val) VALUES (?)", (value,))
con.commit()
con.close()
'@
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("kistack-fixture-create-{0}.py" -f ([Guid]::NewGuid()))
    Set-Content -LiteralPath $tmp -Value $py -Encoding utf8NoBOM
    try { & $PythonExecutable $tmp $Path $Value | Out-Null } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Get-KIStackTestFixtureValue {
    param([string]$Path)
    $py = @'
import sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
cur = con.cursor()
cur.execute("SELECT val FROM foo ORDER BY id LIMIT 1")
row = cur.fetchone()
print(row[0] if row else "")
con.close()
'@
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("kistack-fixture-read-{0}.py" -f ([Guid]::NewGuid()))
    Set-Content -LiteralPath $tmp -Value $py -Encoding utf8NoBOM
    try { (& $PythonExecutable $tmp $Path).Trim() } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

try {
    New-KIStackTestFixtureDb -Path $fixtureDb -Value 'original-acceptance-value'

    # --- Backup: Fall A -- source DB missing -> fail ---
    try {
        & $backupScript -DatabasePath (Join-Path $tempRoot 'does-not-exist.db') -BackupDirectory $backupDir -PythonExecutable $PythonExecutable | Out-Null
        $fail.Add('Fall A: Backup mit fehlender Quelle hätte werfen müssen')
    } catch { }

    # --- Backup: Fall B -- normal backup: destination creation, metadata, SHA256, integrity, no source mutation ---
    $hashBefore = (Get-FileHash -LiteralPath $fixtureDb -Algorithm SHA256).Hash
    $goodBackup = & $backupScript -DatabasePath $fixtureDb -BackupDirectory $backupDir -PythonExecutable $PythonExecutable
    $hashAfter = (Get-FileHash -LiteralPath $fixtureDb -Algorithm SHA256).Hash
    if (-not $goodBackup.passed) { $fail.Add('Fall B: Backup meldet passed=false') }
    if (-not (Test-Path -LiteralPath $goodBackup.backupPath -PathType Leaf)) { $fail.Add('Fall B: Backup-Datei wurde nicht erstellt') }
    if (-not (Test-Path -LiteralPath $goodBackup.metadataPath -PathType Leaf)) { $fail.Add('Fall B: Metadaten-Sidecar wurde nicht erstellt') }
    $meta = Get-Content -LiteralPath $goodBackup.metadataPath -Raw | ConvertFrom-Json -Depth 10
    $actualBackupSha256 = (Get-FileHash -LiteralPath $goodBackup.backupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([string]$meta.sha256 -ne $actualBackupSha256) { $fail.Add('Fall B: SHA256 im Sidecar stimmt nicht mit der tatsächlichen Datei überein') }
    if ([string]$goodBackup.sha256 -ne $actualBackupSha256) { $fail.Add('Fall B: SHA256 im Rückgabeobjekt stimmt nicht mit der tatsächlichen Datei überein') }
    if ([string]$goodBackup.verification.integrityCheck -ne 'ok') { $fail.Add('Fall B: Integritätsprüfung des Backups nicht ok') }
    if ($hashBefore -ne $hashAfter) { $fail.Add('Fall B: Quelldatenbank wurde durch das Backup verändert') }
    if ([bool]$goodBackup.mutatesDatabase -ne $false) { $fail.Add('Fall B: mutatesDatabase muss false sein') }

    # --- Backup: Fall C -- deep -Verify includes per-table row counts ---
    Start-Sleep -Seconds 1
    $deepBackup = & $backupScript -DatabasePath $fixtureDb -BackupDirectory $backupDir -PythonExecutable $PythonExecutable -Verify
    if (-not $deepBackup.verification.deep) { $fail.Add('Fall C: deep-Verify-Flag wurde nicht gesetzt') }
    if ($null -eq $deepBackup.verification.tableRowCounts -or [int]$deepBackup.verification.tableRowCounts.foo -ne 1) { $fail.Add('Fall C: tableRowCounts.foo sollte 1 sein') }

    # --- Backup: Fall D -- retention (own directory, isolated from $goodBackup so later Restore
    # falls can still rely on it existing) ---
    $retentionDir = Join-Path $tempRoot 'retention-backups'
    & $backupScript -DatabasePath $fixtureDb -BackupDirectory $retentionDir -PythonExecutable $PythonExecutable | Out-Null
    Start-Sleep -Seconds 1
    & $backupScript -DatabasePath $fixtureDb -BackupDirectory $retentionDir -PythonExecutable $PythonExecutable | Out-Null
    Start-Sleep -Seconds 1
    & $backupScript -DatabasePath $fixtureDb -BackupDirectory $retentionDir -PythonExecutable $PythonExecutable -RetentionCount 2 | Out-Null
    $remaining = @(Get-ChildItem -LiteralPath $retentionDir -Filter 'webui-db-backup-*.sqlite3' -File)
    if ($remaining.Count -ne 2) { $fail.Add("Fall D: Retention hat nicht auf 2 Backups reduziert (tatsächlich: $($remaining.Count))") }
    foreach ($r in $remaining) { if (-not (Test-Path -LiteralPath "$($r.FullName).json")) { $fail.Add("Fall D: verwaistes Backup ohne Metadaten nach Retention: $($r.Name)") } }

    # --- Restore: Fall E -- missing backup -> fail ---
    try {
        & $restoreScript -BackupPath (Join-Path $tempRoot 'nope.sqlite3') -TargetRoot $tempRoot -DatabasePath $fixtureDb -PythonExecutable $PythonExecutable | Out-Null
        $fail.Add('Fall E: Restore mit fehlendem Backup hätte werfen müssen')
    } catch { }

    # --- Restore: Fall F -- invalid SQLite file -> fail ---
    $garbagePath = Join-Path $tempRoot 'garbage.sqlite3'
    Set-Content -LiteralPath $garbagePath -Value 'this is not a sqlite database' -Encoding utf8NoBOM
    try {
        & $restoreScript -BackupPath $garbagePath -TargetRoot $tempRoot -DatabasePath $fixtureDb -PythonExecutable $PythonExecutable | Out-Null
        $fail.Add('Fall F: Restore mit ungültiger SQLite-Datei hätte werfen müssen')
    } catch { }

    # --- Restore: Fall G -- tampered metadata hash -> fail ---
    $tamperBackup = & $backupScript -DatabasePath $fixtureDb -BackupDirectory (Join-Path $tempRoot 'tamper-backups') -PythonExecutable $PythonExecutable
    $tamperMeta = Get-Content -LiteralPath $tamperBackup.metadataPath -Raw | ConvertFrom-Json -Depth 10
    $tamperMeta.sha256 = ('0' * 64)
    $tamperMeta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tamperBackup.metadataPath -Encoding utf8NoBOM
    try {
        & $restoreScript -BackupPath $tamperBackup.backupPath -TargetRoot $tempRoot -DatabasePath $fixtureDb -PythonExecutable $PythonExecutable | Out-Null
        $fail.Add('Fall G: Restore mit manipuliertem Metadaten-Hash hätte werfen müssen')
    } catch { }

    # --- Restore: Fall H -- full real flow: mutate fixture, restore from good backup, verify content + safety backup + non-live path + source-backup preserved ---
    Remove-Item -LiteralPath $fixtureDb -Force
    New-KIStackTestFixtureDb -Path $fixtureDb -Value 'MUTATED-should-be-reverted'
    $preRestoreHash = (Get-FileHash -LiteralPath $goodBackup.backupPath -Algorithm SHA256).Hash

    $restoreResult = & $restoreScript -BackupPath $goodBackup.backupPath -TargetRoot $tempRoot -DatabasePath $fixtureDb -PythonExecutable $PythonExecutable
    if (-not $restoreResult.passed) { $fail.Add('Fall H: Restore meldet passed=false') }
    if ([bool]$restoreResult.isLiveTarget -ne $false) { $fail.Add('Fall H: isLiveTarget hätte false sein müssen (Test-Fixture-Pfad, kein echtes Ziel)') }
    if ([bool]$restoreResult.rolledBack -ne $false) { $fail.Add('Fall H: rolledBack hätte false sein müssen (Restore war erfolgreich)') }
    if ([string]::IsNullOrWhiteSpace([string]$restoreResult.preRestoreSafetyBackup) -or -not (Test-Path -LiteralPath ([string]$restoreResult.preRestoreSafetyBackup) -PathType Leaf)) {
        $fail.Add('Fall H: Pre-Restore-Sicherheitskopie wurde nicht erstellt')
    }
    $restoredValue = Get-KIStackTestFixtureValue -Path $fixtureDb
    if ($restoredValue -ne 'original-acceptance-value') { $fail.Add("Fall H: Wiederhergestellter Inhalt stimmt nicht (erwartet 'original-acceptance-value', erhalten '$restoredValue')") }
    $postRestoreHash = (Get-FileHash -LiteralPath $goodBackup.backupPath -Algorithm SHA256).Hash
    if ($preRestoreHash -ne $postRestoreHash) { $fail.Add('Fall H: Quell-Backup wurde durch den Restore verändert') }
    if (-not (Test-Path -LiteralPath $goodBackup.backupPath -PathType Leaf)) { $fail.Add('Fall H: Quell-Backup wurde gelöscht (verboten)') }
    if ([bool]$restoreResult.sourceBackupDeleted -ne $false) { $fail.Add('Fall H: sourceBackupDeleted muss false sein') }

    # --- Restore: Fall I -- post-restore integrity is asserted as part of the same flow ---
    $postIntegrity = & $PythonExecutable -c "import sqlite3,sys;c=sqlite3.connect('file:$($fixtureDb -replace '\\','/')?mode=ro',uri=True);cur=c.cursor();cur.execute('PRAGMA integrity_check(1);');print(cur.fetchone()[0])"
    if ($postIntegrity.Trim() -ne 'ok') { $fail.Add('Fall I: Ziel-DB nach Restore nicht integer') }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$result = [ordered]@{
    version  = '1.0.0'
    passed   = ($fail.Count -eq 0)
    failures = @($fail)
    fixtures = @('backup-source-missing', 'backup-normal', 'backup-deep-verify', 'backup-retention', 'restore-missing-backup', 'restore-invalid-sqlite', 'restore-tampered-metadata', 'restore-full-flow', 'restore-post-integrity')
}
$result | ConvertTo-Json -Depth 10
if ($fail.Count) { throw ('Backup/Restore-Regression fehlgeschlagen: ' + ($fail -join '; ')) }

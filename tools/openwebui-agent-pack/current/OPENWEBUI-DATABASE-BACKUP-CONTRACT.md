# KI-Stack Open WebUI Database Backup/Restore Contract

**Status: adopted, 2.17 Phase 2.**
**Location note:** placed here for the same reason `MEMORY-CONTRACT.md` is — Open WebUI's
database has no dedicated KI-Stack-owned component of its own; this is the closest, most
relevant existing home. Not part of the Agent Pack's own versioned install/reconcile contract
(not listed in `Test-OpenWebUIAgentPack.ps1`'s required-file set, no `VERSION`/`MANIFEST.json`
coupling) — a standalone operator capability that happens to live in this folder.

## Purpose

A minimal, deterministic backup/restore mechanism for the single SQLite database file backing
Open WebUI's entire persistent state — chats, users, and (since 2.17 Phase 1) native Memory.
Not a general enterprise backup system, no cloud target, no new database engine, no encryption
layer, no migration of Open WebUI storage.

## Exact Protected Database

`C:\KI-Stack\OpenWebUI\data\webui.db` — verified live (2.17 Phase 2): SQLite format, journal
mode **WAL** (`DATABASE_ENABLE_SQLITE_WAL`, confirmed via `PRAGMA journal_mode`), with active
`-wal`/`-shm` sidecars present during normal operation. Open WebUI keeps this database open
continuously through a SQLAlchemy async engine connection pool (`pool_size` up to 512,
`check_same_thread=False`) — writes can occur at any moment during normal operation, including
while a backup runs.

## Selected Backup Method

**SQLite `VACUUM INTO`**, issued over a read-only connection opened via the standard-library
`sqlite3` module of the same Python venv Open WebUI itself runs under
(`C:\KI-Stack\python\venvs\openwebui\Scripts\python.exe`).

Rejected alternatives and why:

- **Raw file copy while running (A)** — unsafe. In WAL mode, recently committed data can still
  live only in the `-wal` sidecar; a plain copy of just `webui.db` can miss it, or race an
  in-progress checkpoint, producing a torn/inconsistent snapshot.
- **Stop Open WebUI, copy DB, restart (B)** — unnecessary and more disruptive than required.
  `VACUUM INTO` provides an equally consistent snapshot without an interruption, so this project
  deliberately does not stop the service for a routine backup.
- **Copy DB + WAL/SHM coherently (D)** — better than (A) alone, but still three separate
  filesystem copies racing a live writer; not atomic, and does not defragment/compact.
- **SQLite Online Backup API / `VACUUM INTO` (C) — chosen.** `VACUUM INTO` opens its own read
  transaction against the live database (an ordinary concurrent WAL reader — it neither blocks
  nor is blocked by Open WebUI's own writers) and writes one complete, internally consistent,
  freshly-compacted copy to a brand-new file in a single SQL statement. No service interruption.

**Consequence: this is an online backup. Open WebUI is never stopped for a routine backup.**
WAL mode is exactly why a naive raw copy was rejected and why `VACUUM INTO` was required instead
of "preferred" — see Fail-Closed below.

## Fail-Closed

`Backup-KIStackOpenWebUIDatabase.ps1` never falls back to a raw file copy. If the venv Python or
stdlib `sqlite3` is unavailable, or `VACUUM INTO` / the post-write integrity check fails for any
reason, the script throws and removes any partial output file — it never silently produces a
lower-assurance backup.

## Backup Directory

`C:\KI-Stack\backups\openwebui-database\` (default; overridable via `-BackupDirectory`).
Filenames are deterministic and sortable: `webui-db-backup-<yyyyMMddTHHmmssZ>.sqlite3`.

## Metadata / Sidecar

Each backup file `<name>.sqlite3` has a sidecar `<name>.sqlite3.json` containing only structural
metadata — **never** database contents:

```json
{
  "schemaVersion": "1.0",
  "sourcePath": "...",
  "createdAtUtc": "...",
  "backupMethod": "sqlite-vacuum-into",
  "sourceSizeBytes": 0,
  "backupSizeBytes": 0,
  "sha256": "...",
  "openWebUIVersion": "0.11.3",
  "kiStackVersion": "2.14.0",
  "integrityCheck": "ok",
  "tableCount": 43,
  "deepVerify": false
}
```

`openWebUIVersion`/`kiStackVersion` are best-effort (read from the installed package metadata and
`installer\complete\VERSION` respectively) and `null` if unavailable — never block the backup.

## Retention

Disabled by default (`-RetentionCount 0` — nothing is ever deleted automatically). Passing a
positive `-RetentionCount N` keeps only the `N` newest backups (by filename, which sorts
chronologically) in the given directory, deleting older `.sqlite3`+`.json` pairs together.
Covered by the offline regression (`Test-KIStackOpenWebUIDatabaseBackupRestore.ps1`, Fall D).

## Restore Procedure

`Restore-KIStackOpenWebUIDatabase.ps1` is **always an explicit operator action** — never invoked
automatically by install/reconcile, and never wired into any Agent Pack / Ballistics Pack /
Complete Installer flow.

1. Validates the given `-BackupPath` exists and is itself a structurally intact SQLite file
   (`PRAGMA integrity_check`) — fails closed otherwise.
2. If a `.json` sidecar exists next to it, validates its recorded `sha256` against the actual
   file — fails closed on a mismatch. A missing sidecar is tolerated (not itself a failure).
3. Takes a **pre-restore safety backup** of whatever currently sits at the destination (via the
   same `VACUUM INTO` mechanism, in a `pre-restore-safety` subdirectory) — skipped only if
   nothing exists there yet (fresh-install case).
4. Replaces the destination atomically: copies the validated backup to a `.restoring.tmp` file
   in the same directory, removes stale `-wal`/`-shm` sidecars next to the destination, then
   renames the temp file into place (same-volume rename).
5. Re-validates integrity of the just-restored file. If this ever fails, the script **automatically
   rolls back** to the pre-restore safety backup taken in step 3 (when one exists) rather than
   leaving a known-broken database in place.
6. Never deletes the source `-BackupPath` at any point.

### Service-Stop Behavior

The process stop/restart/health-check steps run **only** when the resolved destination database
path is the real live target (`<TargetRoot>\OpenWebUI\data\webui.db`) — detected automatically by
path comparison, not by a caller-supplied flag that could be set wrong. Any other `-DatabasePath`
(a temporary fixture used for a controlled restore acceptance test) is restored at the file level
only; no process on the machine is touched and no HTTP call is made.

For the real live target:
- The Open WebUI process is located and stopped using the exact same command-line-matching
  pattern already used by the installed `Stop-KIStack-Applications.ps1` (venv path token +
  `open_webui` substring in the process command line) — no second, divergent process-finding
  mechanism is introduced.
- After the database is replaced, the service is restarted via the existing
  `modules\applications\Start-KIStack-OpenWebUI.cmd` (same detached-console pattern the
  Applications module already installs).
- Health is verified by polling the real, unauthenticated `GET /health` (process reachable) and
  then `GET /health/db` (confirms Open WebUI's own live connection pool can talk to the restored
  file — not merely that the process started) until both return HTTP 200 or a timeout elapses.
  Failure to reach a healthy state is reported honestly in the result object's `serviceHealth`
  field; it does not retroactively undo an otherwise-successful database restore.

## Relationship to Memory

Memory (2.17 Phase 1, see `MEMORY-CONTRACT.md`) has no storage of its own — it is the `memory`
table inside this same `webui.db`. A whole-database backup/restore therefore captures Memory
together with chats, users, and every other Open WebUI record in one consistent snapshot; there
is no separate memory-only backup path, and none is needed.

## Distinction from Per-Profile Reconcile Backups

Agent Pack / Ballistics Pack Execute already take their own narrow, model-record-level rollback
backups (a JSON snapshot of the specific model forms about to change) before every reconcile —
unrelated in scope and unaffected by this contract. This whole-database mechanism is **not**
triggered automatically before those operations: a profile reconcile touches Open WebUI model
records via its REST API, never `webui.db` directly, so no coupling between the two is justified
(see Phase 2 task instructions, "Integrate only where justified"). The whole-DB backup exists for
a different purpose — protecting persistent chat/user/memory state and enabling an explicit
operator-driven backup/restore, independent of any package install.

## Limitations

- **No encryption-at-rest.** Backup files are plain, directly-readable SQLite files — the same
  posture as the live database itself (see `MEMORY-CONTRACT.md`'s own Security/Privacy section).
- **No automatic scheduling.** Both scripts are operator-invoked; no scheduled task or cron-style
  trigger is created by this phase.
- **Single-machine, local-disk only.** No off-host/cloud copy of any kind.
- **Live-target restore requires the standard KI-Stack process/health conventions to be present**
  (`modules\applications\Start-KIStack-OpenWebUI.cmd`, port 8080) — a target deployed with a
  materially different application layout would need its own adaptation.

# Backup and rollback contract

Only files changed by the active complete-installer transaction are backed up and restored. Existing compliant components are skipped and never added to rollback scope. Kernel module changes use the existing module rollback contracts. OpenWebUI Agent and Visual Pack backups are stored by their public installers and restored with the same in-memory API token. Production Recovery 1.7.0-r7 remains a manual repair source and is never overlaid automatically on a healthy newer installation.

Resume data contains component IDs, statuses, hashes and non-secret paths only. It never contains credentials or `SecureString` values.

## `-Mode RollbackOperations` (`-Mode Rollback`, deprecated alias)

This mode calls exactly one function, `Restore-KICompleteOperations`, against the most recent `operations-latest.json` backup pointer. It is an **Operations Restore**, not a full installation rollback, and never has been.

**What it restores:**

- Registry/autostart state: removes any re-established competing LM Studio autostart Run/RunOnce registry value.
- The three KI-Stack Desktop shortcuts (`KI-Stack starten.lnk`, `KI-Stack stoppen.lnk`, `KI-Stack Status.lnk`), including removing one that did not exist before the transaction that is being rolled back.
- Docker restart policy of any KI-Stack-owned container, back to what it was before that transaction.

**What it explicitly does NOT restore:** any installed component (OpenWebUI, ComfyUI, Integration, RAG, the OpenWebUI Agent/Visual/Ballistics packs, Codex Local, Foundation Runtime, Python/Git), WSL or winget state, user data, models, Knowledge, Code-Interpreter configuration, or any other prior installer state. Reverting any of those is out of scope for this mode; see Resume, Failed-State-Recovery, `Repair`, and a normal reinstall/update run below for the mechanisms that actually apply to them.

**Return shape and exit-code behavior deliberately differ between the two names** -- `Rollback` is a real, pre-existing public CLI surface external scripts may already call, so for 2.13 it keeps its exact historical contract; `RollbackOperations` is new in this same release and gets a fully deliberate one instead. Neither the return shape nor the missing-state behavior is a security boundary, so nothing was broken here just for the sake of making the two names behave identically:

| | `-Mode RollbackOperations` (canonical) | `-Mode Rollback` (deprecated alias) |
|---|---|---|
| Return shape | `{ version, mode, operation='OperationsRestore', scope, notRestored, result }` -- `result` carries the exact object `Restore-KICompleteOperations` itself returned, unwrapped copy included | The exact, historical flat object `Restore-KICompleteOperations` itself returns (`{ status, restored, backupPath }` on success) -- never wrapped |
| No valid `operations-latest.json` state | **Fails closed:** throws a clear error naming "Operations Restore" and explicitly denying a full rollback was attempted; non-zero exit code | **Unchanged since before this mode existed under its new name:** returns `{ status='NoOperationsBackup', restored=$false }`, does not throw, exit code 0 -- plus the deprecation warning below |
| Deprecation warning | none (this is the canonical name) | always printed to the Warning stream |

Prefer `RollbackOperations` in new scripts specifically because of this: it tells you unambiguously, via a non-zero exit code, when nothing was actually restored.

**Relationship to other recovery mechanisms** (unchanged by this section, listed only for disambiguation):
- **Resume** (`-Resume -TransactionId <id>`) continues an interrupted transaction from where it left off; it is not a rollback of any kind.
- **Failed-State-Recovery** (automatic, at the start of a new `Install`/`Upgrade`/`Repair` run) detects and reconciles a transaction that failed without a clean rollback; separate mechanism, untouched by this mode.
- **`Repair`** re-runs a component's own install/validate path for a component the compliance probe finds non-compliant; it does not call `RollbackOperations`.
- **Reinstall/Update** (a fresh `Install`/`Upgrade` run, or `Update-KIStack-All`) is the supported way to change or fix installed component state -- `RollbackOperations` is never part of that path.

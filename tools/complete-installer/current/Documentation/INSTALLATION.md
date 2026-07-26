# Installation, upgrade, and operations

1. Verify `KI-Stack-Complete-Installer-v2.3.1.zip` against its adjacent `.sha256` sidecar with `Get-FileHash -Algorithm SHA256`.
2. Extract the package and run `Start-KIStack-Installer.cmd` with PowerShell 7.
3. Confirm UAC. If requested, enter a temporary OpenWebUI administrator API key through the hidden prompt; it is never stored and should be revoked afterwards.
4. Accept only `Completed` or `SkippedAlreadyCompliant`.

Models are downloaded automatically from revision-pinned sources. Existing targets and optional caches/preloads are reused only after exact size and SHA-256 verification. Partial downloads support resume; invalid size or hash fails. No preload is required.

Lifecycle:

- Start: `Start-KIStack.cmd`
- Stop: `Stop-KIStack.cmd`
- Status: `Status-KIStack.cmd`
- Interactive status: `Lifecycle\Status-KIStack-Interactive.cmd`

Transactions are under `C:\KI-Stack\state\complete-installer\<TransactionId>` and backups under `C:\KI-Stack\backups\complete-installer\<TransactionId>`.

- Resume: `Resume-KIStack-Installer.cmd <TransactionId>`
- Audit: `Start-KIStack-Audit.cmd`
- Validate: `Start-KIStack-Validate.cmd`
- Repair: `Start-KIStack-Repair.cmd`
- Rollback: `Start-KIStack-Rollback.cmd`

Recovery checks pending and failed transactions before a new plan. Rollback restores only the selected transaction. Existing compliant models and user data are retained.

The Greenfield contract was verified with source/package checks and small local fixtures. A complete physical Greenfield installation on an empty target was not performed. Functional validation is inherited unchanged from 2.3.0.

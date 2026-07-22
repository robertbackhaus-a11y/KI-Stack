# KI-Stack System Cleanup 1.0.0

Status: `AuditCompletedPendingCleanupApproval`.

This package inventories plausible KI-Stack locations and produces a portable audit plus a SHA256-bound cleanup plan. Audit is read-only. Execute accepts only an explicitly approved unchanged plan, rechecks dependencies and moves candidates to `C:\KI-Stack-Cleanup-Quarantine\<TransactionId>`; irreversible deletion is deliberately not implemented. In version 1.0.0 Execute remains blocked until a separate cleanup approval is given.

Classification is conservative. Current production data and the repository are `KEEP`; foreign Git worktrees and referenced/running paths are `BLOCKED`; ambiguous ownership is `MANUAL_DECISION`. A filename or age alone never results in `SAFE_TO_DELETE`.

Reports replace the production root, repository root and user profile with portable tokens. No cleanup action, WSL unregister, task/firewall/registry/environment modification, process termination or cache deletion occurs during Audit.

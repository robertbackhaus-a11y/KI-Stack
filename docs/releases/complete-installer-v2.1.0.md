# KI-Stack Complete Installer 2.1.0

Complete Installer 2.1.0 preserves the complete 2.0.0 component set and adds OpenWebUI Ballistics Pack 1.0.0 as an explicitly enabled optional component. Upgrade and repair preserve `data/ballistics`; rollback is scoped to the Ballistics profile/tool pre-state. Already-compliant execution does not request an API key.

Status: `TargetSystemValidatedExistingInstallation` on 2026-07-22. Upgrade from 2.0.0 completed and the second reconcile returned `SkippedAlreadyCompliant` without requesting an API key.

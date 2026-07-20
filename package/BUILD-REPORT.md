# KI-Stack Integration v1.5.5 – Regression-Hardened Repair Build

- Revalidates the actual Debian WSL version before and after `wsl --set-version`; the validated end state decides instead of the native exit code alone.
- Treats an already reached WSL2 target state as success even when WSL returns `WSL_E_VM_MODE_INVALID_STATE`.
- Closes successful SelfTest, DryRun, Execute and GitHub windows automatically while failed runs remain visible until acknowledged.
- Extends the mandatory historical regression matrix for WSL end-state validation and conditional window lifecycle.
- Revalidates starter, paths, StrictMode, versions, preflight, rollback and GitHub contracts.
- Embeds GitHub Update v0.4.5.

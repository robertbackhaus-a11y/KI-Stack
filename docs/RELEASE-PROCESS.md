# Release process

## Status model

- **Reference:** validated predecessor that must remain byte-stable unless a mandatory dependency requires change.
- **Release candidate:** complete package that passed repository/build checks but has not yet completed target-system execution.
- **Stable:** package completed SelfTest, DryRun and Execute on the target system.

## Required release gates

1. Complete package files; no patch-only delivery.
2. JSON and PowerShell parser validation.
3. Internal SHA256 verification.
4. Historical regression matrix passes.
5. SelfTest on target Windows system.
6. DryRun on target Windows system.
7. Execute and transaction completion on target Windows system.
8. Release asset SHA256 recorded.

Failed packages are never repaired manually in place. The defect is analyzed, a regression test is added and the next full version is generated.

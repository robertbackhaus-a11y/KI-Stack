# KI-Stack Models / Workflows v1.3.6-rc1

This release candidate corrects the model download stream variable and the model-manifest self-test contract.

- No assignment to the protected PowerShell automatic variable `$input`.
- Model manifest schema 1.1 is validated with three managed required models and five local placeholders.
- Includes the full target-system self-test, DryRun, Execute, rollback and integrated GitHub publisher.

# Applications v1.4.4-rc1

This release candidate repairs the PowerShell SelfTest corruption introduced by an unsafe text insertion marker in v1.4.3.

- Reconstructs the SelfTest from the last syntactically valid reference.
- Inserts new tests only before the final executable result aggregation.
- Keeps the aggregation search literal intact.
- Consolidates active package versions to 1.4.4.
- Publishes through target stage `Repo-Applications-v1.4.4-rc1`.

# Applications v1.4.10-rc1

## Status

Release candidate. The Applications runtime installation is already validated; this release corrects only GitHub bundle validation and publication.

## Changes

- Uses non-expandable PowerShell literals for all Git-author publisher source checks.
- Prevents StrictMode from resolving publisher-only variables inside `Test-Bundle.ps1`.
- Retains repository-local author identity, target-only snapshots, and strict error propagation.

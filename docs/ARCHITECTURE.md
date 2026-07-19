# Architecture

## Design goals

KI-Stack is a modular Windows deployment framework. The package kernel discovers enabled modules from a release configuration, validates a preflight artifact, creates a transaction, executes modules in a fixed order and invokes rollback when a terminating failure occurs.

## Module order

1. Foundation
2. Runtime
3. PythonGit
4. ComfyUI
5. Models
6. Applications
7. Integration
99. Validation

Only modules listed in `executeRelease.enabledModules` may execute. Disabled modules remain present as future package building blocks but are excluded by the release allowlist.

## Package lifecycle

1. CMD bootstrap resolves PowerShell and preserves diagnostics.
2. Starter validates package files and locates the newest supported preflight ZIP.
3. Self-test checks syntax, configuration and historical regressions.
4. DryRun produces a plan without mutating the target system.
5. Execute requires explicit confirmation and administrator rights.
6. Kernel writes transaction state and invokes modules.
7. Failure triggers rollback using module state and persistent journals.

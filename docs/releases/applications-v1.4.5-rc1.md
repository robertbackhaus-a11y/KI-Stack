# Applications v1.4.5-rc1

- Restores persistent CMD diagnostics for SelfTest, DryRun and Execute.
- Keeps all entry points on `cmd /K` and changes the common bootstrap finish path to `exit /b`.
- Adds an end-to-end regression that rejects any future process-terminating finish exit.
- Retains all validated Foundation, Runtime, PythonGit, ComfyUI and Models content.

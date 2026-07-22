# KI-Stack OpenWebUI Ballistics Pack 1.0.0

This package installs exactly one managed OpenWebUI 0.10.2 profile (`ki-stack-18bravo`, display name `18Bravo`) and exactly one exclusively bound tool (`ki_stack_ballistics_calculator`). It is a technical calculator for lawful sporting, hunting and engineering use and does not claim military identity or experience.

The solver is the pinned `pyballistic` 2.2.0 wheel with the pure-Python RK4 engine. G1 and G7 are supported. SciPy, Cython, compiled extension and chart engines are neither selected nor installed. Payloads are resolved solely by file name, size and SHA256; Git is never needed at package runtime.

Required values are never silently defaulted. Station pressure and sea-level-reduced pressure are distinguished, and altitude is not double-counted. Output supports chat tables, CSV schema 1.0.0, JSON and compact DOPE cards. Results always carry the numerical-approximation warning.

Local user-confirmed profiles live below `C:\KI-Stack\data\ballistics\profiles`; exports and backups have separate directories. No example or synthetic user profile is installed. Fixtures remain inside the test source.

Run `Start-OpenWebUI-Ballistics-Pack-DryRun.cmd` before Execute. Execute prompts once for a temporary administrator API key as a `SecureString`; revoke it in OpenWebUI afterward. Rollback requires the generated backup path.

Supported and tested: G1, G7, metric/imperial values, MRAD/MOA, wind direction, shot angle and library spin drift when a valid twist is supplied. Not claimed by 1.0.0: Coriolis or automatic BC/muzzle-velocity calibration. Transsonic behavior is whatever the pinned drag tables and RK4 point-mass solver provide and remains an approximation.

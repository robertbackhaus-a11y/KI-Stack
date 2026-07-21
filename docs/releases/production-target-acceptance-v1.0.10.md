# KI-Stack Production Target Acceptance v1.0.10

Status: `TARGET_SYSTEM_ACCEPTANCE_PASSED`

- Production Recovery: `1.7.0-r7`, `TargetSystemAccepted`
- Recovery ZIP SHA256: `0b4b28c886f01939fb45a9d7f3ce9f5323f57a8208e42381088544afa5955c59`
- Target Acceptance: `1.0.10`
- Target Acceptance ZIP SHA256: `bbfe6e79438406fecbc301f8883a7b629ca0c1ff5736917c267c02ec79fce0d6`
- Final acceptance completed: `2026-07-21T12:15:06.4833454Z`

The final run used exactly the listed Recovery artifact and passed SearXNG, Open WebUI 0.10.2, LM Studio and ComfyUI on the first endpoint attempt. Separate controlled lifecycle evidence covered cold WSL start, a stale keeper PID, repeated start, partial uWSGI failure repair and stop/restart.

The raw target report is neither committed nor published because it contains system-specific paths. Only this sanitized summary is released.

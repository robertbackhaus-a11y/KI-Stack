# KI-Stack Complete Installer 2.1.2

Status: `TargetValidated`.

This operations-only patch over 2.1.1 makes normal Windows and Debian startup passive. It removes only positively identified KI-Stack autostarts, keeps `valkey-server`, `uwsgi` and `nginx` available to the existing central manual start, and manages Start, Stop and read-only Status shortcuts through the actual Windows Desktop Known Folder.

Every changed setting is captured in `operations.backup.json`; the Complete Installer rollback entry point restores Run values, shortcut state, systemd enablement and owned Docker restart policies. Applications 1.4.10, Agent Pack 1.8.3, Image Pack 1.9.0, Ballistics Pack 1.0.0, Models / Workflows 1.3.8 and all ComfyUI content remain unchanged.

The former 415-Markdown knowledge experiment is explicitly not a dependency. All three managed profiles enforce empty knowledge bindings, and the supported OpenWebUI API removes only unequivocally KI-Stack-owned knowledge collections and their file/vector state after writing a private metadata-only rollback record. Original Markdown sources and unrelated OpenWebUI data remain untouched.

The controlled cold-reboot acceptance confirmed passive startup; central start, read-only status and central stop remain manually available.

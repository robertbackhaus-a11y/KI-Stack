# KI-Stack Complete Installer 2.1.1

Complete Installer 2.1.1 is a patch over 2.1.0 and updates only Models / Workflows from 1.3.7 to 1.3.8. It preserves models, input, output, user workflows and every other already compliant component. The new UI workflow is installed under its versioned name; the OpenWebUI API workflow remains byte-identical.

The controlled existing-system upgrade completed on 2026-07-22. All three required FLUX2 files were reused without download, all other components remained compliant, and the immediate second reconcile returned `SkippedAlreadyCompliant` without creating a transaction or backup.

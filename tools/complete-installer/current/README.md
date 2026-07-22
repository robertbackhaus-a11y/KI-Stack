# KI-Stack Complete Installer 2.0.0

Status: `TargetSystemValidatedExistingInstallation`. Fresh-install behavior is contract- and fixture-tested; physical validation is limited to an existing installation. ComfyUI 1.2.2 and Integration 1.5.9 use immutable file/size/SHA256 payload contracts without Git at package runtime.

The root starters provide audit, install/upgrade, repair, validation, rollback, start and stop without requiring users to browse subdirectories. One orchestration core creates resumable component transactions and preserves already compliant components. Production Recovery 1.7.0-r7 is an explicit repair and fallback source, never an automatic overlay over newer Agent Pack 1.8.2 or Image Pack 1.9.0 content.

The package has no Git dependency for acquiring package payloads and contains no `.git` directory. It is not offline: the three required FLUX2 model payloads total about 18.4 GB and are fetched over HTTPS only when their expected target SHA256 is absent. The gated FLUX model requires user authorization under its license. KREA and Pony remain optional user-provided profiles.

OpenWebUI 0.10.2 may require initial administrator setup in the browser. The transaction then enters `WaitingForUserAction`. A temporary API key is requested as a hidden `SecureString` immediately before Agent/Image reconciliation, used only in memory for both steps, cleared afterward, and must then be revoked.

No physically tested bare-metal fresh-install claim is made.

# Complete Installer v2.3.0-rc16

RC15 is rejected after target validation exposed internal ComfyUI API prompt JSON files as empty entries in the ComfyUI user workflow browser.

RC16 updates Visual Models / Workflows to 2.0.2. Its two API prompt graphs remain packaged as internal resources for OpenWebUI tool execution, but are no longer copied into `data/comfyui/user/default/workflows/KI-Stack`. During the package-managed upgrade, previously published managed API prompt files are moved to the transaction workflow backup. The two real Visual Pack UI graph workflows remain unchanged and visible.

OpenWebUI Visual Pack remains 2.0.5-rc2 and Agent Pack remains 1.8.7 because neither package's delivered content changed.

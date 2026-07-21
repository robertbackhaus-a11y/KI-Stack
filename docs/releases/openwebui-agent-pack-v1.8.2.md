# KI-Stack OpenWebUI Agent Pack 1.8.2

Agent Pack 1.8.2 retains the two established OpenWebUI 0.10.2 profiles and adds only the optional registered extension contract for Image Pack 1.9.0. The canonical tool `ki-stack-generate-image` is bound through OpenWebUI's required identifier-safe internal ID `ki_stack_generate_image`. When it is absent or not owned by `KI-STACK-OPENWEBUI-IMAGE-PACK`, both profiles remain tool-free. Foreign bindings are never adopted.

Status: `TargetSystemValidated` on 2026-07-21. Both established profiles retained exactly the registered Image Pack binding after final installation; rollback removed it without changing the profiles.

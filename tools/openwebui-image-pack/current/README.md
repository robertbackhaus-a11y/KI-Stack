# KI-Stack OpenWebUI Image Pack 1.9.0

Status: `TargetSystemValidated` on 2026-07-21 for OpenWebUI 0.10.2, ComfyUI 1.2.1, Models / Workflows 1.3.7 and Agent Pack 1.8.2.

The package manages exactly one canonical tool: `ki-stack-generate-image` (`KI-Stack Bildgenerierung`). OpenWebUI 0.10.2 requires Python-identifier database IDs, so its internal/bindable ID is `ki_stack_generate_image`; the canonical ID and ownership remain explicit in tool frontmatter. It submits the existing FLUX2 Klein 9B API workflow to local ComfyUI and supports `prompt`, `aspect_ratio` (`1:1`, `16:9`, `9:16`) and an optional `seed`.

Only the already installed required FLUX2 model profile is used. The package contains no models, downloads no models, and does not use optional KREA or Pony profiles. Both KI-Stack Agent Pack profiles are bound to the managed tool; no foreign bindings are added.

The API key is requested as a `SecureString`, used only in memory, and never persisted. Execute creates a targeted backup. Rollback restores the previous tool and both profile forms.

The target-safe exact-ratio resolutions are `512x512`, `768x432`, and `432x768`. They remain aligned to the FLUX2 latent node's required 16-pixel step and complete within the bounded local runtime.

# KI-Stack OpenWebUI Image Pack 1.10.0

Status: `RegressionValidated` for OpenWebUI 0.10.2 and local ComfyUI 1.2.2. The Pony workflow and its direct OpenWebUI chat output were previously exercised successfully on the target system. This factual evidence is limited to that path and is not a claim of complete target-system validation for version 1.10.0.

The package continues to manage exactly one canonical tool: `ki-stack-generate-image` (`KI-Stack Bildgenerierung`). OpenWebUI uses the identifier-safe internal ID `ki_stack_generate_image`. The tool now exposes two explicit methods:

- `generate_image(prompt, aspect_ratio, seed)` retains the established FLUX2 Klein 9B behavior, including `1:1`, `16:9`, and `9:16`.
- `generate_pony_image(prompt, seed)` uses `ponyDiffusionV6XL_v6StartWithThisOne.safetensors` at 1024 × 1024, CLIP skip 2 (`stop_at_clip_layer = -2`), 40 steps, CFG 3.1, sampler `euler`, and scheduler `normal`.

Both methods accept a free prompt and optional seed. Both submit only to the trusted local ComfyUI origin `http://127.0.0.1:8188`. Request paths must remain relative; untrusted origins and schemes are rejected.

Generated images are registered through OpenWebUI's supported file store, attached through `chat:message:files`, displayed directly in the chat, and made available through authenticated preview and download. No base64 payload, `/mnt/uploads` path, absolute Windows path, or direct ComfyUI URL is returned.

The package contains and downloads no model files. The Pony checkpoint and the existing FLUX2 model files must already be installed in ComfyUI. No access credentials, personal paths, generated test images, or raw target-system reports are included.

The API key is requested as a `SecureString`, used only in memory, and never persisted. Execute creates a targeted backup. Rollback restores the previous tool and both profile bindings.

# KI-Stack OpenWebUI Image Pack 1.10.0

Image Pack 1.10.0 preserves the existing `generate_image` FLUX2 path and adds the explicit `generate_pony_image` method to the same managed OpenWebUI tool.

The Pony SDXL contract uses `ponyDiffusionV6XL_v6StartWithThisOne.safetensors`, 1024 × 1024, CLIP skip 2 (`stop_at_clip_layer = -2`), 40 steps, CFG 3.1, `euler`, and `normal`, with a caller-provided prompt and optional seed. It persists and attaches its result through the same OpenWebUI file-store path as FLUX2.

All 1.9.2 security protections remain in place. In particular, ComfyUI requests are restricted to `http://127.0.0.1:8188` and relative request paths. The package contains and downloads no model binaries.

The Pony workflow and its direct OpenWebUI chat display/download behavior were previously tested successfully on the target system. Version 1.10.0 is repository- and regression-validated; that prior practical evidence does not constitute a complete target-system validation of the full 1.10.0 package.

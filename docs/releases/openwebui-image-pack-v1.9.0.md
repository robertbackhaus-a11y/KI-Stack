# KI-Stack OpenWebUI Image Pack 1.9.0

The package provides exactly one managed OpenWebUI 0.10.2 tool, canonically `ki-stack-generate-image` (`KI-Stack Bildgenerierung`) and internally `ki_stack_generate_image` because OpenWebUI rejects non-identifier IDs. It uses the existing FLUX2 Klein 9B workflow through ComfyUI 1.2.1 and the required Models / Workflows 1.3.7 profile. It contains and downloads no model files.

Supported inputs are a prompt, aspect ratio `1:1`, `16:9` or `9:16`, and an optional seed. Installation and rollback are limited to the managed tool and its binding on `ki-stack-it-technik` and `ki-stack-allgemein`.

Status: `TargetSystemValidated` on 2026-07-21. Real OpenWebUI-to-ComfyUI renders passed for `Allgemein` (PNG, 512 x 512, 295,616 bytes) and `KI & IT-Technik` (PNG, 768 x 432, 440,053 bytes). Non-image routing, invalid-ratio rejection, idempotence, rollback, final reinstall, API readback and SearXNG regression checks passed. No raw target report or rendered image is part of the repository or release.

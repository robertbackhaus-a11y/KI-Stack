# Complete Installer v2.3.0-rc17

RC16 is rejected because its target validation found that the visible Z-Image UI workflow was not a tracked package source and still referenced the obsolete local-only Qwen filename and workflow-embedded download URLs.

RC17 contains OpenWebUI Visual Pack 2.0.5-rc3. The Visual Pack now owns exactly two visible ComfyUI UI graphs, deploys them transactionally with backup and hash readback, and keeps its two API prompt graphs internal. The Z-Image UI loader uses exactly `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`. Visible UI graphs contain no model download URLs; those remain authoritative only in the central model manifest.

Models / Workflows remains 2.0.2, Agent Pack remains 1.8.7, ComfyUI remains 1.2.4, and WAN2.2 tool/API contracts are unchanged.

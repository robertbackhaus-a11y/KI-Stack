# Model contract 2.4.0

- LM Studio exposes Heretic as the only chat LLM.
- `nomic-embed-text-v1.5.Q4_K_M.gguf` is acquired automatically into the current user's LM Studio home. Nomic is embedding-only and must never be selectable as a chat model.
- ComfyUI is limited to Z-Image Turbo and WAN2.2 T2V 14B with both LightX2V four-step LoRAs.
- No model weights are embedded. Missing files are downloaded from revision-bound sources; optional caches/preloads and installed targets are reused only after exact size and SHA-256 verification.
- Downloads remain in transaction state until verified, support resume, and are activated atomically only afterwards. Network failures remain resumable; size or hash mismatches fail.
- Z-Image uses only the public manufacturer artifact `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`. A file using the former `Uncensored` name is neither overwritten nor deleted.
- OpenWebUI uses Visual Pack 2.0.5. MP4 output is one persistent `type: file` download attachment emitted through the native `files` event.

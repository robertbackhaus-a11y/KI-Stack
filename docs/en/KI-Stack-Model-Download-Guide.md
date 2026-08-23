# Automatic model download contract

This contract applies to Complete Installer 2.4.0 Stable.

The Complete Installer requires no manually supplied model or payload files on an empty target. The nine visual artifacts for Z-Image Turbo and WAN2.2 T2V 14B with both LightX2V four-step LoRAs, both Heretic files, and the embedding-only `nomic-embed-text-v1.5.Q4_K_M.gguf` have revision-bound sources, exact byte sizes and SHA-256 values in `tools/models-workflows/current/Manifests/models.manifest.json`.

The importer:

1. Reuses a valid target by size and SHA-256.
2. Uses an optional cache or `ExternalModels` preload only after the same validation.
3. Downloads a missing file into transaction state and resumes a partial transfer using HTTP Range.
4. Verifies full size and SHA-256.
5. Only then activates the file atomically and reads it back.

An unreachable source yields resumable `WaitingForNetwork`. A wrong size or SHA-256 yields `Failed`; the component is not recorded as completed.

Z-Image uses BennyDaBall's `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`, pinned to revision `db48689636056934d4f0600952ac15894f8ce1a2`, size `4280404800`, and SHA-256 `be7b7285f6b80daef5b15affbe96d6626c308ef53dae878568b36664099c71d0`.

Heretic is chat-only and Nomic is embedding-only. The Greenfield contract has been verified with a complete, successful, physical installation on an empty target.

An existing `Qwen3-4b-Uncensored-Z-Image-Engineer-V4-Q8_0.gguf` is outside the active contract and is not renamed, overwritten, or deleted.

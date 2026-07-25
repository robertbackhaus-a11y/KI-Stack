# KI-Stack Visual Models / Workflows 2.0.1

This model-free payload manages exactly Z-Image Turbo and WAN2.2 T2V 14B with both LightX2V four-step LoRAs.

Every external artifact has a revision-bound HTTPS source, exact byte size and SHA-256 in `Manifests/models.manifest.json`. `Import-KIStackExternalModels.ps1 -Mode Install` reuses a verified installed file or optional preload, otherwise downloads into transaction state with HTTP Range resume. It verifies size and SHA-256 before atomically activating the file. An unreachable source returns resumable `WaitingForNetwork`; a checksum mismatch fails the transaction.

The former local-only `Qwen3-4b-Uncensored-Z-Image-Engineer-V4-Q8_0.gguf` is not managed, renamed, overwritten or deleted. The active Z-Image contract uses the public manufacturer artifact `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`.

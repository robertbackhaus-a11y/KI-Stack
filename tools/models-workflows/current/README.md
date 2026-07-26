# KI-Stack Visual Models / Workflows 2.0.2

This model-free payload manages exactly Z-Image Turbo and WAN2.2 T2V 14B with both LightX2V four-step LoRAs.

Every external artifact has a revision-bound HTTPS source, exact byte size and SHA-256 in `Manifests/models.manifest.json`. `Import-KIStackExternalModels.ps1 -Mode Install` reuses a verified installed file or optional preload, otherwise downloads into transaction state with HTTP Range resume. It verifies size and SHA-256 before atomically activating the file. An unreachable source returns resumable `WaitingForNetwork`; a checksum mismatch fails the transaction.

The former local-only `Qwen3-4b-Uncensored-Z-Image-Engineer-V4-Q8_0.gguf` is not managed, renamed, overwritten or deleted. The active Z-Image contract uses the public manufacturer artifact `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`.

The JSON files below `Workflows` are internal ComfyUI API prompt graphs used by the OpenWebUI tools. They are deliberately not published into ComfyUI's user workflow browser, because API prompt JSON is not a UI graph and would appear as an empty workflow. The visible UI workflows are supplied separately by the Visual Pack.

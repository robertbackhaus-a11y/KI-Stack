# Optional model provisioning and preload

Complete Installer 2.3.1 automatically downloads missing models from revision-pinned sources in the central model manifest. Manual provisioning is not an installation prerequisite.

An optional cache or `ExternalModels` preload can save bandwidth. A file is accepted only after filename, exact size, and full SHA-256 verification. A valid target is reused and is not downloaded again. Interrupted downloads remain resumable; an incorrect size or hash produces `Failed`.

Heretic is chat-only. Nomic is embedding-only. The official `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf` is used only by Z-Image. Active visual models belong only to Z-Image Turbo and WAN2.2 T2V 14B with both LightX2V four-step LoRAs.

Optional import from a local cache directory:

```powershell
Start-KIStack-Model-Import.cmd -SourcePath "D:\KI-ModelCache"
```

`AlreadyCompliant` means the target already matches fully. A cache never bypasses manifest verification and cannot make a differently named or hashed file valid.

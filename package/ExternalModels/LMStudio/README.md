# Heretic for LM Studio

Put the two contract files here before starting `Start-KIStack-Model-Import.cmd`:

- `Qwen3.6-27B-uncensored-heretic-v2-Native-MTP-Preserved-Q5_K_M.gguf`
- `Qwen3.6-27B-mmproj-BF16.gguf`

The importer verifies exact size and SHA256, then places them beneath the current user's `.lmstudio\models` directory. No file in this folder is included in Git or a release ZIP.

# Manual model provisioning

This guide covers external model payloads only. No model is contained in Git or a KI-Stack ZIP. HTTPS pages are information sources, not trusted installation sources; the exact filename, byte size and SHA256 are authoritative.

## Sequence

1. Obtain the files below from their publisher and verify size and SHA256 locally.
2. Put ComfyUI files directly in `ExternalModels` beside the extracted Models / Workflows package.
3. Put both LM Studio files in `ExternalModels\LMStudio`.
4. Run `Start-KIStack-Model-Import.cmd`, or `Import-KIStackExternalModels.ps1 -SourcePath "<folder>"`.
5. Load Heretic in LM Studio and verify its model identifier through `GET /v1/models`.

`AlreadyCompliant` means a target file already matches filename, size and SHA256 and is not copied. Missing, undersized or wrongly hashed files return `WaitingForUserAction`; after correcting the same staging location, use `-Resume`. The importer copies through `.partial`, moves atomically, and can roll back only its own transaction.

## Manual ComfyUI models

| Workflow | File | Size (bytes) | SHA256 | Target below `C:\KI-Stack\models` | Information page | License status |
|---|---|---:|---|---|---|---|
| KREA | `flux1-krea-dev_fp8_scaled.safetensors` | 11904639672 | `b17a8c21703c4d6ffb0e300dd920eff3cfd35c9a72a1abaf107e3788e408b8d8` | `diffusion_models` | Comfy-Org FLUX.1 Krea Dev | FLUX.1 Dev non-commercial |
| KREA | `clip_l.safetensors` | 246144152 | `660c6f5b1abae9dc498ac2d21e1347d2abdb0cf6c0c0c8576cd796491d9a6cdd` | `text_encoders` | comfyanonymous flux text encoders | Apache-2.0 |
| KREA | `t5xxl_fp16.safetensors` | 9787841024 | `6e480b09fae049a72d2a8c5fbccb8d3e92febeb233bbe9dfe7256958a9167635` | `text_encoders` | comfyanonymous flux text encoders | Apache-2.0 |
| KREA | `ae.safetensors` | 335304388 | `afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38` | `vae` | Comfy-Org Lumina repackaging | not declared by repackaging |
| WAN | `umt5_xxl_fp8_e4m3fn_scaled.safetensors` | 6735906897 | `c3355d30191f1f066b26d93fba017ae9809dce6c627dda5f6a66eaa651204f68` | `text_encoders` | Comfy-Org WAN 2.2 | Apache-2.0 upstream |
| WAN | `wan2.2_ti2v_5B_fp16.safetensors` | 9999658848 | `456f901338bd9eadbded3828b819109a9b68e8a525ca5cf8d0049a69fcfeca1e` | `diffusion_models` | Comfy-Org WAN 2.2 | Apache-2.0 upstream |
| WAN | `wan2.2_vae.safetensors` | 1409400960 | `e40321bd36b9709991dae2530eb4ac303dd168276980d3e9bc4b6e2b75fed156` | `vae` | Comfy-Org WAN 2.2 | Apache-2.0 upstream |

Pony is not manual: only fixed Civitai model version `290640` may be acquired externally automatically, followed by complete verification.

## LM Studio: Heretic

The canonical base model is `qwen3.6-27b-uncensored-heretic-v2-native-mtp-preserved` by **llmfan46**. Information page: https://huggingface.co/llmfan46/Qwen3.6-27B-uncensored-heretic-v2-Native-MTP-Preserved-GGUF. Contract: Apache-2.0, `Q5_K_M`, context 8192, unload the previous model on selection. The page is not an allowed installation URL.

| Role | File | Size (bytes) | SHA256 |
|---|---|---:|---|
| Language model | `Qwen3.6-27B-uncensored-heretic-v2-Native-MTP-Preserved-Q5_K_M.gguf` | 19745091680 | `9d309b8fadd5788bfa8ee26cd34c37b26df0205613a3be34394ba4da7d5a4285` |
| Vision projector | `Qwen3.6-27B-mmproj-BF16.gguf` | 931146048 | `c5c8c41da6d155a61edd21b7e3aa50b6ef77f122d502d36afe4a4d5c3e494d4f` |

The importer places both files in `%USERPROFILE%\.lmstudio\models\llmfan46\Qwen3.6-27B-uncensored-heretic-v2-Native-MTP-Preserved-GGUF`. Then load the model in LM Studio and verify the expected identifier through `http://127.0.0.1:1234/v1/models`. The LLM contract requires 20,676,237,728 bytes; the seven manual ComfyUI models require 40,418,591,941 bytes. Additional free capacity is required for copying and the transaction.

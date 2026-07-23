# Download guide for manual ComfyUI models

This guide applies to the seven manual ComfyUI models in the published contract. Information pages are not installation sources. Trust is established only by the exact file name, exact byte size and full SHA256; no models are contained in Git or package ZIPs.

## Quick procedure

1. Download the seven files using the official information pages.
2. Copy unchanged files directly to `ExternalModels`.
3. Start `Start-KIStack-Model-Import.cmd`.
4. Alternatively: `Start-KIStack-Model-Import.cmd -SourcePath "D:\KI-Modelle"`.
5. The importer verifies file name, size and SHA256.
6. Success is indicated by `AlreadyCompliant` or a successful import.
7. Wrong or incomplete files are not adopted.

On every information page, verify publisher and license status, find only the file name below in the available file inventory, and obtain the file under the publisher's access rules. This guide does not claim a sign-in, button or page layout. Mutable direct links and `resolve/main` are explicitly not an installation contract.

| Workflow | Model | Size | SHA256 | ExternalModels | final target path |
|---|---|---:|---|---|---|
| KREA Realism | `flux1-krea-dev_fp8_scaled.safetensors` | 11904639672 | `b17a8c21703c4d6ffb0e300dd920eff3cfd35c9a72a1abaf107e3788e408b8d8` | `ExternalModels\flux1-krea-dev_fp8_scaled.safetensors` | `C:\KI-Stack\models\diffusion_models\flux1-krea-dev_fp8_scaled.safetensors` |
| KREA Realism | `clip_l.safetensors` | 246144152 | `660c6f5b1abae9dc498ac2d21e1347d2abdb0cf6c0c0c8576cd796491d9a6cdd` | `ExternalModels\clip_l.safetensors` | `C:\KI-Stack\models\text_encoders\clip_l.safetensors` |
| KREA Realism | `t5xxl_fp16.safetensors` | 9787841024 | `6e480b09fae049a72d2a8c5fbccb8d3e92febeb233bbe9dfe7256958a9167635` | `ExternalModels\t5xxl_fp16.safetensors` | `C:\KI-Stack\models\text_encoders\t5xxl_fp16.safetensors` |
| KREA Realism | `ae.safetensors` | 335304388 | `afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38` | `ExternalModels\ae.safetensors` | `C:\KI-Stack\models\vae\ae.safetensors` |
| WAN 2.2 Official | `umt5_xxl_fp8_e4m3fn_scaled.safetensors` | 6735906897 | `c3355d30191f1f066b26d93fba017ae9809dce6c627dda5f6a66eaa651204f68` | `ExternalModels\umt5_xxl_fp8_e4m3fn_scaled.safetensors` | `C:\KI-Stack\models\text_encoders\umt5_xxl_fp8_e4m3fn_scaled.safetensors` |
| WAN 2.2 Official | `wan2.2_ti2v_5B_fp16.safetensors` | 9999658848 | `456f901338bd9eadbded3828b819109a9b68e8a525ca5cf8d0049a69fcfeca1e` | `ExternalModels\wan2.2_ti2v_5B_fp16.safetensors` | `C:\KI-Stack\models\diffusion_models\wan2.2_ti2v_5B_fp16.safetensors` |
| WAN 2.2 Official | `wan2.2_vae.safetensors` | 1409400960 | `e40321bd36b9709991dae2530eb4ac303dd168276980d3e9bc4b6e2b75fed156` | `ExternalModels\wan2.2_vae.safetensors` | `C:\KI-Stack\models\vae\wan2.2_vae.safetensors` |

## Publishers, information pages and identification

| Model | Publisher and official information page | License status | Identify the correct file |
|---|---|---|---|
| `flux1-krea-dev_fp8_scaled.safetensors` | Comfy-Org — https://huggingface.co/Comfy-Org/FLUX.1-Krea-dev_ComfyUI | `flux-1-dev-non-commercial-license` | Name, 11904639672 bytes and SHA256 from the table. |
| `clip_l.safetensors` | comfyanonymous — https://huggingface.co/comfyanonymous/flux_text_encoders | `apache-2.0` | Name, 246144152 bytes and SHA256 from the table. |
| `t5xxl_fp16.safetensors` | comfyanonymous — https://huggingface.co/comfyanonymous/flux_text_encoders | `apache-2.0` | Name, 9787841024 bytes and SHA256 from the table. |
| `ae.safetensors` | Comfy-Org — https://huggingface.co/Comfy-Org/Lumina_Image_2.0_Repackaged | `not-declared-by-repackaging-repository` | Name, 335304388 bytes and SHA256 from the table. |
| `umt5_xxl_fp8_e4m3fn_scaled.safetensors` | Comfy-Org — https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged | `apache-2.0-upstream-wan2.2` | Name, 6735906897 bytes and SHA256 from the table. |
| `wan2.2_ti2v_5B_fp16.safetensors` | Comfy-Org — https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged | `apache-2.0-upstream-wan2.2` | Name, 9999658848 bytes and SHA256 from the table. |
| `wan2.2_vae.safetensors` | Comfy-Org — https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged | `apache-2.0-upstream-wan2.2` | Name, 1409400960 bytes and SHA256 from the table. |

Pony follows the separate automatic Civitai contract. Heretic follows the separate [manual model provisioning](KI-Stack-Manual-Model-Provisioning.md).

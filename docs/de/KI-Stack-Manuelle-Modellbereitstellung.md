# Manuelle Modellbereitstellung

Diese Anleitung beschreibt ausschließlich externe Modellpayloads. Kein Modell ist in Git oder einem KI-Stack-ZIP enthalten. HTTPS-Seiten sind Informationsquellen, keine vertrauenswürdigen Installationsquellen; maßgeblich sind immer exakter Dateiname, Bytegröße und SHA256.

## Reihenfolge

1. Die unten genannten Dateien vom jeweiligen Herausgeber beziehen und lokal gegen Größe und SHA256 prüfen.
2. ComfyUI-Dateien unmittelbar in `ExternalModels` neben dem entpackten Models-/Workflows-Paket ablegen.
3. Die beiden LM-Studio-Dateien unter `ExternalModels\LMStudio` ablegen.
4. `Start-KIStack-Model-Import.cmd` ausführen, alternativ `Import-KIStackExternalModels.ps1 -SourcePath "<Ordner>"`.
5. In LM Studio Heretic laden und mit `GET /v1/models` die Modellkennung prüfen.

`AlreadyCompliant` bedeutet, dass eine Zieldatei bereits Dateiname, Größe und SHA256 erfüllt und nicht kopiert wird. Fehlende, zu kleine oder falsch gehashte Dateien erzeugen `WaitingForUserAction`; nach Korrektur derselben Ablage ist `-Resume` möglich. Der Import kopiert erst als `.partial`, verschiebt atomar und kann ausschließlich seine eigene Transaktion zurückrollen.

## Manuelle ComfyUI-Modelle

| Workflow | Datei | Größe (Bytes) | SHA256 | Ziel unter `C:\KI-Stack\models` | Informationsseite | Lizenzstatus |
|---|---|---:|---|---|---|---|
| KREA | `flux1-krea-dev_fp8_scaled.safetensors` | 11904639672 | `b17a8c21703c4d6ffb0e300dd920eff3cfd35c9a72a1abaf107e3788e408b8d8` | `diffusion_models` | Comfy-Org FLUX.1 Krea Dev | FLUX.1 Dev non-commercial |
| KREA | `clip_l.safetensors` | 246144152 | `660c6f5b1abae9dc498ac2d21e1347d2abdb0cf6c0c0c8576cd796491d9a6cdd` | `text_encoders` | comfyanonymous flux text encoders | Apache-2.0 |
| KREA | `t5xxl_fp16.safetensors` | 9787841024 | `6e480b09fae049a72d2a8c5fbccb8d3e92febeb233bbe9dfe7256958a9167635` | `text_encoders` | comfyanonymous flux text encoders | Apache-2.0 |
| KREA | `ae.safetensors` | 335304388 | `afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38` | `vae` | Comfy-Org Lumina repackaging | vom Repackaging nicht deklariert |
| WAN | `umt5_xxl_fp8_e4m3fn_scaled.safetensors` | 6735906897 | `c3355d30191f1f066b26d93fba017ae9809dce6c627dda5f6a66eaa651204f68` | `text_encoders` | Comfy-Org WAN 2.2 | Apache-2.0 upstream |
| WAN | `wan2.2_ti2v_5B_fp16.safetensors` | 9999658848 | `456f901338bd9eadbded3828b819109a9b68e8a525ca5cf8d0049a69fcfeca1e` | `diffusion_models` | Comfy-Org WAN 2.2 | Apache-2.0 upstream |
| WAN | `wan2.2_vae.safetensors` | 1409400960 | `e40321bd36b9709991dae2530eb4ac303dd168276980d3e9bc4b6e2b75fed156` | `vae` | Comfy-Org WAN 2.2 | Apache-2.0 upstream |

Pony wird nicht manuell bereitgestellt: ausschließlich die feste Civitai-Modellversion `290640` kann extern automatisch bezogen und danach vollständig geprüft werden.

## LM Studio: Heretic

Kanonisches Basismodell ist `qwen3.6-27b-uncensored-heretic-v2-native-mtp-preserved` von **llmfan46**. Informationsseite: https://huggingface.co/llmfan46/Qwen3.6-27B-uncensored-heretic-v2-Native-MTP-Preserved-GGUF. Vertrag: Apache-2.0, `Q5_K_M`, Kontext 8192, vorheriges Modell beim Laden entladen. Die Seite ist nicht als Installations-URL zulässig.

| Rolle | Datei | Größe (Bytes) | SHA256 |
|---|---|---:|---|
| Sprachmodell | `Qwen3.6-27B-uncensored-heretic-v2-Native-MTP-Preserved-Q5_K_M.gguf` | 19745091680 | `9d309b8fadd5788bfa8ee26cd34c37b26df0205613a3be34394ba4da7d5a4285` |
| Vision-Projektor | `Qwen3.6-27B-mmproj-BF16.gguf` | 931146048 | `c5c8c41da6d155a61edd21b7e3aa50b6ef77f122d502d36afe4a4d5c3e494d4f` |

Der Importer übernimmt beide Dateien nach `%USERPROFILE%\.lmstudio\models\llmfan46\Qwen3.6-27B-uncensored-heretic-v2-Native-MTP-Preserved-GGUF`. Anschließend in LM Studio laden und die erwartete Kennung über `http://127.0.0.1:1234/v1/models` prüfen. Der LLM-Vertrag benötigt 20.676.237.728 Bytes; die sieben manuellen ComfyUI-Modelle benötigen 40.418.591.941 Bytes. Zusätzlicher freier Speicher für Kopie und Transaktion ist erforderlich.

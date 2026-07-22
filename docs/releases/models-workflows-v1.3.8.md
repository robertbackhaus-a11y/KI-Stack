# KI-Stack Models / Workflows 1.3.8

Status: `TargetSystemAccepted`.

The release contains the ComfyUI-saved and manually accepted `KI-Stack-FLUX2-Text-to-Image-v1.3.8.json` UI workflow plus the byte-identical `FLUX2-Klein-9B-OpenWebUI-API-FLAT.json` API workflow. The UI workflow SHA256 is `331b7a5a14b284d7d130d60bdcd0168f0ddc3169a164d2adfbc4e49b8cd4ab58`; the API workflow SHA256 remains `697ea261e1c62a8e32d775ee9cba5c5c5c3548c6bd082a63a84c71f53c3123a5`.

The required profile uses `flux-2-klein-9b-fp8.safetensors` (FP8), `qwen_3_8b_fp8mixed.safetensors` (FP8 mixed), `flux2-vae.safetensors`, `euler`, `Flux2Scheduler`, Guidance `1` and four steps. Users enter prompt, seed and batch size directly. Width, height and steps are edited directly: quick `512 x 512`, standard `1024 x 576`, quality-format `768 x 1344`. The labels primarily distinguish resolution and output format; four steps do not claim higher sampling quality.

KREA is deferred until its model, `clip_l`, `t5xxl_fp16` and `ae.safetensors` exist. Pony is deferred until a Pony-SDXL checkpoint exists. ControlNet is deferred until compatible models and a confirmed node chain exist. No placeholder workflow or automatic optional download is included.

The former error `No link found in parent graph for id [11] slot [0] clip` came from an incomplete synthetic UI graph. The replacement is a complete ComfyUI-saved graph and passed graph validation, two automated loads, manual load, manual function acceptance and the three documented render sizes.

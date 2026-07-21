"""
title: KI-Stack Bildgenerierung
managedBy: KI-STACK-OPENWEBUI-IMAGE-PACK
version: 1.9.0
canonical_id: ki-stack-generate-image
"""

import copy
import json
import random
import time
import urllib.parse
import urllib.request


class Tools:
    def __init__(self):
        self.comfy_url = "http://127.0.0.1:8188"
        self.timeout_seconds = 600
        self.workflow = json.loads('''{"78":{"inputs":{"filename_prefix":"Flux2-Klein","images":["82",0]},"class_type":"SaveImage"},"80":{"inputs":{"sampler_name":"euler"},"class_type":"KSamplerSelect"},"81":{"inputs":{"noise":["86",0],"guider":["90",0],"sampler":["80",0],"sigmas":["93",0],"latent_image":["83",0]},"class_type":"SamplerCustomAdvanced"},"82":{"inputs":{"samples":["81",0],"vae":["89",0]},"class_type":"VAEDecode"},"83":{"inputs":{"width":["84",0],"height":["85",0],"batch_size":1},"class_type":"EmptyFlux2LatentImage"},"84":{"inputs":{"value":1024},"class_type":"PrimitiveInt"},"85":{"inputs":{"value":1024},"class_type":"PrimitiveInt"},"86":{"inputs":{"noise_seed":1},"class_type":"RandomNoise"},"87":{"inputs":{"unet_name":"flux-2-klein-9b-fp8.safetensors","weight_dtype":"default"},"class_type":"UNETLoader"},"88":{"inputs":{"clip_name":"qwen_3_8b_fp8mixed.safetensors","type":"flux2","device":"default"},"class_type":"CLIPLoader"},"89":{"inputs":{"vae_name":"flux2-vae.safetensors"},"class_type":"VAELoader"},"90":{"inputs":{"cfg":1,"model":["87",0],"positive":["92",0],"negative":["91",0]},"class_type":"CFGGuider"},"91":{"inputs":{"conditioning":["92",0]},"class_type":"ConditioningZeroOut"},"92":{"inputs":{"text":"","clip":["88",0]},"class_type":"CLIPTextEncode"},"93":{"inputs":{"steps":4,"width":["84",0],"height":["85",0]},"class_type":"Flux2Scheduler"}}''')

    def _json(self, method, path, body=None, timeout=30):
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(self.comfy_url + path, data=data, method=method)
        request.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))

    async def generate_image(self, prompt: str, aspect_ratio: str = "1:1", seed: int | None = None, __event_emitter__=None) -> str:
        """Generate one FLUX2 image. aspect_ratio must be 1:1, 16:9, or 9:16; seed is optional."""
        if not prompt or not prompt.strip():
            raise ValueError("prompt must not be empty")
        sizes = {"1:1": (512, 512), "16:9": (768, 432), "9:16": (432, 768)}
        if aspect_ratio not in sizes:
            raise ValueError("aspect_ratio must be 1:1, 16:9, or 9:16")
        if seed is None:
            seed = random.SystemRandom().randrange(0, 1125899906842624)
        if not isinstance(seed, int) or seed < 0 or seed > 1125899906842624:
            raise ValueError("seed must be an integer from 0 through 1125899906842624")
        width, height = sizes[aspect_ratio]
        workflow = copy.deepcopy(self.workflow)
        workflow["92"]["inputs"]["text"] = prompt.strip()
        workflow["84"]["inputs"]["value"] = width
        workflow["85"]["inputs"]["value"] = height
        workflow["86"]["inputs"]["noise_seed"] = seed
        if __event_emitter__:
            await __event_emitter__({"type": "status", "data": {"description": "FLUX2-Bild wird erzeugt", "done": False}})
        queued = self._json("POST", "/prompt", {"prompt": workflow})
        prompt_id = queued.get("prompt_id")
        if not prompt_id:
            raise RuntimeError("ComfyUI returned no prompt_id")
        deadline = time.monotonic() + self.timeout_seconds
        image = None
        while time.monotonic() < deadline:
            history = self._json("GET", "/history/" + urllib.parse.quote(prompt_id), timeout=30)
            record = history.get(prompt_id)
            if record:
                for output in record.get("outputs", {}).values():
                    images = output.get("images", [])
                    if images:
                        image = images[0]
                        break
            if image:
                break
            time.sleep(1)
        if not image:
            raise TimeoutError("ComfyUI image generation timed out")
        query = urllib.parse.urlencode({"filename": image["filename"], "subfolder": image.get("subfolder", ""), "type": image.get("type", "output")})
        view_url = self.comfy_url + "/view?" + query
        with urllib.request.urlopen(view_url, timeout=30) as response:
            payload = response.read()
            content_type = response.headers.get("Content-Type", "")
        if not payload or not content_type.startswith("image/"):
            raise RuntimeError("ComfyUI returned no valid image")
        if __event_emitter__:
            await __event_emitter__({"type": "status", "data": {"description": "FLUX2-Bild erzeugt", "done": True}})
        return f"![KI-Stack Bildgenerierung]({view_url})\n\nFLUX2 · {aspect_ratio} · Seed {seed}"

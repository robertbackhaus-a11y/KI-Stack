"""
title: KI-Stack Bildgenerierung
managedBy: KI-STACK-OPENWEBUI-IMAGE-PACK
version: 1.10.0
canonical_id: ki-stack-generate-image
"""

import base64
import copy
import json
import random
import time
import urllib.parse
import urllib.request

class Tools:
    _TRUSTED_COMFY_ORIGINS = {"http://127.0.0.1:8188"}

    def __init__(self):
        self.comfy_url = "http://127.0.0.1:8188"
        self.timeout_seconds = 600
        self.workflow = json.loads('''{"78":{"inputs":{"filename_prefix":"Flux2-Klein","images":["82",0]},"class_type":"SaveImage"},"80":{"inputs":{"sampler_name":"euler"},"class_type":"KSamplerSelect"},"81":{"inputs":{"noise":["86",0],"guider":["90",0],"sampler":["80",0],"sigmas":["93",0],"latent_image":["83",0]},"class_type":"SamplerCustomAdvanced"},"82":{"inputs":{"samples":["81",0],"vae":["89",0]},"class_type":"VAEDecode"},"83":{"inputs":{"width":["84",0],"height":["85",0],"batch_size":1},"class_type":"EmptyFlux2LatentImage"},"84":{"inputs":{"value":1024},"class_type":"PrimitiveInt"},"85":{"inputs":{"value":1024},"class_type":"PrimitiveInt"},"86":{"inputs":{"noise_seed":1},"class_type":"RandomNoise"},"87":{"inputs":{"unet_name":"flux-2-klein-9b-fp8.safetensors","weight_dtype":"default"},"class_type":"UNETLoader"},"88":{"inputs":{"clip_name":"qwen_3_8b_fp8mixed.safetensors","type":"flux2","device":"default"},"class_type":"CLIPLoader"},"89":{"inputs":{"vae_name":"flux2-vae.safetensors"},"class_type":"VAELoader"},"90":{"inputs":{"cfg":1,"model":["87",0],"positive":["92",0],"negative":["91",0]},"class_type":"CFGGuider"},"91":{"inputs":{"conditioning":["92",0]},"class_type":"ConditioningZeroOut"},"92":{"inputs":{"text":"","clip":["88",0]},"class_type":"CLIPTextEncode"},"93":{"inputs":{"steps":4,"width":["84",0],"height":["85",0]},"class_type":"Flux2Scheduler"}}''')
        self.pony_workflow = json.loads('''{"1":{"inputs":{"ckpt_name":"ponyDiffusionV6XL_v6StartWithThisOne.safetensors"},"class_type":"CheckpointLoaderSimple"},"2":{"inputs":{"stop_at_clip_layer":-2,"clip":["1",1]},"class_type":"CLIPSetLastLayer"},"3":{"inputs":{"text":"","clip":["2",0]},"class_type":"CLIPTextEncode"},"4":{"inputs":{"text":"blurry, low quality, bad anatomy, deformed hands, extra fingers, extra limbs, fake text, watermark, logo","clip":["2",0]},"class_type":"CLIPTextEncode"},"5":{"inputs":{"width":1024,"height":1024,"batch_size":1},"class_type":"EmptyLatentImage"},"6":{"inputs":{"seed":1,"steps":40,"cfg":3.1,"sampler_name":"euler","scheduler":"normal","denoise":1,"model":["1",0],"positive":["3",0],"negative":["4",0],"latent_image":["5",0]},"class_type":"KSampler"},"7":{"inputs":{"samples":["6",0],"vae":["1",2]},"class_type":"VAEDecode"},"11":{"inputs":{"filename_prefix":"pony_sdxl","images":["7",0]},"class_type":"SaveImage"}}''')

    def _comfy_url(self, path):
        """Build only a local, configured ComfyUI URL; untrusted values cannot select an origin."""
        origin = urllib.parse.urlsplit(self.comfy_url)
        normalized_origin = f"{origin.scheme}://{origin.netloc}"
        if origin.scheme not in {"http", "https"} or normalized_origin not in self._TRUSTED_COMFY_ORIGINS:
            raise RuntimeError("ComfyUI origin is not a trusted local HTTP(S) configuration")
        if not path.startswith("/"):
            raise ValueError("ComfyUI request path must be relative")
        return normalized_origin + path

    def _json(self, method, path, body=None, timeout=30):
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(self._comfy_url(path), data=data, method=method)
        request.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(request, timeout=timeout) as response:  # nosec B310: _comfy_url allows only trusted local HTTP(S) origins.
            return json.loads(response.read().decode("utf-8"))

    async def _persist_image(self, data_url, request, metadata, user_info):
        if not request or not user_info or not user_info.get("id"):
            raise RuntimeError("OpenWebUI user context is required for image persistence")
        from open_webui.models.users import Users
        from open_webui.utils.files import get_image_url_from_base64

        user = await Users.get_user_by_id(user_info["id"])
        if not user:
            raise RuntimeError("OpenWebUI user was not found")
        return await get_image_url_from_base64(request, data_url, metadata or {}, user)

    async def generate_image(self, prompt: str, aspect_ratio: str = "1:1", seed: int | None = None, __event_emitter__=None, __request__=None, __metadata__=None, __user__=None, __chat_id__=None, __message_id__=None) -> str:
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
        view_url = self._comfy_url("/view?" + query)
        with urllib.request.urlopen(view_url, timeout=30) as response:  # nosec B310: _comfy_url allows only trusted local HTTP(S) origins.
            payload = response.read()
            content_type = response.headers.get("Content-Type", "")
        if not payload or not content_type.startswith("image/"):
            raise RuntimeError("ComfyUI returned no valid image")
        if __event_emitter__:
            await __event_emitter__({"type": "status", "data": {"description": "FLUX2-Bild erzeugt", "done": True}})
        encoded = base64.b64encode(payload).decode("ascii")
        data_url = f"data:{content_type};base64,{encoded}"
        image_url = await self._persist_image(data_url, __request__, __metadata__, __user__)
        if not image_url:
            raise RuntimeError("OpenWebUI could not persist the generated image")
        image_files = [{"type": "image", "url": image_url}]
        if __chat_id__ and __message_id__:
            from open_webui.models.chats import Chats

            persisted = await Chats.add_message_files_by_id_and_message_id(
                __chat_id__, __message_id__, image_files
            )
            if persisted is not None:
                image_files = persisted
        if __event_emitter__:
            await __event_emitter__(
                {"type": "chat:message:files", "data": {"files": image_files}}
            )
        return json.dumps(
            {
                "status": "success",
                "message": "Das Bild ist bereits direkt im Chat sichtbar und kann dort geöffnet oder heruntergeladen werden.",
                "files": image_files,
                "aspect_ratio": aspect_ratio,
                "seed": seed,
            },
            ensure_ascii=False,
        )

    async def generate_pony_image(self, prompt: str, seed: int | None = None, __event_emitter__=None, __request__=None, __metadata__=None, __user__=None, __chat_id__=None, __message_id__=None) -> str:
        """Generate one 1024x1024 Pony SDXL image with CLIP skip 2; seed is optional."""
        if not prompt or not prompt.strip():
            raise ValueError("prompt must not be empty")
        if seed is None:
            seed = random.SystemRandom().randrange(0, 1125899906842624)
        if not isinstance(seed, int) or seed < 0 or seed > 1125899906842624:
            raise ValueError("seed must be an integer from 0 through 1125899906842624")
        workflow = copy.deepcopy(self.pony_workflow)
        workflow["3"]["inputs"]["text"] = prompt.strip()
        workflow["6"]["inputs"]["seed"] = seed
        if __event_emitter__:
            await __event_emitter__({"type": "status", "data": {"description": "Pony-SDXL-Bild wird erzeugt", "done": False}})
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
        view_url = self._comfy_url("/view?" + query)
        with urllib.request.urlopen(view_url, timeout=30) as response:  # nosec B310: _comfy_url allows only trusted local HTTP(S) origins.
            payload = response.read()
            content_type = response.headers.get("Content-Type", "")
        if not payload or not content_type.startswith("image/"):
            raise RuntimeError("ComfyUI returned no valid image")
        if __event_emitter__:
            await __event_emitter__({"type": "status", "data": {"description": "Pony-SDXL-Bild erzeugt", "done": True}})
        encoded = base64.b64encode(payload).decode("ascii")
        data_url = f"data:{content_type};base64,{encoded}"
        image_url = await self._persist_image(data_url, __request__, __metadata__, __user__)
        if not image_url:
            raise RuntimeError("OpenWebUI could not persist the generated image")
        image_files = [{"type": "image", "url": image_url}]
        if __chat_id__ and __message_id__:
            from open_webui.models.chats import Chats

            persisted = await Chats.add_message_files_by_id_and_message_id(
                __chat_id__, __message_id__, image_files
            )
            if persisted is not None:
                image_files = persisted
        if __event_emitter__:
            await __event_emitter__(
                {"type": "chat:message:files", "data": {"files": image_files}}
            )
        return json.dumps(
            {
                "status": "success",
                "message": "Das Pony-SDXL-Bild ist bereits direkt im Chat sichtbar und kann dort geöffnet oder heruntergeladen werden.",
                "files": image_files,
                "width": 1024,
                "height": 1024,
                "seed": seed,
            },
            ensure_ascii=False,
        )

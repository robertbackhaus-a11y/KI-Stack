"""
title: KI-Stack Bildgenerierung
managedBy: KI-STACK-OPENWEBUI-VISUAL-PACK
version: 2.0.5-rc2
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
        self.workflow = {
            "3": {
                "inputs": {
                    "seed": 0,
                    "steps": 8,
                    "cfg": 1.0,
                    "sampler_name": "res_multistep",
                    "scheduler": "simple",
                    "denoise": 1.0,
                    "model": ["11", 0],
                    "positive": ["27", 0],
                    "negative": ["33", 0],
                    "latent_image": ["13", 0],
                },
                "class_type": "KSampler",
            },
            "8": {
                "inputs": {"samples": ["3", 0], "vae": ["29", 0]},
                "class_type": "VAEDecode",
            },
            "9": {
                "inputs": {
                    "filename_prefix": "z-image-turbo-openwebui",
                    "images": ["8", 0],
                },
                "class_type": "SaveImage",
            },
            "11": {
                "inputs": {"shift": 3.0, "model": ["28", 0]},
                "class_type": "ModelSamplingAuraFlow",
            },
            "13": {
                "inputs": {"width": 1024, "height": 1024, "batch_size": 1},
                "class_type": "EmptySD3LatentImage",
            },
            "27": {
                "inputs": {"text": "", "clip": ["30", 0]},
                "class_type": "CLIPTextEncode",
            },
            "28": {
                "inputs": {
                    "unet_name": "z_image_turbo_bf16.safetensors",
                    "weight_dtype": "default",
                },
                "class_type": "UNETLoader",
            },
            "29": {
                "inputs": {"vae_name": "ae.safetensors"},
                "class_type": "VAELoader",
            },
            "30": {
                "inputs": {
                    "clip_name": "Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf",
                    "type": "lumina2",
                    "device": "default",
                },
                "class_type": "CLIPLoaderGGUF",
            },
            "33": {
                "inputs": {"conditioning": ["27", 0]},
                "class_type": "ConditioningZeroOut",
            },
        }

    def _comfy_url(self, path):
        origin = urllib.parse.urlsplit(self.comfy_url)
        normalized_origin = f"{origin.scheme}://{origin.netloc}"
        if (
            origin.scheme not in {"http", "https"}
            or normalized_origin not in self._TRUSTED_COMFY_ORIGINS
        ):
            raise RuntimeError("ComfyUI origin is not a trusted local configuration")
        if not path.startswith("/"):
            raise ValueError("ComfyUI request path must be relative")
        return normalized_origin + path

    def _json(self, method, path, body=None, timeout=30):
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(
            self._comfy_url(path), data=data, method=method
        )
        request.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))

    async def _persist_image(self, data_url, request, metadata, user_info):
        if not request or not user_info or not user_info.get("id"):
            raise RuntimeError("OpenWebUI user context is required")
        from open_webui.models.users import Users
        from open_webui.utils.files import get_image_url_from_base64

        user = await Users.get_user_by_id(user_info["id"])
        if not user:
            raise RuntimeError("OpenWebUI user was not found")
        return await get_image_url_from_base64(
            request, data_url, metadata or {}, user
        )

    async def generate_image(
        self,
        prompt: str,
        aspect_ratio: str = "1:1",
        seed: int | None = None,
        __event_emitter__=None,
        __request__=None,
        __metadata__=None,
        __user__=None,
        __chat_id__=None,
        __message_id__=None,
    ) -> str:
        """Generate one Z-Image Turbo image. aspect_ratio: 1:1, 16:9, or 9:16."""
        if not prompt or not prompt.strip():
            raise ValueError("prompt must not be empty")
        sizes = {
            "1:1": (1024, 1024),
            "16:9": (1280, 720),
            "9:16": (720, 1280),
        }
        if aspect_ratio not in sizes:
            raise ValueError("aspect_ratio must be 1:1, 16:9, or 9:16")
        if seed is None:
            seed = random.SystemRandom().randrange(0, 1125899906842624)
        if not isinstance(seed, int) or seed < 0 or seed > 1125899906842624:
            raise ValueError("seed is outside the supported range")

        width, height = sizes[aspect_ratio]
        workflow = copy.deepcopy(self.workflow)
        workflow["27"]["inputs"]["text"] = prompt.strip()
        workflow["13"]["inputs"]["width"] = width
        workflow["13"]["inputs"]["height"] = height
        workflow["3"]["inputs"]["seed"] = seed

        if __event_emitter__:
            await __event_emitter__(
                {
                    "type": "status",
                    "data": {
                        "description": "Z-Image-Bild wird erzeugt",
                        "done": False,
                    },
                }
            )

        queued = self._json("POST", "/prompt", {"prompt": workflow})
        prompt_id = queued.get("prompt_id")
        if not prompt_id:
            raise RuntimeError("ComfyUI returned no prompt_id")

        deadline = time.monotonic() + self.timeout_seconds
        image = None
        while time.monotonic() < deadline:
            history = self._json(
                "GET", "/history/" + urllib.parse.quote(prompt_id), timeout=30
            )
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
            raise TimeoutError("ComfyUI Z-Image generation timed out")

        query = urllib.parse.urlencode(
            {
                "filename": image["filename"],
                "subfolder": image.get("subfolder", ""),
                "type": image.get("type", "output"),
            }
        )
        with urllib.request.urlopen(self._comfy_url("/view?" + query), timeout=30) as response:
            payload = response.read()
            content_type = response.headers.get("Content-Type", "")
        if not payload or not content_type.startswith("image/"):
            raise RuntimeError("ComfyUI returned no valid image")

        data_url = (
            f"data:{content_type};base64,"
            + base64.b64encode(payload).decode("ascii")
        )
        image_url = await self._persist_image(
            data_url, __request__, __metadata__, __user__
        )
        if not image_url:
            raise RuntimeError("OpenWebUI could not persist the generated image")

        files = [{"type": "image", "url": image_url}]
        if __chat_id__ and __message_id__:
            from open_webui.models.chats import Chats

            persisted = await Chats.add_message_files_by_id_and_message_id(
                __chat_id__, __message_id__, files
            )
            if persisted is not None:
                files = persisted
        if __event_emitter__:
            await __event_emitter__(
                {"type": "status", "data": {"description": "Z-Image-Bild erzeugt", "done": True}}
            )
            await __event_emitter__(
                {"type": "chat:message:files", "data": {"files": files}}
            )
        return json.dumps(
            {
                "status": "success",
                "message": "Das Z-Image-Bild ist direkt im Chat verfügbar.",
                "files": files,
                "aspect_ratio": aspect_ratio,
                "seed": seed,
            },
            ensure_ascii=False,
        )

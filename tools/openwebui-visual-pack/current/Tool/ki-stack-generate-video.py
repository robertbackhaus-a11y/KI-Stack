"""
title: KI-Stack Videogenerierung
managedBy: KI-STACK-OPENWEBUI-VISUAL-PACK
version: 2.0.5-rc3
canonical_id: ki-stack-generate-video
"""

import asyncio
import copy
import io
import json
import random
import time
import urllib.parse
import urllib.request


class Tools:
    _TRUSTED_COMFY_ORIGINS = {"http://127.0.0.1:8188"}
    _NEGATIVE_PROMPT = (
        "low quality, worst quality, blurry details, overexposure, underexposure, "
        "JPEG artifacts, compression artifacts, text, subtitles, watermark, logo, "
        "static frame, frozen motion, deformed anatomy, distorted face, poorly drawn "
        "face, poorly drawn hands, extra limbs, missing limbs, duplicated limbs, "
        "extra arms, extra legs, extra fingers, missing fingers, fused fingers, "
        "malformed joints, unnatural proportions, detached body parts, floating "
        "objects, floating accessories, disconnected components, duplicated objects, "
        "fused objects, intersecting geometry, fragmented objects, incomplete objects, "
        "impossible construction, inconsistent scale, broken perspective, detached "
        "optic, floating scope, misaligned optic, duplicated optic, missing mounting "
        "interface, impossible weapon geometry, fused weapon parts, temporal flicker, "
        "frame-to-frame inconsistency, identity drift, object morphing, disappearing "
        "objects, appearing objects, unstable geometry, warped motion, unnatural "
        "movement, unstable camera"
    )

    def __init__(self):
        self.comfy_url = "http://127.0.0.1:8188"
        self.timeout_seconds = 1200
        self.workflow = {
            "71": {
                "inputs": {
                    "clip_name": "umt5_xxl_fp8_e4m3fn_scaled.safetensors",
                    "type": "wan",
                    "device": "default",
                },
                "class_type": "CLIPLoader",
            },
            "72": {
                "inputs": {"text": self._NEGATIVE_PROMPT, "clip": ["71", 0]},
                "class_type": "CLIPTextEncode",
            },
            "73": {
                "inputs": {"vae_name": "wan_2.1_vae.safetensors"},
                "class_type": "VAELoader",
            },
            "74": {
                "inputs": {
                    "width": 640,
                    "height": 640,
                    "length": 81,
                    "batch_size": 1,
                },
                "class_type": "EmptyHunyuanLatentVideo",
            },
            "75": {
                "inputs": {
                    "unet_name": "wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors",
                    "weight_dtype": "default",
                },
                "class_type": "UNETLoader",
            },
            "76": {
                "inputs": {
                    "unet_name": "wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors",
                    "weight_dtype": "default",
                },
                "class_type": "UNETLoader",
            },
            "78": {
                "inputs": {
                    "add_noise": "disable",
                    "noise_seed": 0,
                    "steps": 4,
                    "cfg": 1.0,
                    "sampler_name": "euler",
                    "scheduler": "simple",
                    "start_at_step": 2,
                    "end_at_step": 4,
                    "return_with_leftover_noise": "disable",
                    "model": ["86", 0],
                    "positive": ["89", 0],
                    "negative": ["72", 0],
                    "latent_image": ["81", 0],
                },
                "class_type": "KSamplerAdvanced",
            },
            "80": {
                "inputs": {
                    "filename_prefix": "video/wan22-openwebui",
                    "format": "mp4",
                    "codec": "h264",
                    "video": ["88", 0],
                },
                "class_type": "SaveVideo",
            },
            "81": {
                "inputs": {
                    "add_noise": "enable",
                    "noise_seed": 0,
                    "steps": 4,
                    "cfg": 1.0,
                    "sampler_name": "euler",
                    "scheduler": "simple",
                    "start_at_step": 0,
                    "end_at_step": 2,
                    "return_with_leftover_noise": "enable",
                    "model": ["82", 0],
                    "positive": ["89", 0],
                    "negative": ["72", 0],
                    "latent_image": ["74", 0],
                },
                "class_type": "KSamplerAdvanced",
            },
            "82": {
                "inputs": {"shift": 5.0, "model": ["83", 0]},
                "class_type": "ModelSamplingSD3",
            },
            "83": {
                "inputs": {
                    "lora_name": "Wan2.2_LightX2V_high_n54vv.safetensors",
                    "strength_model": 1.0,
                    "model": ["75", 0],
                },
                "class_type": "LoraLoaderModelOnly",
            },
            "85": {
                "inputs": {
                    "lora_name": "Wan2.2_LightX2V_low_n54vv.safetensors",
                    "strength_model": 1.0,
                    "model": ["76", 0],
                },
                "class_type": "LoraLoaderModelOnly",
            },
            "86": {
                "inputs": {"shift": 5.0, "model": ["85", 0]},
                "class_type": "ModelSamplingSD3",
            },
            "87": {
                "inputs": {"samples": ["78", 0], "vae": ["73", 0]},
                "class_type": "VAEDecode",
            },
            "88": {
                "inputs": {"images": ["87", 0], "fps": 16.0, "bit_depth": 8},
                "class_type": "CreateVideo",
            },
            "89": {
                "inputs": {"text": "", "clip": ["71", 0]},
                "class_type": "CLIPTextEncode",
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

    @staticmethod
    def _find_video_file(value):
        candidates = []

        def visit(item):
            if isinstance(item, dict):
                filename = item.get("filename")
                if isinstance(filename, str) and filename:
                    candidates.append(item)
                for nested in item.values():
                    visit(nested)
            elif isinstance(item, list):
                for nested in item:
                    visit(nested)

        visit(value)
        for candidate in candidates:
            if str(candidate.get("filename", "")).lower().endswith(".mp4"):
                return candidate
        return candidates[0] if candidates else None

    async def _persist_video(self, payload, filename, request, user_info):
        if not request or not user_info or not user_info.get("id"):
            raise RuntimeError("OpenWebUI user context is required")
        from open_webui.models.users import Users
        from open_webui.routers.files import upload_file_handler
        from starlette.datastructures import Headers, UploadFile

        user = await Users.get_user_by_id(user_info["id"])
        if not user:
            raise RuntimeError("OpenWebUI user was not found")
        upload = UploadFile(
            file=io.BytesIO(payload),
            filename=filename,
            headers=Headers({"content-type": "video/mp4"}),
        )
        item = await upload_file_handler(
            request,
            file=upload,
            metadata={"source": "ki-stack-wan22"},
            process=False,
            process_in_background=False,
            user=user,
            background_tasks=None,
            db=None,
        )
        file_id = item.get("id") if isinstance(item, dict) else item.id
        if not file_id:
            raise RuntimeError("OpenWebUI returned no persisted file id")
        return {
            "id": file_id,
            "type": "file",
            "name": filename,
            "url": f"/api/v1/files/{file_id}/content",
            "content_type": "video/mp4",
            "size": len(payload),
            "meta": {
                "name": filename,
                "content_type": "video/mp4",
                "size": len(payload),
            },
        }

    async def generate_video(
        self,
        prompt: str,
        seed: int | None = None,
        __event_emitter__=None,
        __request__=None,
        __user__=None,
        __chat_id__=None,
        __message_id__=None,
    ) -> str:
        """Generate one 640x640, 5-second WAN2.2 T2V MP4 video at 16 fps."""
        if not prompt or not prompt.strip():
            raise ValueError("prompt must not be empty")
        if seed is None:
            seed = random.SystemRandom().randrange(0, 1125899906842624)
        if not isinstance(seed, int) or seed < 0 or seed > 1125899906842624:
            raise ValueError("seed is outside the supported range")

        workflow = copy.deepcopy(self.workflow)
        workflow["89"]["inputs"]["text"] = prompt.strip()
        workflow["81"]["inputs"]["noise_seed"] = seed

        if __event_emitter__:
            await __event_emitter__(
                {
                    "type": "status",
                    "data": {
                        "description": "WAN2.2-Video wird erzeugt",
                        "done": False,
                    },
                }
            )

        queued = self._json("POST", "/prompt", {"prompt": workflow})
        prompt_id = queued.get("prompt_id")
        if not prompt_id:
            raise RuntimeError("ComfyUI returned no prompt_id")

        deadline = time.monotonic() + self.timeout_seconds
        video = None
        while time.monotonic() < deadline:
            history = self._json(
                "GET", "/history/" + urllib.parse.quote(prompt_id), timeout=30
            )
            record = history.get(prompt_id)
            if record:
                video = self._find_video_file(record.get("outputs", {}))
            if video:
                break
            await asyncio.sleep(1)
        if not video:
            raise TimeoutError("ComfyUI WAN2.2 generation timed out")

        query = urllib.parse.urlencode(
            {
                "filename": video["filename"],
                "subfolder": video.get("subfolder", ""),
                "type": video.get("type", "output"),
            }
        )
        with urllib.request.urlopen(self._comfy_url("/view?" + query), timeout=60) as response:
            payload = response.read()
            content_type = response.headers.get("Content-Type", "")
        if not payload:
            raise RuntimeError("ComfyUI returned an empty video")
        if content_type and not (
            content_type.startswith("video/") or content_type == "application/octet-stream"
        ):
            raise RuntimeError(f"ComfyUI returned unexpected content type: {content_type}")

        filename = str(video["filename"]).split("/")[-1]
        if not filename.lower().endswith(".mp4"):
            filename += ".mp4"
        video_file = await self._persist_video(
            payload, filename, __request__, __user__
        )
        files = [video_file]
        if __event_emitter__:
            await __event_emitter__(
                {"type": "status", "data": {"description": "WAN2.2-Video erzeugt", "done": True}}
            )
            await __event_emitter__(
                {"type": "files", "data": {"files": files}}
            )
        return json.dumps(
            {
                "status": "success",
                "message": (
                    "Das WAN2.2-Video ist direkt im Chat verfügbar: "
                    + video_file["url"]
                ),
                "files": files,
                "video_url": video_file["url"],
                "resolution": "640x640",
                "duration_seconds": 5,
                "fps": 16,
                "seed": seed,
            },
            ensure_ascii=False,
        )

import asyncio
import importlib.util
import json
import pathlib
import unittest
from unittest.mock import AsyncMock, patch


ROOT = pathlib.Path(__file__).parents[1]


def load_module(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


IMAGE = load_module("ki_stack_image", "Tool/ki-stack-generate-image.py")
VIDEO = load_module("ki_stack_video", "Tool/ki-stack-generate-video.py")


class FakeResponse:
    def __init__(self, payload, content_type):
        self.payload = payload
        self.headers = {"Content-Type": content_type}

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return self.payload


class VisualToolTests(unittest.TestCase):
    def test_embedded_workflows_match_package_files(self):
        image_json = json.loads(
            (ROOT / "Workflow/Z-Image-Turbo-OpenWebUI-API.json").read_text()
        )
        video_json = json.loads(
            (ROOT / "Workflow/WAN2.2-T2V-14B-OpenWebUI-API.json").read_text()
        )
        self.assertEqual(image_json, IMAGE.Tools().workflow)
        self.assertEqual(video_json, VIDEO.Tools().workflow)

    def test_all_workflow_links_resolve(self):
        for workflow in (IMAGE.Tools().workflow, VIDEO.Tools().workflow):
            for node in workflow.values():
                for value in node["inputs"].values():
                    if (
                        isinstance(value, list)
                        and len(value) == 2
                        and isinstance(value[0], str)
                        and isinstance(value[1], int)
                    ):
                        self.assertIn(value[0], workflow)

    def test_image_contract(self):
        tool = IMAGE.Tools()
        serialized = json.dumps(tool.workflow)
        self.assertIn("z_image_turbo_bf16.safetensors", serialized)
        self.assertIn(
            "Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf", serialized
        )

    def test_video_contract(self):
        tool = VIDEO.Tools()
        serialized = json.dumps(tool.workflow)
        self.assertIn(
            "wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors", serialized
        )
        self.assertIn(
            "wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors", serialized
        )
        self.assertEqual("mp4", tool.workflow["80"]["inputs"]["format"])
        self.assertEqual("h264", tool.workflow["80"]["inputs"]["codec"])
        self.assertEqual(4, tool.workflow["81"]["inputs"]["steps"])
        self.assertEqual(2, tool.workflow["81"]["inputs"]["end_at_step"])
        self.assertEqual(2, tool.workflow["78"]["inputs"]["start_at_step"])
        self.assertEqual(81, tool.workflow["74"]["inputs"]["length"])
        self.assertIn("floating scope", tool.workflow["72"]["inputs"]["text"])

    def test_video_history_file_discovery(self):
        tool = VIDEO.Tools()
        found = tool._find_video_file(
            {
                "80": {
                    "video": {
                        "filename": "video/test.mp4",
                        "subfolder": "",
                        "type": "output",
                    }
                }
            }
        )
        self.assertEqual("video/test.mp4", found["filename"])

    def test_image_generation_adapter(self):
        tool = IMAGE.Tools()
        calls = []

        def fake_json(method, path, body=None, timeout=30):
            calls.append((method, path, body))
            if method == "POST":
                return {"prompt_id": "image-1"}
            return {
                "image-1": {
                    "outputs": {
                        "9": {
                            "images": [
                                {
                                    "filename": "z.png",
                                    "subfolder": "",
                                    "type": "output",
                                }
                            ]
                        }
                    }
                }
            }

        tool._json = fake_json
        tool._persist_image = AsyncMock(
            return_value="/api/v1/files/image-1/content"
        )
        events = []

        async def emitter(event):
            events.append(event)

        with patch.object(
            IMAGE.urllib.request,
            "urlopen",
            return_value=FakeResponse(b"png", "image/png"),
        ):
            result = asyncio.run(
                tool.generate_image(
                    "test",
                    aspect_ratio="16:9",
                    seed=7,
                    __event_emitter__=emitter,
                    __request__=object(),
                    __metadata__={},
                    __user__={"id": "user-1"},
                )
            )
        body = json.loads(result)
        submitted = calls[0][2]["prompt"]
        self.assertEqual(1280, submitted["13"]["inputs"]["width"])
        self.assertEqual(720, submitted["13"]["inputs"]["height"])
        self.assertEqual(7, submitted["3"]["inputs"]["seed"])
        self.assertEqual("success", body["status"])
        self.assertEqual("image", body["files"][0]["type"])
        self.assertEqual(
            ["status", "status", "chat:message:files"],
            [event["type"] for event in events],
        )

    def test_video_generation_adapter(self):
        tool = VIDEO.Tools()
        calls = []

        def fake_json(method, path, body=None, timeout=30):
            calls.append((method, path, body))
            if method == "POST":
                return {"prompt_id": "video-1"}
            return {
                "video-1": {
                    "outputs": {
                        "80": {
                            "video": {
                                "filename": "video/wan.mp4",
                                "subfolder": "",
                                "type": "output",
                            }
                        }
                    }
                }
            }

        tool._json = fake_json
        tool._persist_video = AsyncMock(
            return_value={
                "id": "video-1",
                "type": "file",
                "name": "wan.mp4",
                "url": "/api/v1/files/video-1/content",
                "content_type": "video/mp4",
                "size": 3,
                "meta": {
                    "name": "wan.mp4",
                    "content_type": "video/mp4",
                    "size": 3,
                },
            }
        )
        events = []

        async def emitter(event):
            events.append(event)

        with patch.object(
            VIDEO.urllib.request,
            "urlopen",
            return_value=FakeResponse(b"mp4", "video/mp4"),
        ):
            result = asyncio.run(
                tool.generate_video(
                    "test",
                    seed=9,
                    __event_emitter__=emitter,
                    __request__=object(),
                    __user__={"id": "user-1"},
                )
            )
        body = json.loads(result)
        submitted = calls[0][2]["prompt"]
        self.assertEqual(9, submitted["81"]["inputs"]["noise_seed"])
        self.assertEqual("success", body["status"])
        self.assertEqual("file", body["files"][0]["type"])
        self.assertEqual("video-1", body["files"][0]["id"])
        self.assertEqual(
            "/api/v1/files/video-1/content", body["video_url"]
        )
        self.assertEqual("video/mp4", body["files"][0]["content_type"])
        self.assertEqual(3, body["files"][0]["size"])
        self.assertEqual("video/mp4", body["files"][0]["meta"]["content_type"])
        self.assertEqual(
            ["status", "status", "files"],
            [event["type"] for event in events],
        )
        self.assertEqual(1, len(body["files"]))
        self.assertEqual(1, len(events[-1]["data"]["files"]))
        self.assertEqual(body["files"], events[-1]["data"]["files"])
        self.assertNotIn(
            "add_message_files_by_id_and_message_id",
            (ROOT / "Tool/ki-stack-generate-video.py").read_text(),
        )

    def test_video_attachment_is_not_missing(self):
        source = (ROOT / "Tool/ki-stack-generate-video.py").read_text()
        self.assertIn('{"type": "files", "data": {"files": files}}', source)
        self.assertIn('"files": files', source)
        self.assertIn('"type": "file"', source)

    def test_video_attachment_is_not_emitted_twice(self):
        source = (ROOT / "Tool/ki-stack-generate-video.py").read_text()
        self.assertEqual(
            1,
            source.count('{"type": "files", "data": {"files": files}}'),
        )
        self.assertNotIn("chat:message:files", source)
        self.assertNotIn("add_message_files_by_id_and_message_id", source)

    def test_video_attachment_content_route_is_openable(self):
        file_id = "12345678-abcd-4321-abcd-1234567890ab"
        item = {
            "id": file_id,
            "type": "file",
            "name": "wan.mp4",
            "url": f"/api/v1/files/{file_id}/content",
            "content_type": "video/mp4",
            "size": 3,
            "meta": {
                "name": "wan.mp4",
                "content_type": "video/mp4",
                "size": 3,
            },
        }
        self.assertEqual(
            f"/api/v1/files/{item['id']}/content",
            item["url"],
        )
        self.assertFalse(item["url"].endswith("/content/content"))
        self.assertTrue(item["name"].lower().endswith(".mp4"))

    def test_local_origin_restriction(self):
        for tool in (IMAGE.Tools(), VIDEO.Tools()):
            self.assertEqual(
                "http://127.0.0.1:8188/prompt", tool._comfy_url("/prompt")
            )
            tool.comfy_url = "http://example.com:8188"
            with self.assertRaises(RuntimeError):
                tool._comfy_url("/prompt")


if __name__ == "__main__":
    unittest.main()

import asyncio
import importlib.util
import json
import pathlib
import unittest
from unittest.mock import AsyncMock, patch


TOOL = pathlib.Path(__file__).parents[1] / "Tool" / "ki-stack-generate-image.py"
SPEC = importlib.util.spec_from_file_location("ki_stack_image_tool", TOOL)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FakeResponse:
    headers = {"Content-Type": "image/png"}
    def __enter__(self): return self
    def __exit__(self, *_): return False
    def read(self): return b"\x89PNG\r\n\x1a\nvalid"


class AdapterTests(unittest.TestCase):
    def test_prompt_ratio_and_seed_are_patched(self):
        tool = MODULE.Tools()
        tool._persist_image = AsyncMock(return_value="/api/v1/files/file-1/content")
        events = []
        async def emit(event): events.append(event)
        calls = []
        def fake_json(method, path, body=None, timeout=30):
            calls.append((method, path, body))
            if path == "/prompt": return {"prompt_id": "p1"}
            return {"p1": {"outputs": {"78": {"images": [{"filename": "x.png", "type": "output"}]}}}}
        tool._json = fake_json
        with patch.object(MODULE.urllib.request, "urlopen", return_value=FakeResponse()):
            result = asyncio.run(tool.generate_image("exact prompt", "16:9", 42, __event_emitter__=emit, __request__=object(), __user__={"id": "user-1"}))
        workflow = calls[0][2]["prompt"]
        self.assertEqual(workflow["92"]["inputs"]["text"], "exact prompt")
        self.assertEqual((workflow["84"]["inputs"]["value"], workflow["85"]["inputs"]["value"]), (768, 432))
        self.assertEqual(workflow["86"]["inputs"]["noise_seed"], 42)
        body = json.loads(result)
        self.assertEqual(body["status"], "success")
        self.assertEqual(body["files"], [{"type": "image", "url": "/api/v1/files/file-1/content"}])
        self.assertEqual(events[-1], {"type": "chat:message:files", "data": {"files": body["files"]}})
        self.assertEqual([event["type"] for event in events], ["status", "status", "chat:message:files"])
        serialized = json.dumps(body)
        self.assertNotIn("data:image/png;base64,", serialized)
        self.assertNotIn("/mnt/uploads/", serialized)
        self.assertNotIn("127.0.0.1:8188/view", serialized)
        self.assertNotIn("C:\\", serialized)

    def test_invalid_ratio_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "aspect_ratio"):
            asyncio.run(MODULE.Tools().generate_image("x", "4:3"))

    def test_empty_prompt_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "prompt"):
            asyncio.run(MODULE.Tools().generate_image(" "))

    def test_invalid_seed_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "seed"):
            asyncio.run(MODULE.Tools().generate_image("x", seed=-1))

    def test_empty_history_times_out(self):
        tool = MODULE.Tools(); tool.timeout_seconds = -1
        tool._json = lambda *args, **kwargs: {"prompt_id": "p1"} if args[1] == "/prompt" else {}
        with self.assertRaises(TimeoutError): asyncio.run(tool.generate_image("x"))

    def test_invalid_image_is_rejected(self):
        tool = MODULE.Tools()
        tool._json = lambda *args, **kwargs: {"prompt_id": "p1"} if args[1] == "/prompt" else {"p1": {"outputs": {"78": {"images": [{"filename": "x.bin"}]}}}}
        bad = FakeResponse(); bad.headers = {"Content-Type": "application/octet-stream"}; bad.read = lambda: b"bad"
        with patch.object(MODULE.urllib.request, "urlopen", return_value=bad):
            with self.assertRaises(RuntimeError): asyncio.run(tool.generate_image("x"))


if __name__ == "__main__": unittest.main()

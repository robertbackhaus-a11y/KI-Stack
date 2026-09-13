"""Unit tests for ki_desktop_control_tools.py (KI-Stack MCP Runtime, 2.19 Phase 1).

No GUI, no real dispatcher, no real winapp: `subprocess.run` is mocked throughout. These tests
cover exactly the Phase-1 test list (see MCP-INTEGRATION.md): exact tool names with no
namespace/prefix drift, request -> Desktop-Control-operation mapping, invalid JSON, a missing
dispatcher, a non-zero dispatcher exit, `SecretContextBlocked`/`PostconditionNotProven` passed
through unchanged, a read-only and a mutating success, and that no raw-winapp/send-input surface
is ever registered.

Run (from this Scripts/ directory) against the SAME dependency resolution
`Config/mcp-runtime.config.json`'s `packageSpec` actually produces at runtime -- never a
hand-picked fastmcp version. `open-terminal[mcp]==0.11.34` resolves fastmcp 4.0.3 as of this
writing (verified 2026-09-13; re-verify after any `packageSpec` version bump, since a pinned
extra can still resolve a different transitive version over time):

    uv run --with "open-terminal[mcp]==0.11.34" python -m unittest test_ki_desktop_control_tools.py -v
"""

from __future__ import annotations

import asyncio
import json
import subprocess
import unittest
from unittest import mock

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError

import ki_desktop_control_tools as uitools

FAKE_TARGET_ROOT = r"C:\FakeKIStack"
FAKE_DISPATCHER = uitools.resolve_dispatcher_path(FAKE_TARGET_ROOT)


def _completed(stdout: str = "", stderr: str = "", returncode: int = 0) -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(args=["pwsh"], returncode=returncode, stdout=stdout, stderr=stderr)


class RunDesktopControlOperationTests(unittest.TestCase):
    """Direct tests of the transport function, independent of FastMCP tool registration."""

    def setUp(self) -> None:
        self._isfile_patch = mock.patch("os.path.isfile")
        self.mock_isfile = self._isfile_patch.start()
        self.addCleanup(self._isfile_patch.stop)

        def isfile_side_effect(path: str) -> bool:
            return path == FAKE_DISPATCHER

        self.mock_isfile.side_effect = isfile_side_effect

        self._pwsh_patch = mock.patch.object(uitools, "_resolve_pwsh", return_value=r"C:\pwsh.exe")
        self._pwsh_patch.start()
        self.addCleanup(self._pwsh_patch.stop)

    def test_dispatcher_missing_raises_tool_error_no_path_fallback(self) -> None:
        self.mock_isfile.side_effect = lambda path: False
        with self.assertRaises(ToolError) as ctx:
            uitools.run_desktop_control_operation("list_windows", {}, FAKE_TARGET_ROOT)
        self.assertIn(FAKE_DISPATCHER, str(ctx.exception))
        self.assertIn("PATH-Fallback", str(ctx.exception))

    def test_invalid_json_raises_tool_error(self) -> None:
        with mock.patch.object(uitools.subprocess, "run", return_value=_completed(stdout="not json", returncode=0)):
            with self.assertRaises(ToolError) as ctx:
                uitools.run_desktop_control_operation("list_windows", {}, FAKE_TARGET_ROOT)
        self.assertIn("gueltiges JSON", str(ctx.exception))

    def test_empty_stdout_with_nonzero_exit_raises_tool_error(self) -> None:
        # A real crash: dispatcher exits non-zero AND produces no parseable JSON at all.
        with mock.patch.object(uitools.subprocess, "run", return_value=_completed(stdout="", stderr="boom", returncode=1)):
            with self.assertRaises(ToolError) as ctx:
                uitools.run_desktop_control_operation("list_windows", {}, FAKE_TARGET_ROOT)
        self.assertIn("boom", str(ctx.exception))

    def test_nonzero_exit_with_valid_json_is_not_an_error_secret_context_blocked(self) -> None:
        # Invoke-KIStackDesktopControl.ps1 exits 1 for every business-level success:false too --
        # a valid JSON object must be returned unchanged, never turned into an MCP error.
        payload = {
            "schemaVersion": "1.0", "operation": "get_value", "mode": "mutating",
            "success": False, "status": "SecretContextBlocked", "blockedReason": "secret",
        }
        with mock.patch.object(uitools.subprocess, "run", return_value=_completed(stdout=json.dumps(payload), returncode=1)):
            result = uitools.run_desktop_control_operation("get_value", {}, FAKE_TARGET_ROOT)
        self.assertEqual(result, payload)

    def test_nonzero_exit_with_valid_json_is_not_an_error_postcondition_not_proven(self) -> None:
        payload = {
            "schemaVersion": "1.0", "operation": "set_value", "mode": "mutating",
            "success": False, "status": "PostconditionNotProven", "blockedReason": "readback failed",
        }
        with mock.patch.object(uitools.subprocess, "run", return_value=_completed(stdout=json.dumps(payload), returncode=1)):
            result = uitools.run_desktop_control_operation("set_value", {}, FAKE_TARGET_ROOT)
        self.assertEqual(result, payload)

    def test_read_only_success_returned_unchanged(self) -> None:
        payload = {"schemaVersion": "1.0", "operation": "list_windows", "mode": "read-only", "success": True, "status": "OK", "result": {"windowCount": 1, "windows": [{"hwnd": "1001"}]}}
        with mock.patch.object(uitools.subprocess, "run", return_value=_completed(stdout=json.dumps(payload), returncode=0)) as mock_run:
            result = uitools.run_desktop_control_operation("list_windows", {"application": "notepad"}, FAKE_TARGET_ROOT)
        self.assertEqual(result, payload)
        called_args = mock_run.call_args.args[0]
        self.assertIn("-Operation", called_args)
        self.assertEqual(called_args[called_args.index("-Operation") + 1], "list_windows")
        self.assertIn("-RequestJson", called_args)
        self.assertEqual(json.loads(called_args[called_args.index("-RequestJson") + 1]), {"application": "notepad"})
        self.assertIn("-TargetRoot", called_args)
        self.assertEqual(called_args[called_args.index("-TargetRoot") + 1], FAKE_TARGET_ROOT)
        self.assertEqual(called_args[called_args.index("-File") + 1], FAKE_DISPATCHER)

    def test_mutating_success_returned_unchanged(self) -> None:
        payload = {"schemaVersion": "1.0", "operation": "invoke", "mode": "mutating", "success": True, "status": "OK", "postcondition": {"proven": True}}
        with mock.patch.object(uitools.subprocess, "run", return_value=_completed(stdout=json.dumps(payload), returncode=0)):
            result = uitools.run_desktop_control_operation("invoke", {"element": {"automationId": "OkButton"}}, FAKE_TARGET_ROOT)
        self.assertEqual(result, payload)

    def test_timeout_raises_tool_error(self) -> None:
        with mock.patch.object(uitools.subprocess, "run", side_effect=subprocess.TimeoutExpired(cmd="pwsh", timeout=45)):
            with self.assertRaises(ToolError):
                uitools.run_desktop_control_operation("list_windows", {}, FAKE_TARGET_ROOT)

    def test_process_start_failure_raises_tool_error(self) -> None:
        with mock.patch.object(uitools.subprocess, "run", side_effect=OSError("no such file")):
            with self.assertRaises(ToolError):
                uitools.run_desktop_control_operation("list_windows", {}, FAKE_TARGET_ROOT)


class RegisterUiToolsSurfaceTests(unittest.TestCase):
    """Verifies the registered tool surface itself: names, no drift, no forbidden tools."""

    def setUp(self) -> None:
        self.mcp = FastMCP(name="test-server")
        uitools.register_ui_tools(self.mcp, FAKE_TARGET_ROOT)

    def _tool_names(self) -> set[str]:
        tools = asyncio.run(self.mcp.list_tools())
        return {t.name for t in tools}

    def test_exact_tool_names_no_drift(self) -> None:
        expected = set(uitools.UI_TOOL_TO_OPERATION.keys())
        self.assertEqual(self._tool_names(), expected)
        self.assertEqual(
            expected,
            {
                "ui_list_windows", "ui_inspect_window", "ui_find_element", "ui_get_properties",
                "ui_get_value", "ui_screenshot", "ui_wait_for", "ui_set_value", "ui_invoke", "ui_focus",
            },
        )

    def test_no_forbidden_ui_surface_registered(self) -> None:
        forbidden = {
            "ui_scroll", "ui_scroll_into_view", "send_input", "send_keys", "global_hotkey",
            "system_hotkey", "coordinate_click", "mouse_click_coordinate", "drag", "touch",
            "pen", "raw_winapp", "desktop_control",
        }
        self.assertEqual(self._tool_names() & forbidden, set())

    def test_flat_prefix_no_namespacing(self) -> None:
        for name in self._tool_names():
            self.assertTrue(name.startswith("ui_"), name)
            self.assertNotIn(":", name)
            self.assertNotIn(".", name)


class RegisterUiToolsMappingTests(unittest.TestCase):
    """Each ui_* tool maps to exactly one Desktop-Control operation with the right RequestJson."""

    def setUp(self) -> None:
        self.mcp = FastMCP(name="test-server")
        uitools.register_ui_tools(self.mcp, FAKE_TARGET_ROOT)
        self._run_patch = mock.patch.object(uitools, "run_desktop_control_operation", return_value={"success": True})
        self.mock_run = self._run_patch.start()
        self.addCleanup(self._run_patch.stop)

    def _fn(self, tool_name: str):
        tools = {t.name: t for t in asyncio.run(self.mcp.list_tools())}
        return tools[tool_name].fn

    def test_ui_list_windows_maps_to_list_windows(self) -> None:
        self._fn("ui_list_windows")(application="notepad")
        operation, request, target_root = self.mock_run.call_args.args
        self.assertEqual(operation, "list_windows")
        self.assertEqual(request, {"application": "notepad"})
        self.assertEqual(target_root, FAKE_TARGET_ROOT)

    def test_ui_list_windows_omits_none_fields(self) -> None:
        self._fn("ui_list_windows")(application=None)
        _, request, _ = self.mock_run.call_args.args
        self.assertEqual(request, {})

    def test_ui_inspect_window_maps_to_inspect_window(self) -> None:
        self._fn("ui_inspect_window")(hwnd="1001", titlePattern="Editor")
        operation, request, _ = self.mock_run.call_args.args
        self.assertEqual(operation, "inspect_window")
        self.assertEqual(request, {"hwnd": "1001", "titlePattern": "Editor"})

    def test_ui_find_element_maps_element_identity(self) -> None:
        element = uitools.UiElementIdentity(automationId="TextBox1", name="Body")
        self._fn("ui_find_element")(hwnd="1001", element=element)
        operation, request, _ = self.mock_run.call_args.args
        self.assertEqual(operation, "find_element")
        self.assertEqual(request, {"hwnd": "1001", "element": {"automationId": "TextBox1", "name": "Body"}})

    def test_ui_get_properties_maps_to_get_properties(self) -> None:
        element = uitools.UiElementIdentity(selector="sel-1")
        self._fn("ui_get_properties")(hwnd="1001", element=element)
        operation, _, _ = self.mock_run.call_args.args
        self.assertEqual(operation, "get_properties")

    def test_ui_get_value_maps_to_get_value(self) -> None:
        element = uitools.UiElementIdentity(automationId="TextBox1")
        self._fn("ui_get_value")(hwnd="1001", element=element)
        operation, _, _ = self.mock_run.call_args.args
        self.assertEqual(operation, "get_value")

    def test_ui_screenshot_maps_to_screenshot(self) -> None:
        self._fn("ui_screenshot")(hwnd="1001")
        operation, request, _ = self.mock_run.call_args.args
        self.assertEqual(operation, "screenshot")
        self.assertEqual(request, {"hwnd": "1001"})

    def test_ui_wait_for_maps_timeout_and_element(self) -> None:
        element = uitools.UiElementIdentity(name="Ready")
        self._fn("ui_wait_for")(element=element, hwnd="1001", timeoutMs=5000)
        operation, request, _ = self.mock_run.call_args.args
        self.assertEqual(operation, "wait_for")
        self.assertEqual(request, {"hwnd": "1001", "element": {"name": "Ready"}, "timeoutMs": 5000})

    def test_ui_set_value_maps_value_and_element(self) -> None:
        element = uitools.UiElementIdentity(automationId="TextBox1")
        self._fn("ui_set_value")(element=element, value="hello", hwnd="1001")
        operation, request, _ = self.mock_run.call_args.args
        self.assertEqual(operation, "set_value")
        self.assertEqual(request, {"hwnd": "1001", "element": {"automationId": "TextBox1"}, "value": "hello"})

    def test_ui_invoke_maps_expect_tree_change(self) -> None:
        element = uitools.UiElementIdentity(automationId="OkButton")
        self._fn("ui_invoke")(element=element, hwnd="1001", expectTreeChange="Saved")
        operation, request, _ = self.mock_run.call_args.args
        self.assertEqual(operation, "invoke")
        self.assertEqual(request, {"hwnd": "1001", "element": {"automationId": "OkButton"}, "expectTreeChange": "Saved"})

    def test_ui_focus_maps_to_focus(self) -> None:
        element = uitools.UiElementIdentity(automationId="TextBox1")
        self._fn("ui_focus")(element=element, hwnd="1001")
        operation, request, _ = self.mock_run.call_args.args
        self.assertEqual(operation, "focus")
        self.assertEqual(request, {"hwnd": "1001", "element": {"automationId": "TextBox1"}})

    def test_every_mapped_operation_is_in_the_allowed_desktop_control_set(self) -> None:
        allowed = {
            "list_windows", "inspect_window", "find_element", "get_properties", "get_value",
            "screenshot", "wait_for", "set_value", "invoke", "focus",
        }
        self.assertEqual(set(uitools.UI_TOOL_TO_OPERATION.values()), allowed)


class ToolResultPassthroughTests(unittest.TestCase):
    """End-to-end through FastMCP's own tool.run(): a real dispatcher JSON result survives the
    full FunctionTool schema-validation + serialization path unchanged as structured_content."""

    def setUp(self) -> None:
        self.mcp = FastMCP(name="test-server")
        uitools.register_ui_tools(self.mcp, FAKE_TARGET_ROOT)

    def _tool(self, name: str):
        tools = {t.name: t for t in asyncio.run(self.mcp.list_tools())}
        return tools[name]

    def test_read_only_result_passes_through_tool_run(self) -> None:
        payload = {"schemaVersion": "1.0", "operation": "list_windows", "success": True, "status": "OK", "result": {"windowCount": 0, "windows": []}}
        with mock.patch.object(uitools, "run_desktop_control_operation", return_value=payload):
            result = asyncio.run(self._tool("ui_list_windows").run({"application": "notepad"}))
        self.assertEqual(result.structured_content, payload)

    def test_dispatcher_missing_surfaces_as_tool_error_through_tool_run(self) -> None:
        with mock.patch("os.path.isfile", return_value=False):
            with self.assertRaises(ToolError):
                asyncio.run(self._tool("ui_list_windows").run({}))


if __name__ == "__main__":
    unittest.main()

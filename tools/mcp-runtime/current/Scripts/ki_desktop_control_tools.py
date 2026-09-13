"""KI-Stack Desktop Control tools -- native FastMCP tool layer, KI-Stack 2.19 Phase 1.

Exposes a flat `ui_*` tool surface on the SAME FastMCP instance `mcp_launcher.py` already
starts (no second MCP server, no second port, no second runtime process). Every tool here is a
thin transport that maps exactly onto one existing Desktop Control operation and calls the
existing, productive dispatcher:

    <TargetRoot>\\tools\\desktop-control\\current\\Invoke-KIStackDesktopControl.ps1

Desktop Control's own Resolve -> Validate -> Act -> Re-observe -> Verify pipeline
(tools/desktop-control/current/DesktopControl.psm1 + DesktopControl.Policy.psm1) makes every
policy decision. This module never re-implements or duplicates any of it: it does not classify
operations, does not check window/element contracts, does not decide what is a secret. It only
(1) builds a RequestJson object from typed tool parameters, (2) invokes the dispatcher, and
(3) returns the dispatcher's own JSON result unchanged -- including a business-level failure
such as `SecretContextBlocked`, `PostconditionNotProven`, or `ResolverError`, which is valid
JSON and is passed through exactly as-is, never turned into an MCP tool error.

An MCP tool error (`fastmcp.exceptions.ToolError`) is raised ONLY for a transport-level failure:
the dispatcher script is missing (checked at exactly one fixed path -- no PATH fallback, ever),
`pwsh.exe` cannot be resolved, the process could not be started or timed out, or stdout does not
parse as a JSON object. A non-zero dispatcher exit code alone is NOT such a failure: the
dispatcher's own `Invoke-KIStackDesktopControl.ps1` (see its own tail) exits 1 for every
business-level `success:false` result too (e.g. `SecretContextBlocked`), so a valid JSON object
on stdout is always returned to the caller regardless of exit code.

Only the ten semantic, already-productive UIA operations are exposed. `scroll` / `scroll_into_view`
(backend capability unverified, fails closed inside Desktop Control itself) and any raw
send-input / send-keys / global-hotkey / coordinate-click / drag / touch / pen / raw-winapp
surface are deliberately never wired up here -- there is no tool function for them at all.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from typing import Any

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import BaseModel

# Fixed, single lookup path for the dispatcher -- relative to the MCP Runtime's own TargetRoot.
# Never a PATH search, never a second candidate location (LOCAL-CONTROL-CONTRACT-style
# fail-closed dependency: see MCP-INTEGRATION.md).
_DISPATCHER_RELATIVE_PARTS = ("tools", "desktop-control", "current", "Invoke-KIStackDesktopControl.ps1")

# Wall-clock ceiling for one dispatcher invocation. Desktop Control's own config
# (Config/desktop-control.config.json) caps window/element resolution and postcondition waits at
# 8-10s each; 45s leaves headroom for a mutating operation's Resolve+Act+Re-observe+Verify
# sequence without hanging an MCP tool call indefinitely on a wedged dispatcher.
_DISPATCHER_TIMEOUT_SECONDS = 45

# The exact, flat tool-name -> Desktop-Control-operation mapping. Single source of truth for
# both the tool registration below and its own test suite (test_ki_desktop_control_tools.py) --
# asserting against this dict is how "no namespace/prefix drift" is verified mechanically rather
# than by hand-reading ten function definitions.
UI_TOOL_TO_OPERATION: dict[str, str] = {
    "ui_list_windows": "list_windows",
    "ui_inspect_window": "inspect_window",
    "ui_find_element": "find_element",
    "ui_get_properties": "get_properties",
    "ui_get_value": "get_value",
    "ui_screenshot": "screenshot",
    "ui_wait_for": "wait_for",
    "ui_set_value": "set_value",
    "ui_invoke": "invoke",
    "ui_focus": "focus",
}


class UiElementIdentity(BaseModel):
    """Identity of one UI Automation element, re-matched fresh on every call.

    A bare `selector` alone is a transport detail, never durable identity -- Desktop Control's
    own Target Contract (DesktopControl.Policy.psm1) rejects a stale selector-only identity on a
    mutating operation. Prefer `automationId` / `name` / `controlType` / `className`.
    """

    automationId: str | None = None
    name: str | None = None
    controlType: str | None = None
    className: str | None = None
    selector: str | None = None


def _compact(values: dict[str, Any]) -> dict[str, Any]:
    """Drops None entries so RequestJson only carries fields the caller actually supplied."""
    return {key: value for key, value in values.items() if value is not None}


def _resolve_pwsh() -> str:
    """Resolves pwsh.exe: managed PowerShell-7 install path first, PATH as the last resort.

    (This is a generic PowerShell-7 host lookup, not the Desktop-Control-dispatcher lookup --
    that one below is intentionally never allowed a PATH fallback.)
    """
    program_files = os.environ.get("ProgramFiles", r"C:\Program Files")
    candidate = os.path.join(program_files, "PowerShell", "7", "pwsh.exe")
    if os.path.isfile(candidate):
        return candidate
    found = shutil.which("pwsh.exe") or shutil.which("pwsh")
    if found:
        return found
    raise ToolError(
        "PowerShell 7 (pwsh.exe) wurde nicht gefunden -- Desktop Control kann nicht aufgerufen werden."
    )


def resolve_dispatcher_path(target_root: str) -> str:
    """The one, fixed Desktop Control dispatcher path under TargetRoot. No PATH fallback."""
    return os.path.join(target_root, *_DISPATCHER_RELATIVE_PARTS)


def run_desktop_control_operation(
    operation: str, request: dict[str, Any], target_root: str
) -> dict[str, Any]:
    """Invokes Invoke-KIStackDesktopControl.ps1 and returns its JSON result verbatim.

    Raises `fastmcp.exceptions.ToolError` only for a transport-level failure (dispatcher
    missing, pwsh missing, process could not run, stdout not valid JSON). See the module
    docstring for why a non-zero exit code alone is not such a failure.
    """
    dispatcher = resolve_dispatcher_path(target_root)
    if not os.path.isfile(dispatcher):
        raise ToolError(
            f"Desktop Control Dispatcher nicht gefunden unter '{dispatcher}'. Kein PATH-Fallback -- "
            "Desktop Control muss unter <TargetRoot>\\tools\\desktop-control\\current installiert und "
            "compliant sein (siehe Invoke-KIStackDesktopControl.ps1 -Action Validate)."
        )
    pwsh = _resolve_pwsh()
    request_json = json.dumps(request or {})
    arguments = [
        pwsh,
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        dispatcher,
        "-Operation",
        operation,
        "-RequestJson",
        request_json,
        "-TargetRoot",
        target_root,
    ]
    try:
        completed = subprocess.run(
            arguments,
            capture_output=True,
            text=True,
            timeout=_DISPATCHER_TIMEOUT_SECONDS,
            encoding="utf-8",
            errors="replace",
        )
    except subprocess.TimeoutExpired as exc:
        raise ToolError(
            f"Desktop Control Dispatcher hat innerhalb von {_DISPATCHER_TIMEOUT_SECONDS}s nicht "
            f"geantwortet (Operation '{operation}')."
        ) from exc
    except OSError as exc:
        raise ToolError(f"Desktop Control Dispatcher konnte nicht gestartet werden: {exc}") from exc

    stdout = (completed.stdout or "").strip()
    if not stdout:
        stderr_excerpt = (completed.stderr or "").strip()[:2000]
        raise ToolError(
            f"Desktop Control Dispatcher lieferte keine Ausgabe (exitCode={completed.returncode}, "
            f"Operation '{operation}'). stderr: {stderr_excerpt}"
        )
    try:
        result = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise ToolError(
            f"Desktop Control Dispatcher lieferte kein gueltiges JSON (exitCode={completed.returncode}, "
            f"Operation '{operation}'): {exc}. stdout (gekuerzt): {stdout[:2000]}"
        ) from exc
    if not isinstance(result, dict):
        raise ToolError(
            f"Desktop Control Dispatcher lieferte kein JSON-Objekt (exitCode={completed.returncode}, "
            f"Operation '{operation}'). stdout (gekuerzt): {stdout[:2000]}"
        )
    return result


def register_ui_tools(mcp: FastMCP, target_root: str) -> None:
    """Registers the flat ui_* tool surface on the given (already-running) FastMCP instance.

    Adds ten native FastMCP tools alongside whatever providers/tools the caller already
    registered (in practice, mcp_launcher.py's Open-Terminal OpenAPIProvider) -- it never
    replaces or wraps them.
    """

    def _call(operation: str, **fields: Any) -> dict[str, Any]:
        return run_desktop_control_operation(operation, _compact(fields), target_root)

    def _element_payload(element: UiElementIdentity | None) -> dict[str, Any] | None:
        return element.model_dump(exclude_none=True) if element is not None else None

    @mcp.tool
    def ui_list_windows(application: str | None = None) -> dict[str, Any]:
        """List top-level windows, optionally filtered by application/process name. Read-only."""
        return _call("list_windows", application=application)

    @mcp.tool
    def ui_inspect_window(
        application: str | None = None,
        hwnd: str | None = None,
        titlePattern: str | None = None,
        expectedProcessName: str | None = None,
    ) -> dict[str, Any]:
        """Resolve exactly one window (fresh, never cached) and return its UI Automation element tree. Read-only."""
        return _call(
            "inspect_window",
            application=application,
            hwnd=hwnd,
            titlePattern=titlePattern,
            expectedProcessName=expectedProcessName,
        )

    @mcp.tool
    def ui_find_element(
        application: str | None = None,
        hwnd: str | None = None,
        titlePattern: str | None = None,
        expectedProcessName: str | None = None,
        element: UiElementIdentity | None = None,
    ) -> dict[str, Any]:
        """Find all elements in one window's current tree matching the given identity. Read-only."""
        return _call(
            "find_element",
            application=application,
            hwnd=hwnd,
            titlePattern=titlePattern,
            expectedProcessName=expectedProcessName,
            element=_element_payload(element),
        )

    @mcp.tool
    def ui_get_properties(
        application: str | None = None,
        hwnd: str | None = None,
        titlePattern: str | None = None,
        expectedProcessName: str | None = None,
        element: UiElementIdentity | None = None,
    ) -> dict[str, Any]:
        """Read the current UI Automation properties of exactly one, unambiguously identified element. Read-only."""
        return _call(
            "get_properties",
            application=application,
            hwnd=hwnd,
            titlePattern=titlePattern,
            expectedProcessName=expectedProcessName,
            element=_element_payload(element),
        )

    @mcp.tool
    def ui_get_value(
        application: str | None = None,
        hwnd: str | None = None,
        titlePattern: str | None = None,
        expectedProcessName: str | None = None,
        element: UiElementIdentity | None = None,
    ) -> dict[str, Any]:
        """Read one element's current value. Read-only. Blocked by the secret/credential guard for a secret-context element."""
        return _call(
            "get_value",
            application=application,
            hwnd=hwnd,
            titlePattern=titlePattern,
            expectedProcessName=expectedProcessName,
            element=_element_payload(element),
        )

    @mcp.tool
    def ui_screenshot(
        application: str | None = None,
        hwnd: str | None = None,
        titlePattern: str | None = None,
        expectedProcessName: str | None = None,
    ) -> dict[str, Any]:
        """Capture a screenshot of exactly one, unambiguously resolved window as evidence. Read-only."""
        return _call(
            "screenshot",
            application=application,
            hwnd=hwnd,
            titlePattern=titlePattern,
            expectedProcessName=expectedProcessName,
        )

    @mcp.tool
    def ui_wait_for(
        element: UiElementIdentity,
        application: str | None = None,
        hwnd: str | None = None,
        titlePattern: str | None = None,
        expectedProcessName: str | None = None,
        timeoutMs: int | None = None,
    ) -> dict[str, Any]:
        """Poll a fresh UI Automation tree until an element identity appears. Read-only."""
        return _call(
            "wait_for",
            application=application,
            hwnd=hwnd,
            titlePattern=titlePattern,
            expectedProcessName=expectedProcessName,
            element=_element_payload(element),
            timeoutMs=timeoutMs,
        )

    @mcp.tool
    def ui_set_value(
        element: UiElementIdentity,
        value: str,
        application: str | None = None,
        hwnd: str | None = None,
        titlePattern: str | None = None,
        expectedProcessName: str | None = None,
    ) -> dict[str, Any]:
        """Set one element's value; succeeds only once independently verified by readback. Mutating."""
        return _call(
            "set_value",
            application=application,
            hwnd=hwnd,
            titlePattern=titlePattern,
            expectedProcessName=expectedProcessName,
            element=_element_payload(element),
            value=value,
        )

    @mcp.tool
    def ui_invoke(
        element: UiElementIdentity,
        application: str | None = None,
        hwnd: str | None = None,
        titlePattern: str | None = None,
        expectedProcessName: str | None = None,
        expectTreeChange: str | None = None,
    ) -> dict[str, Any]:
        """Invoke (click-equivalent) one element; succeeds only once an independently observable tree change is proven. Mutating."""
        return _call(
            "invoke",
            application=application,
            hwnd=hwnd,
            titlePattern=titlePattern,
            expectedProcessName=expectedProcessName,
            element=_element_payload(element),
            expectTreeChange=expectTreeChange,
        )

    @mcp.tool
    def ui_focus(
        element: UiElementIdentity,
        application: str | None = None,
        hwnd: str | None = None,
        titlePattern: str | None = None,
        expectedProcessName: str | None = None,
    ) -> dict[str, Any]:
        """Focus one element; succeeds only once independently confirmed via get-focused. Mutating."""
        return _call(
            "focus",
            application=application,
            hwnd=hwnd,
            titlePattern=titlePattern,
            expectedProcessName=expectedProcessName,
            element=_element_payload(element),
        )

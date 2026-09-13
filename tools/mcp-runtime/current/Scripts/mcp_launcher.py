"""KI-Stack MCP Runtime launcher.

Starts Open Terminal's FastAPI app as a native MCP server (streamable-http),
with a correctly auth-configured internal bridge client, and (2.19 Phase 1)
KI-Stack's own flat `ui_*` Desktop Control tool surface on the SAME FastMCP
instance -- same process, same port, no second MCP server.

Why this file exists (Phase 0 finding, docs/proposals/2.15-mcp-foundation.md):
`open-terminal mcp` alone (FastMCP.from_fastapi(app=app)) builds its internal
ASGI bridge client with NO headers. Open Terminal's own FastAPI routes require
`Authorization: Bearer <OPEN_TERMINAL_API_KEY>` (HTTPBearer dependency), so
every real tool call fails with 401 even though the outer MCP session (the
caller's own connection) authenticates fine. This is a FastMCP/open-terminal
integration gap, not something KI-Stack owns or forks -- fixed here purely by
supplying the missing, already-documented `httpx_client_kwargs`-equivalent
configuration via FastMCP's own public OpenAPIProvider(client=...) API
(see its own docstring), which `open_terminal.mcp_server` simply never does.

This is a STARTUP-TIME configuration wrapper, not a tool-execution or proxy
layer: it does not intercept, inspect, or transform any tool call. Open WebUI
still talks directly to this MCP server as an ordinary native MCP client. The
`ui_*` tools added below are plain native FastMCP tools registered on the same
`mcp_server` object via its own public `@mcp_server.tool` decorator (the exact
mechanism `fastmcp.server.server.FastMCP` documents for adding local tools to
an existing server) -- not a second provider, not a second bridge client, and
not a proxy in front of Open Terminal's OpenAPIProvider tools.

Usage: python mcp_launcher.py <host> <port> <cwd> <target_root>
The API key is read exclusively from the OPEN_TERMINAL_API_KEY environment
variable (never a command-line argument, so it never appears in a process
command-line listing), and is never written to disk by this script.
`target_root` is this MCP Runtime's own TargetRoot (see
McpRuntime.psm1's Get-KIMcpRuntimePaths) -- Desktop Control's dispatcher is
looked up at exactly `<target_root>\\tools\\desktop-control\\current\\
Invoke-KIStackDesktopControl.ps1`, never via PATH.
"""
import os
import sys

host, port, cwd, target_root = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
api_key = os.environ["OPEN_TERMINAL_API_KEY"]

os.chdir(cwd)

import httpx2  # fastmcp>=4.0.3's OpenAPIProvider expects a real httpx2.AsyncClient -- passing a
# plain httpx.AsyncClient still works but raises FastMCPDeprecationWarning ("will be removed in a
# future release"). httpx2 is a genuine, separate PyPI package (not an alias for httpx) already
# resolved transitively by this launcher's own `open-terminal[mcp]==0.11.34` pin (it is fastmcp's
# own dependency) -- verified 2026-09-13, `python -c "import httpx2; print(httpx2.__version__)"`
# under that exact packageSpec resolves httpx2==2.12.0, with the same AsyncClient/ASGITransport
# surface this launcher already uses. No new dependency, no packageSpec change needed.
from fastmcp import FastMCP
from fastmcp.server.providers.openapi import OpenAPIProvider

from open_terminal.main import app  # import after cwd/env are set, matching the `open-terminal mcp` CLI's own order

from ki_desktop_control_tools import register_ui_tools  # sibling module in this same Scripts/ dir

client = httpx2.AsyncClient(
    transport=httpx2.ASGITransport(app=app),
    base_url="http://fastapi",
    headers={"Authorization": f"Bearer {api_key}"},
)

provider = OpenAPIProvider(openapi_spec=app.openapi(), client=client)
mcp_server = FastMCP(name="KI-Stack MCP Runtime (Open Terminal)", providers=[provider])
register_ui_tools(mcp_server, target_root)

mcp_server.run(transport="streamable-http", host=host, port=port)

"""KI-Stack MCP Runtime launcher.

Starts Open Terminal's FastAPI app as a native MCP server (streamable-http),
with a correctly auth-configured internal bridge client.

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
still talks directly to this MCP server as an ordinary native MCP client.

Usage: python mcp_launcher.py <host> <port> <cwd>
The API key is read exclusively from the OPEN_TERMINAL_API_KEY environment
variable (never a command-line argument, so it never appears in a process
command-line listing), and is never written to disk by this script.
"""
import os
import sys

host, port, cwd = sys.argv[1], int(sys.argv[2]), sys.argv[3]
api_key = os.environ["OPEN_TERMINAL_API_KEY"]

os.chdir(cwd)

import httpx as httpx2  # fastmcp's OpenAPIProvider expects an httpx2-compatible client
from fastmcp import FastMCP
from fastmcp.server.providers.openapi import OpenAPIProvider

from open_terminal.main import app  # import after cwd/env are set, matching the `open-terminal mcp` CLI's own order

client = httpx2.AsyncClient(
    transport=httpx2.ASGITransport(app=app),
    base_url="http://fastapi",
    headers={"Authorization": f"Bearer {api_key}"},
)

provider = OpenAPIProvider(openapi_spec=app.openapi(), client=client)
mcp_server = FastMCP(name="KI-Stack MCP Runtime (Open Terminal)", providers=[provider])

mcp_server.run(transport="streamable-http", host=host, port=port)

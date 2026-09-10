# Desktop Control -> MCP Runtime integration (deferred)

**Status: design note only. Not implemented in KI-Stack 2.18 Phase "Desktop Control wrapper".**

## Why it is deferred

The existing MCP Runtime (`tools/mcp-runtime/current/`) does not host a KI-Stack-owned tool
registry or dispatcher. `Scripts/mcp_launcher.py` starts **Open Terminal's own FastAPI app**
unchanged and exposes it through FastMCP's `OpenAPIProvider`. Its "12 tools" are Open Terminal's
OpenAPI operations; no KI-Stack code is on the tool-call path at runtime (README.md, "Architektur-
regel"). `LOCAL-CONTROL-CONTRACT.md` §18 lists a *new MCP tool / new runtime / new port / new
component* as explicitly out of scope for that contract.

Adding a `desktop_control` MCP tool therefore requires one of:

1. a second FastMCP provider inside `mcp_launcher.py` backed by a small KI-Stack-owned FastAPI
   sub-app that shells out to `Invoke-KIStackDesktopControl.ps1 -Operation ...`; or
2. a standalone OpenAPI shim (its own tiny FastAPI app on loopback) registered as an additional
   `tool_server.connections` entry alongside `ki-stack-mcp-runtime`.

Both change the MCP Runtime component or add a component/endpoint. Per the task's own guidance
("Wenn eine direkte MCP-Tool-Erweiterung in dieser Phase architektonisch unsauber wäre: erst
Wrapper/Dispatcher + Tests bauen und Integration separat dokumentieren. Nicht erzwingen."), the
wrapper + policy + tests ship first (this component); the MCP wiring is a separate, later step.

## Contract the integration must honour

- **No new MCP server, port, or credential.** The runtime stays `server:mcp:ki-stack-mcp-runtime`
  on its existing port. Option 1 adds no port; option 2 would add a loopback port and is the
  less preferred path for exactly that reason.
- **Exactly one tool**, `desktop_control`, taking `{ operation, ... }` and returning the wrapper's
  JSON result contract verbatim. No `raw_winapp`, no `send_input`, no coordinate-click tool.
- The tool implementation is a thin transport that calls
  `Invoke-KIStackDesktopControl.ps1 -Operation <op> -RequestJson <json> -TargetRoot <root>` and
  returns its stdout JSON. All Resolve/Validate/Act/Re-observe/Verify and policy enforcement stay
  inside this component; the MCP layer adds nothing but transport.
- Audit records continue to be written by this component under
  `<TargetRoot>\state\desktop-control\logs\actions\<date>.jsonl`.

## Open decision

Whether the desktop-control tool is exposed only to a dedicated capability/profile (so ordinary
`ki-stack-mcp-runtime`-bound profiles do not gain GUI control implicitly) is left to the MCP
integration step, alongside the profile-wiring question already tracked in
`LOCAL-CONTROL-CONTRACT.md` §21.

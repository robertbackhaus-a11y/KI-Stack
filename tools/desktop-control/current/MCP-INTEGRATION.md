# Desktop Control -> MCP Runtime integration

**Status: implemented, KI-Stack 2.19 Phase 1.**

## History: why this was deferred through 2.18

Through 2.18, the existing MCP Runtime (`tools/mcp-runtime/current/`) hosted no KI-Stack-owned
tool registry or dispatcher. `Scripts/mcp_launcher.py` started **Open Terminal's own FastAPI
app** unchanged and exposed it through FastMCP's `OpenAPIProvider`. Its tools were Open
Terminal's OpenAPI operations only; no KI-Stack code was on the tool-call path at runtime
(README.md, "Architekturregel"). `LOCAL-CONTROL-CONTRACT.md` §18 lists a *new MCP tool / new
runtime / new port / new component* as explicitly out of scope for that contract, and the 2.18
Desktop Control wrapper shipped as a standalone, policy-complete component with the MCP wiring
left for a later step (see the "Open decision" note this section used to carry, and the
originally-considered two options below -- both were rejected).

2.19 Phase 1 resolves that open decision **without** either originally-considered option:

1. ~~a second FastMCP provider inside `mcp_launcher.py` backed by a small KI-Stack-owned FastAPI
   sub-app~~ -- rejected: a second provider/sub-app is unnecessary machinery when FastMCP's own
   `FastMCP.tool` decorator can register native Python tools directly on the same instance.
2. ~~a standalone OpenAPI shim on its own loopback port, registered as a second
   `tool_server.connections` entry~~ -- rejected: it would have added a second port, which
   `LOCAL-CONTROL-CONTRACT.md` §18 and this component's own README both rule out.

## What actually shipped in 2.19 Phase 1

`Scripts/mcp_launcher.py` still builds the exact same single `FastMCP` instance it always has
(Open Terminal's `OpenAPIProvider`, unchanged, same auth-bridge fix as before) -- and, on that
**same instance**, additionally calls `register_ui_tools(mcp_server, target_root)` from the new
sibling module `Scripts/ki_desktop_control_tools.py`. `register_ui_tools` uses FastMCP's own
public `@mcp.tool` decorator (`fastmcp.server.server.FastMCP.tool` / `.add_tool`) -- the same
mechanism used for any local FastMCP tool, not a provider, not a bridge client, not a proxy. No
second MCP server, no second port (still exactly `127.0.0.1:8021`, `server:mcp:ki-stack-mcp-
runtime`), no second credential, no second runtime process.

**Ten flat tools, not one `desktop_control(operation, ...)` tool** -- this is the one point where
2.19 deliberately diverges from what this document originally proposed. Each tool has a concrete,
typed schema for exactly one Desktop Control operation instead of a generic `operation` string
plus a loose parameter bag:

| Tool | Desktop Control operation | Class |
|---|---|---|
| `ui_list_windows` | `list_windows` | read-only |
| `ui_inspect_window` | `inspect_window` | read-only |
| `ui_find_element` | `find_element` | read-only |
| `ui_get_properties` | `get_properties` | read-only |
| `ui_get_value` | `get_value` | read-only |
| `ui_screenshot` | `screenshot` | read-only |
| `ui_wait_for` | `wait_for` | read-only |
| `ui_set_value` | `set_value` | mutating |
| `ui_invoke` | `invoke` | mutating |
| `ui_focus` | `focus` | mutating |

`scroll_into_view` / `scroll` (backend capability unverified, fails closed inside Desktop Control
itself) and the entire never-exposed surface (`send_input`, `send_keys`, `global_hotkey`,
`mouse_click_coordinate`, `drag`, `touch`, `pen`, `raw_winapp`, ...) have **no** corresponding
tool at all -- not merely policy-blocked, structurally absent from `ki_desktop_control_tools.py`.

## Contract the integration honours

- **No new MCP server, port, or credential.** The runtime stays `server:mcp:ki-stack-mcp-runtime`
  on its existing port (`127.0.0.1:8021`).
- Every `ui_*` tool is a thin transport that serializes its typed parameters to a Desktop Control
  `RequestJson` object and calls
  `Invoke-KIStackDesktopControl.ps1 -Operation <op> -RequestJson <json> -TargetRoot <root>`
  (`ki_desktop_control_tools.run_desktop_control_operation`). All
  Resolve -> Validate -> Act -> Re-observe -> Verify and policy enforcement stay inside Desktop
  Control; the MCP layer adds nothing but transport and never re-classifies an operation, never
  re-checks a window/element contract, never re-decides a secret context.
- The dispatcher is looked up at exactly one fixed path,
  `<TargetRoot>\tools\desktop-control\current\Invoke-KIStackDesktopControl.ps1`, derived from the
  MCP Runtime's own `TargetRoot` (now passed to `mcp_launcher.py` as its 4th argument by
  `McpRuntime.psm1`'s `Get-KIMcpRuntimeStartArguments`) -- **never** a `PATH` search, never a
  second candidate location. If it is missing, every `ui_*` call fails closed with a structured
  MCP tool error (`fastmcp.exceptions.ToolError`); it is never silently skipped or resolved from
  somewhere else.
- A **business-level** Desktop Control result -- including `success:false` statuses such as
  `SecretContextBlocked`, `PostconditionNotProven`, `WindowNotFound`, or `ResolverError` -- is
  valid JSON on the dispatcher's stdout and is returned to the MCP caller **unchanged**, exactly
  like a `success:true` result. `Invoke-KIStackDesktopControl.ps1` itself exits `1` for every
  `success:false` result (see its own tail), so the MCP layer treats a non-zero exit code as a
  transport failure **only** when it is *also* not accompanied by parseable JSON on stdout (a
  real crash) -- never on its own. Only a missing dispatcher, an unresolvable `pwsh.exe`, a
  process that could not start or timed out, or stdout that does not parse as a JSON object
  raises an MCP tool error.
- Audit records continue to be written by Desktop Control itself, unchanged, under
  `<TargetRoot>\state\desktop-control\logs\actions\<date>.jsonl` -- the MCP layer does not
  duplicate or bypass that audit trail.

## Files

- `tools/mcp-runtime/current/Scripts/ki_desktop_control_tools.py` -- the ten `ui_*` tool
  definitions, the transport function, and the fixed dispatcher-path resolution.
- `tools/mcp-runtime/current/Scripts/mcp_launcher.py` -- registers them on the existing FastMCP
  instance via `register_ui_tools`.
- `tools/mcp-runtime/current/Scripts/test_ki_desktop_control_tools.py` -- unit tests (mocked
  dispatcher process; no GUI, no real `winapp`, no real PowerShell dispatcher execution).
- `tools/mcp-runtime/current/McpRuntime.psm1` -- `Get-KIMcpRuntimeStartArguments` now also passes
  `TargetRoot`; `Test-KIMcpRuntimeHealthy` additionally verifies, from the same `list_tools`
  round-trip, that Open Terminal's baseline tools are still present, all ten `ui_*` tools are
  present, and no never-exposed UI tool name is.

## Dependency verification: fastmcp version actually resolved

`Config/mcp-runtime.config.json`'s `packageSpec` (`open-terminal[mcp]==0.11.34`) pins Open
Terminal's own version, not fastmcp's -- fastmcp is a *transitive* dependency, resolved by `uv`
at launcher-start time. Verified reproducibly (2026-09-13), not merely inferred from a locally
cached wheel:

```
uv run --with "open-terminal[mcp]==0.11.34" python -c "import fastmcp; print(fastmcp.__version__)"
# -> 4.0.3
```

`fastmcp==4.0.3`'s `OpenAPIProvider` (`fastmcp/server/providers/openapi/provider.py`) now detects
a plain `httpx.AsyncClient` (by walking the client's class MRO for a top-level `httpx` module) and
raises `FastMCPDeprecationWarning` — still accepted, but "will be removed in a future release" —
recommending a real `httpx2.AsyncClient` instead. `httpx2` is a genuine, separate PyPI package
(not an alias for `httpx`), already resolved transitively by this same `packageSpec` (it is
fastmcp's own dependency: verified `httpx2.__version__ == '2.12.0'` under the identical `uv run`
invocation above, with the same `AsyncClient`/`ASGITransport` surface `mcp_launcher.py` already
used). Fixed in the same branch, no architecture change and no new dependency: `mcp_launcher.py`
now does a real `import httpx2` instead of `import httpx as httpx2`. Re-verified with
`warnings.catch_warnings(record=True)` around the exact construction `mcp_launcher.py` performs
(`OpenAPIProvider(client=httpx2.AsyncClient(...))`, real `open_terminal.main.app`,
`register_ui_tools` included) under the real resolved environment: zero `FastMCPDeprecationWarning`
instances, 22 tools still constructed correctly.

Re-verify this exact command after any future `packageSpec` version bump -- a pinned Open Terminal
version can still resolve a different transitive fastmcp/httpx2 version over time.

## Still open: profile / capability exposure

The 2.18 "open decision" about whether Desktop Control should be gated behind a dedicated
capability/profile is **not resolved by this phase**. As shipped, the `ui_*` tools are ordinary
native FastMCP tools on the same `server:mcp:ki-stack-mcp-runtime` connection every existing
profile already binds to (`LOCAL-CONTROL-CONTRACT.md` §2) -- so, structurally, every profile that
already has local control also gains GUI/UIA control the same way, with no separate profile-gating
mechanism added. Whether that is the *intended* exposure, or whether a later phase should restrict
`ui_*` to a subset of profiles, is a product decision this phase deliberately leaves for the user
to make explicitly -- it is called out again in the Phase-1 report's open points. The related,
still-open question in `LOCAL-CONTROL-CONTRACT.md` §21 about *where* per-profile agent guidance
should live is unaffected either way.

# KI-Stack Desktop Control

Productive policy / wrapper layer over `winapp ui` (Windows UI Automation) for KI-Stack 2.18.
Realizes the GUI/UIA control boundary that `LOCAL-CONTROL-CONTRACT.md` §18 defers to 2.18, and
follows the "Architecture recommendation" of the desktop-control spike
(`scripts/Test-KIStackDesktopControlSpike.ps1`).

```
Open WebUI / Agent
  -> existing MCP Runtime  (unchanged, server:mcp:ki-stack-mcp-runtime)
  -> Desktop Control Wrapper
      -> Policy / Validation           (DesktopControl.Policy.psm1)
      -> central WinApp Resolver       (Vendor/WinApp.Resolver.psm1 == tools/winapp/current/WinApp.Resolver.psm1)
      -> winapp ui                     (semantic UIA verbs only)
      -> Windows UI Automation
```

Every request runs **Resolve -> Validate -> Act -> Re-observe -> Verify**. The LLM never runs
`winapp` directly. Introduces **no runtime, no port, no credential**.

## Operations

`Invoke-KIStackDesktopControl.ps1 -Operation <op> -RequestJson '{...}' [-TargetRoot ...] [-KIStackRoot ...]`

| Class | Operations |
|---|---|
| read-only | `list_windows`, `inspect_window`, `find_element`, `get_properties`, `get_value`, `screenshot`, `wait_for` |
| mutating (semantic UIA) | `set_value`, `invoke`, `focus` |
| deferred (backend capability unverified, fails closed) | `scroll_into_view`, `scroll` |
| **not exposed at all** | send-input / send-keys, global keyboard injection, system hotkeys, mouse coordinate click, arbitrary drag/touch/pen, raw `winapp` command execution |

Lifecycle self-check: `-Action Audit|Validate|Status` (static; `-SkipResolverProbe` to skip the
live central-resolver check).

Request object: `{ application, hwnd, titlePattern, expectedProcessName,
element: { automationId, name, controlType, className, selector }, value, timeoutMs, expectTreeChange }`.

## Result contract

One JSON object per operation: `schemaVersion, timestampUtc, operation, mode, success, status,
resolver, target, policy, action, postcondition, evidence, audit, blockedReason`.

- `success = true` only when: the central resolver succeeded **and** the Target Contract held
  **and** (read-only: the observation was parseable) / (mutating: an **independent postcondition**
  was proven). A `winapp` CLI `exitCode` of `0` is **never** on its own an `success`.
- Blocking statuses: `OperationNotPermitted`, `RawArgumentsRejected`, `ResolverError`,
  `WindowNotFound`, `WindowAmbiguous`, `WindowContractFailed`, `WindowNotInteractable`,
  `ElementNotFound`, `ElementAmbiguous`, `ElementContractFailed`, `SecretContextBlocked`,
  `PostconditionNotProven`, `BackendCapabilityUnverified`, `WinAppError`, `Timeout`.

## Target Contract (`Config/desktop-control.policy.json`)

Before any action:

- **Window** — resolved fresh now (never a cached snapshot), exactly one HWND, process identity
  re-checked against a live process, title context checked.
- **Element** — re-resolved in the freshly re-inspected tree, `ControlType` present,
  `IsEnabled != false`, `IsOffscreen != true`, the caller's `automationId`/`name`/`className`/
  `controlType` still hold, unambiguous. A bare generated `winapp` selector is a transport
  detail only — never accepted as the sole durable identity.
- **Window state** — a minimized window is **not** auto-restored in this first step; mutation
  fails closed as `WindowNotInteractable`. Background observation stays allowed.

## Secret / credential guard

`IsPassword` is never the sole guard (the spike observed the Explorer address bar reporting
`IsPassword=true` falsely). The guard is composite: `IsPassword` **or** any name / automationId /
className / process-name signal. A secret element blocks **both `get_value` and `set_value`**.
False-positive exceptions are narrow and explicit (process + control type + class + non-secret
name), never a bare name allowlist like `Address` / `Breadcrumb`, and only apply when
`IsPassword` was the *only* signal. Every decision (including an applied exception, by id) is
written to the audit record.

## Audit

Append-only JSONL, one record per operation, under
`<TargetRoot>\state\desktop-control\logs\actions\<yyyy-MM-dd>.jsonl` — the same jsonl-under-state
audit shape `LOCAL-CONTROL-CONTRACT.md` §17 uses for `run_command`. Fields: timestamp, operation,
target HWND, process, window title, element identity, policy result, action result, postcondition
result, `winapp` exitCode, evidence path, blocked reason. Screenshots (evidence) go to
`<TargetRoot>\state\desktop-control\evidence\`.

## MCP integration

Deferred — see `MCP-INTEGRATION.md`. The existing MCP Runtime hosts Open Terminal's OpenAPI app
unchanged and has no KI-Stack-owned tool registry; adding a `desktop_control` tool changes that
component or adds an endpoint, so the wrapper + policy + tests ship first and the wiring is a
separate step. No new MCP server, port, or credential when it lands.

## Tests

`Test-KIStackDesktopControl.ps1` — 20 contract/unit blocks, no GUI, no application launch, no
global input: every `winapp ui` call is served by an in-process fake, the live `--version` probe
is injected, and the real central resolver is exercised against fake / hostile trees.

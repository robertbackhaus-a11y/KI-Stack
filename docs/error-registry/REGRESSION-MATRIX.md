# Regression registry

Every new package must retain automated coverage for all entries below.

| Introduced/fixed | Defect | Required permanent regression |
|---|---|---|
| v1.0.6 | Runtime state used `requiredCommand` while persisted state could contain `command` | Round-trip accepts both names |
| v1.0.7 | winget exit code overruled an already-correct runtime state | Revalidated end state is authoritative |
| v1.0.8 | Git version `2.55.0.windows.3` compared incorrectly | Numeric version normalization |
| v1.0.9 | `$Matches` automatic variable collision | Protected-variable and naming test |
| v1.1.1 | CMD starter could not resolve nested Preflight path | Recursive search over both download roots, newest by UTC modification time |
| v1.1.1 | Partial PythonGit rollback state was unavailable | Transaction-bound rollback journal |
| v1.1.2 | Early starter failures could close the window silently | Persistent CMD session and TEMP/package logs |
| v1.1.3 | Execute required manual administrator start | Automatic UAC elevation plus second security gate |
| v1.1.4 | AST test rejected legitimate `$null = ...` discard assignments | `$null` allowed only as discard target |
| v1.1.5 | DryRun self-test used an incomplete configuration fixture | All module DryRun tests consume full release configuration |

| GitHub Initial v0.1.1 | StrictMode validator accessed `$failed.name` when the failure list was empty | Explicit `ForEach-Object` name enumeration, result-schema validation and empty-list regression check |

A correction is incomplete until its regression test executes before final self-test aggregation.

| v1.2.1 | ComfyUI pinned-release test interpolated `$Context` instead of checking literal source | Literal-safe source and executable Git argument validation |


## MW-013 — Integration endpoint count coupled to module count

- **Observed:** Models/Workflows v1.3.2 SelfTest failed after the fifth module was enabled.
- **Cause:** `Integration Dry-Run` expected five endpoints although the integration contract contains four endpoints.
- **Permanent test:** expected count is derived from `searxngUrl`, `openWebUIUrl`, `lmStudioUrl` and `comfyUIUrl`; `Count -eq 5` is rejected at build time.
- **Fixed in:** v1.3.3.

| MW-1.3.4-01 | External Preflight ZIP missing after validated predecessor stages | Embedded continuation Preflight is present and passes real kernel input validation | v1.3.4 |

| MW-135-01 | CMD UTF-8 BOM executed as command | All CMD files must be UTF-8 without BOM and CRLF | v1.3.5 |
| MW-135-02 | Trailing comma in PowerShell required-path array | Native parser gate before module import | v1.3.5 |
| MW-135-03 | Double-nested and space-containing package path | Dedicated path-resolution gate | v1.3.5 |

| MW-136-01 | `$input` overwritten by model HTTP download stream | AST collision test plus dedicated stream-variable regression | v1.3.6 |
| MW-136-02 | Manifest self-test expected obsolete schema 1.0 / three entries | Validate schema 1.1, 3 managed required models and 5 local placeholders | v1.3.6 |

| GH-027-01 | Known-failed snapshot v1.3.4 was revalidated with the PowerShell parser | Snapshot classes are disjoint; failed intermediates are resume-only and never execute repository release validation | v1.3.7 / GitHub v0.2.7 |

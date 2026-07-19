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

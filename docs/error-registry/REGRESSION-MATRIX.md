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

| APP-140-01 | Application installer could overwrite pre-existing state or trust package-manager exit codes | Explicit transaction ownership, backup journal and end-state validation | v1.4.0 |
| APP-140-02 | Floating Open WebUI installation could change behavior between runs | Exact pin `open-webui==0.10.2` and version validation | v1.4.0 |

| APP-141-01 | StrictMode aborts while reading missing uninstall registry properties | Property-existence helper and regression test | v1.4.1 |
| APP-141-02 | Kernel exit 30 hides the actual module error | Console failure summary and `failure-summary.json` | v1.4.1 |
| APP-141-03 | WindowsApps/PATH Python alias can be selected without version validation | Executable candidate validation for Python 3.11/3.12 | v1.4.1 |


## Applications v1.4.2 regressions

- Dry-Run module fixtures must provide every context property used by the module, including `Transaction` and `TransactionDirectory`.
- Reference-release tests must derive from the active package version and release ID; stale predecessor literals are forbidden.
- Source-contract tests must use actual implementation identifiers (`$candidatePaths`) rather than invented names.
- Embedded GitHub bundle filename, extraction working root, extracted bundle root and path-resolution tests must use the same bundle version.

## Applications v1.4.3 regressions

- Active Config, Release, Core, module manifest, starter, README and SelfTest must share one version.
- Python resolver regression must validate the escaped WindowsApps regex literal used by the module.
- Historical 1.4.1 and 1.4.2 snapshots are resume-only.

## Applications v1.4.4 regressions

- Active Config, Release, Core, module manifest, starter, README and SelfTest must share one version.
- Python resolver regression must validate the escaped WindowsApps regex literal used by the module.
- Historical 1.4.1 and 1.4.2 snapshots are resume-only.

| GH-038 | Historical resume snapshots rebundled and rehashed | Bundle contains only target snapshot; previous stages recognized by Git tree hash | v0.3.8 |
| GH-039 | Validation failure reported as successful by outer starter | PowerShell and CMD exit codes are propagated end-to-end | v0.3.8 |

| GH-AUTHOR-001 | Temporary clone lacks Git author identity | Publisher sets and validates repository-local `user.name` and `user.email` before commit/tag; global config remains untouched | v1.4.9 |
## APP-GH-STRICTMODE-001 — Publisher variables expanded in bundle validator

- **Fixed in:** Applications v1.4.10 / GitHub Update v0.3.10
- **Regression:** `Test-Bundle.ps1` must not use expandable `.Contains("...")` strings containing `$GitAuthorName`, `$GitAuthorEmail`, or `$workPath`.
- **Expected:** Bundle validation succeeds before the publisher runs, and identity remains repository-local.

## INT-WSL-SEARXNG-001 — WSL/SearXNG integration release

- **Introduced in:** Integration v1.5.0
- **Regression:** Existing healthy JSON endpoints must be adopted; managed installation is allowed only as fallback.
- **Regression:** SearXNG configuration must enable both HTML and JSON formats.
- **Regression:** WSL distro rollback must never unregister a distro automatically.



## Integration top-level starter contract regression

- **Introduced in:** Integration v1.5.0
- **Corrected in:** Integration v1.5.1
- **Failure:** The Integration package validator required `Bootstrap-KIStack-Applications.cmd` and `Start-KIStack-Applications.ps1`.
- **Permanent test:** Validate all top-level Integration launchers, logs, embedded preflight and GitHub wrapper identities as one contract; explicitly reject stale Applications launcher names.

| INT-152-01 | Dry-Run endpoint data missing | Validate returns four named endpoint objects | v1.5.2 |
| INT-152-02 | Early-start test inherited Applications log | Integration emergency-log literal required | v1.5.2 |
| INT-152-03 | Embedded updater exit-code contract drift | Explicit initialized invocationExitCode required | v1.5.2 |

| INT-153-01 | String.Replace Char/empty-string overload | Execute helper with a real NUL character and require String/String overload | v1.5.3 |
| GLOBAL-REG-01 | Known errors recur across packages | Mandatory historical regression gate before every action | v1.5.3 |

| INT-153-01 | String.Replace Char/empty-string overload | Execute helper with a real NUL character and require String/String overload | v1.5.4 |
| GLOBAL-REG-01 | Known errors recur across packages | Mandatory historical regression gate before every action | v1.5.4 |

| INT-153-01 | String.Replace Char/empty-string overload | Execute helper with a real NUL character and require String/String overload | v1.5.5 |
| GLOBAL-REG-01 | Known errors recur across packages | Mandatory historical regression gate before every action | v1.5.5 |

| REG-START-003 | Successful CMD closed before result acknowledgement | Always display result/exitcode, pause once, then close | v1.5.6 |
| REG-GH-004 | Release publisher references stale tag/assets | Derive tag/assets from current manifest and prevalidate existence/SHA256 | v1.5.6 |

| REG-GATE-002 | CMD lifecycle gate scanned helper labels after `:Finish` | Parse only the exact label block up to the next CMD label | v1.5.7 |

## Production recovery and acceptance regressions

| ID | Defect | Permanent regression | Fixed in |
|---|---|---|---|
| REC-ASSET-001 | Recovery builder assumed a non-existent runtime asset name | Select the unique exact published asset and reject missing or duplicate assets | Recovery Builder 1.0.1 |
| REC-HASH-002 | Historical validated archive hash was compared with the separately published core ZIP | Keep historical acceptance identity and published core identity as separate contracts | Recovery Builder 1.0.2 |
| REC-MANIFEST-003 | Embedded release manifest was assumed although the real core ZIP has none | External provenance plus internal SHA256SUMS; embedded manifest remains optional | Recovery Builder 1.0.3 |
| ACC-MANIFEST-001 | Hashtable `.Key` was used instead of `.Keys` | Exact manifest valid, extra, missing and drift fixtures | Target Acceptance 1.0.1 |
| ACC-PATH-002 | Double-backslash string prefix comparison rejected safe nested ZIP paths | Canonical paths plus `Path.GetRelativePath()` | Target Acceptance 1.0.2 |
| GATE-MUTATION-001 | Python tests created `__pycache__` inside the package before exact-set validation | Isolated temporary execution with pre/post package snapshots | Validation Gate 1.0.1 |
| ACC-SCHEMA-003 | Direct access to a missing `fileCount` property failed under StrictMode | Optional-property resolution with actual entry-count fallback | Target Acceptance 1.0.4 |
| ACC-STOP-004 | Controlled stop called a pause-bearing CMD and timed out | Direct PowerShell stop invocation with bounded timeout | Target Acceptance 1.0.5 |
| APP-OWUI-005 | Open WebUI was started through unsupported `python -m open_webui` | Require and execute `open-webui.exe serve` | Target Acceptance 1.0.6 |
| COMFY-DB-006 | ComfyUI SQLite parent directory did not exist | Create `C:\KI-Stack\ComfyUI\user` before startup | Target Acceptance 1.0.6 |
| ACC-CONTENT-007 | Self-test omitted the real `02-Operational-Overlay/Content` path segment | Resolve and verify starters below the extracted Content root | Target Acceptance 1.0.8 |
| REC-STOP-008 | ComfyUI exited between process inventory and the stop request | Treat a missing inventoried PID as already stopped and verify that no matching process remains | Production Recovery 1.7.0-r6 |

## OpenWebUI Agent Pack regressions

| ID | Defect | Permanent regression | Fixed in |
|---|---|---|---|
| OWUI-EMPTY-001 | StrictMode member enumeration failed for empty API resource lists | Enumerate IDs explicitly through the pipeline and accept empty collections | Agent Pack 1.8.0 |
| OWUI-BACKUP-002 | Second-resolution transaction IDs could overwrite backups during rapid idempotence runs | Use fractional-second transaction IDs and verify separate backup contracts | Agent Pack 1.8.0 |
| INT-SEARX-COLD-003 | The integration starter started Valkey and nginx but omitted the standard uWSGI application service, so a cold WSL instance exposed no SearXNG endpoint | Start and verify `valkey-server`, `uwsgi` and `nginx`; require HTML plus parsed JSON search evidence | Integration 1.5.8 |
| INT-KEEPER-PID-004 | A stale PID file was trusted without proving that its process was the managed Debian WSL keeper | Match PID, executable and command line through CIM before reuse or termination; never kill a foreign PID | Integration 1.5.8 |
| INT-PARALLEL-005 | A cold but completely configured standard SearXNG installation could fall through to a second managed installation | Detect the complete standard configuration, cold-start it, and fail closed for incomplete or broken existing configurations | Integration 1.5.8 |
| ACC-SEARX-EVIDENCE-006 | Earlier acceptance only proved an endpoint response in the then-current runtime state and did not prove cold-start lifecycle recovery | Require controlled cold start, stale-PID recovery, service-chain verification, HTML and nonempty JSON search evidence | Target Acceptance 1.0.10 |

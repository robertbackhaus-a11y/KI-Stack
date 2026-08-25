# KI-Stack Complete Installer v2.4.0

Stable release. Adds the Codex Local extension (portable, LM Studio-backed) and the RAG module, and folds in a set of Greenfield-path fixes discovered and corrected during real end-to-end testing.

- Complete Installer: 2.4.0
- Codex Local: 0.1.3 (new)
- RAG: 0.2.0 (new)
- Applications: 1.4.11
- Cutover Runtime: 1.6.10
- Other component versions: unchanged; see the active-components table in the technical documentation

## Verified with a real Greenfield run

Unlike prior 2.4.0 release candidates, this release has been verified with a complete, successful, physical Greenfield installation on an empty target: every transaction step completed and the installer exited with code 0.

## Fixes folded into this release

- **Resume after a required Windows restart** no longer misreports success as a failure: resuming a cutover transaction that had already completed is now treated as a no-op success instead of throwing.
- **SearXNG adoption**: the Integration component's own install path now probes the local backend directly (rather than through its not-yet-configured nginx route) before deciding to install, and its identity check no longer depends on a rate-limited endpoint. Either the Cutover Runtime's `ki-stack-searxng.service` or the Integration component's own `uwsgi.service` is recognized as a valid, already-serving instance; a second, port-conflicting installation is no longer started when one of them is already healthy.
- **LM Studio on a genuine first run**: the managed starter `Start-KIStack-LMStudio.cmd` now waits for LM Studio's `lms` CLI to appear after its first-ever GUI launch (it is not available before that) and then starts the local API server itself, instead of leaving Codex Local unable to reach it.
- A stale, transaction-wide error field left over from an earlier failed attempt no longer appears in the final summary of a subsequently successful run.

## Known manual follow-up

Without a supplied OpenWebUI administrator API key, the temporary Knowledge bootstrap-experiment rollback and the Code Interpreter connection configuration remain manual follow-up steps in OpenWebUI after installation (`CredentialRequiredForApiReadback` / `CredentialRequiredForApiConfiguration`).

The authoritative Complete Installer ZIP hash is published only in the adjacent `.sha256` sidecar and the GitHub Release description.

## Known issue / superseded by 2.5.0

A defect was discovered after this release shipped, during the real, physical Greenfield acceptance testing performed for 2.5.0: in the Visual Models / Workflows download logic, `Receive-Artifact` issued a Range request starting at the already-complete artifact's end-of-file offset (`Range: bytes=<ExpectedSize>-`) whenever a fully-downloaded `.partial` file had not yet been moved to its final target. The download source correctly answers such a request with HTTP 416 Range Not Satisfiable, which could prevent an otherwise fully-downloaded model artifact from finalizing on resume. This defect was present in 2.4.0 as released above; it was reproduced live during the 2.5.0 Greenfield run and is fixed and live-verified in 2.5.0.

This entry documents the defect for the historical record only. 2.4.0 remains published exactly as described above; its artifact and Git tag are not replaced, amended, or re-issued. Anyone still running 2.4.0 should upgrade to 2.5.0, which includes the fix.

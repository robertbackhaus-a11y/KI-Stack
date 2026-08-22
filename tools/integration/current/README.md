# KI-Stack Integration 1.5.11

Git-free successor to 1.5.10. The package builder obtains SearXNG only from upstream commit `357662d86dd225bf8f0bfe5cfaa45bed09aef788`, verifies archive size and SHA-256, applies the tracked Git-free version overlay and produces the embedded payload deterministically. A verified cache is optional; interrupted downloads resume and no manual preload is required. The upstream source and overlay remain AGPL-3.0-or-later. A healthy standard installation is adopted without deleting unmanaged source or metadata.

## SearXNG readiness (diag10)

Readiness -- both during install (`Linux/install-searxng-payload.sh`) and in the
Windows-side `Test-IntegrationEndpoint`/`Test-IntegrationTarget` path
(`IntegrationPackage.psm1`) -- is local-only and deterministic. It never
issues a `/search` request and never depends on any external search engine
being reachable. It proves the local SearXNG app is ready by checking, all
locally:

1. the uWSGI process is active (`systemctl is-active uwsgi`)
2. the uWSGI port/socket (`127.0.0.1:8888`) is actually listening
3. the local HTTP endpoint answers -- SearXNG's own liveness route, `/healthz`
4. the answering app really is SearXNG, not some other listener -- SearXNG's
   `/config` route is parsed for `instance_name`, `version`, and `engines`

Both `/healthz` and `/config` are part of upstream SearXNG itself (see
`searx/webapp.py` at the pinned revision) and never contact an external
engine.

Earlier revisions (through `rc9-diag9`) instead executed a real
`/search?q=...&format=json` request as the readiness check. Because `/search`
always fans out to external engines, a 403/timeout from those engines made
`/search` itself slow or fail; the installer's 60x retry loop then saturated
the uWSGI listen queue on `127.0.0.1:8888`, taking down even plain
diagnostic `curl` calls. The health check was causing its own outage. This
is fixed as of diag10: the retry loop only calls the local probe above.

The original `/search` check still exists as **`optional_search_functional_probe`**
(bash) / **`Test-IntegrationSearchFunctional`** (PowerShell) -- an optional,
informational functional test. It runs at most once per install, never in a
retry loop, and its result never affects the installer's exit code or
`Test-IntegrationTarget`'s `passed` value. An unreachable external engine is
an expected, non-fatal result there.

`Linux/Test-KIStackSearXNGReadiness.sh` is a regression-test harness that
sources the production functions directly (no duplicated logic) and proves,
against local mock HTTP servers:

- local SearXNG app up, external engines unreachable/unmocked -> **ready**
- local SearXNG process/port down -> **not ready**
- some other HTTP app answering on the port -> **not ready**
- the readiness gate never issues a `/search` request
- the optional functional probe never runs inside the retry loop

Run it directly with `bash Linux/Test-KIStackSearXNGReadiness.sh`, or via
`Test-KIStackIntegration.ps1`, which invokes it automatically when a `bash`
runtime (WSL or native) is reachable from the host.

## Windows-side integration marker (diag11)

`Install-IntegrationPayload` writes a small JSON marker to
`C:\KI-Stack\modules\integration\installation.json` after a successful
install. Through `rc9-diag10` this used `Set-Content` directly, which fails
with *"Could not find a part of the path ..."* on a greenfield system where
`C:\KI-Stack\modules\integration` has never been created.

Fixed via the dedicated **`Write-IntegrationMarker`** helper in
`IntegrationPackage.psm1`: it idempotently creates the marker's parent
directory (`New-Item -ItemType Directory -Force`, a no-op if it already
exists) immediately before writing, then writes atomically via a temp file
in the same directory followed by `Move-Item -Force` (an atomic rename on
the same volume), so a partial/corrupt marker can never be left behind.
`Restore-IntegrationState`'s rollback path writes the same marker file
(via `Copy-Item` from a backup) and received the same parent-directory
guard for the identical reason.

`Test-KIStackIntegration.ps1` covers both the greenfield case (parent
directory absent beforehand) and the existing case (directory and a prior
marker already present) by calling `Write-IntegrationMarker` directly --
the real production function, no duplicated logic.


## Windows runtime contract (diag13)

The authoritative runtime set is tracked in `Runtime/RUNTIME-CONTRACT.json` and the adjacent `Runtime` files. Install, upgrade, and repair deploy all declared starters and stoppers atomically to `C:\KI-Stack\modules\integration` before the atomic `installation.json` readback. Rollback restores the complete previous runtime directory or removes a newly created Greenfield directory. Production Recovery, `dist`, `_import`, and backups are never runtime build sources.

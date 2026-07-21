# Integration v1.5.8

Stable. This release preserves the existing integration scope and CMD finish-block lifecycle gate while repairing the real SearXNG runtime lifecycle.

- Runtime chain: `valkey-server` → `uwsgi` → `nginx`.
- Keeper: identity-checked `wsl.exe -d Debian -u root --exec sleep infinity`.
- Success evidence: TCP 80, HTTP 200 HTML page, HTTP 200 JSON content type and parsed nonempty search results.
- Existing complete standard configurations are cold-started and adopted; incomplete or broken configurations fail closed instead of creating a parallel instance.
- Target validation covered cold start, stale PID, idempotent start, partial uWSGI failure and controlled stop/restart.

The earlier Integration 1.5.7 acceptance did not prove this cold-start lifecycle and is superseded for SearXNG runtime evidence.

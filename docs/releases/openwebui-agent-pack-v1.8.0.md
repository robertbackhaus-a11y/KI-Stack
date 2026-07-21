# KI-Stack OpenWebUI Agent Pack 1.8.0

Status: `TargetSystemValidated` at `2026-07-21T11:28:47.0068811Z`.

The package manages exactly two OpenWebUI 0.10.2 workspace models through supported HTTP APIs:

- `ki-stack-it-technik` — `KI & IT-Technik`
- `ki-stack-allgemein` — `Allgemein`

Both definitions use canonical prompts and native function-calling mode. The base model is resolved from an explicit runtime parameter or, only when unique, from the offered usable models. The package attaches no knowledge bases, tools, skills or functions.

OpenWebUI 0.10.2 exposes web search as a chat runtime feature rather than a workspace-model field. The technical profile therefore relies on the existing global SearXNG configuration and is tested with `features.web_search = true` during target validation.

Authentication is a temporary runtime Bearer token held as `SecureString`. Raw exports, tokens, database content and backups are excluded from Git and release publication.

Controlled validation confirmed create/update behavior, a second idempotent Execute, API readback, affected-object backup and rollback, final activation, unchanged foreign resources, both real profile chats and a SearXNG-backed web-search chat. No persistent chat history was created.

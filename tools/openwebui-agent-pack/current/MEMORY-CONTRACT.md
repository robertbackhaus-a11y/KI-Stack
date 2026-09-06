# KI-Stack Native Memory Contract

**Status: adopted, 2.17 Phase 1.**
**Applies to:** `ki-stack-it-technik`, `ki-stack-allgemein` (Agent Pack), `ki-stack-18bravo`
(Ballistics Pack), `ki-stack-research` (Agent Pack). `roleplay` is unmanaged and out of scope.
**Location note:** placed here rather than in a dedicated component because Open WebUI's native
Memory has no KI-Stack-owned component of its own (unlike `server:mcp:ki-stack-mcp-runtime`) — Agent
Pack manages the majority of the memory-relevant profiles (`ki-stack-it-technik`, `ki-stack-allgemein`,
`ki-stack-research`); Ballistics Pack's own `ki-stack-18bravo` policy (§ Profile Policy) references this
document rather than duplicating it.

## Purpose

Persistent, user-specific facts/preferences/context using Open WebUI's own **native** Memory system —
no new KI-Stack store, no new MCP server, no new runtime.

## Architecture

- **Open WebUI native implementation** — 8 builtin tool functions
  (`search_memories`, `list_memory_paths`, `read_memory_path`, `list_memories`, `update_memory`,
  `add_memory`, `replace_memory_content`, `delete_memory`), verified against installed Open WebUI
  `0.11.3` source (`open_webui/tools/builtin.py`).
- **Storage**: the `memory` table inside `webui.db` (SQLite) — the *same* database file already used
  for chats, users, and every other Open WebUI record. No new database, no new file, no new schema
  introduced by KI-Stack.
- **No new KI-Stack store.** No MCP memory server. No ChromaDB involvement.
- **Execution**: the real local model (currently `qwen3.6-27b-uncensored-heretic-v2-native-mtp-preserved`,
  served by LM Studio) performs the actual tool calls via Open WebUI's native function-calling path —
  verified real, end to end, in 2.17 Phase 0 and re-confirmed in this phase's acceptance test.

## Scope

Memory **is**:
- per authenticated user (the `memory` table has a `user_id` column; it has **no** model/profile column
  at all)
- shared across chats for that same user
- shared across profiles for that same user (a memory created under one profile is visible when
  searched from a different profile, in a different chat — verified real, Phase 0)
- persistent across a real Open WebUI restart (verified real, Phase 0)

Memory is **NOT**:
- profile-specific storage — there is no technical mechanism to scope a memory to a single profile;
  any apparent "profile isolation" is a policy/behavioral choice (see Profile Policy), never a storage
  guarantee
- Chat History (a separate table/tool pair, `search_chats`/`view_chat` — searches past conversation
  transcripts themselves, not extracted facts)
- KI-Stack RAG (ChromaDB-backed document/knowledge retrieval, entirely separate storage and tool set)
- 2.16 Local Control (`server:mcp:ki-stack-mcp-runtime` — host/system control, unrelated domain)

## Five-Gate Contract

Verified against installed source, not documentation. Five effective checks gate whether memory tools
actually reach a model in a given request — stated precisely because oversimplifying this (e.g. "just
enable memory on the profile") was the exact failure mode this project's own Phase 0 testing first hit
(a profile with `capabilities.memory:true` still produced zero real tool calls, because of Gate 2
below):

1. **Global master switch** — `memories.enable` (env `ENABLE_MEMORIES`, default `true`). Enforced in
   `open_webui/routers/memories.py`. Verified live on this installation: **`true`**.
2. **Global builtin-tools master switch (per-model, not truly global)** —
   `meta.capabilities.builtin_tools` (default `true` if unset). This is the master switch for the
   *entire* builtin-tools category (memory, notes, chats, channels, calendar, automations alike), not
   memory-specific. **This is the exact gate that was found `false` on `ki-stack-it-technik`
   (Phase 0), silently disabling memory there despite `capabilities.memory:true` — fixed in this
   phase, see Profile Policy.**
3. **Per-model memory capability** — `meta.capabilities.memory` (default `true` if unset).
4. **Per-model memory builtin-tool category** — `meta.builtinTools.memory` (default `true` if unset) —
   a *separate* flag from #3, both must independently pass.
5. **Per-chat activation** — `features.memory` in the chat-completion request body. Not read from any
   model/profile/user default anywhere in the installed server code (confirmed by exhaustive source
   search across `models/models.py`, `models/users.py`, `config.py`, and
   `utils/middleware.py` — see the companion Phase 1 report's "Remaining Product/UI Limitation"
   section). **This is a genuine, real, per-request client responsibility that no server-side
   KI-Stack configuration can eliminate without custom frontend code, which is explicitly out of scope
   for this phase.**

A sixth, related check exists for a *separate* code path — the **passive system-context injection**
(memories silently added to the model's context before generation, independent of tool-calling):
gated by the same `features.memory` flag (#5) plus a distinct global switch,
`memories.system_context.enable` (env `ENABLE_MEMORY_SYSTEM_CONTEXT`, default `true`) — verified live:
**`true`**. Per-user permission is re-checked on this path too.

Also relevant, not itself a gate but required for either path to be reachable at all:
**`params.function_calling` must be `native`** (not `legacy`, not unset) — `roleplay`'s own
`function_calling` was found unset during Phase 0; this was left unmodified per this phase's scope
(`roleplay` is explicitly untouched).

Per-user/per-group permission (`user.permissions.features.memories`) sits alongside gate 1, checked on
both the active and passive paths; admins always pass regardless of the stored permission value.
Verified live: the default user-permission set already has **`features.memories: true`**.

## Profile Policy

| Profile | Native Memory | Mechanism |
|---|---|---|
| `ki-stack-it-technik` | **Enabled** (gates 2/3/4 asserted) | `capabilities.builtin_tools:true` (fixes the Phase 0 misconfiguration), `capabilities.memory:true`, `builtinTools.memory:true` — all package-declared in `Definitions/ki-stack-it-technik.json`, reasserted every reconcile |
| `ki-stack-allgemein` | **Enabled** (gates 2/3/4 asserted) | Same three fields, package-declared in `Definitions/ki-stack-allgemein.json` |
| `ki-stack-18bravo` | **Disabled by default** | `capabilities.memory:false`, hardcoded in `OpenWebUIBallisticsPack.psm1`'s `New-BallisticsModelForm`, reasserted every reconcile — see Ballistics Rationale below |
| `ki-stack-research` | **Disabled** | `capabilities.memory:false` / `builtinTools.memory:false`, already present in `Definitions/ki-stack-research.json` prior to this phase — unchanged, consistent with its existing no-shell/no-host security posture |
| `roleplay` | **Unchanged/unmanaged** | No repository definition exists for this profile (live-only, unmanaged); explicitly out of scope for 2.17 Phase 1 |

Gate 5 (per-chat `features.memory` activation) is **not** and cannot be set by any of the above —
see the Five-Gate Contract's own point 5 and the companion report's "Remaining Product/UI Limitation."
Enabling gates 2-4 makes memory **available**; whether any individual chat actually activates it
remains a per-request client decision in every case.

## Ballistics Rationale

`ki-stack-18bravo`'s existing behavior already requires **explicit user confirmation** before saving
any change to a ballistic profile, BC, or muzzle-velocity value (unchanged by this phase — the
`"Ändere Profile, BC oder Mündungsgeschwindigkeit nie automatisch und speichere nur nach ausdrücklicher
Bestätigung"` rule in its own system prompt remains authoritative). General, cross-session Open WebUI
user memory must not be allowed to silently substitute for that explicit, current-calculation input:
a stray memory of "the user's rifle is chambered in .308" from a previous, unrelated session could
otherwise leak into a new calculation without the same confirmation discipline the Ballistics-specific
mechanism already enforces. Disabling native Memory for this profile closes that risk at the source,
without touching the existing, already-correct Ballistics persistence/confirmation semantics themselves.

## Security / Privacy

- Local SQLite storage only (`webui.db`) — no cloud API involved anywhere in the read/write path.
- `user_id`-based separation; no per-profile or per-chat storage boundary exists (see Scope).
- No secret syncing.
- **No encryption-at-rest claim** — the database file is a plain, directly-readable SQLite file on
  this installation (verified by direct `sqlite3` access); no `sqlite+sqlcipher` configuration is in
  use.
- Admins have elevated visibility/control: the per-user permission check is bypassed entirely for the
  `admin` role, and the global `memories.enable` switch is admin-configurable.
- Deletion is real, immediate row deletion (`delete_memory` performs an actual `DELETE`, verified via
  direct database re-query after a real test call) — not a soft-delete/tombstone.
- Backup of `webui.db` (and therefore memory) is a **separate concern**, out of scope for this phase —
  no whole-database backup mechanism was found to exist in this repository prior to 2.17 (a
  pre-existing characteristic of the whole Open WebUI database, not something this phase creates or
  worsens).

## Namespaces / Paths

Minimal convention only — organizational metadata, **not** an access-control boundary:

- `general/` — everyday facts/preferences with no more specific home
- `it/` — technical/infrastructure-specific context (`ki-stack-it-technik`)
- `preferences/` — standing user preferences (tone, format, recurring constraints)

Any of these paths are visible to, and searchable by, any profile the same user talks to (per Scope) —
using a path is a way to keep `list_memory_paths`/`read_memory_path` organized as memory volume grows,
never a way to hide a memory from a different profile. No `ballistics/` namespace is defined, since
native Memory is disabled for `ki-stack-18bravo` by policy (see Ballistics Rationale) — there is
nothing to namespace there today.

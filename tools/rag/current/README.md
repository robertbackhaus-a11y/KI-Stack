# KI-Stack RAG 0.2.0

Development ingestion module for OpenWebUI 0.11.0. Nomic is the only embedding model. Document and query prefixes are separate. Sources are explicit, hash-controlled and removable by stable `source_id`.

`Config/sources.json` is the explicit source allow-list. Audit, DryRun and Status never mutate the target. Execute creates or reuses one managed Knowledge collection, uploads deterministic local chunks with the complete metadata contract, performs SHA256 delta replacement and removes deleted sources. Tokens are accepted only as `SecureString` and are never stored.

OpenWebUI endpoint contracts are pinned to 0.11.0. Target-system acceptance and explicit remote rollback remain intentionally unclaimed until they have passed on the Windows target.

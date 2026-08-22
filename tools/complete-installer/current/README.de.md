# KI-Stack Complete Installer 2.4.0-rc9

Entwicklungsstand auf Basis des stabilen Complete Installers 2.3.2. Der RC ergänzt die Local Intelligence Extension; eine Zielsystemfreigabe liegt noch nicht vor.

- Heretic ist das einzige Chat-LLM.
- Nomic dient ausschließlich Embeddings.
- Z-Image verwendet nur `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`.
- Aktive visuelle Workflows sind Z-Image Turbo und WAN2.2 T2V 14B mit beiden LightX2V-4-Step-LoRAs.
- Visual Pack ist 2.0.5, Agent Pack 1.8.9 und Models / Workflows 2.0.3.
- Fehlende Modelle einschließlich des ausschließlich für Embeddings verwendeten `nomic-embed-text-v1.5.Q4_K_M.gguf` werden automatisch geladen. Gültige Ziele und optionale Caches/Preloads werden nur nach Größen- und SHA-256-Prüfung wiederverwendet.
- Ein temporärer OpenWebUI-Administrator-API-Key bleibt ausschließlich im Arbeitsspeicher und wird nie gespeichert.
- Codex Local 0.1.3 wird reproduzierbar über LM Studio angebunden. Node.js 24.14.0 und npm werden dabei als portable, SHA256-geprüfte Modullaufzeit paketgesteuert bereitgestellt; eine globale Node.js-Installation ist nicht erforderlich. Die Windows-Buildvalidierung führt die installierte CLI vor der Zielfreigabe real mit der verwalteten Laufzeit aus.
- RAG 0.2.0 wird als getrenntes Modul installiert; Quellen bleiben kontrolliert und die Ingestion wird nicht ohne Freigabe automatisch gestartet.
- OpenWebUI erhält beim Start die Nomic-Präfixe `search_document:` und `search_query:`.

Prüfe das ZIP vor dem Entpacken gegen das danebenliegende `.sha256`-Sidecar. Der endgültige ZIP-Hash ist absichtlich nicht im Paket eingebettet.

Installation, Upgrade, Lifecycle, SHA-256, Resume, Recovery und Rollback stehen in `Documentation/INSTALLATION.de.md`. Der Greenfield-Vertrag wurde mit Quell-/Paketprüfungen und kleinen Fixtures geprüft; eine vollständige reale Greenfield-Neuinstallation auf einem leeren Ziel wurde nicht durchgeführt.

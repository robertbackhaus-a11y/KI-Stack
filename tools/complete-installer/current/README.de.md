# KI-Stack Complete Installer 2.3.1 Stable

Reines Dokumentationspatch über dem funktional identischen, TargetValidated-Release 2.3.0.

- Heretic ist das einzige Chat-LLM.
- Nomic dient ausschließlich Embeddings.
- Z-Image verwendet nur `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`.
- Aktive visuelle Workflows sind Z-Image Turbo und WAN2.2 T2V 14B mit beiden LightX2V-4-Step-LoRAs.
- Visual Pack ist 2.0.5, Agent Pack 1.8.9 und Models / Workflows 2.0.2.
- Fehlende Modelle werden automatisch geladen. Gültige Ziele und optionale Caches/Preloads werden nur nach Größen- und SHA-256-Prüfung wiederverwendet.
- Ein temporärer OpenWebUI-Administrator-API-Key bleibt ausschließlich im Arbeitsspeicher und wird nie gespeichert.

Prüfe das ZIP vor dem Entpacken gegen das danebenliegende `.sha256`-Sidecar. Der endgültige ZIP-Hash ist absichtlich nicht im Paket eingebettet.

Installation, Upgrade, Lifecycle, SHA-256, Resume, Recovery und Rollback stehen in `Documentation/INSTALLATION.de.md`. Der Greenfield-Vertrag wurde mit Quell-/Paketprüfungen und kleinen Fixtures geprüft; eine vollständige reale Greenfield-Neuinstallation auf einem leeren Ziel wurde nicht durchgeführt.

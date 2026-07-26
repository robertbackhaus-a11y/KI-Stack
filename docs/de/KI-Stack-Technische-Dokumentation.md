# KI-Stack 2.3.1 – Technische Dokumentation

KI-Stack ist ein transaktionsgesicherter lokaler Windows-KI-Stack. Complete Installer 2.3.1 ist ein reines Dokumentationspatch über dem funktional identischen, TargetValidated-Release 2.3.0.

## Aktive Komponenten

| Komponente | Version |
|---|---:|
| Foundation / Runtime | 1.0.9 |
| Python / Git | 1.1.5 |
| ComfyUI | 1.2.4 |
| Models / Workflows | 2.0.2 |
| Applications | 1.4.10 |
| Integration | 1.5.10 |
| Cutover Runtime | 1.6.5 |
| Production Recovery | 1.7.0-r7 |
| Validation Gate | 1.0.3 |
| Target Acceptance | 1.0.10 |
| OpenWebUI Visual Pack | 2.0.5 |
| OpenWebUI Agent Pack | 1.8.9 |
| Complete Installer | 2.3.1 |

Heretic ist das einzige auswählbare Chat-LLM. Nomic dient ausschließlich Embeddings. Z-Image verwendet nur `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`. Die visuelle Ausführung ist auf Z-Image Turbo und WAN2.2 T2V 14B mit beiden High-/Low-LightX2V-4-Step-LoRAs begrenzt.

## Modellbeschaffung

Das zentrale versionierte Manifest enthält revisionsgebundene Quellen, Dateinamen, Größen und SHA-256-Werte. Zuerst wird ein gültiges installiertes Ziel wiederverwendet, danach ein optionaler geprüfter Cache/Preload. Fehlende Dateien werden automatisch in den Transaktionszustand geladen und, sofern unterstützt, per Range fortgesetzt. Die atomare Aktivierung erfolgt erst nach vollständiger Größen- und SHA-256-Prüfung. Netzwerkausfälle bleiben fortsetzbar; falsche Größe oder falscher Hash schlägt fehl.

Git und Complete-Installer-ZIP enthalten keine Modellgewichte. Preloads sind optional und keine Installationsvoraussetzung.

## Transaktionen und OpenWebUI

Installation und Upgrade verwenden Komponentenplanung, begrenzte Backups, protokollierten Zustand, realen Versions-Readback, Resume, Recovery und Rollback. Eine Komponente wird erst nach erfolgreichem Deployment und Readback als abgeschlossen gespeichert. Rollback betrifft ausschließlich die aktive Transaktion.

Für die OpenWebUI-Visual-/Agent-Verwaltung kann ein temporärer Administrator-API-Key verdeckt als `SecureString` abgefragt werden. Er wird nur im Arbeitsspeicher verwendet, nicht in Berichte, State, Kommandozeilen oder Umgebungsdateien geschrieben und soll anschließend widerrufen werden.

MP4 bleibt genau ein persistenter Dateianhang über das native `files`-Event und `/api/v1/files/{id}/content`.

## Validierungsumfang

Greenfield-Beschaffung, Cache-Wiederverwendung, Resume, Netzwerkausfall, Größen-/Hashfehler und atomare Aktivierung wurden mit Quell-/Paketprüfungen und kleinen lokalen Fixtures geprüft. Eine vollständige reale Greenfield-Neuinstallation auf einem leeren Ziel wurde nicht durchgeführt. Die funktionale Validierung von Heretic, Nomic, Z-Image, WAN2.2, OpenWebUI-Anhängen und Stack-Health wird unverändert von 2.3.0 übernommen, da 2.3.1 ausschließlich Dokumentation ändert.

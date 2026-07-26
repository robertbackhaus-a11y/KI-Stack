# KI-Stack 2.3.2 – Betriebs- und Benutzerhandbuch

## Normalbetrieb

- Installation oder Upgrade: `Start-KIStack-Installer.cmd`
- Stack starten: `Start-KIStack.cmd`
- Stack stoppen: `Stop-KIStack.cmd`
- Read-only-Status: `Status-KIStack.cmd`
- Interaktiver Status: `Lifecycle\Status-KIStack-Interactive.cmd`

Verwende PowerShell 7. Halte die Paketdateien zusammen und starte keine einzelnen Komponenteninstaller manuell.

## Modelle und Workflows

Heretic ist das einzige Chat-LLM; Nomic dient ausschließlich Embeddings. Z-Image verwendet das offizielle `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`. Die einzigen aktiven visuellen Workflows sind Z-Image Turbo und WAN2.2 T2V 14B mit beiden LightX2V-4-Step-LoRAs. FLUX, Krea, Pony, WAN-5B/I2V und Legacy-Image-Pack-Workflows sind nicht aktiv.

Fehlende benötigte Modelle werden automatisch aus revisionsgebundenen Quellen geladen. Gültige Ziele und optionale Cache-/Preload-Dateien werden nur nach Größen- und SHA-256-Prüfung wiederverwendet. Unterbrochene Übertragungen werden, sofern unterstützt, fortgesetzt. Falsche Größe oder falscher Hash schlägt sicher fehl; keine ungültige Datei wird aktiviert.

## OpenWebUI

Der Agent Pack ist 1.8.9, der Visual Pack 2.0.5. Bei einer Visual-/Agent-Aktualisierung kann ein temporärer OpenWebUI-Administrator-API-Key abgefragt werden. Er wird verdeckt eingegeben, nur im Arbeitsspeicher gehalten, nie gespeichert und soll anschließend widerrufen werden.

Bilder bleiben sichtbarer Chatinhalt. MP4 bleibt nach Reload genau ein persistenter herunterladbarer FileItem über `/api/v1/files/{id}/content`.

## Transaktionen

Transaktionszustand liegt unter `C:\KI-Stack\state\complete-installer\<TransactionId>`, Backups unter `C:\KI-Stack\backups\complete-installer\<TransactionId>`.

- Resume: `Resume-KIStack-Installer.cmd <TransactionId>`
- Audit: `Start-KIStack-Audit.cmd`
- Validate: `Start-KIStack-Validate.cmd`
- Repair nach Diagnose: `Start-KIStack-Repair.cmd`
- Rollback: `Start-KIStack-Rollback.cmd`

Resume setzt beim ersten unvollständigen Schritt fort. Recovery prüft offene und fehlgeschlagene Transaktionen vor einem neuen Installationsplan. Rollback stellt nur Dateien wieder her, die durch die ausgewählte Transaktion geändert wurden. Vorhandene konforme Modelle und Nutzerdaten bleiben erhalten.

Der Greenfield-Vertrag wurde mit Quell-/Paketprüfungen und kleinen Download-Fixtures geprüft; eine vollständige reale Greenfield-Neuinstallation auf einem leeren Ziel wurde für diesen Release nicht durchgeführt.

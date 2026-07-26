# KI-Stack Complete Installer 2.3.1 – Installation und Upgrade

Diese Anleitung gilt für das Stable-Paket `KI-Stack-Complete-Installer-v2.3.1.zip`. Version 2.3.1 korrigiert ausschließlich Dokumentation; die funktionale Validierung wurde unverändert von 2.3.0 übernommen.

## Download und SHA-256

Lade ZIP und `KI-Stack-Complete-Installer-v2.3.1.zip.sha256` aus demselben GitHub-Release. Der verbindliche Hash steht ausschließlich im Sidecar und in der GitHub-Releasebeschreibung.

```powershell
$zip = '.\KI-Stack-Complete-Installer-v2.3.1.zip'
$expected = ((Get-Content "$zip.sha256" -Raw) -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw 'SHA-256 stimmt nicht überein.' }
```

Entpacke das ZIP erst nach erfolgreicher Prüfung.

## Installation und Upgrade

1. Entpacke das Paket vollständig.
2. Starte `Start-KIStack-Installer.cmd` mit PowerShell 7; bestätige die einmalige UAC-Abfrage.
3. Wenn Visual oder Agent aktualisiert werden, gib einen temporären OpenWebUI-Administrator-API-Key verdeckt ein. Er wird nur im Arbeitsspeicher verwendet, nicht gespeichert und soll anschließend in OpenWebUI widerrufen werden.
4. Warte auf `Completed` oder `SkippedAlreadyCompliant`.

Der Installer verwendet denselben transaktionalen Upgradepfad für Greenfield, Upgrade und Reparaturplanung. Bereits anhand Dateiname, Größe und SHA-256 gültige Modelle werden wiederverwendet. Fehlende Modelle werden automatisch aus revisionsgebundenen Quellen geladen. Ein optionaler Cache beziehungsweise `ExternalModels`-Preload ist erlaubt, aber keine Voraussetzung. Teildownloads werden per Resume fortgesetzt; falsche Größe oder SHA-256 führt zu `Failed`.

Der Greenfield-Vertrag wurde mit Quell-, Paket- und lokalen Download-Fixtures geprüft. Eine vollständige reale Greenfield-Neuinstallation auf einem leeren Zielsystem wurde für diesen Release nicht durchgeführt.

## Modellrollen

- Heretic ist das einzige Chat-LLM.
- Nomic wird ausschließlich für Embeddings verwendet.
- `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf` wird ausschließlich durch Z-Image verwendet.
- Aktive visuelle Workflows sind ausschließlich Z-Image Turbo und WAN2.2 T2V 14B mit beiden LightX2V-4-Step-LoRAs.
- FLUX, Krea, Pony, WAN-5B/I2V und Legacy-Image-Pack-Verträge sind nicht aktiv.

## Start, Stop und Status

- Start: `Start-KIStack.cmd`
- Stop: `Stop-KIStack.cmd`
- Status: `Status-KIStack.cmd`
- Interaktiver Status: `Lifecycle\Status-KIStack-Interactive.cmd`

Status ist read-only und startet keine Dienste.

## Resume, Recovery und Rollback

Transaktionen liegen unter `C:\KI-Stack\state\complete-installer\<TransactionId>`, Backups unter `C:\KI-Stack\backups\complete-installer\<TransactionId>`.

- Resume: `Resume-KIStack-Installer.cmd <TransactionId>`
- Read-only Audit: `Start-KIStack-Audit.cmd`
- Read-only Validate: `Start-KIStack-Validate.cmd`
- Reparatur nach Diagnose: `Start-KIStack-Repair.cmd`
- Kontrollierter Rollback: `Start-KIStack-Rollback.cmd`

Resume überspringt abgeschlossene beziehungsweise bereits konforme Schritte. Recovery prüft ausstehende oder fehlgeschlagene Transaktionen vor einem neuen Plan. Rollback stellt nur Änderungen der betroffenen Transaktion aus deren Backup wieder her; vorher vorhandene konforme Modelle und Nutzerdaten bleiben außerhalb des Löschumfangs.

# KI-Stack 2.4.0 – Betriebs- und Benutzerhandbuch

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

## LM Studio und Codex Local

LM Studio wird über `winget` installiert, sein lokaler API-Server wird dabei aber nicht automatisch mitgestartet. Der verwaltete Starter `Start-KIStack-LMStudio.cmd` bringt den Server hoch:

- Ist LM Studios `lms`-CLI bereits verfügbar, startet der Starter den Server direkt.
- Auf einer Maschine, auf der LM Studio noch nie gelaufen ist, wird `lms` erst verfügbar, nachdem die LM-Studio-GUI ihre eigene Ersteinrichtung abgeschlossen hat. Der Starter startet dann einmalig die GUI, wartet begrenzt darauf, dass `lms` erscheint, startet anschließend den lokalen API-Server und bestätigt, dass er unter `http://127.0.0.1:1234/v1/models` antwortet.

Codex Local benötigt genau diesen erreichbaren Endpunkt. Der Complete Installer ruft deshalb den LM-Studio-Starter vor der Codex-Local-Konfiguration auf, sodass eine normale Installation kein manuelles Starten von LM Studio erfordert. Falls der LM-Studio-Server einmal manuell gestartet werden muss — etwa nach einem Stopp —, `Start-KIStack-LMStudio.cmd` aus `C:\KI-Stack\modules\applications` ausführen.

## SearXNG, nginx und Valkey

SearXNG ist über nginx unter `/searxng` erreichbar, das auf eine lokale, per `uwsgi` betriebene Instanz proxyt; `valkey-server` stützt den lokalen Ratenlimiter-/Session-Speicher. Der Dienst kann entweder unter dem eigenen `ki-stack-searxng.service` der Cutover-Runtime-Komponente oder unter dem generischen `uwsgi.service` der Integration-Komponente laufen — beide werden als gültige, bereits laufende Installation erkannt. Ist einer davon bereits gesund, übernimmt die Integration-Komponente diesen, statt eine zweite, portkonfliktäre Instanz zu starten.

## OpenWebUI

Der Agent Pack ist 1.8.9, der Visual Pack 2.0.5. Bei einer Visual-/Agent-Aktualisierung kann ein temporärer OpenWebUI-Administrator-API-Key abgefragt werden. Er wird verdeckt eingegeben, nur im Arbeitsspeicher gehalten, nie gespeichert und soll anschließend widerrufen werden.

Bilder bleiben sichtbarer Chatinhalt. MP4 bleibt nach Reload genau ein persistenter herunterladbarer FileItem über `/api/v1/files/{id}/content`.

## RAG / Knowledge-Ingestion

Das RAG-Modul (0.2.0) wird bei einer normalen Installation automatisch unter `C:\KI-Stack\modules\rag` installiert; seine OpenWebUI-Suchpräfix-Umgebung wird dabei in den bestehenden OpenWebUI-Starter eingebunden. Die Installation prüft nur den eigenen Quellenvertrag des Moduls und legt dessen Dateien ab — sie **ingestiert keine Dokumente**, und standardmäßig sind keine Quellen konfiguriert (`Config/sources.json` liefert eine leere Allow-List aus).

Um tatsächlich Inhalte zu ingestieren, müssen zunächst selbst Einträge in `Config/sources.json` hinzugefügt werden (Schema: `Contracts/source.schema.json`), danach der eigene Einstiegspunkt des Moduls aus `C:\KI-Stack\modules\rag` ausgeführt werden:

```powershell
.\Invoke-KIStackRAG.ps1 -Mode Execute -ApiToken (Read-Host -AsSecureString)
```

Verfügbare Modi sind `Audit`, `DryRun`, `Execute`, `Status` und `Rollback`; nur `Audit`, `DryRun` und `Status` sind garantiert ohne Änderung an OpenWebUI. Der API-Token wird ausschließlich als `SecureString` entgegengenommen und nie gespeichert.

Dieser Ingestionspfad (die Modi `Execute`/`Rollback` gegen eine echte OpenWebUI-Knowledge-Collection) wurde **nicht** gesondert zielsystemvalidiert, über die reine Installation des Moduls im erfolgreichen Greenfield-Lauf hinaus — laut eigenem README des Moduls als funktional, aber nicht vollständig zielsystemvalidiert zu betrachten.

## Knowledge-Bootstrap und Code-Interpreter-Nacharbeit

Ohne angegebenen OpenWebUI-Administrator-API-Key bleiben zwei Abschlussschritte manuelle Nacharbeit (in der finalen Installer-Zusammenfassung als `CredentialRequiredForApiReadback` beziehungsweise `CredentialRequiredForApiConfiguration` ausgewiesen):

- Entfernen des temporären Knowledge-Bootstrap-Experiments (unabhängig von der eigentlichen Ingestion des RAG-Moduls oben).
- Konfiguration der OpenWebUI-Code-Interpreter-Verbindung.

Bei einem späteren Lauf mit angegebenem temporärem Administrator-API-Key erledigt der Installer diese Schritte automatisch, andernfalls müssen sie manuell in OpenWebUI nachgeholt werden.

## Transaktionen

Transaktionszustand liegt unter `C:\KI-Stack\state\complete-installer\<TransactionId>`, Backups unter `C:\KI-Stack\backups\complete-installer\<TransactionId>`.

- Resume: `Resume-KIStack-Installer.cmd <TransactionId>`
- Audit: `Start-KIStack-Audit.cmd`
- Validate: `Start-KIStack-Validate.cmd`
- Repair nach Diagnose: `Start-KIStack-Repair.cmd`
- Rollback: `Start-KIStack-Rollback.cmd`

Resume setzt beim ersten unvollständigen Schritt fort. Recovery prüft offene und fehlgeschlagene Transaktionen vor einem neuen Installationsplan. Rollback stellt nur Dateien wieder her, die durch die ausgewählte Transaktion geändert wurden. Vorhandene konforme Modelle und Nutzerdaten bleiben erhalten.

Eine erstmalige WSL2-Aktivierung auf einer wirklich leeren Maschine kann einen Windows-Neustart erfordern; der Installer bricht dann mit Exitcode `31` ab und gibt die TransaktionsID zum späteren Fortsetzen aus. Das ist eine normale, fortsetzbare Pause, kein Fehler.

## Fehlerbehebung

- **Installer meldet `NEUSTART ERFORDERLICH` / Exitcode 31**: Windows neu starten, danach `Resume-KIStack-Installer.cmd <TransactionId>` mit der ausgegebenen TransaktionsID ausführen.
- **LM-Studio-/Codex-Local-Schritt schlägt mit nicht erreichbarem Endpunkt fehl**: prüfen, ob das LM-Studio-Fenster offen ist und ob `%USERPROFILE%\.lmstudio\bin\lms.exe` existiert; wurde LM Studio gerade zum allerersten Mal installiert, kann die eigene Ersteinrichtung auf einer langsamen Maschine länger dauern als das Wartefenster des Starters — die Transaktion erneut per Resume fortsetzen.
- **SearXNG scheint nicht erreichbar**: in der WSL-Debian-Instanz `systemctl status ki-stack-searxng uwsgi nginx valkey-server` prüfen; dass entweder `ki-stack-searxng` oder `uwsgi` aktiv und auf Port 8888 gesund ist, ist ein gültiger, erwarteter Zustand.
- **Ein Schritt meldet `CredentialRequiredForApiReadback` oder `CredentialRequiredForApiConfiguration`**: das ist erwartet, wenn kein OpenWebUI-Administrator-API-Key angegeben wurde; siehe Abschnitt Knowledge-Bootstrap und Code-Interpreter-Nacharbeit oben.

Der Greenfield-Vertrag wurde mit einer vollständigen, erfolgreichen, realen Installation auf einem leeren Zielsystem verifiziert.

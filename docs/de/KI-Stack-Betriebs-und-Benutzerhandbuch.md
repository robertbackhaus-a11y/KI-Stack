# KI-Stack 2.12.0 – Betriebs- und Benutzerhandbuch

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

Der Agent Pack ist 1.9.0, der Visual Pack 2.0.5. Der Agent Pack verwaltet drei Workspace-Modelle: `KI & IT-Technik`, `Allgemein` und den Referenz-Research-Agenten `ki-stack-research` (dynamisch gebundenes lokales RAG-Wissen plus Websuche, isolierter Pyodide-Code-Interpreter, keine Extension-Tools, kein Shell-/Host-/Administrationszugriff -- siehe „RAG / Knowledge-Ingestion" unten sowie das eigene README des Agent Packs für den vollständigen Vertrag). Bei einer Visual-/Agent-Aktualisierung kann ein temporärer OpenWebUI-Administrator-API-Key abgefragt werden. Er wird verdeckt eingegeben, nur im Arbeitsspeicher gehalten, nie gespeichert und soll anschließend widerrufen werden.

Bilder bleiben sichtbarer Chatinhalt. MP4 bleibt nach Reload genau ein persistenter herunterladbarer FileItem über `/api/v1/files/{id}/content`.

## RAG / Knowledge-Ingestion

Das RAG-Modul (0.4.0) wird bei einer normalen Installation automatisch unter `C:\KI-Stack\modules\rag` installiert; seine OpenWebUI-Suchpräfix-Umgebung wird dabei in den bestehenden OpenWebUI-Starter eingebunden. Die Installation prüft nur den eigenen Quellenvertrag des Moduls und legt dessen Dateien ab — sie **ingestiert keine Dokumente**, und standardmäßig sind keine Quellen konfiguriert (`Config/sources.json` liefert eine leere Allow-List aus).

Um tatsächlich Inhalte zu ingestieren, müssen zunächst selbst Einträge in `Config/sources.json` hinzugefügt werden (Schema: `Contracts/source.schema.json`), danach der eigene Einstiegspunkt des Moduls aus `C:\KI-Stack\modules\rag` ausgeführt werden:

```powershell
.\Invoke-KIStackRAG.ps1 -Mode Execute -ApiToken (Read-Host -AsSecureString)
```

Verfügbare Modi sind `Audit`, `DryRun`, `Execute`, `Status` und `Rollback`; nur `Audit`, `DryRun` und `Status` sind garantiert ohne Änderung an OpenWebUI. Der API-Token wird ausschließlich als `SecureString` entgegengenommen und nie gespeichert. `Invoke-KIStackRAG.ps1` ist ein schedulierbarer Einstiegspunkt: ein abbrechender Fehler propagiert als von Null verschiedener Prozess-Exitcode, sodass er sich ohne Wrapper in einen externen Scheduler (z. B. die Windows-Aufgabenplanung) für unbeaufsichtigten, periodischen Re-Import einbinden lässt.

`Execute` importiert Quellen idempotent per SHA-256 erneut: eine unveränderte Quelle bleibt unangetastet (`Skip`), eine geänderte Quelle wird remote gelöscht und neu angelegt (`Replace`), eine neue Quelle wird hinzugefügt (`Add`), und eine aus `Config/sources.json` entfernte Quelle wird remote entfernt (`Remove`) -- ein Teilfehlschlag lässt bereits committete Quellen unangetastet, ein Retry verarbeitet nur das noch nicht Abgeschlossene erneut. `Execute`/`Rollback` (Add, Replace, Remove) sind real gegen eine echte OpenWebUI-Instanz zielsystemvalidiert, jeweils einschließlich eines wiederholten `Rollback`-Aufrufs, der als sauberer, idempotenter No-op bestätigt wurde, und zusätzlich durch eine umfangreiche gemockte Regressionssuite abgedeckt.

Standardmäßig gehören alle Quellen zu einer globalen Knowledge-Collection. `New-KIStackRAGProjectScope.ps1 -ProjectName <name>` legt einen zusätzlichen, vollständig isolierten Projekt-Scope an (eigenes Config-/Sources-Dateipaar, abgebildet auf eine eigene, getrennte OpenWebUI-Knowledge-Collection), sodass die Dokumente eines Projekts nie in einer fremden globalen Antwort auftauchen und umgekehrt.

Der Referenz-Research-Agent `ki-stack-research` (OpenWebUI Agent Pack, siehe „OpenWebUI" oben) löst die globale RAG-Knowledge-Collection zur Installations-/Reconcile-Zeit dynamisch anhand des Namens auf -- nie eine hartcodierte Collection-ID. Existiert diese Collection noch nicht (RAG hat auf diesem Ziel noch nie `Execute` ausgeführt), wird `ki-stack-research` bei diesem Lauf vollständig übersprungen statt mit leerer Knowledge-Bindung angelegt zu werden; alle anderen verwalteten Profile werden im selben Lauf normal fertiggestellt.

## Knowledge-Bootstrap und Code-Interpreter-Nacharbeit

Ohne angegebenen OpenWebUI-Administrator-API-Key bleiben zwei Abschlussschritte manuelle Nacharbeit (in der finalen Installer-Zusammenfassung als `CredentialRequiredForApiReadback` beziehungsweise `CredentialRequiredForApiConfiguration` ausgewiesen):

- Entfernen des temporären Knowledge-Bootstrap-Experiments (unabhängig von der eigentlichen Ingestion des RAG-Moduls oben).
- Konfiguration der OpenWebUI-Code-Interpreter-Verbindung.

Bei einem späteren Lauf mit angegebenem temporärem Administrator-API-Key erledigt der Installer diese Schritte automatisch, andernfalls müssen sie manuell in OpenWebUI nachgeholt werden.

## Wartung: Reconcile- und Wiederholungslauf-Verhalten

Ein erneuter Upgrade-/Repair-/Audit-Lauf auf einem bereits installierten Ziel ist ein normaler, unterstützter Vorgang. Stand Cutover Runtime 1.6.14 und OpenWebUI Agent Pack 1.9.0:

- **Die Neuerzeugung von Integrations OpenWebUI-mit-Suche-Starter löscht RAGs Embedding-Präfix-Zeile nicht mehr.** Integration erzeugt `Start-KIStack-OpenWebUI-WithSearch.cmd` bei jedem Install-/Upgrade-/Repair-Lauf bedingungslos neu; eine reale Regression löschte zuvor eine bereits eingebundene RAG-Zeile (`call "...\OpenWebUI-RAG.env.cmd"`) still, sobald Integration ohne RAG in derselben Transaktion reconciled wurde. Diese Zeile bleibt jetzt bei jeder Neuerzeugung erhalten.
- **Agent-Pack-Reconcile ersetzt `meta` eines verwalteten Profils nicht mehr pauschal.** OpenWebUIs eigener Modell-Update-Endpunkt ersetzt `meta` statt sie zu mergen; das Agent Pack merged jetzt selbst vor jedem Create/Update, sodass ein live/über die UI ergänzter Wert bei `capabilities`, `builtinTools`, `access_grants` oder `profile_image_url` eines bereits verwalteten Profils einen Reconcile unangetastet übersteht, während nur die tatsächlich paketverwalteten Felder (Name, Basismodell, Systemprompt, Tool-/Knowledge-Bindungen usw.) erneut erzwungen werden.
- **RAG-Re-Import ist idempotent.** Ein erneuter `Execute`-Lauf gegen unveränderte Quellen erzeugt keine Remote-Mutation (`Skip`); nur tatsächlich hinzugefügte, geänderte oder entfernte Quellen werden angefasst.
- **Eine fehlende `ki-stack-research`-Knowledge-Collection führt zu einem kontrollierten Skip, keiner defekten Installation.** Existiert RAGs globale Knowledge-Collection noch nicht, überspringt das Agent Pack die Anlage/Aktualisierung von `ki-stack-research` bei diesem Lauf (nie mit leerer Knowledge-Bindung) und schließt jedes andere verwaltete Profil normal ab; ein anschließender Lauf von RAGs eigenem `Execute` gefolgt von einem erneuten Agent-Pack-Reconcile löst dies auf.

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

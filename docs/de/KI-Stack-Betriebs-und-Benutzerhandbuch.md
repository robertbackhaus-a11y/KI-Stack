# KI-Stack 2.18.1 – Betriebs- und Benutzerhandbuch

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

### Codex Local: Install, Update, Repair, Status

Codex Local umschließt die `@openai/codex`-CLI mit einer eigenen, verwalteten Node.js-Runtime unter `C:\KI-Stack\modules\codex-local` -- keine systemweite Node/npm-Installation, keine globalen PATH-Änderungen. Es unterstützt denselben Install-/Upgrade-/Repair-/Validate-/Rollback-Vertrag wie jede andere isolierte Komponente, plus eine eigene `Status`-Aktion:

- **Install** benötigt einen erreichbaren LM-Studio-Endpunkt (der bestehende, gehärtete Greenfield-Vertrag -- startet LM Studio bei Bedarf selbst über den obigen verwalteten Starter) -- das beweist vor Abschluss, dass die Einrichtung Ende-zu-Ende funktioniert. **Upgrade und Repair einer bereits erfassten Installation benötigen dies nie**: sie gleichen ausschließlich das Codex-Paket selbst ab (Runtime, CLI-Version, Marker), wofür LM Studio in diesem Moment nicht laufen muss.
- **Isoliertes CODEX_HOME**: Codex Local läuft gegen sein eigenes, isoliertes Home unter `C:\KI-Stack\state\codex-local\codex-home` -- niemals das reale, mit jeder anderen Codex-CLI-Nutzung auf der Maschine geteilte `%USERPROFILE%\.codex`. Jeder echte Aufruf (der generierte Starter, `Status`/`Validate`, der Analysis-/Audit-Acceptance-Aufruf und die Codex-Local-Konformitätsprüfung des Complete Installers) setzt `CODEX_HOME` explizit für genau diesen einen Kindprozess; keiner fällt je auf die Umgebungsvariable zurück. Das schließt einen realen, bereits dokumentierten Architekturfund aus dem Greenfield-Cold-Start-Workstream: vorhandener Zustand in einem realen, geteilten `~/.codex` erwies sich als eigentliche Ursache eines reproduzierten Fehl-Downloads des falschen Modells, den die explizite `-m`-Modellfixierung allein nicht zuverlässig verhinderte. Es findet keine Migration aus dem alten, geteilten Ort statt -- eine Greenfield-Installation erhält ein sauberes isoliertes Home, eine bestehende Installation initialisiert eines beim nächsten echten Install/Upgrade/Repair neu; das reale, geteilte `%USERPROFILE%\.codex` (und darin liegende fremde Codex-Sessions/-Konfigurationen/-Credentials) wird nie gelesen, geschrieben oder gelöscht.
- **Preserve-Vertrag**: `C:\KI-Stack\state\codex-local\codex-home\ki-stack-local.config.toml` (Sandbox-/Freigaberichtlinie) und die `AGENTS.md` des Arbeitsbereichs (Agenten-Arbeitsanweisungen) werden nur geschrieben, wenn sie noch nicht existieren -- ein Upgrade oder Repair überschreibt eine handangepasste Kopie nie. Alles andere unter `modules/codex-local` (Node-Runtime, npm-global-Codex-CLI-Installation, Marker, Starter-Skript) ist vollständig verwaltet und wird bei jedem echten Lauf auf den konfigurierten Zielstand abgeglichen.
- **Idempotent**: ein erneuter Install-/Upgrade-/Repair-Lauf gegen eine bereits konforme Installation ist ein schneller No-Op (`SkippedAlreadyCompliant`) -- keine wiederholte npm-/Netzwerkarbeit, keine doppelten Dateien.
- **Backup/Rollback**: jeder echte, nicht übersprungene Lauf sichert die verwalteten Dateien, den Marker und die beiden Preserve-Vertrag-Dateien unter `C:\KI-Stack\backups\codex-local\<Zeitstempel>`, bevor irgendetwas angefasst wird; ein Fehlschlag während dieses Laufs stellt diesen genauen Stand automatisch wieder her.
- **Status** (`Invoke-KIStackCodexLocal.ps1 -Action Status`) liefert `Installed`/`InstalledVersion`/`InstallPath`/`RuntimeReady`/`LMStudioEndpointConfigured`/`Healthy`/`Reason` sowie einen von vier Zuständen: `NotInstalled`, `Broken` (das Codex-Paket selbst ist beschädigt -- fehlende/kaputte verwaltete Dateien), `RuntimeUnavailable` (Codex Local ist korrekt installiert, aber LM Studio ist gerade nicht erreichbar -- nie als beschädigt gewertet) oder `Healthy`. `AvailableVersion`/`VersionStatus` werden hier bewusst nicht neu ermittelt -- der zentrale `Update-KIStack-All.ps1`-Bericht löst diese bereits über dieselbe Registry auf, die jede andere interne Komponente nutzt (siehe Abschnitt oben); Status dupliziert diese Abfrage nie.
- **Einzelkomponenten-Update**: `Update-KIStack-All.ps1 -Component codex-local` betrifft ausschließlich Codex Local -- keine andere Komponente, kein Complete-Installer-Batch, kein Finalizer. Auch dessen Health-Check nach der Aktion benötigt aus demselben Grund wie Upgrade/Repair nie einen erreichbaren LM-Studio-Endpunkt.

### LM Studio + Codex Local: Erstinstallation, First Boot, Recovery, Neustart

- **Erstinstallation.** LM Studio wird über `winget install --id ElementLabs.LMStudio --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity` installiert -- vollständig nicht-interaktiv, kein GUI-Dialog manuell zu bestätigen. Das installiert nur die Anwendung; der API-Server wird dabei noch nicht gestartet, kein Modell ausgewählt.
- **First Boot / Headless-API-Modus.** Der verwaltete Starter (`Start-KIStack-LMStudio.cmd`) bringt den API-Server tatsächlich hoch, beim allerersten Lauf genauso wie bei jedem späteren: Ist die `lms`-CLI noch nicht auflösbar (ein echter First Boot -- `lms` wird erst nach Abschluss der eigenen Ersteinrichtung der LM-Studio-GUI nach `%USERPROFILE%\.lmstudio\bin` geschrieben), startet der Starter einmalig die GUI, wartet bis zu ~90s auf `lms`, führt dann `lms server start --port 1234 --bind 127.0.0.1` aus und bestätigt, dass `GET http://127.0.0.1:1234/v1/models` antwortet, bevor er mit Exitcode 0 endet. Kein manueller GUI-Konfigurationsschritt ist irgendwo in diesem Pfad erforderlich.
- **Modellvertrag.** Das einzige unterstützte Chat-Modell ist `qwen3.6-27b-uncensored-heretic-v2-native-mtp-preserved` (`Contracts/PAYLOADS.json`s `modelPolicy.chatModels`), hinterlegt durch `Qwen3.6-27B-uncensored-heretic-v2-Native-MTP-Preserved-Q5_K_M.gguf` aus einer revisionsgebundenen Hugging-Face-Quelle, vor Aktivierung durch exakte Größe und SHA-256 verifiziert (`Contracts/PAYLOADS.json`s `policy.automaticDownload`/`verifyBeforeActivation`) und in LM Studios eigenem Standard-Modellbaum abgelegt (`%USERPROFILE%\.lmstudio\models\<Publisher>\<Repo>\...`) -- nie in einem separaten KI-Stack-eigenen Modellverzeichnis.
- **Modell-Laden ist real, aber implizit.** Nirgendwo in diesem Repository wird für das Chat-Modell explizit `lms load` aufgerufen, so wie es RAGs eigenes Modul für sein Embedding-Modell tut (`Assert-RAGEmbeddingModelReady` in `KIStackRAG.psm1`) -- das Chat-Modell soll über LM Studios eigenes Just-in-Time-Laden bereit werden, ausgelöst durch die erste echte Inferenzanfrage. Das hat in einem echten, nicht-Greenfield-Test gegen das bereits vorhandene reale Modell auf der eigenen RTX 5090 dieses Projekts zuverlässig funktioniert (siehe Abschlussbericht des Codex-Local-Greenfield-Workstreams), ist aber eine echte, ehrlich dokumentierte Lücke: Codex Locals eigener Health-Check (`Test-KILMStudioEndpoint`) prüft nur, ob `GET /v1/models` überhaupt antwortet, nie ob das konkrete Ziel-Chat-Modell geladen und bereit ist -- ein erreichbares, aber noch nicht geladenes LM Studio meldet weiterhin `Healthy`.
- **RuntimeUnavailable, nie Broken.** Ist LM Studio nicht erreichbar (noch nicht gestartet, noch am Laden, oder tatsächlich nicht installiert), meldet Codex Locals eigener `Status` `RuntimeUnavailable` mit einem Klartextgrund -- nie `Broken`, und nie eine Marker-/Config-Änderung. LM Studio starten und `Status` erneut ausführen (kein Repair, keine Neuinstallation) kehrt von selbst zu `Healthy` zurück.
- **Neustart ist kein Einmalzustand.** LM Studios Server und Codex Locals eigenen (pro Aufruf, nicht dauerhaften) Prozess zu stoppen und beide anschließend über dieselben verwalteten Starter erneut zu starten, erreicht denselben funktionierenden, aufrufbaren Zustand erneut -- in diesem Workstream in der isolierten Fixture-Suite über einen echten Stop-/Restart-Zyklus bewiesen.
- **Umfang des Realnachweises hinter diesem Abschnitt.** Diesem Projekt steht keine entbehrliche Greenfield-VM/-Snapshot zur Verfügung; ein echter "LM Studio war auf dieser Maschine noch nie installiert"-First-Boot-Nachweis wurde deshalb hier nicht erbracht (stattdessen wurde ein real bereits installiertes LM Studio mit einem real bereits heruntergeladenen Modell auf der eigenen Maschine dieses Projekts für einen echten, aber nicht-Greenfield-funktionalen Nachweis verwendet, und die Codex-Local-Seite des Vertrags wurde frisch in einer isolierten Fixture bewiesen). Den exakten, einzeln benannten Grenzverlauf zwischen real Bewiesenem und dokumentierter Lücke enthält der eigene Abschlussbericht des Codex-Local-Greenfield-Workstreams.

## SearXNG, nginx und Valkey

SearXNG ist über nginx unter `/searxng` erreichbar, das auf eine lokale, per `uwsgi` betriebene Instanz proxyt; `valkey-server` stützt den lokalen Ratenlimiter-/Session-Speicher. Der Dienst kann entweder unter dem eigenen `ki-stack-searxng.service` der Cutover-Runtime-Komponente oder unter dem generischen `uwsgi.service` der Integration-Komponente laufen — beide werden als gültige, bereits laufende Installation erkannt. Ist einer davon bereits gesund, übernimmt die Integration-Komponente diesen, statt eine zweite, portkonfliktäre Instanz zu starten.

## OpenWebUI

Der Agent Pack ist `1.9.0`, der Visual Pack `2.0.5`.

Aktuelle Policy der verwalteten Profile:

- `ki-stack-it-technik`: MCP Runtime für lokale Terminal-/Host-Steuerung aktiviert; natives OpenWebUI-Memory aktiviert.
- `ki-stack-allgemein`: MCP Runtime für lokale Terminal-/Host-Steuerung aktiviert; natives OpenWebUI-Memory aktiviert.
- `ki-stack-research`: dynamisch gebundenes lokales RAG-Knowledge, SearXNG-Websuche und isolierter Pyodide-Code-Interpreter; keine MCP-Terminalbindung; natives Memory deaktiviert.
- `ki-stack-18bravo`: Ballistics-Profil mit erhaltener technischer MCP-Bindung; natives Memory deaktiviert.
- `roleplay`: außerhalb der verwalteten Memory-Policy.

Bilder bleiben sichtbarer Chatinhalt. MP4 bleibt nach Reload genau ein persistenter herunterladbarer FileItem über `/api/v1/files/{id}/content`.

## MCP Runtime und Local Control

MCP Runtime `0.1.0` ist der primäre Terminal- und Host-Control-Backendpfad für MCP-fähige KI-Stack-Profile. Er läuft lokal auf `127.0.0.1:8021` über OpenWebUIs MCP-Tool-Server-Mechanismus.

Er stellt die verwaltete Werkzeugoberfläche für Command-Ausführung, Prozesssteuerung, Filesystem-Operationen, Suche und Dateianzeige bereit. KI-Stack 2.16 baut Local Control auf genau dieser Runtime auf, statt einen weiteren Windows-Control-Dienst einzuführen.

Im Betrieb bedeutet das:

- das normale OpenWebUI-Profil verwenden;
- das Profil ruft die registrierten MCP-Tools auf;
- allgemeine Windows-/WSL-/Anwendungsarbeiten verwenden die vorhandene MCP-Oberfläche, insbesondere `run_command`, PowerShell und die KI-Stack-Lifecycle-Skripte;
- es gibt keinen zweiten Local-Control-Port, keine zweite Runtime und kein zusätzliches Credential.

Der MCP Runtime wird vom Complete Installer installiert und reconciled. Seit 2.18 umfasst der zentrale Start (`Start-KIStack.cmd`) auch MCP Runtime: Er wird vor OpenWebUI gestartet und über den vorhandenen MCP-Health-Vertrag geprüft; schlägt das fehl, startet OpenWebUI nicht. Der zentrale Stop stoppt OpenWebUI zuerst, MCP Runtime zuletzt. Ein Zielsystem ohne installierten MCP Runtime ist davon unberührt.

## Native Memory

KI-Stack 2.17 verwendet OpenWebUIs eigenes natives Memory.

Memory-Policy:

- aktiviert: `ki-stack-it-technik`, `ki-stack-allgemein`
- deaktiviert: `ki-stack-18bravo`, `ki-stack-research`
- durch diesen Vertrag nicht verwaltet: `roleplay`

Memory ist benutzerbezogen und liegt in OpenWebUIs `webui.db`. Für denselben authentifizierten Benutzer kann es chat- und profilübergreifend wiederverwendet werden.

Ein Chat/Request muss Memory weiterhin mit `features.memory=true` aktivieren; OpenWebUI 0.11.3 besitzt keinen persistenten serverseitigen Standard für dieses Request-Flag.

Zum Schutz der Datenbank stellt 2.17 bereit:

- Online-SQLite-Backup über `VACUUM INTO`;
- Integritätsprüfung des erzeugten Backups;
- kontrolliertes Restore-Werkzeug;
- verpflichtendes Sicherheitsbackup vor dem Restore;
- WAL-/SHM-Behandlung;
- Health-Verifikation nach dem Restore.

Ein reales Online-Backup der Produktionsdatenbank wurde durchgeführt. Die kontrollierte Restore-Acceptance erfolgte gegen eine temporäre Datenbankkopie; ein Restore der produktiven `webui.db` wurde nicht durchgeführt.

## Open-Terminal-Fallback

Open Terminal `0.1.0` bleibt installiert, unterstützt, über den Lifecycle verwaltet und unter `http://127.0.0.1:8000` verfügbar, ist aber nicht mehr der Standardpfad für Terminal-/Host-Control produktiver MCP-fähiger Profile.

Open Terminal nur noch als ausdrücklichen Fallback- oder Rollback-Pfad verwenden.

Weiterhin genutzt werden:

- die verwaltete KI-Stack-Python-/uv-Runtime;
- der persistente DPAPI-geschützte API-Key;
- begrenzte Readiness-Prüfungen;
- Prozessidentitätsprüfung;
- zentrale KI-Stack-Start-/Stop-/Status-Behandlung.

Wird der Fallback bewusst über OpenWebUIs Legacy-OpenAPI-Tool-Server-Integration verwendet, bleibt dessen Registrierung ein separater expliziter Konfigurationsschritt. Der normale MCP-basierte Betrieb benötigt diese Registrierung nicht.
## OpenWebUI-Credential-Bootstrap

Administrative KI-Stack-Automatisierung verwendet ein zentrales persistentes OpenWebUI-Credential.

`Initialize-KIStackOpenWebUICredential.ps1` führt den einmaligen interaktiven Bootstrap durch:

- fragt das OpenWebUI-Administratorkonto ab;
- meldet sich über OpenWebUIs unterstützte API an;
- aktiviert bei Bedarf die API-Key-Unterstützung;
- erzeugt einen persistenten benutzerbezogenen API-Key;
- validiert den Key, bevor etwas gespeichert wird.

Der Key wird ausschließlich DPAPI-verschlüsselt unter `C:\KI-Stack\state\openwebui\credential.json` gespeichert. Er wird niemals im Klartext im Repository, in Build-Artefakten, Kommandozeilen, Reports oder Logs persistiert.

Spätere Complete-Installer-, Agent-Pack-, RAG-, Knowledge- und Code-Interpreter-Aktionen lösen dasselbe Credential automatisch auf und verwenden es wieder.

Unterstützte Credential-Aktionen:

- Status: `Test-KIStackOpenWebUICredential.ps1`
- Bootstrap/Wiederverwendung: `Initialize-KIStackOpenWebUICredential.ps1`
- Rotation: `Initialize-KIStackOpenWebUICredential.ps1 -Rotate`
- Revoke: `Remove-KIStackOpenWebUICredential.ps1`

Bei Rotation wird der Ersatz validiert, bevor das bisher funktionierende Credential abgelöst wird. Revoke entfernt ausschließlich das KI-Stack-eigene lokale Credential und den zugehörigen Key.

Ist OpenWebUI nicht erreichbar, wird das Credential nicht fälschlich als ungültig gemeldet. Fehlt ein verwendbares Administrator-Credential, werden API-abhängige Arbeiten kontrolliert als Pending/Blocked gemeldet, statt unauthentifiziert fortzufahren.

### Research-Agent-Websuche

`ki-stack-research` wird als Research-Profil mit dynamisch gebundenem lokalem RAG-Knowledge, SearXNG-gestützter Websuche und isoliertem Pyodide-Code-Interpreter verwaltet.

Profilvertrag, Tool-Bindungen und Knowledge-Bindung werden durch den Agent Pack reconciled. Historische Headless-/API-Ausführungspfad-Nachweise früherer OpenWebUI-Versionen bleiben in den jeweiligen Release-Dokumenten erhalten; dieses aktuelle Betriebshandbuch behandelt diese versionsspezifischen früheren Beobachtungen nicht als Betriebsvertrag für OpenWebUI 0.11.3.
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

## Credential-abhängige Finalisierung

Agent Pack, RAG-/Knowledge-Anbindung und Code-Interpreter-Konfiguration verwenden das oben beschriebene zentrale OpenWebUI-Credential.

Mit einem gültig gespeicherten Credential werden diese Schritte im unterstützten Installer-/Reconcile-Ablauf automatisch abgeschlossen.

Fehlt das Credential, ist es ungültig, nicht prüfbar oder besitzt keine Administratorrechte, werden die betroffenen API-abhängigen Arbeiten kontrolliert als Pending/Blocked mit Diagnose gemeldet. Ein separater temporärer Administrator-API-Key gehört nicht mehr zum normalen Betriebsverfahren; stattdessen das zentrale KI-Stack-Credential bootstrappen oder reparieren.

## Wartung: Reconcile- und Wiederholungslauf-Verhalten

Ein erneuter Upgrade-/Repair-/Audit-Lauf auf einem bereits installierten Ziel ist ein normaler, unterstützter Vorgang. Stand Cutover Runtime 1.6.14 und OpenWebUI Agent Pack 1.9.0:

- **Die Neuerzeugung von Integrations OpenWebUI-mit-Suche-Starter löscht RAGs Embedding-Präfix-Zeile nicht mehr.** Integration erzeugt `Start-KIStack-OpenWebUI-WithSearch.cmd` bei jedem Install-/Upgrade-/Repair-Lauf bedingungslos neu; eine reale Regression löschte zuvor eine bereits eingebundene RAG-Zeile (`call "...\OpenWebUI-RAG.env.cmd"`) still, sobald Integration ohne RAG in derselben Transaktion reconciled wurde. Diese Zeile bleibt jetzt bei jeder Neuerzeugung erhalten.
- **Agent-Pack-Reconcile ersetzt `meta` eines verwalteten Profils nicht mehr pauschal.** OpenWebUIs eigener Modell-Update-Endpunkt ersetzt `meta` statt sie zu mergen; das Agent Pack merged jetzt selbst vor jedem Create/Update, sodass ein live/über die UI ergänzter Wert bei `capabilities`, `builtinTools`, `access_grants` oder `profile_image_url` eines bereits verwalteten Profils einen Reconcile unangetastet übersteht, während nur die tatsächlich paketverwalteten Felder (Name, Basismodell, Systemprompt, Tool-/Knowledge-Bindungen usw.) erneut erzwungen werden.
- **RAG-Re-Import ist idempotent.** Ein erneuter `Execute`-Lauf gegen unveränderte Quellen erzeugt keine Remote-Mutation (`Skip`); nur tatsächlich hinzugefügte, geänderte oder entfernte Quellen werden angefasst.
- **Eine fehlende `ki-stack-research`-Knowledge-Collection führt zu einem kontrollierten Skip, keiner defekten Installation.** Existiert RAGs globale Knowledge-Collection noch nicht, überspringt das Agent Pack die Anlage/Aktualisierung von `ki-stack-research` bei diesem Lauf (nie mit leerer Knowledge-Bindung) und schließt jedes andere verwaltete Profil normal ab; ein anschließender Lauf von RAGs eigenem `Execute` gefolgt von einem erneuten Agent-Pack-Reconcile löst dies auf.

## Komponenten-Isolation: Auswahl einer Komponente ist kein Batch

`Update-KIStack-All.ps1 -Component <id>` (eine oder mehrere IDs) löst vor jeder Ausführung einen strukturierten Plan auf: `Resolve-KIStackUpdatePlan` (`Lifecycle/KIStackUpdateIsolation.psm1`) übersetzt die Auswahl in `Selected`, `Dependencies`, `Will update`, `Will preserve` und `Cannot update` und gibt alle fünf vor der Bestätigungsabfrage aus. `-CheckOnly` und ein echter Lauf lösen exakt denselben Plan auf -- ein DryRun zeigt nie ein anderes Ergebnis als das, was Execute tatsächlich täte.

- **Auswahl ≠ Batch.** `openwebui-agent-pack`, `openwebui-visual-pack`, `openwebui-ballistics-pack`, `codex-local`, `rag`, `comfyui`, `models-workflows`, `integration` und `validation-gate` besitzen jeweils einen eigenen, in sich geschlossenen Install-/Backup-/Rollback-Einstiegspunkt (`Invoke-KIStackIsolatedComponentUpdate`) und rufen nie die vollständige Complete-Installer-Transaktion, deren Orchestrator-/Central-Starter-/Operations-Neuaufspielung oder deren bedingungslose Knowledge-Experiment-Rollback-/Code-Interpreter-Schritte auf. Die Auswahl nur einer dieser Komponenten betrifft ausschließlich diese eine Komponente -- alles andere steht unter `Will preserve` und wird weder gelesen noch auf Mutation geprüft noch beschrieben. `comfyui`s isolierter Pfad prüft vor jeder Ausführung erneut, ob eine bereits vorhandene, unterstützte Installation vorliegt, und lässt eine neuere, git-verwaltete ComfyUI-Version unangetastet, statt sie auf die Greenfield-Referenzversion zurückzusetzen.
- **Abhängigkeiten werden benannt, nie stillschweigend aufgelöst.** `rag` benötigt `integration` (es liest und schreibt Integrations OpenWebUI-mit-Suche-Starter neu); ist Integration noch nicht konform, wird es unter `Dependencies` gelistet und, falls es ebenfalls Aktion benötigt, zusätzlich unter `Will update` -- nie stillschweigend übersprungen und nie stillschweigend einem Batch-Lauf zur Behebung überlassen. Da Integration nun selbst isoliert aktualisiert werden kann, läuft `-Component rag` auf einem noch nicht konformen Ziel heute vollständig ohne Complete-Installer-Batch: erst Integration, dann RAG, alles andere unverändert.
- **Komponenten ohne heutigen isolierten Pfad** (die gemeinsame Foundation-/Python-Git-/Applications-/Cutover-Runtime-BuilderKernel-Ausführung sowie Production Recovery und Target Acceptance, die beide keinen eigenständigen Installationspfad besitzen) benötigen weiterhin den Complete-Installer-Batch-Pfad. Die alleinige Auswahl einer davon wird verweigert (`Cannot update`, Modus `Blocked`, Exitcode 1), sobald ein echter Batch-Lauf zusätzlich eine andere, aktuell nicht konforme, in der Auswahl nicht genannte Komponente anfassen würde -- die ausgelassene(n) Komponente(n) werden in der Verweigerung explizit benannt. Entweder alle betroffenen Komponenten explizit benennen, oder `-Component complete-installer` übergeben, um den echten, vollständigen Batch bewusst zu autorisieren -- beides läuft durch.
- **Fehlerisolation.** Sind mehrere Komponenten im selben Lauf geplant und eine schlägt fehl, behalten bereits abgeschlossene Komponenten ihren Status, die fehlgeschlagene wird mit `Failed` und eigenem Detail gemeldet, und jede noch dahinter wartende Komponente wird als `NotRun` gemeldet (nie stillschweigend ausgelassen) statt gestartet zu werden.

## Komponenten-Versionen: Installed, Source und Published sind drei verschiedene Dinge

`Update-KIStack-All.ps1`s Bericht zeigte bislang für jede KI-Stack-eigene Komponente (Agent Pack, Visual Pack, Ballistics Pack, RAG, Codex Local, Models/Workflows, Integration, Validation Gate, Cutover Runtime sowie die darauf reitenden Komponenten) `AvailableVersion=Unknown` -- korrekt für ein echtes externes Upstream-Projekt, aber nicht für eine Komponente, die dieses Projekt selbst versioniert und veröffentlicht. `Lifecycle/KIStackComponentVersionRegistry.psm1`, gesteuert über neue `Contracts/COMPONENTS.json`-Felder (`versionSourceType`, `packageIdentity`, `referenceComponent`), schließt diese Lücke für jede Komponente mit einer echten, belastbaren Quelle.

- **Drei Versionen, nie vermischt.** **InstalledVersion** ist, was die bestehende Probe (`VERSION`-Datei, Manifestfeld oder Installations-Marker) real vom Ziel liest -- unverändert. **SourceVersion** ist, was ein Entwicklungs-Checkout in derselben Datei aktuell in seiner Arbeitskopie stehen hat -- ein rein lokaler, in Arbeit befindlicher Wert, der einem produktiven Ziel nie angezeigt oder von ihm verwendet wird. **AvailableVersion/PublishedVersion** ist, was dieselbe Datei AM Commit liest, den der zuletzt veröffentlichte Complete-Installer-GitHub-Release referenziert -- der tatsächliche, reale Verteilmechanismus für jede dieser Komponenten heute (anhand der eigenen Release-Historie dieses Repositories verifiziert: die vielen Einzelkomponenten-Release-Kanäle wurden eingestellt, sobald der vereinheitlichte Complete-Installer-Release-Zug übernahm, und jede gebündelte Komponentenversion ist seither im Gleichschritt mit ihm gewandert).
- **Warum nicht die Arbeitskopie.** Ein Entwicklungsbranch kann die eigene Version einer Komponente bereits über den zuletzt veröffentlichten Stand hinaus angehoben haben (z. B. Agent Pack `1.9.1` in Arbeit gegenüber tatsächlich veröffentlichtem `1.9.0`). Den Arbeitskopie-Wert einem produktiven Ziel als "verfügbar" zu melden, würde ein Update anbieten, das noch gar nicht existiert. AvailableVersion wird deshalb immer aus dem getaggten Release über GitHubs Raw-Content-API gelesen, nie aus einem lokalen Dateipfad.
- **Nicht jeder veröffentlichte Release ist ein Complete-Installer-Release.** Dieses Repository hat über seine Geschichte hinweg Dutzende Einzelkomponenten-Releases (ComfyUI, Integration, Models/Workflows, OpenWebUI-Packs, Production Recovery, Python/Git, …) unter sehr uneinheitlichen Tag-Namen veröffentlicht. Die Registry nimmt nie an, dass der neueste Tag nach Namen oder Datum relevant ist -- sie sucht gezielt den zuletzt veröffentlichten Release, dessen Assets ein `KI-Stack-Complete-Installer-*.zip` enthalten, und liest dann jede Komponente aus ihrer eigenen Datei innerhalb genau dieses getaggten Commits. Ein Complete-Installer-Release-Versionsnummer (z. B. `2.14.0`) wird nie mit z. B. RAGs Version (`0.4.0`) verwechselt -- jede Komponente bezieht ihren Wert aus ihrer eigenen benannten Datei, nie aus der Versionsangabe des Releases selbst.
- **NewerInstalled / Preserve.** Ist InstalledVersion neuer als die aktuell veröffentlichte AvailableVersion, lautet der Status `NewerInstalled` -- exakt spiegelbildlich zum bestehenden OpenWebUI-/ComfyUI-Preserve-Newer-Supported-Vertrag, nie als Downgrade-Bedarf gedeutet.
- **Offline-Verhalten.** Ist GitHub nicht erreichbar (keine `gh`-CLI, kein Netzwerk, API-Fehler), meldet AvailableVersion `VersionUnavailable` mit einem Klartext-Grund; InstalledVersion wird weiterhin wie geprobt angezeigt, und es wird nie ein Update-Bedarf behauptet oder verneint, wenn die Datengrundlage fehlt. Komponenten, die strukturell nie eine eigene, unabhängige Version hatten (die gemeinsame Foundation-/Python-Git-/Applications-/Cutover-Runtime-Ausführungseinheit sowie Target Acceptance, das auf Production Recovery reitet), melden ebenfalls `VersionUnavailable` -- bewusst, unter Spiegelung des Status der Komponente, in deren Bündel sie tatsächlich mitgeliefert werden; ihre eigene Versionsnummer wird nie gegen eine andersskalierte Referenznummer verglichen.
- **Rein zusätzlich.** Diese Registry ändert nie, was `Update-KIStack-All.ps1` tatsächlich aktualisiert -- diese Entscheidung kommt weiterhin ausschließlich aus dem bestehenden Installed-vs-Pinned-Compliance-Check. `packageAvailableVersion`/`packageVersionSource`/`packageVersionStatus` sind neue, rein informative Berichtsspalten neben den bestehenden.

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
- **Ein OpenWebUI-API-abhängiger Schritt meldet einen Credential-bezogenen Pending-/Blocked-Zustand**: `Test-KIStackOpenWebUICredential.ps1` ausführen. Existiert kein gültiges Credential, dieses mit `Initialize-KIStackOpenWebUICredential.ps1` bootstrappen; nicht auf einen separat gepflegten temporären API-Key zurückfallen.

Die letzte vollständige, erfolgreiche, reale Greenfield-Installation auf einem leeren Zielsystem wurde mit Complete Installer 2.4.0 verifiziert. Die späteren Releases bis 2.18.1 ergänzen Regression-, Paket-, Komponenten-, Upgrade-/Reconcile- und Real-Target-Nachweise, behaupten jedoch keinen neueren vollständigen Windows-Greenfield-Lauf auf einem leeren Zielsystem.

## Bekannte offene Punkte

- **Latenz-Tracing**: Es gibt weiterhin keine dedizierte Ende-zu-Ende-Zeitaufschlüsselung für OpenWebUI-Eingabe -> Prompt-/Tool-Aufbereitung -> LM-Studio-Request -> erstes Token.
- **Memory-Request-Default**: OpenWebUI 0.11.3 besitzt keinen persistenten serverseitigen Standard für `features.memory=true`.
- **Produktionsdatenbank-Restore**: Das Online-Backup von `webui.db` ist real zielsystemvalidiert und das kontrollierte Restore acceptance-getestet; ein Restore der Produktionsdatenbank wurde nicht durchgeführt.
- **GUI-/Desktop-Automation**: Breite grafische Desktop-/Anwendungsautomation liegt außerhalb von 2.18; die kontrollierte Desktop-Control-Schicht ist bewusst schmal und ihre MCP-Anbindung noch nicht aktiviert.
- **Bootstrap-Phase ohne PowerShell 7**: Der Bootstrap-Pfad, der nur verwendet wird wenn PowerShell 7 selbst fehlt, besitzt keine eigene Live-Heartbeat-Anzeige und schreibt stattdessen ein strukturiertes `.bootstrap.jsonl`-Diagnoselog.

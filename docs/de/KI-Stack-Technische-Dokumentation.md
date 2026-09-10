# KI-Stack 2.18.0 – Technische Dokumentation

KI-Stack ist ein transaktionsgesicherter lokaler Windows-KI-Stack. Complete Installer `2.18.0` ist das aktuell veröffentlichte GitHub-Release.

Der Validierungsstand muss nach Umfang getrennt betrachtet werden: Die letzte vollständige physische Greenfield-Installation auf einem leeren Windows-Zielsystem wurde mit 2.4.0 durchgeführt und verifiziert; Complete Installer 2.10.0 bleibt der dokumentierte Referenzlauf für Gesamt-Regression plus reales Zielsystem. Spätere Releases ergänzten weitere reale Zielsystem-, Komponenten-, Upgrade-/Reconcile-, Security- und Paketvalidierungen, ohne damit einen neueren vollständigen Windows-Greenfield-Lauf auf einem leeren Zielsystem zu behaupten.

Die aktuelle 2.18-Architektur umfasst den mit 2.15 eingeführten MCP Runtime als primären Terminal-/Host-Control-Pfad für MCP-fähige Profile, autonomes Local Control auf genau dieser Runtime seit 2.16 sowie natives persistentes OpenWebUI-Memory einschließlich Datenbank-Backup-/Restore-Schutz seit 2.17. Open Terminal bleibt installiert und als ausdrücklicher Fallback-/Rollback-Pfad unterstützt. 2.18 ergänzt darauf die zentral verwaltete Windows-UI-Automation-Basis WinApp `0.6.1` und die kontrollierte semantische UIA-Schicht Desktop Control `0.1.0`.

## Aktive Komponenten

| Komponente | Version |
|---|---:|
| Foundation / Runtime | 1.0.9 |
| Python / Git | 1.1.5 |
| ComfyUI | 1.2.4 |
| Models / Workflows | 2.0.3 |
| Applications | 1.4.11 |
| Integration | 1.5.11 |
| Cutover Runtime | 1.6.14 |
| Codex Local | 0.2.1 |
| RAG | 0.4.0 |
| MCP Runtime | 0.1.0 |
| Open Terminal | 0.1.0 |
| WinApp | 0.6.1 |
| Desktop Control | 0.1.0 |
| Production Recovery | 1.7.0-r7 |
| Validation Gate | 1.0.3 |
| Target Acceptance | 1.0.10 |
| OpenWebUI Visual Pack | 2.0.5 |
| OpenWebUI Agent Pack | 1.9.0 |
| Complete Installer | 2.18.0 |

Referenz- und Mindestversion von ComfyUI für reproduzierbare Neuinstallationen und Reconcile ist `v0.34.0`; eine bestehende, unterstützte neuere Installation bleibt erhalten und wird nie automatisch zurückgestuft. `ReferenceVersion` und `MinimumSupportedVersion` von Open WebUI sind beide `0.11.3` -- jede installierte Version ab `0.11.3` wird unterstützt, und eine bestehende, unterstützte neuere Installation bleibt ebenso erhalten, nie automatisch auf exakt die Referenz zurückgestuft.

OpenWebUI Agent Pack `1.9.0` verwaltet `ki-stack-it-technik`, `ki-stack-allgemein` und `ki-stack-research`. MCP-fähige Produktionsprofile verwenden den MCP Runtime dort, wo Terminal-/Host-Control erlaubt ist. `ki-stack-research` besitzt bewusst keine MCP-Terminalbindung und kombiniert dynamisch gebundenes lokales RAG-Knowledge, SearXNG-Websuche und den isolierten Pyodide-Code-Interpreter. Natives OpenWebUI-Memory ist für `ki-stack-it-technik` und `ki-stack-allgemein` aktiviert und für `ki-stack-research` deaktiviert; der Ballistics Pack hält Memory für `ki-stack-18bravo` deaktiviert. Reconcile erhält zulässige live/UI-gepflegte Metadaten sowie KI-Stack-MCP-Bindungen, statt sie stillschweigend zu entfernen. RAG `0.4.0` stellt globale und isolierte projektbezogene Knowledge-Collections bereit.

Heretic ist das einzige auswählbare Chat-LLM. Nomic dient ausschließlich Embeddings. Z-Image verwendet nur `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`. Die visuelle Ausführung ist auf Z-Image Turbo und WAN2.2 T2V 14B mit beiden High-/Low-LightX2V-4-Step-LoRAs begrenzt.


## Modellbeschaffung

Das zentrale versionierte Manifest enthält revisionsgebundene Quellen, Dateinamen, Größen und SHA-256-Werte. Zuerst wird ein gültiges installiertes Ziel wiederverwendet, danach ein optionaler geprüfter Cache/Preload. Fehlende Dateien werden automatisch in den Transaktionszustand geladen und, sofern unterstützt, per Range fortgesetzt. Die atomare Aktivierung erfolgt erst nach vollständiger Größen- und SHA-256-Prüfung. Netzwerkausfälle bleiben fortsetzbar; falsche Größe oder falscher Hash schlägt fehl.

Git und Complete-Installer-ZIP enthalten keine Modellgewichte. Preloads sind optional und keine Installationsvoraussetzung.


## SearXNG, nginx und Valkey

SearXNGs lokaler Suchendpunkt läuft unter `uwsgi` hinter einem `nginx`-Reverse-Proxy unter `/searxng`, gestützt durch `valkey-server` als lokalen Cache-/Ratenlimiter-Speicher. Für diesen Dienst existieren zwei unabhängige Installationspfade:

- Die Cutover-Runtime-Komponente kann einen eigenen, dedizierten `ki-stack-searxng.service`-systemd-Unit installieren.
- Die Integration-Komponente kann den generischen `uwsgi.service`-Unit installieren (der eigene `apps-enabled`-Mechanismus des Debian-Pakets).

Beide gelten als gleichwertig gültiges Signal einer bereits laufenden SearXNG-Instanz. Bevor einer der beiden Pfade eine Neuinstallation durchführt, prüft er direkt gegen das lokale Backend; antwortet dort bereits eine gesunde Instanz, wird diese übernommen und keine zweite, portkonfliktäre Installation gestartet.


## LM Studio und Codex Local

LM Studio wird über `winget` installiert; sein lokaler API-Server wird dabei nicht mitgestartet. Der verwaltete Starter `Start-KIStack-LMStudio.cmd` (erzeugt unter `C:\KI-Stack\modules\applications`) löst LM Studios `lms`-CLI auf — entweder bereits im `PATH`/unter `%USERPROFILE%\.lmstudio\bin`, oder, bei einem allerersten Lauf, indem er einmalig die GUI startet und begrenzt darauf wartet, dass `lms` dort nach LM Studios eigener Ersteinrichtung erscheint — und startet anschließend den lokalen API-Server, wobei er vor der Rückkehr bestätigt, dass dieser unter `http://127.0.0.1:1234/v1/models` antwortet.

Codex Local benötigt genau diesen Endpunkt. Der Complete Installer ruft den LM-Studio-Starter unmittelbar vor der Konfiguration des Codex-Local-Profils auf, damit der Endpunkt rechtzeitig bereitsteht; ist er nach dem begrenzten Warten weiterhin nicht erreichbar, schlägt der Schritt mit einer klaren Fehlermeldung fehl, statt stillschweigend fortzufahren.


## MCP Runtime und Local Control

MCP Runtime `0.1.0`, eingeführt mit KI-Stack 2.15, ist eine eigenständige Complete-Installer-Komponente und der primäre Terminal-/Host-Control-Backendpfad für MCP-fähige OpenWebUI-Profile. Er läuft lokal auf `127.0.0.1:8021` über OpenWebUIs standardisierten MCP-Tool-Server-Mechanismus und stellt zwölf validierte Werkzeuge für Command-Ausführung, Prozesssteuerung, Filesystem-Operationen, Suche und Dateianzeige bereit.

KI-Stack 2.16 ergänzt Local Control auf genau dieser vorhandenen Runtime. Bewusst entstehen kein zweiter Windows-Control-Dienst, kein zusätzlicher Port und kein zusätzliches Credential. Windows-, WSL-, Prozess-, Filesystem-, Service-, Registry-, Task- und Anwendungssteuerung verwendet die vorhandene MCP-Oberfläche, insbesondere `run_command`, PowerShell und die bestehenden KI-Stack-Lifecycle-Skripte.


## Desktop Control und WinApp

WinApp `0.6.1` ist die zentral verwaltete Windows-UI-Automation-Basis. Desktop Control `0.1.0` kapselt diese Basis als kontrollierte semantische UIA-Schicht darauf.

Jede Desktop-Control-Anfrage folgt dem festen Ablauf Resolve -> Validate -> Act -> Re-observe -> Verify. Vor jeder Aktion wird das Ziel eindeutig aufgelöst (genau ein Fenster, genau ein Element); Policy-, Interactability- und Secret-Context-Prüfungen greifen davor. Mutierende Operationen gelten nur dann als erfolgreich, wenn eine unabhängige Postcondition bestätigt ist -- ein CLI-Exitcode allein genügt nicht.

Nicht freigegeben sind rohe Keyboard-/Mouse-Injection, beliebige oder ungekapselte WinApp-Ausführung sowie nicht verifizierte Backend-Fähigkeiten.

Der Complete Installer integriert WinApp und Desktop Control in Reconciliation und Payload-Parity. Es entsteht kein neuer Dienst, kein neuer Port, kein neues Credential und keine neue Windows-Control-Service-Instanz. Die MCP-Anbindung von Desktop Control ist in 2.18 bewusst noch nicht aktiviert.

## Native Memory

KI-Stack 2.17 verwendet OpenWebUIs eigenes lokales natives Memory und führt weder einen KI-Stack-spezifischen Memory-Service noch ein separates Vector-/Datenbank-Backend ein.

Profilpolitik:

- Memory aktiviert: `ki-stack-it-technik`, `ki-stack-allgemein`
- Memory deaktiviert: `ki-stack-18bravo`, `ki-stack-research`
- `roleplay`: außerhalb der verwalteten Memory-Policy

Memory liegt in OpenWebUIs `webui.db`, ist benutzerbezogen und kann für denselben authentifizierten Benutzer chat- und profilübergreifend wiederverwendet werden. Die Chat-/Request-Aktivierung hängt weiterhin von `features.memory=true` ab; OpenWebUI 0.11.3 bietet keinen persistenten serverseitigen Standard für dieses Request-Flag.

2.17 ergänzt außerdem ein Online-SQLite-Datenbankbackup über `VACUUM INTO`, verpflichtende Integritätsprüfung sowie kontrolliertes Restore mit Sicherheitsbackup vor dem Restore, WAL-/SHM-Behandlung und anschließender Health-Verifikation. Ein reales Online-Backup der Produktionsdatenbank wurde durchgeführt. Die Restore-Acceptance erfolgte gegen eine kontrollierte temporäre Datenbankkopie; ein Restore der Produktionsdatenbank wurde nicht durchgeführt.


## Open Terminal

Open Terminal `0.1.0` bleibt eine eigenständige, vollständig unterstützte Complete-Installer-Komponente. Seit 2.15 ist es jedoch nicht mehr die Standardintegration für Terminal-/Host-Control produktiver MCP-fähiger Profile; der MCP Runtime ist der primäre Pfad.

Open Terminal bleibt als ausdrücklicher Fallback- und Rollback-Pfad unter `http://127.0.0.1:8000` verfügbar. Es verwendet die verwaltete Python-/uv-Runtime, einen eigenen persistenten DPAPI-geschützten API-Key, begrenzte Readiness-Prüfungen, Prozessidentitätsprüfung sowie den zentralen KI-Stack-Start-/Stop-/Status-Lifecycle.

Wird dieser Fallback über OpenWebUIs Legacy-OpenAPI-Tool-Server-Pfad verwendet, bleibt dafür eine separate explizite Registrierung erforderlich. Der normale MCP-basierte KI-Stack-Betrieb hängt von dieser Registrierung nicht ab.

## Transaktionen und OpenWebUI

Installation und Upgrade verwenden Komponentenplanung, begrenzte Backups, protokollierten Zustand, realen Versions-Readback, Resume, Recovery und Rollback. Eine Komponente wird erst nach erfolgreichem Deployment und Readback als abgeschlossen gespeichert. Rollback betrifft ausschließlich die aktive Transaktion. Eine erstmalige WSL2-Aktivierung kann einen Windows-Neustart erfordern; der Installer bricht dann mit Exitcode `31` ab, was fortsetzbar ist und keinen Rollback auslöst.

Für die OpenWebUI-Visual-/Agent-Verwaltung kann ein temporärer Administrator-API-Key verdeckt als `SecureString` abgefragt werden. Er wird nur im Arbeitsspeicher verwendet, nicht in Berichte, State, Kommandozeilen oder Umgebungsdateien geschrieben und soll anschließend widerrufen werden. Ohne diesen Key bleiben der Rollback des temporären Knowledge-Bootstrap-Experiments und die Konfiguration der Code-Interpreter-Verbindung manuelle Nacharbeit (`CredentialRequiredForApiReadback` / `CredentialRequiredForApiConfiguration`).

MP4 bleibt genau ein persistenter Dateianhang über das native `files`-Event und `/api/v1/files/{id}/content`.


## Validierungsumfang

Die Validierungsnachweise werden bewusst danach getrennt, was tatsächlich ausgeführt wurde:

- **2.4.0**: letzte vollständige physische Greenfield-Installation auf einem leeren Windows-Zielsystem einschließlich WSL2-/Debian-Foundation, ComfyUI, LM Studio mit verwaltetem lokalem Serverstart, SearXNG, Codex Local und RAG.
- **2.10.0**: dokumentierter Gesamt-Regressionstest plus realer Zielsystemlauf auf einem bestehenden System. Die Complete-Installer-/Cutover-Runtime-Transaktion wurde erfolgreich abgeschlossen, unterstützte ComfyUI- und OpenWebUI-Installationen blieben erhalten und LM Studio war nach der Transaktion weiterhin erreichbar. Siehe `docs/releases/complete-installer-v2.10.0.md`.
- **2.13.0**: deterministische Source-/Paketvalidierung plus zusätzliche reale Zielsystemnachweise: OpenWebUI-Credential-Bootstrap, Codex Local `0.2.1` mit isoliertem `CODEX_HOME` und realem Login -> Starter -> `codex exec` sowie ein realer SearXNG-gestützter Websuche-Tool-Calling-Nachweis für `ki-stack-research`.
- **2.14.0**: realer Complete-Installer-Lauf gegen ein bestehendes Zielsystem mit tatsächlich installiertem Open Terminal, sichtbarem Heartbeat im erhöhten Lauf und anschließendem `SkippedAlreadyCompliant`; deterministischer Build und PackageSelfTest wurden ebenfalls bestätigt.
- **2.15.0**: MCP Foundation real auf dem Zielsystem validiert, einschließlich MCP-Bindungen der produktiven Profile, realer MCP-Tool-Aufrufe, Rollback-/Fallback-Verhalten, Credential-Synchronisierung und korrigierter Cutover-Runtime-Compliance-Erkennung.
- **2.16.0**: reale Local-Control-Validierung auf Basis des vorhandenen MCP Runtime, einschließlich Filesystem-, Prozess-, Working-Directory-, Windows-Abfrage-, Anwendungssteuerungs- und Ballistics-MCP-Binding-Preservation-Verhalten.
- **2.17.0**: reale Native-Memory-Add/Search/Delete-Acceptance, Agent-Pack-Memory-/Profil-Policy-Validierung, reales Online-Backup von `webui.db` bei weiter gesundem OpenWebUI sowie kontrollierte Restore-Acceptance gegen eine temporäre Datenbankkopie. Repository-Regression: 34/34 PASS.
- **2.18.0**: reale Desktop-Control-Ende-zu-Ende-Validierung für `list_windows`, `inspect_window`, `find_element`, `get_properties`, `get_value`, `wait_for`, `set_value` (inklusive unabhängigem Readback), `invoke` (inklusive erneuter Tree-Beobachtung) und `focus` (inklusive Focus-Readback) sowie Reconcile-, Repair-, Idempotenz- und Payload-Parity-Nachweise. Kein breiter MCP-Integrationsclaim.

Diese Umfänge sind kumulative Nachweise und keine austauschbaren Gesamtfreigaben. Insbesondere wurde nach 2.4.0 kein neuer vollständiger Windows-Greenfield-Lauf auf einem leeren Zielsystem behauptet oder durchgeführt; ebenso wurde in 2.17 kein Restore der produktiven `webui.db` durchgeführt.

## Bekannte offene Punkte

- **Latenz-Tracing**: Es gibt weiterhin keine dedizierte Ende-zu-Ende-Zeitaufschlüsselung für OpenWebUI-Eingabe -> Prompt-/Tool-Aufbereitung -> LM-Studio-Request -> erstes Token. Der in 2.15 ergänzte LM-Studio-Runtime-Baseline-Check ersetzt kein vollständiges Tracing.
- **Memory-Request-Default**: OpenWebUI 0.11.3 besitzt keinen persistenten serverseitigen Standard für `features.memory=true`.
- **Produktionsdatenbank-Restore**: Das Online-Backup von `webui.db` ist real zielsystemvalidiert und das kontrollierte Restore acceptance-getestet; ein Restore der Produktionsdatenbank wurde nicht durchgeführt.
- **Desktop-Control-MCP-Anbindung**: Die MCP-Anbindung von Desktop Control ist noch nicht aktiviert; nicht freigegebene oder noch nicht produktionsvalidierte UIA-Fähigkeiten bleiben außerhalb des Vertrags.
- **Bootstrap-Phase ohne PowerShell 7**: `Bootstrap-KIStackPowerShell7.ps1`, nur verwendet wenn PowerShell 7 selbst fehlt, besitzt weiterhin keine eigene Live-Heartbeat-Anzeige und schreibt stattdessen sein strukturiertes `.bootstrap.jsonl`-Diagnoselog.

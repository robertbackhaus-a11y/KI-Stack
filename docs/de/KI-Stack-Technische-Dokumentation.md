# KI-Stack 2.14.0 – Technische Dokumentation

KI-Stack ist ein transaktionsgesicherter lokaler Windows-KI-Stack. Complete Installer `2.14.0` ist der aktuelle Repository-/Entwicklungsstand (noch nicht als GitHub-Release veröffentlicht); `2.12.0` ist das zuletzt tatsächlich veröffentlichte GitHub-Release. Complete Installer 2.10.0 bleibt der letzte durchgängig regressions- und zielsystemvalidierte Gesamtstand (siehe `docs/releases/complete-installer-v2.10.0.md`), und die letzte vollständige, physische Greenfield-Installation auf einem leeren Zielsystem wurde in einem früheren Zyklus (2.4.0) durchgeführt und verifiziert. 2.13.0 selbst bringt jedoch mehrere echte, neue Real-Target-Nachweise gegenüber 2.12.0: ein realer Codex-Local-Login→Upgrade→Starter→`codex exec`-Ende-zu-Ende-Lauf, eine reale OpenWebUI-Credential-Bootstrap-Validierung (Admin-Login, API-Key, DPAPI-Store) und ein realer Websuche-Nachweis für `ki-stack-research` -- kein vollständiger Windows-Greenfield-Nachweis (bewusst für `2.15` vorgemerkt), aber deutlich mehr echte Zielsystem-Abdeckung als 2.12.0. Seitdem, auf demselben, weiterhin unveröffentlichten Entwicklungsstand, wurde Open Terminal `0.1.0` als reale, zielsystemvalidierte Complete-Installer-Komponente integriert (siehe „Open Terminal" unten), und der Live-Heartbeat des Installers, die Transcript-Live-Filterung, die einmalige finale Ergebniszusammenfassung sowie die Schema-Stabilität von `centralStarters` in der Transaktion wurden korrigiert und real zielsystemgeprüft. Siehe "Validierungsumfang" unten.

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
| Open Terminal | 0.1.0 |
| Production Recovery | 1.7.0-r7 |
| Validation Gate | 1.0.3 |
| Target Acceptance | 1.0.10 |
| OpenWebUI Visual Pack | 2.0.5 |
| OpenWebUI Agent Pack | 1.9.0 |
| Complete Installer | 2.14.0 |

Referenz- und Mindestversion von ComfyUI für reproduzierbare Neuinstallationen und Reconcile ist `v0.34.0`; eine bestehende, unterstützte neuere Installation bleibt erhalten und wird nie automatisch zurückgestuft. `ReferenceVersion` und `MinimumSupportedVersion` von Open WebUI sind beide `0.11.3` -- jede installierte Version ab `0.11.3` wird unterstützt, und eine bestehende, unterstützte neuere Installation bleibt ebenso erhalten, nie automatisch auf exakt die Referenz zurückgestuft.

OpenWebUI Agent Pack `1.9.0` fügt ein drittes verwaltetes Profil hinzu, `ki-stack-research`: ein Referenz-Research-Agent, der eine dynamisch gebundene lokale RAG-Knowledge-Collection mit Websuche und isoliertem Pyodide-Code-Interpreter kombiniert, ohne Extension-Tools, mit explizit verweigertem `terminal` und jeder weiteren ungenutzten nativen Capability -- für keines der verwalteten Profile existiert Shell-, Host-Dateisystem- oder Administrationszugriff. Ein Reconcile auf ein bereits verwaltetes Profil merged `meta` jetzt statt sie zu ersetzen, sodass live/über die UI ergänzte Werte bei `capabilities`, `builtinTools`, `access_grants` oder `profile_image_url` einen Reconcile überstehen. RAG `0.4.0` fügt projektbezogene Knowledge-Collections neben dem bestehenden globalen Scope hinzu, jede isoliert auf ihre eigene OpenWebUI-Knowledge-Collection abgebildet.

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

## Open Terminal

Open Terminal `0.1.0` ist eine eigenständige („Isolation A") Complete-Installer-Komponente, installiert/aktualisiert/repariert/übersprungen genauso wie Codex Local: eigener Einstiegspunkt `Invoke-KIStackOpenTerminal.ps1`, eigenes Backup/Rollback, eigene Versionsprobe (`modules/open-terminal/installation.json`). Es läuft über `uvx open-terminal run --host 127.0.0.1 --port 8000 --cwd <verwalteter-Workspace>` (uvs eigenes `tool run`-Kürzel), deterministisch aufgelöst unter `C:\KI-Stack\python` -- zuerst das verwaltete Konsolen-Script, sonst `python.exe -m uv`, und nur als letzter Ausweg ein bloßes `uv`/`uv.exe` im `PATH` -- niemals die bloße Annahme, ein unverwaltetes `uvx` sei einfach vorhanden. Die Prozessidentität wird über PID plus einen realen `Win32_Process`-Commandline-Abgleich geprüft (nie eine bloße PID-Prüfung, da PIDs vom Betriebssystem wiederverwendet werden), bevor Stop überhaupt etwas beendet -- ein fremder Prozess kann dadurch nie betroffen sein. Die Authentifizierung nutzt einen einzigen, 256 Bit langen Zufalls-API-Key, einmalig erzeugt und DPAPI-verschlüsselt (`ConvertFrom-SecureString`, benutzerbezogen) unter `C:\KI-Stack\state\open-terminal\credential.json` abgelegt -- erst beim Start in die Umgebung des Kindprozesses aufgelöst, nie im Klartext in eine Datei, ein Skript oder ein Log geschrieben. Die Bereitschaftsprüfung ist ein begrenztes Warten gegen `http://127.0.0.1:8000/openapi.json`, nie eine unbegrenzte Schleife. Start/Stop/Status sind zusätzlich in die eigenen Wurzel-Kommandos des Complete Installers eingehängt (`Start-KIStack.cmd`/`Stop-KIStack.cmd`/`Get-KIStackStatus.ps1`), sodass es wie jede andere verwaltete Komponente ohne separaten Workflow startet, stoppt und gemeldet wird. OpenWebUI bleibt das alleinige benutzerseitige Frontend; die Anbindung von OpenWebUI selbst erfordert weiterhin eine einmalige manuelle OpenAPI-Tool-Server-Registrierung (siehe Betriebshandbuch).

## Transaktionen und OpenWebUI

Installation und Upgrade verwenden Komponentenplanung, begrenzte Backups, protokollierten Zustand, realen Versions-Readback, Resume, Recovery und Rollback. Eine Komponente wird erst nach erfolgreichem Deployment und Readback als abgeschlossen gespeichert. Rollback betrifft ausschließlich die aktive Transaktion. Eine erstmalige WSL2-Aktivierung kann einen Windows-Neustart erfordern; der Installer bricht dann mit Exitcode `31` ab, was fortsetzbar ist und keinen Rollback auslöst.

Für die OpenWebUI-Visual-/Agent-Verwaltung kann ein temporärer Administrator-API-Key verdeckt als `SecureString` abgefragt werden. Er wird nur im Arbeitsspeicher verwendet, nicht in Berichte, State, Kommandozeilen oder Umgebungsdateien geschrieben und soll anschließend widerrufen werden. Ohne diesen Key bleiben der Rollback des temporären Knowledge-Bootstrap-Experiments und die Konfiguration der Code-Interpreter-Verbindung manuelle Nacharbeit (`CredentialRequiredForApiReadback` / `CredentialRequiredForApiConfiguration`).

MP4 bleibt genau ein persistenter Dateianhang über das native `files`-Event und `/api/v1/files/{id}/content`.

## Validierungsumfang

Der 2.10.0-Release wurde regressionsgetestet und anschließend auf einem realen, bestehenden (nicht Greenfield-)Zielsystem validiert: die Complete-Installer-/Cutover-Runtime-Transaktion wurde erfolgreich abgeschlossen, ComfyUIs bestehende, unterstützte Installation `v0.34.0` blieb erhalten statt auf die Referenzversion `v0.28.0` zurückgesetzt zu werden, Open WebUIs bestehende Installation `0.11.1` blieb ebenso erhalten, und LM Studios lokaler API-Server war nach dem Lauf weiterhin unter `http://127.0.0.1:1234/v1/models` erreichbar, ohne den konkurrierenden Windows-Autostart-Eintrag. Der vollständige Real-Target-Nachweis steht in `docs/releases/complete-installer-v2.10.0.md`. Die letzte vollständige, physische Greenfield-Installation auf einem leeren Zielsystem — WSL2/Debian-Foundation-Einrichtung, ComfyUI, LM Studio mit automatischem Serverstart, SearXNG-Dienstübernahme, Codex Local und RAG — wurde in einem früheren Zyklus (2.4.0) durchgeführt und verifiziert; keine funktionale Änderung seitdem entwertet diesen Installationspfad.

Zuletzt schloss ein realer Complete-Installer-Lauf gegen ein bestehendes, bereits eingerichtetes Zielsystem mit Gesamtstatus `Completed` und Exitcode `0` ab, mit durchgehend sichtbarem Live-Heartbeat: Open Terminal wurde real installiert, und ein Folgelauf gegen dasselbe Zielsystem meldete es korrekt als `SkippedAlreadyCompliant`.

## Bekannte offene Punkte

- **Latenzanalyse**: noch keine technische Aufschlüsselung des realen Anfragewegs OpenWebUI-Eingang → Prompt-/Tool-Aufbereitung → LM-Studio-Request → erstes Token.
- **Automatische OpenWebUI-Tool-Server-Registrierung**: Open Terminal erfordert weiterhin eine einmalige manuelle Registrierung unter OpenWebUIs eigenen Admin-Einstellungen → Tools; dies ist noch nicht automatisiert.
- **Bootstrap-Phase ohne PowerShell 7**: `Bootstrap-KIStackPowerShell7.ps1` (nur relevant, wenn PowerShell 7 selbst fehlt) hat keine eigene Live-Heartbeat-Darstellung -- es schreibt nur ein strukturiertes `.bootstrap.jsonl`-Diagnoseprotokoll. Bekannte, akzeptierte Lücke, kein 2.14-Blocker.

Die Validierung von 2.13.0 kombiniert einen quellcodebasierten Build (deterministischer Doppelbuild, bytegleicher ZIP-/Sidecar-/SBOM-Root-SHA256, SPDX 2.3, frisch extrahierter PackageSelfTest) mit mehreren echten Real-Target-Läufen, die 2.12.0 noch fehlten: (1) ein echter OpenWebUI-Credential-Bootstrap (einmaliger Admin-Login, echter API-Key, DPAPI-Store, reale Statusvalidierung); (2) ein echtes Codex-Local-`0.2.1`-Upgrade mit isoliertem `CODEX_HOME` und ein realer Login→Starter→`codex exec`-Ende-zu-Ende-Lauf; (3) ein realer Websuche-Nachweis für `ki-stack-research` (Modell fordert `search_web`/`fetch_url` korrekt an, echte SearXNG-Quellen, echte finale Antwort) -- mit präzise dokumentierter Grenze bei OpenWebUIs eigener automatischer Hintergrundausführung für Nicht-Browser-Aufrufer, kein Agent-Pack- oder Modell-Defekt. Kein Credential wird jemals aus einer Datenbank extrahiert oder im Repository gespeichert. Ein vollständiger frischer Windows-Greenfield-Nachweis bleibt bewusst für `2.15` vorgemerkt.

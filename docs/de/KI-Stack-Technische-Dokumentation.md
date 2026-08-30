# KI-Stack 2.12.0 – Technische Dokumentation

KI-Stack ist ein transaktionsgesicherter lokaler Windows-KI-Stack. Complete Installer `2.12.0` ist der aktuelle Repository-/Entwicklungsstand (noch nicht als GitHub-Release veröffentlicht); Complete Installer 2.10.0 bleibt der letzte durchgängig regressions- und zielsystemvalidierte Stand (siehe `docs/releases/complete-installer-v2.10.0.md`), und die letzte vollständige, physische Greenfield-Installation auf einem leeren Zielsystem wurde in einem früheren Zyklus (2.4.0) durchgeführt und verifiziert. Die Validierung von 2.12.0 selbst ist quellcodebasiert plus gemockte HTTP-Regressionsabdeckung sowie ein deterministischer Doppelbuild-/PackageSelfTest-Nachweis -- siehe "Validierungsumfang" unten.

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
| Codex Local | 0.1.4 |
| RAG | 0.4.0 |
| Production Recovery | 1.7.0-r7 |
| Validation Gate | 1.0.3 |
| Target Acceptance | 1.0.10 |
| OpenWebUI Visual Pack | 2.0.5 |
| OpenWebUI Agent Pack | 1.9.0 |
| Complete Installer | 2.12.0 |

Referenzversion von ComfyUI für reproduzierbare Neuinstallationen ist `v0.28.0`; eine bestehende, unterstützte neuere Installation (z. B. `v0.34.0`) bleibt erhalten und wird nie automatisch zurückgestuft. `ReferenceVersion` von Open WebUI ist `0.11.1`, `MinimumSupportedVersion` ist `0.11.0` -- jede installierte Version ab `0.11.0` wird unterstützt, und eine bestehende, unterstützte neuere Installation bleibt ebenso erhalten, nie automatisch auf exakt die Referenz zurückgestuft.

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

## Transaktionen und OpenWebUI

Installation und Upgrade verwenden Komponentenplanung, begrenzte Backups, protokollierten Zustand, realen Versions-Readback, Resume, Recovery und Rollback. Eine Komponente wird erst nach erfolgreichem Deployment und Readback als abgeschlossen gespeichert. Rollback betrifft ausschließlich die aktive Transaktion. Eine erstmalige WSL2-Aktivierung kann einen Windows-Neustart erfordern; der Installer bricht dann mit Exitcode `31` ab, was fortsetzbar ist und keinen Rollback auslöst.

Für die OpenWebUI-Visual-/Agent-Verwaltung kann ein temporärer Administrator-API-Key verdeckt als `SecureString` abgefragt werden. Er wird nur im Arbeitsspeicher verwendet, nicht in Berichte, State, Kommandozeilen oder Umgebungsdateien geschrieben und soll anschließend widerrufen werden. Ohne diesen Key bleiben der Rollback des temporären Knowledge-Bootstrap-Experiments und die Konfiguration der Code-Interpreter-Verbindung manuelle Nacharbeit (`CredentialRequiredForApiReadback` / `CredentialRequiredForApiConfiguration`).

MP4 bleibt genau ein persistenter Dateianhang über das native `files`-Event und `/api/v1/files/{id}/content`.

## Validierungsumfang

Der 2.10.0-Release wurde regressionsgetestet und anschließend auf einem realen, bestehenden (nicht Greenfield-)Zielsystem validiert: die Complete-Installer-/Cutover-Runtime-Transaktion wurde erfolgreich abgeschlossen, ComfyUIs bestehende, unterstützte Installation `v0.34.0` blieb erhalten statt auf die Referenzversion `v0.28.0` zurückgesetzt zu werden, Open WebUIs bestehende Installation `0.11.1` blieb ebenso erhalten, und LM Studios lokaler API-Server war nach dem Lauf weiterhin unter `http://127.0.0.1:1234/v1/models` erreichbar, ohne den konkurrierenden Windows-Autostart-Eintrag. Der vollständige Real-Target-Nachweis steht in `docs/releases/complete-installer-v2.10.0.md`. Die letzte vollständige, physische Greenfield-Installation auf einem leeren Zielsystem — WSL2/Debian-Foundation-Einrichtung, ComfyUI, LM Studio mit automatischem Serverstart, SearXNG-Dienstübernahme, Codex Local und RAG — wurde in einem früheren Zyklus (2.4.0) durchgeführt und verifiziert; keine funktionale Änderung seitdem entwertet diesen Installationspfad.

Die Validierung von 2.12.0 selbst ist ein quellcodebasierter Build: deterministischer Doppelbuild (bytegleicher ZIP-/Sidecar-/SBOM-Root-SHA256, SPDX 2.3) und ein frisch extrahierter PackageSelfTest (28/28), plus gemockte HTTP-Regressionssuiten für die neuen/geänderten Verträge (Provisionierung und Knowledge-Bindung von `ki-stack-research`, der Agent-Pack-Reconcile-Feldeigentümer-/Preserve-Vertrag mit Negativkontrolle, RAG-Projekt-Scope-Trennung, der Integration-RAG-Starter-Preservation-Fix). Für 2.12.0 wurde kein neuer Real-Target-Lauf durchgeführt; ein echter, authentifizierter Multi-Step-Chat-End-zu-End-Nachweis für `ki-stack-research` erfordert speziell einen extern bereitgestellten OpenWebUI-Administrator-API-Key -- eine bekannte Automatisierungs-/Bootstrap-Grenze, kein Funktionsfehler (kein Credential wird jemals aus der Datenbank extrahiert oder im Repository gespeichert).

> Aktuelle Produktionsabnahme: `production-target-acceptance-v1.0.10`

# KI-Stack – Deutsch

Der KI-Stack ist ein modularer und transaktionsgesicherter Windows-Installer für PowerShell 7, Git, Python, ComfyUI, Modelle, LM Studio, Open WebUI, WSL und SearXNG.

Projektseite und begleitende Artikel: [okami.de – Lokaler KI-Stack](https://www.okami.de/projekte/lokaler-ki-stack-sprachmodelle-bilder-videos-und-rag-auf-einem-system/)

## Freigabestand

| Baustein | Version | Status |
|---|---:|---|
| Foundation / Runtime | 1.0.9 | Stabiler Referenzstand, auf Zielsystem validiert |
| Python / Git | 1.1.5 | Stabil, auf Zielsystem validiert |
| ComfyUI | 1.2.4 | Stabile Komponente; transaktionaler Marker/Readback. Referenz-/Mindestversion `v0.34.0` für reproduzierbare Neuinstallationen und Reconcile; eine bestehende, unterstützte neuere Installation bleibt erhalten und wird nie automatisch zurückgestuft |
| Modelle / Workflows | 2.0.3 | Automatischer revisionsgebundener Modelldownload einschließlich Nomic Q4_K_M mit optionalem geprüftem Cache/Preload |
| Applications | 1.4.11 | Stabil; LM Studio (konkurrierender Electron-Autostart wird vor *und* nach dem Serverstart entfernt) und Open WebUI (`ReferenceVersion`/`MinimumSupportedVersion` `0.11.3`; jede installierte Version ab `0.11.3` wird unterstützt, eine neuere unterstützte Installation bleibt immer erhalten und wird nie automatisch zurückgestuft) |
| Integration | 1.5.11 | Stabile Komponente; feste SearXNG-Revision plus getracktes Overlay; der bei jedem Reconcile neu erzeugte OpenWebUI-mit-Suche-Starter erhält jetzt eine bereits eingebundene RAG-Embedding-Präfix-Umgebungszeile, statt sie stillschweigend zu löschen |
| Cutover Runtime | 1.6.14 | Stabile Komponente; transaktionslokaler Fortsetzungszustand; zielsystemvalidierter ComfyUI-Supported-Version-Vertrag, Schutz gegen v0.28.0-Payload-Overlay, der Open-WebUI-`0.11.1`-Referenzversions-Bump und der Integration-RAG-Starter-Preservation-Fix oben (siehe `docs/releases/complete-installer-v2.10.0.md` für die fortgeführten ComfyUI-/Applications-Korrekturen) |
| Production Recovery | 1.7.0-r7 | Auf dem Zielsystem akzeptiert; SearXNG-Kaltstart repariert |
| Universeller Paket-Validation-Gate | 1.0.3 | Auf dem Zielsystem aktiviert |
| Production Target Acceptance | 1.0.10 | `TARGET_SYSTEM_ACCEPTANCE_PASSED` am 21.07.2026 |
| OpenWebUI Agent Pack | 1.9.0 | Stabil; drei Heretic-Profile (`ki-stack-it-technik`, `ki-stack-allgemein` und der neue Referenz-Research-Agent `ki-stack-research`, der dynamisch gebundenes lokales RAG-Wissen mit Websuche, isoliertem Pyodide-Code-Interpreter und ohne Shell-/Host-/Administrationszugriff kombiniert) mit Visual-Pack-2.0.5-Bindung; Reconcile merged `meta` jetzt statt sie zu ersetzen, sodass live/über die UI ergänzte `capabilities`-/`builtinTools`-/`access_grants`-/`profile_image_url`-Werte auf bereits verwalteten Profilen einen erneuten Lauf unverändert überstehen |
| OpenWebUI Visual Pack | 2.0.5 | Stabil; Z-Image- und WAN2.2-Tools mit persistenten MP4-Anhängen |
| OpenWebUI Ballistics Pack | 1.0.0 | Stabil; `18Bravo` und Solver zielsystemvalidiert |
| Codex Local | 0.2.1 | Stabile Komponente; eigenes, isoliertes `CODEX_HOME` (nie mehr das geteilte `%USERPROFILE%\.codex`), real zielsystemvalidiert per Login→Upgrade→Starter→`codex exec`-Ende-zu-Ende-Lauf |
| RAG | 0.4.0 | Stabile Komponente; Add/Replace/Remove (plus Skip für bereits aktuelle Quellen) und Rollback von Add/Replace/Remove sind real zielsystemvalidiert; neu hinzugekommen sind projektbezogene Knowledge-Collections neben dem bestehenden globalen Scope, jede auf eine eigene, isolierte OpenWebUI-Knowledge-Collection abgebildet |
| MCP Runtime | 0.1.0 | Stabiler primärer Terminal-/Host-Control-Backendpfad für MCP-fähige OpenWebUI-Profile; lokaler Streamable-HTTP-Endpunkt auf `127.0.0.1:8021`, zwölf Command-/Process-/Filesystem-Tools, DPAPI-geschütztes Credential, Verwaltung über den Complete Installer |
| Open Terminal | 0.1.0 | Stabile Komponente; lokaler Tool-/Terminal-Backend-Dienst für OpenWebUI (Filesystem, PowerShell, WSL, Git, Prozess-/Command-Ausführung) unter `http://127.0.0.1:8000`, kein Docker; gestartet über den bestehenden, bereits verwalteten KI-Stack-Python/uv-Vertrag (deterministische Auflösung des verwalteten Pfads, nie ein blindes PATH-Lookup); authentifiziert über einen einzigen persistenten, DPAPI-geschützten lokalen API-Key (nie im Repository, nie geloggt, über Neustarts hinweg unverändert wiederverwendet); Install/Upgrade/Repair/Skip über den Complete Installer, Start/Stop/Status über dieselben zentralen KI-Stack-Lifecycle-Kommandos wie jede andere Komponente; real zielsystemvalidiert, einschließlich eines echten Complete-Installer-Laufs, der es beim zweiten Durchlauf korrekt als `SkippedAlreadyCompliant` meldete. Die Anbindung an OpenWebUI selbst erfordert weiterhin eine einmalige manuelle Tool-Server-Registrierung (siehe „Open Terminal" unten) |
| Complete Installer | 2.17.0 | Aktuell veröffentlichtes GitHub-Release `v2.17.0`. Enthält die MCP Foundation aus 2.15, autonomes Local Control aus 2.16 und natives persistentes OpenWebUI-Memory aus 2.17; außerdem Component Isolation, interne Komponentenversions-Registry, automatische Release Attestation, sicheren OpenWebUI-Credential-Bootstrap, Codex Local `0.2.1`, RAG `0.4.0`, unterstützten Open-Terminal-Fallback, deterministische Builds, PackageSelfTest und die bis zu diesem Release validierten Installer-/Reconciliation-Härtungen. |
| System Cleanup Audit | 1.0.0 | Audit abgeschlossen; Bereinigungsplan wartet auf ausdrückliche Freigabe |

Vollständige Paketquellen liegen im Verzeichnis `package`. Fertige ZIP-Pakete werden als GitHub-Release-Artefakte veröffentlicht und nicht dauerhaft in die normale Git-Historie aufgenommen.

## Dokumentation

- **[Start here: installation guide](docs/en/KI-Stack-Installation-Guide.md)**
- **[Hier beginnen: Installationsanleitung](docs/de/KI-Stack-Installationsanleitung.md)**
- [Technical documentation (English)](docs/en/KI-Stack-Technical-Documentation.md)
- [Technische Dokumentation (Deutsch)](docs/de/KI-Stack-Technische-Dokumentation.md)
- [Operations and user guide (English)](docs/en/KI-Stack-Operations-and-User-Guide.md)
- [Betriebs- und Benutzerhandbuch (Deutsch)](docs/de/KI-Stack-Betriebs-und-Benutzerhandbuch.md)
- [Manual model provisioning (English)](docs/en/KI-Stack-Manual-Model-Provisioning.md)
- [Manuelle Modellbereitstellung (Deutsch)](docs/de/KI-Stack-Manuelle-Modellbereitstellung.md)
- [ComfyUI model download guide (English)](docs/en/KI-Stack-Model-Download-Guide.md)
- [ComfyUI-Modell-Downloadanleitung (Deutsch)](docs/de/KI-Stack-Modell-Downloadanleitung.md)

Jedes Paket enthält Selbsttest, Dry-Run, Execute, Transaktionsprotokollierung, Diagnose und Rollback. Neue Pakete müssen sämtliche bekannten und bereits behobenen Fehler als Regressionstests abdecken.

`tools/system-cleanup/current` inventarisiert ausschließlich lesend und klassifiziert konservativ. Der erzeugte Bereinigungsplan ist per SHA256 gebunden und ohne getrennte ausdrückliche Freigabe nicht ausführbar; Version 1.0.0 löscht nichts.

Production Recovery `1.7.0-r7` ist eine Wiederherstellungslinie und keine neue Runtime-Version; r5 bleibt als veröffentlichter Vorgänger dokumentiert. Die aktuelle Cutover-Runtime-Version ist `1.6.14` (siehe Tabelle oben und `docs/releases/complete-installer-v2.10.0.md`).

## Produktionswiederherstellung und Zielsystemabnahme

Das Repository enthält vollständige wiederverwendbare Quellen für Production Recovery `1.7.0-r7`, Universal Package Validation Gate `1.0.2` und Production Target Acceptance `1.0.10`. ZIP-Binärdateien bleiben GitHub-Release-Artefakte und werden über explizite Artefaktverträge referenziert. Der veröffentlichte r5-Stand bleibt als akzeptierter Vorgänger dokumentiert.

Gesamtstatus: `TARGET_SYSTEM_ACCEPTANCE_PASSED`.

## OpenWebUI Agent Pack

Das OpenWebUI Agent Pack `1.9.0` verwaltet die KI-Stack-Workspace-Profile über die unterstützte HTTP-API von OpenWebUI. Die aktuelle Profilpolitik unterscheidet bewusst nach Rolle:

- `ki-stack-it-technik` und `ki-stack-allgemein` verwenden den MCP Runtime für lokale Terminal-/Host-Steuerung und haben natives OpenWebUI-Memory aktiviert.
- `ki-stack-18bravo` verwendet den MCP Runtime, soweit dies für den technischen Workflow erforderlich ist; natives Memory bleibt jedoch deaktiviert. Das Speichern von Ballistics-Profilen behält den expliziten Bestätigungsvertrag.
- `ki-stack-research` kombiniert dynamisch gebundenes lokales RAG-Knowledge, SearXNG-Websuche und einen isolierten Pyodide-Code-Interpreter; bewusst keine MCP-Terminalbindung und natives Memory deaktiviert.
- `roleplay` liegt außerhalb des verwalteten Memory-Vertrags und bleibt durch die 2.17-Memory-Arbeit ansonsten unverändert.

Der Agent-Pack-Reconcile stellt paketverwaltete Einstellungen wieder her und erhält gleichzeitig fremde/live in OpenWebUI gepflegte Metadaten dort, wo der Ownership-Vertrag dies vorsieht. MCP-Bindungen der KI-Stack-Control-Architektur überstehen spätere Reconcile-Läufe und werden nicht mehr stillschweigend entfernt.

## MCP Runtime und Local Control

MCP Runtime `0.1.0`, eingeführt mit KI-Stack 2.15, ist der primäre Terminal- und Host-Control-Pfad für MCP-fähige Profile. Er läuft lokal auf `127.0.0.1:8021` über OpenWebUIs standardisierten MCP-Tool-Server-Mechanismus und stellt die validierte Oberfläche für Commands, Prozesse, Filesystem, Suche und Dateianzeige bereit.

KI-Stack 2.16 baut Local Control auf genau diesem vorhandenen MCP Runtime auf und führt keinen zweiten Windows-Control-Dienst ein. Allgemeine Windows-, WSL-, Prozess-, Datei-, Service-, Registry-, Task- und Anwendungssteuerung verwendet die vorhandenen MCP-Tools, `run_command`, PowerShell und die bestehenden KI-Stack-Lifecycle-Skripte. Es gibt dafür keinen zusätzlichen Local-Control-Port, kein zusätzliches Credential und keine zusätzliche Runtime.

## Native Memory

KI-Stack 2.17 verwendet OpenWebUIs eigenes lokales natives Memory und führt keinen zusätzlichen Memory-Service sowie kein separates Vector-/Datenbank-Backend ein.

Memory-Policy:

- aktiviert: `ki-stack-it-technik`, `ki-stack-allgemein`
- deaktiviert: `ki-stack-18bravo`, `ki-stack-research`
- durch diesen Vertrag nicht verwaltet: `roleplay`

Memory liegt in OpenWebUIs `webui.db`, ist benutzerbezogen und kann für denselben authentifizierten Benutzer chat- und profilübergreifend wiederverwendet werden. Die Aktivierung auf Chat-/Request-Ebene hängt weiterhin von OpenWebUIs `features.memory=true` ab, da OpenWebUI 0.11.3 keinen persistenten serverseitigen Standardwert für dieses Request-Flag bereitstellt.

Der 2.17-Datenbankschutz ergänzt ein Online-SQLite-Backup über `VACUUM INTO`, Integritätsprüfung sowie kontrolliertes Restore mit Sicherheitsbackup vor dem Restore, WAL-/SHM-Behandlung und anschließender Health-Verifikation. Ein reales Online-Backup der Produktionsdatenbank wurde durchgeführt; ein Restore der Produktionsdatenbank wurde nicht durchgeführt.

## Open Terminal

Open Terminal `0.1.0` bleibt vollständig installiert, unterstützt, über den zentralen Lifecycle verwaltet und ausführbar, ist seit KI-Stack 2.15 jedoch nicht mehr der Standardpfad für Terminal-/Host-Control der produktiven MCP-fähigen Profile. Der MCP Runtime ist der primäre Pfad.

Open Terminal bleibt als ausdrücklicher Fallback- und Rollback-Pfad erhalten. Der Dienst läuft lokal unter `http://127.0.0.1:8000`, verwendet die verwaltete Python-/uv-Runtime und authentifiziert über einen eigenen persistenten, DPAPI-geschützten lokalen API-Key. Install/Upgrade/Repair/Skip sowie zentrale Start-/Stop-/Status-Behandlung bleiben unterstützt.

Wird der Open-Terminal-Fallback bewusst über OpenWebUIs Legacy-OpenAPI-Tool-Server-Pfad verwendet, bleibt dessen Registrierung ein separater expliziter Konfigurationsschritt. Der normale MCP-basierte KI-Stack-Betrieb hängt davon nicht ab.

## Bekannte offene Punkte

- **Latenz-Tracing**: Eine vollständige technische Zeitaufschlüsselung von OpenWebUI-Eingabe -> Prompt-/Tool-Aufbereitung -> LM-Studio-Request -> erstes Token ist weiterhin nicht als eigenes Tracing-Verfahren implementiert. Der in 2.15 ergänzte LM-Studio-Runtime-Baseline-Check deckt nur eine zuvor identifizierte latenzrelevante Einstellung ab und ersetzt kein Ende-zu-Ende-Tracing.
- **Memory-Request-Default**: OpenWebUI 0.11.3 besitzt keinen persistenten serverseitigen Standard für `features.memory=true`; Memory hängt deshalb weiterhin von der Chat-/Request-seitigen Aktivierung ab.
- **OpenWebUI-Datenbankoperationen**: Das Online-Backup ist real auf dem Zielsystem validiert und das kontrollierte Restore gegen eine temporäre Datenbankkopie acceptance-getestet; ein Restore der produktiven `webui.db` wurde nicht durchgeführt.
- **GUI-/Desktop-Automation**: Breite grafische Desktop-/Anwendungsautomation liegt außerhalb von 2.17 und ist für die nächste Architekturstufe vorgesehen.

## Supply-Chain-Sicherheit

`main` ist geschützt und akzeptiert Änderungen über Pull Requests mit verpflichtenden Gitleaks-, PSScriptAnalyzer-, Bandit- und CodeQL-Prüfungen. CI-Actions sind auf vollständige Commit-SHAs gepinnt und Payloadverträge prüfen SHA256-Werte inhaltsbasiert. Jedes Release stellt eine SPDX-2.3-SBOM und GitHub-verifizierbare Build-Attestierungen bereit; der Meldeweg steht in [SECURITY.md](SECURITY.md).

KI-Stack verwendet geschützte Änderungen, verpflichtende statische Sicherheitsprüfungen, inhaltsbasierte SHA256-Verträge, veröffentlichte SBOMs und überprüfbare Build-Attestierungen. Diese Nachweise reduzieren Supply-Chain-Risiken, ersetzen jedoch keine unabhängige Sicherheitsprüfung und stellen keine Garantie für Fehler- oder Backdoorfreiheit dar.

```powershell
gh attestation verify .\<release>.zip --repo robertbackhaus-a11y/KI-Stack
gh attestation verify .\<release>.zip --repo robertbackhaus-a11y/KI-Stack --predicate-type https://spdx.dev/Document/v2.3
```

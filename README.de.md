> Aktuelle Produktionsabnahme: `production-target-acceptance-v1.0.10`

# KI-Stack – Deutsch

Der KI-Stack ist ein modularer und transaktionsgesicherter Windows-Installer für PowerShell 7, Git, Python, ComfyUI, Modelle, LM Studio, Open WebUI, WSL und SearXNG.

## Freigabestand

| Baustein | Version | Status |
|---|---:|---|
| Foundation / Runtime | 1.0.9 | Stabiler Referenzstand, auf Zielsystem validiert |
| Python / Git | 1.1.5 | Stabil, auf Zielsystem validiert |
| ComfyUI | 1.2.4 | Stabile Komponente; transaktionaler Marker/Readback. Referenzversion `v0.28.0` für reproduzierbare Neuinstallationen; eine bestehende, unterstützte neuere Installation (z. B. `v0.34.0`) bleibt erhalten und wird nie automatisch zurückgestuft |
| Modelle / Workflows | 2.0.3 | Automatischer revisionsgebundener Modelldownload einschließlich Nomic Q4_K_M mit optionalem geprüftem Cache/Preload |
| Applications | 1.4.11 | Stabil; LM Studio (konkurrierender Electron-Autostart wird vor *und* nach dem Serverstart entfernt) und Open WebUI (`ReferenceVersion` `0.11.1`, `MinimumSupportedVersion` `0.11.0`; jede installierte Version ab `0.11.0` wird unterstützt, eine neuere unterstützte Installation bleibt immer erhalten und wird nie automatisch zurückgestuft) |
| Integration | 1.5.11 | Stabile Komponente; feste SearXNG-Revision plus getracktes Overlay; der bei jedem Reconcile neu erzeugte OpenWebUI-mit-Suche-Starter erhält jetzt eine bereits eingebundene RAG-Embedding-Präfix-Umgebungszeile, statt sie stillschweigend zu löschen |
| Cutover Runtime | 1.6.14 | Stabile Komponente; transaktionslokaler Fortsetzungszustand; zielsystemvalidierter ComfyUI-Supported-Version-Vertrag, Schutz gegen v0.28.0-Payload-Overlay, der Open-WebUI-`0.11.1`-Referenzversions-Bump und der Integration-RAG-Starter-Preservation-Fix oben (siehe `docs/releases/complete-installer-v2.10.0.md` für die fortgeführten ComfyUI-/Applications-Korrekturen) |
| Production Recovery | 1.7.0-r7 | Auf dem Zielsystem akzeptiert; SearXNG-Kaltstart repariert |
| Universeller Paket-Validation-Gate | 1.0.3 | Auf dem Zielsystem aktiviert |
| Production Target Acceptance | 1.0.10 | `TARGET_SYSTEM_ACCEPTANCE_PASSED` am 21.07.2026 |
| OpenWebUI Agent Pack | 1.9.0 | Stabil; drei Heretic-Profile (`ki-stack-it-technik`, `ki-stack-allgemein` und der neue Referenz-Research-Agent `ki-stack-research`, der dynamisch gebundenes lokales RAG-Wissen mit Websuche, isoliertem Pyodide-Code-Interpreter und ohne Shell-/Host-/Administrationszugriff kombiniert) mit Visual-Pack-2.0.5-Bindung; Reconcile merged `meta` jetzt statt sie zu ersetzen, sodass live/über die UI ergänzte `capabilities`-/`builtinTools`-/`access_grants`-/`profile_image_url`-Werte auf bereits verwalteten Profilen einen erneuten Lauf unverändert überstehen |
| OpenWebUI Visual Pack | 2.0.5 | Stabil; Z-Image- und WAN2.2-Tools mit persistenten MP4-Anhängen |
| OpenWebUI Ballistics Pack | 1.0.0 | Stabil; `18Bravo` und Solver zielsystemvalidiert |
| Codex Local | 0.1.4 | Stabile Komponente |
| RAG | 0.4.0 | Stabile Komponente; Add/Replace/Remove (plus Skip für bereits aktuelle Quellen) und Rollback von Add/Replace/Remove sind real zielsystemvalidiert; neu hinzugekommen sind projektbezogene Knowledge-Collections neben dem bestehenden globalen Scope, jede auf eine eigene, isolierte OpenWebUI-Knowledge-Collection abgebildet |
| Complete Installer | 2.12.0 | Aktueller Repository-/Entwicklungsstand, noch nicht als GitHub-Release veröffentlicht: bündelt die obigen Cutover-Runtime-, Agent-Pack- und RAG-Bumps (neuer Referenz-Agent `ki-stack-research`, Agent-Pack-Reconcile-Feldeigentümervertrag/Preserve-Fix, RAG-Projekt-Scoping, Integration-RAG-Starter-Preservation-Fix). Deterministischer Doppelbuild und PackageSelfTest (28/28) gegen diesen Stand erneut bestätigt. 2.10.0 (`KI-Stack-Complete-Installer-v2.10.0.zip`) bleibt das zuletzt veröffentlichte [GitHub Release](https://github.com/robertbackhaus-a11y/KI-Stack/releases/tag/2.10.0); siehe `docs/releases/complete-installer-v2.10.0.md` und `docs/releases/complete-installer-v2.10.1.md` für dessen vollständigen Funktionsumfang bzw. das nachfolgende 2.10.1-Wartungs-Update. |
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


## Applications v1.4.0-rc1

LM Studio and Open WebUI 0.10.2 are delivered as the sixth transaction-protected Execute module.


## Applications v1.4.3-rc1

Fixes StrictMode-safe LM Studio detection and exposes exact transaction failure causes.


## Applications v1.4.9-rc1

Setzt die Git-Autoridentität vor Commit und annotiertem Tag repository-lokal, ohne die globale Git-Konfiguration zu verändern.

## Produktionswiederherstellung und Zielsystemabnahme

Das Repository enthält vollständige wiederverwendbare Quellen für Production Recovery `1.7.0-r7`, Universal Package Validation Gate `1.0.2` und Production Target Acceptance `1.0.10`. ZIP-Binärdateien bleiben GitHub-Release-Artefakte und werden über explizite Artefaktverträge referenziert. Der veröffentlichte r5-Stand bleibt als akzeptierter Vorgänger dokumentiert.

Gesamtstatus: `TARGET_SYSTEM_ACCEPTANCE_PASSED`.

## OpenWebUI Agent Pack

Das OpenWebUI Agent Pack `1.9.0` verwaltet drei Workspace-Modelle -- `KI & IT-Technik`, `Allgemein` und den Referenz-Research-Agenten `ki-stack-research` -- über die unterstützte HTTP-API von OpenWebUI (`ReferenceVersion` `0.11.1`; `MinimumSupportedVersion` `0.11.0`; jede neuere unterstützte Installation bleibt erhalten und wird nie automatisch zurückgestuft). `KI & IT-Technik`/`Allgemein` aktivieren nur den eingebauten browserlokalen Pyodide-Code-Interpreter und erhalten ausschließlich die registrierte Image-Pack-/Visual-Pack-Toolbindung; `execute_code` ist keine Workspace-Tool-ID. `ki-stack-research` bindet stattdessen genau eine dynamisch aufgelöste lokale RAG-Knowledge-Collection plus Websuche, hat keinerlei Extension-Tools gebunden und verweigert explizit `terminal` sowie jede weitere ungenutzte native Capability -- für keines der verwalteten Profile existiert Shell-, Host-Dateisystem- oder Administrationszugriff. Ein Reconcile auf ein bereits bestehendes Profil merged `meta` jetzt statt sie zu ersetzen: nur paketverwaltete Felder (`toolIds`, `knowledge` sofern vertraglich paketeigen, der Prompt usw.) werden erneut erzwungen, während jeder andere live/über die UI ergänzte Wert bei `capabilities`, `builtinTools`, `access_grants` oder `profile_image_url` unangetastet bleibt. Die Provisionierung erfordert einen echten, von aussen bereitgestellten OpenWebUI-Administrator-API-Key (nie aus der Datenbank extrahiert, nie im Repository gespeichert) -- eine bekannte Automatisierungs-/Bootstrap-Grenze, kein Funktionsfehler; Reconcile, Idempotenz und Knowledge-Bindung sind davon unabhängig über gemockte HTTP-Regressionstests verifiziert.

Das OpenWebUI Image Pack `1.10.0` verwaltet weiterhin genau das kanonische Tool `ki-stack-generate-image` über die lokale ComfyUI 1.2.2. Die bestehende FLUX2-Methode `generate_image` bleibt erhalten; `generate_pony_image` ergänzt Pony SDXL mit 1024 × 1024, CLIP Skip 2, 40 Schritten, CFG 3.1, `euler` und `normal`. Beide Wege speichern Bilder direkt im OpenWebUI-Chat. Das Pack lädt keine Modelle; der Pony-Checkpoint muss bereits installiert sein. Pony-Workflow und Chat-Ausgabe wurden auf dem Zielsystem praktisch geprüft, ohne damit eine vollständige Zielsystemvalidierung von 1.10.0 zu behaupten.

Das OpenWebUI Ballistics Pack `1.0.0` ergänzt ausschließlich das technische Profil `18Bravo` mit `ki_stack_ballistics_calculator`. Der fest gepinnte `pyballistic`-2.2.0-RK4-Kern rechnet G1/G7 ohne Git, kompilierte Solver-Erweiterungen, SciPy-Engine oder Diagrammerweiterungen. Pflichtwerte müssen vollständig explizit sein; Profile werden nur nach Bestätigung gespeichert. Der Umfang ist auf rechtmäßige sportliche, jagdliche und technische Nutzung beschränkt.

## Supply-Chain-Sicherheit

`main` ist geschützt und akzeptiert Änderungen über Pull Requests mit verpflichtenden Gitleaks-, PSScriptAnalyzer-, Bandit- und CodeQL-Prüfungen. CI-Actions sind auf vollständige Commit-SHAs gepinnt und Payloadverträge prüfen SHA256-Werte inhaltsbasiert. Jedes Release stellt eine SPDX-2.3-SBOM und GitHub-verifizierbare Build-Attestierungen bereit; der Meldeweg steht in [SECURITY.md](SECURITY.md).

KI-Stack verwendet geschützte Änderungen, verpflichtende statische Sicherheitsprüfungen, inhaltsbasierte SHA256-Verträge, veröffentlichte SBOMs und überprüfbare Build-Attestierungen. Diese Nachweise reduzieren Supply-Chain-Risiken, ersetzen jedoch keine unabhängige Sicherheitsprüfung und stellen keine Garantie für Fehler- oder Backdoorfreiheit dar.

```powershell
gh attestation verify .\<release>.zip --repo robertbackhaus-a11y/KI-Stack
gh attestation verify .\<release>.zip --repo robertbackhaus-a11y/KI-Stack --predicate-type https://spdx.dev/Document/v2.3
```

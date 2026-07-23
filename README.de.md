> Aktuelle Produktionsabnahme: `production-target-acceptance-v1.0.10`

# KI-Stack – Deutsch

Der KI-Stack ist ein modularer und transaktionsgesicherter Windows-Installer für PowerShell 7, Git, Python, ComfyUI, Modelle, LM Studio, Open WebUI, WSL und SearXNG.

## Freigabestand

| Baustein | Version | Status |
|---|---:|---|
| Foundation / Runtime | 1.0.9 | Stabiler Referenzstand, auf Zielsystem validiert |
| Python / Git | 1.1.5 | Stabil, auf Zielsystem validiert |
| ComfyUI | 1.2.2 | Stabil; Git-freier Inhaltsvertrag auf dem Zielsystem validiert |
| Modelle / Workflows | 1.4.6 | Zentraler transaktionssicherer Import externer Modelle, UAC-/Resume-Einstiege und Lizenzierung |
| Applications | 1.4.10 | Stabil; LM Studio und Open WebUI 0.10.2 auf dem Zielsystem akzeptiert |
| Integration | 1.5.9 | Stabil; Git-freies SearXNG-Payload und reparierter Lebenszyklus zielsystemvalidiert |
| Cutover Runtime | 1.6.3 | Akzeptierter Runtime-Basisstand |
| Production Recovery | 1.7.0-r7 | Auf dem Zielsystem akzeptiert; SearXNG-Kaltstart repariert |
| Universeller Paket-Validation-Gate | 1.0.2 | Auf dem Zielsystem aktiviert |
| Production Target Acceptance | 1.0.10 | `TARGET_SYSTEM_ACCEPTANCE_PASSED` am 21.07.2026 |
| OpenWebUI Agent Pack | 1.8.3 | Zielsystemvalidiert; eingebauter Pyodide-Code-Interpreter für Allgemein und KI & IT-Technik |
| OpenWebUI Image Pack | 1.9.2 | Stabil; direkte FLUX2-Erzeugung zielsystemvalidiert |
| OpenWebUI Ballistics Pack | 1.0.0 | Stabil; `18Bravo` und Solver zielsystemvalidiert |
| Complete Installer | 2.2.6 | Erzwingt alle acht externen Modelle vor Models-/Workflows-Konformität; zweisprachige Dokumentation enthalten |
| System Cleanup Audit | 1.0.0 | Audit abgeschlossen; Bereinigungsplan wartet auf ausdrückliche Freigabe |

Vollständige Paketquellen liegen im Verzeichnis `package`. Fertige ZIP-Pakete werden als GitHub-Release-Artefakte veröffentlicht und nicht dauerhaft in die normale Git-Historie aufgenommen.

## Dokumentation

- **[Start here: installation guide](docs/en/KI-Stack-Installation-Guide.md)**
- **[Hier beginnen: Installationsanleitung](docs/de/KI-Stack-Installationsanleitung.md)**
- [Technical documentation (English)](docs/en/KI-Stack-Technical-Documentation.md)
- [Technische Dokumentation (Deutsch)](docs/de/KI-Stack-Technische-Dokumentation.md)
- [Operations and user guide (English)](docs/en/KI-Stack-Operations-and-User-Guide.md)
- [Betriebs- und Benutzerhandbuch (Deutsch)](docs/de/KI-Stack-Betriebs-und-Benutzerhandbuch.md)

Jedes Paket enthält Selbsttest, Dry-Run, Execute, Transaktionsprotokollierung, Diagnose und Rollback. Neue Pakete müssen sämtliche bekannten und bereits behobenen Fehler als Regressionstests abdecken.

`tools/system-cleanup/current` inventarisiert ausschließlich lesend und klassifiziert konservativ. Der erzeugte Bereinigungsplan ist per SHA256 gebunden und ohne getrennte ausdrückliche Freigabe nicht ausführbar; Version 1.0.0 löscht nichts.


Die Repository-Runtime bleibt Cutover `1.6.3`. Production Recovery `1.7.0-r7` ist eine Wiederherstellungslinie und keine neue Runtime-Version; r5 bleibt als veröffentlichter Vorgänger dokumentiert.


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

Das OpenWebUI Agent Pack `1.8.3` verwaltet ausschließlich die Workspace-Modelle `KI & IT-Technik` und `Allgemein` über die unterstützte HTTP-API von OpenWebUI 0.10.2. Es aktiviert nur den eingebauten browserlokalen Pyodide-Code-Interpreter und erhält ausschließlich die registrierte Image-Pack-Toolbindung. `execute_code` ist keine Workspace-Tool-ID.

Das OpenWebUI Image Pack `1.9.2` verwaltet genau das kanonische Tool `ki-stack-generate-image` für direkte Bilderzeugung mit dem bestehenden FLUX2-Klein-Workflow über ComfyUI 1.2.2. OpenWebUI 0.10.2 bindet dafür intern die zwingend identifier-sichere ID `ki_stack_generate_image`. Das Pack lädt keine Modelle und ergänzt keine KREA- oder Pony-Abhängigkeit.

Das OpenWebUI Ballistics Pack `1.0.0` ergänzt ausschließlich das technische Profil `18Bravo` mit `ki_stack_ballistics_calculator`. Der fest gepinnte `pyballistic`-2.2.0-RK4-Kern rechnet G1/G7 ohne Git, kompilierte Solver-Erweiterungen, SciPy-Engine oder Diagrammerweiterungen. Pflichtwerte müssen vollständig explizit sein; Profile werden nur nach Bestätigung gespeichert. Der Umfang ist auf rechtmäßige sportliche, jagdliche und technische Nutzung beschränkt.

## Supply-Chain-Sicherheit

`main` ist geschützt und akzeptiert Änderungen über Pull Requests mit verpflichtenden Gitleaks-, PSScriptAnalyzer-, Bandit- und CodeQL-Prüfungen. CI-Actions sind auf vollständige Commit-SHAs gepinnt und Payloadverträge prüfen SHA256-Werte inhaltsbasiert. Jedes Release stellt eine SPDX-2.3-SBOM und GitHub-verifizierbare Build-Attestierungen bereit; der Meldeweg steht in [SECURITY.md](SECURITY.md).

KI-Stack verwendet geschützte Änderungen, verpflichtende statische Sicherheitsprüfungen, inhaltsbasierte SHA256-Verträge, veröffentlichte SBOMs und überprüfbare Build-Attestierungen. Diese Nachweise reduzieren Supply-Chain-Risiken, ersetzen jedoch keine unabhängige Sicherheitsprüfung und stellen keine Garantie für Fehler- oder Backdoorfreiheit dar.

```powershell
gh attestation verify .\<release>.zip --repo robertbackhaus-a11y/KI-Stack
gh attestation verify .\<release>.zip --repo robertbackhaus-a11y/KI-Stack --predicate-type https://spdx.dev/Document/v2.3
```

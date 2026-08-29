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
| Applications | 1.4.11 | Stabil; LM Studio (konkurrierender Electron-Autostart wird vor *und* nach dem Serverstart entfernt) und Open WebUI (Referenzversion `0.11.0`, `MinimumSupportedVersion` `0.11.0`; eine neuere unterstützte Installation wie `0.11.1` bleibt erhalten und wird nie automatisch zurückgestuft) |
| Integration | 1.5.11 | Stabile Komponente; feste SearXNG-Revision plus getracktes Overlay |
| Cutover Runtime | 1.6.13 | Stabile Komponente; transaktionslokaler Fortsetzungszustand; zielsystemvalidierter ComfyUI-Supported-Version-Vertrag, Schutz gegen v0.28.0-Payload-Overlay und die Applications-Korrekturen oben (siehe `docs/releases/complete-installer-v2.10.0.md`) |
| Production Recovery | 1.7.0-r7 | Auf dem Zielsystem akzeptiert; SearXNG-Kaltstart repariert |
| Universeller Paket-Validation-Gate | 1.0.3 | Auf dem Zielsystem aktiviert |
| Production Target Acceptance | 1.0.10 | `TARGET_SYSTEM_ACCEPTANCE_PASSED` am 21.07.2026 |
| OpenWebUI Agent Pack | 1.8.9 | Stabil; Heretic-Profile mit Visual-Pack-2.0.5-Bindung |
| OpenWebUI Visual Pack | 2.0.5 | Stabil; Z-Image- und WAN2.2-Tools mit persistenten MP4-Anhängen |
| OpenWebUI Ballistics Pack | 1.0.0 | Stabil; `18Bravo` und Solver zielsystemvalidiert |
| Codex Local | 0.1.4 | Stabile Komponente |
| RAG | 0.3.1 | Stabile Komponente; Ingestion zurückgestellt, Remote-Rollback validiert |
| Complete Installer | 2.10.0 | Ergänzt `Update-KIStack-All.cmd`, einen zentralen Update-Checker mit `InstalledVersion`/`PinnedVersion`/`AvailableVersion` je verwalteter Komponente; Upstream-Erkennung ist rein informativ, automatische Ausführung erfolgt ausschließlich bei echter `InstalledVersion`/`PinnedVersion`-Abweichung. Dieselbe Zielsystemvalidierung schloss drei Cutover-Runtime-Korrekturen ab (Anhebung auf 1.6.13): ComfyUI und Open WebUI stufen eine bestehende, unterstützte, neuere Installation nicht mehr automatisch auf ihre Referenzversion (`v0.28.0`/`0.11.0`) zurück, nur weil sie nicht exakt übereinstimmt; der LM-Studio-Steady-State-Autostart-Schutz wirkt jetzt zusätzlich nach dem Serverstart. Regressions- und zielsystemvalidiert (siehe `docs/releases/complete-installer-v2.10.0.md`). |
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


Production Recovery `1.7.0-r7` ist eine Wiederherstellungslinie und keine neue Runtime-Version; r5 bleibt als veröffentlichter Vorgänger dokumentiert. Die aktuelle Cutover-Runtime-Version ist `1.6.13` (siehe Tabelle oben und `docs/releases/complete-installer-v2.10.0.md`).


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

Das OpenWebUI Agent Pack `1.8.9` verwaltet ausschließlich die Workspace-Modelle `KI & IT-Technik` und `Allgemein` über die unterstützte HTTP-API von OpenWebUI (Referenzversion `0.11.0`; eine neuere unterstützte Installation wie `0.11.1` bleibt erhalten). Es aktiviert nur den eingebauten browserlokalen Pyodide-Code-Interpreter und erhält ausschließlich die registrierte Image-Pack-Toolbindung. `execute_code` ist keine Workspace-Tool-ID.

Das OpenWebUI Image Pack `1.10.0` verwaltet weiterhin genau das kanonische Tool `ki-stack-generate-image` über die lokale ComfyUI 1.2.2. Die bestehende FLUX2-Methode `generate_image` bleibt erhalten; `generate_pony_image` ergänzt Pony SDXL mit 1024 × 1024, CLIP Skip 2, 40 Schritten, CFG 3.1, `euler` und `normal`. Beide Wege speichern Bilder direkt im OpenWebUI-Chat. Das Pack lädt keine Modelle; der Pony-Checkpoint muss bereits installiert sein. Pony-Workflow und Chat-Ausgabe wurden auf dem Zielsystem praktisch geprüft, ohne damit eine vollständige Zielsystemvalidierung von 1.10.0 zu behaupten.

Das OpenWebUI Ballistics Pack `1.0.0` ergänzt ausschließlich das technische Profil `18Bravo` mit `ki_stack_ballistics_calculator`. Der fest gepinnte `pyballistic`-2.2.0-RK4-Kern rechnet G1/G7 ohne Git, kompilierte Solver-Erweiterungen, SciPy-Engine oder Diagrammerweiterungen. Pflichtwerte müssen vollständig explizit sein; Profile werden nur nach Bestätigung gespeichert. Der Umfang ist auf rechtmäßige sportliche, jagdliche und technische Nutzung beschränkt.

## Supply-Chain-Sicherheit

`main` ist geschützt und akzeptiert Änderungen über Pull Requests mit verpflichtenden Gitleaks-, PSScriptAnalyzer-, Bandit- und CodeQL-Prüfungen. CI-Actions sind auf vollständige Commit-SHAs gepinnt und Payloadverträge prüfen SHA256-Werte inhaltsbasiert. Jedes Release stellt eine SPDX-2.3-SBOM und GitHub-verifizierbare Build-Attestierungen bereit; der Meldeweg steht in [SECURITY.md](SECURITY.md).

KI-Stack verwendet geschützte Änderungen, verpflichtende statische Sicherheitsprüfungen, inhaltsbasierte SHA256-Verträge, veröffentlichte SBOMs und überprüfbare Build-Attestierungen. Diese Nachweise reduzieren Supply-Chain-Risiken, ersetzen jedoch keine unabhängige Sicherheitsprüfung und stellen keine Garantie für Fehler- oder Backdoorfreiheit dar.

```powershell
gh attestation verify .\<release>.zip --repo robertbackhaus-a11y/KI-Stack
gh attestation verify .\<release>.zip --repo robertbackhaus-a11y/KI-Stack --predicate-type https://spdx.dev/Document/v2.3
```

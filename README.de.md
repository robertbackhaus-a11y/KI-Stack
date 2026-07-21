> Aktuelle Produktionsabnahme: `production-target-acceptance-v1.0.9`

# KI-Stack – Deutsch

Der KI-Stack ist ein modularer und transaktionsgesicherter Windows-Installer für PowerShell 7, Git, Python, ComfyUI, Modelle, LM Studio, Open WebUI, WSL und SearXNG.

## Freigabestand

| Baustein | Version | Status |
|---|---:|---|
| Foundation / Runtime | 1.0.9 | Stabiler Referenzstand, auf Zielsystem validiert |
| Python / Git | 1.1.5 | Stabil, auf Zielsystem validiert |
| ComfyUI | 1.2.1 | Stabil; auf dem Zielsystem validiert |
| Modelle / Workflows | 1.3.7 | Stabil; FLUX2-Pflichtprofil validiert, KREA und Pony optional |
| Applications | 1.4.10 | Stabil; LM Studio und Open WebUI 0.10.2 auf dem Zielsystem akzeptiert |
| Integration | 1.5.7 | Stabil; präzises CMD-Finish-Block-Lifecycle-Gate beibehalten |
| Cutover Runtime | 1.6.3 | Akzeptierter Runtime-Basisstand |
| Production Recovery | 1.7.0-r6 | Auf dem Zielsystem akzeptiert; portable Laufzeitauflösung |
| Universeller Paket-Validation-Gate | 1.0.2 | Auf dem Zielsystem aktiviert |
| Production Target Acceptance | 1.0.9 | `TARGET_SYSTEM_ACCEPTANCE_PASSED` am 21.07.2026 |
| OpenWebUI Agent Pack | 1.8.0 | Stabil; mit OpenWebUI 0.10.2 auf dem Zielsystem validiert |

Vollständige Paketquellen liegen im Verzeichnis `package`. Fertige ZIP-Pakete werden als GitHub-Release-Artefakte veröffentlicht und nicht dauerhaft in die normale Git-Historie aufgenommen.

Jedes Paket enthält Selbsttest, Dry-Run, Execute, Transaktionsprotokollierung, Diagnose und Rollback. Neue Pakete müssen sämtliche bekannten und bereits behobenen Fehler als Regressionstests abdecken.


Die Repository-Runtime bleibt Cutover `1.6.3`. Production Recovery `1.7.0-r6` ist eine Wiederherstellungslinie und keine neue Runtime-Version; r5 bleibt als veröffentlichter und akzeptierter Vorgänger dokumentiert.


## Applications v1.4.0-rc1

LM Studio and Open WebUI 0.10.2 are delivered as the sixth transaction-protected Execute module.


## Applications v1.4.3-rc1

Fixes StrictMode-safe LM Studio detection and exposes exact transaction failure causes.


## Applications v1.4.9-rc1

Setzt die Git-Autoridentität vor Commit und annotiertem Tag repository-lokal, ohne die globale Git-Konfiguration zu verändern.

## Produktionswiederherstellung und Zielsystemabnahme

Das Repository enthält vollständige wiederverwendbare Quellen für Production Recovery `1.7.0-r6`, Universal Package Validation Gate `1.0.2` und Production Target Acceptance `1.0.9`. ZIP-Binärdateien bleiben GitHub-Release-Artefakte und werden über explizite Artefaktverträge referenziert. Der veröffentlichte r5-Stand bleibt als akzeptierter Vorgänger dokumentiert.

Gesamtstatus: `TARGET_SYSTEM_ACCEPTANCE_PASSED`.

## OpenWebUI Agent Pack

Das OpenWebUI Agent Pack `1.8.0` verwaltet ausschließlich die Workspace-Modelle `KI & IT-Technik` und `Allgemein` über die unterstützte HTTP-API von OpenWebUI 0.10.2. Modellbindung und temporärer API-Key werden nur zur Laufzeit übergeben; Wissensbasen, Tools, Skills und Functions werden nicht fest verbunden.

# KI-Stack – Deutsch

Der KI-Stack ist ein modularer und transaktionsgesicherter Windows-Installer für PowerShell 7, Git, Python, ComfyUI, Modelle, LM Studio, Open WebUI, WSL und SearXNG.

## Freigabestand

| Baustein | Version | Status |
|---|---:|---|
| Foundation / Runtime | 1.0.9 | Stabiler Referenzstand, auf Zielsystem validiert |
| Python / Git | 1.1.5 | Stabil, auf Zielsystem validiert |
| ComfyUI | 1.2.1 | Stabil; auf dem Zielsystem validiert |
| Modelle / Workflows | 1.3.4-rc1 | Release Candidate; Zielsystemtest ausstehend |

Vollständige Paketquellen liegen im Verzeichnis `package`. Fertige ZIP-Pakete werden als GitHub-Release-Artefakte veröffentlicht und nicht dauerhaft in die normale Git-Historie aufgenommen.

Jedes Paket enthält Selbsttest, Dry-Run, Execute, Transaktionsprotokollierung, Diagnose und Rollback. Neue Pakete müssen sämtliche bekannten und bereits behobenen Fehler als Regressionstests abdecken.


Current release candidate: `models-workflows-v1.3.7-rc1`.

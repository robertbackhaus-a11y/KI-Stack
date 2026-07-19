# KI-Stack ComfyUI Execute v1.2.1 – Buildbericht

## Ergebnis

- Statische Build- und Regressionsprüfungen: **88 von 88 bestanden**
- Foundation-, Runtime- und PythonGit-Moduldateien: bytegleich zum freigegebenen v1.1.5-Referenzinhalt
- ComfyUI-Installationslogik: gegenüber v1.2.0 unverändert, abgesehen von der Paketkennung
- ComfyUI: fest gepinnt auf `v0.28.0`
- Korrigiert: Regressionstest interpolierte `$Context` statt Quelltextliteral zu prüfen

## Zielsystemprüfung

Der native PowerShell-AST-Selbsttest wird vor Dry-Run und Execute auf dem Windows-Zielsystem ausgeführt. v1.2.1 prüft den gepinnten Tag anhand der vollständigen Releasekonfiguration, der konkreten Clone-/Tag-Prüflogik und des Fehlens eines ausführbaren `pull`-Arguments.

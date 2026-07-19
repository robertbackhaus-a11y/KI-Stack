# KI-Stack ComfyUI Execute v1.2.0 – Buildbericht

## Ergebnis

- Statische Build- und Regressionsprüfungen: **70 von 70 bestanden**
- Foundation-, Runtime- und PythonGit-Moduldateien: bytegleich zum freigegebenen v1.1.5-Paket
- ComfyUI: offizielles Repository, fest gepinnt auf `v0.28.0`
- PyTorch: offizieller NVIDIA-CUDA-13.0-Paketindex
- Modelle: nicht Bestandteil dieses Releases

## Zielsystemprüfungen

Der Paket-Selbsttest prüft vor Dry-Run und Execute zusätzlich:

- echte PowerShell-AST-Parsergebnisse
- sämtliche historischen Regressionen
- Starter, UAC, rekursive Preflight-Suche und Zeilenenden
- vollständige Release- und Modul-Allowlist
- ComfyUI-Konfiguration und Rollbackmechanismen

Während Execute validiert das ComfyUI-Modul zusätzlich Repository-Tag, Git-Status,
Python- und Torch-Version, CUDA-Verfügbarkeit, GPU-Namen und Compute Capability.

# KI-Stack ComfyUI Execute v1.2.0

## Freigabebasis

- Foundation/Runtime Execute v1.0.9: eingefrorener Referenzstand
- PythonGit Execute v1.1.5: erfolgreich auf dem Zielsystem validierter Referenzstand
- Foundation-, Runtime- und PythonGit-Fachmodule wurden unverändert übernommen

## Umfang dieses Pakets

Das Paket aktiviert als vierten Baustein `KIModuleComfyUI` und installiert bzw.
validiert:

- ComfyUI aus dem offiziellen Repository
- fest gepinnter Release-Tag `v0.28.0`
- eigenes Virtual Environment unter `C:\KI-Stack\python\venvs\comfyui`
- stabiles PyTorch für NVIDIA mit CUDA 13.0
- CUDA-, RTX-5090- und Compute-Capability-Validierung
- ComfyUI- und Manager-Abhängigkeiten
- zentrale Modell-, Ein-/Ausgabe- und Benutzerdatenpfade
- verwaltete Start- und Stop-Artefakte
- transaktionsgebundenes Rollback-Journal

Modelle werden in diesem Paket noch nicht heruntergeladen. Das folgt im nächsten
Baustein `Models`.

## Sicherheits- und Bestandsregeln

- Kein implizites `git pull`.
- Ein bestehendes Repository muss sauber sein und exakt dem freigegebenen Tag
  entsprechen.
- Nicht durch den KI-Stack verwaltete Start- oder Konfigurationsdateien werden
  nicht überschrieben.
- Ein vorhandenes Venv wird validiert, aber nicht ungefragt verändert.
- Rollback entfernt nur durch die laufende Transaktion erzeugte Repository- und
  Venv-Pfade; Datenverzeichnisse werden nur entfernt, wenn sie leer sind.

## Startreihenfolge

1. `Start-Nur-Selbsttest.cmd`
2. `Start-KIStack-ComfyUI-DryRun.cmd`
3. `Start-KIStack-ComfyUI-Execute.cmd`
4. Windows-UAC bestätigen
5. `EXECUTE` eingeben

Nach erfolgreicher Installation liegt der Laufzeitstarter unter:

`C:\KI-Stack\modules\comfyui\Start-KIStack-ComfyUI.cmd`

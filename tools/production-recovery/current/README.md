# KI-Stack Production Recovery v1.7.0-r5

Rekonstruierter Production-Recovery-Stand mit veröffentlichtem Cutover Runtime-Core v1.6.3 und 32 operationalen Overlay-Dateien.

## Korrektur r5

- Open WebUI wird über den im Venv installierten Console-Launcher `open-webui.exe serve` gestartet.
- Der Start bricht verständlich ab, wenn der Launcher fehlt.
- ComfyUI legt zusätzlich `C:\KI-Stack\ComfyUI\user` an; dort erwartet die vorhandene Version standardmäßig `comfyui.db`.
- Die bisherigen Korrekturen für kontrollierten Stop, sichere Wiederherstellung und Idempotenz bleiben erhalten.

Die historische Byteidentität zum verlorenen Vollpaket wird nicht behauptet.

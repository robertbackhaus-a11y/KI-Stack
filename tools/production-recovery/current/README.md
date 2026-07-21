# KI-Stack Production Recovery v1.7.0-r6

Vorbereiteter, noch nicht zielsystemvalidierter Production-Recovery-Quellstand mit veröffentlichtem Cutover Runtime-Core v1.6.3 und 32 operationalen Overlay-Dateien.

Status: `SourcePrepared`. Vorgänger ist der veröffentlichte und akzeptierte Stand Production Recovery `1.7.0-r5`. Das Production Release Manifest und Target Acceptance `1.0.8` referenzieren weiterhin ausschließlich diesen validierten Vorgänger.

## Korrektur r6

- Persönliche LM-Studio-Pfade wurden durch portable Laufzeitauflösung ersetzt.
- Release-, Overlay- und Prüfsummenverträge wurden an den vorbereiteten Quellenstand angepasst.
- Dieser Stand darf erst nach einer erneuten Zielsystemvalidierung als akzeptierter Production-Recovery-Stand bezeichnet werden.

## Übernommene Korrekturen aus r5

- Open WebUI wird über den im Venv installierten Console-Launcher `open-webui.exe serve` gestartet.
- Der Start bricht verständlich ab, wenn der Launcher fehlt.
- ComfyUI legt zusätzlich `C:\KI-Stack\ComfyUI\user` an; dort erwartet die vorhandene Version standardmäßig `comfyui.db`.
- Die bisherigen Korrekturen für kontrollierten Stop, sichere Wiederherstellung und Idempotenz bleiben erhalten.

Die historische Byteidentität zum verlorenen Vollpaket wird nicht behauptet.

Der Runtime-Core ist Cutover v1.6.3. Die im validierten Operational Overlay erhaltenen Installationsmarker für Integration und Cutover tragen weiterhin v1.6.2, weil v1.6.3 ausschließlich den Repository-/Manifestvertrag des Runtime-Pakets korrigierte und diese installierten Komponenten nicht neu schrieb.

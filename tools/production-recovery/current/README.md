# KI-Stack Production Recovery v1.7.0-r7

Zielsystemakzeptierter Production-Recovery-Stand mit veröffentlichtem Cutover Runtime-Core v1.6.3 und 32 operationalen Overlay-Dateien.

Status: `TargetSystemAccepted`. Vorgänger ist der veröffentlichte und akzeptierte Stand Production Recovery `1.7.0-r6`. Dessen SearXNG-Nachweis belegte keinen Kaltstart und wurde nicht als Beleg für r7 verwendet.

## Korrektur r7

- Der Starter verwendet die tatsächlich installierte Debian-Standardkette `valkey-server`, `uwsgi` und `nginx`; eine nicht vorhandene produktspezifische systemd-Unit wird nicht vorausgesetzt.
- Keeper-PIDs werden vor Wiederverwendung oder Beendigung anhand Prozessname und Kommandozeile verifiziert. Veraltete oder fremde PIDs werden nicht beendet.
- Erfolg erfordert TCP-Port 80, die HTML-Seite sowie eine parsebare JSON-Suche mit Ergebnisvertrag.
- Eine vorhandene kalte Standardinstallation wird übernommen; unvollständige oder defekte Konfigurationen führen nicht zu einer parallelen Installation.

## Übernommene Korrekturen aus r6

- Persönliche LM-Studio-Pfade wurden durch portable Laufzeitauflösung ersetzt.
- Der kontrollierte ComfyUI-Stop ist gegen bereits während der Inventarisierung beendete Prozesse idempotent.
- Release-, Overlay- und Prüfsummenverträge wurden an den vorbereiteten Quellenstand angepasst.
- Der finale r6-Artefaktvertrag wurde nach der damaligen Zielsystemvalidierung gebaut und veröffentlicht.

## Übernommene Korrekturen aus r5

- Open WebUI wird über den im Venv installierten Console-Launcher `open-webui.exe serve` gestartet.
- Der Start bricht verständlich ab, wenn der Launcher fehlt.
- ComfyUI legt zusätzlich `C:\KI-Stack\ComfyUI\user` an; dort erwartet die vorhandene Version standardmäßig `comfyui.db`.
- Die bisherigen Korrekturen für kontrollierten Stop, sichere Wiederherstellung und Idempotenz bleiben erhalten.

Die historische Byteidentität zum verlorenen Vollpaket wird nicht behauptet.

Der Runtime-Core ist Cutover v1.6.3. Der r7-Overlaymarker kennzeichnet die reparierte Integration 1.5.8; der Cutover-Marker bleibt historisch unverändert.

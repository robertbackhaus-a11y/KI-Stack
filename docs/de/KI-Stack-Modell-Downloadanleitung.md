# Automatischer Modell-Downloadvertrag

Der Complete Installer benötigt auf einem leeren Zielsystem keine manuell bereitgestellten Modell- oder Payloaddateien. Die neun Visualartefakte für Z-Image Turbo und WAN2.2 T2V 14B mit beiden LightX2V-4-Step-LoRAs sowie die beiden Heretic-Dateien besitzen revisionsgebundene Downloadquellen, exakte Bytegrößen und SHA-256-Werte in `tools/models-workflows/current/Manifests/models.manifest.json`.

Der Importer arbeitet in dieser Reihenfolge:

1. Gültiges Ziel anhand Größe und SHA-256 wiederverwenden.
2. Optionalen Cache beziehungsweise `ExternalModels`-Preload nur nach derselben Prüfung verwenden.
3. Fehlende Datei in den Transaktionszustand herunterladen und einen vorhandenen Teildownload per HTTP Range fortsetzen.
4. Größe und SHA-256 des vollständigen Downloads prüfen.
5. Erst danach die Datei atomar am Ziel aktivieren und erneut lesen.

Eine nicht erreichbare Quelle ergibt `WaitingForNetwork` mit fortsetzbarem Transaktionszustand. Eine falsche Größe oder SHA-256 ergibt `Failed`; die Komponente wird nicht als abgeschlossen gespeichert.

Z-Image verwendet `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf` von BennyDaBall, gebunden an Revision `db48689636056934d4f0600952ac15894f8ce1a2`, Größe `4280404800` und SHA-256 `be7b7285f6b80daef5b15affbe96d6626c308ef53dae878568b36664099c71d0`.

Eine vorhandene Datei `Qwen3-4b-Uncensored-Z-Image-Engineer-V4-Q8_0.gguf` gehört nicht zum aktiven Vertrag und wird nicht umbenannt, überschrieben oder gelöscht.

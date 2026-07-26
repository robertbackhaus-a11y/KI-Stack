# Optionale Modellbereitstellung und Preload

Complete Installer 2.3.1 lädt fehlende Modelle automatisch aus den revisionsgebundenen Quellen des zentralen Modellmanifests. Eine manuelle Bereitstellung ist keine Installationsvoraussetzung.

Ein optionaler Cache oder `ExternalModels`-Preload kann Bandbreite sparen. Der Installer akzeptiert eine Datei ausschließlich nach Prüfung von Dateiname, exakter Größe und vollständigem SHA-256. Eine gültige Zieldatei wird wiederverwendet und nicht erneut geladen. Unterbrochene Downloads bleiben fortsetzbar; eine falsche Größe oder Prüfsumme führt zu `Failed`.

Heretic ist ausschließlich Chat-LLM. Nomic dient ausschließlich Embeddings. Das offizielle `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf` wird ausschließlich durch Z-Image verwendet. Aktive visuelle Modelle gehören nur zu Z-Image Turbo und WAN2.2 T2V 14B mit beiden LightX2V-4-Step-LoRAs.

Optionaler Import eines lokalen Cache-Verzeichnisses:

```powershell
Start-KIStack-Model-Import.cmd -SourcePath "D:\KI-Modelcache"
```

`AlreadyCompliant` bedeutet, dass das Ziel bereits vollständig passt. Ein Cache ersetzt niemals die Manifestprüfung und darf keine Datei mit abweichendem Namen oder Hash als gültig erklären.

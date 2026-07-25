# Modellvertrag 2.3.0-rc14

- LM Studio stellt ausschließlich Heretic als Chat-LLM bereit.
- Nomic ist ausschließlich Embedding-Modell und darf nicht als Chatmodell angeboten werden.
- ComfyUI enthält ausschließlich die Paketverträge für Z-Image Turbo und WAN2.2 T2V 14B mit beiden LightX2V-4-Step-LoRAs.
- Das Paket enthält keine Modellgewichte. Alle fehlenden Dateien werden aus revisionsgebundenen Quellen geladen; optionale Cache-/Preload-Dateien und vorhandene Ziele werden nur nach exakter Größen- und SHA-256-Prüfung wiederverwendet.
- Downloads liegen bis zur vollständigen Prüfung im Transaktionszustand, unterstützen Resume und werden erst danach atomar aktiviert. Netzwerkausfälle bleiben fortsetzbar; Größen- oder Hashabweichungen schlagen fehl.
- Z-Image verwendet ausschließlich das öffentliche Herstellerartefakt `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`. Eine vorhandene Datei unter dem früheren `Uncensored`-Namen wird weder überschrieben noch gelöscht.
- OpenWebUI verwendet Visual Pack 2.0.5-rc2. MP4 wird als genau ein persistenter `type: file`-Downloadanhang über das native `files`-Event ausgegeben.

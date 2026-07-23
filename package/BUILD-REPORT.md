# KI-Stack Cutover v1.6.3 Repair Report

- Ausgelieferter Stand: Cutover v1.6.3; die Korrektur baut auf dem v1.6.2-Vorgänger auf
- GitHub-Repository-Validator unterstützt `version` und Legacy-`packageVersion`
- StrictMode-sichere Manifest-Feldauflösung ohne direkten Zugriff auf optionale Properties
- Schema-Fixtures für current, legacy, dual, conflict und missing
- Release-Manifest enthält kompatiblen Alias `packageVersion`
- GitHub-Update-Bundle und Publishing-Starter sind nicht Bestandteil des Runtime-Pakets
- Models / Workflows 1.4.0 ist zielsystemvalidiert: der freigegebene FLUX2-UI/API-Stand bleibt unverändert; KREA, Pony SDXL und WAN 2.2 wurden mit acht lokal wiederverwendeten, gegen offizielle Größen- und SHA256-Verträge geprüften Modellen aktiviert. Load-Test und ein Funktionslauf waren jeweils erfolgreich. Die externen Modelle umfassen 47.356.936.991 Bytes und sind nicht Bestandteil von Git oder Paket-ZIPs. Defekte Sicherungen, Archive und die OpenWebUI-Mappingdatei bleiben ausdrücklich ausgeschlossen
- Applications 1.4.10 ist stabil: LM Studio und Open WebUI 0.10.2 entsprechen dem in Production Target Acceptance 1.0.8 akzeptierten Funktionsumfang
- Integration 1.5.8 ist stabil: die reale Standarddienstkette `valkey-server`, `uwsgi`, `nginx`, der verifizierte WSL-Keeper sowie HTML- und JSON-Endpunkte wurden kalt, idempotent und nach Teilausfall geprüft
- OpenWebUI Agent Pack 1.8.1 ist ein separater API-basierter Baustein unter `tools/openwebui-agent-pack/current`; Profil-Readback, Duplikatfreiheit, technischer Chat und reale SearXNG-Websuche wurden mit Integration 1.5.8 zielsystemvalidiert

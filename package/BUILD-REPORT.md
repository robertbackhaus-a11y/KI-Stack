# KI-Stack Cutover v1.6.3 Repair Report

- Ausgelieferter Stand: Cutover v1.6.3; die Korrektur baut auf dem v1.6.2-Vorgänger auf
- GitHub-Repository-Validator unterstützt `version` und Legacy-`packageVersion`
- StrictMode-sichere Manifest-Feldauflösung ohne direkten Zugriff auf optionale Properties
- Schema-Fixtures für current, legacy, dual, conflict und missing
- Release-Manifest enthält kompatiblen Alias `packageVersion`
- GitHub-Update-Bundle und Publishing-Starter sind nicht Bestandteil des Runtime-Pakets
- Models / Workflows 1.3.7 ist stabil: FLUX2 ist das freigegebene Pflichtprofil; KREA und Pony bleiben optionale Zusatzprofile
- Applications 1.4.10 ist stabil: LM Studio und Open WebUI 0.10.2 entsprechen dem in Production Target Acceptance 1.0.8 akzeptierten Funktionsumfang
- Integration 1.5.7 ist stabil: bestehender Integrationsumfang und präzises CMD-Finish-Block-Lifecycle-Gate entsprechen Production Target Acceptance 1.0.8

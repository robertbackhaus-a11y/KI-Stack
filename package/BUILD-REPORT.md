# KI-Stack Models/Workflows Execute v1.3.7 – Korrekturbericht

Stand: 2026-07-19

## Ursache

Das integrierte GitHub-Bundle v0.2.6 behandelte den bekanntermaßen fehlerhaften historischen Snapshot `Repo-Models-Workflows-v1.3.4-rc1` als vollständig freizugebenden Stand und führte dessen Repository-Parser aus. Der Snapshot wird für eine sichere Wiederaufnahme benötigt, darf aber nicht als gültiger Release-Stand revalidiert werden.

## Korrektur

- Historische fehlerhafte Zwischenstände werden ausschließlich als Resume-Snapshots klassifiziert.
- Vollvalidierung erfolgt nur für den stabilen ComfyUI-Stand, den letzten syntaktisch validen Models/Workflows-Stand v1.3.6 und das neue Ziel v1.3.7.
- Die Snapshot-Klassen sind disjunkt und werden vor der Veröffentlichung geprüft.
- Das GitHub-Update v0.2.7 ist direkt im Gesamtpaket integriert.
- Execute-, Modell- und Workflowlogik bleiben gegenüber v1.3.6 funktional unverändert.

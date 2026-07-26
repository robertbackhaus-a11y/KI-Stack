# KI-Stack OpenWebUI Agent Pack 1.8.8

Status: `StaticPendingValidation_TargetPending`. 1.8.8 aktualisiert ausschließlich den verbindlichen Visual-Pack-Abhängigkeitsvertrag auf 2.0.5-rc3; die StrictMode-sichere HTTP-Fehlerklassifizierung und der automatische Rollback aus 1.8.7 bleiben unverändert.

Reproduzierbares Paket für genau zwei verwaltete OpenWebUI-0.10.2-Workspace-Modelle: `ki-stack-it-technik` (`KI & IT-Technik`) und `ki-stack-allgemein` (`Allgemein`).

Die LM-Studio-Verbindung wird über den realen OpenWebUI-0.10.2-Vertrag
`OPENAI_API_CONFIGS.<index>.model_ids` auf Heretic begrenzt. Dadurch bleiben
Nomic und fremde LM-Studio-Modelle aus dem Chat-Modellwähler ausgeschlossen.
Der vorherige Verbindungsfilter wird ohne API-Schlüssel im Transaktionsbackup
gesichert und beim Rollback wiederhergestellt.

Das Paket verwendet ausschließlich die von der real installierten Version angebotene HTTP-API. Ein temporärer API-Key wird verdeckt als `SecureString` eingelesen und ausschließlich für den Bearer-Header im Arbeitsspeicher verwendet. Er wird nicht gespeichert oder protokolliert.

`BaseModelId` ist ein Laufzeitparameter. Ohne Parameter wird nur dann automatisch gewählt, wenn exakt ein verwendbares Modell angeboten wird. Arena- und Embedding-Modelle werden nicht als Basismodell verwendet. Bei null oder mehreren Kandidaten bricht das Paket mit der Liste der angebotenen IDs ab.

Beide Profile verwenden `params.function_calling = native`, `knowledge=[]` und die eingebaute Pyodide-Code-Interpreter-Capability. Ist das registrierte Visual Pack 2.0.5-rc3 vorhanden, bleiben ausschließlich dessen OpenWebUI-kompatible interne Tool-IDs `ki_stack_generate_image` und `ki_stack_generate_video` gebunden. `execute_code` ist keine Workspace-Tool-ID. Das Profil `ki-stack-18bravo` bleibt ohne Code Interpreter und ausschließlich an `ki_stack_ballistics_calculator` gebunden.

## Abläufe

- `Start-OpenWebUI-Agent-Pack-SelfTest.cmd`: statischer Paketvertrag.
- `Start-OpenWebUI-Agent-Pack-DryRun.cmd`: mutierungsfreie Operationsvorschau.
- `Start-OpenWebUI-Agent-Pack-Execute.cmd`: verdeckte Token-Eingabe, Backup, Create/Update und Readback.
- `Invoke-OpenWebUIAgentPack.ps1 -Action Validate`: API-Readback.
- `Invoke-OpenWebUIAgentPack.ps1 -Action Rollback -BackupPath <path>`: stellt ausschließlich die zwei betroffenen IDs wieder her oder entfernt neu angelegte IDs.
- `Test-OpenWebUIAgentPackTarget.ps1`: API-Readback, zwei reale Profilchats sowie SearXNG-/Websuchtest ohne persistierten Chatverlauf.
- `New-OpenWebUIAgentPackArchive.ps1`: deterministisches Release-ZIP mit festem Entry-Zeitpunkt und SHA256-Sidecar.

Andere Modelle, Chats, Prompts, Tools, Skills, Functions und Benutzerinhalte werden nicht verändert.

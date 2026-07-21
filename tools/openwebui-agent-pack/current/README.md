# KI-Stack OpenWebUI Agent Pack 1.8.2

Status: `TargetSystemValidated` mit OpenWebUI 0.10.2 am 21.07.2026.

Reproduzierbares Paket für genau zwei verwaltete OpenWebUI-0.10.2-Workspace-Modelle: `ki-stack-it-technik` (`KI & IT-Technik`) und `ki-stack-allgemein` (`Allgemein`).

Das Paket verwendet ausschließlich die von der real installierten Version angebotene HTTP-API. Ein temporärer API-Key wird verdeckt als `SecureString` eingelesen und ausschließlich für den Bearer-Header im Arbeitsspeicher verwendet. Er wird nicht gespeichert oder protokolliert.

`BaseModelId` ist ein Laufzeitparameter. Ohne Parameter wird nur dann automatisch gewählt, wenn exakt ein verwendbares Modell angeboten wird. Arena- und Embedding-Modelle werden nicht als Basismodell verwendet. Bei null oder mehreren Kandidaten bricht das Paket mit der Liste der angebotenen IDs ab.

Beide Profile verwenden `params.function_calling = native`. Ist das registrierte Image Pack 1.9.0 vorhanden, bleibt ausschließlich dessen OpenWebUI-kompatible interne Tool-ID `ki_stack_generate_image` (kanonisch `ki-stack-generate-image`) gebunden; ohne Image Pack bleiben die Profile ungebunden. Fremde Tools, Wissensbasen, Skills und Functions werden nicht gebunden.

## Abläufe

- `Start-OpenWebUI-Agent-Pack-SelfTest.cmd`: statischer Paketvertrag.
- `Start-OpenWebUI-Agent-Pack-DryRun.cmd`: mutierungsfreie Operationsvorschau.
- `Start-OpenWebUI-Agent-Pack-Execute.cmd`: verdeckte Token-Eingabe, Backup, Create/Update und Readback.
- `Invoke-OpenWebUIAgentPack.ps1 -Action Validate`: API-Readback.
- `Invoke-OpenWebUIAgentPack.ps1 -Action Rollback -BackupPath <path>`: stellt ausschließlich die zwei betroffenen IDs wieder her oder entfernt neu angelegte IDs.
- `Test-OpenWebUIAgentPackTarget.ps1`: API-Readback, zwei reale Profilchats sowie SearXNG-/Websuchtest ohne persistierten Chatverlauf.
- `New-OpenWebUIAgentPackArchive.ps1`: deterministisches Release-ZIP mit festem Entry-Zeitpunkt und SHA256-Sidecar.

Andere Modelle, Chats, Prompts, Tools, Skills, Functions und Benutzerinhalte werden nicht verändert.

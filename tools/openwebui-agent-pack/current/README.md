# KI-Stack OpenWebUI Agent Pack 1.9.0

Status: `StaticPendingValidation_TargetPending`. 1.9.0 fügt das dritte verwaltete Profil `ki-stack-research` hinzu (siehe unten) und führt den expliziten Feldeigentümervertrag für Reconcile/Update ein (`Resolve-AgentPackReconcileForm`/`Merge-AgentPackObjectValueByKey`): OpenWebUIs reales `update_model_by_id` ersetzt `meta` vollständig statt es zu mergen, daher merged das Paket jetzt selbst -- nur paketverwaltete Felder werden erzwungen, jeder unbekannte oder live-only ergänzte Wert (z. B. über die OpenWebUI-UI hinzugefügte `capabilities`-/`builtinTools`-Schlüssel, `access_grants`, `profile_image_url`) bleibt bei einem Reconcile unangetastet erhalten. Die StrictMode-sichere HTTP-Fehlerklassifizierung und der automatische Rollback aus 1.8.7 bleiben unverändert.

Reproduzierbares Paket für drei verwaltete OpenWebUI-Workspace-Modelle: `ki-stack-it-technik` (`KI & IT-Technik`), `ki-stack-allgemein` (`Allgemein`) und `ki-stack-research` (`KI-Stack Research`, siehe eigener Abschnitt unten). Greenfield-ReferenceVersion ist OpenWebUI `0.11.1`; `MinimumSupportedVersion` bleibt `0.11.0`, eine neuere unterstützte Installation wird nie automatisch heruntergestuft (`preserved`).

Die LM-Studio-Verbindung wird über den realen OpenWebUI-Vertrag
`OPENAI_API_CONFIGS.<index>.model_ids` auf Heretic begrenzt. Dadurch bleiben
Nomic und fremde LM-Studio-Modelle aus dem Chat-Modellwähler ausgeschlossen.
Der vorherige Verbindungsfilter wird ohne API-Schlüssel im Transaktionsbackup
gesichert und beim Rollback wiederhergestellt.

Das Paket verwendet ausschließlich die von der real installierten Version angebotene HTTP-API. Ein temporärer API-Key wird verdeckt als `SecureString` eingelesen und ausschließlich für den Bearer-Header im Arbeitsspeicher verwendet. Er wird nicht gespeichert oder protokolliert.

`BaseModelId` ist ein Laufzeitparameter. Ohne Parameter wird nur dann automatisch gewählt, wenn exakt ein verwendbares Modell angeboten wird. Arena- und Embedding-Modelle werden nicht als Basismodell verwendet. Bei null oder mehreren Kandidaten bricht das Paket mit der Liste der angebotenen IDs ab.

Alle drei Profile verwenden `params.function_calling = native` und die eingebaute Pyodide-Code-Interpreter-Capability. `ki-stack-it-technik`/`ki-stack-allgemein` haben `knowledge=[]` (keine Knowledge-Bindung) und, sofern das registrierte Visual Pack 2.0.5 vorhanden ist, ausschließlich dessen OpenWebUI-kompatible interne Tool-IDs `ki_stack_generate_image`/`ki_stack_generate_video` gebunden. `ki-stack-research` bindet stattdessen dynamisch genau eine RAG-Knowledge-Collection und bewusst keine Extension-Tools (siehe unten). `execute_code` ist keine Workspace-Tool-ID. Das Profil `ki-stack-18bravo` (separates Paket `openwebui-ballistics-pack`) bleibt ohne Code Interpreter und ausschließlich an `ki_stack_ballistics_calculator` gebunden.

## Abläufe

- `Start-OpenWebUI-Agent-Pack-SelfTest.cmd`: statischer Paketvertrag.
- `Start-OpenWebUI-Agent-Pack-DryRun.cmd`: mutierungsfreie Operationsvorschau.
- `Start-OpenWebUI-Agent-Pack-Execute.cmd`: verdeckte Token-Eingabe, Backup, Create/Update und Readback.
- `Invoke-OpenWebUIAgentPack.ps1 -Action Validate`: API-Readback.
- `Invoke-OpenWebUIAgentPack.ps1 -Action Rollback -BackupPath <path>`: stellt ausschließlich die zwei betroffenen IDs wieder her oder entfernt neu angelegte IDs.
- `Test-OpenWebUIAgentPackTarget.ps1`: API-Readback, zwei reale Profilchats sowie SearXNG-/Websuchtest ohne persistierten Chatverlauf.
- `New-OpenWebUIAgentPackArchive.ps1`: deterministisches Release-ZIP mit festem Entry-Zeitpunkt und SHA256-Sidecar.

Andere Modelle, Chats, Prompts, Tools, Skills, Functions und Benutzerinhalte werden nicht verändert.

## Agent-Pack-Feldvertrag (Reconcile-Ownership, seit 1.9.0)

OpenWebUIs reales `update_model_by_id` merged `meta` nicht -- es ersetzt das Objekt vollständig (Ausnahme: `profile_image_url` und `base_model_id`, serverseitig nur erhalten, wenn im Request gar nicht gesetzt). `Resolve-AgentPackReconcileForm`/`Merge-AgentPackObjectValueByKey` bauen daher vor jedem Create/Update den tatsächlich gesendeten Body aus einem vollständigen Klon des aktuellen Live-Modells und erzwingen darin ausschliesslich die paketverwalteten Felder:

| Feld | Vertrag | Begründung |
|---|---|---|
| `id`, `base_model_id`, `name` | Managed (Replace) | Paketidentität/-konfiguration |
| `params.system`, `params.function_calling` | Managed (Replace) | Der Prompt-/Verhaltensvertrag ist genau das, was dieses Paket definiert und deterministisch hält |
| `meta.description`, `meta.toolIds`, `meta.skillIds`, `meta.functionIds`, `meta.managedBy`, `meta.agentPackVersion` | Managed (Replace) | paketeigene Buchführung/Listen |
| `meta.capabilities`, `meta.builtinTools` | Merge (schlüsselweise) | nur die vom jeweiligen Definitionsfile deklarierten Schlüssel sind paketverwaltet; jeder andere (z. B. live über die OpenWebUI-UI ergänzte) Schlüssel bleibt unangetastet |
| `meta.knowledge` | Managed nur bei `knowledgeSource`-Vertrag (aktuell nur `ki-stack-research`), sonst Preserve | ein Profil ohne Knowledge-Vertrag hat keine Meinung zu einer manuell angehängten Collection |
| `meta.profile_image_url` | Preserve | wird hier nie referenziert, überlebt als Teil des Live-Meta-Klons |
| `access_grants` | Preserve | Sichtbarkeit/Freigaben sind nicht Teil des Agent-Pack-Vertrags; nur ein neu angelegtes Modell erhält den Paket-Default `[]` |
| `is_active` | Managed (Replace, immer `true`) | Paketvertrag: ein verwaltetes Modell existiert und ist aktiv |
| jeder sonstige, dem Paket unbekannte `meta`-Schlüssel | Preserve | überlebt automatisch über den Live-Meta-Klon |

Regressionstest: `Test-OpenWebUIAgentPackPreserve.ps1` (Fälle A-E plus Negativkontrolle, die das alte Replace-Verhalten reaktiviert und beweist, dass die Prüfungen die Regression tatsächlich erkennen).

## ki-stack-research: nativer Referenz-Agent (2.12.0)

Drittes verwaltetes Profil, sicherer Read-/Research-Agent: kombiniert lokales KI-Stack-Wissen (RAG) und Websuche zu einer belegten Antwort. Kein Schreibzugriff auf Betriebssystem, Dateisystem oder Repository; keine administrativen OpenWebUI-Funktionen.

**Native OpenWebUI-0.11.1-Mechanismen, keine externe Agentenplattform.** Quellcode-bestätigt (`open_webui/utils/tools.py get_builtin_tools`, `open_webui/utils/middleware.py`, `open_webui/models/models.py`):

- `params.function_calling = native` gibt dem Modell selbst die Kontrolle über Werkzeugauswahl, Ergebnisverarbeitung und Folgeschritte -- die eigentliche "agentische" Eigenschaft, vollständig OpenWebUI-intern (`get_builtin_tools`, `CHAT_RESPONSE_MAX_TOOL_CALL_ITERATIONS`, Default 256 -- eingebauter Schutz gegen endlose Toolschleifen).
- `meta.knowledge` (Objekte `{type:"collection",id,name}`, **keine** blossen ID-Strings -- ein String wird von OpenWebUI stillschweigend ignoriert) macht `query_knowledge_files` zu einem vom Modell selbst aufrufbaren Werkzeug, sobald mindestens ein Eintrag gebunden ist.
- Websuche ist ein **globales** Laufzeit-Feature (`ENABLE_WEB_SEARCH`, `web.search.enable`) plus ein **Chat-Feature-Flag** (`features.web_search`) -- es gibt keinen Modell-Schalter, der Websuche fest erzwingt oder ausschliesst (`profileSettingAvailable: false`, unverändert seit 0.11.0).
- `meta.builtinTools.<kategorie>` (Objekt, `extra: allow` im Model-Schema) ist der reale, native Vertrag für Tool-Berechtigungen pro Modell -- `is_builtin_tool_enabled(category, default=True)` entscheidet pro Kategorie (`knowledge`, `web_search`, `code_interpreter`, `image_generation`, `memory`, `files`, `chats`, `subagents`, `notes`, `time`, `user_input`), ob ein Werkzeug überhaupt angeboten wird. `ki-stack-research` setzt ausschliesslich `knowledge`, `web_search`, `code_interpreter` auf `true`, alle übrigen Kategorien explizit auf `false`.

**Toolvertrag (`Definitions/ki-stack-research.json`):**

| Erlaubt | Verboten (`builtinTools.*=false`) |
|---|---|
| `knowledge` (RAG) | `time`, `user_input`, `files`, `chats`, `subagents`, `memory`, `image_generation`, `notes` |
| `web_search` (SearXNG, global-runtime-feature) | beliebige Shell/PowerShell, Dateilöschung, Systemkonfiguration, Installationen, Secrets, administrative OpenWebUI-Funktionen -- für keine dieser Aktionen existiert überhaupt ein OpenWebUI-Tool; der native Vertrag deckt nur die oben genannten Kategorien ab |
| `code_interpreter` (Pyodide, isoliert -- kein Host-/Repo-Zugriff) | Visual-Pack-Tools (`extensionTools: false` -- bewusst nicht gebunden, ausserhalb des Research-Use-Case) |

Kein `toolIds`/`skillIds`/`functionIds` gebunden (`extensionTools: false` schliesst auch die sonst automatisch gebundenen Visual-Pack-Werkzeuge aus).

**`meta.capabilities`-Deny-Liste (zusätzlich zum `builtinTools`-Vertrag oben):** `code_interpreter`/`web_search` erlaubt; `image_generation`, `memory`, `file_upload` **und `terminal`** explizit auf `false`. `terminal` gated OpenWebUIs `terminal_server`-Tool-Brücke (`utils/middleware.py`) -- die real naheliegendste Capability zu "beliebige Shell gegen den Host" in diesem Schema; sie defaultet auf `true`, wenn abwesend, und wird daher als Defense-in-Depth explizit verboten, obwohl auf diesem Deployment aktuell kein `terminal_server.connections` konfiguriert ist. `ki-stack-research` hat damit keinerlei Shell-, Dateisystem- oder Host-Administrationszugriff -- weder über `builtinTools` noch über `capabilities` noch über gebundene Extension-Tools.

**RAG-Knowledge-Bindung ist dynamisch, nie hartcodiert:** `knowledgeSource: "rag-global"` im Definitionsfile löst `Get-AgentPackRAGKnowledgeReference` zur Installationszeit gegen `GET /api/v1/knowledge/` auf, nach dem in `rag.config.json`'s `knowledgeName` hinterlegten Namen (RAG's eigener globaler Scope, siehe `tools/rag/current`). Existiert diese Collection noch nicht (RAG wurde auf diesem Ziel noch nie ausgeführt), wird `ki-stack-research` **übersprungen** -- weder angelegt noch aktualisiert, nie mit leerer Knowledge-Bindung erzeugt. Alle anderen Definitionen im selben Lauf werden davon nicht berührt. Das ist bewusst strenger als der grosszügige, nie hart fehlschlagende Musterentscheid der optionalen Visual-Pack-Werkzeuge (die weiterhin einfach ungebunden bleiben, wenn nicht registriert).

**Systemprompt** ist eine versionierte Repository-Datei (`Definitions/ki-stack-research.json`, Feld `systemPrompt`), keine manuelle OpenWebUI-Konfiguration. Kurz und deterministisch: Rolle, erlaubte Werkzeuge und wann sie eingesetzt werden, Quellenpflicht, Umgang mit fehlender Information, Verbot erfundener Werkzeugergebnisse, Verbot unnötiger Werkzeugaufrufe, explizite Stop-Bedingung.

**Credential-Gap (bekannte Automatisierungs-/Bootstrap-Grenze, kein Funktionsfehler des Research Agents):** Provisionierung (Create/Update/Readback/Rollback aller drei Profile, inklusive `ki-stack-research`) erfordert einen echten OpenWebUI-Admin-API-Key, eingegeben als `SecureString`, nie persistiert und nie im Repository gespeichert. Ohne interaktive Eingabe oder einen von aussen (vom Menschen) bereitgestellten Token ist keine vollautomatische Provisionierung möglich -- kein DB-Hack, kein automatischer Extraktionsversuch aus der OpenWebUI-Datenbank. Insbesondere ein echter, authentifizierter Multi-Step-Chat-End-zu-End-Nachweis für `ki-stack-research` benötigt dieses extern bereitgestellte Credential; die reine Provisionierung/Reconcile/Knowledge-Bindung ist davon unabhängig vollständig automatisiert und getestet (siehe `Test-OpenWebUIAgentPackResearchContract.ps1`, `Test-OpenWebUIAgentPackPreserve.ps1`).

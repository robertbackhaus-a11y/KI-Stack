# KI-Stack MCP Runtime

Phase 1 des 2.15-MCP-Konzepts (`docs/proposals/2.15-mcp-foundation.md`). Isoliertes Komponente
(Isolation Category A), die **ausschließlich** Installation, Lifecycle, Konfiguration und
Open-WebUI-Registrierung eines nativen MCP-Servers übernimmt.

**Architekturregel:** Dieses Modul ist **kein** Tool-Ausführungs- oder Proxy-Layer. Open WebUIs
eigener nativer MCP-Client verbindet sich direkt mit dem hier gestarteten MCP-Server; kein
Tool-Aufruf läuft zur Laufzeit durch KI-Stack-Code.

## Was hier läuft

Open Terminals bestehende FastAPI-App, über FastMCPs `OpenAPIProvider` als MCP-Server
(`streamable-http`-Transport) exponiert — gestartet über `Scripts/mcp_launcher.py`, **nicht**
über das nackte `open-terminal mcp`-CLI. Grund (siehe Skript-Header und
`docs/proposals/2.15-mcp-foundation.md`): `open-terminal mcp` allein baut seine interne
ASGI-Bridge ohne Auth-Header auf, wodurch jeder echte Tool-Aufruf mit 401 fehlschlägt
(Phase-0-Befund). Der Launcher ist eine reine Start-Zeit-Konfiguration, kein Laufzeit-Proxy.

Diese MCP-Runtime-Instanz ist **unabhängig** vom produktiven Open Terminal auf Port 8000 — eigener
Port (Default 8021), eigener API-Key, eigenes Workspace-Verzeichnis. Der produktive
OpenAPI-Terminal-Pfad bleibt in Phase 1 vollständig unangetastet parallel bestehen.

## Version-Pinning (Phase 7)

`Config/mcp-runtime.config.json`s `packageSpec` ist explizit auf `open-terminal[mcp]==0.11.34`
gepinnt (kein `latest`) — die Version, die während der gesamten Phasen 0–6 tatsächlich real
aufgelöst und gegen echte Produktions- wie Scratch-Ziele getestet wurde (verifiziert über den
lokalen `uv`-Cache: genau ein `open_terminal-0.11.34.dist-info` vorhanden). Quelle: öffentliches
PyPI, kein privater Index. Die eigenständige KI-Stack-Komponente `open-terminal`
(`tools/open-terminal/current/Config/open-terminal.config.json`) verwendet weiterhin ihre eigene,
unveränderte `packageSpec: "open-terminal"` ohne Versionspin — das ist eine vorbestehende
Eigenschaft dieser bereits veröffentlichten (2.14.0), separaten Komponente, deren Anpassung
außerhalb des Umfangs dieser Phase liegt (kein Scope-Creep auf eine bereits ausgelieferte
Komponente). Es existiert im Repository keine etablierte Hash-/Source-Record-Konvention für
externe PyPI-Abhängigkeiten (Open Terminals eigenes `MANIFEST.json` dokumentiert seine PyPI-Version
ebenfalls nicht) — der Versionspin in der Konfigurationsdatei selbst ist damit der einzige,
konsistente Verifikationspunkt.

## Lifecycle

`Invoke-KIStackMcpRuntime.ps1 -Action <Action> [-TargetRoot ...] [-OpenWebUIEndpoint ...]`

| Action | Zweck |
|---|---|
| `Audit` / `Validate` | Compliance-Check (Dateien + Credential), Prozess muss nicht laufen |
| `Install` / `Upgrade` / `Repair` | Reconcile-zu-Zielversion, idempotent (`SkippedAlreadyCompliant` bei bereits passendem Stand) |
| `Start` / `Stop` | Idempotent — ein bereits laufender Prozess wird nie dupliziert, ein bereits gestoppter erzeugt keinen Fehler |
| `Status` | Read-only: `Running` / `Failed` / `Stopped`, inkl. Health-Check |
| `Register` / `Unregister` / `RegistrationStatus` | Open-WebUI-`tool_server.connections`-Eintrag verwalten (Read-Modify-Write, nur der eigene Eintrag) |
| `Rollback` | Wiederherstellung aus einem `rollback.json`-Backup |
| `Uninstall` | Stop + Unregister + Entfernen des eigenen Modul-/State-Baums |

Namenskonvention 1:1 von `tools/open-terminal/current/` übernommen (dem einzigen anderen
Langläufer-Dienst-Modul im Repo) — kein repo-weit einheitliches Interface existiert, jedes Modul
implementiert Install/Repair/Health eigenständig (Phase-1-Recherchebefund).

## Sicherheit

- Bindung ausschließlich an `127.0.0.1` (Default-Config, `host: "127.0.0.1"`) — kein
  `0.0.0.0`-Binding, kein externes Netzwerk-Exposure.
- Eigener, zufällig generierter API-Key (32 Byte), DPAPI-verschlüsselt unter
  `state/mcp-runtime/credential.json` (Windows DPAPI, CurrentUser-Scope) — nie im Klartext auf
  Platte, nie geloggt, nie als Prozessargument übergeben (nur als Umgebungsvariable unmittelbar
  vor dem Start, danach sofort zurückgesetzt).
- Workspace strikt auf `state/mcp-runtime/workspace` begrenzt — nie das Repository, nie ein
  Nutzer-Arbeitsverzeichnis.
- Open-WebUI-Admin-Credential wird **wiederverwendet** aus dem bereits bestehenden,
  DPAPI-geschützten Store (`Lifecycle/KIStackOpenWebUICredential.psm1`) — dieses Modul legt kein
  eigenes Open-WebUI-Credential an.
- Keine Secrets im Repository, in `MANIFEST.json`/`Config/*.json` oder in Log-Ausgaben.

## Validation Gate

`Test-KIStackMcpRuntime.ps1` — 13-Punkte-Check (Server läuft, Health, Open-WebUI-Registrierung,
Tool Discovery, `run_command`/Exitcode/Dateien/Prozesssteuerung/`kill_process` direkt gegen den
MCP-Server, ein echter Open-WebUI-Agententest **mit `stream:true`**, vollständiger Cleanup danach),
seit 2.19 Phase 1 zusätzlich um drei `ui_*`-Tool-Oberflächen-Checks aus demselben
`list_tools`-Roundtrip ergänzt (Open-Terminal-Basistools weiterhin vorhanden, alle 10 `ui_*`
Tools vorhanden, keine verbotenen UI-Tools exponiert). Die `ui_*`-Transportlogik selbst hat ihre
eigene, dispatcherfreie Unit-Test-Suite: `Scripts/test_ki_desktop_control_tools.py`.

**Wichtig:** Ein Test mit `stream:false` ist laut Phase-0-Befund kein gültiger Nachweis für einen
MCP-Runtime-Defekt — Open WebUIs `non_streaming_chat_response_handler` durchläuft die
Tool-Ausführungsschleife für keinen Tool-Typ, unabhängig von MCP. Deshalb erzwingt der
Validation-Gate-Test an der einzigen Stelle, die einen echten Agentenzyklus über Open WebUI prüft,
explizit `stream:true`.

## Desktop Control (`ui_*` Tools, 2.19 Phase 1)

`Scripts/mcp_launcher.py` registriert zusätzlich zum unveränderten Open-Terminal-`OpenAPIProvider`
zehn native FastMCP-Tools (`Scripts/ki_desktop_control_tools.py`, `register_ui_tools`) auf
DERSELBEN `FastMCP`-Instanz — kein zweiter Server, kein zweiter Port, kein zweiter Prozess:
`ui_list_windows`, `ui_inspect_window`, `ui_find_element`, `ui_get_properties`, `ui_get_value`,
`ui_screenshot`, `ui_wait_for`, `ui_set_value`, `ui_invoke`, `ui_focus`. Jedes Tool ist ein
reiner Transport auf `tools/desktop-control/current/Invoke-KIStackDesktopControl.ps1` — Policy,
Zielauflösung und Verifikation bleiben vollständig dort. Details, Kontrakt und die bewusst nicht
exponierte Oberfläche (`scroll`, `send_input`, `raw_winapp`, ...) siehe
`tools/desktop-control/current/MCP-INTEGRATION.md`.

Der Dispatcher wird ausschließlich unter `<TargetRoot>\tools\desktop-control\current\
Invoke-KIStackDesktopControl.ps1` gesucht (kein PATH-Fallback) — `TargetRoot` wird dafür seit
2.19 als viertes Argument an `mcp_launcher.py` durchgereicht (`Get-KIMcpRuntimeStartArguments`).
Fehlt der Dispatcher, schlägt jeder `ui_*`-Aufruf einzeln mit einem strukturierten MCP-Fehler
fehl; ein bereits vom Dispatcher selbst gemeldetes `success:false` (z. B.
`SecretContextBlocked`, `PostconditionNotProven`, `ResolverError`) wird unverändert durchgereicht.

## Bekannte Grenzen (Phase 1, dokumentiert, nicht blockierend)

- Working-Directory-Persistenz über getrennte `run_command`-Aufrufe: nicht unterstützt (Baseline-
  Limitierung von Open Terminal selbst, keine MCP-Regression — siehe Paritätsmatrix in
  `docs/proposals/2.15-mcp-foundation.md`).
- Streaming stdout/stderr, Terminal-Dateien im Chat, Status-Events: SHOULD, nicht Teil von Phase 1.
- Kein Cutover: der produktive Open-Terminal-OpenAPI-Pfad bleibt bestehen, bis eine vollständige
  Paritätsprüfung UND eine explizite Freigabe vorliegen.

# KI-Stack Complete Installer 2.18.2

`KI-Stack-Complete-Installer-v2.18.2.zip` ist das aktuell veröffentlichte Complete-Installer-Paket.

Das aktuelle Paket stellt den vollständig verwalteten KI-Stack-Stand bis Release 2.18.2 bereit. Die aktuelle Architektur umfasst:

- Open WebUI `0.11.3` als Referenz-/Mindestversion; unterstützte neuere Installationen bleiben erhalten und werden nie automatisch zurückgestuft.
- ComfyUI `v0.34.0` als Referenz-/Mindestversion; unterstützte neuere Installationen bleiben erhalten.
- Desktop Control 0.1.0 mit zentralem WinApp 0.6.1 als kontrollierte Windows-UIA-Schicht; semantische Operationen mit Policy-, Target-, Secret-, Audit- und unabhängiger Postcondition-Prüfung. MCP-Anbindung bleibt in 2.18 bewusst noch ausstehend.
- Codex Local `0.2.1` mit isoliertem `CODEX_HOME`.
- RAG `0.4.0` mit globalen und projektbezogenen Knowledge-Collections.
- OpenWebUI Agent Pack `1.9.0`.
- OpenWebUI Visual Pack `2.0.5`.
- Ballistics Pack `1.0.0`.
- MCP Runtime `0.1.0` als primärer Terminal-/Host-Control-Backendpfad für MCP-fähige Profile auf `127.0.0.1:8021`.
- Local Control auf dem vorhandenen MCP Runtime, ohne zweite Windows-Control-Runtime, zusätzlichen Port oder zusätzliches Credential.
- Open Terminal `0.1.0` bleibt vollständig verwaltet und in den Lifecycle integriert als unterstützter Fallback-/Rollback-Backendpfad; der MCP Runtime ist der primäre Terminal-/Host-Control-Pfad für produktive MCP-fähige Profile.
- natives OpenWebUI-Memory für die durch die Agent-Pack-Policy definierten verwalteten Profile.
- zentraler persistenter OpenWebUI-Credential-Bootstrap mit lokalem DPAPI-geschütztem Secret-Store.
- Component Isolation, interne Komponentenversions-Registry, deterministische Release-Paketierung, PackageSelfTest und automatische Release Attestation.

Memory-Policy des aktuellen Pakets:

- aktiviert: `ki-stack-it-technik`, `ki-stack-allgemein`
- deaktiviert: `ki-stack-18bravo`, `ki-stack-research`
- durch diesen Vertrag nicht verwaltet: `roleplay`

Der 2.17-Datenbankschutz umfasst Online-Backup von `webui.db` über SQLite `VACUUM INTO`, Integritätsprüfung, kontrolliertes Restore-Werkzeug, Sicherheitsbackup vor dem Restore, WAL-/SHM-Behandlung sowie Health-Verifikation nach dem Restore.

Validierungsaussagen bleiben nach Umfang getrennt. Die letzte vollständige physische Windows-Greenfield-Installation auf einem leeren Zielsystem wurde mit 2.4.0 durchgeführt. Die späteren Releases bis 2.18.2 ergänzen Repository-Regression, deterministische Paket-, Komponenten-, Upgrade-/Reconcile- und Real-Target-Acceptance-Nachweise, ohne einen neueren vollständigen Greenfield-Lauf zu behaupten.
- Heretic ist das einzige Chat-LLM.
- Nomic dient ausschließlich Embeddings.
- Z-Image verwendet nur `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`.
- Aktive visuelle Workflows sind Z-Image Turbo und WAN2.2 T2V 14B mit beiden LightX2V-4-Step-LoRAs.
- Visual Pack ist 2.0.5, Agent Pack 1.9.0 und Models / Workflows 2.0.3.
- Fehlende Modelle einschließlich des ausschließlich für Embeddings verwendeten `nomic-embed-text-v1.5.Q4_K_M.gguf` werden automatisch geladen. Gültige Ziele und optionale Caches/Preloads werden nur nach Größen- und SHA-256-Prüfung wiederverwendet. Eine Teildatei, die bereits ihre erwartete Endgröße erreicht hat, wird direkt gegen diesen Größen-/SHA256-Vertrag verifiziert und nie erneut über das Netzwerk angefragt (ein echter, im Greenfield-Lauf gefundener Fehler, bei dem dieser Fall einen HTTP-416 der Quelle auslöste, wurde behoben und gegen ein echtes Ziel erneut verifiziert).
- OpenWebUI-API-abhängige Installer-Aktionen verwenden das zentrale persistente KI-Stack-OpenWebUI-Credential. Fehlt ein gültiges Credential, werden abhängige Arbeiten kontrolliert als Pending/Blocked gemeldet, statt einen separat gepflegten temporären Administrator-API-Key zu verwenden.
- `WaitingForUserAction` bedeutet jetzt ausschließlich, dass OpenWebUI und ComfyUI beide erreichbar sind, aber Erstanmeldung/API-Key noch fehlen. Bleibt OpenWebUI oder ComfyUI über sein begrenztes Readiness-Zeitfenster hinaus nicht erreichbar, schlägt der Installer stattdessen mit einem echten Fehler fehl, statt unbegrenzt auf eine Benutzeraktion zu warten, die nicht erfolgen kann.
- Codex Local 0.2.1 wird reproduzierbar über LM Studio angebunden. Node.js 24.14.0 und npm werden dabei als portable, SHA256-geprüfte Modullaufzeit paketgesteuert bereitgestellt; eine globale Node.js-Installation ist nicht erforderlich. Die Windows-Buildvalidierung führt die installierte CLI vor der Zielfreigabe real mit der verwalteten Laufzeit aus. Das Warten auf LM Studios lokalen API-Server bei einem echten Erststart nutzt jetzt dasselbe bis zu ~120s-Zeitfenster, für das der verwaltete Starter selbst ausgelegt ist, und beobachtet dessen Exitcode — statt eines unabhängig getakteten, kürzeren Budgets, das aufgeben konnte, während der Starter noch legitim lief (ein echter, während des 2.5.0-Greenfield-Laufs reproduzierter Fehler, behoben, regressionsgetestet und gegen das reale Zielsystem bestätigt).
- RAG 0.4.0 wird als getrenntes Modul installiert; Quellen bleiben kontrolliert und die Ingestion wird nicht ohne Freigabe automatisch gestartet. Audit, DryRun und Status sind semantisch getrennte Read-only-Modi; Execute (Add/Replace/Remove (plus Skip für bereits aktuelle Quellen)) und Rollback von Add, Replace und Remove sind alle real zielsystemvalidiert, jeweils einschließlich eines als idempotent bestätigten wiederholten Rollback-Aufrufs. Ein echter Fehler im Rollback-Retry-Pfad (ein teilweise fehlgeschlagenes Replace/Remove-Rollback konnte seinen eigenen Retry zum Scheitern bringen, indem es einen Remove-Aufruf gegen bereits entfernten Remote-Inhalt erneut absetzte) wurde über einen dedizierten Teilfehler-Regressionstest gefunden und behoben; die Entfernung gilt beim Retry jetzt als bereits erledigt, passend zum Verhalten des echten Servers. Die globale OpenWebUI-Embedding-Konfiguration wird idempotent mit credential-sicherem Backup/Restore geändert.
- OpenWebUI erhält beim Start die Nomic-Präfixe `search_document:` und `search_query:`.
- LM Studio wird über `winget` installiert; der verwaltete Starter `Start-KIStack-LMStudio.cmd` bringt den lokalen API-Server automatisch hoch — auch bei einem allerersten Greenfield-Lauf, bei dem LM Studios `lms`-CLI noch nicht verfügbar ist. Codex Local benötigt genau diesen Endpunkt; derselbe Starter wird vor der Codex-Local-Konfiguration aufgerufen.
- SearXNGs lokaler Endpunkt wird übernommen, nicht neu installiert, sobald eine bereits gesunde Instanz gefunden wird — entweder unter dem `ki-stack-searxng.service` der Cutover-Runtime-Komponente oder dem `uwsgi.service` der Integration-Komponente, hinter einem `nginx`-Reverse-Proxy mit `valkey-server` als lokalem Speicher.
- Ohne angegebenen OpenWebUI-Administrator-API-Key bleiben der Rollback des temporären Knowledge-Bootstrap-Experiments (unabhängig von der eigentlichen Ingestion des RAG-Moduls) und die Konfiguration der Code-Interpreter-Verbindung manuelle Nacharbeit nach der Installation.
- Der Installer gibt pro Schritt eine Konsolen-Statuszeile aus (`Running`, `Waiting`, `WaitingForUserAction`, `Completed`, `Failed`) mit Zeitstempel sowie einen Heartbeat spätestens alle ~20-30s, solange eine bestehende Warteschleife (etwa die OpenWebUI-Readiness-Prüfung) noch aktiv ist, damit ein länger laufender Schritt nie wie hängengeblieben wirkt. Es gibt keinen Fortschrittsbalken und keine erfundenen Prozentwerte — nur den aktuellen Schritt, die Laufzeit und eine kurze Statusbeschreibung.

Prüfe das ZIP vor dem Entpacken gegen das danebenliegende `.sha256`-Sidecar. Der endgültige ZIP-Hash ist absichtlich nicht im Paket eingebettet.

Installation, Upgrade, Lifecycle, SHA-256, Resume, Recovery und Rollback stehen in `Documentation/INSTALLATION.de.md`.

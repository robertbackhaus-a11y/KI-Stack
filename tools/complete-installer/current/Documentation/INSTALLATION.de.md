# Installation, Upgrade und Betrieb

1. Prüfe `KI-Stack-Complete-Installer-v2.7.0.zip` mit `Get-FileHash -Algorithm SHA256` gegen das danebenliegende `.sha256`-Sidecar.
2. Entpacke das Paket und starte `Start-KIStack-Installer.cmd` mit PowerShell 7.
3. Meldet der Installer nach einer erstmaligen WSL-Aktivierung `NEUSTART ERFORDERLICH` (Exitcode 31), starte Windows neu und führe `Resume-KIStack-Installer.cmd <TransactionId>` aus. Der Zustand `WaitingForRestart` ist fortsetzbar und löst keinen Rollback aus.
4. Bestätige UAC. Ist der OpenWebUI-Visual-Pack-Schritt noch nicht konform, öffnet sich OpenWebUI im Standardbrowser, sobald es und ComfyUI erreichbar sind: führe die Erstanmeldung durch (Admin-Konto anlegen) bzw. melde dich an, erzeuge unter Einstellungen -> Konto -> API-Keys einen neuen API-Key, kehre dann zum Installer zurück und bestätige mit Enter. Gib diesen Key anschließend verdeckt ein; er bleibt ausschließlich im Arbeitsspeicher als `SecureString`, wird nie gespeichert und soll danach widerrufen werden. Der bestehende Visual-Pack-Install-/Validate-Pfad läuft danach mit diesem Key weiter, und eine abschließende Abfrage verlangt genau einen echten Bild- und einen echten Videotest in OpenWebUI, bevor der Schritt akzeptiert wird.
5. Akzeptiere nur `Completed` oder `SkippedAlreadyCompliant`.

Modelle einschließlich des ausschließlich für Embeddings verwendeten `nomic-embed-text-v1.5.Q4_K_M.gguf` werden automatisch aus revisionsgebundenen Quellen geladen. Vorhandene Ziele und optionale Caches/Preloads werden nur nach exakter Größen- und SHA-256-Prüfung wiederverwendet. Teildownloads unterstützen Resume; falsche Größe oder falscher Hash schlägt fehl. Kein Preload ist erforderlich.

## OpenWebUI Visual Pack: Erstanmeldung und API-Key

OpenWebUI und ComfyUI werden vor diesem Schritt jeweils mit einem begrenzten Readiness-Zeitfenster geprüft. `WaitingForUserAction` wird nur gemeldet, wenn beide erreichbar sind, aber noch kein API-Key eingegeben wurde — Fortsetzung durch erneuten Aufruf des Installer-Kommandos, sobald der Key bereitsteht. Bleibt OpenWebUI oder ComfyUI über sein Readiness-Zeitfenster hinaus nicht erreichbar, schlägt der Installer stattdessen mit einem echten Fehler fehl, da keine Benutzeraktion einen nicht laufenden Dienst beheben kann.

## LM Studio und Codex Local

LM Studio wird über `winget` installiert, sein lokaler API-Server wird dabei nicht mitgestartet. Der verwaltete Starter `Start-KIStack-LMStudio.cmd` (unter `C:\KI-Stack\modules\applications`) übernimmt das: Ist LM Studios `lms`-CLI bereits verfügbar, startet er den Server direkt; bei einem allerersten Greenfield-Lauf, bei dem `lms` erst nach Abschluss der eigenen Ersteinrichtung der LM-Studio-GUI unter `%USERPROFILE%\.lmstudio\bin` bereitgestellt wird, startet der Starter einmalig die GUI, wartet begrenzt darauf, dass `lms` erscheint, startet dann den Server und bestätigt, dass er unter `http://127.0.0.1:1234/v1/models` antwortet.

Codex Local benötigt genau diesen Endpunkt. Der Installer ruft den LM-Studio-Starter unmittelbar vor der Konfiguration des Codex-Local-Profils auf, sodass eine normale Installation kein manuelles Starten von LM Studio erfordert. Codex Locals eigenes Warten auf diesen Endpunkt behandelt den Starter als maßgeblichen Timeout-Vertrag: es wartet mindestens so lange wie das legitime Erststart-Zeitfenster des Starters selbst (bis zu ~120s) und beobachtet dessen Prozess/Exitcode, sodass ein echter Starter-Fehlschlag sofort gemeldet wird, statt dass der Aufrufer bei einem kürzeren, unabhängigen Zeitgeber aufgibt, während der Starter noch legitim läuft.

## SearXNG, nginx und Valkey

SearXNGs lokaler Endpunkt läuft unter `uwsgi` hinter einem `nginx`-Reverse-Proxy unter `/searxng`, gestützt durch `valkey-server` als lokalen Ratenlimiter-/Session-Speicher. Er kann bereits durch den eigenen `ki-stack-searxng.service` der Cutover-Runtime-Komponente oder den `uwsgi.service` der Integration-Komponente bereitgestellt sein; beide werden als gültige, bereits laufende Instanz erkannt und übernommen, statt eine zweite, portkonfliktäre Installation zu starten.

## RAG / Knowledge-Ingestion

Das RAG-Modul (0.3.1) wird automatisch unter `C:\KI-Stack\modules\rag` installiert; die Installation prüft nur den eigenen Quellenvertrag und legt die Dateien ab, die OpenWebUI-Suchpräfix-Umgebung wird in den bestehenden OpenWebUI-Starter eingebunden. Sie **ingestiert keine Dokumente**, standardmäßig sind keine Quellen konfiguriert (`Config/sources.json` liefert eine leere Allow-List aus). Zum Ingestieren selbst Einträge in `Config/sources.json` hinzufügen und aus diesem Verzeichnis `Invoke-KIStackRAG.ps1 -Mode Execute -ApiToken <SecureString>` ausführen (Modi: `Audit`, `DryRun`, `Execute`, `Status`, `Rollback`; der Token wird nie gespeichert; `Audit`/`DryRun`/`Status` sind Read-only und mutieren das Ziel nie). `Execute` (Add/Query/Replace/Remove) und `Rollback` aller drei mutierenden Aktionen (Add, Replace, Remove) sind real gegen eine echte OpenWebUI-0.11.0-Instanz zielsystemvalidiert, jeweils einschließlich eines wiederholten `Rollback`-Aufrufs, der als sauberer, idempotenter No-op bestätigt wurde. `Rollback` ist zusätzlich durch eine umfangreiche, gemockte Regressionssuite abgedeckt, einschließlich expliziter Teilfehler-dann-Retry-Abdeckung für den Replace-/Remove-Restore-Pfad. Jede `Execute`-Mutation der globalen OpenWebUI-Embedding-Konfiguration ist idempotent und wird vorher gesichert; ein automatisches Restore bei Fehlschlag oder Rollback erfolgt nur, wenn dieses Backup nachweislich keinen von RAG nicht gespeicherten Credential-Wert enthielt -- andernfalls meldet das Ergebnis `EmbeddingRestoreRequiresManualAction` statt eines destruktiven Teil-Restores.

## Manuelle Nacharbeit: API-Credentials

Ohne angegebenen OpenWebUI-Administrator-API-Key bleiben der Rollback des temporären Knowledge-Bootstrap-Experiments (`CredentialRequiredForApiReadback`, unabhängig von der eigentlichen Ingestion des RAG-Moduls oben) und die Konfiguration der Code-Interpreter-Verbindung (`CredentialRequiredForApiConfiguration`) manuelle Nacharbeit in OpenWebUI nach der Installation.

Lifecycle:

- Start: `Start-KIStack.cmd`
- Stop: `Stop-KIStack.cmd`
- Status: `Status-KIStack.cmd`
- Interaktiver Status: `Lifecycle\Status-KIStack-Interactive.cmd`

Transaktionen liegen unter `C:\KI-Stack\state\complete-installer\<TransactionId>`, Backups unter `C:\KI-Stack\backups\complete-installer\<TransactionId>`.

Codex Local verwendet ausschließlich die vom Paket verwaltete Node.js-Laufzeit unter `C:\KI-Stack\modules\codex-local\runtime`. Das offizielle Node.js-Archiv wird vor der Aktivierung gegen Dateigröße und SHA256 geprüft. Eine globale Node.js-/npm-Installation ist weder Voraussetzung noch Installationsziel.

- Resume: `Resume-KIStack-Installer.cmd <TransactionId>`
- Audit: `Start-KIStack-Audit.cmd`
- Validate: `Start-KIStack-Validate.cmd`
- Repair: `Start-KIStack-Repair.cmd`
- Rollback: `Start-KIStack-Rollback.cmd`

Recovery prüft offene und fehlgeschlagene Transaktionen vor einem neuen Plan. Rollback stellt nur die ausgewählte Transaktion wieder her. Vorhandene konforme Modelle und Nutzerdaten bleiben erhalten.

Der Greenfield-Vertrag wurde mit einer vollständigen, erfolgreichen, realen Installation auf einem leeren Zielsystem verifiziert: alle Schritte wurden abgeschlossen, der Installer beendete sich mit Exitcode 0.

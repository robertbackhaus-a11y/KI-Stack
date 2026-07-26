# Installation, Upgrade und Betrieb

1. Prüfe `KI-Stack-Complete-Installer-v2.3.1.zip` mit `Get-FileHash -Algorithm SHA256` gegen das danebenliegende `.sha256`-Sidecar.
2. Entpacke das Paket und starte `Start-KIStack-Installer.cmd` mit PowerShell 7.
3. Bestätige UAC. Falls abgefragt, gib einen temporären OpenWebUI-Administrator-API-Key verdeckt ein; er wird nie gespeichert und soll danach widerrufen werden.
4. Akzeptiere nur `Completed` oder `SkippedAlreadyCompliant`.

Modelle werden automatisch aus revisionsgebundenen Quellen geladen. Vorhandene Ziele und optionale Caches/Preloads werden nur nach exakter Größen- und SHA-256-Prüfung wiederverwendet. Teildownloads unterstützen Resume; falsche Größe oder falscher Hash schlägt fehl. Kein Preload ist erforderlich.

Lifecycle:

- Start: `Start-KIStack.cmd`
- Stop: `Stop-KIStack.cmd`
- Status: `Status-KIStack.cmd`
- Interaktiver Status: `Lifecycle\Status-KIStack-Interactive.cmd`

Transaktionen liegen unter `C:\KI-Stack\state\complete-installer\<TransactionId>`, Backups unter `C:\KI-Stack\backups\complete-installer\<TransactionId>`.

- Resume: `Resume-KIStack-Installer.cmd <TransactionId>`
- Audit: `Start-KIStack-Audit.cmd`
- Validate: `Start-KIStack-Validate.cmd`
- Repair: `Start-KIStack-Repair.cmd`
- Rollback: `Start-KIStack-Rollback.cmd`

Recovery prüft offene und fehlgeschlagene Transaktionen vor einem neuen Plan. Rollback stellt nur die ausgewählte Transaktion wieder her. Vorhandene konforme Modelle und Nutzerdaten bleiben erhalten.

Der Greenfield-Vertrag wurde mit Quell-/Paketprüfungen und kleinen lokalen Fixtures geprüft. Eine vollständige reale Greenfield-Neuinstallation auf einem leeren Ziel wurde nicht durchgeführt. Die funktionale Validierung wird unverändert von 2.3.0 übernommen.

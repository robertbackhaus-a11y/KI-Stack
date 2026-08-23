# KI-Stack Complete Installer 2.4.0 – Installation und Upgrade

Diese Anleitung gilt für das Stable-Paket `KI-Stack-Complete-Installer-v2.4.0.zip`. Version 2.4.0 wurde mit einer vollständigen, erfolgreichen, realen Greenfield-Installation auf einem leeren Zielsystem verifiziert: alle Schritte wurden abgeschlossen, der Installer beendete sich mit Exitcode 0.

## Download und SHA-256

Lade ZIP und `KI-Stack-Complete-Installer-v2.4.0.zip.sha256` aus demselben GitHub-Release. Der verbindliche Hash steht ausschließlich im Sidecar und in der GitHub-Releasebeschreibung.

```powershell
$zip = '.\KI-Stack-Complete-Installer-v2.4.0.zip'
$expected = ((Get-Content "$zip.sha256" -Raw) -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw 'SHA-256 stimmt nicht überein.' }
```

Entpacke das ZIP erst nach erfolgreicher Prüfung.

## Installation und Upgrade

1. Entpacke das Paket vollständig.
2. Starte `Start-KIStack-Installer.cmd` mit PowerShell 7; bestätige die einmalige UAC-Abfrage.
3. Wenn Visual oder Agent aktualisiert werden, gib einen temporären OpenWebUI-Administrator-API-Key verdeckt ein. Er wird nur im Arbeitsspeicher verwendet, nicht gespeichert und soll anschließend in OpenWebUI widerrufen werden.
4. Warte auf `Completed` oder `SkippedAlreadyCompliant`.

Der Installer verwendet denselben transaktionalen Upgradepfad für Greenfield, Upgrade und Reparaturplanung. Bereits anhand Dateiname, Größe und SHA-256 gültige Modelle werden wiederverwendet. Fehlende Modelle einschließlich `nomic-embed-text-v1.5.Q4_K_M.gguf` werden automatisch aus revisionsgebundenen Quellen geladen. Ein optionaler Cache beziehungsweise `ExternalModels`-Preload ist erlaubt, aber keine Voraussetzung. Teildownloads werden per Resume fortgesetzt; falsche Größe oder SHA-256 führt zu `Failed`.

## Windows-Neustart während Foundation / WSL2-Einrichtung

Der Foundation-Schritt aktiviert WSL2 und richtet die Debian-Laufzeit ein, die von ComfyUI, SearXNG und verwandten Diensten genutzt wird. Auf einer Maschine, auf der WSL2 noch nie aktiviert war, verlangt Windows für den Abschluss dieser Aktivierung einen Neustart. In diesem Fall bricht der Installer mit Exitcode `31` ab und gibt `WINDOWS-NEUSTART ERFORDERLICH` zusammen mit der TransaktionsID aus. Das ist eine normale, fortsetzbare Pause, kein Fehler — es wird kein Rollback ausgelöst.

Nach dem Neustart dieselbe Transaktion fortsetzen:

```powershell
Resume-KIStack-Installer.cmd <TransactionId>
```

Bereits vor dem Neustart abgeschlossene Schritte werden erneut geprüft und übersprungen; der Installer fährt mit dem nächsten offenen Schritt fort.

## LM Studio

LM Studio wird über `winget` installiert. Auf einer wirklich frischen (Greenfield-)Maschine existiert LM Studios eigenes Kommandozeilenwerkzeug `lms` noch nicht — es wird erst unter `%USERPROFILE%\.lmstudio\bin` bereitgestellt, nachdem die LM-Studio-GUI einmal gestartet wurde und ihre eigene Ersteinrichtung abgeschlossen hat.

Der verwaltete Starter `Start-KIStack-LMStudio.cmd` berücksichtigt das automatisch:

- Ist `lms` bereits verfügbar, startet er den lokalen API-Server direkt (`lms server start --port 1234 --bind 127.0.0.1`).
- Bei einem ersten Greenfield-Lauf startet er einmalig die LM-Studio-GUI, wartet begrenzt (nicht endlos) darauf, dass `lms` erscheint, startet dann den lokalen API-Server und wartet, bis dieser unter `http://127.0.0.1:1234/v1/models` antwortet, bevor er fortfährt.

Codex Local benötigt genau diesen erreichbaren Endpunkt (siehe unten); der Complete Installer ruft deshalb denselben verwalteten Starter vor der Codex-Konfiguration auf — LM Studio muss bei einer normalen Installation nicht manuell gestartet werden.

## Codex Local

Codex Local benötigt einen laufenden LM-Studio-Modell-Endpunkt unter `http://127.0.0.1:1234/v1/models`. Der Installer stellt vor der Konfiguration des Codex-Local-Profils sicher, dass LM Studio läuft (siehe oben); ist der Endpunkt nach dem begrenzten Warten weiterhin nicht erreichbar, schlägt der Schritt mit einer klaren Fehlermeldung fehl, statt die Anforderung stillschweigend zu überspringen.

## SearXNG, nginx und Valkey

SearXNGs lokaler Suchendpunkt wird über `uwsgi` hinter einem `nginx`-Reverse-Proxy unter `/searxng` bereitgestellt, gestützt durch `valkey-server` als lokalen Cache/Ratenlimiter-Speicher. Die Cutover-Runtime-Komponente kann ihren eigenen, dedizierten `ki-stack-searxng.service` installieren; die Integration-Komponente erkennt sowohl diesen Dienst als auch ihren eigenen generischen `uwsgi.service` als gültige, bereits laufende SearXNG-Instanz und übernimmt diese, statt eine zweite, portkonfliktäre Installation zu starten.

## Modellrollen

- Heretic ist das einzige Chat-LLM.
- Nomic wird ausschließlich für Embeddings verwendet.
- `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf` wird ausschließlich durch Z-Image verwendet.
- Aktive visuelle Workflows sind ausschließlich Z-Image Turbo und WAN2.2 T2V 14B mit beiden LightX2V-4-Step-LoRAs.
- FLUX, Krea, Pony, WAN-5B/I2V und Legacy-Image-Pack-Verträge sind nicht aktiv.

## Start, Stop und Status

- Start: `Start-KIStack.cmd`
- Stop: `Stop-KIStack.cmd`
- Status: `Status-KIStack.cmd`
- Interaktiver Status: `Lifecycle\Status-KIStack-Interactive.cmd`

Status ist read-only und startet keine Dienste.

## Manuelle Nacharbeit: API-Credentials, Knowledge-Bootstrap, Code Interpreter

Wurde bei der Installation kein OpenWebUI-Administrator-API-Key angegeben, können zwei Abschlussschritte nicht automatisch laufen und bleiben manuelle Nacharbeit:

- Entfernen des temporären Knowledge-Bootstrap-Experiments (unabhängig von der eigentlichen Ingestion des RAG-Moduls, in der finalen Installer-Zusammenfassung als `CredentialRequiredForApiReadback` ausgewiesen).
- Konfiguration der OpenWebUI-Code-Interpreter-Verbindung (als `CredentialRequiredForApiConfiguration` ausgewiesen).

Wird bei einem späteren Lauf (oder über die verdeckte Eingabe desselben Laufs) ein temporärer Administrator-API-Key angegeben, erledigt der Installer diese Schritte automatisch; andernfalls müssen sie anschließend manuell in OpenWebUI nachgeholt werden.

## Resume, Recovery und Rollback

Transaktionen liegen unter `C:\KI-Stack\state\complete-installer\<TransactionId>`, Backups unter `C:\KI-Stack\backups\complete-installer\<TransactionId>`.

- Resume: `Resume-KIStack-Installer.cmd <TransactionId>`
- Read-only Audit: `Start-KIStack-Audit.cmd`
- Read-only Validate: `Start-KIStack-Validate.cmd`
- Reparatur nach Diagnose: `Start-KIStack-Repair.cmd`
- Kontrollierter Rollback: `Start-KIStack-Rollback.cmd`

Resume überspringt abgeschlossene beziehungsweise bereits konforme Schritte. Recovery prüft ausstehende oder fehlgeschlagene Transaktionen vor einem neuen Plan. Rollback stellt nur Änderungen der betroffenen Transaktion aus deren Backup wieder her; vorher vorhandene konforme Modelle und Nutzerdaten bleiben außerhalb des Löschumfangs.

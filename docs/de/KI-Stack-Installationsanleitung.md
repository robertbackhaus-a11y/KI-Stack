# Schnellinstallation

Diese Anleitung gilt für das veröffentlichte Paket **KI-Stack Complete Installer 2.2.6**. Sie beschreibt nur im Paket vorhandene Dateien und den aus den Quellen geprüften Ablauf. Der normale fachliche Einstieg ist `Start-KIStack-Installer.cmd`; die unten dokumentierten Modell-, Audit-, Validate-, Repair- und Rollback-Starter sind Spezialwege.

## Schritt 1 – Paket herunterladen

1. Öffne das Release [complete-v2.2.6](https://github.com/robertbackhaus-a11y/KI-Stack/releases/tag/complete-v2.2.6).
2. Lade `KI-Stack-Complete-Installer-v2.2.6.zip` und den Sidecar `KI-Stack-Complete-Installer-v2.2.6.zip.sha256` aus derselben Release-Seite herunter.
3. Prüfe die ZIP in PowerShell 7:

```powershell
Get-FileHash -LiteralPath .\KI-Stack-Complete-Installer-v2.2.6.zip -Algorithm SHA256
```

Erwarteter SHA256-Wert: `43e24404dec62403588b057415bb30a609bf734bc3cbb3aee80ff05c1d7d057e`.

**Erwartetes Ergebnis:** Der ausgegebene `Hash` stimmt exakt mit diesem Wert und dem Inhalt der Sidecar-Datei überein. **Nächster Schritt:** Nur bei Übereinstimmung entpacken.

## Schritt 2 – Paket entpacken

Entpacke die ZIP in einen kurzen, beschreibbaren Ordner und öffne den obersten entpackten Paketordner. Dort befinden sich nachweislich:

```text
KI-Stack-Complete-Installer-v2.2.6/
├── Start-KIStack-Installer.cmd
├── Start-KIStack-Audit.cmd
├── Start-KIStack-Model-Import.cmd
├── Start-KIStack-Validate.cmd
├── Start-KIStack-Repair.cmd
├── Start-KIStack-Rollback.cmd
├── Start-KIStack.cmd
├── Stop-KIStack.cmd
├── ExternalModels/
└── README.md
```

Der tatsächliche interaktive Status-Starter liegt unter `Lifecycle\Status-KIStack-Interactive.cmd`; ein Root-Starter `Start-KIStack-Status.cmd` existiert nicht. `README.de.md` ist im veröffentlichten ZIP **nicht vorhanden**. Das ist ein dokumentierter Paketfehler gegenüber der erwarteten zweisprachigen Root-Struktur; nicht nach einer Ersatzdatei in Unterordnern suchen.

**Erwartetes Ergebnis:** Alle oben genannten tatsächlichen Dateien sind sichtbar. **Nächster Schritt:** Modelle in `ExternalModels` bereitstellen.

## Schritt 3 – Modelle bereitstellen

Lege Dateien direkt in `ExternalModels` ab; Unterverzeichnisse sind weder erforderlich noch zulässig, weil der Importer nur `<SourcePath>\<Dateiname>` prüft. Die sieben manuellen Dateien sind:

| Manuell bereitzustellen | Zielbereich |
|---|---|
| `flux1-krea-dev_fp8_scaled.safetensors` | `models\diffusion_models` |
| `clip_l.safetensors` | `models\text_encoders` |
| `t5xxl_fp16.safetensors` | `models\text_encoders` |
| `ae.safetensors` | `models\vae` |
| `umt5_xxl_fp8_e4m3fn_scaled.safetensors` | `models\text_encoders` |
| `wan2.2_ti2v_5B_fp16.safetensors` | `models\diffusion_models` |
| `wan2.2_vae.safetensors` | `models\vae` |

`ponyDiffusionV6XL_v6StartWithThisOne.safetensors` ist das einzige automatisch beziehbare Modell; sein Vertrag verwendet ausschließlich die feste Civitai-Modellversion `290640`. Die sieben manuellen Verträge benennen nur Herausgeber und HTTPS-Informationsseite; diese Seiten sind keine installierbaren Payload-Quellen und der Importer lädt dort nie herunter. Alle acht Verträge prüfen Dateiname, Bytegröße und SHA256. Die exakten Werte stehen in `Payload\ModelsWorkflows\...\Manifests\models.manifest.json` beziehungsweise im Paketvertrag; keine andere Datei oder Quelle verwenden.

Führe vor der Installation den zentralen Import aus:

```cmd
Start-KIStack-Model-Import.cmd
```

Ein anderer direkter Übergabeordner ist nachweislich möglich:

```cmd
Start-KIStack-Model-Import.cmd -SourcePath "D:\KI-Modelle"
```

`Start-KIStack-Installer.cmd` startet den öffentlichen Modellimport nicht selbst. Daher zuerst diesen Import ausführen, sobald Modelle fehlen oder neu bereitgestellt wurden. `AlreadyCompliant` bedeutet, dass alle geprüften Zielmodelle bereits exakt passen. `WaitingForUserAction` nennt Datei, erwartete Bytegröße, SHA256 und Quellordner; Datei dort direkt ablegen und mit der ausgegebenen Resume-Anweisung fortsetzen. Eine vorhandene Datei mit falscher Größe oder SHA256 bleibt ungültig und wird nicht übernommen.

**Erwartetes Ergebnis:** `Completed` oder `AlreadyCompliant`; bei manuellen Lücken `WaitingForUserAction`. **Nächster Schritt:** Bei Erfolg den Installer starten; bei Wartezustand die fehlende Datei bereitstellen.

## Schritt 4 – Installation starten

1. Den obersten Paketordner im Explorer öffnen.
2. `Start-KIStack-Installer.cmd` verwenden.
3. Keine einzelnen Modulskripte manuell starten.

Der Starter ruft nachweislich `Invoke-KIStackCompleteInstaller.ps1 -Mode Upgrade` auf. Er plant Komponenten, prüft PowerShell 7, die Paket-Payloads, Administratorstatus, Ports und die Konformität vorhandener Komponenten. Verwaltete Komponenten umfassen Cutover Runtime, ComfyUI, Models/Workflows, Integration, OpenWebUI Agent/Image und optional Ballistics; bereits konforme Inhalte werden übersprungen.

`Start-KIStack-Installer.cmd` startet den vorhandenen PowerShell-7-Einstieg. Dieser fordert bei Bedarf genau einmal UAC an, verhindert eine Elevationsschleife und reicht den Exitcode durch. Die UAC-Abfrage bestätigen.

Erforderliche Benutzereingaben können eine OpenWebUI-Erstanmeldung oder ein temporärer Administrator-API-Key sein. Der Key darf nur verdeckt als `SecureString` eingegeben, nie in Dateien oder Befehlszeilen gespeichert und danach in OpenWebUI widerrufen werden. Ein erfolgreicher Ablauf meldet `Completed`; `SkippedAlreadyCompliant` bedeutet, dass alle Komponenten bereits konform waren. Transaktionsdateien liegen unter `C:\KI-Stack\state\complete-installer\<TransactionId>\`; Backups unter `C:\KI-Stack\backups\complete-installer\<TransactionId>\`.

**Nächster Schritt bei Fehler:** Zuerst die Transaktionsdatei lesen, dann Resume, Validate, Repair oder Rollback nur wie unten beschrieben verwenden.

## Schritt 5 – Unterbrechung und Resume

`Resume-KIStack-Installer.cmd` ist der öffentliche Resume-Starter. Ohne Argument fragt er verständlich nach der TransactionId; alternativ lautet der vollständige Aufruf:

```powershell
& .\Invoke-KIStackCompleteInstaller.ps1 -Mode Upgrade -TransactionId "<TransactionId>" -Resume
```

`<TransactionId>` steht in `C:\KI-Stack\state\complete-installer\<TransactionId>\transaction.json`; die zugehörige Resume-Datei heißt `resume.json` im selben Ordner. Der Resume-Code liest `transaction.json`, überspringt `Completed` und `SkippedAlreadyCompliant` und setzt beim ersten offenen Schritt fort. Für den Modellimport lautet die vom Importer ausgegebene Form:

```powershell
.\Import-KIStackExternalModels.ps1 -SourcePath "<SourcePath>" -TransactionId "<TransactionId>" -Resume
```

Bei `WaitingForUserAction` zuerst in OpenWebUI anmelden oder die geforderte Modellquelle bereitstellen. Wenn Agent oder Image geändert werden müssen, fragt der bereits erhöhte Prozess den temporären API-Key genau einmal verdeckt als `SecureString` ab und verwendet ihn nur im Arbeitsspeicher für beide Schritte. Sind beide bereits konform, erfolgt keine Abfrage. Nach jeder erlaubten Schlüsselverwendung den temporären Key in OpenWebUI widerrufen.

**Erwartetes Ergebnis:** Abgeschlossene Schritte bleiben übersprungen; der nächste offene Schritt wird fortgesetzt. **Nächster Schritt:** Nach Abschluss validieren.

## Schritt 6 – Installation prüfen

Starte `Start-KIStack-Validate.cmd` per Doppelklick oder aus einer PowerShell-7-Konsole im Paketordner:

```powershell
& .\Start-KIStack-Validate.cmd
```

Der Starter ruft `-Mode Validate` auf. Er prüft read-only die konfigurierten Health-Endpunkte für LM Studio (`/v1/models`), ComfyUI, OpenWebUI, SearXNG HTML und SearXNG JSON-Suche sowie die Betriebsprüfung. Ein erfolgreicher JSON-Status enthält `health` und `operations` ohne Fehler. Ein Fehlerstatus bedeutet keine automatische Reparatur: zuerst Status und Transaktion prüfen.

Der Validate-Starter erzeugt laut aktuellem Code keinen eigenen Reportpfad; seine Ausgabe geht an die Konsole. Installer-Transaktionen und Logs liegen unter `C:\KI-Stack\state\complete-installer` und `C:\KI-Stack\logs\complete-installer`.

**Nächster Schritt:** Den Stack starten oder bei Fehlern Audit/Repair/Rollback wählen.

## Schritt 7 – KI-Stack verwenden

Start: `Start-KIStack.cmd`. Stop: `Stop-KIStack.cmd`. Der tatsächliche interaktive Status-Starter ist `Lifecycle\Status-KIStack-Interactive.cmd`; die installierte Desktop-Verknüpfung **KI-Stack Status** startet `Lifecycle\Show-KIStackStatus.ps1` mit PowerShell 7 und bleibt bis Tastendruck sichtbar. Die vorgesehenen Desktop-Verknüpfungen heißen **KI-Stack Start**, **KI-Stack Stop** und **KI-Stack Status**.

Verifizierte lokale Oberflächen:

| Oberfläche | Adresse |
|---|---|
| OpenWebUI | `http://127.0.0.1:8080` |
| LM Studio API | `http://127.0.0.1:1234/v1/models` |
| ComfyUI | `http://127.0.0.1:8188` |
| SearXNG | `http://localhost/searxng/` |

**Erwartetes Ergebnis:** Status zeigt Läuft, Gestoppt oder Fehler und startet nichts. **Nächster Schritt:** OpenWebUI oder ComfyUI öffnen.

## Schritt 8 – Upgrade

Neues Paket entpacken, Modelle bei Bedarf vorher mit `Start-KIStack-Model-Import.cmd` konform bringen und anschließend `Start-KIStack-Installer.cmd` als Administrator verwenden. Der Plan liest vorhandene Komponentenmarker; `AlreadyCompliant`/`SkippedAlreadyCompliant` bedeutet, dass passende vorhandene Inhalte erhalten bleiben. Nutzermodelle, Workflows, Chats, Prompts, Uploads und andere Nutzdaten werden nicht als Upgrade-Ziel gelöscht. `ExternalModels` ist nur erneut erforderlich, wenn ein manueller Modellvertrag fehlt oder nicht mehr exakt passt.

## Schritt 9 – Fehlerbehebung

| Anzeige oder Fehler | Bedeutung | Exakt auszuführender Starter | Nächster Schritt |
|---|---|---|---|
| PowerShell 7 fehlt / Exitcode 70 | `pwsh.exe` wurde nicht gefunden | Keiner | PowerShell 7 installieren, danach denselben Starter erneut ausführen. |
| Administratorrechte erforderlich | Upgrade/Repair benötigt erhöhten Prozess | `Start-KIStack-Installer.cmd` | PowerShell 7 oder CMD als Administrator öffnen und den Starter von dort ausführen. |
| WSL2 oder Debian fehlt | Preflight kann die Linux-Dienstkette nicht prüfen | `Start-KIStack-Audit.cmd` | Audit-Ausgabe lesen; WSL2/Debian bereitstellen, nicht manuell an Paketmodulen ändern. |
| Modell fehlt | Manueller Vertrag ist nicht in direktem Quellordner | `Start-KIStack-Model-Import.cmd` | Exakte Datei in `ExternalModels` legen und Import wiederholen. |
| Modell-SHA256 falsch | Datei entspricht nicht dem Vertrag | `Start-KIStack-Model-Import.cmd` | Falsche Datei entfernen/ersetzen; keine Übernahme erzwingen. |
| `WaitingForUserAction` | Modell oder OpenWebUI-Aktion ist offen | Resume-Aufruf aus Schritt 5 | Voraussetzung erfüllen und mit derselben TransactionId fortsetzen. |
| Abgebrochene Transaktion | `transaction.json` enthält offene Schritte | Resume-Aufruf aus Schritt 5 | Bericht lesen, dann Resume; bei unlösbarem Fehler Rollback. |
| Validierung fehlgeschlagen | Health oder Operations fehlerhaft | `Start-KIStack-Validate.cmd` | Status prüfen, keine automatische Reparatur annehmen. |
| Dienst oder Port nicht erreichbar | Status-/Healthcheck meldet Gestoppt oder Fehler | `Lifecycle\Status-KIStack-Interactive.cmd` | Status lesen; danach `Start-KIStack.cmd` nur für bewusstes Starten verwenden. |
| Repair erforderlich | Verwalteter Zustand ist beschädigt | `Start-KIStack-Repair.cmd` | **Warnung:** Nur nach Audit/Transaktionsprüfung und als Administrator ausführen. |
| Rollback erforderlich | Eine aktive Transaktion soll rückgängig gemacht werden | `Start-KIStack-Rollback.cmd` | **Warnung:** Nur die aktuelle Complete-Installer-Operation wird zurückgerollt; vorher Bericht lesen. |

## Bedienmatrix

| Zweck | Datei | Startart | Administratorrechte | Wann verwenden |
|---|---|---|---|---|
| Installation/Upgrade | `Start-KIStack-Installer.cmd` | erhöhter Explorer-/Konsolenstart | Ja | Normaler Installationsweg nach Modellimport. |
| Modellaudit/Import | `Start-KIStack-Model-Import.cmd` | Doppelklick oder Konsole; Argumente möglich | Für Zieländerung erforderlich | Vor Installation bei fehlenden Modellen. |
| Audit | `Start-KIStack-Audit.cmd` | Doppelklick oder Konsole | Nein | Read-only Inventar und Plan. |
| Validate | `Start-KIStack-Validate.cmd` | Doppelklick oder Konsole | Nein | Read-only Health- und Betriebsprüfung. |
| Repair | `Start-KIStack-Repair.cmd` | erhöhte Konsole | Ja | Nur nach Diagnose. |
| Rollback | `Start-KIStack-Rollback.cmd` | erhöhte Konsole | Ja | Nur für kontrolliertes Zurückrollen. |
| Start | `Start-KIStack.cmd` | Doppelklick oder Konsole | Abhängig vom installierten Lifecycle | Bewusster zentraler Start. |
| Stop | `Stop-KIStack.cmd` | Doppelklick oder Konsole | Abhängig vom installierten Lifecycle | Kontrollierter zentraler Stopp. |
| Status | `Lifecycle\Status-KIStack-Interactive.cmd` | Doppelklick | Nein | Read-only Status mit sichtbarem Fenster. |
| Selbsttest | `Start-KIStack-Complete-Installer-SelfTest.cmd` | Konsole | Nein | Paketentwicklungsprüfung, nicht für den normalen Nutzerweg. |

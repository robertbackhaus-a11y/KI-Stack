# KI-Stack Betriebs- und Benutzerhandbuch

## 1. Voraussetzungen und Installation

Verwende unterstütztes Windows mit WSL2/Debian, PowerShell 7, die freigegebene lokale Installation von LM Studio, OpenWebUI und ComfyUI, ausreichend Speicher für 47.356.936.991 Bytes externer Modelle sowie die jeweiligen Modelllizenzen. Entpacke den Complete Installer, halte seine Dateien zusammen und verwende seinen öffentlichen Starter für Installation oder Upgrade. Führe Paketskripte nicht mit Windows PowerShell aus. Das Paket ist zur Laufzeit Git-frei, aber nicht offline.

Für ein Upgrade stoppe den Stack über die verwaltete Stop-Verknüpfung, behalte bereits konforme Dateien bei, starte den Installer und befolge eine mögliche Aufforderung `WaitingForUserAction`. Überschreibe keine Nutzermodelle, Workflows, Chats oder privaten Daten, um Konformität zu erzwingen.

## 2. Bereitstellung externer Modelle

Lege manuell bereitgestellte Modelldateien direkt in `ExternalModels` neben dem entpackten Models-/Workflows-Paket oder verwende einen anderen direkten Ordner. Starte den zentralen Importer mit:

```cmd
Start-KIStack-Model-Import.cmd
```

Um einen anderen Ordner zu wählen, reiche alle Argumente unverändert an den CMD-Starter weiter:

```cmd
Start-KIStack-Model-Import.cmd -SourcePath "D:\\ExternalModels"
```

Der Importer prüft jedes vorhandene Ziel und jede Quellkandidatin nach exaktem Dateinamen, Bytegröße und SHA256. Korrekte Ziele sind `AlreadyCompliant`. Eine geprüfte Quelle wird als `.partial` kopiert und atomar verschoben. Fehlende manuelle Modelle führen zu `WaitingForUserAction` mit der genau benötigten Datei, Größe, SHA256 und Quellordner; nach Bereitstellung wird derselbe Befehl zur Fortsetzung erneut ausgeführt. Benutzerverzeichnisse werden nicht als einziger Bereitstellungsweg durchsucht. Pony darf nur seinen festen Civitai-Modellversionsvertrag 290640 verwenden; Git-, Commit- und `latest`-Quellen werden nicht verwendet.

## 3. Start, Stop und Status

Verwende die Desktop-Verknüpfungen `KI-Stack Start`, `KI-Stack Stop` und `KI-Stack Status`. Start startet die verwalteten Dienste; Stop beendet sie zentral. Status ist read-only, benötigt keine Administratorrechte und meldet LM Studio, `/v1/models`, OpenWebUI, SearXNG HTML/JSON, ComfyUI, WSL-Keeper, valkey-server, uwsgi und nginx als Läuft, Gestoppt oder Fehler. Das interaktive Statusfenster zeigt seinen Exitcode und bleibt bis zum Tastendruck offen. Status repariert oder startet keine Dienste.

Vor einem geplanten Neustart zentral stoppen. Nach dem Neustart prüfen, dass kein KI-Stack-Prozess, Listener, automatischer Dienst oder stale PID existiert, bevor Start verwendet wird. Der Stack benötigt keinen Windows-Autostart, keine Boot-/Anmeldeaufgabe, keinen Run/RunOnce-Eintrag, keinen Autostartordner-Eintrag, keinen LM-Studio-Autostart, keinen OpenWebUI-Autostart, keinen ComfyUI-Autostart und keinen WSL-Keeper-Autostart. Debian valkey-server, uwsgi und nginx sind für den automatischen Start deaktiviert, aber manuell startbar.

## 4. OpenWebUI

Öffne die von Status angezeigte lokale OpenWebUI-Adresse. Verwende `Allgemein` für allgemeine lokale Assistenz und `KI & IT-Technik` für technische Arbeit. Beide haben Native Function Calling, `knowledge=[]`, ausschließlich die Bildtoolbindung und den browserlokalen Pyodide-Code-Interpreter. Verwende `18Bravo` ausschließlich für rechtmäßige sportliche, jagdliche und technische Ballistikberechnungen; es hat nur das Ballistiktool, keinen Code Interpreter und keine Knowledge-Bindung.

Der Code Interpreter ist in OpenWebUI eingebaut: Pyodide, kein Jupyter, Open Terminal, Docker, zusätzlicher Dienst oder dateiübergreifende Browserneustart-Persistenz. Er kann nicht auf Windows, Shell oder `C:\\KI-Stack` zugreifen. `execute_code` wird nicht als normale Tool-ID ergänzt. Widerrufe jeden temporären OpenWebUI-API-Key unmittelbar nach administrativer oder Validierungsarbeit.

Die Websuche verwendet SearXNG. Bei Fehlern zuerst Status verwenden und die SearXNG-HTML- und JSON-Ergebnisse prüfen; keinen doppelten Dienst erzeugen. Normale Chats funktionieren ohne RAG, weil alle verwalteten Profile `knowledge=[]` verwenden.

## 5. Bild- und Workflowverwendung

Die Profile `Allgemein` und `KI & IT-Technik` verwenden dieselbe freigegebene Bildbindung. Erzeugte FLUX2-Bilder erscheinen direkt im Chat und behalten nach dem Neuladen einen anklickbaren Download. Ein gültiges Chatergebnis enthält keinen `/mnt/uploads`-, Windows- oder ComfyUI-Pfad.

Öffne ComfyUI über die lokal konfigurierte Adresse. Freigegebene Workflows sind FLUX2 UI, FLUX2 API (von OpenWebUI verwendet), KREA Realism, Pony SDXL und WAN 2.2 Official. Verwende nur die in Workflow- und Modellverträgen benannten Dateien. FLUX2 UI verwendet standardmäßig 512×512, Batch 1 und die eingecheckten Samplerwerte. KREA und Pony erzeugen Bilder; WAN schreibt seine Videoausgabe in den workflowdefinierten Videoausgabeort. Installiere keine fehlenden Custom Nodes und ersetze keine ungeprüften Modelle.

## 6. Audit, Validate, Repair, Resume und Rollback

Verwende die öffentlichen Complete-Installer-Starter für Audit, Validate, Repair, Resume und Rollback. Audit und Validate sind read-only. Repair ist transaktionsgesichert und muss ausdrücklich gewählt werden. Resume setzt die aufgezeichnete Transaktion fort, nachdem eine fehlende Abhängigkeit bereitgestellt wurde. Rollback stellt nur Backups dieser Transaktion wieder her und entfernt nur transaktionserzeugte Dateien; bereits vorher konforme Modelle bleiben unverändert. Lies den Transaktionsbericht vor dem Wiederholen eines fehlgeschlagenen Schritts.

Für Logs und Diagnose verwende das gemeldete Transaktionsverzeichnis, den Paketvalidierungsbericht und die Statusübersicht. Veröffentliche keine Logs mit Benutzerpfaden, API-Keys, rohen OpenWebUI-Exporten, Testbildern oder Backups. Typische sichere Lösungen sind: PowerShell 7 installieren, wenn ein Starter Exitcode 70 liefert; die exakt fehlende Modelldatei nach `ExternalModels` legen; Repair erst nach Lesen des Fehlers verwenden; bei ungelöstem Transaktionsfehler Rollback verwenden; und einen gestoppten Dienst vor dem Start über Status prüfen.

## 7. Kontrollierter Stopp und Entfernung

Für das normale Herunterfahren `KI-Stack Stop` verwenden und über Status bestätigen, dass keine verwalteten Listener oder stale PID-Dateien verbleiben. Eine vollständige Entfernung ist ein kontrollierter Wartungsvorgang: zuerst stoppen, Nutzermodelle, Workflows, Chats, Prompts, Uploads, Browserdaten und fremde Tools erhalten und anschließend nur ausdrücklich identifizierte verwaltete KI-Stack-Inhalte und Transaktionsbackups nach Prüfung entfernen. WSL-Distributionen, Benutzerprofile oder gemeinsame Modellordner dürfen nicht als generische Deinstallationsmaßnahme gelöscht werden.

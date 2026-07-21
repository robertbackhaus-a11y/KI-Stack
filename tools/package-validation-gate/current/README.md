# KI-Stack Universal Package Validation Gate v1.0.2

Dieses Paket macht die vollständige Code- und Paketvalidierung zu einem verbindlichen Release-Gate für alle künftig erzeugten KI-Stack-Pakete.

## Verbindlicher Freigabevertrag

Ein neues KI-Stack-Paket wird nicht freigegeben, wenn nicht mindestens der Status `NATIVE_PACKAGE_VALIDATION_PASSED` erreicht wurde. Zielsystempakete benötigen zusätzlich eine gesonderte reale Zielsystemabnahme, bevor `TARGET_SYSTEM_ACCEPTANCE_PASSED` vergeben werden darf.

Jedes künftige Paket muss enthalten:

- `VERSION`
- `SHA256SUMS.txt` mit exakt vollständigem Dateisatz
- `Validation/VALIDATION-CONTRACT.json`
- einen nativen Paket-Selbsttest
- alle auf den Pakettyp anwendbaren Regressionstests

## Korrektur v1.0.1

Der native Selbsttest prüft den exakten Paketdateisatz jetzt vor jeder ausführbaren Prüfung. Python-Unit-Tests und der importierte Validator werden ausschließlich aus einer isolierten temporären Kopie mit `-B` und `PYTHONDONTWRITEBYTECODE=1` ausgeführt. Ein vollständiger Vorher-/Nachher-Snapshot weist jede Selbstmutation des ausgelieferten Pakets ab.

## Aktivierung und Installation

`Start-Activate-KIStack-ValidationGate.cmd` starten. Der Starter führt zuerst den vollständigen nativen Selbsttest aus und installiert den Gate nur bei Erfolg. Die Selbst-Elevation erfolgt anschließend automatisch.

`Start-Install-KIStack-ValidationGate.cmd` ist nur für eine erneute Installation eines bereits erfolgreich getesteten Pakets vorgesehen.

Installationsziel:

`C:\KI-Stack\Tools\PackageValidationGate\current`

## Einzelnes Paket validieren

ZIP auf `Start-Validate-KIStack-Package.cmd` ziehen oder den Starter aufrufen und den vollständigen ZIP-Pfad eingeben.

Das Gate prüft das endgültige ZIP nach frischer Extraktion. Ein Arbeitsordner allein kann keine Freigabe erhalten.

## Automatische Verwendung durch künftige Builder

Jeder neue Paketbuilder ruft nach dem atomaren Erzeugen des finalen ZIPs auf:

`Integration\Invoke-KIStack-ReleaseGate.ps1`

Der Builder muss bei einem Gate-Exitcode ungleich 0 abbrechen und darf das Paket nicht als veröffentlicht oder freigegeben markieren.

Für neue Builder ist `Integration\Publish-KIStack-Package.ps1` der verbindliche Finalisierungspfad. Er erzeugt das SHA256-Manifest, baut das finale ZIP in einem Staging-Verzeichnis, validiert genau dieses ZIP und verschiebt es erst nach bestandenem Gate in den Veröffentlichungsordner. `Integration\New-KIStack-ValidationContract.ps1` erzeugt den verpflichtenden Paketvertrag.

## Prüfebenen

- unabhängige Python-Gegenprüfung von ZIP, SHA256, exaktem Dateisatz, JSON, YAML, Python, CMD/BAT und verschachtelten Archiven
- nativer PowerShell-Parser und AST
- Prüfung tatsächlicher statt nur textlich erwähnter Repository-Befehle
- Ausführung des Selbsttests aus dem final entpackten ZIP
- bekannte Regressionsmuster und Pfadsicherheitsregeln
- maschinenlesbarer JSON- und lesbarer Markdown-Bericht

## Selbsttest

`Start-KIStack-ValidationGate-SelfTest.cmd`

Der Selbsttest erzeugt reale Testpakete und weist unter anderem zusätzliche, fehlende, veränderte und unsichere Inhalte sowie tatsächliche verbotene Befehle nach.

## Statuslogik

- `REJECTED`: mindestens eine Prüfung fehlgeschlagen
- `STATIC_VALIDATION_PASSED`: nur plattformunabhängige Prüfung bestanden; keine Releasefreigabe
- `NATIVE_PACKAGE_VALIDATION_PASSED`: native Paketprüfung und realer Selbsttest bestanden
- `TARGET_SYSTEM_ACCEPTANCE_PASSED`: ausschließlich nach echter Zielsystemprüfung

## Korrektur v1.0.2

Das äußere neu gebaute Paket bleibt vollständig strikt. Unveränderliche verschachtelte Altarchive ohne eigenen Validation-Contract werden nicht rückwirkend nach neuen Formatregeln abgewiesen; Pfadsicherheit, vollständige Lesbarkeit, Duplikate, Symlinks und alle im vorhandenen Manifest deklarierten Hashwerte bleiben zwingend.

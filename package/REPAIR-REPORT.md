# Reparatur- und Prüfbericht v1.1.5

## Fehlerbild

v1.1.4 startet korrekt, führt die automatische UAC-Elevation aus und erzeugt
einen Selbsttestbericht. Der vorgeschaltete Selbsttest endet jedoch mit
Exitcode 1.

## Tatsächliche Ursache

Der Test `PythonGit Dry-Run` verwendete ein selbst erzeugtes Teilobjekt als
Konfiguration. Darin fehlte `pythonEnvironment.pipUpgrade`.

Das PythonGit-Modul liest im Dry-Run unter anderem:

- `pythonEnvironment.bootstrapUv`
- `pythonEnvironment.pipUpgrade`
- `gitEnvironment.longPaths`

Unter `Set-StrictMode -Version Latest` ist der Zugriff auf eine nicht vorhandene
Property ein Fehler. Der Selbsttest testete daher nicht das Fachmodul, sondern
scheiterte an seinem eigenen unvollständigen Fixture.

## Nachhaltige Korrektur

Nicht nur `pipUpgrade` wurde ergänzt. Sämtliche Dry-Run-Modultests beziehen ihre
Konfiguration nun direkt aus der vollständigen Releasekonfiguration. Dadurch
können neue Konfigurationsfelder nicht erneut durch veraltete Teil-Fixtures zu
falschen Selbsttestabbrüchen führen.

Zusätzlich wird bei jedem künftigen Fehler unmittelbar ausgegeben:

- Name des fehlgeschlagenen Tests
- vollständige Testmeldung
- Pfad des JSON-Berichts

## Unveränderte Referenzbestandteile

Bytegleich gegenüber v1.1.4:

- Modules/01-Foundation/KIModuleFoundation.psm1
- Modules/01-Foundation/module.json
- Modules/02-Runtime/KIModuleRuntime.psm1
- Modules/02-Runtime/module.json
- Modules/03-PythonGit/KIModulePythonGit.psm1
- Modules/03-PythonGit/module.json

Foundation/Runtime v1.0.9 bleibt eingefrorener Referenzstand.

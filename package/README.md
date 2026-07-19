# KI-Stack PythonGit Execute v1.1.5

## Status

Vollständige korrigierte Nachfolgeversion von v1.1.4.

Referenzstand bleibt unverändert:

- KI-Stack-Foundation-Runtime-Execute-v1.0.9
- letzte erfolgreiche Foundation/Runtime-Transaktion: KI-STACK-TX-20260719-110527

Foundation-, Runtime- und PythonGit-Fachmodule wurden bytegleich übernommen.

## Ursache des v1.1.4-Abbruchs

Der Selbsttest `PythonGit Dry-Run` erzeugte eine handgeschriebene, unvollständige
Konfiguration. Die Property `pythonEnvironment.pipUpgrade` fehlte. Das
PythonGit-Modul greift im Dry-Run auf diese Property zu. Unter
`Set-StrictMode -Version Latest` führt der Zugriff auf eine fehlende Property zu
einem Fehler und damit zu Exitcode 1.

## Korrekturen v1.1.5

- Alle Modul-Dry-Run-Tests verwenden die vollständige echte
  `Config/kernel-config.json`.
- Direkter Regressionstest auf vollständige PythonGit-Konfiguration inklusive
  `pipUpgrade`.
- Keine handgebauten Teilkonfigurationen mehr für Runtime, DownloadManager,
  PythonGit, ComfyUI, Applications und Integration.
- Bei Selbsttestfehlern zeigt Konsole und Starter sofort Testname und Meldung.
- Vollständige historische Regressionsmatrix bleibt aktiv.

## Startreihenfolge

1. Start-Nur-Selbsttest.cmd
2. Start-KIStack-PythonGit-DryRun.cmd
3. Start-KIStack-PythonGit-Execute.cmd
4. UAC bestätigen
5. EXECUTE eingeben

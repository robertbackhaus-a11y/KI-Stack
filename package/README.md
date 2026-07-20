# KI-Stack Applications Execute v1.4.10

## Korrektur v1.4.10

- GitHub-Bundle-Validator prüft Git-Autorparameter und Identitätsaufruf ausschließlich mit nicht expandierbaren PowerShell-Literalen.
- `Set-StrictMode` kann im Validator keine nicht definierten Publishervariablen mehr auswerten.
- Integriertes GitHub-Update v0.3.10.

## Korrektur v1.4.9

- Der integrierte GitHub-Publisher setzt Git-Autorname und -E-Mail repository-lokal im temporären Clone.
- Commit und annotierte Tags funktionieren auch ohne globale Git-Identität.
- Die globale Git-Konfiguration wird nicht verändert.
- Integriertes GitHub-Update v0.3.9.


## Korrektur v1.4.9

- Versionskonsistenz wird nur über autoritative Felder bewertet; historische Hinweise bleiben zulässig.
- Integrierter GitHub-Wrapper und Bundle-Validator verwenden keine uninitialisierte `$LASTEXITCODE`-Variable mehr.
- Integriertes GitHub-Update v0.3.9.


## Korrektur v1.4.9

- Applications v1.4.5 ist zielsystemvalidiert; v1.4.9 korrigiert die GitHub-/Snapshot-Verpackung.
- Historische Snapshots bleiben bytegenau und werden nur noch über feste Git-Tree-Hashes erkannt.
- Integriertes GitHub-Update v0.3.9.


## Korrektur v1.4.9

- Persistente CMD-Diagnosesitzung vollständig wiederhergestellt.
- Einstiegsstarter verwenden `cmd /K`; der Bootstrap kehrt am Ende ausschließlich mit `exit /b` zurück.
- Neuer End-to-End-Regressionscheck prüft die gesamte Startkette.
- Integriertes GitHub-Update v0.3.9.

Sechster transaktionsgesicherter Baustein des KI-Stacks.

## Referenzstände

- Foundation/Runtime v1.0.9
- PythonGit v1.1.5
- ComfyUI v1.2.1
- Models/Workflows v1.3.7

## Anwendungen

- LM Studio über den exakten winget-Paketbezeichner `ElementLabs.LMStudio`; vorhandene Installationen werden wiederverwendet.
- Open WebUI ist reproduzierbar auf Version `0.10.2` gepinnt und wird im isolierten Venv `C:\KI-Stack\python\venvs\openwebui` installiert.
- Persistente Daten liegen unter `C:\KI-Stack\OpenWebUI\data`.
- Open WebUI ist initial für den lokalen OpenAI-kompatiblen LM-Studio-Endpunkt `http://127.0.0.1:1234/v1` vorbereitet.
- Beide Dienste binden standardmäßig ausschließlich an `127.0.0.1`.

## Erzeugte Laufzeitstarter

Nach erfolgreichem Execute:

- `C:\KI-Stack\modules\applications\Start-KIStack-LMStudio.cmd`
- `C:\KI-Stack\modules\applications\Start-KIStack-OpenWebUI.cmd`
- `C:\KI-Stack\modules\applications\Start-KIStack-Applications.cmd`
- `C:\KI-Stack\modules\applications\Stop-KIStack-Applications.cmd`

## Paketstart

1. `Start-Nur-Selbsttest.cmd`
2. `Start-KIStack-Applications-DryRun.cmd`
3. `Start-KIStack-Applications-Execute.cmd`
4. UAC bestätigen und `EXECUTE` eingeben.
5. Nach erfolgreichem Zielsystemlauf `Start-Validate-GitHub-Update.cmd` und `Start-Publish-GitHub-Update.cmd` ausführen.

Das Paket enthält einen eingebetteten Fortsetzungs-Preflight und benötigt kein separates Preflight-ZIP.

## Korrekturen v1.4.9

- Vollständiger Transaktionskontext im Applications-Dry-Run-Selbsttest.
- Referenztests verwenden konsistent Kernel/Release v1.4.9.
- Python-Auflösungsprüfung entspricht der tatsächlichen Implementierung und schließt WindowsApps-Aliase aus.
- Eingebetteter GitHub-Wrapper verwendet durchgängig v0.3.9.

## Korrekturen v1.4.9

- Vollstaendige Konsolidierung aller aktiven Versionsquellen.
- Robuster Python-Aufloesungs-Regressionsvertrag.
- Permanentes Gate gegen gemischte aktive Paketversionen.
- Integriertes GitHub-Update v0.3.9.

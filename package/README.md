# KI-Stack Models/Workflows Execute v1.3.7

Dieses Paket setzt auf den validierten Referenzständen auf:

- Foundation/Runtime v1.0.9
- PythonGit v1.1.5
- ComfyUI v1.2.1

## Freigegebener Pflichtumfang

Das Execute-Modul richtet den vollständigen FLUX.2-Klein-9B-Bildstack ein:

- `flux-2-klein-9b-fp8.safetensors`
- `qwen_3_8b_fp8mixed.safetensors`
- `flux2-vae.safetensors`

Alle drei Dateien werden anhand von Dateigröße und SHA-256 geprüft. Bereits vorhandene gültige Dateien werden wiederverwendet. Danach werden bekannte lokale Modellpfade durchsucht. Nur fehlende verwaltete Dateien werden aus den offiziellen Hugging-Face-Repositories geladen.

Das BFL-Diffusionsmodell ist zugriffsgeschützt. Vor dem Execute müssen die Lizenzbedingungen im eigenen Hugging-Face-Konto akzeptiert sein. Das Paket fragt bei Bedarf verdeckt nach einem Read-Token und speichert ihn benutzergebunden mittels Windows-DPAPI/`Export-Clixml`. Tokens werden nicht protokolliert.

## Workflows

Installiert werden:

- FLUX.2 Klein 9B – ComfyUI UI/API
- FLUX.2 Klein 9B – flacher Open-WebUI-API-Workflow
- KREA Realism – vorhandener Projektworkflow
- Pony Control QuickTest v2 – vorhandener Projektworkflow

KREA- und Pony-Gewichte werden aus vorhandenen Beständen übernommen, aber nicht aus inoffiziellen Quellen heruntergeladen. Fehlen sie, bleiben nur diese beiden optionalen Workflows zunächst nicht ausführbar. FLUX.2 Klein 9B ist Pflicht und wird vollständig validiert.

## Startreihenfolge

1. `Start-Nur-Selbsttest.cmd`
2. `Start-KIStack-ModelsWorkflows-DryRun.cmd`
3. `Start-KIStack-ModelsWorkflows-Execute.cmd`
4. UAC bestätigen
5. `EXECUTE` eingeben

Modelldownloads sind fortsetzbar. Partielle Dateien enden auf `.partial`. Ungültige vorhandene Zieldateien werden nicht überschrieben.

## Verbindliches Syntax-Gate ab v1.3.1

Vor SelfTest, DryRun und Execute wird `Tests\Test-KIStackPowerShellSyntax.ps1`
ausgeführt. Das Skript verwendet den nativen PowerShell-AST-Parser für sämtliche
`.ps1`- und `.psm1`-Dateien. Ein Parserfehler blockiert jede weitere Ausführung
und wird unter `State\Syntax\PowerShell-Syntax-latest.json` protokolliert.

## Korrektur v1.3.2

Der Syntax-Gate-Selbsttest wertet `Test-Path` vor der booleschen Verknüpfung separat aus. Dadurch wird die in v1.3.1 aufgetretene PowerShell-Parsermehrdeutigkeit ausgeschlossen.


## Korrektur v1.3.3

Der Integration-Dry-Run leitet die erwartete Endpunktanzahl aus dem tatsächlichen Integrationsvertrag ab. Die vier Endpunkte SearXNG, Open WebUI, LM Studio und ComfyUI werden nicht mehr fälschlich mit der Anzahl der freigegebenen Execute-Module gleichgesetzt.


## Korrektur v1.3.7

- Paketinterner Fortsetzungs-Preflight beseitigt die Abhängigkeit von einem separat aufbewahrten Preflight-ZIP.
- Ein expliziter Preflight kann weiterhin per Parameter oder `KI_STACK_PREFLIGHT_PATH` vorgegeben werden.
- Das vollständige GitHub-Update v0.2.6 ist im Execute-Paket enthalten.
- Nach erfolgreichem Execute stehen `Start-Validate-GitHub-Update.cmd` und `Start-Publish-GitHub-Update.cmd` direkt in der Paketwurzel bereit.


## Korrektur v1.3.7

- CMD-Dateien sind BOM-frei und CRLF-kodiert.
- Der native PowerShell-Parser läuft vor jedem Modulimport.
- Die tatsächliche doppelte Download-Verschachtelung und Pfade mit Leerzeichen werden vor jeder Aktion geprüft.
- Das GitHub-Update v0.2.6 ist im Gesamtpaket enthalten.


## Korrektur v1.3.7

- Das Models-Modul verwendet für den HTTP-Antwortstream `$responseStream` statt der geschützten PowerShell-Automatikvariable `$input`.
- Der Selbsttest prüft den aktuellen Modellmanifest-Vertrag: Schema 1.1, drei verwaltete Pflichtmodelle und fünf lokale Modellplatzhalter.
- Ein eigener Regressionstest verhindert die erneute Überschreibung von `$input`.
- Das integrierte GitHub-Update v0.2.6 veröffentlicht den korrigierten Stand als `models-workflows-v1.3.7-rc1`.

## Korrektur v1.3.7

- Das integrierte GitHub-Bundle validiert bekannte fehlerhafte Zwischenstände nicht mehr als freigegebene Releases.
- `Repo-Models-Workflows-v1.3.4-rc1` bleibt ausschließlich als Resume-Snapshot erhalten.
- GitHub-Update v0.2.7 und Ziel-Tag `models-workflows-v1.3.7-rc1` sind Bestandteil des Gesamtpakets.

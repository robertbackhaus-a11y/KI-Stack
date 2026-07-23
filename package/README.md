# KI-Stack Cutover Execute v1.6.3

Finaler Cutover- und Gesamtvalidierungsbaustein des modularen KI-Stacks.

## Enthalten

- alle validierten Referenzmodule bis Integration v1.5.8
- neues Execute-Modul `KIModuleCutover`
- aktiviertes Abschlussmodul `KIModuleValidation`
- verwaltete Gesamtstarter für Start, Stop und Healthcheck
- Readiness- und Acceptance-Berichte
- paketinterner Fortsetzungs-Preflight
- vollständige historische Regressionsmatrix
- Repository-Veröffentlichung ist nicht Bestandteil dieses Runtime-Pakets

Models / Workflows `1.4.2` übernimmt die funktional abgenommenen Workflowgraphen unverändert und ergänzt den zentralen Modellimport über `Start-KIStack-Model-Import.cmd` beziehungsweise `Import-KIStackExternalModels.ps1`. Standardquelle ist `ExternalModels` neben dem entpackten Paket; `-SourcePath` wählt einen anderen expliziten Ordner. Alle acht externen Modelle werden vor der Übernahme nach Dateiname, Größe und SHA256 geprüft.

Der Katalog bestätigt außerdem `FLUX2-Klein-9B-OpenWebUI-API-FLAT.json` als funktionalen und freigegebenen API-Workflow. Der funktionierende externe Alt-Workflow `FLUX2-Klein-9B-Text-to-Image.json` ist durch den verwalteten UI-Workflow ersetzt. Defekte Sicherungen und Archive sowie `OpenWebUI-Generation-Mapping.json` als reine Mappingdatei sind ausdrücklich keine katalogisierten Workflows.

Der zentrale Workflowkatalog führt zusätzlich die drei optionalen kanonischen Workflows `KREA-Realism-Official-Template.json`, `PONY-SDXL-Control-QuickTest-v2.json` und `WAN2.2-5B-Official.json`. Alle acht Modellabhängigkeiten wurden aus dem vorhandenen lokalen ComfyUI-Bestand anhand offizieller Größen- und SHA256-Verträge übernommen; es erfolgte kein Download. Alle drei Workflows wurden im aktiven KI-Stack geladen und mit genau einem Funktionslauf erfolgreich validiert. Die unverbundene `MarkdownNote`-Annotation wurde ausschließlich bei KREA und WAN durch den vorhandenen Standardnode `Note` ersetzt. `PONY-Control-QuickTest-v2.json`, `WAN2.2-5B-I2V-QuickTest.json` und `WAN2.2-5B-T2V-QuickTest.json` bleiben als ältere Dubletten beziehungsweise ersetzt gekennzeichnet.

Die acht externen Modelle umfassen zusammen `47.356.936.991` Bytes. Sie sind nicht Bestandteil von Git oder Paket-ZIPs. Der Installer verwendet korrekte vorhandene Dateien wieder und bezieht ausschließlich fehlende Dateien anhand unveränderlicher HTTPS-, Größen- und SHA256-Verträge; das Paket ist daher nicht vollständig offline.

Applications `1.4.10` ist der stabile Baustein für LM Studio und Open WebUI `0.10.2`. Der bestehende Installations-, Starter-, Validierungs- und Rollbackvertrag bleibt unverändert.

Integration `1.5.8` ist stabil. Das präzise CMD-`:Finish`-Block-Lifecycle-Gate bleibt unverändert; der SearXNG-Starter verwendet und prüft die tatsächlich installierte Debian-Standardkette `valkey-server`, `uwsgi` und `nginx` sowie einen identitätsgeprüften WSL-Keeper.

## Ausführung

1. `Start-Nur-Selbsttest.cmd`
2. `Start-KIStack-Cutover-DryRun.cmd`
3. `Start-KIStack-Cutover-Execute.cmd`

GitHub-Publishing-Starter und eingebettete GitHub-Update-Bundles gehören nicht mehr zum Paket. Releases werden ausschließlich über die Repository-Release-Werkzeuge erzeugt.

Nach Execute liegen die operativen Gesamtstarter unter `C:\KI-Stack\modules\cutover`.

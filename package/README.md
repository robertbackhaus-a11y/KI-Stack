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

Models / Workflows `1.3.7` verwendet FLUX2 als stabiles Pflichtprofil. KREA und Pony sind optionale Zusatzprofile; fehlende optionale Modelle verhindern die Freigabe des Pflichtprofils nicht.

Applications `1.4.10` ist der stabile Baustein für LM Studio und Open WebUI `0.10.2`. Der bestehende Installations-, Starter-, Validierungs- und Rollbackvertrag bleibt unverändert.

Integration `1.5.8` ist stabil. Das präzise CMD-`:Finish`-Block-Lifecycle-Gate bleibt unverändert; der SearXNG-Starter verwendet und prüft die tatsächlich installierte Debian-Standardkette `valkey-server`, `uwsgi` und `nginx` sowie einen identitätsgeprüften WSL-Keeper.

## Ausführung

1. `Start-Nur-Selbsttest.cmd`
2. `Start-KIStack-Cutover-DryRun.cmd`
3. `Start-KIStack-Cutover-Execute.cmd`

GitHub-Publishing-Starter und eingebettete GitHub-Update-Bundles gehören nicht mehr zum Paket. Releases werden ausschließlich über die Repository-Release-Werkzeuge erzeugt.

Nach Execute liegen die operativen Gesamtstarter unter `C:\KI-Stack\modules\cutover`.

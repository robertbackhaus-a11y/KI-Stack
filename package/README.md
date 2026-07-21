# KI-Stack Cutover Execute v1.6.3

Finaler Cutover- und Gesamtvalidierungsbaustein des modularen KI-Stacks.

## Enthalten

- alle validierten Referenzmodule bis Integration v1.5.7
- neues Execute-Modul `KIModuleCutover`
- aktiviertes Abschlussmodul `KIModuleValidation`
- verwaltete Gesamtstarter für Start, Stop und Healthcheck
- Readiness- und Acceptance-Berichte
- paketinterner Fortsetzungs-Preflight
- vollständige historische Regressionsmatrix
- Repository-Veröffentlichung ist nicht Bestandteil dieses Runtime-Pakets

## Ausführung

1. `Start-Nur-Selbsttest.cmd`
2. `Start-KIStack-Cutover-DryRun.cmd`
3. `Start-KIStack-Cutover-Execute.cmd`

GitHub-Publishing-Starter und eingebettete GitHub-Update-Bundles gehören nicht mehr zum Paket. Releases werden ausschließlich über die Repository-Release-Werkzeuge erzeugt.

Nach Execute liegen die operativen Gesamtstarter unter `C:\KI-Stack\modules\cutover`.

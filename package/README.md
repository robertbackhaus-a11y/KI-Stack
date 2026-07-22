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

Models / Workflows `1.3.8` verwendet den in ComfyUI gespeicherten und manuell funktional abgenommenen Workflow `KI-Stack-FLUX2-Text-to-Image-v1.3.8.json`. Das Pflichtprofil nutzt `flux-2-klein-9b-fp8.safetensors` (FP8), `qwen_3_8b_fp8mixed.safetensors` (FP8 mixed), `flux2-vae.safetensors`, `euler`, `Flux2Scheduler`, Guidance `1` und genau einen aktiven Samplingpfad. Prompt, Seed und Batchgröße sind Nutzereingaben; Breite, Höhe und vier Schritte werden direkt eingetragen. Geprüfte Größen: Schnelltest `512 x 512`, Standard `1024 x 576`, Qualität `768 x 1344`; „Qualität“ bezeichnet hier Auflösung und Ausgabeformat, nicht eine höhere Samplingqualität.

KREA ist zurückgestellt, solange KREA-Modell, `clip_l`, `t5xxl_fp16` und `ae.safetensors` fehlen. Pony ist ohne Pony-SDXL-Checkpoint zurückgestellt. ControlNet ist ohne kompatible Modelle und bestätigte Node-Kette zurückgestellt. Es erfolgen keine automatischen Downloads optionaler Modelle und es werden keine Platzhalter-Workflows ausgeliefert.

Applications `1.4.10` ist der stabile Baustein für LM Studio und Open WebUI `0.10.2`. Der bestehende Installations-, Starter-, Validierungs- und Rollbackvertrag bleibt unverändert.

Integration `1.5.8` ist stabil. Das präzise CMD-`:Finish`-Block-Lifecycle-Gate bleibt unverändert; der SearXNG-Starter verwendet und prüft die tatsächlich installierte Debian-Standardkette `valkey-server`, `uwsgi` und `nginx` sowie einen identitätsgeprüften WSL-Keeper.

## Ausführung

1. `Start-Nur-Selbsttest.cmd`
2. `Start-KIStack-Cutover-DryRun.cmd`
3. `Start-KIStack-Cutover-Execute.cmd`

GitHub-Publishing-Starter und eingebettete GitHub-Update-Bundles gehören nicht mehr zum Paket. Releases werden ausschließlich über die Repository-Release-Werkzeuge erzeugt.

Nach Execute liegen die operativen Gesamtstarter unter `C:\KI-Stack\modules\cutover`.

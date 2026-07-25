# KI-Stack Technische Dokumentation

**[Hier beginnen: Installationsanleitung](KI-Stack-Installationsanleitung.md)**

## 1. Zielbild und Architektur

KI-Stack ist ein Windows-orientierter, transaktionsgesicherter lokaler KI-Stack. Das Repository stellt reproduzierbare Paketquellen bereit; Release-ZIPs sind GitHub-Release-Artefakte und werden nicht eingecheckt. Die Laufzeitbeschaffung von Paketen ist Git-frei. Jede verwaltete Änderung wird geplant, journalisiert und kann fortgesetzt oder zurückgerollt werden.

Die unterstützte Topologie verwendet Windows für Benutzereinstiege, LM Studio, ComfyUI und Desktop-Verknüpfungen; WSL2/Debian für SearXNG und seine Dienstkette `valkey-server`, `uwsgi` und `nginx`. OpenWebUI läuft lokal und verbindet die Profile, Tools, Code-Fähigkeit, Websuche und Bildausgabe.

## 2. Komponentenmatrix

| Komponente | Version / Status | Release oder Vertrag | SHA256 / Integritätsnachweis |
|---|---|---|---|
| Cutover Runtime | 1.6.3, akzeptierte Basis | `cutover-v1.6.3-rc1` | Core `e387199493575131045c888ebbd4c1313bb985b13e3a1f72c3f99efe9bf2b85d` |
| ComfyUI | 1.2.2, zielsystemvalidiert | eingebettetes Complete-Payload | `tools/comfyui/current/MANIFEST.json` |
| Visuelle Modelle / Workflows | 2.0.0; Heretic nur Chat, Nomic nur Embeddings | `tools/models-workflows/current` | Paket-`SHA256SUMS.txt`; Modelle extern |
| Applications | 1.4.10, akzeptiert | Cutover-Payload | Paketmanifest-Vertrag |
| Integration / SearXNG | 1.5.9, zielsystemvalidiert | eingebettetes Complete-Payload | Payloadvertrag |
| Production Recovery | 1.7.0-r7, zielsystemakzeptiert | `production-v1.7.0-r7` | `0b4b28c886f01939fb45a9d7f3ce9f5323f57a8208e42381088544afa5955c59` |
| Validation Gate | 1.0.2, aktiv | Production Release | `a03dd59df2322bc37b763d8d16ff6127f04b969069a698b361e6c52099a7db81` |
| Target Acceptance | 1.0.10, bestanden | Production Release | `bbfe6e79438406fecbc301f8883a7b629ca0c1ff5736917c267c02ec79fce0d6` |
| OpenWebUI Agent Pack | 1.8.3, zielsystemvalidiert | separates Release | Pack-`SHA256SUMS.txt` |
| OpenWebUI Visual Pack | 2.0.5-rc2, persistente Bild- und MP4-Anhänge | eingebettetes Complete-Payload | Pack-`SHA256SUMS.txt` |
| OpenWebUI Ballistics Pack | 1.0.0, zielsystemvalidiert | separates Release | Pack-`SHA256SUMS.txt` |
| Complete Installer | 2.3.0-rc2, aus Quellen reproduzierbar | `tools/complete-installer/current` | Paket-`SHA256SUMS.txt` |

`production-release-manifest.json`, jedes Paket-`MANIFEST.json`, `SHA256SUMS.txt` und der Release-Sidecar sind die maßgeblichen Integritätsnachweise. Das Target-Acceptance-Ergebnis lautet `TARGET_SYSTEM_ACCEPTANCE_PASSED`.

## 3. Verzeichnisse und verwaltete Daten

`package/` enthält die Runtime-Paketquelle, Module, Modell- und Workflowmanifeste, öffentliche Import-Einstiege und die kanonischen Workflows. `tools/complete-installer/current/` enthält die vollständige Orchestrierungsquelle und den Vertrag der eingebetteten Payloads. `tools/` enthält reproduzierbare Quellen für Recovery, Validation Gate und Acceptance. `docs/` enthält Betriebs- und Release-Dokumentation. `_import/` ist privat, von Git ausgeschlossen und niemals ein Release-Eingang.

Verwaltete Inhalte umfassen Paketdateien, Komponentenmarker, Transaktionszustand, konfigurierte Workflowkopien und bekannte KI-Stack-Dienstkonfiguration. Nutzereigene Modelle, Workflows, Chats, Prompts, hochgeladene Dateien, Browserdaten, Modellcaches, virtuelle Umgebungen und fremde Git-Arbeitsverzeichnisse sind keine Löschziele. Modelle bleiben außerhalb von Git und Release-ZIPs.

## 4. Dienste, Ports und Healthchecks

LM Studio stellt den lokalen OpenAI-kompatiblen Endpunkt und `/v1/models` bereit. OpenWebUI stellt die lokale Chat-Oberfläche bereit. SearXNG wird über HTML- und JSON-Suche geprüft. ComfyUI wird über seinen Health-/API-Endpunkt geprüft. Der Statuskern meldet jeden Eintrag als Läuft, Gestoppt oder Fehler sowie WSL-Keeper und Debian `valkey-server`, `uwsgi` und `nginx`. Lokale Portzuweisungen werden aus der installierten Konfiguration gelesen statt aus der Dokumentation angenommen; Statusprüfungen starten keine Komponente.

## 5. OpenWebUI-Profile und Integrationen

`Allgemein` und `KI & IT-Technik` verwenden Native Function Calling, haben `knowledge=[]`, nutzen den eingebauten browserlokalen Pyodide-Code-Interpreter und binden die verwalteten Bild- und Videotools. `18Bravo` hat `knowledge=[]`, deaktiviert den Code Interpreter und bindet ausschließlich `ki_stack_ballistics_calculator`. Heretic ist das einzige auswählbare Chat-LLM; Nomic dient ausschließlich Embeddings. `execute_code` ist eine eingebaute Fähigkeit und keine Workspace-Tool-ID.

Die Visual-Tools senden ausschließlich den freigegebenen Z-Image-Turbo- oder WAN2.2-T2V-14B-API-Workflow an ComfyUI. Ergebnisse werden über den OpenWebUI-Dateispeicher registriert. Bilder bleiben eingebettet; MP4-Ergebnisse bleiben nach Reload genau ein persistenter Download-Anhang über `/api/v1/files/{id}/content`. Die Tools zeigen keine `/mnt/uploads`-, Windows- oder ComfyUI-Pfade. Das Ballistiktool bleibt auf rechtmäßige sportliche, jagdliche und technische Berechnungen beschränkt.

## 6. Workflows und Modellverträge

Die einzigen kanonischen Visual-Workflows sind Z-Image Turbo und WAN2.2 T2V 14B. Ihre neun externen Dateien sind `z_image_turbo_bf16.safetensors`, `Qwen3-4b-Z-Image-Engineer-V4-Q8_0.gguf`, `ae.safetensors`, die WAN2.2-T2V-14B-High-/Low-Noise-Diffusionsmodelle, `umt5_xxl_fp8_e4m3fn_scaled.safetensors`, `wan_2.1_vae.safetensors` sowie beide High-/Low-LightX2V-4-Step-LoRAs. Der externe Visual-Modellvertrag umfasst 54.994.650.267 Bytes und steht in `tools/models-workflows/current/Manifests/models.manifest.json`.

Der zentrale Importer prüft den deklarierten Dateinamen und die exakte Größe sowie, falls im Vertrag vorhanden, SHA256. Er verwendet eine `.partial`-Kopie mit anschließendem atomarem Verschieben, protokolliert eine fortsetzbare Transaktion und rollt nur Dateien dieser Transaktion zurück. Modellbinärdateien bleiben extern und sind nie im Complete Installer eingebettet.

## 7. Transaktions- und Lebenszyklusarchitektur

Installation, Upgrade, Repair und Import verwenden explizite Planung, Backups, Journaleinträge, begrenztes Rollback und Resume-Zustand. Bereits konforme Inhalte bleiben erhalten. Ein fehlendes manuelles Modell liefert `WaitingForUserAction` einschließlich genauem Dateinamen, Größe, SHA256 und Quellordner; es schreibt niemals einen Completed- oder AlreadyCompliant-Marker.

Alle CMD-Starter lösen zuerst PowerShell 7 aus `%ProgramFiles%\\PowerShell\\7\\pwsh.exe` und danach über `where pwsh.exe` auf und brechen bei Fehlen mit Exitcode 70 ab. Windows PowerShell ist kein Fallback. Start, Stop und read-only Status haben getrennte Einstiege. Nur der interaktive Desktop-Statuswrapper wartet auf eine Taste; Statuskern und Validierungsstarter bleiben pausenfrei. Es sind weder KI-Stack-Windows-Autostart, geplante Boot-/Anmeldeaufgaben, Run/RunOnce-Einträge noch automatische Debian-Dienstaktivierung erforderlich. Debian-Dienste bleiben manuell startbar.

## 8. Sicherheit, Abhängigkeiten und Einschränkungen

API-Keys werden interaktiv als `SecureString` angefordert, nur im Arbeitsspeicher verwendet und müssen danach in OpenWebUI widerrufen werden. Sie sind weder Kommandozeilenargumente noch Umgebungsdateien, Git-Inhalte oder Berichte. Kein roher Target-Report, persönlicher Pfad, Testbild, Modellbinärfile, Backup oder privater Importinhalt ist veröffentlichbar.

Der Complete Installer ist zur Laufzeit Git-frei, aber nicht vollständig offline, weil Modelle extern sowie lizenz- oder zugangsbeschränkt sind oder manuell bereitgestellt werden. Fresh-Install-Verhalten ist vertraglich und mit Fixtures validiert; die physische Zielsystemvalidierung bezieht sich auf die bestehende Installation. Production Recovery r7 und Target Acceptance 1.0.10 sind feste externe Referenzen, keine automatisch überlagerten Pakete.

`main` ist durch Pull-Request-Pflicht, Verbot von Force-Pushes und Löschschutz geschützt. Gitleaks, PSScriptAnalyzer, Bandit, CodeQL und der Modellquellenvertrag sind verpflichtende Prüfungen. CI-Actions sind auf vollständige Commit-SHAs gepinnt. Jedes Release von Models / Workflows, Complete Installer und Visual Pack stellt eine SPDX-2.3-JSON-SBOM bereit, die das Release-ZIP per SHA256, enthaltene Komponenten und Drittanbieterabhängigkeiten benennt; alle Modellbinärdateien sind ausdrücklich extern und nicht enthalten. GitHub-Build-Provenienz- und SPDX-SBOM-Attestierungen entstehen für die exakten veröffentlichten ZIP-Bytes.

```powershell
gh attestation verify .\<release>.zip --repo robertbackhaus-a11y/KI-Stack
gh attestation verify .\<release>.zip --repo robertbackhaus-a11y/KI-Stack --predicate-type https://spdx.dev/Document/v2.3
```

KI-Stack verwendet geschützte Änderungen, verpflichtende statische Sicherheitsprüfungen, inhaltsbasierte SHA256-Verträge, veröffentlichte SBOMs und überprüfbare Build-Attestierungen. Diese Nachweise reduzieren Supply-Chain-Risiken, ersetzen jedoch keine unabhängige Sicherheitsprüfung und stellen keine Garantie für Fehler- oder Backdoorfreiheit dar. Der koordinierte Meldeweg steht in `SECURITY.md`.

## 9. Wartungs- und Releaseverfahren

Ändere nur die betroffene Quelle und den Vertrag. Aktualisiere Version, Manifeste, Berichte, `SHA256SUMS.txt`, Dokumentation und Release Notes gemeinsam. Prüfe Links und Dokumentgleichstand, führe Repository-Validator und `git diff --check` aus, baue jedes betroffene Paket einmal, prüfe ZIP- und Sidecar-SHA256, committe bewusst, pushe, veröffentliche die etablierte Assetanzahl und prüfe die hochgeladenen Assets einmal. ZIPs oder `_import/`-Inhalte gehören nicht in Git.

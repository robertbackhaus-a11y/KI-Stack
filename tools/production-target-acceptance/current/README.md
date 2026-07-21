# KI-Stack Production Target Acceptance v1.0.10

Dieses Paket führt die reale Zielsystemabnahme des Recovery-Standes v1.7.0-r7 gegen `C:\KI-Stack` durch.

## Ausführen

`Start-KIStack-Target-Acceptance-Execute.cmd`

Der Lauf validiert das Paket, repariert nur abweichende Overlay-Dateien mit Backup, stoppt und startet den Stack und prüft SearXNG, Open WebUI, LM Studio und ComfyUI.

## Korrektur v1.0.10

- Verwendet ausschließlich das neue Recovery-Artefakt `KI-Stack-Production-Recovery-v1.7.0-r7.zip` mit festem SHA256-Vertrag.
- Behält die vorhandene Acceptance-Logik und alle Regressionen aus v1.0.8 unverändert bei.
- Starter und Selbsttest geben die Paketversion `1.0.10` sichtbar aus.

## Korrektur v1.0.8

- Der Selbsttest berechnet den Overlay-Content-Pfad direkt aus der real extrahierten Recovery-Wurzel.
- Der berechnete Pfad muss exakt mit `overlayContentRoot` übereinstimmen.
- Open-WebUI- und ComfyUI-Starter werden nur unter `02-Operational-Overlay\Content` geprüft.
- Starter und Selbsttest geben die Paketversion `1.0.8` sichtbar aus.

Bericht: `C:\KI-Stack\reports\production-recovery\Target-Acceptance-latest.json`

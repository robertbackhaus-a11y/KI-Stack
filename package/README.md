# KI-Stack Integration Execute v1.5.5

Siebter Execute-Baustein auf Basis von Applications v1.4.10.

## Umfang

- WSL2- und Debian-Erkennung; Debian-Installation nur wenn erforderlich.
- systemd-Aktivierung mit kontrolliertem WSL-Neustart.
- Übernahme eines bereits funktionierenden SearXNG-JSON-Endpunkts.
- Andernfalls reproduzierbare native Debian-Installation des offiziellen SearXNG-Commits `277d8469c`.
- Valkey, uWSGI und nginx mit lokalem Endpunkt `http://localhost/searxng`.
- JSON-Format für Open WebUI.
- WSL-Keeper sowie Start-/Stop-Skripte für den integrierten Stack.
- Nichtdestruktiver Rollback: neu installierte WSL-Distributionen werden niemals automatisch abgemeldet.
- GitHub Update v0.4.5 direkt im Paket.

## Reihenfolge

1. `Start-Nur-Selbsttest.cmd`
2. `Start-KIStack-Integration-DryRun.cmd`
3. `Start-KIStack-Integration-Execute.cmd`
4. Nach erfolgreichem Zielsystemlauf: `Start-Validate-GitHub-Update.cmd`
5. Danach: `Start-Publish-GitHub-Update.cmd`

## v1.5.5 correction

The package validation now requires the Integration bootstrap and launcher names and rejects inherited Applications top-level launcher names.

## v1.5.5 regression hardening

- Fixes WSL NUL-character removal.
- Adds the mandatory historical regression matrix for all future package actions.

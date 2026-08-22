# KI-Stack OpenWebUI Visual Pack 2.0.5

Dieses Paket bindet den bereinigten Visual-Runtime-Zielstand an OpenWebUI 0.11.0 an:

- Bildgenerierung ausschließlich über Z-Image Turbo.
- Videogenerierung ausschließlich über WAN2.2 T2V 14B, die beiden LightX2V-4-Step-LoRAs und MP4/H.264.
- MP4-Dateien werden einmalig als `type: file` über den nativen `files`-Event ausgegeben.
- Der FileItem-Vertrag enthält `id`, `name`, `url`, `content_type`, `size` und `meta`; `url` ist exakt `/api/v1/files/{id}/content`.
- OpenWebUI 0.11.0 persistiert den `files`-Event selbst in der Chatnachricht. Der Adapter schreibt deshalb nicht zusätzlich über `Chats.add_message_files_by_id_and_message_id`.
- `chat:message:files` und `embeds` werden für MP4 nicht verwendet. Das reale 0.11.0-Frontend zeigt `type: file` als sichtbaren FileItem; die Content-Route liefert MP4 mit `video/mp4` und `Content-Disposition: attachment` zum direkten Download.

Das Paket enthält keine Modelle und führt keine Downloads durch. Es prüft die neun geschützten Modelldateien, die beiden manuell getesteten ComfyUI-Workflows, alle erforderlichen ComfyUI-Nodes, MP4/H.264 sowie die beiden vorhandenen OpenWebUI-Agentenprofile.

## Reihenfolge

1. `Start-VisualPack-Preflight.cmd`
2. Bei bestandenem Preflight: `Start-VisualPack-Install.cmd`
3. Bild und Video jeweils einmal direkt in OpenWebUI erzeugen.

Alternativ:

```powershell
.\Install-KIStack-OpenWebUI-VisualPack-v2.0.5.ps1 -Action Preflight
.\Install-KIStack-OpenWebUI-VisualPack-v2.0.5.ps1 -Action Install
.\Install-KIStack-OpenWebUI-VisualPack-v2.0.5.ps1 -Action Validate
```

Der API-Key wird ausschließlich als PowerShell `SecureString` abgefragt und nicht gespeichert.

## Sicherung und Rollback

Vor jeder Installation wird unter `C:\KI-Stack\backups\openwebui-visual-pack` ein gezieltes Backup der beiden Tooldefinitionen und der Profilbindungen erstellt. Bei einem Installationsfehler erfolgt ein automatischer Rollback.

Manueller Rollback:

```powershell
.\Install-KIStack-OpenWebUI-VisualPack-v2.0.5.ps1 `
  -Action Rollback `
  -BackupPath 'C:\KI-Stack\backups\openwebui-visual-pack\...\visual-pack.backup.json'
```

## Abnahmegrenze

Die Paket- und Adaptertests decken fehlende, doppelte und nicht auflösbare MP4-Anhänge ab. Der Status bleibt bis zum realen Bild- und Videotest aus OpenWebUI `StaticValidated_TargetPending`.

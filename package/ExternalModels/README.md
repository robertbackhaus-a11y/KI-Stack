# ExternalModels

Place the eight ComfyUI external model files directly in this directory using their exact contract filenames. Place the two Heretic LM Studio files in `LMStudio`. The importer verifies filename, byte size and SHA256 before copying a file through a `.partial` target into its managed model directory.

Run `Start-KIStack-Model-Import.cmd`, or use `Import-KIStackExternalModels.ps1 -SourcePath "<folder>"`. No model file belongs in Git or a package archive.

Deutsch: ComfyUI-Downloadschritte und Prüfsummen stehen in `docs/de/KI-Stack-Modell-Downloadanleitung.md`; Heretic in `docs/de/KI-Stack-Manuelle-Modellbereitstellung.md`. English: see `docs/en/KI-Stack-Model-Download-Guide.md` and `docs/en/KI-Stack-Manual-Model-Provisioning.md`.

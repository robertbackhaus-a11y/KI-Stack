# ExternalModels

Place the eight ComfyUI external model files directly in this directory and the two Heretic LM Studio files in `LMStudio`, then run `Start-KIStack-Model-Import.cmd`. An alternative source directory can be supplied with `-SourcePath`.

The seven `manualExternal` models are never downloaded by the installer. Their contracts contain only the publisher, an informational HTTPS page, exact file name, size and SHA256. The informational page is not an installable payload source and no `resolve/main` URL is trusted for installation. Pony remains the only automatic external model through the fixed Civitai model version `290640`, followed by mandatory size and SHA256 verification.

The Complete Installer delegates to the single importer contained in its Models / Workflows 1.4.9 payload. No model file is embedded in this directory or in the release archive. See `docs/en/KI-Stack-Model-Download-Guide.md`, `docs/de/KI-Stack-Modell-Downloadanleitung.md`, `docs/en/KI-Stack-Manual-Model-Provisioning.md` and `docs/de/KI-Stack-Manuelle-Modellbereitstellung.md`.

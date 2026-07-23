# KI-Stack Models / Workflows 1.4.2

Adds one public, transactional import path for all eight external KREA, Pony SDXL and WAN 2.2 models. `Start-KIStack-Model-Import.cmd` forwards to `Import-KIStackExternalModels.ps1`; the default source is `ExternalModels` beside the extracted package and `-SourcePath` selects another explicit directory.

Targets and sources are verified by exact filename, byte size and SHA256. Imports use a verified `.partial` copy followed by an atomic move. Missing manual files return `WaitingForUserAction`; transactions can resume or roll back only their own changes. No model is embedded.

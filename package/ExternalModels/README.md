# ExternalModels

Place the eight external model files directly in this directory using their exact contract filenames. The importer verifies filename, byte size and SHA256 before copying a file through a `.partial` target into its managed model directory.

Run `Start-KIStack-Model-Import.cmd`, or use `Import-KIStackExternalModels.ps1 -SourcePath "<folder>"`. No model file belongs in Git or a package archive.

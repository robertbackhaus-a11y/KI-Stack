# KI-Stack Models / Workflows v1.3.3-rc1

Release candidate for the model and workflow layer.

v1.3.3 corrects the Integration Dry-Run regression introduced while enabling the fifth execute module. The integration contract remains four endpoints: SearXNG, Open WebUI, LM Studio and ComfyUI. Endpoint count is now derived from that contract instead of the enabled-module count. The native PowerShell AST gate remains mandatory before SelfTest, DryRun and Execute.

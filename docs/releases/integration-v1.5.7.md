# Integration v1.5.7

## Status

Stable. The existing integration implementation and precise CMD `:Finish`-block lifecycle gate are unchanged. Production Target Acceptance 1.0.8 is the target-system evidence for SearXNG, Open WebUI, LM Studio and ComfyUI endpoint operation.

## Scope

- Existing WSL2, Debian and SearXNG integration behavior.
- Existing Open WebUI search integration and managed start/stop contracts.
- Result and exit code remain visible until one key is pressed.
- Lifecycle validation remains restricted to the exact `:Finish` block.
- No new functions, acceptance layer or runtime-path assumptions.

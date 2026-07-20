# KI-Stack Integration v1.5.7 – CMD Lifecycle Gate Precision Repair

- Keeps the requested lifecycle: every result remains visible until one key is pressed.
- Fixes the false-positive historical gate by parsing only the exact `:Finish` CMD label block.
- Applies the same label-block precision to normal package SelfTests.
- Adds permanent regression `REG-GATE-002` and SelfTest `CMD-Finishblock-Praezision`.
- Embeds GitHub Update v0.4.7.

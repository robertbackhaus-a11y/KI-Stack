# Applications v1.4.9-rc1

## Status

Release candidate. The Applications runtime installation was already successful; this release corrects only repository publication.

## Changes

- Configures `user.name=Robert Backhaus` and `user.email=robert.backhaus@gmail.com` locally in the temporary clone.
- Reads both values back and aborts before commit/tag if they are missing or different.
- Does not change global Git configuration.
- Preserves target-only snapshot and strict error propagation.

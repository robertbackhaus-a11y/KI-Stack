# KI-Stack Models / Workflows 1.4.6

This release adds a deterministic SPDX-2.3 JSON SBOM asset. The SBOM identifies the ZIP by SHA256, lists included components and records every model as an external, non-contained dependency with publisher, size, SHA256 and license status.

The release ZIP is attested after publication with GitHub build provenance and an SPDX SBOM predicate. Verify both with `gh attestation verify <zip> --repo robertbackhaus-a11y/KI-Stack` and the `https://spdx.dev/Document/v2.3` predicate.

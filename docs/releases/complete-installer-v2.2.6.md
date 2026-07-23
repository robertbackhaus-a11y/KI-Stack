# KI-Stack Complete Installer 2.2.6

This release updates the embedded Models / Workflows contract to 1.4.6 and adds a deterministic SPDX-2.3 JSON SBOM asset for the Complete Installer ZIP. Models remain external, are never embedded, and retain their filename, size, SHA256, publisher and license-status contracts.

The release ZIP is attested after publication with GitHub build provenance and an SPDX SBOM predicate. Verify both with `gh attestation verify <zip> --repo robertbackhaus-a11y/KI-Stack` and the `https://spdx.dev/Document/v2.3` predicate.

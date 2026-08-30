# KI-Stack Complete Installer v2.10.1

Maintenance release. Base: 2.10.0.

- Complete Installer: 2.10.1 (base: 2.10.0)
- Status: `SbomPipelineRestored_MaintenanceRelease`
- Component pins: unchanged from 2.10.0 (ComfyUI 1.2.4, Models/Workflows 2.0.3, Applications 1.4.11, Integration 1.5.11, Cutover Runtime 1.6.13, Production Recovery 1.7.0-r7, Validation Gate 1.0.3, Target Acceptance 1.0.10, OpenWebUI Visual Pack 2.0.5, OpenWebUI Agent Pack 1.8.9, OpenWebUI Ballistics Pack 1.0.0, Codex Local 0.1.4, RAG 0.3.1).
- No runtime component version changes. No product runtime logic changes.

## Scope

After the 2.10.0 release, PR [#49](https://github.com/robertbackhaus-a11y/KI-Stack/pull/49) restored automatic SPDX 2.3 SBOM generation for the Complete Installer package: `New-KIStackCompleteInstallerArchive.ps1` had stopped calling the shared `scripts/New-KIStackSpdxSbom.ps1` generator during an earlier `tools/`-reorganization, so no Complete Installer release since 2.3.0 had produced an SBOM. That fix also updated the generator itself so it no longer assumes fields the current `tools/models-workflows/current/Manifests/models.manifest.json` schema (renamed/dropped `lmStudioModel`, `displayName`, `publisher`, `license`, `sourceKind`, `informationSource`, `targetDirectory`; plural `sources[]`) no longer carries, falling back safely instead of throwing.

2.10.1 is the version bump that ships that already-merged fix as part of a normal Complete Installer release: the build now produces `KI-Stack-Complete-Installer-v2.10.1.zip`, its SHA-256 sidecar, and `KI-Stack-Complete-Installer-v2.10.1.spdx.json` (SPDX-2.3, generated automatically by the build script, not as a separate manual step).

No component pin changed, no payload content changed beyond the package's own version-reporting fields, and no installer/runtime logic changed. The full 2.10.0 feature set (central update checker, ComfyUI/Open WebUI supported-version contracts, LM-Studio autostart guard, Cutover Runtime 1.6.13) is unaffected and remains documented in `docs/releases/complete-installer-v2.10.0.md` and the `## 2.10.0` changelog entry.

## Validation

- Full repository test suite (`scripts/Test-Repository.ps1`) and the Complete Installer `PackageSelfTest` both pass against the updated package.
- Deterministic double-build: two independent builds of the 2.10.1 package produce byte-identical ZIPs (same size and SHA-256).
- The generated SBOM parses as valid JSON, reports `spdxVersion: SPDX-2.3`, and its root package checksum matches the built ZIP's SHA-256 exactly; the `.zip.sha256` sidecar matches the same ZIP.

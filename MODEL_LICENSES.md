# Model licenses and redistribution

Model files are external dependencies. They are not committed to Git and are not embedded in KI-Stack release ZIPs. The importer accepts a file only when its exact filename, byte size and SHA256 match `package/Manifests/models.manifest.json` and the Complete Installer payload contract.

| Model family | Contract status | License / redistribution status |
|---|---|---|
| FLUX.2 Klein 9B FP8 | Required profile; source may be gated | FLUX Non-Commercial License; obtain from the upstream provider under its terms. |
| Qwen 3 8B FP8 Mixed and FLUX.2 VAE | Required profile | Upstream repository license applies; external dependency. |
| FLUX.1 Krea Dev FP8 | Manual external dependency | `flux-1-dev-non-commercial-license`; external only. |
| CLIP-L and T5XXL FP16 | Manual external dependencies | Apache-2.0 upstream terms stated in the model contract; external only. |
| FLUX AE VAE | Manual external dependency | Upstream/repackaging repository does not declare a redistributable license in the contract; manual external provision only. |
| Pony Diffusion V6 XL | Fixed Civitai model-version-290640 acquisition contract | Civitai model permissions in the model contract; package redistribution prohibited. |
| WAN 2.2 UMT5, TI2V and VAE | Manual external dependencies | Apache-2.0 upstream WAN 2.2 terms in the contract; external only. |

The user is responsible for accepting applicable upstream terms and for any lawful use, download and redistribution decision. Apache-2.0 for KI-Stack does not grant model rights.

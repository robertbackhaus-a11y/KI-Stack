# KI-Stack Complete Installer 2.3.0-rc2

RC2 replaces the non-source-reproducible RC1 package with a deterministic build
from the canonical repository sources.

- Complete Installer source: `tools/complete-installer/current`
- Visual model/workflow source: `tools/models-workflows/current`
- OpenWebUI Visual Pack source: `tools/openwebui-visual-pack/current`
- Heretic is the only chat LLM.
- Nomic is embedding-only.
- Visual generation is limited to Z-Image Turbo and WAN2.2 T2V 14B with both
  LightX2V four-step LoRAs.
- MP4 tool results use the persistent OpenWebUI file attachment contract and
  `/api/v1/files/{id}/content`.
- The target installation is not accessed during repository build or validation.

RC1 reference SHA-256:
`ae1e368b08f2cfb2b7592d02c38fcd4eb4a1a65a8bc7121db956d990561752c7`

RC1 source-build SHA-256:
`c52d4e61cb07ac8f318e05cc0afec16673f8931ec2efaa7583453ae68a465dcf`

The mismatch is caused by the previously missing source-integrated build chain;
therefore RC1 is explicitly classified as non-reproducible.

# Security policy

## Public repository rules

Never commit:

- credentials, passwords, API keys or access tokens;
- SSH, TLS or signing private keys;
- `.env` files containing secrets;
- personal preflight or transaction archives;
- machine-specific logs containing usernames, hostnames or private paths;
- proprietary model files or third-party binaries without redistribution rights.

## Reporting

Do not publish a suspected credential or vulnerability in a public issue. Send the report privately to [robert.backhaus@gmail.com](mailto:robert.backhaus@gmail.com) with the subject `KI-Stack security report`. Do not include live credentials; revoke or redact them first.

## Response process

The maintainer acknowledges a report within seven calendar days, validates the report privately, and coordinates a fix before public disclosure. A release note identifies the fixed security impact without disclosing exploitable details until affected users have had a reasonable update window. If the report cannot be reproduced or concerns a third-party component or model, the reporter receives that assessment and the relevant upstream channel.

## Security-assessment boundary

Published checks cover tracked source, declared runtime contracts, package integrity metadata and the configured CI checks. They are not a claim that the software is free of backdoors and do not replace an independent code, infrastructure or runtime review.

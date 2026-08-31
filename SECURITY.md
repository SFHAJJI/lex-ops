# Security

This repository contains only the public V3 preview deployment boundary. It must not contain
credentials, signing material, publisher evidence, corpus data, indexes, or private endpoints.

Report vulnerabilities through a
[private GitHub security advisory](https://github.com/SFHAJJI/lex-ops/security/advisories/new).
Do not include credentials or exploit details in a public issue.

The current trust boundaries are deliberately small:

- GitHub OIDC supplies Azure authentication without a stored cloud credential.
- The workflow accepts only an allowlisted registry image with an exact SHA-256 digest.
- A uniquely named preview Container App receives no production traffic.
- Runtime checks are bounded and the workflow always attempts exact-name teardown.
- Signing, publication, promotion, and rollback are intentionally absent until the complete V3
  release contract exists. This preview is never release-grade evidence.

# Security

This repository contains public orchestration code and public operational status only. It must not
contain credentials, private signing material, raw publisher evidence or private Azure endpoints.

Report vulnerabilities through a
[private GitHub security advisory](https://github.com/SFHAJJI/lex-ops/security/advisories/new).
Do not include credentials or exploit details in a public issue.

The important trust boundaries are:

- Publication OIDC is bound to this repository's `production` environment, which requires a
  reviewer and accepts deployments only from the exact `main` branch.
- Release manifests are signed by a non-exportable Azure Key Vault key.
- Long local builds upload only hash-pinned DB and vector files to private staging.
- The public workflow re-verifies content, provenance and retrieval behavior before publication.
- Candidate revisions receive zero traffic until an explicit, compare-before-switch operation.

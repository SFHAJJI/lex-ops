# lex-ops — fleet operations

The hub of the hub-and-spoke ops layer (spec §11), running in **N-small
centralized mode** (§11.5): one nightly workflow ingests every enabled
publisher, applies the pre-commit anomaly gate, pushes corpus commits, rebuilds
and signs indexes, uploads release assets, and writes the fleet's three-state
status (`ran_no_change` / `ran_committed` / `failed_*`) — one status commit per
night, never a heartbeat in a corpus repo.

- `publishers.json` — the fleet registry.
- `fleet.sh` — the runner.
- `status/` — per-publisher status records (the freshness feed).
- `LEX_OPS_TOKEN` authorizes cross-repository pushes. It is an interim OAuth token and must be
  replaced with a GitHub App installation token by the third publisher or 90 days, whichever
  comes first (spec §11.1).
- `LEX_SIGNING_KEY` signs only the embedded compatibility stamp during the rollback window. It is
  not the trust root for released artifacts.

Every index published by the current pipeline travels with a signed `lex-artifacts/1` manifest. The manifest binds
the complete release file list, hashes, sizes, code commit and corpus commit to the public key
pinned in the Lex application release. The pipeline verifies its own output before upload.
The stale-index gate queues any pre-migration release that lacks this manifest, even when its
corpus did not change, so an unsigned legacy asset cannot be treated as current indefinitely.
EU releases also carry the exact reviewed `eu-scope.json` that selected their works. It is a
signed artifact, so a reviewer can reproduce which domains, languages, waves and relationship
rules produced a particular index.

Production publication uses `ARTIFACT_SIGNING_MODE=keyvault`. GitHub Actions authenticates through
the production OIDC environment, and Azure Key Vault signs each canonical manifest with the
non-exportable P-256 key. The private key never enters the runner. The publisher identity has only
the Key Vault data-plane permission required to sign and no subscription role.

`DEPLOY_AFTER_PUBLISH=1` dispatches the Lex deployment workflow only after at least one artifact
set was built, signed, verified and uploaded successfully. The deployment builds an immutable
image identified by the code and artifact-manifest hashes, creates a zero-traffic Container Apps
revision, runs health, MCP and assistant smoke tests, and only then promotes traffic. The previous
revision remains available for immediate rollback.

During the dual-reader rollback window, `LEX_SIGNING_KEY` still signs only the index's embedded
compatibility stamp. The application does not trust that adjacent public key. Runtime trust comes
from the whole-release Key Vault signature and the public-key fingerprint pinned in the Lex image.

When the fleet grows past a couple of publishers, this migrates to the
dispatch/fan-out shape in spec §10.1 — per-corpus-repo workflows triggered via
`workflow_dispatch`, status via run artifacts. The status model and gates stay
identical; only the execution topology changes.

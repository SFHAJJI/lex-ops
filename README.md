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
- Secrets: `LEX_OPS_TOKEN` (cross-repo pushes — **interim OAuth token; replace
  with a GitHub App installation token by the third publisher or 90 days,
  whichever comes first**, spec §11.1), `LEX_SIGNING_KEY` (the D40 index
  signing key, ECDSA-P256).

Every published index now travels with a signed `lex-artifacts/1` manifest. The manifest binds
the complete release file list, hashes, sizes, code commit and corpus commit to the public key
pinned in the Lex application release. The pipeline verifies its own output before upload.
EU releases also carry the exact reviewed `eu-scope.json` that selected their works. It is a
signed artifact, so a reviewer can reproduce which domains, languages, waves and relationship
rules produced a particular index.

`DEPLOY_AFTER_PUBLISH=1` dispatches the verified Lex deployment workflow. It stays unset until
the production GitHub OIDC environment and managed identities exist. The existing signing secret
is the migration root. After the Key Vault public root has shipped in Lex, set
`ARTIFACT_SIGNING_MODE=keyvault`, `ARTIFACT_KEY_ID`, `AZURE_KEY_VAULT`, `AZURE_KEY_NAME` and the
Azure tenant and client OIDC variables. The publisher login is data-plane-only and receives no
subscription role. The nightly job asks Key Vault to sign the manifest digest; the private key is
non-exportable and never enters the runner.

During the dual-reader rollback window, `LEX_SIGNING_KEY` still signs only the index's embedded
compatibility stamp. The application does not trust that adjacent public key. Runtime trust comes
from the whole-release Key Vault signature and the public-key fingerprint pinned in the Lex image.

When the fleet grows past a couple of publishers, this migrates to the
dispatch/fan-out shape in spec §10.1 — per-corpus-repo workflows triggered via
`workflow_dispatch`, status via run artifacts. The status model and gates stay
identical; only the execution topology changes.

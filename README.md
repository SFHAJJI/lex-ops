# lex-ops — fleet operations

The hub of the hub-and-spoke ops layer (spec §11), running in **N-small
centralized mode** (§11.5): one nightly workflow ingests every enabled
publisher, applies the pre-commit anomaly gate, pushes corpus commits, rebuilds
and signs indexes, uploads release assets, and writes the fleet's three-state
status (`ran_no_change` / `ran_committed` / `failed_*`) — one status commit per
night, never a heartbeat in a corpus repo.

Workflow concurrency is serialized without preemption. If a manual recovery run overlaps the
02:17 schedule, the scheduled run waits rather than racing the active publisher, article, release,
or status writers. The active run is never canceled merely because a newer trigger arrived.
The final status-only commit rebases onto the current `main` and retries a bounded three times, so
an unrelated operations change made during a long Fleet run does not silently discard its status.

If an index build is interrupted after corpus and article commits land, dispatch the workflow with
`force_index_publisher` set to that enabled publisher id (for example, `eu-eurlex`). Fleet still
verifies and derives the committed inputs, but it does not poll any publisher or advance a corpus
head during recovery. It also suppresses the normal stale-index sweep and queues exactly the named
publisher. Invalid or disabled ids fail before cloning, and integrity or derivation failures cannot
be forced past the publication gates.

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

Key-Vault-signed releases are written first to the private `stlexindexes/lex` Blob container under
`releases/<publisher>/<manifest-sha256>/`. Only after every versioned asset upload succeeds does
Fleet replace `current/<publisher>.json`. The pointer is only discovery metadata: the application
still verifies the externally pinned signature and every manifest hash before serving anything.
GitHub Releases remains a public mirror while every individual asset is at most 2 GiB. If an asset
crosses that platform limit, Blob remains canonical and Container App image deployment is blocked
until the measured VM/local-disk path is active; Fleet never deploys a mixture of old and new
publisher releases.

The derived `lex-articles` repository carries `generation.json`, which records every enabled
corpus head and the Git tree fingerprint of `src/Lex.Derive`. Fleet accepts derived changes only
when that deterministic input identity changes. This allows a failed run to resume after corpus
publication and allows an intentional versioned extraction profile to regenerate results, while
identical inputs producing a diff still fail as nondeterminism.

Production publication uses `ARTIFACT_SIGNING_MODE=keyvault`. GitHub Actions authenticates through
the production OIDC environment, and Azure Key Vault signs each canonical manifest with the
non-exportable P-256 key. The private key never enters the runner. The publisher identity has only
the Key Vault `Get`, `Sign` and `Verify` permissions and no subscription role. Immediately after
OIDC login, the workflow signs and verifies a fixed test digest so authorization or digest-encoding
drift fails before the long fleet run begins.

`DEPLOY_AFTER_PUBLISH=1` dispatches the Lex deployment workflow only after at least one artifact
set was built, signed, verified and uploaded successfully. The deployment builds an immutable
image identified by the code and artifact-manifest hashes, creates a zero-traffic Container Apps
revision, runs health, MCP and assistant smoke tests, and only then promotes traffic. The previous
revision remains available for immediate rollback.

If a hosted runner deadline interrupts a large build but a trusted local or self-hosted builder
finishes it, `publish-prebuilt-index` promotes those bytes without bypassing the same gates. The
operator first uploads the DB and vector file to a private `staging/<publisher>/...` Blob prefix,
then dispatches the workflow with their SHA-256 values and the exact corpus commit. The OIDC runner
re-downloads and checks the bytes, verifies that the index stamp binds the exact collection,
corpus commit, Lex build commit, content digest and reviewed enrichment, resolves the pinned model
and scope, creates the whole-artifact manifest, signs it with Key Vault, runs the public benchmark,
and only then updates the immutable Blob/GitHub releases and deployment pointer. Staging is never a
runtime source, and unsigned, mislabelled or hash-mismatched artifacts cannot be promoted.

The normal Fleet run remains the default for routine updates. Use the prebuilt path when the same
deterministic index build has exceeded, or is expected to exceed, the six-hour hosted-runner window.
Do not use `force_index_publisher` merely to repeat a build that cannot fit that window: build from
the exact committed corpus and Lex revisions locally, upload only the DB and vector artifacts, and
let `publish-prebuilt-index` perform provenance checks, signing, benchmarking and deployment.

During the dual-reader rollback window, `LEX_SIGNING_KEY` still signs only the index's embedded
compatibility stamp. The application does not trust that adjacent public key. Runtime trust comes
from the whole-release Key Vault signature and the public-key fingerprint pinned in the Lex image.
The legacy secret is eligible for removal only after 30 stable production days, no earlier than
2026-09-05, and only after the retained rollback revision no longer needs it.

When the fleet grows past a couple of publishers, this migrates to the
dispatch/fan-out shape in spec §10.1 — per-corpus-repo workflows triggered via
`workflow_dispatch`, status via run artifacts. The status model and gates stay
identical; only the execution topology changes.

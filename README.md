# lex-ops - fleet operations

The hub of the hub-and-spoke ops layer (spec §11), running in **N-small
centralized mode** (§11.5): one nightly workflow ingests every enabled
publisher, applies the pre-commit anomaly gate, pushes corpus and derived commits,
records exact index-build inputs, and writes the fleet's three-state
status (`ran_no_change` / `ran_committed` / `failed_*`) - one generated commit per
night on `fleet-status`, never a heartbeat in a code or corpus branch.

Workflow concurrency is serialized without preemption. If a manual recovery run overlaps the
02:17 schedule, the scheduled run waits rather than racing the active publisher, article, release,
or status writers. The active run is never canceled merely because a newer trigger arrived.
The workflow validates and hydrates `status/` from the fast-forward-only `fleet-status` branch
before each run, then publishes a status-only commit there with a bounded retry. A transport error
or concurrent status writer fails closed instead of falling back to stale state. The status tree
accepts only bounded regular JSON/JSONL files directly under `status/`. `main` remains PR-protected
and contains executable operations code only; a long Fleet run never bypasses that protection.

If an index build is interrupted after corpus and article commits land, dispatch the workflow with
`force_index_publisher` set to that enabled publisher id (for example, `eu-eurlex`). Fleet still
verifies and derives the committed inputs, but it does not poll any publisher or advance a corpus
head during recovery. It also suppresses the normal stale-index sweep and queues exactly the named
publisher. Invalid or disabled ids fail before cloning, and integrity or derivation failures cannot
be forced past the publication gates.

- `publishers.json` - the fleet registry.
- `fleet.sh` - the runner.
- `status/` - per-publisher status records (the freshness feed, published on `fleet-status`).
- `status/index-queue.json` - a content-addressed queue/2 ticket binding the exact corpus manifests,
  derived generation and Lex build commit awaiting a local index build, read from an immutable
  `fleet-status` commit. Retrying the same inputs reuses its ticket identity.
- `LEX_OPS_TOKEN` authorizes cross-repository pushes. The assistant-evaluation publisher exposes it
  only for one hard-coded prepublication Immutable Releases setting read: the sole step on a fresh,
  no-checkout runner, never shared with repository or evaluated code. Normal `GITHUB_TOKEN`
  authority performs every assistant-evaluation tag and release write, and final publication
  patches the pinned numeric release ID. The interim OAuth token must be replaced with a GitHub App
  installation token by the third publisher or 90 days, whichever comes first (spec §11.1).
- `LEX_SIGNING_KEY` is retained, unused by enabled workflows, only for the dated rollback window.
  It is not the trust root for released artifacts.

Every index published by the current pipeline travels with a signed `lex-artifacts/1` manifest. The manifest binds
the complete release file list, hashes, sizes, code commit and corpus commit to the public key
pinned in the Lex application release. The pipeline verifies its own output before upload.
The stale-index gate queues any pre-migration release that lacks this manifest, even when its
corpus did not change, so an unsigned legacy asset cannot be treated as current indefinitely.
EU releases also carry the exact reviewed `eu-scope.json` that selected their works. It is a
signed artifact, so a reviewer can reproduce which domains, languages, waves and relationship
rules produced a particular index.

Private staging, exactly-once coordination claims and mutable discovery pointers live in
`stlexindexes/lex`; none is a runtime trust root. The sole canonical published copy is one exact
immutable GitHub Release in the publisher's corpus repository. Publication requires the repository
setting to report `enabled: true`, publishes a draft targeted at the ticketed corpus commit, and
then verifies the locked tag, API asset digests, downloaded bytes, signed manifests and GitHub's
cryptographic release and per-asset attestations.

Only after that verification does Fleet compare-and-swap `lex/current/<publisher>.json`. This
pointer is discovery metadata only: deployment ignores it and pins one exact immutable GitHub tag
per publisher. The current path rejects any individual asset at or above GitHub's 2 GiB limit.
Azure container-level WORM is a future, separately authorized option only if an asset approaches
that limit, Azure must become canonical independently of GitHub, or a fixed regulatory retention
period is required; see the storage decision record.

The derived `lex-articles` repository carries canonical `lex-articles-generation/3`
`generation.json`. Each publisher entry binds the exact corpus commit and manifest digest,
materializing ingester commit, deriver commit and Git tree, and extraction-profile set. Publisher
source configuration is bound once at acquisition: EUR-Lex records the raw engineering-scope hash,
while Legilux is code-only. Fleet accepts derived changes only when that deterministic input identity
changes. This allows a failed run to resume after corpus publication and allows an intentional
versioned extraction profile to regenerate results, while identical inputs producing a diff still
fail as nondeterminism.

The one-time `fresh-corpus-v4` workflow is the only supported migration from the legacy positional
version layout. It requires the exact reviewed Lex `main` commit, approval through the protected
`corpus-v4-migration` environment and an explicit confirmation,
serializes with the nightly Fleet, builds Luxembourg and EU candidates in parallel beside disposable
checkouts, and publishes only after the application proves every held baseline work and dated state
is represented before body acquisition. A partial matrix success is resumable: an already committed
v4 corpus is verified and reused when its materializing Lex commit is a protected ancestor and its
publisher source configuration is unchanged; a changed EU scope is rebuilt. After both protected
corpus heads exist, the workflow derives each publisher once, commits one canonical
articles generation, and writes an immutable prebuilt-index ticket for the local DirectML builder.
Cancellation after either Git publication is recoverable: exact existing bytes and the same ticket
are verified and reused rather than reacquired, rewritten or queued twice.

Dataset releases contain the same provision-version rows as compressed JSONL and Parquet. Some
official EUR-Lex annex tables are tens of megabytes in one legal provision, so conversion uses a
pinned PyArrow version and an explicit 64 MiB JSON-row ceiling rather than PyArrow's small default
read block. Fleet rejects a row above that documented ceiling instead of growing memory without a
bound or silently omitting legal text. Each release tag is addressed by the exact `lex-articles`
commit. A failed export is therefore retried even after the derived commit has already landed,
while a complete release for the current commit makes later no-change nights a cheap skip.

The generated status branch is coordination state, not a release trust root. Server-side branch
rules reject force-pushes and deletion for `fleet-status` and each automated source `main` while
still allowing linear append-only Fleet pushes. Publication also requires every ticketed Lex,
corpus and derived-article commit to belong to that repository's append-only `main` history,
re-verifies the staged hashes and embedded stamp, and requires the production environment before
Key Vault signing.

The public nightly never receives a signing key, logs into Azure, downloads the embedding model or
attempts the long index build. It records `status/index-queue.json` from exact public Git commits.
The deterministic index is built locally from those commits and uploaded to private staging. The
short `publish-prebuilt-index` workflow then authenticates with GitHub OIDC and uses the
non-exportable P-256 Key Vault key to verify, benchmark, sign and publish it. The publisher identity
has only the permissions needed for private staging and manifest signing.

Assistant release evidence uses the same artifact signer through a separate bounded workflow.
`publish-assistant-evaluation` accepts only an exact six-file draft release, including the signed
admission and its detached signature, then checks out the
evaluated Lex commit, temporarily activates the inactive zero-traffic Container Apps revision,
authenticates it and both Azure model deployments (including SKU), verifies the project-owner review
signature and signed admission, and recomputes every report gate. It runs five unmocked Chromium
presentation samples against that exact revision, adds their candidate-bound evidence as the
seventh signed file, and
returns the candidate to inactive state on success, failure or interruption. It then signs the
whole evidence set with the pinned Key Vault key version and publishes the release.
A failed run leaves the draft private. Standard GitHub-hosted runners are free because this
repository is public.

Publication never creates a Container Apps candidate. After both publisher releases have been
independently verified, one reviewed manual Lex deployment consumes their exact manifest set,
builds an immutable image, creates a zero-traffic revision and runs health, MCP and assistant smoke
tests. Traffic remains unchanged. Promotion or rollback is a separate explicit operation naming
both the expected current revision and the exact target.

If a hosted runner deadline interrupts a large build but a trusted local or self-hosted builder
finishes it, `publish-prebuilt-index` promotes those bytes without bypassing the same gates. The
operator first uploads the DB and vector file to a private `staging/<publisher>/...` Blob prefix,
then dispatches the workflow with their SHA-256 values and the exact lex-ops commit containing the
build ticket. The OIDC runner re-downloads and checks the bytes, verifies that the index stamp binds
the ticket's exact collection, corpus manifest, derived generation, Lex build commit and content
digest, resolves the pinned model and publisher-bound source scope, creates the whole-artifact
manifest, signs it with Key Vault, runs the public benchmark,
and only then publishes and attests the immutable GitHub release and updates the discovery pointer.
A benchmark exit of 0 publishes `semantic_activation=true`. Exit 5 is accepted only when the
exact signed report says `activation_gate_passed=false` with typed gate failures and protected Lex
`main` contains the pinned runtime quarantine guard; the legal DB remains usable, but the vector
companion is signed as quarantined. The benchmark manifest, cleanup receipt and release notes bind
that decision. Every other exit, missing evidence or identity mismatch blocks publication. Staging
is never a runtime source, and unsigned, mislabelled or hash-mismatched artifacts cannot be
promoted.

The normal Fleet run remains the default for routine acquisition and derivation. Index construction
always follows the prebuilt path because the measured build exceeds the hosted-runner window. Do not
use `force_index_publisher` merely to repeat that long build: use the commits in
`status/index-queue.json`, upload only the DB and vector artifacts, and let
`publish-prebuilt-index` perform provenance checks, signing and benchmarking. Candidate deployment
remains a separate reviewed manual action after both publisher artifacts are ready.

During the dual-reader rollback window, `LEX_SIGNING_KEY` still signs only the index's embedded
compatibility stamp. The application does not trust that adjacent public key. Runtime trust comes
from the whole-release Key Vault signature and the public-key fingerprint pinned in the Lex image.
The legacy secret is eligible for removal only after 30 stable production days, no earlier than
2026-09-05, and only after the retained rollback revision no longer needs it.

When the fleet grows past a couple of publishers, this migrates to the
dispatch/fan-out shape in spec §10.1 - per-corpus-repo workflows triggered via
`workflow_dispatch`, status via run artifacts. The status model and gates stay
identical; only the execution topology changes.

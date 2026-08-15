# ADR-001: Use immutable GitHub Releases as the current canonical index store

## Status

Accepted

## Date

2026-08-15

## Context

The prebuilt publication path needs immutable public bytes, an exact commit-bound release identity,
and a recovery protocol that does not delete private staging before an independent postflight. The
current DB, vector, model and evidence files each fit below GitHub's 2 GiB per-file release limit,
and protected Lex deployment downloads only operator-pinned exact GitHub release tags. It consumes
neither the Azure discovery pointer nor a Blob release URL.

Adding a second Azure release copy would create another authority and another partial-publication
surface. A locked container-level WORM policy would also introduce a long-lived, difficult-to-reverse
retention decision without a present regulatory or platform requirement.

## Decision

For the current size-bounded path, one immutable GitHub Release in the publisher's corpus repository
is the sole canonical published artifact:

- the workflow must read the repository immutable-release setting and require `enabled: true`;
- it creates an exact draft targeted at the ticketed corpus commit and attaches the complete bundle;
- it rejects every individual asset at or above 2 GiB;
- after publication it verifies the immutable flag, exact tag target, exact API asset SHA-256/size,
  full downloaded bytes, the pinned Key Vault signatures, and GitHub's release and per-asset
  attestations; and
- a valid signed failing benchmark may publish only as `semantic_activation=false` after the exact
  protected runtime quarantine guard is present; malformed, missing or mismatched benchmark
  evidence remains fatal; and
- only an independent postflight may delete the exact ETag-bound private staging pair.

`stlexindexes/lex` remains private staging and mutable coordination/discovery storage. Its
`current/<publisher>.json` value is compare-and-swapped for operator discovery, but Lex deployment
does not consume it as trust or anti-rollback state; deployment pins exact GitHub tags.
The closed cleanup receipt advances to schema `/3` to bind the pinned runtime quarantine guard;
lineage validation keeps the historical `/1` and `/2` shapes strict instead of redefining them.

This follows GitHub's documented immutable-release draft-then-publish flow and attestation model:
<https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases>.
GitHub documents that each release file must be below 2 GiB:
<https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases>.

## Future Azure WORM trigger

Revisit a dedicated `lex-releases` Azure container only when at least one of these becomes true:

- an asset approaches or exceeds GitHub's 2 GiB per-file limit;
- a requirement makes Azure Blob canonical or requires availability independent of GitHub; or
- a legal or regulatory requirement specifies fixed retention.

That future design requires a separate review and explicit authorization before any infrastructure
mutation. The retention period must come from the actual requirement; it is not automatically ten
years. The likely baseline is dedicated container-level WORM with version-level WORM/blob versioning
off and protected append writes off. Microsoft documents the relevant semantics here:

- <https://learn.microsoft.com/en-us/azure/storage/blobs/immutable-storage-overview>
- <https://learn.microsoft.com/en-us/azure/storage/blobs/immutable-container-level-worm-policies>
- <https://learn.microsoft.com/en-us/azure/storage/blobs/immutable-version-level-worm-policies>

## Consequences

- No `lex-releases` container or Azure immutability policy is required or created now.
- The public trust boundary has one immutable authority instead of two.
- Publication fails closed if repository immutability, API digests, local bytes, signatures, tag
  target or GitHub attestations differ.
- A file at or above 2 GiB blocks this path until the future storage decision is explicitly made.

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

When the fleet grows past a couple of publishers, this migrates to the
dispatch/fan-out shape in spec §10.1 — per-corpus-repo workflows triggered via
`workflow_dispatch`, status via run artifacts. The status model and gates stay
identical; only the execution topology changes.

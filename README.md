# lex-ops V3

This repository contains only the V3 operations boundary.

- `ops-v3.yml` runs the single required repository check.
- `v3-preview.yml` deploys one immutable image to a uniquely named, zero-production-traffic
  Container App, runs bounded smoke checks, and always tears it down.
- `v3-preview.sh` rejects mutable images and non-preview resource names, verifies the deployed
  image and configuration by read-back, and verifies deletion by a second read-back.

Production signing, artifact publication, traffic promotion, and rollback do not occur here yet.
They enter only with the complete reviewed V3 release contract. No partial corpus, index, or
answer contract is promotable.

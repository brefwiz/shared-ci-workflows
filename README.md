# shared-ci-workflows (retired)

This repository is retired and archived. Nothing here is built, published or
maintained any more. Do not add new references to it.

Everything it used to provide has a single owner elsewhere:

| What it provided | Where it lives now |
|---|---|
| `docker/ci-base.Dockerfile` (the OS base CI image) | `images/ci-base.Dockerfile` in `brefwiz/dev-platform`, released by its `ci-v*` pipeline as `registry.brefwiz.com/brefwiz/ci-base` |
| `docker/ci.Dockerfile` and the `ghcr.io/brefwiz/ci` image | layers inlined into `images/ci-internal.Dockerfile` in `brefwiz/dev-platform`; pull `registry.brefwiz.com/brefwiz/ci-internal:latest` instead |
| Reusable GitHub workflows (`rust.yml`, `auto-tag.yml`, `release-rust.yml`, `release-npm.yml`) | CDS pipelines built from the composite actions in `brefwiz/ci-workflows` |
| `policies/audit.toml`, `policies/deny.toml` | `policies/` in `brefwiz/ci-workflows` |
| `scripts/check-release-changelog.sh` | `ci-scripts/check-release-changelog.sh` in `brefwiz/ci-workflows` |

The last published `ghcr.io/brefwiz/ci` and `ghcr.io/brefwiz/ci-base` images
stay pullable but are frozen: they receive no toolchain or security updates.

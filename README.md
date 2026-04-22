# shared-ci-workflows

Shared CI infrastructure for brefwiz Rust projects: reusable GitHub Actions
workflows, CI Docker images, and central security policies.

## Reusable Rust CI workflow

Call from any brefwiz Rust repo:

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  ci:
    uses: brefwiz/shared-ci-workflows/.github/workflows/rust.yml@main
    with:
      run-coverage: true        # optional, default false
      run-no-std: true          # optional, default false — requires an `alloc` feature
      use-central-policies: true  # optional, default true
```

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `run-coverage` | bool | `false` | Generate LLVM coverage and upload to Codecov |
| `run-no-std` | bool | `false` | Run `no_std` + `no_std + alloc` checks (requires crate to have an `alloc` feature) |
| `use-central-policies` | bool | `true` | Use `policies/` from this repo for cargo-audit and cargo-deny |
| `extra-test-flags` | string | `""` | Extra flags appended to `cargo nextest run` |
| `container-image` | string | `ghcr.io/brefwiz/ci:latest` | CI container image to use |

### Jobs

`fmt` · `clippy` · `test` · `no-std` (opt-in) · `security` · `coverage` (opt-in)

## CI Docker images

Two images are published to `ghcr.io/brefwiz/` on every push to `main` that
touches a Dockerfile:

| Image | Based on | Contents |
|---|---|---|
| `ghcr.io/brefwiz/ci-base:latest` | `debian:trixie-slim` | Node, Java, openapi-generator, kubectl, helm, helmfile, k3d, nats, Docker CLI, Zig |
| `ghcr.io/brefwiz/ci:latest` | `ci-base` | + Rust stable, cargo-nextest, llvm-cov, cargo-audit, cargo-deny, cargo-hack, cargo-chef, sqlx-cli, sccache, cargo-zigbuild, cargo-vuln-policy-validator |

Tags: `latest` (main branch) and `sha-<short>` (per-commit).

## Central security policies

`policies/deny.toml`, `policies/audit.toml`, and `policies/exceptions.yaml`
form the central cargo-deny / cargo-audit / exception-review contract. Every
advisory allowlist entry carries a `# review-by: YYYY-MM-DD` comment;
`scripts/check-policy-expiry.sh` fails CI once the date passes, and
`cargo-vuln-policy-validator` checks that the TOML ignore lists match the YAML
exceptions file.

See [`policies/README.md`](policies/README.md) for the full review contract.

## License

MIT — see [LICENSE](LICENSE)

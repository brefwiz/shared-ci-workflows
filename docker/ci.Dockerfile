# ci — Full CI Image
# ===================
# Extends ci-base with the Rust toolchain and cargo tools.
# Rebuild this layer when: Rust version or cargo tool versions change.
# ci-base rebuild does NOT require this image to be rebuilt — it will
# pick up the new base automatically on next push to main.
#
# Added tooling (on top of ci-base):
#   - Rust stable (rustfmt, clippy, llvm-tools-preview)
#   - Fast linker: mold + clang (already in base, wired up here)
#   - cargo-nextest, cargo-llvm-cov, cargo-audit, cargo-deny, cargo-hack, sqlx-cli
#   - cargo-zigbuild (uses Zig from ci-base for reliable aarch64-musl cross-compilation)
#   - cargo-vuln-policy-validator (central allowlist/policy validation helper)

ARG RUST_VERSION=1.95
ARG API_BONES_SDK_GEN_VERSION=0.1.0
ARG CARGO_NEXTEST_VERSION=0.9.114
ARG CARGO_LLVM_COV_VERSION=0.8.4
ARG CARGO_CHEF_VERSION=0.1.77
ARG SQLX_CLI_VERSION=0.8.6
ARG CARGO_DENY_VERSION=0.19.4
ARG CARGO_HACK_VERSION=0.6.37
ARG SCCACHE_VERSION=0.10.0
ARG CARGO_ZIGBUILD_VERSION=0.19.4
ARG CARGO_VULN_POLICY_VALIDATOR_REPO=https://github.com/brefwiz/cargo-vuln-policy-validator
ARG CARGO_VULN_POLICY_VALIDATOR_REF=main
ARG CI_BASE_TAG=latest

FROM ghcr.io/brefwiz/ci-base:${CI_BASE_TAG}

ARG RUST_VERSION
ARG CARGO_NEXTEST_VERSION
ARG CARGO_LLVM_COV_VERSION
ARG CARGO_CHEF_VERSION
ARG SQLX_CLI_VERSION
ARG CARGO_DENY_VERSION
ARG CARGO_HACK_VERSION
ARG SCCACHE_VERSION
ARG CARGO_ZIGBUILD_VERSION
ARG CARGO_VULN_POLICY_VALIDATOR_REPO
ARG CARGO_VULN_POLICY_VALIDATOR_REF
ARG API_BONES_SDK_GEN_VERSION

# ── Rust toolchain ─────────────────────────────────────────────────────────────
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

RUN mkdir -p /usr/local/cargo /usr/local/rustup \
    && chmod -R a+rwX /usr/local/cargo /usr/local/rustup

RUN curl -fsSL https://sh.rustup.rs | sh -s -- \
      -y \
      --no-modify-path \
      --profile minimal \
      --default-toolchain ${RUST_VERSION} \
    && rustup component add rustfmt clippy llvm-tools-preview \
    && rustup target add x86_64-unknown-linux-musl aarch64-unknown-linux-musl \
    && rustc --version && cargo --version

# ── Cargo tools ───────────────────────────────────────────────────────────────
RUN cargo install cargo-nextest --version ${CARGO_NEXTEST_VERSION} --locked \
    && cargo install cargo-llvm-cov --version ${CARGO_LLVM_COV_VERSION} --locked \
    && cargo install cargo-chef --version ${CARGO_CHEF_VERSION} --locked \
    && cargo install cargo-hack --version ${CARGO_HACK_VERSION} --locked \
    && cargo install cargo-audit --locked \
    && cargo install cargo-deny --version ${CARGO_DENY_VERSION} --locked \
    && cargo install cargo-vuln-policy-validator \
        --git ${CARGO_VULN_POLICY_VALIDATOR_REPO} \
        --branch ${CARGO_VULN_POLICY_VALIDATOR_REF} \
        --locked \
    && cargo install sqlx-cli \
        --version ${SQLX_CLI_VERSION} \
        --no-default-features \
        --features native-tls,postgres \
        --locked \
    && cargo install sccache --version ${SCCACHE_VERSION} --locked \
    && cargo install cargo-zigbuild --version ${CARGO_ZIGBUILD_VERSION} --locked \
    && cargo install api-bones-sdk-gen \
        --version ${API_BONES_SDK_GEN_VERSION} \
        --locked \
    && mkdir -p /opt/brefwiz \
    && api-bones-sdk-gen makefile > /opt/brefwiz/api-bones-sdk.mk \
    && rm -rf ${CARGO_HOME}/registry/cache \
    && cargo nextest --version \
    && cargo llvm-cov --version \
    && cargo chef --version \
    && cargo hack --version \
    && cargo audit --version \
    && cargo deny --version \
    && printf '[advisories]\nignore = ["RUSTSEC-0000-0000"]\n' > /tmp/smoke-audit.toml \
    && printf '[advisories]\nignore = []\n' > /tmp/smoke-deny.toml \
    && printf 'exceptions:\n  - id: RUSTSEC-0000-0000\n    owner: smoke-test\n    review_by: 2099-01-01\n    reason: smoke test\n    risk: known\n    impact: low\n    tracking: NONE\n    resolution: none\n' > /tmp/smoke-exceptions.yaml \
    && cargo-vuln-policy-validator /tmp/smoke-audit.toml /tmp/smoke-deny.toml /tmp/smoke-exceptions.yaml \
    && rm /tmp/smoke-audit.toml /tmp/smoke-deny.toml /tmp/smoke-exceptions.yaml \
    && sqlx --version \
    && sccache --version \
    && cargo zigbuild --help > /dev/null \
    && api-bones-sdk-gen --version

# ── CI-optimised Rust defaults ────────────────────────────────────────────────
# sccache: RUSTC_WRAPPER is NOT set globally — jobs opt in by setting it to
# sccache when /var/cache/sccache is mounted in. Defaults for dir/size are set
# so opt-in jobs only need the one env var.
ENV CARGO_TERM_COLOR=always \
    CARGO_INCREMENTAL=0 \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=clang \
    RUSTFLAGS="-C link-arg=-fuse-ld=mold" \
    RUST_BACKTRACE=1 \
    SQLX_OFFLINE=true \
    SCCACHE_DIR=/var/cache/sccache \
    SCCACHE_CACHE_SIZE=30G \
    SCCACHE_IDLE_TIMEOUT=0

# ── Ensure world-writable cargo/rustup (for non-root CI runners) ──────────────
RUN chmod -R a+rwX /usr/local/cargo /usr/local/rustup

# ── Labels ────────────────────────────────────────────────────────────────────
LABEL org.opencontainers.image.title="ci" \
      org.opencontainers.image.description="Full CI image — ci-base + Rust toolchain + cargo tools + policy validator" \
      org.opencontainers.image.source="https://github.com/brefwiz/shared-ci-workflows"

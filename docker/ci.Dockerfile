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
#   - cargo-binstall (installs pre-built binaries; avoids recompilation)
#   - cargo-nextest, cargo-llvm-cov, cargo-audit, cargo-deny, cargo-hack, sqlx-cli,
#     sccache, cargo-zigbuild, wasm-pack (pre-built via binstall)
#   - cargo-vuln-policy-validator, api-bones-sdk-gen (private; compiled from source)

ARG RUST_VERSION=1.94.1
ARG API_BONES_SDK_GEN_VERSION=4.4.0

ARG CARGO_BINSTALL_VERSION=1.19.1

ARG CARGO_NEXTEST_VERSION=0.9.114
ARG CARGO_LLVM_COV_VERSION=0.8.7
ARG CARGO_CHEF_VERSION=0.1.77
# 0.9.0: 0.8.x sqlx-cli fails `cargo sqlx prepare --check` with "Issue parsing
# cargo metadata output" on larger modern dep trees (its bundled cargo_metadata
# is too old for newer crate manifests). 0.9 also matches the sqlx 0.9 library.
ARG SQLX_CLI_VERSION=0.9.0
ARG CARGO_DENY_VERSION=0.19.8
ARG CARGO_HACK_VERSION=0.6.37
ARG SCCACHE_VERSION=0.10.0
ARG CARGO_ZIGBUILD_VERSION=0.19.4
ARG CARGO_SWEEP_VERSION=0.8.0
ARG WASM_PACK_VERSION=0.13.1
# release-plz: real upstream binary (release-pr / release two-step flow) —
# sole tag authority for the Rust axis. Replaces the hand-rolled
# release-plz-bump.py clone, which had a non-atomic commit/tag/publish
# sequence (see "unified fleet release engine" design).
ARG RELEASE_PLZ_VERSION=0.3.159
ARG CARGO_VULN_POLICY_VALIDATOR_REPO=https://github.com/brefwiz/cargo-vuln-policy-validator
ARG CARGO_VULN_POLICY_VALIDATOR_REF=main
ARG CI_BASE_TAG=latest

FROM ghcr.io/brefwiz/ci-base:${CI_BASE_TAG}

ARG RUST_VERSION
ARG CARGO_BINSTALL_VERSION
ARG CARGO_NEXTEST_VERSION
ARG CARGO_LLVM_COV_VERSION
ARG CARGO_CHEF_VERSION
ARG SQLX_CLI_VERSION
ARG CARGO_DENY_VERSION
ARG CARGO_HACK_VERSION
ARG SCCACHE_VERSION
ARG CARGO_ZIGBUILD_VERSION
ARG CARGO_SWEEP_VERSION
ARG WASM_PACK_VERSION
ARG RELEASE_PLZ_VERSION
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
    && rustup target add x86_64-unknown-linux-musl aarch64-unknown-linux-musl wasm32-unknown-unknown \
    && rustc --version && cargo --version

# ── cargo-binstall ─────────────────────────────────────────────────────────────
# Installs pre-built binaries from GitHub releases; avoids compiling from source.
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in \
         amd64) TRIPLE="x86_64-unknown-linux-musl" ;; \
         arm64) TRIPLE="aarch64-unknown-linux-musl" ;; \
         *) echo "Unsupported arch: $ARCH" && exit 1 ;; \
       esac \
    && curl -fsSL --retry 5 --retry-delay 5 \
         "https://github.com/cargo-bins/cargo-binstall/releases/download/v${CARGO_BINSTALL_VERSION}/cargo-binstall-${TRIPLE}.tgz" \
       | tar -xz -C /usr/local/cargo/bin \
    && cargo-binstall -V

# ── Cargo tools (pre-built binaries via binstall) ──────────────────────────────
RUN cargo binstall --no-confirm --locked \
        cargo-nextest@${CARGO_NEXTEST_VERSION} \
        cargo-llvm-cov@${CARGO_LLVM_COV_VERSION} \
        cargo-chef@${CARGO_CHEF_VERSION} \
        cargo-hack@${CARGO_HACK_VERSION} \
        cargo-audit \
        cargo-deny@${CARGO_DENY_VERSION} \
        sccache@${SCCACHE_VERSION} \
        cargo-zigbuild@${CARGO_ZIGBUILD_VERSION} \
        cargo-sweep@${CARGO_SWEEP_VERSION} \
        sqlx-cli@${SQLX_CLI_VERSION} \
        wasm-pack@${WASM_PACK_VERSION} \
        release-plz@${RELEASE_PLZ_VERSION} \
    && cargo nextest --version \
    && cargo llvm-cov --version \
    && cargo chef --version \
    && cargo hack --version \
    && cargo audit --version \
    && cargo deny --version \
    && sccache --version \
    && cargo zigbuild --help > /dev/null \
    && cargo sweep --version \
    && sqlx --version \
    && wasm-pack --version \
    && release-plz --version

# ── Private cargo tools (must compile from source) ────────────────────────────
RUN cargo install cargo-vuln-policy-validator \
        --git ${CARGO_VULN_POLICY_VALIDATOR_REPO} \
        --branch ${CARGO_VULN_POLICY_VALIDATOR_REF} \
        --locked \
    && cargo install api-bones-sdk-gen \
        --version ${API_BONES_SDK_GEN_VERSION} \
        --locked \
    && mkdir -p /opt/brefwiz \
    && api-bones-sdk-gen makefile > /opt/brefwiz/api-bones-sdk.mk \
    && rm -rf ${CARGO_HOME}/registry/cache \
    && printf '[advisories]\nignore = ["RUSTSEC-0000-0000"]\n' > /tmp/smoke-audit.toml \
    && printf '[advisories]\nignore = []\n' > /tmp/smoke-deny.toml \
    && printf 'exceptions:\n  - id: RUSTSEC-0000-0000\n    owner: smoke-test\n    review_by: 2099-01-01\n    reason: smoke test\n    risk: known\n    impact: low\n    tracking: NONE\n    resolution: none\n' > /tmp/smoke-exceptions.yaml \
    && cargo-vuln-policy-validator /tmp/smoke-audit.toml /tmp/smoke-deny.toml /tmp/smoke-exceptions.yaml \
    && rm /tmp/smoke-audit.toml /tmp/smoke-deny.toml /tmp/smoke-exceptions.yaml \
    && api-bones-sdk-gen --version

# ── CI-optimised Rust defaults ────────────────────────────────────────────────
# sccache: RUSTC_WRAPPER is NOT set globally — jobs opt in by setting it to
# sccache when /var/cache/sccache is mounted in. Defaults for dir/size are set
# so opt-in jobs only need the one env var.
ENV CARGO_TERM_COLOR=always \
    CARGO_INCREMENTAL=0 \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=clang \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=clang \
    RUSTFLAGS="-C link-arg=-fuse-ld=mold" \
    RUST_BACKTRACE=1 \
    SQLX_OFFLINE=true \
    SCCACHE_DIR=/var/cache/sccache \
    SCCACHE_CACHE_SIZE=30G \
    SCCACHE_IDLE_TIMEOUT=0 \
    RUSTUP_TOOLCHAIN=1.94.1 \
    AR_aarch64_unknown_linux_musl=llvm-ar \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=aarch64-linux-musl-gcc \
    CC_aarch64_unknown_linux_musl=aarch64-linux-musl-gcc \
    # zig cc (our musl-gcc wrapper) provides its own crt1.o; rustc's
    # self-contained crt also ships crt1.o for aarch64-unknown-linux-musl,
    # causing duplicate `_start` at link time. Tell rustc to skip its
    # self-contained linker components for this target — zig owns crt.
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C link-self-contained=no"

# ── Ensure world-writable cargo/rustup (for non-root CI runners) ──────────────
RUN chmod -R a+rwX /usr/local/cargo /usr/local/rustup

# ── Labels ────────────────────────────────────────────────────────────────────
LABEL org.opencontainers.image.title="ci" \
      org.opencontainers.image.description="Full CI image — ci-base + Rust toolchain + cargo tools + policy validator" \
      org.opencontainers.image.source="https://github.com/brefwiz/shared-ci-workflows"

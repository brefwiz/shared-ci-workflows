# ci-base — Base CI Image
# ========================
# System tools shared by all CI jobs. Intentionally excludes Rust.
# Rebuild this layer when: Node, Java, openapi-generator, kubectl,
# helm, helmfile, k3d, nats, redocly, or Zig versions change.
#
# Included tooling:
#   - Node.js (LTS)
#   - Java 21 (openapi-generator-cli)
#   - openapi-generator-cli (pinned jar, exposed as `openapi-generator`)
#   - kubectl, helm, helmfile, k3d
#   - nats-server
#   - buf (protobuf linter / breaking-change detector)
#   - @redocly/cli (npm global)
#   - Python 3, Go (SDK generation utilities)
#   - Build essentials (mold, clang, pkg-config, libssl-dev, libpq-dev)
#   - Docker CLI + buildx (daemon runs on host; socket mounted at job level)
#   - Zig (used by cargo-zigbuild for reliable musl cross-compilation)
#   - aarch64-linux-musl-strip, x86_64-linux-musl-strip (symlink aliases for strip)
#
# Multi-arch: linux/amd64 and linux/arm64. All download URLs use
# $(dpkg --print-architecture) or equivalent arch detection at build time.

ARG NODE_MAJOR=24
ARG ZIG_VERSION=0.14.0
ARG OPENAPI_GENERATOR_VERSION=7.12.0
ARG KUBECTL_VERSION=1.35.2
ARG HELM_VERSION=4.1.3
ARG HELMFILE_VERSION=1.4.2
ARG NATS_VERSION=2.12.5
ARG BUF_VERSION=1.47.2
ARG PROTOC_GEN_CONNECT_OPENAPI_VERSION=v0.16.0

FROM debian:trixie-slim

ARG NODE_MAJOR
ARG ZIG_VERSION
ARG OPENAPI_GENERATOR_VERSION
ARG KUBECTL_VERSION
ARG HELM_VERSION
ARG HELMFILE_VERSION
ARG NATS_VERSION
ARG BUF_VERSION
ARG PROTOC_GEN_CONNECT_OPENAPI_VERSION

# ── System packages ────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Build essentials (needed by Rust layer and native Node modules)
    build-essential mold clang \
    pkg-config libssl-dev libpq-dev \
    # musl C toolchains
    # musl-tools: provides musl-gcc for x86_64-unknown-linux-musl
    # gcc-aarch64-linux-gnu: binutils only (objcopy etc.); Zig handles aarch64 musl C compilation
    musl-tools gcc-aarch64-linux-gnu \
    # Protobuf compiler + well-known .proto files (prost-wkt-types needs them)
    protobuf-compiler libprotobuf-dev \
    # Tools — cmake required by aws-lc-sys (rustls-aws-lc backend) at build time
    ca-certificates curl git make cmake jq tar xz-utils \
    # Python + CI script deps (check-spec.py requires pyyaml + jsonschema)
    python3 python3-pip python3-venv python3-yaml python3-jsonschema \
    # Java 21 (openapi-generator-cli)
    openjdk-21-jdk-headless \
    # Go (SDK generation utilities)
    golang-go \
    && rm -rf /var/lib/apt/lists/*

# ── Zig (aarch64 musl cross-compilation via cargo-zigbuild) ───────────────────
# Zig uses x86_64/aarch64 naming; map from dpkg's amd64/arm64.
RUN DPKG_ARCH=$(dpkg --print-architecture) \
    && case "$DPKG_ARCH" in \
         amd64) ZIG_ARCH="x86_64"  ;; \
         arm64) ZIG_ARCH="aarch64" ;; \
         *) echo "Unsupported arch: $DPKG_ARCH" && exit 1 ;; \
       esac \
    && curl -fsSL --retry 5 --retry-delay 5 \
         "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz" \
         -o /tmp/zig.tar.xz \
    && tar -xJ -C /usr/local/lib -f /tmp/zig.tar.xz \
    && ln -s "/usr/local/lib/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}/zig" /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz \
    && zig version

# ── Node.js (via NodeSource) ───────────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version && npm --version \
    && npm install -g @redocly/cli \
    && redocly --version

# ── openapi-generator-cli ──────────────────────────────────────────────────────
RUN curl -fsSL \
    "https://repo1.maven.org/maven2/org/openapitools/openapi-generator-cli/${OPENAPI_GENERATOR_VERSION}/openapi-generator-cli-${OPENAPI_GENERATOR_VERSION}.jar" \
    -o /usr/local/lib/openapi-generator-cli.jar \
    && printf '#!/bin/sh\nexec java -jar /usr/local/lib/openapi-generator-cli.jar "$@"\n' \
       > /usr/local/bin/openapi-generator \
    && chmod +x /usr/local/bin/openapi-generator \
    && openapi-generator version

# ── kubectl ───────────────────────────────────────────────────────────────────
# kubectl release arch names match dpkg: amd64, arm64.
RUN curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/$(dpkg --print-architecture)/kubectl" \
    -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client

# ── Helm ──────────────────────────────────────────────────────────────────────
# Helm archive path uses linux-amd64 / linux-arm64.
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz" \
       | tar -xz --strip-components=1 -C /usr/local/bin "linux-${ARCH}/helm" \
    && helm version

# ── Helmfile ──────────────────────────────────────────────────────────────────
# Helmfile asset name uses linux_amd64 / linux_arm64 (underscores).
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_${ARCH}.tar.gz" \
       | tar -xz -C /usr/local/bin helmfile \
    && helmfile --version

# ── k3d ───────────────────────────────────────────────────────────────────────
RUN curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash \
    && k3d version

# ── Docker CLI + buildx plugin ────────────────────────────────────────────────
# CLI only — the docker daemon runs on the runner host. CI jobs that need
# docker-build/docker-push mount /var/run/docker.sock into the container.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
       -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
        https://download.docker.com/linux/debian trixie stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        docker-ce-cli docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/* \
    && docker --version \
    && docker buildx version

# ── musl strip aliases ────────────────────────────────────────────────────────
# aarch64-linux-gnu-strip (from gcc-aarch64-linux-gnu) strips musl ELF identically
# to a hypothetical aarch64-linux-musl-strip: strip is libc-agnostic.
# x86_64: the host strip (binutils) handles x86_64 musl ELF natively; we expose a
# named alias so callers can use a consistent aarch64/x86_64 naming convention.
RUN ln -s /usr/bin/aarch64-linux-gnu-strip /usr/local/bin/aarch64-linux-musl-strip \
    && ln -s /usr/bin/strip                /usr/local/bin/x86_64-linux-musl-strip \
    && aarch64-linux-musl-strip --version \
    && x86_64-linux-musl-strip --version

# ── aarch64-linux-musl-gcc wrapper ───────────────────────────────────────────
# cargo-zigbuild uses zig cc for aarch64 musl builds, but plain `cargo check
# --target aarch64-unknown-linux-musl` (e.g. publish-preflight) invokes CC
# directly via cc-rs. Provide a named wrapper so cc-rs finds its compiler.
# cc-rs also passes --target=aarch64-unknown-linux-musl (Rust triple, not zig
# syntax); strip it — the target is already hardcoded in this wrapper.
RUN printf '#!/bin/bash\nargs=()\nfor a in "$@"; do [[ "$a" == --target=* ]] || args+=("$a"); done\nexec zig cc -target aarch64-linux-musl "${args[@]}"\n' \
      > /usr/local/bin/aarch64-linux-musl-gcc \
    && chmod +x /usr/local/bin/aarch64-linux-musl-gcc \
    && aarch64-linux-musl-gcc --version

# ── nats-server ───────────────────────────────────────────────────────────────
# NATS asset name uses linux-amd64 / linux-arm64.
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/nats-io/nats-server/releases/download/v${NATS_VERSION}/nats-server-v${NATS_VERSION}-linux-${ARCH}.tar.gz" \
       | tar -xz --strip-components=1 -C /usr/local/bin \
           "nats-server-v${NATS_VERSION}-linux-${ARCH}/nats-server" \
    && nats-server --version

# ── buf (protobuf linter / breaking-change detector) ─────────────────────────
# Replaces brefwiz/ci-workflows install-buf composite action — baked in so
# CI jobs don't reinstall on every run. Asset name uses Linux-x86_64 /
# Linux-aarch64 (note: capital L, and aarch64 — distinct from kubectl/helm).
RUN UNAME_M=$(uname -m) \
    && curl -fsSL --retry 5 --retry-delay 5 \
        "https://github.com/bufbuild/buf/releases/download/v${BUF_VERSION}/buf-Linux-${UNAME_M}" \
        -o /usr/local/bin/buf \
    && chmod +x /usr/local/bin/buf \
    && buf --version

# ── protoc-gen-connect-openapi (Go plugin for buf gen) ───────────────────────
# Generates OpenAPI 3 schemas from Connect-flavored protobuf services. Required
# by brefwiz services that emit OpenAPI alongside Connect bindings (ADR-0085).
# `go install` into a stable bindir; Go itself is already present (golang-go).
ENV GOBIN=/usr/local/bin
RUN go install \
        "github.com/sudorandom/protoc-gen-connect-openapi@${PROTOC_GEN_CONNECT_OPENAPI_VERSION}" \
    && protoc-gen-connect-openapi --version 2>&1 | head -1 || \
       echo "protoc-gen-connect-openapi installed (version flag may vary)"

# ── Labels ────────────────────────────────────────────────────────────────────
LABEL org.opencontainers.image.title="ci-base" \
      org.opencontainers.image.description="Base CI image — Node, Java, openapi-generator, kubectl, helm, k3d, nats, buf" \
      org.opencontainers.image.source="https://github.com/brefwiz/shared-ci-workflows"

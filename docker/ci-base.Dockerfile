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
#   - @redocly/cli (npm global)
#   - Python 3, Go (SDK generation utilities)
#   - Build essentials (mold, clang, pkg-config, libssl-dev, libpq-dev)
#   - Docker CLI + buildx (daemon runs on host; socket mounted at job level)
#   - Zig (used by cargo-zigbuild for reliable musl cross-compilation)

ARG NODE_MAJOR=24
ARG ZIG_VERSION=0.14.0
ARG OPENAPI_GENERATOR_VERSION=7.12.0
ARG KUBECTL_VERSION=1.35.2
ARG HELM_VERSION=4.1.3
ARG HELMFILE_VERSION=1.4.2
ARG NATS_VERSION=2.12.5

FROM debian:trixie-slim

ARG NODE_MAJOR
ARG ZIG_VERSION
ARG OPENAPI_GENERATOR_VERSION
ARG KUBECTL_VERSION
ARG HELM_VERSION
ARG HELMFILE_VERSION
ARG NATS_VERSION

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
    # Tools
    ca-certificates curl git make jq tar \
    # Python
    python3 python3-pip python3-venv \
    # Java 21 (openapi-generator-cli)
    openjdk-21-jdk-headless \
    # Go (SDK generation utilities)
    golang-go \
    && rm -rf /var/lib/apt/lists/*

# ── Zig (aarch64 musl cross-compilation via cargo-zigbuild) ───────────────────
# musl.cc is unreliable from GitHub Actions runners. Zig ships its own libc
# headers (including musl) and acts as a drop-in C cross-compiler for any
# target triple. cargo-zigbuild (installed in the ci layer) wraps cargo build
# to use Zig as the linker/compiler, replacing the musl.cc toolchain entirely.
# Zig releases are hosted on GitHub — always reachable from Actions.
RUN curl -fsSL --retry 5 --retry-delay 5 \
      "https://github.com/ziglang/zig/releases/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
      -o /tmp/zig.tar.xz \
    && tar -xJ -C /usr/local/lib -f /tmp/zig.tar.xz \
    && ln -s "/usr/local/lib/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig \
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
RUN curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client

# ── Helm ──────────────────────────────────────────────────────────────────────
RUN curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
    | tar -xz --strip-components=1 -C /usr/local/bin linux-amd64/helm \
    && helm version

# ── Helmfile ──────────────────────────────────────────────────────────────────
RUN curl -fsSL "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz" \
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

# ── nats-server ───────────────────────────────────────────────────────────────
RUN curl -fsSL "https://github.com/nats-io/nats-server/releases/download/v${NATS_VERSION}/nats-server-v${NATS_VERSION}-linux-amd64.tar.gz" \
    | tar -xz --strip-components=1 -C /usr/local/bin \
        "nats-server-v${NATS_VERSION}-linux-amd64/nats-server" \
    && nats-server --version

# ── Labels ────────────────────────────────────────────────────────────────────
LABEL org.opencontainers.image.title="ci-base" \
      org.opencontainers.image.description="Base CI image — Node, Java, openapi-generator, kubectl, helm, k3d, nats" \
      org.opencontainers.image.source="https://github.com/brefwiz/shared-ci-workflows"

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
#   - @redocly/cli, jscpd (npm global)
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
ARG PROTOC_GEN_CONNECT_OPENAPI_VERSION=v0.25.6
# release-please: manifest-first, PR-based release automation for every
# non-Rust SDK language (TS/npm today; Python/Go/Swift/Java as those SDKs
# come online) — see ADR-track "unified fleet release engine" design.
ARG RELEASE_PLEASE_VERSION=17.10.2
# Duplication gate tooling. All PINNED: jscpd's own token counts drift between
# versions, and a grammar change moves what the wiring tiers see -- either would
# re-baseline every repo in a single PR and turn the ratchet into noise.
#
# The two tree-sitter pins are versioned independently upstream. The PyPI
# binding tops out at 0.26.0; the language pack vendors its own grammars and
# only asks for tree-sitter>=0.23, so the pack pin is the one that actually
# determines what the parsers do.
ARG JSCPD_VERSION=5.0.14
ARG TREE_SITTER_VERSION=0.26.0
ARG TREE_SITTER_PACK_VERSION=1.14.1

# Base repository and digest are ARGs so the two lanes that build this file can
# each reach it the cheapest way. The defaults are the public coordinates, so
# the GitHub build and anyone building this by hand are unchanged; the internal
# lane overrides DEBIAN_IMAGE to a registry mirror rather than pulling Docker
# Hub across the internet on every architecture leg of every build.
#
# The digest is the load-bearing half. Our buildah recipe derives its pull
# policy from this file: every base pinned by digest gets `--pull=missing`,
# anything tag-based gets `--pull-always`, because a tag can move under a stale
# local copy. A digest cannot, so pinning removes a full base-image pull per
# arch, per build. Digests are content addresses, so this same one resolves
# through a mirror as well as through Docker Hub.
#
# renovate: datasource=docker depName=debian
ARG DEBIAN_IMAGE=debian
ARG DEBIAN_TAG=trixie-slim
ARG DEBIAN_DIGEST=sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258

FROM ${DEBIAN_IMAGE}:${DEBIAN_TAG}@${DEBIAN_DIGEST}

ARG NODE_MAJOR
ARG ZIG_VERSION
ARG OPENAPI_GENERATOR_VERSION
ARG KUBECTL_VERSION
ARG HELM_VERSION
ARG HELMFILE_VERSION
ARG NATS_VERSION
ARG BUF_VERSION
ARG PROTOC_GEN_CONNECT_OPENAPI_VERSION
ARG RELEASE_PLEASE_VERSION
ARG JSCPD_VERSION
ARG TREE_SITTER_VERSION
ARG TREE_SITTER_PACK_VERSION

# ── System packages ────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Build essentials (needed by Rust layer and native Node modules)
    build-essential mold clang \
    pkg-config libssl-dev libpq-dev \
    # musl C toolchains
    # musl-tools: provides musl-gcc for x86_64-unknown-linux-musl
    # gcc-aarch64-linux-gnu: binutils only (objcopy etc.); Zig handles aarch64 musl C compilation
    musl-tools gcc-aarch64-linux-gnu \
    # libunwind: jemalloc's heap profiling (--enable-prof-libunwind) calls
    # unw_backtrace on each sampled allocation. Without it, jemalloc falls back
    # to libgcc's _Unwind_Backtrace, which segfaults in a statically linked musl
    # binary — brefwiz-spiffe shipped that three times before CI could see it.
    # This covers glibc host builds and `cargo *--all-features`, which link
    # -lunwind as soon as the feature is enabled anywhere in the graph. Static
    # musl targets additionally need a musl-built libunwind; see below.
    libunwind-dev \
    # Protobuf compiler + well-known .proto files (prost-wkt-types needs them)
    protobuf-compiler libprotobuf-dev \
    # Tools — cmake required by aws-lc-sys (rustls-aws-lc backend) at build time
    ca-certificates curl git make cmake jq rsync tar xz-utils zstd openssh-client \
    # Python + CI script deps (check-spec.py requires pyyaml + jsonschema)
    python3 python3-pip python3-venv python3-yaml python3-jsonschema python3-pydantic python3-pytest python3-pytest-xdist \
    # Java 21 (openapi-generator-cli)
    openjdk-21-jdk-headless \
    # Go (SDK generation utilities)
    golang-go \
    && rm -rf /var/lib/apt/lists/*

# ── Python CI script deps (pip) ────────────────────────────────────────────────
# pyrefly not packaged in apt (young Rust-based type checker, pip/cargo only).
RUN python3 -m pip install -q --break-system-packages \
      pyrefly \
      "tree-sitter==${TREE_SITTER_VERSION}" \
      "tree-sitter-language-pack==${TREE_SITTER_PACK_VERSION}" \
    && pyrefly --version \
    && python3 -c "import tree_sitter_language_pack as p; p.get_parser('rust'); print('tree-sitter grammars ok')"

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
    && npm install -g @redocly/cli release-please@${RELEASE_PLEASE_VERSION} jscpd@${JSCPD_VERSION} \
    && redocly --version \
    && release-please --version \
    && jscpd --version

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
        docker-ce-cli docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/* \
    && docker --version \
    && docker buildx version \
    && docker compose version

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
# -march=* flags from crate build scripts (ring, aws-lc-sys, zstd-sys) use GCC
# arch names (e.g. armv8.4-a) that Zig's CC frontend does not recognise. Strip
# them: the target triple already encodes the architecture for Zig.
RUN printf '#!/bin/bash\nargs=()\nfor a in "$@"; do\n  [[ "$a" == --target=* ]] && continue\n  [[ "$a" == -march=* ]]   && continue\n  args+=("$a")\ndone\nexec zig cc -target aarch64-linux-musl "${args[@]}"\n' \
      > /usr/local/bin/aarch64-linux-musl-gcc \
    && chmod +x /usr/local/bin/aarch64-linux-musl-gcc \
    && aarch64-linux-musl-gcc --version

# ── llvm-ar wrapper ───────────────────────────────────────────────────────────
# ci.Dockerfile sets AR_aarch64_unknown_linux_musl=llvm-ar so cc-rs uses the
# right archiver for aarch64-musl builds (ring, aws-lc-sys, zstd-sys). zig ar
# provides a fully compatible ar implementation; expose it as llvm-ar so the
# env var resolves without requiring the full llvm package.
RUN printf '#!/bin/sh\nexec zig ar "$@"\n' \
      > /usr/local/bin/llvm-ar \
    && chmod +x /usr/local/bin/llvm-ar \
    && llvm-ar --version

# ── libunwind for static musl targets ─────────────────────────────────────────
# jemalloc built with --enable-prof-libunwind calls unw_backtrace on every
# sampled allocation. Without a musl-built libunwind, jemalloc falls back to
# libgcc's _Unwind_Backtrace, which has no working unwind path in a statically
# linked musl binary: brefwiz-spiffe shipped that three times and each release
# segfaulted in production rather than failing in CI.
#
# The apt libunwind-dev above covers glibc host builds. It cannot serve musl
# targets — Debian's build links glibc — so both musl arches are built here
# from source.
#
# Built with zig cc for both arches rather than musl-gcc for one and zig for
# the other: musl-gcc targets whatever the builder happens to be, and this
# image is built for amd64 and arm64. Zig makes the output independent of the
# builder, which is the same reason the aarch64 wrapper above exists.
#
# --disable-minidebuginfo is load-bearing, not tidiness. With it enabled
# libunwind reads LZMA-compressed .gnu_debugdata and needs liblzma and libz at
# static link time; a dynamic link hides that behind DT_NEEDED, a static one
# does not, and consumers would have to carry both. Disabling it makes the
# archive self-contained for the only thing jemalloc wants from it.
ARG LIBUNWIND_VERSION=1.8.3
RUN set -eux; \
    curl -fsSL --retry 5 --retry-delay 5 \
      "https://github.com/libunwind/libunwind/releases/download/v${LIBUNWIND_VERSION}/libunwind-${LIBUNWIND_VERSION}.tar.gz" \
      -o /tmp/libunwind.tar.gz; \
    for ARCH in x86_64 aarch64; do \
      rm -rf /tmp/lu && mkdir -p /tmp/lu; \
      tar -xzf /tmp/libunwind.tar.gz -C /tmp/lu --strip-components=1; \
      cd /tmp/lu; \
      CC="zig cc -target ${ARCH}-linux-musl" \
      AR="zig ar" \
      RANLIB="zig ranlib" \
      ./configure \
        --host="${ARCH}-linux-musl" \
        --prefix="/usr/local/musl/${ARCH}" \
        --enable-static --disable-shared \
        --disable-minidebuginfo \
        --disable-tests --disable-documentation; \
      make -j"$(nproc)"; \
      make install; \
    done; \
    rm -rf /tmp/lu /tmp/libunwind.tar.gz
# Verify rather than assume: the archive must exist for both arches AND
# actually define unw_backtrace, which is the single symbol jemalloc needs.
# An archive that builds but does not export it would fail at link time in a
# consumer, which is exactly the class of failure this whole change exists to
# stop happening downstream.
RUN set -eux; \
    for ARCH in x86_64 aarch64; do \
      test -f "/usr/local/musl/${ARCH}/lib/libunwind.a"; \
      nm --print-armap "/usr/local/musl/${ARCH}/lib/libunwind.a" \
        | grep -q "^unw_backtrace in " \
        || { echo "libunwind for ${ARCH} does not define unw_backtrace"; exit 1; }; \
    done; \
    echo "libunwind: musl x86_64 + aarch64 provide unw_backtrace"

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
#
# This binary is the ONLY copy consumers resolve: repo buf.gen.yaml files declare
# `local: protoc-gen-connect-openapi`, which buf looks up on PATH. The version
# baked here is therefore the version that generates every OpenAPI artifact in
# the fleet — keep it in step with the pin ci-workflows' install-buf-plugins
# asserts, or that composite fails the job with a rebake instruction.
#
# `go install` at a pinned version authenticates the module against the Go
# checksum database (sum.golang.org) before building, so no hand-rolled sha256
# of a release tarball is needed on this path.
#
# Assert the built binary reports the pinned version. The previous form ended in
# `|| echo "...version flag may vary"`, which swallowed EVERY failure on this
# line — a missing binary or a wrong version still shipped a green image.
# Reported format: "protoc-gen-connect-openapi v0.25.6 (none) @ unknown; go1.x".
ENV GOBIN=/usr/local/bin
RUN set -eux; \
    go install \
      "github.com/sudorandom/protoc-gen-connect-openapi@${PROTOC_GEN_CONNECT_OPENAPI_VERSION}"; \
    reported="$(protoc-gen-connect-openapi --version 2>&1 | head -1)"; \
    if ! printf '%s\n' "${reported}" \
         | grep -qwF -- "${PROTOC_GEN_CONNECT_OPENAPI_VERSION}"; then \
      echo "protoc-gen-connect-openapi: expected ${PROTOC_GEN_CONNECT_OPENAPI_VERSION}, got '${reported}'" >&2; \
      exit 1; \
    fi; \
    echo "protoc-gen-connect-openapi ${PROTOC_GEN_CONNECT_OPENAPI_VERSION} at $(command -v protoc-gen-connect-openapi)"

# ── Labels ────────────────────────────────────────────────────────────────────
LABEL org.opencontainers.image.title="ci-base" \
      org.opencontainers.image.description="Base CI image — Node, Java, openapi-generator, kubectl, helm, k3d, nats, buf" \
      org.opencontainers.image.source="https://github.com/brefwiz/shared-ci-workflows"

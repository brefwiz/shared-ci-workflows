#!/usr/bin/env bash
# smoke-ci-images.sh — assert a built ci-base/ci image is actually usable,
# not just that `docker build` exited 0.
#
# A build that exits 0 proves the layers assembled. It does not prove a
# binary landed on PATH, is executable on the arch it was built for, or
# reports the version the Dockerfile pins -- a wrong tarball URL for one
# arch, or an install step that silently no-ops, still produces a "clean"
# build. This runs each pinned tool inside the built image and checks the
# reported version against the ARG default in the Dockerfile that built it,
# so drift between "pinned" and "shipped" fails here instead of in a
# consumer's cold-start Pod.
#
# Versions are read from the Dockerfile at runtime (never duplicated as
# literals here) so this script cannot go stale against a version bump the
# way a hardcoded expectation list would.
#
# Usage:
#   smoke-ci-images.sh <image> base   # docker/ci-base.Dockerfile
#   smoke-ci-images.sh <image> full   # docker/ci.Dockerfile (extends ci-base)

set -euo pipefail

IMAGE="${1:?usage: smoke-ci-images.sh <image> <base|full>}"
KIND="${2:?usage: smoke-ci-images.sh <image> <base|full>}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
BASE_DOCKERFILE="${SCRIPT_DIR}/../docker/ci-base.Dockerfile"
CI_DOCKERFILE="${SCRIPT_DIR}/../docker/ci.Dockerfile"

FAILED=0

# Reads an ARG's default out of a Dockerfile. Takes the first declaration
# only (the pre-FROM one) since a bare re-declaration after FROM has no `=`
# and would otherwise clobber this with an empty string.
dockerfile_arg() {
  grep -m1 -E "^ARG $1=" "$2" | cut -d= -f2- || true
}

run_in_image() {
  docker run --rm --entrypoint sh "$IMAGE" -c "$1" 2>&1
}

# assert_contains LABEL COMMAND EXPECTED_SUBSTRING
# EXPECTED_SUBSTRING empty => the tool isn't pinned via an ARG in the
# Dockerfile (e.g. apt-installed with no version pin); only assert the
# command runs and prints something.
assert_contains() {
  local label="$1" cmd="$2" expected="$3" reported
  if ! reported="$(run_in_image "$cmd")"; then
    echo "SMOKE FAIL (${label}): command failed: ${cmd}" >&2
    echo "${reported}" >&2
    FAILED=1
    return
  fi
  if [ -z "${reported// /}" ]; then
    echo "SMOKE FAIL (${label}): empty output from: ${cmd}" >&2
    FAILED=1
    return
  fi
  if [ -n "$expected" ] && ! printf '%s\n' "$reported" | grep -qF -- "$expected"; then
    echo "SMOKE FAIL (${label}): expected to find '${expected}', got:" >&2
    echo "${reported}" >&2
    FAILED=1
    return
  fi
  echo "SMOKE OK (${label}): $(printf '%s' "$reported" | head -1)"
}

case "$KIND" in
  base)
    node_major="$(dockerfile_arg NODE_MAJOR "$BASE_DOCKERFILE")"
    pnpm_version="$(dockerfile_arg PNPM_VERSION "$BASE_DOCKERFILE")"
    zig_version="$(dockerfile_arg ZIG_VERSION "$BASE_DOCKERFILE")"
    openapi_gen_version="$(dockerfile_arg OPENAPI_GENERATOR_VERSION "$BASE_DOCKERFILE")"
    kubectl_version="$(dockerfile_arg KUBECTL_VERSION "$BASE_DOCKERFILE")"
    helm_version="$(dockerfile_arg HELM_VERSION "$BASE_DOCKERFILE")"
    helmfile_version="$(dockerfile_arg HELMFILE_VERSION "$BASE_DOCKERFILE")"
    nats_version="$(dockerfile_arg NATS_VERSION "$BASE_DOCKERFILE")"
    buf_version="$(dockerfile_arg BUF_VERSION "$BASE_DOCKERFILE")"
    gitleaks_version="$(dockerfile_arg GITLEAKS_VERSION "$BASE_DOCKERFILE")"
    osv_version="$(dockerfile_arg OSV_SCANNER_VERSION "$BASE_DOCKERFILE")"
    typescript_version="$(dockerfile_arg TYPESCRIPT_VERSION "$BASE_DOCKERFILE")"
    jscpd_version="$(dockerfile_arg JSCPD_VERSION "$BASE_DOCKERFILE")"
    go_version="$(dockerfile_arg GO_VERSION "$BASE_DOCKERFILE")"

    assert_contains node          "node --version"                       "v${node_major}"
    assert_contains pnpm          "pnpm --version"                       "${pnpm_version}"
    assert_contains zig           "zig version"                          "${zig_version}"
    assert_contains openapi-generator "openapi-generator version"        "${openapi_gen_version}"
    assert_contains kubectl       "kubectl version --client"             "${kubectl_version}"
    assert_contains helm          "helm version"                         "${helm_version}"
    assert_contains helmfile      "helmfile --version"                   "${helmfile_version}"
    assert_contains nats-server   "nats-server --version"                "${nats_version}"
    assert_contains buf           "buf --version"                        "${buf_version}"
    assert_contains gitleaks      "gitleaks version"                     "${gitleaks_version#v}"
    assert_contains osv-scanner   "osv-scanner --version"                "${osv_version#v}"
    assert_contains tsc           "tsc --version"                        "${typescript_version}"
    assert_contains jscpd         "jscpd --version"                      "${jscpd_version}"
    # GO_VERSION only exists once the pinned-tarball Go lands (replacing the
    # apt golang-go package); until then this only proves `go` is on PATH.
    assert_contains go            "go version"                           "${go_version:+go${go_version}}"
    assert_contains python3       "python3 --version"                    ""
    assert_contains docker-cli    "docker --version"                     ""
    assert_contains protoc-gen-connect-openapi "protoc-gen-connect-openapi --version" \
      "$(dockerfile_arg PROTOC_GEN_CONNECT_OPENAPI_VERSION "$BASE_DOCKERFILE")"
    ;;
  full)
    rust_version="$(dockerfile_arg RUST_VERSION "$CI_DOCKERFILE")"
    nextest_version="$(dockerfile_arg CARGO_NEXTEST_VERSION "$CI_DOCKERFILE")"
    llvm_cov_version="$(dockerfile_arg CARGO_LLVM_COV_VERSION "$CI_DOCKERFILE")"
    sqlx_version="$(dockerfile_arg SQLX_CLI_VERSION "$CI_DOCKERFILE")"
    cargo_deny_version="$(dockerfile_arg CARGO_DENY_VERSION "$CI_DOCKERFILE")"
    cargo_hack_version="$(dockerfile_arg CARGO_HACK_VERSION "$CI_DOCKERFILE")"
    sccache_version="$(dockerfile_arg SCCACHE_VERSION "$CI_DOCKERFILE")"
    wasm_pack_version="$(dockerfile_arg WASM_PACK_VERSION "$CI_DOCKERFILE")"
    release_plz_version="$(dockerfile_arg RELEASE_PLZ_VERSION "$CI_DOCKERFILE")"
    cosign_version="$(dockerfile_arg COSIGN_VERSION "$CI_DOCKERFILE")"
    syft_version="$(dockerfile_arg SYFT_VERSION "$CI_DOCKERFILE")"

    assert_contains rustc         "rustc --version"                      "${rust_version}"
    assert_contains cargo         "cargo --version"                      "${rust_version}"
    assert_contains cargo-nextest "cargo nextest --version"              "${nextest_version}"
    assert_contains cargo-llvm-cov "cargo llvm-cov --version"            "${llvm_cov_version}"
    assert_contains sqlx-cli      "sqlx --version"                       "${sqlx_version}"
    assert_contains cargo-deny    "cargo deny --version"                 "${cargo_deny_version}"
    assert_contains cargo-hack    "cargo hack --version"                 "${cargo_hack_version}"
    assert_contains sccache       "sccache --version"                    "${sccache_version}"
    assert_contains wasm-pack     "wasm-pack --version"                  "${wasm_pack_version}"
    assert_contains release-plz   "release-plz --version"                "${release_plz_version}"
    assert_contains cosign        "cosign version"                       "${cosign_version}"
    assert_contains syft          "syft version"                        "${syft_version}"
    assert_contains cargo-audit   "cargo audit --version"                ""
    assert_contains api-bones-sdk-gen "api-bones-sdk-gen --version"      ""
    # ci extends ci-base: prove the base layer's tools are still reachable
    # through the full image, not just that the Rust layer landed on top.
    assert_contains node-via-ci   "node --version"                       ""
    assert_contains kubectl-via-ci "kubectl version --client"            ""
    ;;
  *)
    echo "unknown kind: ${KIND} (expected 'base' or 'full')" >&2
    exit 2
    ;;
esac

if [ "$FAILED" -ne 0 ]; then
  echo "one or more smoke assertions failed for ${IMAGE} (${KIND})" >&2
  exit 1
fi

echo "smoke-ci-images: all assertions passed for ${IMAGE} (${KIND})"

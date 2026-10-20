#!/usr/bin/env bash
# Build both images in the local daemon so ci consumes the base built here.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

docker build \
  -f docker/ci-base.Dockerfile \
  -t ci-base:pr-validate \
  .
scripts/smoke-ci-images.sh ci-base:pr-validate base

docker build \
  -f docker/ci.Dockerfile \
  --build-arg CI_BASE_IMAGE=ci-base \
  --build-arg CI_BASE_TAG=pr-validate \
  -t ci:pr-validate \
  .
scripts/smoke-ci-images.sh ci:pr-validate full

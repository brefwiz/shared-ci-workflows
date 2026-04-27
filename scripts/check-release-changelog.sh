#!/usr/bin/env bash
# check-release-changelog.sh — verify the current package version has a
# matching entry in CHANGELOG.md.
#
# Triggered every time `make ci-lint` (or `make pre-commit`) runs, so any PR
# that bumps the package version without a corresponding CHANGELOG entry
# fails CI before merge — preventing release pipelines from breaking
# post-merge with "Version X.Y.Z not found in CHANGELOG.md".
#
# Detects Rust (Cargo.toml), Node (package.json), or Python (pyproject.toml)
# and looks for any of these CHANGELOG heading shapes:
#   ## [VERSION] — YYYY-MM-DD
#   ## [VERSION]
#   ## VERSION
#   ## v[VERSION]
#   ## vVERSION
#
# Usage:
#   check-release-changelog.sh [--changelog path] [--manifest path] [--allow-unreleased]
#
#   --allow-unreleased   Pass if there's an `## [Unreleased]` heading and
#                        the manifest version equals the most recent
#                        released entry (i.e. you haven't bumped yet).

set -euo pipefail

CHANGELOG="CHANGELOG.md"
MANIFEST=""
ALLOW_UNRELEASED="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --changelog)         CHANGELOG="$2"; shift 2 ;;
    --manifest)          MANIFEST="$2";  shift 2 ;;
    --allow-unreleased)  ALLOW_UNRELEASED="true"; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$MANIFEST" ]]; then
  for candidate in Cargo.toml package.json pyproject.toml; do
    [[ -f "$candidate" ]] && { MANIFEST="$candidate"; break; }
  done
fi

if [[ -z "$MANIFEST" || ! -f "$MANIFEST" ]]; then
  echo "::warning::changelog check: no Cargo.toml/package.json/pyproject.toml found — skipping" >&2
  exit 0
fi

case "$MANIFEST" in
  *Cargo.toml)
    # Match either [package] or [workspace.package] section.
    VERSION="$(awk '
      /^\[package\]/        { in_pkg = 1; next }
      /^\[workspace\.package\]/ { in_ws = 1;  next }
      /^\[/                 { in_pkg = 0; in_ws = 0 }
      (in_pkg || in_ws) && $1 == "version" {
        gsub(/[" ]/, "", $3)
        print $3
        exit
      }' "$MANIFEST")"
    [[ -z "$VERSION" ]] && VERSION="$(grep -m1 '^version' "$MANIFEST" | sed -E 's/.*"([^"]+)".*/\1/')"
    ;;
  *package.json)
    VERSION="$(grep -m1 '"version"' "$MANIFEST" | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
    ;;
  *pyproject.toml)
    VERSION="$(grep -m1 '^version' "$MANIFEST" | sed -E 's/.*"([^"]+)".*/\1/')"
    ;;
esac

if [[ -z "$VERSION" ]]; then
  echo "::error::changelog check: cannot extract version from $MANIFEST" >&2
  exit 2
fi

if [[ ! -f "$CHANGELOG" ]]; then
  echo "::error::changelog check: $CHANGELOG not found" >&2
  echo "This repo has a versioned manifest ($MANIFEST = $VERSION) but no CHANGELOG.md." >&2
  exit 1
fi

ESCAPED="${VERSION//./\\.}"
PATTERN="^##[[:space:]]+(\[v?${ESCAPED}\]|v?${ESCAPED})([[:space:]]|$)"

if grep -qE "$PATTERN" "$CHANGELOG"; then
  echo "changelog check: $CHANGELOG has entry for version $VERSION ✓"
  exit 0
fi

if [[ "$ALLOW_UNRELEASED" == "true" ]] && grep -qE '^##[[:space:]]+\[?[Uu]nreleased\]?' "$CHANGELOG"; then
  echo "changelog check: no entry for $VERSION but [Unreleased] present — allowed"
  exit 0
fi

cat >&2 <<EOF
::error::changelog check: no entry for version $VERSION in $CHANGELOG

The package version in $MANIFEST is $VERSION but $CHANGELOG has no
corresponding heading. Add an entry like one of these (and commit it in
the same PR as the version bump):

  ## [$VERSION] — $(date -u +%Y-%m-%d)

      ### Added / Changed / Fixed
      - …

This check catches version/changelog drift at lint time so release
pipelines don't fail post-merge.
EOF
exit 1

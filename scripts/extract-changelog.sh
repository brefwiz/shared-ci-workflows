#!/usr/bin/env bash
# Extract the body of a CHANGELOG.md section for a given version.
#
# Usage: extract-changelog.sh <VERSION> [CHANGELOG_PATH]
#   VERSION        — bare version string, e.g. "4.0.0" (no leading "v")
#   CHANGELOG_PATH — path to CHANGELOG.md (default: CHANGELOG.md)
#
# Outputs the section body (between the version heading and the next
# version heading) to stdout.  Exits 1 if the version is not found.
#
# CHANGELOG format expected (Keep a Changelog):
#   ## [4.0.0] - 2026-04-20
#   ...body...
#   ## [3.1.0] - ...

set -euo pipefail

VERSION="${1:?Usage: $0 <VERSION> [CHANGELOG_PATH]}"
FILE="${2:-CHANGELOG.md}"

if [ ! -f "$FILE" ]; then
  echo "CHANGELOG not found: $FILE" >&2
  exit 1
fi

# Escape dots so they match literally in awk regex
VERSION_ESC="${VERSION//./\\.}"

BODY=$(awk \
  "/^## \\[${VERSION_ESC}\\]/{found=1; next} found && /^## \\[/{exit} found" \
  "$FILE")

if [ -z "$BODY" ]; then
  echo "Version ${VERSION} not found in ${FILE}" >&2
  exit 1
fi

echo "$BODY"

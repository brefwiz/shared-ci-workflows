#!/usr/bin/env bash
# check-makefile-contract.sh — verify a repo's Makefile implements the
# unified contract used by brefwiz reusable CI workflows.
#
# Required targets:
#   help, fmt, ci-format, ci-lint, ci-test, ci-coverage, pre-commit
#
# Usage:
#   check-makefile-contract.sh [--makefile path/to/Makefile] [--strict-pre-commit]
#
#   --strict-pre-commit  Also verify pre-commit chains ci-format ci-lint ci-test
#                        as prerequisites.

set -euo pipefail

MAKEFILE="Makefile"
STRICT_PRE_COMMIT="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --makefile)            MAKEFILE="$2"; shift 2 ;;
    --strict-pre-commit)   STRICT_PRE_COMMIT="true"; shift ;;
    -h|--help)
      sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

REQUIRED_TARGETS=(help fmt ci-format ci-lint ci-test ci-coverage pre-commit)

if [[ ! -f "$MAKEFILE" ]]; then
  echo "::error::Makefile contract: $MAKEFILE not found." >&2
  echo "Every repo using these reusable workflows must expose a Makefile with the unified contract targets." >&2
  exit 1
fi

# Match a target on a Makefile line, accounting for multi-target declarations
# like "fmt format: ## ...". Awk splits on ':' once, then on whitespace.
target_declared() {
  local target="$1" makefile="$2"
  awk -v t="$target" '
    /^[A-Za-z_][A-Za-z0-9_.-]*([[:space:]]+[A-Za-z_][A-Za-z0-9_.-]*)*[[:space:]]*:/ {
      head = $0
      sub(/:.*/, "", head)
      n = split(head, names, /[[:space:]]+/)
      for (i = 1; i <= n; i++) if (names[i] == t) { print "yes"; exit }
    }
  ' "$makefile" | grep -q yes
}

MISSING=()
for t in "${REQUIRED_TARGETS[@]}"; do
  if ! target_declared "$t" "$MAKEFILE"; then
    MISSING+=("$t")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "::error::Makefile contract: missing required targets" >&2
  for t in "${MISSING[@]}"; do echo "  - $t" >&2; done
  echo >&2
  echo "Required: ${REQUIRED_TARGETS[*]}" >&2
  exit 1
fi

if [[ "$STRICT_PRE_COMMIT" == "true" ]]; then
  PRE_COMMIT_LINE="$(grep -E '^pre-commit:' "$MAKEFILE" | head -1)"
  for prereq in ci-format ci-lint ci-test; do
    if ! echo "$PRE_COMMIT_LINE" | grep -qw "$prereq"; then
      echo "::error::Makefile contract: pre-commit must depend on '$prereq' (found: $PRE_COMMIT_LINE)" >&2
      exit 1
    fi
  done
fi

echo "Makefile contract OK (${REQUIRED_TARGETS[*]})"

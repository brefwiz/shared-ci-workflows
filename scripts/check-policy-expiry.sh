#!/usr/bin/env bash
# Enforce the 90-day review contract on policies/audit.toml + policies/deny.toml.
#
# Neither cargo-audit nor the cargo-deny version in ci-base supports a native
# expiry field, so we enforce it here. Every ignored RUSTSEC id in either file
# must be preceded by `# review-by: YYYY-MM-DD` (within 3 lines above). CI
# fails when any is past due; entries within 30 days of expiry warn (nonfatal).
#!/usr/bin/env bash
set -euo pipefail

AUDIT="${1:-policies/audit.toml}"
DENY="${2:-policies/deny.toml}"

[[ -f "$AUDIT" ]] || { echo "missing: $AUDIT"; exit 1; }
[[ -f "$DENY" ]]  || { echo "missing: $DENY"; exit 1; }

TODAY=$(date -u +%Y-%m-%d)
WARN_SEC=$(( 30 * 86400 ))
today_epoch=$(date -u -d "$TODAY" +%s 2>/dev/null || date -u -j -f %Y-%m-%d "$TODAY" +%s)

FAIL=0
WARN=0

check_entries() {
  local file="$1"
  local mode="$2"

  awk '
    function reset_meta() {
      review=""; reason=""; risk=""; impact=""; tracking=""; owner="";
      last_line=0;
    }

    BEGIN { reset_meta() }

    {
      if ($0 ~ /# *review-by: *[0-9]{4}-[0-9]{2}-[0-9]{2}/) {
        match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2}/);
        review = substr($0, RSTART, RLENGTH); last_line = NR;
      }
      if ($0 ~ /# *reason:/)   { reason=1; last_line=NR }
      if ($0 ~ /# *risk:/)     { risk=1; last_line=NR }
      if ($0 ~ /# *impact:/)   { impact=1; last_line=NR }
      if ($0 ~ /# *tracking:/) { tracking=1; last_line=NR }
      if ($0 ~ /# *owner:/)    { owner=1; last_line=NR }

      if ($0 ~ /RUSTSEC-[0-9]{4}-[0-9]+/) {
        match($0, /RUSTSEC-[0-9]{4}-[0-9]+/);
        id = substr($0, RSTART, RLENGTH);

        missing=""
        if (review == "" || NR - last_line > 5) missing = missing " review-by"
        if (!reason)   missing = missing " reason"
        if (!risk)     missing = missing " risk"
        if (!impact)   missing = missing " impact"
        if (!tracking) missing = missing " tracking"
        if (!owner)    missing = missing " owner"

        if (missing != "") {
          print "MISSING\t" id "\t" review "\t" missing
        } else {
          print "OK\t" id "\t" review "\t"
        }

        reset_meta()
      }
    }
  ' "$file"
}

process_results() {
  local entries="$1"

  while IFS=$'\t' read -r status id review missing; do
    [[ -z "$status" ]] && continue

    case "$status" in
      MISSING)
        echo "  ✗ $id — missing fields:$missing"
        FAIL=1
        ;;
      OK)
        rev_epoch=$(date -u -d "$review" +%s 2>/dev/null || date -u -j -f %Y-%m-%d "$review" +%s)
        delta=$(( rev_epoch - today_epoch ))

        if (( delta < 0 )); then
          echo "  ✗ $id — review-by $review is PAST DUE"
          FAIL=1
        elif (( delta < WARN_SEC )); then
          days=$(( delta / 86400 ))
          echo "  ⚠ $id — review-by $review (expires in ${days}d)"
          WARN=1
        else
          echo "  ✓ $id — review-by $review"
        fi
        ;;
    esac
  done < <(printf '%s\n' "$entries")
}

echo "==> Checking $AUDIT..."
AUDIT_ENTRIES=$(check_entries "$AUDIT" "audit")
[[ -z "$AUDIT_ENTRIES" ]] && echo "  (no RUSTSEC ignore entries)"
process_results "$AUDIT_ENTRIES"

echo "==> Checking $DENY..."
DENY_ENTRIES=$(check_entries "$DENY" "deny")
[[ -z "$DENY_ENTRIES" ]] && echo "  (no RUSTSEC ignore entries)"
process_results "$DENY_ENTRIES"

if [[ "$FAIL" != "0" ]]; then
  echo ""
  echo "FAIL: policy review contract violated."
  exit 1
fi

if [[ "$WARN" != "0" ]]; then
  echo ""
  echo "NOTE: one or more entries expire within 30 days — schedule review."
fi

echo "==> Policy expiry check OK"

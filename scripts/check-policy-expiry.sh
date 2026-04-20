#!/usr/bin/env bash
# Enforce the 90-day review contract on policies/audit.toml + policies/deny.toml.
#
# Neither cargo-audit nor the cargo-deny version in ci-base supports a native
# expiry field, so we enforce it here. Every ignored RUSTSEC id in either file
# must be preceded by `# review-by: YYYY-MM-DD` (within 3 lines above). CI
# fails when any is past due; entries within 30 days of expiry warn (nonfatal).

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

# Extract "STATUS<TAB>ID<TAB>REVIEW_DATE" lines from audit.toml via awk.
ENTRIES=$(awk '
  /# *review-by: *[0-9]{4}-[0-9]{2}-[0-9]{2}/ {
    match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2}/);
    last_review = substr($0, RSTART, RLENGTH); last_line = NR;
  }
  /"RUSTSEC-[0-9]{4}-[0-9]+"/ {
    match($0, /RUSTSEC-[0-9]{4}-[0-9]+/);
    id = substr($0, RSTART, RLENGTH);
    if (last_review == "" || NR - last_line > 3) {
      print "MISSING\t" id "\t";
    } else {
      print "OK\t" id "\t" last_review;
    }
  }
' "$AUDIT")

echo "==> Checking $AUDIT..."
if [[ -z "$ENTRIES" ]]; then
  echo "  (no RUSTSEC ignore entries)"
fi
while IFS=$'\t' read -r status id review; do
  [[ -z "$status" ]] && continue
  case "$status" in
    MISSING)
      echo "  ✗ $id — no '# review-by: YYYY-MM-DD' within 3 lines above"
      FAIL=1
      ;;
    OK)
      rev_epoch=$(date -u -d "$review" +%s 2>/dev/null || date -u -j -f %Y-%m-%d "$review" +%s)
      delta=$(( rev_epoch - today_epoch ))
      if (( delta < 0 )); then
        echo "  ✗ $id — review-by $review is PAST DUE (re-review, bump +90d, or remove)"
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
done < <(printf '%s\n' "$ENTRIES")

# deny.toml: same contract as audit.toml — every [advisories.ignore] entry
# must be preceded by `# review-by: YYYY-MM-DD` within 3 lines.
echo "==> Checking $DENY..."
DENY_ENTRIES=$(awk '
  /^\[advisories\]/ {in_adv=1; next}
  /^\[/ && !/advisories/ {in_adv=0}
  /# *review-by: *[0-9]{4}-[0-9]{2}-[0-9]{2}/ {
    match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2}/);
    last_review = substr($0, RSTART, RLENGTH); last_line = NR;
  }
  in_adv && /id *= *"RUSTSEC-/ {
    match($0, /RUSTSEC-[0-9]{4}-[0-9]+/);
    id = substr($0, RSTART, RLENGTH);
    if (last_review == "" || NR - last_line > 3) {
      print "MISSING\t" id "\t";
    } else {
      print "OK\t" id "\t" last_review;
    }
  }
' "$DENY")

if [[ -z "$DENY_ENTRIES" ]]; then
  echo "  (no RUSTSEC ignore entries)"
fi
while IFS=$'\t' read -r status id review; do
  [[ -z "$status" ]] && continue
  case "$status" in
    MISSING)
      echo "  ✗ $id — no '# review-by: YYYY-MM-DD' within 3 lines above"
      FAIL=1
      ;;
    OK)
      rev_epoch=$(date -u -d "$review" +%s 2>/dev/null || date -u -j -f %Y-%m-%d "$review" +%s)
      delta=$(( rev_epoch - today_epoch ))
      if (( delta < 0 )); then
        echo "  ✗ $id — review-by $review is PAST DUE (re-review, bump +90d, or remove)"
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
done < <(printf '%s\n' "$DENY_ENTRIES")

if [[ "$FAIL" != "0" ]]; then
  echo ""
  echo "FAIL: policy review contract violated. See policies/README.md."
  exit 1
fi

if [[ "$WARN" != "0" ]]; then
  echo ""
  echo "NOTE: one or more entries expire within 30 days — schedule review."
fi

echo "==> Policy expiry check OK"

# Central security policies

One place for every brefwiz Rust repo's cargo-deny and cargo-audit config.
Adding an exception here applies to all 14+ repos at once — and expires on
a schedule that forces re-review.

## Files

| File | Purpose |
|---|---|
| [`deny.toml`](deny.toml) | License allowlist, ban rules, registry allowlist, advisory ignore list. `# review-by:` comments enforced by [`../scripts/check-policy-expiry.sh`](../scripts/check-policy-expiry.sh). |
| [`audit.toml`](audit.toml) | cargo-audit advisory ignore list. `# review-by:` comments enforced by [`../scripts/check-policy-expiry.sh`](../scripts/check-policy-expiry.sh). |

## The quarterly review contract

**Every allowlist entry expires 90 days after it is added or last re-reviewed.**
After expiry, CI fails across every repo until the entry is removed or re-validated.

- `deny.toml` and `audit.toml` — immediately above each ignored RUSTSEC id,
  add `# review-by: YYYY-MM-DD`. `check-policy-expiry.sh` fails the pipeline
  once today > review-by, and warns at <30 days to give time to triage.

## Adding an exception

1. File a ticket describing the advisory, exposure, and mitigation.
2. Open a PR against `brefwiz/ci-workflows` adding the entry with a 90-day
   expiry. Link the ticket in `reason` / comment.
3. Merge triggers every downstream repo's next CI run to pick it up.

## Re-reviewing an exception

Before expiry: open a PR bumping `review-by` by 90 days, linking
the ticket that confirms the exposure is still understood.

If you can remove the exception instead — do that and close the ticket.

## Downstream opt-out

A repo can ship its own `deny.toml` at the repo root and set
`use-central-policies: false` in its `rust-ci.yml` caller. Use sparingly;
every opt-out is drift.

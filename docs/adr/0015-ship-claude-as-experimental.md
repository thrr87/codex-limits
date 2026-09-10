# Ship Claude Code as experimental

Date: 2026-09-10

Status: Accepted

## Decision

The product owner explicitly requested release 0.3.0 with Claude Code treated as experimental and waived the eligible Pro/Max account observation requirement. Claude Code is not installed on the release operator's Mac, so no live Claude allowance observation is claimed.

Claude Code remains opt-in and is labelled `Experimental` in Settings and its detail header. Its setup consent, eligible-plan explanation, bounded relay, private storage, exact setup removal, and deterministic tests remain required. Grok retains its separate `Beta` label and live source evidence.

The eligible-account check is recorded as `Waived`, not `Passed`, and no longer blocks the release validator.

The product owner also explicitly waived the expanded all-enabled idle comparison and eight-hour mixed lifecycle soak for release 0.3.0 on 2026-09-10. Neither test was performed. Their PRD rows are `Waived for 0.3.0`; the validator accepts that exact release exception and rejects it for another version. CI, deterministic lifecycle tests, native QA, universal packaging, and update-signature validation remain required.

## Consequence

Release notes identify Claude Code as experimental and state that the real Pro/Max allowance path has not been verified. A later consenting tester can supply that evidence before the experimental label is removed.

The release records that expanded idle overhead and eight-hour lifecycle stability are unverified. This acceptance does not claim either performance budget passed.

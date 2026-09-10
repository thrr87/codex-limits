# Ship Claude Code as experimental

Date: 2026-09-10

Status: Accepted

## Decision

The product owner explicitly requested release 0.3.0 with Claude Code treated as experimental and waived the eligible Pro/Max account observation requirement. Claude Code is not installed on the release operator's Mac, so no live Claude allowance observation is claimed.

Claude Code remains opt-in and is labelled `Experimental` in Settings and its detail header. Its setup consent, eligible-plan explanation, bounded relay, private storage, exact setup removal, and deterministic tests remain required. Grok retains its separate `Beta` label and live source evidence.

The eligible-account check is recorded as `Waived`, not `Passed`, and no longer blocks the release validator. The idle comparison and lifecycle soak remain separate requirements; this decision does not waive them.

## Consequence

Release notes identify Claude Code as experimental and state that the real Pro/Max allowance path has not been verified. A later consenting tester can supply that evidence before the experimental label is removed.

# Measurement contract

This contract defines how Codex Limits labels facts, Coverage, Confidence, and comparable work. It applies to the reader snapshot, charts, Facts, Insights, tooltips, notifications, and tests.

The product prefers no estimate to a weak estimate.

## Source classes

Every value has one source class:

1. **Account fact** — returned by the Codex account API.
2. **Local fact** — observed in Codex records on this Mac.
3. **Derived estimate** — calculated from named account and local facts.

The UI never merges these classes into one unexplained value.

## Primary allowance

The weekly Codex allowance is the primary allowance.

- Select the Codex window whose `windowDurationMins` is `10080`.
- Show its Usage remaining in the menu bar, current-state header, Runway, Suggested Pace, and default Usage remaining chart.
- Do not replace it with a five-hour window because that window has a lower percentage.
- Show five-hour and model-specific windows as Other limits in Facts.
- If no weekly window is returned, show `Weekly usage unavailable`. Do not substitute another window without naming it.

Every allowance-derived metric carries the selected limit ID, duration, start, and reset time.

## Account Token Activity

Account Token Activity is the primary weekly token total. Use the strongest available method in this order:

1. **Observed lifetime delta** — subtract two monotonic `summary.lifetimeTokens` readings that bound the same account and interval.
2. **Exact daily sum** — sum complete account daily buckets only when their calendar boundaries match the selected interval.
3. **Partial daily sum** — show complete daily buckets inside the interval as a factual partial value. Do not scale partial days or call the result a weekly total.
4. **Unavailable** — withhold the total when no method above applies.

An observed lifetime delta is valid only when:

- both readings belong to the same local account partition;
- the counter did not decrease;
- both interval boundaries meet the boundary rules below;
- no account change occurred between the readings.

Daily buckets may seed a historical chart, but they never become observed allowance readings.

## Account facts

Facts may show these values when the account API returns them:

- Lifetime tokens
- Peak daily tokens
- Longest running turn
- Current streak
- Longest streak
- Credits balance or unlimited credits
- Spend-control limit, Usage remaining, and reset time

These are Account facts. They do not need Confidence. They do need source, fetched time, and an unavailable state.

## Local Activity source boundary

Issue `Prove read-only Local Activity ingestion and Coverage` owns the source decision before Local Token Activity ships.

Until that spike is complete:

- do not assume that a separate app-server connection receives live events from Tasks owned by another Codex process;
- do not resume, load, start, stop, or take ownership of a user Task to observe it;
- treat supported read-only app-server projections as the preferred metadata source;
- treat incrementally tailed local Codex records as a candidate source for token, turn, tool, and timing facts;
- record source capability and CLI version with every normalized event.

If no safe read-only source exists for a fact, the fact is unavailable.

## Time boundaries

### Rolling ranges

`24 hours`, `3 days`, `4 weeks`, and `12 weeks` end at the current instant and use exact elapsed durations of 86,400, 259,200, 2,419,200, and 7,257,600 seconds. A delayed observation does not move a rolling range into the past.

### Machine-local time

Reader-facing dates and clock labels use the Mac's current time zone when rendered. A time-zone or daylight-saving change changes local labels, not the underlying elapsed interval.

An interval is:

- **Tightly bounded** when the closest account readings are no more than 15 minutes from both boundaries.
- **Loosely bounded** when both readings are no more than 60 minutes from the boundaries.
- **Unbounded** when either reading is farther away or missing.

For allowance movement:

- a gap of no more than 30 minutes between account readings supports High Coverage;
- a gap over 30 minutes and no more than 6 hours lowers Coverage to Partial;
- a gap over 6 hours makes comparable allowance movement unavailable;
- any gap that may contain an unknown reset or correction makes the interval unbounded.

A known scheduled reset, banked reset, account change, or detected correction always splits the interval.

## Coverage

Coverage says how much of the required source data was observed. It does not mean accuracy.

Reader-facing Coverage states are:

| State | Meaning |
|---|---|
| `Complete` | Every required source and boundary is present, with no known gap or ambiguity. |
| `High` | At least 80% of aligned activity is represented and every required boundary is tight. |
| `Partial` | Useful evidence exists, but coverage is between 50% and 79%, a boundary is loose, or a named source is missing. |
| `Low` | Less than 50% is represented or a material gap prevents a dependable conclusion. |
| `Unavailable` | The required source, identity, token definition, or time boundary cannot be reconciled. |
| `Not applicable` | The metric has no meaningful coverage denominator, such as an interval with no activity. |

Every state other than Complete names at least one reason, such as:

- `Account boundary is 42 minutes late`
- `Local Tasks are missing`
- `Activity from another device is possible`
- `Token definitions do not align`
- `Unknown reset or correction`
- `Codex version does not expose this field`

### Numeric Local Coverage

Numeric Local Coverage is shown only when the source spike proves that Account Token Activity and Local Token Activity use compatible token definitions for the active Codex version and both values cover the same interval.

For aligned values:

`Local Coverage = Local Token Activity / Account Token Activity`

Rules:

- When both totals are zero, Coverage is Not applicable.
- When account activity is zero but local activity is positive, numeric Coverage is unavailable.
- When local activity is more than 2% above account activity, numeric Coverage is unavailable and the UI says `Account and local totals do not align`.
- A difference of at most 2% may be treated as rounding and clamped to 100%.
- Numeric Coverage describes the share of Account Token Activity visible in local records. It does not prove that local records explain account billing.

### Reset Detail Coverage

Reset Detail Coverage uses the authoritative reset count and returned available detail:

- `Complete` when detail count equals the authoritative count.
- `Partial` when detail count is greater than zero and lower than the count.
- `Unavailable` when the count is greater than zero and no detail is returned.
- `Not applicable` when the authoritative count is zero.

## Confidence

Confidence says how strongly the observed evidence supports a derived estimate or Insight.

| State | Product behavior |
|---|---|
| `High` | Show the estimate or Insight. Coverage is Complete or High, the interval is tightly bounded, and no material comparability warning applies. |
| `Medium` | Show the estimate with its range and named caveat. The interval is still bounded and the conclusion remains useful. |
| `Low` | Withhold the estimate or Insight. Show the observed facts and the reason more evidence is needed. |
| `Unavailable` | Do not calculate the result. |

Direct Account facts and Local facts show provenance and freshness instead of artificial Confidence.

The engine, not the view, owns Confidence and its reasons. Thresholds are versioned policy values and have deterministic tests.

## Comparable work

Two intervals are comparable only when all these gates pass:

- both intervals belong to the same account partition;
- both use the weekly Codex allowance;
- both are bounded;
- neither contains a reset, account change, unknown correction, or counter decrease;
- both have non-zero Account Token Activity;
- Local Coverage is at least 50% when workload mix is part of the comparison;
- the dominant model family and reasoning level are known;
- model, reasoning, and cached-input shares differ by no more than 20 percentage points;
- the product can name every reason that lowers comparability.

Comparability is:

- **High** when Local Coverage is at least 80%, both intervals are tightly bounded, and each observed workload-mix share differs by no more than 10 percentage points.
- **Medium** when Local Coverage is at least 50%, the intervals are at least loosely bounded, and each share differs by no more than 20 percentage points.
- **Not comparable** otherwise.

Low-comparability conclusions are withheld.

## Reference Baseline

The default Reference Baseline is the median Allowance Intensity of the previous four complete, High-comparability weekly windows.

- Use exactly four eligible windows.
- If fewer than four exist, show `Not enough comparable weeks`.
- A user-pinned period must pass at least Medium comparability.
- Pinning a period does not override reset, identity, boundary, or token-definition failures.
- Store the baseline interval IDs and policy version with the derived result.

Allowance Intensity divides observed weekly Account Movement by aligned Account Token Activity. Equivalent Capacity extrapolates from that intensity and always remains an estimate.

## Account partitions

Analytics History never mixes signed-in accounts.

- Read account state before joining new observations to history.
- When an email is available, derive an on-device keyed fingerprint and never persist the email as the partition key.
- When stable identity is unavailable, start an isolated unknown-account partition after every observed auth transition.
- A plan change does not create a new partition, but it splits comparable intervals.

## Delete analytics history

`Delete analytics history` means all Analytics History owned by Codex Limits:

- all local Derived Records;
- Codex-assisted Insight results;
- Analytics Overhead records;
- account usage samples in the selected sync folder;
- records written by every installation in that sync folder.

Preferences, notification settings, and Codex source records remain.

Deletion creates a new empty sync generation so another Mac cannot republish older history. Each installation that observes the generation discards older local analytics before it publishes again.

If the selected sync folder is unavailable, the product must not claim that deletion completed. It prevents older synced records from being imported, keeps a pending deletion state, and offers retry.

The app does not rebuild deleted history automatically. A separate explicit `Rebuild available history` action may read only source data that still exists. New observations after deletion belong to the new generation.

## Codex-assisted availability

`Analyze with Codex` is visible only when `model/list` advertises:

- GPT-5.6 Luna;
- Medium reasoning for that exact model;
- an account state that can run the request.

If any condition is missing or model availability cannot be checked, hide the action. Do not fall back to GPT-5.5, Terra, Sol, another reasoning level, or the analyzed Task model.

Metadata-only Analysis uses a closed payload allowlist. Source-backed Analysis sends only the categories and scope accepted in its current preflight. The analysis Task cannot use tools, read additional files, or change the workspace.

## Reader rules

- Show the source beside a value when sources may disagree.
- Show the observed interval for every derived value.
- Show raw facts before estimates.
- Use `Not enough data` or a specific reason instead of a Low-confidence number.
- Never call Coverage accuracy.
- Never call Confidence certainty.
- Never call Account Token Activity a token allowance.
- Never call Local Coverage billing coverage.

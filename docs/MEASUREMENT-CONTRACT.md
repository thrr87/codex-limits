# Measurement contract

This contract defines how Codex Limits labels facts, Freshness, Coverage, Confidence, and comparable work across supported Integrations. It applies to the reader snapshot, charts, Facts, Insights, tooltips, notifications, and tests.

The product prefers no estimate to a weak estimate.

## Source classes

Every value has one source class:

1. **Account fact** — returned by an Integration's supported account source.
2. **Local fact** — observed in an Integration's supported local records on this Mac.
3. **Derived estimate** — calculated from named account and local facts.

The UI never merges these classes into one unexplained value.

## Integration separation

Every fact and Integration Snapshot carries its Integration ID, capability, observed time, source kind, and source version when available.

- Never add, average, rank, or otherwise combine allowance percentages from different Integrations.
- Never convert OpenCode Local Activity into Account Allowance.
- Never infer support for one Integration Capability from another capability.
- Omit an Unsupported Capability. Use unavailable only when a supported capability cannot currently produce a value.
- Keep the existing Codex analytics engine isolated from Claude Code and Grok snapshots and histories, and from any future OpenCode snapshot.

The `All` overview uses separate current-period thumbnails. Each includes only recorded account observations, the latest actual point, and a target when the period start is known. It excludes forecasts and token estimates, preserves gaps, and retains at most 256 display points. Claude/Grok overview reads cover at most 31 elapsed days (32 UTC files); detail history keeps its existing 84-day read bound. A single reading remains one point.

## Account Allowance normalization

An Integration may publish Account Allowance only when the source identifies the percentage orientation and allowance period.

- A percentage must be finite and source-valid. Missing, null, malformed, or semantically unknown values are unavailable, never zero.
- Claude Code `used_percentage` is valid only inside `0...100`; convert it to `remaining = 100 - used`. Reject an out-of-range value.
- Grok `creditUsagePercent` is a used percentage. Preserve the finite original as `reportedUsedPercent`, apply the official `0...100` clamp, and convert it to remaining. Record `measurementSource` as `creditUsagePercent` or `legacyCredits`, with the CLI version when available. Use legacy `100 * used.val / monthlyLimit.val` only when both current fields are absent; a zero or missing legacy limit is unavailable. A present empty Cent object means zero, while a missing monetary field remains unavailable. The collector sends `_x.ai/billing` on the ACP wire; the internal handler name omits the underscore.
- A valid Grok `currentPeriod` without `creditUsagePercent` is a successful partial observation: retain its period, reset, observation time, and available account facts, but leave the percentage unavailable. It replaces the latest snapshot without adding an allowance-history point or forecast. Never substitute zero, a previous period’s percentage, or legacy credits for the omitted value. A present null or malformed percentage remains an invalid response. Historic charts identify their range as the last recorded window when no current allowance observation exists; `Last received` dates the latest accepted response rather than the latest refresh attempt.
- A direct remaining percentage is validated without changing its orientation.
- Every allowance window carries its provider window ID or period type, observed time, reset time, and duration when known.
- Weekly and monthly Grok periods remain distinct. Retain a supplied `currentPeriod.start` or legacy `billingPeriodStart` only after supported finite-date and start-before-reset validation. A missing start remains absent; never invent a monthly start from a fixed duration. An unknown period type is unavailable rather than relabeled as weekly.
- A missing secondary window does not invalidate another independently valid window.
- OpenCode Local Token Activity is not Account Allowance and never passes through this normalization.

## Freshness and allowance lifetime

Freshness describes age and current source availability, not accuracy or Confidence.

The OpenCode row is a future contract. Freshness windows do not define polling schedules; Grok polls every ten minutes only while selected for the menu bar, with failure backoff and a thirty-second launch floor.

| Integration | Fresh window |
|---|---:|
| Codex | At most 15 minutes old |
| Claude Code | At most 30 minutes old |
| Grok | At most 30 minutes old |
| OpenCode | At most 15 minutes old |

Reader-facing source states are:

| State | Meaning |
|---|---|
| `Fresh` | A valid observation inside its Freshness window and, for allowance, before its known reset. |
| `Stale` | A valid observation outside its Freshness window but still before the same known reset. |
| `Expired` | A valid allowance observation whose known reset passed without a post-reset observation. Its old percentage is withheld. |
| `Unavailable` | No compatible valid observation exists. |

Claude Code always shows `Last observed` because its `statusLine` source is event-driven. When a supported source fails, retain the last valid snapshot only while it remains meaningful, show the current actionable source error, and never replace a failed or absent reading with zero. A known reset boundary takes precedence over the Freshness window: no numeric allowance crosses it.

Concurrent event-driven observations are ordered by receive time captured before parsing. Atomic persistence must not allow an older Claude relay process that finishes later to replace a newer observation.

## Claude Code and Grok allowance history

Each provider has its own Usage remaining chart backed only by recorded allowance observations. Claude's seven-day and five-hour windows are separate series; Grok's weekly and monthly periods are separate series. Every point retains its observation time, period or window, reset, source provenance, and provider-reported start when available. A cached snapshot from before history support may seed one real point at its original observation time. It never creates earlier points or a complete past period.

A source or period change, reset, or detected correction breaks a comparable interval. An increase in remaining percentage beyond the shared 0.1 percentage-point rounding tolerance is a correction. Do not connect across these breaks. Missing observations remain gaps; token activity, local sessions, costs, and monetary balances never act as allowance proxies.

A current allowance estimate requires at least two compatible observations spanning at least 60 seconds, a latest observation inside the provider's 30-minute Freshness window and before reset, and no intervening gap over 30 minutes, reset, source change, or correction. The estimate stays within the same known allowance period and is labeled as an estimate. When these gates fail, show recorded facts and the reason more observations are needed. Do not borrow Codex token-based guidance, workload comparisons, or Confidence from another Integration.

## Primary Codex allowance

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

## OpenCode Local Activity

OpenCode Local Activity is deferred from v1 because the tested supported local-server process failed the memory and initialization-write budgets. The rules below are the acceptance contract for a future supported source; they do not authorize the rejected server collector. A future source never requests messages or parts.

- The rolling seven-day interval is exactly 604,800 seconds ending now.
- Local Token Activity is the sum of finite, non-negative input, output, reasoning, cache-read, and cache-write counters only after fixtures prove these categories are disjoint cumulative values.
- A root session has no parent ID. Overview session count includes roots only; detail may show bounded descendants separately.
- Parent and child token or cost totals are not added until fixtures prove that parent totals exclude descendants.
- Repeated cumulative snapshots deduplicate by `(Integration ID, session ID)` and retain the newest compatible counter state.
- A counter decrease after compaction, fork, archive, deletion, or schema change creates a source break; do not produce a negative delta or silently join both sides.
- Missing or invalid cost is unavailable, not zero. Valid cost is labeled `OpenCode local estimated cost` and remains distinct from provider billing.
- Session provider/model describes only the currently saved session selection. It does not prove per-response or whole-session model attribution.
- Production collection remains unavailable until a supported source enforces accepted range and count bounds before returning session data and passes the process, memory, disk-write, and endurance budgets.

## Time boundaries

### Rolling ranges

`24 hours`, `3 days`, `7 days`, `4 weeks`, and `12 weeks` end at the current instant and use exact elapsed durations of 86,400, 259,200, 604,800, 2,419,200, and 7,257,600 seconds. A delayed observation does not move a rolling range into the past.

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

Claude Code and Grok snapshots and observation histories remain in separate Local Installation Partitions and are never joined or synchronized. Neither source supplies a stable account identity, so these histories describe observations on this installation and cannot establish continuity through an unobserved provider account change. Current snapshots remain bounded at 64 KiB; retained history is separate. A future OpenCode integration follows the same partition rule and keeps only the bounded rolling seven-day cache defined by the multi-integration PRD.

## Retention and Bounded Working Set

Retention describes the canonical records kept on disk. It never authorizes loading every retained record into resident memory.

- Reader snapshots contain only the current value, the selected visible range, and bounded summaries required by the visible surface.
- Ordinary refresh and periodic sync do not enumerate or decode all retained Codex history.
- A range query returns a bounded point count or a bounded aggregate resolution.
- Source detail caches are released when their capability becomes hidden.
- Claude Code and Grok retain compact provider-local allowance observations until explicit deletion. Their active history view is bounded to the latest 84 days; this bound does not delete older canonical records or authorize eager full-history reads. Disabling preserves history, and a prior latest-only snapshot seeds at most its own observation.
- The provider-local reader opens at most 85 direct UTC daily journal paths, reads at most 4 MiB per file and 32 MiB total, limits each record to 512 bytes and the decoded working set to 200,000 records, and reports a history failure for malformed committed records or exceeded bounds. It does not silently downsample. Appends are cross-process locked, contain at most 64 records, and inspect only a bounded tail for interrupted-write recovery and duplicate suppression.
- Tests compare short and multi-year fixtures and fail when resident memory or ordinary refresh time grows proportionally with retained history.
- The Codex reader working set contains at most 6,000 samples from the latest 84 days. The latest eight days remain full resolution; older data keeps the first and last sample per hourly/reset bucket plus explicit comparison breaks.
- The default 84-day working set does not redefine retained-history bounds. Selecting an older interval reads at most 84 days and returns at most 6,000 exact or explicitly downsampled samples; it never requires all retained samples to become resident. A cold default or range read considers at most 32 writer partitions, reads at most 256 daily files and 8 MiB, and exposes a partial-history issue when a bound is reached.
- A bounded Codex sync uses the durable manifest and cursor contract in ADR-0014. One periodic pass examines at most 32 calendar-day candidates and reads at most 32 daily files across all writers, prioritizes recent changes, persists its round-robin backlog position, and eventually merges every changed daily file. Truncating to the newest files without eventual backfill is forbidden. An explicit new-folder connection may do one full reconciliation outside the main actor.

## Delete non-Codex Integration data

`Delete integration data` disables the selected non-Codex Integration, cancels its source work, and removes every app-owned snapshot, retained allowance observation, Derived Record, cache, and Codex Limits-owned source configuration for that Integration. It preserves source records owned by the integrated product and does not rebuild automatically. Re-enabling the Integration explicitly starts a new local collection boundary.

## Delete analytics history

`Delete analytics history` means all Codex Analytics History owned by Codex Limits; Claude Code and Grok use their separate Integration deletion actions:

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
- Never show a pre-reset allowance percentage as current after its known reset.
- Never call an event-driven cache refresh a live account refresh.
- Never call a missing or invalid OpenCode cost zero.

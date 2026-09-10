# Reset graph root-cause research — 2026-08-06

## Executive conclusion

The apparent recurrence is not a failure of the 0.2.8 fix. The screenshot was produced by the still-running installed app at `/Applications/Codex Limits.app`, which is **version 0.2.6, build 7**. Its process started on 2026-08-05 at 13:06:47, before 0.2.8 was released, and that build has no Sparkle updater. The visible `2.8` at the screenshot edge is therefore not evidence that the running binary is 0.2.8.

The raw local history reproduces issue #67 exactly:

- reset `2026-08-08 10:13:03Z`: 607 samples, 28–100% remaining;
- reset `2026-08-08 10:13:04Z`: two samples—70% at `2026-08-02 15:47:41Z` and 29% at `2026-08-06 14:37:27Z`; and
- reset `2026-08-08 10:13:05Z`: one sample.

Version 0.2.6 groups those one-second reset variants as separate allowance windows. Step-end interpolation turns the sparse `70% -> 29%` window into the long horizontal plateau and final vertical drop visible in the screenshot.

The released 0.2.8 regression test passes against this failure mode: the variants become one allowance window. The same test fails on tag 0.2.6 with two windows instead of one. The immediate fix is therefore to quit the old process and install/launch 0.2.8, not to change history or add another graph heuristic.

The "draft usage was saved before the first real read" hypothesis is independently unsupported. Codex Limits awaits a complete `account/rateLimits/read` response before recording a sample, and current OpenAI Codex performs a real backend read rather than fabricating a percentage/reset.

## Local evidence

### Installed and running version

The installed bundle metadata is `/Applications/Codex Limits.app/Contents/Info.plist`:

```text
CFBundleShortVersionString = 0.2.6
CFBundleVersion = 7
```

`ps` identified PID `89649`, started `Wed Aug 5 13:06:47 2026`, executing `/Applications/Codex Limits.app/Contents/MacOS/CodexLimits`; `lsof` confirmed the same bundle path.

This matches the project's documented upgrade boundary: [README line 146](https://github.com/thrr87/codex-limits/blob/3de3707/README.md#L146) says versions 0.2.6 and earlier require one final manual update.

### Raw history

The inspected files are under:

```text
~/Library/Application Support/com.github.thrr87.CodexLimits/History/
  partitions/account-54d70c46ba4989e74b0c2eede6940a6c0f7b3639a51d64fe0016e6989da15911/
  installations/*/2026-08-*.json
```

Aggregation by `resetsAt` found:

| Encoded `Date` value | UTC reset | Samples | Remaining range |
|---:|---|---:|---:|
| `807876783` | 2026-08-08 10:13:03 | 607 | 28–100% |
| `807876784` | 2026-08-08 10:13:04 | 2 | 29–70% |
| `807876785` | 2026-08-08 10:13:05 | 1 | one value |

The numeric values are Swift `Date`'s JSON representation (seconds from Apple's 2001 reference date), not Unix timestamps.

The sparse `:04` series is exactly:

```text
2026-08-02T15:47:41Z  70%  reset 2026-08-08T10:13:04Z
2026-08-06T14:37:27Z  29%  reset 2026-08-08T10:13:04Z
```

With `.stepEnd`, those two points render as 70% until the second observation, then drop vertically to 29%.

### Release regression check

`UsageIntelligenceEngineTests/testResetTimeJitterDoesNotCreateASecondAllowanceWindow` passed 1/1 in the 0.2.8 release worktree. Running the equivalent test against tag 0.2.6 failed:

```text
allowanceWindows: 2 (expected 1)
observed points: 1 (expected 3)
```

This is direct evidence that the shipped fix covers the observed one-second reset split, while the currently running binary does not.

## What OpenAI Codex actually returns

Research was performed against `openai/codex` commit [`57f42a81131ccf5933e7ec5dc659c381eeb5d72b`](https://github.com/openai/codex/commit/57f42a81131ccf5933e7ec5dc659c381eeb5d72b), current on 2026-08-06.

### Snapshot schema

`RateLimitWindow` contains only consumed percentage, optional duration, and optional `resets_at`. `resets_at` is documented as Unix seconds. `RateLimitSnapshot` has no capture timestamp, device/source identifier, account identifier, or stable allowance-window instance identifier. See the [core protocol types](https://github.com/openai/codex/blob/57f42a81131ccf5933e7ec5dc659c381eeb5d72b/codex-rs/protocol/src/protocol.rs#L2156-L2212).

The app-server protocol rounds `used_percent` to an integer and passes `resets_at` through unchanged; it does not calculate a device-local reset. See the [v2 account protocol conversion](https://github.com/openai/codex/blob/57f42a81131ccf5933e7ec5dc659c381eeb5d72b/codex-rs/app-server-protocol/src/protocol/v2/account.rs#L507-L621).

The backend model actually contains both `reset_after_seconds` and absolute `reset_at`, but the Codex client forwards the backend's absolute `reset_at`; it does not reconstruct it from the local clock. See the [backend model](https://github.com/openai/codex/blob/57f42a81131ccf5933e7ec5dc659c381eeb5d72b/codex-rs/codex-backend-openapi-models/src/models/rate_limit_window_snapshot.rs#L13-L37) and [mapping into the protocol snapshot](https://github.com/openai/codex/blob/57f42a81131ccf5933e7ec5dc659c381eeb5d72b/codex-rs/backend-client/src/client.rs#L644-L656).

### Full reads are backend reads, not drafts

`account/rateLimits/read` calls `get_rate_limits_with_reset_credits`, which performs an authenticated GET against `/api/codex/usage` or `/wham/usage`. See the [backend request implementation](https://github.com/openai/codex/blob/57f42a81131ccf5933e7ec5dc659c381eeb5d72b/codex-rs/backend-client/src/client/rate_limit_resets.rs#L22-L35) and [endpoint selection](https://github.com/openai/codex/blob/57f42a81131ccf5933e7ec5dc659c381eeb5d72b/codex-rs/backend-client/src/client/rate_limit_resets.rs#L80-L85).

The app-server returns an error when ChatGPT authentication is unavailable or when the backend returns no snapshots. It has no fallback percentage/reset construction. See [`get_account_rate_limits_response`](https://github.com/openai/codex/blob/57f42a81131ccf5933e7ec5dc659c381eeb5d72b/codex-rs/app-server/src/request_processors/account_processor.rs#L1047-L1117).

The TUI's startup prefetch also invokes the same `account/rateLimits/read`; there is no fake 100% or other default window. See [background request startup](https://github.com/openai/codex/blob/57f42a81131ccf5933e7ec5dc659c381eeb5d72b/codex-rs/tui/src/app/background_requests.rs#L69-L105) and the [request itself](https://github.com/openai/codex/blob/57f42a81131ccf5933e7ec5dc659c381eeb5d72b/codex-rs/tui/src/app/background_requests.rs#L760-L770).

There is one upstream "default" nuance, but it cannot explain a 70% line: the response-header parser can produce an empty default `codex` snapshot when no rate-limit headers are present. That snapshot has no primary/secondary usage window and therefore no percentage or reset to persist. See [`parse_all_rate_limits`](https://github.com/openai/codex/blob/57f42a81131ccf5933e7ec5dc659c381eeb5d72b/codex-rs/codex-api/src/rate_limits.rs#L22-L50).

### Rolling updates are sparse

Rate-limit data can also arrive from model-response headers or websocket `codex.rate_limits` events. The parser forwards `used_percent`, duration, and absolute reset values supplied by the server; it does not synthesize timestamps. See the [header/event parser](https://github.com/openai/codex/blob/57f42a81131ccf5933e7ec5dc659c381eeb5d72b/codex-rs/codex-api/src/rate_limits.rs#L52-L176).

Official app-server documentation explicitly calls `account/rateLimits/updated` a **sparse rolling update** and tells clients to merge it into the latest full read or refetch. See the [account API overview](https://github.com/openai/codex/blob/57f42a81131ccf5933e7ec5dc659c381eeb5d72b/codex-rs/app-server/README.md#L2164-L2177) and [rate-limit field notes](https://github.com/openai/codex/blob/57f42a81131ccf5933e7ec5dc659c381eeb5d72b/codex-rs/app-server/README.md#L2300-L2341).

Codex Limits does not persist such a notification directly. During a full read it notices concurrent rate-limit/account updates, repeats the read up to two times, and fails with `updatesDidNotSettle` if state remains unstable. See [Codex Limits 0.2.8 reconciliation](https://github.com/thrr87/codex-limits/blob/3de3707/Sources/CodexLimits/CodexClient.swift#L387-L419) and [batched full reads](https://github.com/thrr87/codex-limits/blob/3de3707/Sources/CodexLimits/CodexClient.swift#L500-L529).

## Can reset values change between reads or devices?

The protocol defines `resets_at` only as the next reset timestamp. It does not promise that the value is immutable for a nominal duration bucket, and current client code replaces primary/secondary windows whenever the server supplies a new snapshot. Because the absolute timestamp is backend-owned and passed through, two Macs do not independently calculate different reset dates; they can, however, observe different backend snapshots at different times.

There is first-party confirmation of at least one legitimate reason for a reset timestamp to change: an OpenAI collaborator explained that after a global compensating reset, the next Codex use establishes a new five-hour and seven-day date ([openai/codex#13330 comment](https://github.com/openai/codex/issues/13330#issuecomment-3988712564)).

There are also unresolved public field reports in the official repository:

- [openai/codex#23190](https://github.com/openai/codex/issues/23190) records two 10,080-minute snapshots roughly two hours apart: `27% used / reset May 23`, then `99% used / reset May 18`. A later comment reports stale-looking history after resume/fork. This is very similar in shape to the current graph, but remains a user report, not an upstream root-cause determination.
- [openai/codex#23192](https://github.com/openai/codex/issues/23192) records incompatible percentages and reset timestamps between web analytics and the macOS app for the same account.
- [openai/codex#34874](https://github.com/openai/codex/issues/34874) reports a reset timestamp advancing on consecutive days without allowance replenishment. The issue explicitly labels its backend explanation as a hypothesis.

These reports prove that materially different values have been observed in real clients. They do not prove whether the source is backend window selection, caching, a special reset, or client replay.

## Why 0.2.6 draws the line and 0.2.8 does not

Issue [codex-limits#67](https://github.com/thrr87/codex-limits/issues/67) documented real synchronized history with reset values `12:13:03` and `12:13:04`. PR [#68](https://github.com/thrr87/codex-limits/pull/68) fixed exact-reset grouping by aligning reset values within 15 minutes in memory while leaving stored observations unchanged.

The 0.2.8 implementation:

1. anchors reset timestamps only when they are within `tightBoundary = 15 minutes` ([alignment policy](https://github.com/thrr87/codex-limits/blob/3de3707/Sources/CodexLimits/UsageModels.swift#L145-L176));
2. groups chart points by the aligned reset timestamp ([allowance-window grouping](https://github.com/thrr87/codex-limits/blob/3de3707/Sources/CodexLimits/UsageIntelligenceEngine.swift#L1842-L1880));
3. starts a new observed segment whenever remaining percentage rises by more than 0.1 percentage point ([segment policy](https://github.com/thrr87/codex-limits/blob/3de3707/Sources/CodexLimits/UsageModels.swift#L178-L193)); and
4. renders every segment with `.stepEnd` interpolation ([chart rendering](https://github.com/thrr87/codex-limits/blob/3de3707/Sources/CodexLimits/MenuContentView.swift#L2403-L2428)).

For the locally observed `:03`, `:04`, and `:05` reset variants, the alignment step places every sample in one allowance window. That removes the sparse second allowance series responsible for this screenshot. The focused release test confirms this behavior.

The 15-minute rule does not claim to solve every possible backend inconsistency. Reset timestamps farther apart or genuinely conflicting backend windows would require separate evidence and policy. They are not needed to explain this incident.

The history store deduplicates only exact `UsageSample` equality. Samples with a different observation time, percentage, or reset remain independent ([history normalization](https://github.com/thrr87/codex-limits/blob/3de3707/Sources/CodexLimits/UsageHistory.swift#L985-L1015)). This is intentional for preserving raw observations, but means a bad or stale reading remains visible until chart policy excludes or reconciles it.

## Startup-cache hypothesis checked against Codex Limits

On refresh, Codex Limits restores history for display, starts a live fetch, awaits the result, selects/verifies the account partition, exchanges synchronized history, and only then records the new main-window sample ([refresh flow](https://github.com/thrr87/codex-limits/blob/3de3707/Sources/CodexLimits/UsageMonitor.swift#L245-L324)).

It can display a previously persisted account snapshot during startup, but that restored snapshot is not automatically appended to history before the live read. A new 70% history point therefore needs an actual successful fetch result or an already-existing/synchronized history record; local UI initialization alone is insufficient.

## Root-cause assessment

| Hypothesis | Assessment | Evidence |
|---|---|---|
| Old 0.2.6 process renders the known one-second reset split | **Confirmed root cause** | Installed/running version is 0.2.6; raw history has `:03/:04/:05`; sparse `:04` values exactly match the plateau; the 0.2.6 test fails. |
| 0.2.8 fix does not work | **Ruled out for this data** | Focused 0.2.8 regression passes and produces one allowance window. |
| Codex Limits writes a draft/default percentage before live fetch | **Ruled out by current source** | History record occurs only after awaited fetch; upstream full read errors rather than fabricates data. |
| Conflicting full backend snapshots | **Possible upstream context, not needed for this incident** | Protocol has no immutability guarantee and public reports show conflicts, but local one-second jitter plus old binary fully explains the graph. |
| Sparse rolling update saved as a full point by Codex Limits | **Unlikely in current code** | Codex Limits observes the notification only to trigger bounded full-read reconciliation. |

## Action

Quit PID `89649`, replace `/Applications/Codex Limits.app` with the 0.2.8 release, and launch it again. Verify the running bundle reports version 0.2.8 before judging the graph. No history edit is required: 0.2.8 aligns the raw reset variants in memory and intentionally leaves persisted observations unchanged.

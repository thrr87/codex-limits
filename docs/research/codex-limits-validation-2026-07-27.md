# Codex limits after GPT‑5.6: validation, counterevidence, and shipping decisions

Date: 2026-07-27\
Observation window: 2026-07-09–2026-07-27\
Companion to: [codex-limits-user-research-2026-07-27.md](./codex-limits-user-research-2026-07-27.md)\
Product: `codex-limits`

## Executive verdict

The validation pass supports a focused product, not a general-purpose token dashboard.

The strongest opportunities are:

1. **Prevent a banked reset from expiring unnoticed.**
2. **Say whether the observed allowance is likely to last until its reset.**
3. **Keep history and forecasts correct across scheduled, banked, and unexplained reset events.**
4. **Explain which numbers are backend facts, local observations, or estimates.**

The strongest diagnostic opportunity is a later, explicitly local view of model, reasoning, thread, subagent, context, cache, compaction, and tool-loop activity. It addresses real user questions, but local rollout tokens cannot be presented as an explanation of OpenAI's subscription ledger.

| Idea | Confidence | Decision | Short rationale |
|---|---:|---|---|
| Banked-reset count and exact next known expiry | High | **Ship** | Repeated losses and confusion; count is authoritative and returned expiry rows are backend facts. |
| One opt-in expiry reminder | High | **Ship** | Clear user harm, technically simple local notification, consistent with Apple guidance when sparse and permissioned. |
| Time-to-empty / will-it-last forecast | High | **Ship** | Users repeatedly ask this decision; backend percentage history supports an estimate if confidence is visible. |
| `runtime/week` | Medium | **Experiment** | Useful vocabulary, but runtime varies radically by model, reasoning, context, tools, and task shape. |
| Weekly suggested pace | Medium-high | **Ship with caveat** | Actionable if expressed as percentage/day or budget/day, not as an official entitlement. |
| Reset-aware history | High | **Ship** | Required for forecast correctness; reset discontinuities are common enough to mislead ordinary charts. |
| Anomaly detection | Medium | **Experiment** | Real spikes exist, but shared usage, sparse snapshots, and unknown resets create false positives. |
| Model/reasoning/thread/subagent attribution | Medium | **Experiment** | Strong demand; local observability is good, but quota attribution remains approximate. |
| Cache/context/compaction/tool-loop diagnostics | Medium-high | **Experiment** | Multiple concrete failures; useful as local diagnostics, never as proof of backend charging. |
| Reset-use advisor | Low-medium | **Experiment later** | Advice depends on undocumented reset scope, ordering, and reset-anchor behavior. |
| Automatic reset redemption | High confidence against default | **Drop as a default** | Consequential account mutation; both unwanted-consumption and accidental-expiry reports exist. |
| Confidence, source, and freshness UI | High | **Ship** | Necessary to prevent estimates from being mistaken for OpenAI facts. |
| Local-first privacy safeguards | High | **Ship as a constraint** | Rollouts can contain full prompts, outputs, paths, and tool data even though direct privacy-feature demand is weak. |

## Method

### Source rules

This pass used:

- official OpenAI announcements, help pages, pricing, and the public `openai/codex` app-server protocol;
- direct user reports in `openai/codex` GitHub issues;
- direct Reddit posts and comments in the observation window;
- official Apple notification documentation and Human Interface Guidelines.

X was searched, but individual posts were inconsistently indexable and often lacked stable context. X sentiment is therefore not counted in the frequency signals below. Reddit scores and comments are dynamic and self-selected; they indicate resonance, not population prevalence.

The report does not treat:

- one user's local token count as OpenAI billing data;
- a subreddit complaint count as a representative survey;
- a model runtime as an entitlement;
- an unexplained percentage jump as proof that OpenAI changed limits.

### Confidence rubric

**High**

- the problem appears in at least three independent direct reports or in multiple reports plus official product behavior;
- the required input is available through a supported API or stable local record;
- major counterexamples change presentation or safeguards, not the core need.

**Medium**

- the problem is repeated and plausible, but the metric depends on local heuristics, incomplete logs, or incomparable workloads;
- or the need is strong while implementation can only approximate the answer.

**Low**

- evidence is isolated, indirect, or dominated by product speculation;
- or the product would need undocumented semantics to make a reliable recommendation.

### Frequency signal

“Repeated” means multiple independent threads or issues during the window. It does not mean a measured percentage of Codex users. High Reddit engagement is recorded only as evidence that a topic resonated with that community.

## What can actually be observed

### Supported backend facts

The official [Codex app-server account API](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#account-api) exposes:

- `account/rateLimits/read`;
- primary and secondary `usedPercent`, `windowDurationMins`, and `resetsAt`;
- backend-classified reached-limit state when present;
- `rateLimitResetCredits.availableCount`;
- reset-credit `id`, type, status, grant time, expiry time, title, and description when the backend returns detail rows;
- `account/usage/read` with an account token-activity summary and daily buckets.

Important constraints from the same protocol:

- rate-limit update notifications are sparse and must be merged with a full snapshot;
- reset-credit detail is snapshot-only;
- reset-credit rows may be capped, while `availableCount` is authoritative;
- a count can be available when individual expiry rows are not;
- the supported API can consume a reset, but that is an account mutation requiring explicit authorization and post-action verification.

These fields are sufficient for exact count, exact known expiry, live quota percentage, reset timestamp, backend daily activity, and a local forecast over observed percentage history.

The distinction between count and detail matters. `availableCount` is authoritative, but `credits` is optional and may be capped. The minimum `expiresAt` in the returned rows is therefore the **next known expiry**, not necessarily the next expiry across every available reset. The UI can say `Next reset expires` only when detail coverage is complete. Otherwise it should say `Next known expiry` and disclose `Details available for 2 of 3 resets`, or `Expiry unavailable` when no row is returned.

### Supported local activity facts and JSONL fallback

The supported app-server exposes more local diagnostic structure than the first research pass assumed:

- `thread/list` returns stored threads and can expose a known parent thread;
- experimental `parentThreadId` and `ancestorThreadId` filters return spawned descendants, but omit Review and Guardian threads;
- `thread/read`, `thread/turns/list`, and `thread/items/list` expose stored thread, turn, and item structure;
- `thread/tokenUsage/updated` identifies the thread and turn and reports cumulative and last-call input, cached input, cache-write input, output, reasoning-output, and total token counts;
- item records can represent command, MCP, dynamic-tool, collaboration, subagent, sleep, and compaction activity.

The official [app-server API overview](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#api-overview) and [v2 thread protocol](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/thread.rs) are the preferred read-only metadata surface. They do not by themselves prove that a separate app-server connection receives live notifications from Tasks owned by another Codex process. Raw rollout JSONL is therefore a candidate incremental source for token, timing, model, and tool facts because persisted thread items are documented as lossy, historical model and reasoning settings are not complete in the ordinary `Thread` and `Turn` projections, and older or ephemeral activity may be absent. Issue #25 must prove the safe source boundary before implementation.

Rollout JSONL can additionally contain:

- `session_meta`: session ID, timestamp, working directory, originator, CLI version, source, and model provider;
- `turn_context`: effective model and reasoning effort;
- `token_count`: input, cached input, output, reasoning output, total tokens, and model context window;
- task, compaction, tool-call, and tool-result events;
- parent/child session relationships that can support subagent grouping in some modes.

Sources include [discussion #12668](https://github.com/openai/codex/discussions/12668), [issue #34370](https://github.com/openai/codex/issues/34370), [issue #34061](https://github.com/openai/codex/issues/34061), and [issue #35259](https://github.com/openai/codex/issues/35259).

These sources can support local activity receipts and diagnostics when the spike proves their read-only behavior and Coverage. `thread/tokenUsage/updated` is cumulative and can be replayed, so a collector must deduplicate and calculate deltas. Neither it nor rollout JSONL is a subscription-billing API; both may be incomplete, deleted, created on another machine, or disconnected from shared account movement.

### Not publicly observable

No public source provides:

- the numeric weekly entitlement for every account and plan;
- a stable formula converting percentage into runtime;
- a one-to-one mapping from local rollout tokens to included-subscription usage;
- complete attribution for activity from other devices or shared agentic surfaces;
- a reliable cause for every hard reset or percentage discontinuity;
- the business value or correctness of a completed task.

Any feature that implies those answers should be dropped or explicitly labeled as an estimate.

## Repository and fork audit

This validation also inspected the current `thrr87/codex-limits` implementation and `shiptomorrow/main`, not only the feature screenshots.

### What the fork gets right

- A persistent app-server connection is the correct prerequisite for lower-latency reads and future notification handling.
- `availableCount` is parsed as the banked-reset count.
- The minimum returned expiry and a runtime-at-recent-pace estimate are useful prototypes.
- Reset-time tolerance and implausible-percentage-jump validation address real sampling problems.
- The new estimator and validation logic have focused unit tests.

### Gaps that must be corrected before treating the fork as product-complete

1. **Expiry coverage is lost.** The fork stores only `availableCount` and one minimum returned date. Because the backend may cap `credits`, it cannot distinguish a complete list from partial detail and must not label that date as the globally oldest reset.
2. **Notifications are not implemented.** The persistent reader currently accepts responses with an `id` and ignores notifications such as `account/rateLimits/updated`. A full snapshot is still required for reset-credit detail because the rolling update contains only `rateLimits`.
3. **The reminder does not exist yet.** There is no `UNUserNotificationCenter` integration, permission flow, pending-request replacement, or cancellation when a reset is used.
4. **`runtime/week` has no workload segmentation.** The fork derives active intervals from `task_started`, `task_complete`, and `token_count`, but does not segment by effective model, reasoning, subagent tree, context, or compaction. The number is a recent-mix estimate, not a weekly entitlement.
5. **Local activity and account allowance are not reconciled.** The fork does not yet show exact local activity beside the observed account-percentage delta and an explicit unattributed remainder.

### Existing chart integrity issue

The current [`BurnDownChart`](../../Sources/CodexLimits/MenuContentView.swift) reconstructs the period before the first allowance sample from daily token buckets, merges those reconstructed points with real samples, and renders the entire series as `Actual`. That violates the proposed provenance contract: a token-weighted estimate is visually presented as an observed account fact.

Before adding analytics, either remove this backfill or render it as a separately labeled estimated segment. Exact allowance samples, local activity, and projections must never share the same visual style or legend label.

## UI and information-architecture validation

The current popover is 420 points wide and already contains a headline, forecast copy, a 190-point four-series chart, reset and pace data, other limits, freshness, and controls. Adding reset inventory, reminders, runtime history, task trees, model mix, cache/context diagnostics, and provenance to that fixed layout would reduce scanability and make source distinctions harder to understand. The menu-bar entry should therefore open a larger, scrollable Analytics Workspace instead of cramming more rows into the existing fixed panel.

This is supported by three external constraints:

- An OpenAI collaborator reports that a Codex progress bar was reverted after negative feedback because users confused `used` with `remaining` and the bar consumed substantial space. The same comment says a gauge is inappropriate for absolute token counts. [GitHub #21324](https://github.com/openai/codex/issues/21324).
- Apple’s [Charts guidance](https://developer.apple.com/design/human-interface-guidelines/charts) calls for a clear main message, visual hierarchy, compact-width restraint, and distinctions that do not depend only on color.
- Apple’s [macOS guidance](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) supports using a resizable window for richer information, while `MenuBarExtra` remains suitable for glanceable status and immediate decisions. [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra).

The accepted information architecture is therefore one workspace with a clear reading order:

### Current guidance

- remaining allowance with an explicit `remaining` orientation;
- scheduled reset and runway verdict;
- banked-reset count, next known expiry, detail coverage, and reminder state;
- suggested percentage/day;
- source freshness and one compact confidence disclosure;
- one primary allowance visual at most.

### Graphs, facts, receipts, and insights

- a compact current-state header above switchable `Graphs`, `Facts`, and `Insights` views;
- `Graphs` switches between Usage remaining, Token activity, Usage per token, and Concurrency while preserving the time range and source-supported filters;
- `Facts` holds account facts, banked resets, Other limits, and Usage Receipts;
- reset-aware allowance history with factual and estimated segments;
- per-thread and agent-tree local activity receipts;
- model and reasoning mix when coverage permits;
- cache, context, compaction, wait/poll, and tool-loop diagnostics;
- observed account delta, associated local activity, and an `unattributed` remainder shown as different quantities;
- filters, point inspection, accessible table equivalents, and export.

No color palette or final chart form needs to be locked before a prototype. Two visual rules do need to be locked: use one explicit `remaining` orientation for allowance percentages, and never use a token-count gauge.

## Evidence matrix

| Product question | Direct problem evidence in window | Frequency signal | Technical observability | Primary UX risk | Confidence | Decision |
|---|---|---|---|---|---:|---|
| When does my next reset expire? | At least five independent Reddit threads plus GitHub #32540 report confusion or loss. | Repeated; one loss report reached roughly 30+ votes. | Exact `expiresAt` for returned rows; count remains available without complete details. | Presenting the earliest returned row as globally earliest when detail is capped. | High | **Ship** |
| Should the app remind me? | Users describe calendar reminders, babysitting expiry, and third-party safety-net tools. | Repeated but episodic. | Local notification from a known timestamp. | Notification fatigue, permission denial, stale schedules. | High | **Ship, opt-in** |
| Will my allowance last? | Multiple users translate usage into hours, days, one goal, or one feature. | Very strong topic resonance; dedicated megathread. | Estimate from percentage samples and reset time. | False certainty under workload changes or shared usage. | High | **Ship with confidence** |
| How many hours do I get per week? | Users ask and report measured runtime. | Repeated, but answers vary by more than an order of magnitude. | Only a local pace estimate. | Looks like an official entitlement. | Medium | **Experiment; rename** |
| What happened around a reset? | Reports of partial jumps, missing windows, changed reset timestamps, and ambiguous hard resets. | Repeated. | Detect discontinuities and known reset events; cause may remain unknown. | Misclassifying backend corrections or shared activity. | High | **Ship event-aware history** |
| Was this burn abnormal? | Sudden large drops and unexpectedly short windows are repeatedly reported. | Repeated. | Compare with the user's own prior comparable windows. | False accusations and alert fatigue. | Medium | **Experiment** |
| Which model/task/subagent used it? | Users explicitly compare Sol/Terra, effort levels, goals, reviews, and subagent fan-out. | Repeated and specific. | Strong local activity attribution; weak backend quota attribution. | Confusing correlation with billing or quality. | Medium | **Experiment** |
| Was context/cache/tool looping involved? | Direct analyses and GitHub issues show replay, compaction loops, polling, and event amplification. | Multiple technically detailed cases. | Rich local signals; no exact quota mapping. | Calling cached input “waste” or overstating causality. | Medium-high | **Experiment** |
| Should I use a reset now? | Users intentionally burn allowance before expiry and ask whether resets auto-apply. | Repeated. | Inputs are partly observable; reset semantics are incomplete. | Bad advice can waste remaining allowance or a reset. | Low-medium | **Experiment later** |
| Can I trust this number? | Users report disagreement between app, CLI, web, and reset states. | Repeated. | Source and fetch time are known; completeness can be modeled. | Too much technical clutter in a small menu. | High | **Ship** |
| Is deep local analysis private? | Little direct demand in-window; one retention question. | Weak expressed demand. | Risk is directly visible in rollout contents. | Exposing prompts, paths, tool output, or secrets. | High as safeguard | **Ship constraint** |

## 1. Reset expiry and reminders

### Problem evidence

The evidence is unusually direct:

- [“Are expiring resets automatically get used?”](https://www.reddit.com/r/codex/comments/1uyqhir/are_expiring_resets_automatically_get_used/) includes users who lost resets, assumed auto-use, or redeemed early because the time was unclear.
- [“Anyone know if when a reset expires is it used automatically?”](https://www.reddit.com/r/codex/comments/1v7eb2i/anyone_know_if_when_a_reset_expires_is_it_used/) asks whether the user must “babysit” a reset and includes another same-day loss.
- [“Lost a banked reset because the expiration timing is so unclear”](https://www.reddit.com/r/codex/comments/1v7s7hi/lost_a_banked_reset_because_the_expiration_timing/) reports a reset disappearing during the displayed date and raises timezone ambiguity.
- [“Banked reset and due date”](https://www.reddit.com/r/codex/comments/1v7r85x/banked_reset_and_due_date/) describes a European user planning around “today” and finding the reset already gone in the morning.
- [“Banked reset safety net”](https://www.reddit.com/r/codex/comments/1v7hyku/banked_reset_safety_net/) exists specifically to plan expiries and redeem before loss.
- [GitHub #32540](https://github.com/openai/codex/issues/32540) asks the official app to show a full timestamp, timezone, and countdown instead of only `Expires 7/12`.
- The user-provided X screenshot independently reports losing a banked reset because it expired before the user could claim it. It corroborates the problem but is not counted as a separate stable frequency signal because the original post was not reliably indexable.

Official OpenAI documentation says banked resets generally expire 30 days after grant. The supported app-server now exposes individual expiry timestamps when the backend provides them. [OpenAI promotion terms](https://help.openai.com/en/articles/20001271-codex-referral-promotions) and [app-server API](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#account-api).

### Disconfirming evidence

- The official Codex CLI `/usage` flow already shows exact local expiry times. Several Reddit replies correctly point users to it.
- The need is episodic: it matters only when a user has a banked reset with known detail.
- The backend may return only a count or a capped subset, so an app cannot always name the globally next expiry.
- A notification is best-effort and can be hidden by Focus or user settings.

These points reduce the need for a complex subsystem, not for the feature itself. A menu-bar app is valuable precisely because it can make a supported but buried timestamp continuously visible.

### Apple UX validation

Apple's [notification HIG](https://developer.apple.com/design/human-interface-guidelines/notifications) and [authorization guidance](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications) support this use case with constraints:

- request permission only after the user turns on the reminder;
- default to one useful notification for the next known expiry, not repeated nudges;
- replace or cancel the pending request when the reset is used or its timestamp changes;
- do not promise exact delivery;
- keep the in-app expiry visible even when notifications are denied;
- avoid `Time Sensitive` for reminders sent days or many hours early;
- do not include account IDs, project names, tokens, or other sensitive data in the preview.

A known date can use a local calendar notification even when the app is not running. It does not justify a hidden persistent helper. [Scheduling local notifications](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app) and [macOS background-process guidance](https://developer.apple.com/documentation/appkit/managing-ongoing-background-processes-in-your-mac).

### Recommendation

**Ship**:

- count;
- exact local date/time and countdown for the next known expiry;
- a visible partial-detail state when count exceeds returned rows;
- one opt-in local reminder;
- a user-selected threshold such as 24 hours, 3 days, or 7 days;
- rescheduling after every fresh reset snapshot;
- a neutral message such as `1 banked reset expires in 23 hours`.

Do not ship repeated automatic reminders or `Time Sensitive` by default.

## 2. Runway, weekly pace, and `runtime/week`

### Problem evidence

Users ask in work units rather than percentages:

- one Plus user reports [100% of weekly Ultra usage in 1h32m](https://www.reddit.com/r/codex/comments/1uv7ui6/codex_56_sol_at_ultra_used_100_of_my_weekly_usage/);
- another reports [one `/goal` consuming the week in about 4.5 hours](https://www.reddit.com/r/codex/comments/1v6wvg9/did_codex_just_eat_my_entire_weekly_quota_on_one/);
- [a Plus workflow question](https://www.reddit.com/r/codex/comments/1v1dgqh/any_tips_for_making_codex_weekly_usage_last/) asks how to make the allowance last after it began disappearing in one or two days;
- the [usage-limits megathread](https://www.reddit.com/r/codex/comments/1v42x6r/codex_usage_limits_and_performance_megathread/) aggregates many similar reports;
- one user manually documents [runtime by plan and model](https://www.reddit.com/r/codex/comments/1v1mr6k/what_i_actually_got_from_chatgpt_plus/), showing demand for a practical unit.

### Disconfirming evidence

Runtime is not stable:

- the Ultra report's highest-voted counterpoint says Ultra is inappropriate for a Plus daily workflow, and the original author acknowledges that the run completed substantial multi-system work;
- [a 47-minute Sol XHigh read-only test](https://www.reddit.com/r/codex/comments/1v6m80n/usage_test_after_reset/) reports only about 2% weekly usage;
- [another workflow discussion](https://www.reddit.com/r/codex/comments/1v4aaim/what_is_your_codex_workflow/) includes roughly eight-hour workdays using 10–20% daily;
- answers to [“How long does $20/$100 last?”](https://www.reddit.com/r/codex/comments/1v1cge2/how_long_does_it_take_to_go_through_the_20100/) range from a single user finding $100 sufficient to a multi-worker setup spending roughly $200/day;
- [“No Five Hour Limit?”](https://www.reddit.com/r/codex/comments/1uunmgu/no_five_hour_limit/) reports only 22% consumption despite multiple concurrent Sol Ultra sessions.

OpenAI explicitly says usage varies with model, task size, context, reasoning, tool use, retrieval, caching, and execution surface. It publishes approximate five-hour message ranges but no numeric weekly entitlement. [Current Codex pricing and limits](https://learn.chatgpt.com/docs/pricing#what-are-the-usage-limits-for-my-plan).

### Recommendation

**Ship** the decision:

- `At your observed pace, likely to last until reset`;
- estimated exhaustion date/time;
- gap between estimated exhaustion and scheduled reset;
- suggested remaining budget in percentage/day.

**Experiment** with runtime:

- show `Active time this week` as observed local time, counting overlapping Task Tree activity once;
- label the forecast `Estimated active time available`, not `Runtime/week`;
- use recent comparable activity only;
- show range and confidence, not a single authoritative number;
- show the forecast only when Local Coverage is high enough;
- invalidate or lower confidence after a reset, model-mix change, long sampling gap, or unexplained shared-pool movement.

Drop any wording implying that OpenAI grants a fixed number of runtime hours.

## 3. Reset-aware history

### Problem evidence

History can jump for reasons unrelated to ordinary consumption:

- users reported a [partial 44% restoration followed by an immediate drop](https://www.reddit.com/r/codex/comments/1v4rjn0/anyone_else_suddenly_get_44_weekly_codex_usage/);
- [GitHub #34661](https://github.com/openai/codex/issues/34661) reports `/usage` appearing to trigger a reset;
- [GitHub #32840](https://github.com/openai/codex/issues/32840) reports a missing five-hour window while the weekly window remained visible;
- [GitHub #34874](https://github.com/openai/codex/issues/34874) reports a free reset changing `reset_at` without restoring allowance;
- the high-engagement [reset complaint](https://www.reddit.com/r/codex/comments/1v788rs/i_hate_the_resets_it_is_unpredictable_when_they/) explains how a global reset can arrive when a user still has most of the allowance left.

### Disconfirming evidence

- A jump can be a display refresh, backend correction, scheduled window, banked reset, promotional reset, or an unknown event.
- Sparse app-server updates can omit fields.
- Sampling alone cannot reliably identify the cause.

### Recommendation

**Ship** event-aware history because it is a correctness requirement:

- split forecast segments at known reset boundaries;
- annotate `scheduled reset`, `banked reset consumed`, and `detected discontinuity`;
- use `unknown reset or correction` when causality is not observable;
- retain the pre-reset sample so the chart does not reinterpret replenishment as negative consumption;
- recompute confidence after a discontinuity.

Do not name an event `OpenAI hard reset` unless its source is known.

## 4. Anomaly detection

### Problem evidence

The window contains repeated sudden-depletion reports:

- [less than ten minutes to a five-hour limit](https://www.reddit.com/r/codex/comments/1ut9wpk/gpt_56_is_unusable/);
- [a first post-reset reading already at 79% used](https://github.com/openai/codex/issues/32607);
- [usage errors with no visible intervening activity](https://www.reddit.com/r/codex/comments/1ut14h3/anyone_else_having_usage_errors/);
- one Ultra task and one `/goal` consuming entire weekly allowances.

### Disconfirming evidence

- Shared usage can happen on another device or supported agentic surface.
- A sparse sample can make a gradual burn look instantaneous.
- Workloads and reasoning levels are not comparable by default.
- User reports cannot prove a universal entitlement reduction.

### Recommendation

**Experiment** with personal-baseline anomalies:

- compare only against the user's prior windows;
- require a minimum sample density;
- segment by model/reasoning mix when available;
- report `usage increased faster than your baseline`;
- show the observed delta, interval, source, and missing-data caveat;
- let users dismiss or mark an event as expected.

Keep the result passive inside `Insights` and show its evidence and Confidence. Do not send anomaly notifications. Never label a deviation `billing error` or `limit reduction`.

### Accepted comparable-workload design

The product can calculate three distinct quantities:

1. `Token Activity` — an account count from bounded lifetime-token readings when possible, a visibly partial daily fact when not, or a local count from Task records.
2. `Allowance Intensity` — observed allowance percentage points per unit of Token Activity for a bounded workload mix.
3. `Equivalent Capacity` — the Token Activity that would correspond to 100% of allowance if the observed mix and intensity remained constant.

Equivalent Capacity is not a published token entitlement. It is a personal extrapolation whose validity depends on model, reasoning, cache, context, tools, concurrency, task mix, shared activity, and reset continuity.

The default `Reference Baseline` is the median of exactly four previous complete High-comparability weekly windows. A user may pin another qualifying historical period. Incomplete coverage does not automatically suppress factual metrics:

- direct Token Activity remains factual;
- Allowance Intensity can use any bounded interval with usable start and end allowance readings;
- Equivalent Capacity can be shown with reduced confidence and the observed interval;
- a segment must stop at a known reset or detected discontinuity;
- a gap that may contain an unknown reset or correction cannot be bridged into one estimate.

The chart should show current comparable workload cost as a multiplier against baseline, expose raw token activity and allowance movement in the tooltip, and avoid the claim that OpenAI changed the limit.

## 5. Model, reasoning, task, and subagent attribution

### Problem evidence

Users explicitly want to choose:

- Sol versus Terra or Luna;
- Medium, High, XHigh, or Ultra;
- one long goal versus smaller tasks;
- one thread versus parallel worktrees;
- foreground work versus subagent fan-out.

The clearest request is [“GPT‑5.6 may have the same pricing but use more per task”](https://www.reddit.com/r/codex/comments/1v5norf/gpt56_in_codex_may_have_the_same_token_pricing/), which asks for model, input, output, reasoning, tool, agent, effort, and cost breakdowns. [Issue #34370](https://github.com/openai/codex/issues/34370) shows why effective metadata matters: a child requested at Medium could record an effective High `turn_context`.

### Disconfirming evidence

- Task boundaries are fuzzy inside a long thread.
- A child may inherit context and create duplicated local traffic without an equivalent independent backend debit.
- Fallback local records may expose only a working directory. They must not be used to invent a second hierarchy when Codex project grouping is unavailable.
- Off-device and shared-pool activity cannot be assigned to local tasks.
- Lower usage is not automatically better if the result is worse or incomplete.

### Recommendation

**Experiment** as a power-user view:

- aggregate local activity by effective model and reasoning effort;
- preserve parent/child relationships and show subagent share;
- group Tasks under the same short folder or project name and hierarchy already presented by Codex;
- show quota percentage deltas separately from local token activity;
- attach an attribution confidence such as `complete local thread`, `partial local data`, or `shared activity possible`.

Do not calculate a universal `efficiency score`. If outcome value is needed, ask for an optional user label such as `completed`, `partial`, or `abandoned`.

## 6. Token, cache, context, compaction, and tool-loop diagnostics

### Problem evidence

- A user reports [118M local tokens and 71% weekly usage](https://www.reddit.com/r/codex/comments/1v3c19s/i_used_118m_codex_tokens_in_one_day_and_consumed/), mostly cached input.
- A separate [context-replay analysis](https://www.reddit.com/r/codex/comments/1v4vawj/important_findings_on_cache_and_baked_in_codex/) argues that repeated input dominates local traffic.
- [GitHub #35259](https://github.com/openai/codex/issues/35259) measures wait/status-only turns at 19.8% of raw local tokens in one corrected reset window.
- [GitHub #34061](https://github.com/openai/codex/issues/34061) documents event amplification and disk growth across task, token, tool, and compaction records.
- [GitHub #35226](https://github.com/openai/codex/issues/35226) documents a July 24 auto-compaction loop that reread files and consumed an estimated 10–15% of paid usage without completing the edit.
- [GitHub #35300](https://github.com/openai/codex/issues/35300) reports a prompt-cache breakpoint issue.

### Disconfirming evidence

- The author of #35259 explicitly says raw local tokens are not subscription usage and found no proof of a silent quota reduction.
- Cached input is materially cheaper than uncached input; a high cache ratio is not inherently bad.
- A tool-heavy task may be valuable and correctly implemented.
- A proposed [tool-batching workaround](https://www.reddit.com/r/codex/comments/1v4vcnr/possible_gpt56_sol_usage_workaround_explicit_tool/) has both reported wins and a commenter who saw no improvement under five parallel worktrees.

### Recommendation

**Experiment** with transparent local diagnostics:

- cached and uncached input;
- output and reasoning output;
- context-window occupancy trend;
- compaction events;
- repeated wait/status-only turns;
- repeated file reads or similar tool calls;
- tool-call count and patch/test/fix cycles;
- parent and child session activity.

Use labels such as `local rollout activity`, `possible repeated work`, and `correlated quota delta`. Do not use `wasted credits`, `OpenAI charged`, or `billing cause`.

## 7. Reset-use advice and automatic redemption

### Problem evidence

Users want to avoid both failure modes:

- losing an unused reset at expiry;
- consuming a reset while substantial allowance remains.

[GitHub #32218](https://github.com/openai/codex/issues/32218) proposes a carefully bounded, opt-in queue that redeems one reset only after a real usage-limit block and notifies on success, expiry, cancellation, or failure. The proposal exists because a long-running task can otherwise stop unattended.

The countercase is [GitHub #28525](https://github.com/openai/codex/issues/28525), where a user reports an automatic reset consumption without explicit confirmation and asks Codex to pause first. The [July 26 reset complaint](https://www.reddit.com/r/codex/comments/1v788rs/i_hate_the_resets_it_is_unpredictable_when_they/) likewise objects to resets arriving when most quota remains.

### Unknown mechanics

OpenAI does not publicly guarantee:

- FIFO consumption;
- how every `Full reset` affects all limit windows;
- whether redemption changes the normal reset anchor in every account state;
- a universal optimal threshold for redemption.

### Recommendation

**Ship only factual guidance**:

- expiry timestamp;
- current remaining percentage;
- scheduled reset timestamp;
- estimated likelihood of exhaustion before expiry.

**Experiment later** with a read-only advisor using explicit assumptions:

- `At your recent pace, you are unlikely to hit the limit before this reset expires`;
- `Using it now would replace approximately 12% remaining`.

**Drop automatic redemption.** The accepted product uses a Reset Reminder and leaves redemption to the user.

## 8. Confidence, provenance, and freshness

### Problem evidence

Users report conflicting or missing usage states between app, CLI, web, and refreshes. The underlying data genuinely comes from different layers:

1. backend rate-limit snapshots;
2. backend daily usage buckets;
3. local rollouts;
4. local estimates derived from the first three.

The app-server protocol itself warns that update notifications are sparse and that reset detail can be missing even when the count is known.

### Recommendation

**Ship** a compact provenance system:

- `Live allowance · OpenAI account`;
- `Reset expiry · OpenAI account · updated 2m ago`;
- `Task activity · local Codex logs`;
- `Runway · estimate · medium confidence`.

Each derived metric should carry:

- source class;
- observation/fetch time;
- completeness;
- sample count and span;
- confidence-reduction reasons.

In the menu, this can be one secondary label and a tooltip or disclosure. It should not become a wall of telemetry.

## 9. Privacy

### Evidence

Direct in-window demand is weak: one [data-retention question](https://www.reddit.com/r/codex/comments/1v3k1ax/how_long_is_my_data_retained_from_codex_if_i_use/) had little engagement.

The technical risk is nevertheless high. Official guidance to inspect `~/.codex/sessions` shows that rollout files can contain full instructions, prompts, outputs, working directories, and tool records. [Discussion #12668](https://github.com/openai/codex/discussions/12668). Deep analytics therefore process potentially sensitive source paths, code, terminal output, and secrets even if the product never uploads them.

### Recommendation

Treat privacy as a shipping constraint, not a marketing-only feature:

- local processing by default;
- read only known Codex data locations;
- aggregate numeric/event fields without storing raw prompt or tool text;
- hash or omit project paths in persisted analytics;
- make content-level loop inspection opt-in;
- expose retention and deletion controls;
- never put project names, account identifiers, token details, or activity content in notifications;
- make export explicit and redactable.

The product should remain useful using backend snapshots alone. Deep local diagnostics can be an optional mode.

## Disconfirming evidence summary

The research does **not** validate these claims:

- “GPT‑5.6 always consumes the weekly allowance faster.”
- “OpenAI silently reduced every user's weekly cap.”
- “Local JSONL tokens equal billed or included usage.”
- “Cached tokens are wasted tokens.”
- “Ultra is inefficient because it consumed more quota.”
- “Runtime per week is a stable plan entitlement.”
- “Every percentage jump is a hard reset.”
- “Automatic reset redemption is always user-beneficial.”
- “More tool calls or subagents necessarily means a worse outcome.”

The product should help users test these hypotheses against their own history without presenting them as established facts.

## Recommended product sequence

### Ship now

1. Banked-reset count.
2. Exact next known expiry with timezone, live countdown, and detail coverage.
3. One opt-in local expiry reminder.
4. Suggested percentage/day and will-it-last forecast.
5. Reset-aware history and forecast segmentation.
6. Source, freshness, completeness, and confidence labels.
7. Local-first privacy defaults.

### Experiment next

1. Active time this week and estimated active time available at recent pace, with a range.
2. Comparable workload cost and Equivalent Capacity over time.
3. Personal-baseline anomaly detection.
4. Local model/reasoning/thread/subagent breakdown.
5. Cache, context, compaction, and tool-loop diagnostics.
6. Read-only reset-use scenarios.

### Drop or defer

1. A fixed `hours per week` entitlement.
2. A universal usage-efficiency score.
3. Claims that local activity explains backend billing.
4. Automatic reset redemption.
5. Multiple unsolicited expiry notifications.
6. `Time Sensitive` notifications days before expiry.
7. A hidden always-running helper solely for a known expiry timestamp.

## Decision queue before PRD

These questions should be resolved one at a time. The recommended defaults preserve the high-confidence product while keeping uncertain analytics reversible.

1. **Product center — resolved:** how should glanceable decisions and power analytics be divided?\
   **Decision:** opening the menu-bar item presents one screen-aware, scrollable Analytics Workspace. A compact current-state header stays visible above switchable `Graphs`, `Facts`, and `Insights` views. `Graphs` switches between `Usage remaining`, `Token activity`, `Usage per token`, and `Concurrency`; `Facts` holds account facts, reset details, Other limits, and Usage Receipts.
2. **Hours-based metrics — resolved:** what should measured and forecast time mean?\
   **Decision:** `Active time this week` is observed local time in the current Allowance Window, with overlapping Task Tree activity counted once. `Estimated active time available` is a range based on recent comparable work and appears only with high enough Local Coverage. Never use `runtime/week` or imply a fixed hours entitlement.
3. **Reminder default — resolved:** what should happen when a reset first becomes observable?\
   **Decision:** reminders remain off until enabled. Once enabled, schedule one notification with a default Reminder Lead Time of 24 hours; the user can select another interval.
4. **Missing expiry detail — resolved:** how visible should incomplete backend detail be?\
   **Decision:** show a short Reset Detail Coverage label next to the authoritative count, such as `3 banked resets · 1 expiry known`. Use `Next known expiry` for partial detail and `Expiry dates unavailable` when no expiry is known.
5. **Local diagnostics — resolved:** what is the consent boundary?\
   **Decision:** Codex information already accessible on the machine can be analyzed without a separate analytics opt-in, but all Codex-derived data, computation, and derived history remain local and are not transmitted as product telemetry.
6. **Project identity — resolved:** how should work be grouped and named?\
   **Decision:** reuse the hierarchy already presented by Codex and show its short folder or project name. Do not create aliases, infer another hierarchy, or rename Codex projects.
7. **Mutation boundary — resolved:** may the app change Codex state?\
   **Decision:** no. It reads, calculates, shows, reminds, and analyzes on request without redeeming resets, changing settings, or controlling tasks. `Reset Reminder` replaces the rejected Reset Automation and never changes account state.
8. **Usage deviation posture — resolved:** should unusual burn trigger notifications?\
   **Decision:** no. Show a Usage Deviation as a passive Insight with its evidence, comparison period, Coverage, and Confidence. Do not send anomaly notifications or claim a cause.
9. **Canonical orientation — resolved:** should allowance be shown as used or remaining?\
   **Decision:** use Codex’s reader-facing label `Usage remaining` for every primary percentage and burn-down orientation. Consumption metrics may use `used` only when the label names the quantity explicitly.
10. **Test seam — resolved:** what unit should own the intelligence logic?\
    **Decision:** one pure `UsageIntelligenceEngine` transforms normalized account events, local activity events, settings, and `now` into the complete reader-facing snapshot. Source adapters only read and normalize data. SwiftUI only renders the snapshot. Test adapters against protocol fixtures and test forecasts, reset segmentation, coverage, reconciliation, confidence, and copy-driving states through the engine.
11. **Codex-assisted trigger — resolved:** may model-assisted analysis run automatically?\
    **Decision:** no. It is a separately labeled, user-initiated `Analyze with Codex` action with an information tip explaining that it sends a request to Codex and consumes allowance.
12. **Codex-assisted preflight — resolved:** when is an additional confirmation required?\
    **Decision:** Metadata-only Analysis starts directly from the explicit action. Source-backed Analysis first shows a short preflight listing the content categories that will be sent to Codex.
13. **Codex-assisted execution profile — resolved:** which model performs the default analysis?\
    **Decision:** show the feature only when `model/list` advertises the exact GPT-5.6 Luna Medium profile. Do not fall back to GPT-5.5 Medium, Terra, Sol, another reasoning level, or the analyzed Task model. A stronger retry requires a separate user action and an explicitly available profile.
14. **Comparable workload baseline — resolved:** what historical period anchors the comparison?\
    **Decision:** the median of exactly four previous complete High-comparability weekly windows, with the option to pin another qualifying historical period. Partial observations remain factual but enter comparison only when the Coverage, comparability, boundary, and workload-mix gates in `docs/MEASUREMENT-CONTRACT.md` pass.
15. **Canonical token totals — resolved:** which token source leads the weekly view?\
    **Decision:** Account Token Activity is the primary weekly total. Prefer a same-account lifetime-token delta across a bounded weekly interval. Calendar-day buckets remain factual, but a partial-day sum never becomes an exact weekly total. Local Token Activity provides Task, agent, and model breakdowns. When compatible interval and token definitions are proven, the product shows both and reports Local Coverage rather than silently merging them.
16. **Product language — resolved:** how should reader-facing copy be written?\
    **Decision:** follow Orwell’s six rules: use literal, short, necessary, active, everyday language and break a rule only to avoid harsh, false, or unclear text. Product-specific examples live in `docs/PRODUCT-LANGUAGE.md`.
17. **Usage receipt unit — resolved:** what defines one receipt?\
    **Decision:** one Task Tree: the root Codex Task and every observable descendant agent task. The receipt totals the tree and drills down to agents and turns; projects group Tasks but do not define receipt boundaries.
18. **Analytics history retention — resolved:** how long should Derived Records remain on the machine?\
    **Decision:** keep Analytics History without a time limit until the user deletes it. Do not copy Source Content into the history. `Delete analytics history` removes the whole Codex Limits history on the Mac and in the selected sync folder. It does not rebuild automatically; a separate explicit action can rebuild only what remains available from Codex sources.
19. **PRD scope — resolved:** should advanced analytics be deferred to a later product phase?\
    **Decision:** no. The PRD covers the complete Analytics Workspace, including comparable-workload analysis, Active Time, Concurrency, deep local diagnostics, and user-initiated Codex-assisted Insights alongside the high-confidence allowance and reset features.
20. **Primary allowance window — resolved:** which account window anchors the product?\
    **Decision:** the `10080`-minute weekly window owns the menu-bar percentage, header, Runway, Suggested Pace, and default Usage remaining graph. Five-hour and model-specific windows stay named Other limits and never replace a missing weekly window.
21. **Measurement contract — resolved:** when may the product show Coverage, Confidence, or a comparison?\
    **Decision:** use the shared thresholds, interval boundaries, workload-mix gates, account partitioning, and withholding rules in `docs/MEASUREMENT-CONTRACT.md`. Low-confidence conclusions remain hidden with a reason.
22. **Local source boundary — resolved:** may a second app-server observe another Codex process by assumption?\
    **Decision:** no. A technical spike must prove the safest read-only, incremental source before Local Token Activity implementation. The app never resumes or takes ownership of a user Task merely to observe it.
23. **Account facts — resolved:** which factual account context belongs in Token activity and Facts?\
    **Decision:** show available lifetime tokens, peak daily tokens, longest running turn, current and longest streak, credits, unlimited-credit state, and spend-control state. Missing fields do not invalidate present facts.
24. **History deletion across sync — resolved:** how does deletion stay final when another Mac is offline?\
    **Decision:** advance an empty sync generation, block older imports, and keep deletion pending if the folder is unavailable. Preserve settings and do not claim completion until supported stores are cleared.

## Final assessment

The fork's banked-reset count and returned-expiry fields are validated strongly enough to ship after preserving detail coverage and using `next known expiry` when the list is partial. `Suggested pace` is also defensible when expressed as a budget derived from the current remaining percentage and reset time. Hours are useful only as observed Active Time and a personal, confidence-bounded estimate of Active Time available.

The next differentiated feature should not be another chart. It should be a trustworthy decision layer:

- **Your next known reset expiry is at this exact local time; detail coverage is 2 of 3.**
- **Your current allowance is or is not likely to last until reset.**
- **This estimate changed because a reset, workload mix, or data gap occurred.**
- **These are OpenAI account facts; these are local diagnostics; this is an estimate.**

That combination addresses the most repeated user pain while staying inside what the product can honestly observe.

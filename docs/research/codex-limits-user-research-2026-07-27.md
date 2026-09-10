# Codex limits after GPT‑5.6: user research and product opportunities

Date: 2026-07-27\
Primary observation window: 2026-07-09–2026-07-27\
Product: `codex-limits`

## Executive summary

The strongest user need is no longer another percentage meter. Users want to answer four decisions:

1. **Will my allowance last until reset?**
2. **What consumed it, and was that consumption normal?**
3. **Which model, reasoning level, task, or workflow should I use next?**
4. **Should I use a banked reset, buy credits, pause work, or wait?**

The current app already covers the first question with pacing and a forecast. The fork’s banked-reset count, oldest-reset expiry, and runtime/week estimate extend that well. The most valuable next step is to make the forecast **event-aware and explainable**: compare the current window with previous windows, flag abnormal burn, and attribute local usage to models and tasks without pretending that local token logs are identical to OpenAI’s private subscription ledger.

The evidence for this direction is unusually concentrated. Within the observation window, r/codex created a dedicated [usage-limits megathread](https://www.reddit.com/r/codex/comments/1v42x6r/codex_usage_limits_and_performance_megathread/) after many separate complaints; high-engagement posts reported [one Ultra task consuming a full weekly allowance](https://www.reddit.com/r/codex/comments/1uv7ui6/codex_56_sol_at_ultra_used_100_of_my_weekly_usage/), [one `/goal` consuming a full week](https://www.reddit.com/r/codex/comments/1v6wvg9/did_codex_just_eat_my_entire_weekly_quota_on_one/), and [7% disappearing in five minutes](https://www.reddit.com/r/codex/comments/1v70vl9/7_weekly_limit_gone_in_5_minutes_max_20x_plan/). These are self-selected reports, not proof of a universal quota reduction, but they reveal the questions the product must help users answer.

## Scope and method

- GPT‑5.6 became generally available on **July 9, 2026**, so the research window starts there rather than at an assumed later date. [OpenAI launch announcement](https://openai.com/index/gpt-5-6/) and [model release notes](https://help.openai.com/en/articles/9624314-model-release-notes).
- Sources prioritize first-party user reports on Reddit and GitHub issues in `openai/codex`, plus official OpenAI documentation and status reports.
- X was searched, but direct X pages are inconsistently indexable. A small number of original employee posts are useful as reset-event evidence, but X sentiment is not quantified.
- Reddit scores and comment counts are dynamic. They are used only as a rough signal of resonance.
- Reports show perceived or locally measured consumption. They do **not** establish that OpenAI silently lowered every account’s weekly entitlement.
- Recommendations are separated from observations. Features seen in other open-source trackers are listed separately from user demand.

## Official baseline: what is known and what is not

### Known

- OpenAI says local and cloud messages share a five-hour window and that “additional weekly limits may apply.” It publishes approximate five-hour message ranges but not a numeric weekly entitlement. [Current Codex pricing and limits](https://learn.chatgpt.com/docs/pricing#what-are-the-usage-limits-for-my-plan).
- Usage varies with model, task size, context, reasoning, tool use, retrieval, caching, and execution surface. Similar-looking tasks can therefore consume different amounts. [Current Codex pricing and limits](https://learn.chatgpt.com/docs/pricing#what-are-the-usage-limits-for-my-plan).
- Codex moved to token-based credit accounting. Current GPT‑5.6 rates per one million input / cached-input / output tokens are: Sol `125 / 12.5 / 750`, Terra `62.5 / 6.25 / 375`, and Luna `25 / 2.5 / 150` credits. [OpenAI Codex rate card](https://help.openai.com/en/articles/20001106-codex-rate-card).
- Codex, ChatGPT Work, and supported agentic features can draw from the same included allowance and credit pool. [OpenAI pricing](https://learn.chatgpt.com/docs/pricing) and [credits documentation](https://help.openai.com/en/articles/12642688-using-credits-for-flexible-usage-in-chatgpt-pluspro).
- Eligible Plus and Pro users received reset banking in June. Banked resets are generally usable for 30 days after grant. [June 11 release note](https://help.openai.com/en/articles/6825453-chatgpt-release-notes) and [referral-promotion terms](https://help.openai.com/en/articles/20001271-codex-referral-promotions).
- Banked resets are not cash or API credits. Purchased credits are used after included usage and expire after 12 months. [Referral-promotion terms](https://help.openai.com/en/articles/20001271-codex-referral-promotions) and [credits documentation](https://help.openai.com/en/articles/12642688-using-credits-for-flexible-usage-in-chatgpt-pluspro).
- The public Codex app-server API exposes quota-window usage, reset time, available earned-reset count, and reset-credit expiry details when the backend provides them. It also exposes an account token-activity summary and daily buckets. [Official app-server README](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#account-api).

### Not known publicly

- OpenAI has not published the numeric weekly cap or a formula that converts remaining percentage into hours of runtime.
- OpenAI has not documented `runtime/week`, `suggested pace`, or a stable “messages remaining” conversion as entitlement units.
- OpenAI has not published a changelog proving a permanent weekly-cap reduction caused by GPT‑5.6.
- There is no public guarantee that banked resets are consumed FIFO, nor a general fixed maximum number that can be banked.
- OpenAI has not documented that all local token records map one-to-one onto subscription-limit debits.

**Product consequence:** `runtime/week`, “hours left,” and “effective cap” must be presented as local estimates with a confidence/staleness label, never as official allowance.

## User observations and recommendations

### 1. Users need runway, not a raw percentage

**Observation**

Users repeatedly translate the meter into time or work: “one or two days,” “one feature,” “one `/goal`,” or “a normal workday.” A Plus user asked how to make a weekly allowance last after it began disappearing in one or two days and explicitly compared two simultaneous reasoning configurations. [“Any tips for making Codex weekly usage last longer on Plus”](https://www.reddit.com/r/codex/comments/1v1dgqh/any_tips_for_making_codex_weekly_usage_last/). Another user reported a 4.5-hour `/goal` consuming the full weekly quota and asked whether long goals should be split into smaller tasks. [One `/goal` report](https://www.reddit.com/r/codex/comments/1v6wvg9/did_codex_just_eat_my_entire_weekly_quota_on_one/).

**Recommendation**

Keep the current pace forecast as the primary product. Add a more direct decision statement:

- estimated exhaustion date/time;
- estimated gap before scheduled reset;
- “hours at your recent active-work pace,” explicitly labeled as an estimate;
- confidence based on sample count, recency, and whether a reset or model mix changed.

### 2. Users cannot tell whether a spike came from entitlement, model mix, or agent behavior

**Observation**

The megathread contains multiple unchanged-workflow comparisons: users report the same class of tasks costing materially more after the launch window, but they disagree on the cause. Proposed causes include a lower effective quota, model behavior, cache replay, tool polling, and accounting bugs. [Usage-limits megathread](https://www.reddit.com/r/codex/comments/1v42x6r/codex_usage_limits_and_performance_megathread/). OpenAI has previously acknowledged a separate incident in which fraud-prevention systems incorrectly rate-limited some accounts, while saying it did not observe broad degradation. [OpenAI status incident, June 26–29](https://status.openai.com/incidents/01KW2E6W0503W4NXJNCVAG8V6T).

**Recommendation**

Add an anomaly layer that says **what changed in the observed data**, not why OpenAI changed it:

- current burn rate versus the median of the last 3–5 comparable windows;
- spike start time;
- simultaneous changes in model, reasoning, speed, active threads, or reset state;
- neutral labels such as `Higher than your baseline`, not `OpenAI reduced your limit`.

### 3. Model and reasoning attribution is a high-frequency decision need

**Observation**

Fresh discussions compare Sol/Terra/Luna and Medium/High/XHigh/Ultra because users are trying to choose a viable daily driver. The Plus workflow question asks whether XHigh for review and High for implementation wastes usage. [Workflow question](https://www.reddit.com/r/codex/comments/1v1dgqh/any_tips_for_making_codex_weekly_usage_last/). The Ultra report quantifies two runs totaling 1h32m and a full weekly allowance. [Ultra report](https://www.reddit.com/r/codex/comments/1uv7ui6/codex_56_sol_at_ultra_used_100_of_my_weekly_usage/). The megathread includes comparisons where users moved down to Medium but still perceived higher burn. [Megathread](https://www.reddit.com/r/codex/comments/1v42x6r/codex_usage_limits_and_performance_megathread/).

OpenAI’s current rate card makes this a legitimate cost dimension: Terra is half Sol’s credit rate and Luna one fifth, while reasoning, context, and tool use also affect actual consumption. [Official pricing](https://learn.chatgpt.com/docs/pricing#what-are-the-usage-limits-for-my-plan).

**Recommendation**

Power-user analytics should break local token and estimated-credit usage down by:

- model;
- reasoning effort;
- speed mode where available;
- day/window;
- foreground thread versus child/subagent.

The UI should compare like with like and avoid claims such as “Medium is 2× more efficient” unless enough comparable history exists.

### 4. Thread/task attribution is more actionable than daily totals

**Observation**

Users identify costly units as tasks: a `/goal`, an Ultra run, a review, or one feature. They want to know which unit emptied the meter and whether they should split it next time. [One `/goal` report](https://www.reddit.com/r/codex/comments/1v6wvg9/did_codex_just_eat_my_entire_weekly_quota_on_one/), [Ultra report](https://www.reddit.com/r/codex/comments/1uv7ui6/codex_56_sol_at_ultra_used_100_of_my_weekly_usage/), and [workflow discussion](https://www.reddit.com/r/codex/comments/1v4aaim/what_is_your_codex_workflow/).

**Recommendation**

Add a local “top consumers” view:

- thread/task name, start/end, runtime, quota delta, local token total, estimated credits;
- model/reasoning mix;
- subagent count;
- a link back to the local Codex thread where possible.

Use `quota delta` and `local token estimate` as separate columns. Never imply that local tokens exactly explain the backend percentage.

### 5. Cache/context rebuild and tool loops are now a concrete diagnostic need

**Observation**

One July 22 user analysis reported 118M local tokens and 71% weekly allowance use, with roughly 114.6M cached input tokens. [118M-token analysis](https://www.reddit.com/r/codex/comments/1v3c19s/i_used_118m_codex_tokens_in_one_day_and_consumed/). A separate analysis of ten Sol rollouts reported that 99.77% of local token traffic was input and argued that repeated context replay dominated. [Context-replay analysis](https://www.reddit.com/r/codex/comments/1v4vawj/important_findings_on_cache_and_baked_in_codex/).

The strongest reproducible evidence is GitHub issue [#35259](https://github.com/openai/codex/issues/35259): in one corrected local reset window, turns whose only action was waiting or polling represented 19.8% of raw local token volume. The author explicitly states that raw local tokens are not the same as subscription usage and found no proof of a silent quota reduction.

**Recommendation**

Power-user diagnostics should surface:

- cached versus uncached input;
- cache-hit ratio;
- input/output ratio;
- context size trend per turn;
- compaction/rebuild events;
- repeated wait/status/tool-only turns;
- repeated identical or near-identical tool calls;
- subagent and auto-review share.

These are diagnostic signals, not quality scores. A high cache ratio can be economically useful because cached input is cheaper, while a huge cached prefix replayed hundreds of times can still be costly.

### 6. Reset events make ordinary trend charts misleading

**Observation**

Users report balances jumping after refresh, uncertainty over whether a hard reset completed, and conflicting reset dates between surfaces. [Hard-reset inconsistency report](https://www.reddit.com/r/codex/comments/1ur07x0/hard_limit_reset_or_not/) and GitHub issue [#32840](https://github.com/openai/codex/issues/32840). Another GitHub report says merely opening `/usage` appeared to grant a reset, illustrating how unexplained discontinuities are interpreted as bugs. [Issue #34661](https://github.com/openai/codex/issues/34661).

Promotional/global resets also occurred around the launch period. A July 17 [original Codex-lead X post](https://x.com/thsottiaux/status/2078310751878647932) announced another reset for paid Codex and ChatGPT Work users. These hard resets are not the same thing as a saved reset in the user’s bank.

**Recommendation**

Treat resets as first-class events:

- scheduled window reset;
- detected hard/global reset;
- user-consumed banked reset;
- unknown discontinuity.

Split forecasts at reset boundaries, annotate charts, and do not interpret a jump from 10% to 100% as negative usage.

### 7. Banked resets need an advisor, not only a counter

**Observation**

Users explicitly ask for banked resets instead of unpredictable hard resets and worry that a reset changes their normal reset timing. [Megathread comments](https://www.reddit.com/r/codex/comments/1v42x6r/codex_usage_limits_and_performance_megathread/). OpenAI says banked resets generally expire 30 days after grant and exposes individual expiry timestamps when available through the app server. [Referral terms](https://help.openai.com/en/articles/20001271-codex-referral-promotions) and [app-server API](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#account-api).

The sharper failure mode is accidental expiry. A July 27 user planned around the displayed calendar date, only to find the reset gone early in their local morning; replies pointed them to the exact `/usage` expiry time. [“Banked reset and due date”](https://www.reddit.com/r/codex/comments/1v7r85x/banked_reset_and_due_date/). Another community tool was built specifically to show an expiry planner and optionally redeem a reset shortly before it expires. [Banked Reset Safety Net](https://github.com/just-every/banked-reset-safety-net). This supports an explicit reminder use case even if `codex-limits` remains read-only.

**Recommendation**

The fork’s `Banked resets` and `Oldest reset expires in` fields are strongly supported. Add a read-only **Reset Guard**:

- show the exact local expiry date and time as well as a live countdown;
- schedule configurable notifications, with sensible presets such as 24 hours, 2 hours, and 30 minutes;
- make the final notification actionable: open the Codex usage surface or copy the expiry details;
- persist which notification thresholds have fired so refreshes and app restarts do not duplicate them;
- reschedule from a fresh backend snapshot after wake, clock/time-zone changes, and account changes;
- state clearly that the reset is **not** redeemed automatically.

A later advisor can answer:

- which reset expires first;
- whether current pace is likely to hit the limit before expiry;
- whether waiting for the scheduled reset would preserve more optionality.

Do not assume FIFO. Use expiry details returned by the backend and label missing detail. Automatic redemption should remain a separate, explicit opt-in feature: it changes account state, requires idempotency and post-action verification, and should not be bundled with ordinary notifications.

### 8. Shared-pool and data-freshness ambiguity damages trust

**Observation**

OpenAI documents that supported agentic products can share the same allowance. Users nevertheless ask whether ChatGPT Work consumes Codex usage and report conflicting values between `/status`, web, and app. [Shared-pool question](https://www.reddit.com/r/codex/comments/1us5udh/does_the_new_chatgpt_work_consume_codex_usage/) and GitHub issue [#32840](https://github.com/openai/codex/issues/32840).

**Recommendation**

Always display:

- sample timestamp and source;
- whether data came from backend rate limits, backend daily usage, or local JSONL;
- staleness/error state;
- a note that other supported agentic surfaces can consume the shared pool;
- a warning when two observed sources disagree beyond a tolerance.

## Power-user analytics demand matrix

| Dimension | User question | Evidence strength in the July 9–27 window | Product interpretation |
|---|---|---:|---|
| Model | “Is Sol the cause; should I use Terra/Luna?” | Strong | Per-model breakdown is high value. |
| Reasoning | “Should review be XHigh and implementation High/Medium?” | Strong | Compare effort only within similar tasks; show sample sizes. |
| Thread/task | “Which `/goal` or feature consumed the week?” | Strong | Per-thread/task leaderboard and quota deltas. |
| Subagents | “Did Ultra or agent fan-out burn the allowance?” | Strong | Parent/child attribution and fan-out diagnostics. |
| Cache/context | “Is repeated context replay the real cost?” | Strong | Cache, context-growth, compaction, and replay views. |
| Tool loops | “Was Codex doing useful work or polling?” | Strong | Wait/poll/tool-only turn share and loop flags. |
| Window comparison | “Why is this reset/window worse than last week?” | Strong | Comparable-window baselines and anomaly detection. |
| Project | “Which repo/client is consuming usage?” | Moderate/adjacent | Useful for power users, but direct fresh demand is weaker than thread/model demand. |
| Usage efficiency | “How much useful work did I get per quota?” | Strong concept, weak automatic metric | Use transparent proxies or an explicit user outcome tag. |

## Defining “usage efficiency” without misleading users

No single token-efficiency number measures delivered value. Recommended metrics should form a ladder:

### Safe descriptive metrics

- quota percentage per active hour;
- local estimated credits per active hour;
- local tokens per model turn;
- cached/uncached input and output shares;
- wait/poll-only share;
- context growth per turn;
- current-window burn versus the user’s own historical baseline.

### Useful but interpretive metrics

- estimated credits per completed thread/task;
- quota delta per completed task;
- subagent overhead share;
- tool-loop overhead share;
- context-replay share.

### Experimental outcome proxies

- user marks a task `useful`, `partial`, or `failed`;
- estimated credits per user-confirmed completed task;
- estimated credits per merged PR/commit or verified test pass.

Lines changed, files touched, or output tokens alone must not be labeled “productivity”: a small bug fix can be more valuable than a large generated diff.

## Open-source tracker landscape

This section describes implemented features, not proof that every feature has user demand.

| Project | Primary implemented ideas | Relevance to `codex-limits` |
|---|---|---|
| [ccusage](https://github.com/ccusage/ccusage) | Local daily/weekly/monthly/session reports, per-model breakdown, cache-create/read columns, estimated cost, JSON export; project grouping exists for supported sources. | Strong reference for stable local token aggregation and export; weak on quota runway and reset decisions. |
| [CodexBar](https://github.com/steipete/CodexBar) | Menu-bar quotas, reset countdowns, local 7/30-day cost estimates, model breakdowns, Codex project totals, multi-account/provider support, staleness/incident UI. [CLI schema](https://github.com/steipete/CodexBar/blob/main/docs/cli.md). | Closest product-shape competitor; demonstrates value of combining allowance and local cost, but has much broader multi-provider scope. |
| [Codex Usage Tracker](https://github.com/douglasmonsky/codex-usage-tracker) | Current v0.26 is a local evidence kernel. Historical [v0.25.1](https://github.com/douglasmonsky/codex-usage-tracker/tree/v0.25.1) exposed thread/model/reasoning/subagent/cache/context-pressure diagnostics and evidence links. | Strong reference for forensic drill-down and data-quality caveats; too heavy for the default menu-bar experience. |
| [OpenAI Codex app-server](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#account-api) | Backend rate-limit snapshots, earned-reset details, expiry timestamps, daily token activity. | Preferred authoritative source for live allowance and reset metadata; does not by itself explain per-thread local behavior. |

The clearest positioning opportunity is therefore: **Codex Limits is the decision layer between a simple meter and a forensic token dashboard.**

## Data provenance

Power-user analytics should preserve the boundary between four data classes. Every metric should carry a source class, observation time, and completeness/confidence state.

### A. Backend facts from the Codex app server

`account/rateLimits/read` can provide:

- `rateLimits` / `rateLimitsByLimitId`;
- `limitId` and `limitName`;
- primary and secondary `usedPercent`, `windowDurationMins`, and `resetsAt`;
- backend limit-reached type when available;
- `rateLimitResetCredits.availableCount`;
- optional per-reset `id`, `grantedAt`, `expiresAt`, `status`, `title`, and `description`.

`account/usage/read` provides an account token-activity summary and daily buckets. The current app decodes `dailyUsageBuckets[].startDate` and `tokens`. These are backend responses, but daily aggregation still does not attribute usage to a local thread. [Official app-server account API](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#account-api) and current [`CodexClient.swift`](../../Sources/CodexLimits/CodexClient.swift).

Current implementation note: `CodexClient` presently decodes only the reset `availableCount`, even though the upstream protocol can return expiry details.

### B. Exact local metadata already stored by Codex or Codex Limits

Codex Limits stores a bounded local percentage history:

- `observedAt`;
- `remainingPercent`;
- `resetsAt`.

It also stores backend daily `date` and `tokens` buckets for forecast bootstrapping. See [`UsageModels.swift`](../../Sources/CodexLimits/UsageModels.swift) and the [shared-history ADR](../adr/0006-user-selected-folder-for-shared-usage-history.md).

Codex rollout JSONL can contain, depending on client/version/mode:

- `session_meta`: thread/session ID, timestamp, `cwd`, originator, CLI version, source, and model provider;
- `turn_context`: effective model and reasoning effort, including child-agent context;
- `event_msg/token_count`: cumulative and last-turn input, cached-input, output, reasoning-output, and total tokens; model context-window size; sometimes embedded rate-limit observations;
- lifecycle and diagnostic records such as task start/complete, compaction, tool calls/results, and agent events.

Examples of these exact fields appear in OpenAI’s repository discussions and issues: [`session_meta` and `cwd`](https://github.com/openai/codex/discussions/12668), [`token_count` usage fields](https://github.com/openai/codex/issues/19022), and effective [model/reasoning in child `turn_context`](https://github.com/openai/codex/issues/34370).

These files are precise records of what the local client persisted. They are not a stable billing API, can be absent in ephemeral modes, and can vary by Codex version.

### C. Derived estimates

The following are product calculations, not facts returned by OpenAI:

- `remainingPercent = 100 - usedPercent`;
- expected, historical, and safety remaining-at-reset forecasts;
- suggested percentage per day/hour;
- estimated exhaustion time and `runtime/week`;
- anomalous-burn score versus personal history;
- credits or API-equivalent cost calculated from local token buckets and the public rate card;
- per-thread/task/project attribution assembled from local metadata;
- estimated cache/context/tool-loop overhead.

The current forecast combines recent percentage burn with historical burn and uses daily token history only as a coarse bootstrap. See [`ForecastEngine.swift`](../../Sources/CodexLimits/ForecastEngine.swift). New UI should label these values `Estimate` and expose a short “based on” explanation.

### D. Not observable from available data

- the account’s numeric weekly entitlement and OpenAI’s private debit formula;
- the exact backend debit caused by one local turn;
- which other device or shared-pool product caused an unexplained quota change;
- the cause or scope of a global reset that occurred between samples;
- missing, cleared, archived, ephemeral, or corrupted local sessions;
- whether a task’s result was correct, valuable, or “worth” its usage;
- the counterfactual cost and quality of running the same task on another model;
- whether an observed correlation proves a server-side quota change.

**Required UI rule:** never merge backend quota, backend daily tokens, local rollout tokens, and estimated credits into one unlabeled number. Reconciliation gaps are expected and should be visible.

## Assessment of the shiptomorrow fork

The fork is a substantial prototype rather than a small presentation patch. Relative to the current upstream base it adds roughly 2,770 lines, expands the test suite from 18 to 46 test functions, and includes:

- banked-reset count, earliest expiry, plan label, and used/remaining display;
- a persistent app-server connection and configurable refresh interval;
- weekly-limit history separate from the primary-window history;
- local task-runtime extraction from Codex JSONL;
- estimated active hours per full weekly allowance and a historical pace chart;
- daily-runtime-informed forecasting and guards against implausible percentage increases;
- settings for lookback, pause treatment, prior-window display, and history reset.

The banked-reset fields are sourced from supported app-server data and can move upstream with low interpretive risk. The weekly runtime work is useful but currently reads task timestamps and quota samples; it does not yet segment the estimate by model, reasoning, token composition, project, or subagent. That makes a single `runtime/week` number sensitive to workload changes.

For a power-user roadmap, adopt the fork in separable slices rather than treating the expanded menu view as the final architecture:

1. app-server connection, complete rate-limit/reset model, and data-validation fixes;
2. reset UI, exact countdowns, and Reset Guard notifications;
3. activity ingestion and an incremental analytics store;
4. runtime estimate with confidence and segmentation;
5. advanced charts and settings.

## Product architecture: two ledgers plus reconciliation

The strongest differentiator is to combine two independent ledgers:

1. **Allowance ledger:** event-aware snapshots from `account/rateLimits/read` and `account/rateLimits/updated`, plus reset-credit snapshots and reset events.
2. **Activity ledger:** incrementally parsed local turns/tasks with model, reasoning, speed, token composition, project, parent/child relationship, runtime, compactions, and selected tool metadata.

A reconciliation engine can then align each observed quota delta with activity in the same interval:

- allocate the delta among non-overlapping local tasks using official credit weights as a prior;
- show concurrent tasks as shared attribution rather than false precision;
- preserve an `Unattributed` bucket for Work/cloud/voice, missing logs, or delayed backend accounting;
- calibrate model/task estimates against the user’s own observed quota changes;
- break all calculations at scheduled, banked, hard, or unknown reset events.

This creates a useful power-user answer without claiming access to OpenAI’s private ledger: “The account meter fell 12 points; 9 points are strongly associated with these two local tasks, while 3 remain unattributed.”

The app server already supports sparse rate-limit update notifications, so the persistent connection introduced by the fork can record changes closer to the work that caused them and use periodic full reads only for reconciliation. For local logs, a production analytics engine should index appended JSONL incrementally rather than rereading whole session files on every refresh; very large or event-amplified sessions are a known real-world case.

## Recommended hierarchy

### MVP: broadly useful, low interpretive risk

1. Ship banked-reset count, exact oldest-expiry time, countdown, and configurable Reset Guard notifications.
2. Show explicit estimated exhaustion time and “days/hours before reset.”
3. Make charts reset-event aware and annotate detected hard/manual/scheduled resets.
4. Compare current burn with the previous comparable window and personal median.
5. Add a conservative spike flag based on the user’s own baseline.
6. Show freshness, source, and confidence for every estimate.
7. Keep `runtime/week` but label it `estimated active runtime at recent pace`.

### Power-user v2: explain the burn

1. Per-model and reasoning-effort token/estimated-credit breakdown.
2. Top threads/tasks with runtime, quota delta, models, and child-agent count.
3. Cache/context panel: cached and uncached input, context growth, compactions.
4. Subagent/auto-review/tool-loop share and wait/poll-only diagnostics.
5. Current versus prior windows with filters by model, effort, task, and project.
6. Exportable local evidence for reporting suspicious consumption.

### Experiments: valuable but easy to overclaim

1. Reset-use advisor based on expiry and forecasted exhaustion.
2. “What if I switch to Terra/Luna or lower reasoning?” based only on the user’s comparable history.
3. User-confirmed task outcomes and `estimated credits per completed task`.
4. Inferred effective-cap change across windows.
5. Project/client budgeting and weekly allocation.

## Interpretation and implementation risks

- **Local tokens are not subscription debits.** Local rollouts can contain copied history, duplicated cumulative counters, or records not charged as users assume. Issue [#35259](https://github.com/openai/codex/issues/35259) explicitly separates raw local volume from OpenAI’s private ledger.
- **Off-device usage creates unexplained quota changes.** ChatGPT Work and supported agentic features share the pool; local JSONL cannot fully attribute them.
- **Reset discontinuities corrupt naïve forecasts.** Hard resets, manual banked resets, and scheduled resets must split time series.
- **Model comparisons are confounded.** Harder tasks tend to use stronger models and reasoning, so observational averages are not causal.
- **Runtime is not entitlement.** Long idle waits can consume very little or tool polling can consume a lot; time alone is not a stable denominator.
- **Cached tokens are not free, but high cache use is not automatically waste.** Current rate cards discount cached input substantially.
- **Task boundaries are fuzzy.** A thread can contain multiple tasks; clones/subagents can copy history. Prefer explicit boundaries when available and show attribution confidence.
- **Anomaly detection needs enough personal history.** Use a neutral “insufficient baseline” state instead of global thresholds.
- **Privacy is part of the product promise.** Thread/project names and local paths are more sensitive than aggregate percentages. Keep analysis local and make exports aggregate-first.

## Bottom line

The research supports the fork’s reset fields immediately. Beyond those, the highest-value addition is not another chart by itself but a layered explanation:

1. **Runway:** when will I run out?
2. **Change:** is this window abnormal for me?
3. **Attribution:** which model/task/agent behavior drove it?
4. **Action:** slow down, switch model, split the task, use a reset, or wait?

That hierarchy keeps the default menu simple while giving power users a path from a surprising percentage drop to auditable local evidence.

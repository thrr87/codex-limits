## Problem Statement

Codex shows how much usage remains, but it does not explain whether that usage will last, what consumed it, how the current week compares with earlier work, or when a banked reset will expire. Power users run several tasks and agents across models and reasoning levels. They see large changes in Usage remaining but cannot connect those changes to their local work with enough confidence to make a decision.

The current Codex Limits app helps with pace, but it remains a small status view. It records sparse allowance samples, keeps only 90 days of history, and cannot explain task trees, model mix, concurrency, local token activity, reset-detail coverage, or differences between account and local data. Its chart can also present token-derived estimates as observed allowance, which gives uncertain data too much authority.

Users need a local Codex observability app that answers three questions in one place:

1. What is my account state now?
2. What local work relates to that state?
3. What should I do next?

The answer must remain honest when sources are incomplete. The product must not claim a token entitlement, billing cost, limit reduction, or causal link that it cannot observe.

## Solution

Evolve Codex Limits into one screen-aware, scrollable, native macOS Analytics Workspace opened from the menu bar. The workspace may grow taller than the current panel while remaining bounded by the available display. A persistent current-state header sits above switchable `Graphs`, `Facts`, and `Insights` views.

The top of the workspace shows weekly Usage remaining, the next weekly reset, banked resets, Reset Detail Coverage, Runway, Suggested Pace, and the clearest current action. `Graphs` lets the user switch among `Usage remaining`, `Token activity`, `Usage per token`, and `Concurrency` without losing the selected time range or supported filters. `Facts` contains account facts, banked resets, Other limits, and Usage Receipts. `Insights` contains deterministic and Codex-assisted observations. The user can inspect points, select ranges, and zoom.

Account Token Activity is the main weekly token value. The product derives an exact bounded total from observed lifetime-token readings when possible. Complete daily buckets remain factual, but a partial-day sum never becomes an exact weekly total. Local Token Activity explains tasks, agents, models, and turns. When aligned values differ, the product shows both and reports Local Coverage. It never silently combines them.

The product retains compact Analytics History until the user deletes it. `Delete analytics history` removes all history owned by Codex Limits on the Mac and in the selected sync folder and does not rebuild it automatically. The product reads Source Content locally when needed but does not copy it into the analytics store. Deterministic Insights run locally. `Analyze with Codex` runs only after a clear user action, states that it uses Codex allowance, appears only when the exact GPT-5.6 Luna Medium profile is available, and shows a preflight before sending Source Content.

The account-control boundary remains read-only. The app reads, calculates, shows, reminds, and analyzes on request. It does not redeem resets, change Codex settings, or control tasks.

## User Stories

1. As a Codex user, I want to open one Analytics Workspace from the menu bar, so that I can understand my usage without moving between separate tools.
2. As a Codex user, I want to see weekly Usage remaining first, so that the app uses the established weekly limit and the same orientation as Codex.
3. As a Codex user, I want to see the exact reset date and local time, so that I know when the current Allowance Window ends.
4. As a Codex user, I want to see how fresh the account reading is, so that I know whether I can act on it.
5. As a Codex user, I want to refresh account facts on demand, so that I can check a recent change.
6. As a Codex user, I want the last valid reading to remain visible when refresh fails, so that a temporary source error does not erase useful context.
7. As a Codex user, I want stale data to be marked, so that an old reading is not presented as current.
8. As a Codex user, I want to see the authoritative number of banked resets, so that I know how many are available.
9. As a Codex user, I want to see the Next Known Expiry, so that I can use a banked reset before it expires.
10. As a Codex user, I want Reset Detail Coverage next to the reset count, so that missing expiry details are visible.
11. As a Codex user, I want the app to say `Expiry dates unavailable` when no detail is returned, so that absence is not mistaken for no expiry.
12. As a Codex user, I want reminders to work only for a known expiry, so that the app does not invent a schedule.
13. As a Codex user, I want Reset Reminder to remain off until I enable it, so that notifications start by choice.
14. As a Codex user, I want the default reminder 24 hours before the Next Known Expiry, so that I have time to act.
15. As a Codex user, I want to choose another Reminder Lead Time, so that the reminder fits my work pattern.
16. As a Codex user, I want one local notification for the next known expiry, so that I am reminded without repeated prompts.
17. As a Codex user, I want a scheduled reminder cancelled or updated after a fresh reading shows that the reset was used, expired, or changed, so that stale reminders are reduced.
18. As a Codex user, I want the expiry to remain visible when notification permission is denied, so that the core feature still works.
19. As a Codex user, I want the app never to use a reset for me, so that account changes remain under my control.
20. As a Codex user, I want to know whether my current pace is likely to last until reset, so that I can adjust my work.
21. As a Codex user, I want an estimated exhaustion time, so that I can compare it with the scheduled reset.
22. As a Codex user, I want Runway to update after new account readings, so that guidance follows current facts.
23. As a Codex user, I want Suggested Pace in percentage points per day or hour, so that I have a clear working budget.
24. As a Codex user, I want a configurable safety buffer, so that the forecast can preserve capacity for later work.
25. As a Codex user, I want estimates to show Confidence and Coverage, so that I can distinguish a strong forecast from a weak one.
26. As a Codex user, I want the product to name the source of each value, so that account facts, local facts, and estimates do not blend together.
27. As a Codex user, I want the Usage remaining chart to show observed account readings as observed data, so that estimates never look exact.
28. As a Codex user, I want reset boundaries and unknown corrections marked on history, so that discontinuities do not look like ordinary use.
29. As a Codex user, I want target, observed, current forecast, and historical reference to use distinct visual styles, so that I can read the chart correctly.
30. As a Codex user, I want to hover over chart points, so that I can inspect exact time, value, source, and confidence.
31. As a Codex user, I want to select a chart range, so that receipts and insights can follow the same interval.
32. As a Codex user, I want to zoom and change the time range, so that I can move from the current window to long-term history.
33. As a Codex user, I want filters to remain selected when I switch charts and apply only where their source supports them, so that an account chart is never presented as a Project-level fact.
34. As a Codex user, I want Account Token Activity as the main weekly token total, so that the weekly view follows the account source.
35. As a Codex user, I want Local Token Activity beside the account total, so that I can inspect work recorded on this Mac.
36. As a Codex user, I want Local Coverage shown when account and local totals differ, so that incomplete attribution is explicit.
37. As a Codex user, I want Unattributed Movement shown instead of forced task attribution, so that the product does not invent a cause.
38. As a Codex user, I want token activity broken down by Task Tree, so that I can find work that used the most local tokens.
39. As a Codex user, I want each Usage Receipt to start at the root Codex Task, so that receipt boundaries match Codex.
40. As a Codex user, I want a Usage Receipt to include observable descendant agent tasks, so that agent work is not lost.
41. As a Codex user, I want to drill from a Task Tree into agents and turns, so that I can locate expensive local activity.
42. As a Codex user, I want receipts grouped under the same short Project name and hierarchy shown by Codex, so that the app feels familiar.
43. As a Codex user, I want the product to avoid custom project aliases, so that I do not manage a second hierarchy.
44. As a Codex user, I want breakdowns by effective model and reasoning level, so that I can compare actual execution settings.
45. As a Codex user, I want cache, context, and compaction facts when available, so that I can understand large local token totals.
46. As a Codex user, I want tool-loop and wait activity shown separately from execution, so that elapsed time is not mistaken for active work.
47. As a Codex user, I want Active Time for the current Allowance Window, so that I know how long at least one Task Tree was active.
48. As a Codex user, I want overlapping Task Tree activity counted once in Active Time, so that concurrency does not inflate wall time.
49. As a Codex user, I want Concurrency over time, so that I can see how many Task Trees ran together.
50. As a Codex user, I want to filter Concurrency by Project, model, and Task Tree when supported, so that I can inspect a busy interval.
51. As a Codex user, I want Estimated Active Time Available as a range, so that I can translate remaining allowance into a practical unit.
52. As a Codex user, I want the time estimate hidden when Local Coverage is too low, so that weak data does not produce a precise-looking answer.
53. As a Codex user, I want the time estimate recalculated after a model-mix change, reset, gap, or unexplained account movement, so that stale assumptions lose confidence.
54. As a Codex user, I want Comparable Workload Cost over time, so that I can see whether similar work uses more or less allowance than before.
55. As a Codex user, I want the default Reference Baseline to use the median of the previous four complete High-comparability weeks, so that one unusual week does not dominate.
56. As a Codex user, I want to pin another Reference Baseline, so that I can compare with a period I understand.
57. As a Codex user, I want the comparison shown as a multiplier against baseline with raw values in the tooltip, so that the result remains inspectable.
58. As a Codex user, I want Equivalent Capacity labeled as an estimate under an observed workload mix, so that it is not confused with a token entitlement.
59. As a Codex user, I want partial weeks to remain usable with lower Confidence when their interval is bounded, so that incomplete data is not discarded without reason.
60. As a Codex user, I want a comparison withheld after an unknown reset or correction, so that an unbounded interval does not create a false result.
61. As a Codex user, I want deterministic Insights based on local facts and clear rules, so that useful guidance does not consume allowance.
62. As a Codex user, I want a Usage Deviation to appear as a passive Insight, so that unusual use is visible without interrupting me.
63. As a Codex user, I want a Usage Deviation to include the measured change, comparison period, Coverage, and Confidence, so that I can judge it.
64. As a Codex user, I want no notification for a Usage Deviation, so that uncertain detection does not create alert fatigue.
65. As a Codex user, I want the app to avoid claims such as `billing error` or `limit reduction`, so that observations are not presented as causes.
66. As a Codex user, I want to dismiss or mark a Usage Deviation as expected, so that repeated review stays useful.
67. As a Codex user, I want a separate `Analyze with Codex` action, so that model-assisted analysis runs only when I ask.
68. As a Codex user, I want an information tip on `Analyze with Codex`, so that I know it sends a request to Codex and uses allowance.
69. As a Codex user, I want Metadata-only Analysis to start from that clear click without another modal, so that a safe action stays quick.
70. As a Codex user, I want a preflight before Source-backed Analysis, so that I can see which content categories will be sent.
71. As a Codex user, I want the preflight to list prompts, responses, code, paths, commands, and tool output only when included, so that consent matches the actual request.
72. As a Codex user, I want Analyze with Codex shown only when the exact GPT-5.6 Luna Medium profile is available, so that the product never changes the execution profile silently.
73. As a Codex user, I want a stronger retry to require another action, so that the app does not raise model cost on its own.
74. As a Codex user, I want Analytics Overhead shown after model-assisted analysis, so that the analysis can be included in my usage review.
75. As a Codex user, I want Codex-assisted output marked, so that it is distinct from deterministic facts.
76. As a Codex user, I want no Codex-assisted analysis to run in the background, so that the feature never consumes allowance without intent.
77. As a Codex user, I want Analytics History kept on my Mac until I delete it, so that long comparisons improve over time.
78. As a Codex user, I want Source Content excluded from Analytics History, so that the store remains compact and local.
79. As a Codex user, I want `Delete analytics history`, so that I can remove every Derived Record on demand.
80. As a Codex user, I want the app to state that deleted history can be rebuilt only where Codex sources remain available, so that recovery is not overstated.
81. As a Codex user, I want no product telemetry, so that my Codex work remains on my device.
82. As a Codex user, I want the app to read local Codex data incrementally, so that analytics does not create noticeable CPU, memory, or disk load.
83. As a Codex user, I want clear source errors when the Codex protocol changes, so that incompatible data does not create a misleading chart.
84. As a Codex user, I want other Codex limits shown with Usage remaining and reset time, so that model-specific limits remain visible.
85. As a keyboard user, I want every chart mode, filter, receipt, setting, and action reachable without a pointer, so that the workspace is fully operable.
86. As a VoiceOver user, I want charts to expose summaries and selected-point details as text, so that visual analysis remains accessible.
87. As a Codex user, I want plain, short, active English throughout the product, so that I can understand each fact and action once.
88. As a Codex user, I want the menu-bar percentage to remain glanceable, so that deeper analytics does not remove the current quick check.
89. As a Codex user, I want Token activity to show available account facts such as lifetime tokens, peak daily tokens, longest running turn, streaks, credits, and spend control, so that I can inspect factual account context without another tool.
90. As a Codex user, I want an observed lifetime-token delta to lead weekly Account Token Activity and partial daily buckets to stay labeled as partial, so that a calendar-day approximation does not look exact.
91. As a Codex user, I want Analytics History separated when the signed-in Codex account changes, so that two accounts never share a baseline.
92. As a Codex user, I want Delete analytics history to remove the whole Codex Limits history from this Mac and its selected sync folder without rebuilding it automatically, so that the action means what it says.
93. As a Codex user, I want no fallback model for Analyze with Codex, so that unavailable Luna Medium does not cause a hidden request to another model.
94. As a Codex user, I want the workspace to use the available screen height and switch among Graphs, Facts, and Insights, so that deeper data remains readable without opening another application.
95. As a Codex user, I want Low-confidence conclusions withheld with a reason, so that weak evidence does not create a precise-looking answer.
96. As a Codex user, I want five-hour and model-specific windows shown as named Other limits without replacing the weekly limit, so that each percentage keeps its real meaning.

## Implementation Decisions

- Keep the product as a native macOS 14+ Swift and SwiftUI menu-bar app using Apple Swift Charts. Do not add an Electron, Tauri, browser, or web-server runtime.
- Opening the menu-bar item presents one screen-aware, vertically scrollable Analytics Workspace. It may use more of the available screen height than the current panel but must reflow on smaller displays. Do not open a separate analytics application or use a horizontal chart carousel.
- Keep a compact current-state header visible above switchable `Graphs`, `Facts`, and `Insights` views. It contains weekly Usage remaining, the reset time, banked-reset facts, the current action, Runway, Suggested Pace, freshness, and source state. `Facts` contains account facts, banked resets, Other limits, and Usage Receipts.
- `Graphs` has four first-class modes: `Usage remaining`, `Token activity`, `Usage per token`, and `Concurrency`. Time range persists across modes. Project, Task Tree, model, and reasoning filters remain selected but affect only local or comparable-work views whose sources support them; account-level Usage remaining never changes under a local filter.
- Charts support hover, point inspection, range selection, and zoom. Selected ranges drive the receipts and Insights shown below the chart.
- Observed account data, local activity, forecasts, targets, baselines, and unknown corrections must have distinct marks and legend labels. Token-derived backfill must never use the same `Actual` style as observed account readings.
- Use Codex app-server as the primary supported source. Maintain one persistent local app-server session instead of launching a new process for every refresh.
- Read account state from `account/read`, `account/rateLimits/read`, and `account/usage/read`. Merge sparse rate-limit notifications with full snapshots; request a full snapshot for banked-reset details.
- Select the weekly Codex window by `windowDurationMins == 10080`. It owns the menu-bar percentage, header, Runway, Suggested Pace, and default Usage remaining chart. Five-hour and model-specific windows remain named Other limits and never replace it.
- Record `summary.lifetimeTokens` with account readings. Prefer a same-account lifetime-token delta for bounded weekly Account Token Activity. Use daily buckets only for exact calendar-day sums or visibly partial facts; never scale a partial day into an exact weekly total.
- Show available account facts in Facts and Token activity: lifetime tokens, peak daily tokens, longest running turn, current and longest streak, credits, unlimited-credit state, and spend-control state.
- Partition Analytics History by an on-device keyed account fingerprint when stable account identity is available. An auth transition with unknown identity starts a new isolated partition.
- Treat `rateLimitResetCredits.availableCount` as the authoritative banked-reset count. Treat returned reset records as optional detail. The minimum returned expiry is the Next Known Expiry, not a guaranteed global earliest expiry when Reset Detail Coverage is incomplete.
- Put short reset detail directly beside the count: `2 banked resets · Next expires in 8 days` when complete, `3 banked resets · 1 expiry known · Next known in 8 days` when partial, and `2 banked resets · Expiry dates unavailable` when no detail is returned.
- The completed read-only Local Activity spike fixes the 0.145.0 source contract: use `thread/list` with `useStateDbOnly: true` for Task discovery, use `thread/read` with `includeTurns: false` only as a bounded metadata fallback, and tail rollout JSONL incrementally for local token, turn, model, reasoning, partial tool, timing, and compaction facts. Never resume, start, fork, control, or take ownership of a user Task to observe it. Recheck this capability contract when the installed CLI version changes.
- Read local sources incrementally with durable cursors, file identity, modification time, and cumulative-counter deduplication. Do not rescan all Codex history on every refresh.
- Normalize source output into account events, local activity events, source state, and settings before analysis. Each event carries source, observation time, and enough identity to deduplicate replay.
- One pure `UsageIntelligenceEngine` is the main test seam. It accepts normalized account events, local activity events, settings, and `now`; it returns the complete reader-facing snapshot containing metrics, chart series, receipts, Coverage, Confidence, freshness, and Insights.
- Apply [the measurement contract](../MEASUREMENT-CONTRACT.md) to every reader snapshot. Low-confidence estimates and Insights are withheld with a named reason. Views never invent their own Coverage, Confidence, or comparability rule.
- Source adapters only read and normalize. SwiftUI only renders the reader-facing snapshot and sends explicit user actions. Forecast and insight logic must not live in views.
- Account Token Activity is the main weekly token total. Local Token Activity is a separate local protocol breakdown by Task Tree, observable agent, turn, model, and reasoning level.
- Never merge Account Token Activity and Local Token Activity into one unexplained value. In Codex CLI 0.145.0, show both with their own provenance and qualitative source coverage, but keep numeric Local Coverage unavailable because the account and local token definitions are not proven compatible.
- Represent account changes as Account Movement. In Codex CLI 0.145.0, do not subtract local token totals to create token-denominated Unattributed Movement. Describe the account movement and the incomplete local source coverage separately.
- Segment history at known resets. Preserve samples on both sides. Mark an unexplained increase in Usage remaining as `unknown reset or correction` and lower Confidence until a new bounded interval starts.
- Calculate Runway and Suggested Pace from observed account readings, time to reset, the safety buffer, and comparable history. A model-mix change, gap, reset, or unexplained movement lowers Confidence or invalidates the estimate.
- Calculate Active Time as the union of intervals in the current Allowance Window where at least one observable Task Tree is active. Count overlaps once. Classify waiting and polling separately when the source supports it.
- Calculate Concurrency as the number of Active Task Trees at each point in time. Do not count open or idle threads as active.
- A Task is the root Codex task presented by Codex. A Task Tree contains that Task and every observable descendant agent task. A Usage Receipt totals the Task Tree and drills down to agents and turns.
- Reuse the Project hierarchy and short folder or project name presented by Codex. Do not infer or maintain a second hierarchy.
- The visible `Usage per token` chart uses Comparable Workload Cost internally. It calculates Allowance Intensity only for intervals that pass the measurement contract and compares the current value with a Reference Baseline. The default baseline is the median of the previous four complete High-comparability weekly windows; the user may pin another qualifying period.
- Equivalent Capacity estimates the Account Token Activity associated with 100% allowance under the observed workload mix. It is an estimate, never a token allowance or contract.
- Partial intervals may contribute when their start and end are bounded. Lower Confidence based on Coverage. Exclude intervals containing an unknown reset or correction from comparable-workload calculations.
- Usage Deviation compares only with the user’s personal baseline under comparable conditions. It remains a passive Insight and carries the observed delta, interval, evidence, Coverage, and Confidence.
- Deterministic Insights run locally from the engine. They never invoke a model or consume allowance.
- `Analyze with Codex` is a separate user action with an information tip that states the request is sent to Codex and consumes allowance. It never runs automatically.
- Metadata-only Analysis begins after the explicit click without another modal. Source-backed Analysis first shows a short preflight listing the exact Source Content categories included.
- Read `model/list` before exposing Analyze with Codex. Show the action only when the catalog advertises GPT-5.6 Luna with Medium reasoning. Do not fall back to GPT-5.5, Terra, Sol, another reasoning level, or the analyzed Task model.
- The analysis Task receives only the bounded payload, cannot use tools, cannot read additional files, and cannot change the workspace. A stronger retry is a separate action and must use an explicitly available profile.
- Mark Codex-assisted Insights and record local analysis activity as Analytics Overhead. Show bounded Account Movement observed during the request without claiming that concurrent movement was caused by the analysis.
- Preserve the account-control boundary. Do not call reset redemption, change Codex settings, start or stop user tasks, or otherwise control task execution. User-requested Codex analysis is the only model invocation owned by this feature.
- Request notification authorization when the user first enables Reset Reminder, not at launch. Keep the in-app feature usable if permission is denied.
- Schedule one local calendar notification for the nearest known expiry using a default 24-hour Reminder Lead Time. Reschedule or cancel it after fresh reset data changes its state. Do not use `Time Sensitive` by default.
- Keep reset notifications neutral and private. Include only the banked-reset fact and time to expiry; do not include Project names, account identifiers, token details, or Source Content.
- Keep Derived Records without automatic expiry. Add an explicit destructive `Delete analytics history` action with confirmation. It removes all Codex Limits Derived Records on this Mac and every supported account usage record in the selected sync folder, including files from other installations.
- Deletion advances an empty sync generation so another Mac cannot republish older history. If the sync folder is unavailable, keep deletion pending, block older imports, and do not claim completion. Do not rebuild deleted history automatically; a separate explicit rebuild action may read only sources that still exist.
- Continue using versioned, account-partitioned local records and atomic writes so the app remains lightweight. Remove the current 90-day cutoff. Migrate existing usage history without losing valid samples.
- Keep the existing user-selected folder limited to account usage samples. Do not copy Task Tree, agent, model, Source Content-derived, or Codex-assisted records into that folder in this PRD.
- Do not store copied prompts, responses, code, paths, commands, or tool output in Analytics History. Persist only compact facts, aggregates, classifications, fingerprints, source state, Coverage, and Confidence.
- Do not send Codex-derived product telemetry. The only external data path added by this PRD is the user-requested `Analyze with Codex` request described above.
- Follow the product language rules: literal, short, necessary, active, everyday English. Use `Usage remaining` for the main percentage. Name the quantity and source. Describe a change without inventing a cause.
- Keep all visible UI free of debug text, internal reasoning, test notes, implementation notes, and unsupported claims.
- Preserve graceful degradation. If one source fails, keep valid data from other sources, mark missing Coverage, and withhold only the affected conclusions.
- Keep refresh work off the main actor except for publishing the final reader snapshot. Batch disk reads and UI updates to avoid churn while Codex is active.
- Preserve the menu-bar quick percentage, wake refresh, panel-open refresh, manual refresh, and periodic refresh. Persistent notifications may add lower-latency updates but do not remove full reconciliation reads.

## Testing Decisions

- Test external behavior through the highest stable seam. Given the same normalized events, settings, and `now`, `UsageIntelligenceEngine` must return the same reader-facing snapshot.
- Extend the existing synthetic-fixture approach. Never commit real account data, Source Content, credentials, local paths, or raw user rollout files as fixtures.
- Use `ForecastEngineTests` as prior art for deterministic time and pace scenarios, then migrate those behaviors into `UsageIntelligenceEngine` tests.
- Use `CodexClientTests` as prior art for protocol decoding. Add fixtures for `account/read`, complete and partial reset detail, missing expiry detail, sparse notifications, weekly and Other limits, lifetime and daily account tokens, account facts, credits, spend control, `model/list`, incompatible responses, and reordered fields.
- Use `UsageHistoryTests` as prior art for file corruption, idempotent migration, cross-installation merge, unavailable folders, version mismatches, and preservation of valid in-memory history.
- Test normalization and deduplication for replayed app-server events, cumulative token-usage notifications, duplicate thread reads, JSONL file growth, renamed files, and process reconnects.
- Test weekly-window selection by duration. If no `10080`-minute window exists, verify that the weekly state is unavailable and that a five-hour or model-specific window never replaces it.
- Test Account Token Activity from same-account lifetime-token deltas at exact weekly boundaries. Cover counter decrease, account change, missing boundary readings, gaps, complete calendar-day sums, and partial daily buckets that remain partial instead of being scaled.
- Test account facts when each field is present, null, missing, malformed, or unsupported. A missing fact must not erase the valid facts beside it.
- Test reset segmentation for known resets, banked reset use, unexplained upward corrections, reset timestamp changes, and sparse readings across a boundary.
- Test Reset Detail Coverage for complete detail, partial detail, zero detail, count changes, expired detail, and out-of-order expiry records.
- Test reminder scheduling with an injected notification scheduler and clock. Cover the default 24-hour lead, custom lead, permission denial, app-not-running delivery semantics, reschedule, cancellation after use, expiry, and stale account state.
- Test Runway and Suggested Pace across quiet use, fast use, insufficient samples, long gaps, model-mix changes, shared-account movement, reset boundaries, and safety-buffer hysteresis.
- Test that Account Token Activity and Local Token Activity remain separate in Codex CLI 0.145.0. Even equal values at identical boundaries must remain Not comparable, with numeric Local Coverage and token-denominated Unattributed Movement unavailable. Retain reconciliation scenarios as a future contract test only after a source version proves compatible token definitions.
- Test every Coverage and Confidence state in the measurement contract as reader-facing behavior. Each threshold and named reason must map to stable copy and feature availability; Low-confidence conclusions must be withheld.
- Test Active Time with overlapping Task Trees, nested agents, waits, polls, missing completion, reconnects, and clock-order errors. Verify overlaps count once.
- Test Concurrency as a time series for overlapping roots, child agents, idle threads, and incomplete end events.
- Test Usage Receipt boundaries for one root Task, nested agents, shared Project grouping, missing ancestry, review or guardian items omitted by the source, and effective model differing from requested model.
- Test `Usage per token` against the median of exactly four prior complete High-comparability weekly windows and a pinned qualifying baseline. Cover High, Medium, and Not comparable states, partial bounded intervals, account change, non-weekly windows, an unknown reset, zero account token activity, workload-mix shifts at each threshold, and insufficient history.
- Test Equivalent Capacity as an estimate with range and Confidence. Verify that no output or copy calls it a token allowance or weekly token limit.
- Test Usage Deviation against personal baselines and minimum sample density. Verify that no notification is scheduled and no copy claims `billing error` or `limit reduction`.
- Test Codex-assisted action states through an injected analyzer: hidden when the exact GPT-5.6 Luna Medium profile is absent or catalog lookup fails, idle when it is present, information tip, metadata request, Source Content preflight, cancel, Luna Medium execution, failure, explicit stronger retry using an advertised profile, result marking, and Analytics Overhead. Verify that GPT-5.5 Medium and every other model or reasoning profile remain ineligible as an automatic fallback.
- Verify that Metadata-only Analysis sends no Source Content fields. Verify that Source-backed Analysis sends only categories listed in the accepted preflight.
- Verify that the analyzer task receives no tool access, cannot read files, and cannot mutate the workspace or control another Task.
- Test local storage migration from current 90-day files to unlimited, account-partitioned retention and atomic failure recovery. `Delete analytics history` must remove all local Derived Records and every Codex Limits account-history generation in the selected sync folder while preserving preferences. Cover an unavailable sync folder, pending deletion, blocked stale import, another Mac attempting to republish old data, no automatic rebuild, and a separate explicit rebuild from sources that still exist.
- Test source isolation: failure of account reads must not erase Local Activity; failure of local parsing must not erase account facts; a malformed history file must not replace valid history.
- Add view-level tests for a persistent current-state header; `Graphs`, `Facts`, and `Insights` navigation; screen-aware height and small-display reflow; persistent but source-scoped filters; empty and stale states; complete and partial reset copy; destructive confirmation; and visible provenance.
- Add accessibility checks for keyboard focus order, button labels, chart summaries, selected-point text, contrast, Dynamic Type behavior where macOS supports it, and reduced-motion behavior.
- Add performance fixtures representing years of compact history and thousands of Tasks. Verify bounded incremental reads, no full-history scan on ordinary refresh, and responsive snapshot publication.
- Run the existing Swift test suite throughout migration. Existing forecast, client, and history behaviors remain regression requirements unless this PRD explicitly replaces them.

## Out of Scope

- Redeeming or automatically applying a banked reset.
- Changing Codex account, model, reasoning, or application settings.
- Starting, stopping, pausing, resuming, or routing user Tasks or agents.
- Automatic or scheduled Codex-assisted analysis.
- Falling back from GPT-5.6 Luna Medium to GPT-5.5, Terra, Sol, another reasoning level, or an inherited Task profile.
- Product telemetry, a hosted analytics backend, or uploading Analytics History.
- Expanding optional folder sync to Task Tree, agent, model, Source Content-derived, or Codex-assisted records.
- Treating local token activity as billing, included-plan cost, or an exact account charge.
- Claiming that OpenAI reduced a limit or changed pricing based only on observed Allowance Intensity.
- Publishing a fixed `runtime/week`, token entitlement, or guaranteed number of hours.
- Replacing the weekly allowance view with a five-hour or model-specific window when the weekly window is unavailable.
- A universal efficiency score or automatic judgment that lower usage means better work.
- Automatic outcome scoring from prompts, code, or responses.
- Repeated anomaly notifications or `Time Sensitive` reset notifications by default.
- A custom Project hierarchy, project aliases, or inferred topic grouping.
- Retaining copied Source Content in the analytics store.
- Automatically rebuilding Analytics History after the user deletes it.
- App Store distribution, notarization, a public installer, automatic updates, or support outside macOS in this PRD.

## Further Notes

- This PRD covers the full agreed product, not a reduced first release. Work may be ordered by dependency, but every capability above remains part of acceptance.
- The product is independent and unofficial. It must keep that statement visible in project documentation.
- The highest-confidence user needs are banked-reset visibility, an expiry reminder, Runway, Suggested Pace, reset-aware history, and source confidence. The full scope adds local observability without weakening those facts.
- The main technical risk is source incompleteness. Account data can include activity from another device; local records can be missing, deleted, lossy, or changed by Codex versions. The product response is provenance, Local Coverage, Confidence, and graceful withholding—not forced reconciliation.
- [The measurement contract](../MEASUREMENT-CONTRACT.md) is normative for Coverage, Confidence, comparability, account boundaries, and deletion semantics. Reader-facing features must not define weaker local rules.
- The Local Activity spike selected stable state-database-only Task discovery plus incremental rollout JSONL, proved cursor and replay behavior on synthetic fixtures, and set measured overhead budgets. It did not prove compatible account and local token definitions, so the product ships local breakdowns with numeric Local Coverage and token-denominated Unattributed Movement unavailable for Codex CLI 0.145.0.
- The second technical risk is local overhead. A persistent app-server session, incremental cursors, partitioned Derived Records, and one analysis engine are required to keep observation lighter than the Codex work being observed.
- Relevant upstream work: [shiptomorrow/codex-limits](https://github.com/shiptomorrow/codex-limits), the [Codex app-server account API](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#account-api), and the [Codex app-server protocol](https://github.com/openai/codex/tree/main/codex-rs/app-server-protocol).

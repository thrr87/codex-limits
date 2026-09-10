# Multi-integration workspace

Status: Needs revision — eligible Claude observation, all-enabled idle comparison, and lifecycle soak remain release gates

Development is not blocked. This status postpones release acceptance only; implementation, local testing, and documentation continue normally.

## Destination

The multi-integration model covers Codex, Claude Code, Grok, and OpenCode without pretending that they expose equivalent data. The v1 development workspace presents Codex, Claude Code, and Grok. Claude Code and Grok are opt-in Beta Integrations; release acceptance remains subject to the gates below. OpenCode remains a future Integration until a supported lighter source passes the same functional, privacy, and performance gates. Users choose which shipped Integrations participate and which single Integration metric appears in the menu bar. Disabled Integrations perform no automatic source collection. Enabled Integrations collect only what their visible or explicitly selected capabilities require.

The product remains passive analytics. A fresher value is never worth noticeable CPU, memory, disk, network, process, or UI cost.

The 2026-08-22 spike conditionally accepted Claude Code and rejected the OpenCode local-server collector after measuring approximately 736 MiB RSS and 66 MiB of initialization writes. Its Grok exclusion was based on the bare method `x.ai/billing`, which is not the ACP wire name. On 2026-09-10, official Grok Build 1.0.25 returned an authentication-required response for `_x.ai/billing` in an isolated environment without a login and valid billing data with CLI-managed authentication. Grok is restored to the development scope through that read-only route. The historical 1.0.5 binary has not been retested with the corrected method, so no claim is made about its support.

Codex Limits reads no Grok credentials or browser sessions, calls no private billing backend directly, and parses no TUI. Claude’s implementation checks and historical Codex-plus-Claude idle comparison remain evidence for their original scope. An eligible Pro/Max Claude observation, a new all-enabled idle comparison covering Grok, provider-owned Grok startup-write measurement, and the eight-hour lifecycle soak remain release work. See [current Grok validation](../research/grok-build-validation-2026-09-10.md) and the [historical validation spike](../research/multi-integration-v1-validation-spikes-2026-08-22.md).

## Confirmed decisions

- Codex keeps its deeper Graphs, Facts, and Insights where Codex-specific evidence supports them.
- Claude Code and Grok have Usage remaining burndown charts and estimates based on their own recorded allowance observations. Claude's seven-day and five-hour windows and Grok's weekly and monthly periods remain distinct; no past allowance is manufactured.
- Claude Code, Grok, and OpenCode show only capabilities supported by their own sources; the UI does not manufacture provider parity.
- Grok is compiled into the development build as an opt-in Beta using the official CLI’s read-only ACP billing extension. OpenCode is absent because its validated local-server source violates the performance contract.
- Users enable and disable each Integration independently in Settings.
- New installations enable Codex only and select `Codex — Weekly usage remaining` as the menu bar metric. Existing installations migrate to the same selection so current behavior is preserved.
- Codex can be disabled. Codex Limits remains usable with any subset of Integrations, including none.
- Integration enablement, executable selection, setup, readiness, and menu bar selection are device-local settings. They are not synchronized between Macs.
- v1 has one switch per Integration. Overview and detail contents are fixed per Integration; v1 does not expose capability-level visibility switches.
- The user selects exactly one Enabled Integration metric for the menu bar, or `None`. The menu bar never combines metrics.
- Unsupported capabilities are omitted instead of displayed as zero or as a temporary source failure.
- A disabled Integration performs no automatic polling, process launch, file scan, import, or network request. A bounded availability check explicitly initiated from Settings is the only exception.
- Disabling preserves app-owned snapshots, recorded allowance history, and user preferences. Active source hooks must be deactivated when Codex Limits owns their exact configuration. Data removal is a separate explicit action.
- UI work follows the `emil-design-eng` principles: native controls, purposeful copy, immediate feedback, stable layout, restrained motion, reduced-motion support, and animation limited to `transform` and `opacity` when animation is justified.
- Ordinary refresh must not make the Mac feel busy. Every collection job is bounded, cancellable, serialized, and measured.

## User control over displayed data

Settings separates two choices:

1. **Enabled Integrations** decide which products appear in `All` and workspace navigation.
2. **Menu bar metric** selects one fixed, named metric from an Enabled Integration or `None`.

The menu bar picker contains only currently Enabled Integrations supported by this build. The OpenCode row below is a deferred contract and remains absent:

| Picker value | Displayed metric |
|---|---|
| `None` | App icon without a numeric value |
| `Codex — Weekly usage remaining` | Weekly Codex Usage remaining |
| `Claude Code — 7-day usage remaining` | Last observed seven-day Usage remaining |
| `Grok — Current-period usage remaining` | Weekly or monthly Usage remaining returned by Grok Build |
| `OpenCode — 7-day local tokens` | Rolling seven-day Local Token Activity using compact `K` or `M` notation |

The contents of `All` and Integration detail views are intentionally fixed in v1. They show the strongest supported facts defined below; users do not configure individual cards or fields.

## Settings and Integration lifecycle

Settings uses one native row per Integration. Each row contains the Integration name, `Beta` when applicable, an actionable readiness state when needed, and its switch. A healthy Integration does not add decorative status copy outside Settings.

Opening Settings renders cached readiness immediately. Once per Settings presentation, executable existence checks may run sequentially as cheap file metadata reads. Settings does not launch every CLI. Version, authentication, server, or capability probes run only after the user enables that Integration or selects its explicit `Set up`, `Check again`, or `Locate…` action. These probes use the same serialized work coordinator as collection and are cancelled when no longer needed.

Codex Limits checks known native installer and Homebrew locations without starting a login shell. If an executable is elsewhere, `Locate…` lets the user select it explicitly. The selected executable must be a regular executable file. Detection never reads credentials and never enables an Integration.

| Enabled | Readiness | Reader behavior | Available action |
|---|---|---|---|
| No | Cached status only | Omitted from `All` and navigation | Enable |
| Yes | `Checking` | Cached snapshot if one exists; otherwise a stable placeholder | Cancel by disabling |
| Yes | `Not found` | Integration destination shows one setup message | `Locate…` or install instructions |
| Yes | `Set up` | Integration destination shows one setup message | Provider-specific `Set up` |
| Yes | `Waiting for data` | No numeric zero; explain how the first observation appears | Provider-specific guidance |
| Yes | `Ready` | Show cached facts immediately | Optional provider-specific refresh |
| Yes | `Update required` | Keep the last compatible snapshot stale | Update instructions |
| Yes | Specific error | Preserve the last valid snapshot when still meaningful | `Check again` or setup repair |

State transitions follow these rules:

- Enabling makes the Integration visible immediately, even when setup or data is pending, so the action has an observable result.
- Disabling cancels queued and active jobs, deactivates exact app-owned source hooks, removes the Integration from `All` and navigation, and preserves snapshots and preferences.
- Disabling the current menu bar source selects `None`; Codex Limits never silently selects another source.
- Disabling the currently visible Integration returns the workspace to `All`.
- With no Enabled Integrations, the menu bar shows only the app icon and the workspace shows `No integrations enabled` with `Open Settings`.
- Re-enabling may reuse a compatible cached snapshot but must evaluate its current Freshness before display.

## Workspace navigation

Navigation is `All` followed by every Enabled, shipped Integration in stable product order. v1 therefore offers `Codex`, `Claude Code`, and `Grok`; the future order continues with `OpenCode`. Disabled or deferred Integrations are absent. Integration details share a simple header, remaining allowance, reset, and primary chart. Codex keeps pace and runway under `Usage details`; its `More` menu retains the supported graphs, Facts and reset reminders, Insights, and available updates.

`All` is a compact Integration Overview. It uses one cohesive row style without identical placeholders. Each ready row has a primary allowance, compact reset information, and a small current-window chart on the right. Claude also includes its five-hour remainder. Freshness stays beside the facts when it changes interpretation. Rows open the corresponding detail. Thumbnails show only actual observations, their latest point, and the target; they omit estimates, axes, legends, and point controls. Setup and error rows replace facts with one short recovery action instead of adding banners or global loading UI.

The OpenCode row describes its future capability contract and is not rendered in v1.

| Integration | Overview primary | Overview secondary | Detail contract | Explicitly omitted |
|---|---|---|---|---|
| Codex | Weekly Usage remaining | Reset | Existing guidance, Graphs, Facts, and Insights | Nothing already accepted by the Codex analytics PRD |
| Claude Code | Seven-day Usage remaining | Reset and five-hour Usage remaining | Recorded seven-day and five-hour burndown history, supported allowance estimates, both resets, Last observed, and source state | Session model, session cost, local telemetry, and token-derived guidance |
| Grok | Current weekly or monthly Usage remaining | Reset | Recorded period-specific burndown history, supported allowance estimates, period, plan, available prepaid/PAYG facts, shared-pool provenance when returned, and CLI version | Grok Build local sessions and token-derived guidance |
| OpenCode | Rolling seven-day Local Token Activity | Root session count | Token categories, estimated local cost, projects, sessions, current saved provider/model, and parent/child relationships | Account allowance, provider billing claims, exact per-response model attribution; all shipped v1 surfaces |

Background updates never replace the workspace with a spinner. Cached content remains in place. Manual refresh may show a small inline progress indicator beside the initiating action. Frequent data updates do not animate or shift layout.

## Menu bar behavior

- A fresh selected metric shows its compact value.
- A stale selected metric may retain the last valid value with a non-color-only stale indicator.
- An expired allowance or a source with no valid snapshot shows an em dash, not the previous percentage or zero.
- OpenCode uses a distinct token icon and never displays a percent sign.
- VoiceOver announces the Integration, value to at most two decimal places, unit, and freshness; visual integer or `K`/`M` compaction is presentation only.
- Changing the menu bar metric publishes a compatible cached value immediately and enqueues work only when that source is due.

## Performance contract

### Scheduling

- Every reader surface publishes cached state before scheduling source work.
- Opening `All` may enqueue due allowance reads after rendering, one at a time. It never starts parallel fan-out or Local Activity import.
- On launch, the app refreshes only the selected menu bar source when due. Other Integrations wait for `All`, their detail view, or an explicit action.
- The work coordinator admits at most one active operation across availability probes, setup probes, process launches, file reads, imports, and network reads. An idle transport performs no collection but its process still counts toward process and memory budgets.
- Work priority is: explicit user action, a visible `All` or detail capability, an automatic selected-menu source, then a Settings availability check.
- Requests for the same Integration and capability coalesce. A newer generation supersedes queued work and prevents a late result from publishing.
- An explicit refresh may cancel lower-priority cancellable work. It does not start concurrently with that work.
- An in-flight request for the same Integration and capability coalesces. Provider `Retry-After` and compatibility cooldowns become mandatory if a future shipped source exposes them. Every Grok launch has a monotonic minimum interval of 30 seconds, including explicit reads. A future OpenCode collector must enforce the same floor.
- Hiding a detail view cancels work needed only by that view and releases its bounded in-memory detail cache.
- Disabling an Integration cancels its work before publishing the disabled state.

The implemented Codex account timer is armed only while Codex is Enabled and its weekly allowance is the selected menu bar source. Launch and wake perform a due check only under that same condition. Selecting another menu source or `None` cancels the timer; opening `All` or the Codex detail performs a serialized due read without re-arming background work.

### Source policy

| Integration capability | Automatic policy | Explicit action |
|---|---|---|
| Codex Account Allowance | Every 10 minutes only while selected for the menu bar; due reads from visible `All` or Codex detail | Fetch current account state |
| Claude Code Account Allowance | Event-driven `statusLine`; no app polling, recurring collection timer, or dummy prompt | Re-read relay cache; explain that new data appears during Claude Code activity |
| Grok Account Allowance | Every 10 minutes only while selected for the menu bar; due reads for enablement, visible `All`, or Grok detail; automatic failure backoff | Read current billing through the official CLI, respecting the 30-second launch floor |
| OpenCode Local Activity | Deferred; no v1 collector, polling, or process launch | Unavailable in v1 |
| Codex Local Activity | Existing visibility-gated incremental collector | Existing bounded refresh |

Claude schedules no recurring collection timer. When Claude is Enabled but neither selected for the menu bar nor visible in `All` or its detail, app launch and relay notifications do not read its settings or cache. Settings, enablement, menu selection, or visible `All`/detail creates bounded demand; hiding the workspace removes visible demand. While a valid Claude snapshot has menu or visibility demand, the app keeps at most one cancellable one-shot display task for the next Freshness or reset boundary; that task performs no source I/O and is replaced rather than accumulated. Codex uses the same one-shot display-only rule while its menu metric or workspace surface is visible, so a stale or expired value changes without an extra source read. Grok uses the same display-only boundary rule. Its collection timer exists only while the Grok menu metric is selected; when hidden and unselected it performs no automatic source work. OpenCode performs no work in v1.

Codex keeps its fixed ten-minute selected-menu cadence after an automatic failure; it never retries more frequently because of the failure. Claude is event-driven and has no automatic retry loop. Grok failures delay automatic reads by 600, 1,200, 2,400, then at most 3,600 seconds. Success resets that backoff. Explicit reads may bypass automatic backoff but never the monotonic 30-second launch floor. A future polling collector must define and test its own backoff before shipping.

### Operation and process bounds

- Every provider protocol operation has a 10-second wall deadline unless a smaller provider-specific deadline applies. Bounded local file passes use count and byte limits; the user-confirmed initial history connection remains the documented complete-reconciliation exception.
- Deadline or cancellation terminates the complete app-owned process group: request graceful exit, wait at most one second, then force termination and reap every child.
- The Codex app-server connection may be reused inside one short burst, then closes after five seconds without protocol work. The ten-minute account timer must not keep that child resident between refreshes.
- Grok starts an owned process group in a temporary empty working directory. Its entire initialization-plus-billing fetch has a ten-second deadline, followed by at most one second for graceful group termination before forced cleanup. Cancellation finishes cleanup before the shared coordinator admits another operation. No Grok child stays resident between reads. OpenCode starts no child.
- Grok rejects more than 1 MiB total stdout per fetch, discards stderr, and never persists raw output. Codex JSONL responses are streamed with an 8 MiB line cap. A future captured provider stream must also remain bounded.
- A decoded HTTP or RPC response is rejected above 8 MiB. Provider-specific lower bounds remain preferred.
- Codex Local Activity keeps its per-pass maximum of 10,000 lines or 8 MiB and continues incrementally outside the main actor.
- A future OpenCode source may publish at most the 500 newest sessions in the rolling seven-day range. Fetching all sessions and truncating locally is not acceptable.
- A future OpenCode source never requests messages or parts. The validated `--pure` local-server method is rejected for v1 because it failed memory, initialization-write, and random-port requirements.
- Grok Build local history is outside v1 and performs no local scan.
- Claude relay input is capped at 256 KiB. The relay validates and writes only its bounded allowlist using an atomic, ordered update; raw stdin is never stored or logged.
- Source reads, process management, decoding, aggregation, and persistence run outside the main actor. The main actor only publishes a bounded immutable reader snapshot.

### Bounded history and memory

Unlimited allowance-history retention applies to compact on-disk canonical stores, not to resident memory. Before multi-integration implementation is accepted:

- `UsageMonitor` and reader snapshots must stop retaining every historical sample;
- ordinary refresh and periodic sync must not enumerate or decode the complete history;
- range views request only their bounded interval and resolution;
- long-term charts use bounded summaries or downsampled points;
- Local Activity detail caches are released when their capability becomes hidden;
- adding years of history must not proportionally increase steady-state RSS or ordinary refresh CPU time.

The implemented default Codex reader path keeps at most 6,000 samples from the latest 84 days in memory. It preserves full resolution for the latest eight days and keeps the first and last observation per older hourly/reset bucket plus explicit comparison breaks. Canonical files remain subject to the existing unlimited-retention and deletion contract.

Claude Code and Grok retain separate compact UTC daily observation journals until explicit deletion. Their active reader covers the exact latest 84 days by at most 85 direct daily paths, with ceilings of 4 MiB per file, 32 MiB total, 512 bytes per record, and 200,000 decoded records. The reader does not downsample or enumerate older history; malformed committed records and exceeded bounds produce an explicit history failure. Each journal append writes at most 64 records, uses a cross-process lock, and limits tail recovery and deduplication to about 33 KiB. App-owned history directories use `0700` permissions and files use `0600`. Prior latest-only caches seed their actual observation time and available windows only. Retention does not imply synthetic earlier points or cross-device sync.

The Codex default working set matches the longest preset (`12 weeks`). Its implemented explicit range reader can separately load any requested interval up to 84 days, returns retained and covered bounds, caps the result at 6,000 samples, marks it `exact` or `downsampled`, checks cancellation between files, and leaves canonical data outside the resident window reachable. A cold default or explicit-range read considers at most 32 writer partitions, reads at most 256 daily files and 8 MiB, and reports partial history if any ceiling is reached. Older-range source work starts only from the visible Codex graph's `Earlier` action and is cancelled and released when hidden.

The implemented bounded reconciliation in ADR-0014 replaces complete work on periodic and explicit refresh. It examines at most 32 calendar-day candidates and reads at most 32 daily files across all writers, prioritizes recent changes, persists round-robin backlog progress across relaunch, avoids rewriting unchanged days, and preserves generation/deletion behavior. Only a user-confirmed initial folder connection may perform one complete reconciliation outside the main actor.

### Provisional release budgets

Budgets are measured in a Release build on supported Apple Silicon hardware after a ten-minute warm-up. The provider and performance spikes may tighten these values; relaxing them requires an explicit ADR.

| Measure | v1 gate |
|---|---|
| Cached workspace publication | p95 below 100 ms |
| Main-thread refresh work | No uninterrupted work longer than one display frame |
| New-integration idle RSS, all enabled with Codex selected and detail hidden | No more than 10 MiB above the Codex-only baseline |
| Idle CPU regression in the same state | Less than 0.2 percentage points averaged over 30 minutes |
| New-provider child processes in the same state | Zero |
| Recurring new-provider collection wakeups in the same state | Zero |
| Display-only boundary tasks | At most one per demanded shipped Integration with a valid snapshot; zero while disabled or hidden and unselected |
| Eight-hour mixed lifecycle soak | RSS no more than 5 MiB above its post-warm-up value; process count returns to baseline after every operation |
| Ten-year compact Codex fixture versus 90-day fixture — peak RSS | Difference no greater than 10% or 10 MiB, whichever allowance is larger |
| Ten-year compact Codex fixture versus 90-day fixture — ordinary refresh | Difference no greater than 10% or 10 ms, whichever allowance is larger |
| Automatic collection CPU time | p95 below one second for the app and its child process combined on accepted fixtures |
| Disabled Integration | Zero automatic source operations and zero app-owned live child processes |

The canonical idle comparison uses `Scripts/measure-app-idle.sh PID 2400 10 OUTPUT.csv` once per state. The first 60 samples are the ten-minute warm-up and the final 180 samples are the 30-minute measurement window. The raw CSV records parent and direct-child RSS, CPU, and child count; a shorter run is diagnostic only and cannot satisfy this gate.

The soak covers repeated workspace open/close, Integration switching, explicit refresh, enable/disable, network failure, malformed data, CLI timeout, and sleep/wake. No collection, cache, timer, retained task, file descriptor, or child-process count may grow with repetition.

### Canonical eight-hour lifecycle soak

The soak uses a signed Release QA build with its isolated bundle identifier, defaults suite, Analytics History, Claude settings fixture, and Integration data directory. It must not read or modify the production app's preferences or the user's real Claude settings. Enable Codex and every Integration eligible to ship in the tested build, select the Codex weekly menu metric, leave Settings closed between actions, and begin with no provider child process.

Run `Scripts/measure-app-idle.sh PID 29400 60 OUTPUT.csv`. Samples 1–10 are the ten-minute warm-up; samples 11–490 are the eight-hour measurement. At the end of warm-up and after each hourly cycle, separately record the app's open-file count and the QA data directory's file count and byte size. These checkpoint reads run only nine times and are not a recurring app workload.

Perform one settled lifecycle cycle in each measured hour:

1. open and close the workspace three times, then visit `All`, `Codex`, `Claude Code`, `Grok`, and `All`;
2. request one explicit Codex refresh and wait for its bounded app-server burst to finish;
3. disable, re-enable, and set up Claude Code using only the QA fixture paths, then deliver one accepted bounded relay fixture and one malformed fixture;
4. exercise Grok selection, refresh, disable/re-enable, failure recovery, and malformed/timeout responses through a bounded test CLI, respecting its thirty-second launch floor; keep fixture provider state separate from the user’s Grok installation;
5. wait 20 seconds — the ten-second source deadline, five-second Codex idle release, and five-second observation margin — before taking the checkpoint.

One hourly cycle must span a user-confirmed real network-unavailable/recovery event, and another must span a user-confirmed real sleep/wake event. Synthetic notifications, virtual clocks, or disconnecting the user's network without confirmation cannot satisfy those two checks. The Grok CLI-timeout cycle is now required. Deferred OpenCode is not included or simulated through another Integration. Real Grok account-source measurements complement the fixture soak and must not be replaced by fixture results.

The soak passes only when the mean parent RSS of samples 481–490 is no more than 5,120 KiB above the mean of samples 11–20, every child-process count returns to its post-warm-up baseline within the 20-second settling boundary, and the settled file-descriptor, app-owned file, and cache counts do not grow across the eight cycles. Swift timer and task inventories are not observable through `ps` or `lsof`; their bounded/cancelled state requires the deterministic lifecycle tests and code invariant in addition to the soak's observable no-wakeup and no-growth evidence. Any crash, orphan process, missed cancellation, unbounded file/cache growth, or required use of production provider settings fails the gate.

## Freshness and allowance lifetime

Freshness describes observation age and source availability. Allowance lifetime additionally respects the known reset boundary.

The OpenCode row below is a future contract. Freshness windows are separate from collection schedules.

| Integration | Fresh window |
|---|---:|
| Codex | 15 minutes |
| Claude Code | 30 minutes |
| Grok | 30 minutes |
| OpenCode | 15 minutes |

| State | Behavior |
|---|---|
| `Fresh` | Show the latest valid value normally |
| `Stale` | The observation exceeded its Freshness window but remains inside the same known allowance period; retain it with age and stale indication |
| `Expired` | A known allowance reset has passed without a post-reset observation; hide the old percentage and show that a new observation is needed |
| `Unavailable` | No valid compatible observation exists; show a specific setup or source reason, never zero |

Claude always labels its allowance `Last observed`. A failed refresh never erases a still-meaningful snapshot. No provider may carry a numeric allowance value across its known reset boundary.

## Provider measurement gates

### Claude Code

- Map each independently present `used_percentage` to `remaining = 100 - used` only after finite-range validation.
- Missing five-hour or seven-day data does not create zero.
- Multiple relay processes serialize atomic writes. The event with the newest receive time wins even if an older process finishes later.
- v1 retains allowance observations on this Mac and shows seven-day and five-hour burndown history separately. Neither stable account identity nor continuity across an unobserved account change is claimed.
- Enabling explains that a configured custom status line changes Claude Code's footer and runs a local command during Claude activity. Setup requires confirmation.
- Settings and the setup confirmation state that allowance data requires an eligible Pro or Max account. A Free account waiting without a snapshot is an expected unsupported-plan state, not a zero allowance or a collector failure.
- Setup reads and writes only the user settings file. An existing user `statusLine` is never overwritten or automatically wrapped. Codex Limits does not scan project, local-project, or managed settings; those higher-precedence scopes remain untouched, may override the user status line, and are named in the setup confirmation. Manual composition remains user-owned.

The packaged implementation uses a 256 KiB input cap, a 64 KiB cache cap, an atomic `0600` allowlisted snapshot, cross-process ordering, and a 30-second equivalent-write floor. An eligible allowance produces the compact usage footer; an event with no allowance produces the neutral `Usage unavailable` footer without writing a snapshot. Setup, exact removal, changed-configuration preservation, app-owned data deletion, executable selection, and suppression of superseded lifecycle results have deterministic tests. Codex and Claude source work share one priority-aware coordinator, so background collection cannot overlap an Integration action.

### Grok

- Use the official user-managed CLI: `grok agent --no-leader stdio`, then sequential `initialize` and `_x.ai/billing` requests. The underscore is required on the ACP wire. Create no coding session, send no prompt, and invoke no authentication flow. CLI-managed login remains outside Codex Limits.
- Prefer `creditUsagePercent` and `currentPeriod`; legacy `monthlyLimit`, `used`, and `billingPeriodEnd` apply only when both current fields are absent. Present-but-invalid current data does not fall back to legacy values.
- Preserve the finite original used percentage as `reportedUsedPercent`, clamp only for display, and retain `measurementSource` (`creditUsagePercent` or `legacyCredits`). Missing allowance and zero legacy limit are unavailable; a present empty Cent object is a valid zero monetary value.
- Accept exact weekly and monthly source period types. Validate supported finite reset timestamps, including fractional seconds and UTC offsets. Retain optional provider-reported `currentPeriod.start` or legacy `billingPeriodStart` only when it is supported, finite, and earlier than reset; a missing start remains absent. Never infer a monthly start from a fixed duration. A valid past reset remains an expired cached observation. Unknown periods, invalid resets, missing configuration, authentication failure, unsupported method, timeout, and incompatible schema have safe distinct errors.
- Prepaid, on-demand, subscription-tier, and unified-pool fields are optional Account Facts. Missing fields remain absent and never replace the current-period allowance. A shared-pool percentage is not attributed solely to Grok Build.
- Obtain source version from initialization metadata (`_meta.agentVersion`), without a separate version process on every read. Bound and sanitize optional display strings.
- Official stable 1.0.25 passed a real authenticated read on 2026-09-10. The probe used 77,578,240 bytes maximum transient child RSS, 0.208 seconds child CPU, 4,349 stdout bytes, and no stderr; wall time including cleanup was 1.984 seconds. No model request was made, and the owned process group stopped with SIGTERM. Live provider-owned initialization writes have not yet been quantified.
- The complete Grok/Claude history and chart implementation passed the 640-test Release suite on 2026-09-10 with zero failures. This includes source/date validation, bounded journal reads and locks, lifecycle and deletion races, actual-only history, and compatible-observation forecasts. Signed native QA verified both providers’ charts, point selection, zoom, and separate range state using synthetic observations. All-enabled performance/lifecycle gates and an eligible live Claude observation remain separate checks.

See [Grok validation and local test steps](../research/grok-build-validation-2026-09-10.md).
### OpenCode

This section is a deferred compatibility contract, not v1 implementation scope.

- Rolling seven days is the exact 604,800 seconds ending now.
- Local Token Activity is the sum of finite non-negative `input`, `output`, `reasoning`, `cache.read`, and `cache.write` counters after the spike confirms they are disjoint cumulative categories.
- Root session count excludes child sessions; detail may show the complete bounded parent/child set.
- Parent and child totals are not added until the spike proves they are not already inclusive.
- A missing or invalid cost is unavailable, not zero. Visible cost is `OpenCode local estimated cost` and never billing.
- Session provider/model is labeled as the currently saved session selection. Exact multi-model attribution is unavailable without messages and remains outside v1.
- The tested `1.18.11` server proved a count bound and complete process cleanup but failed the performance and source-mutation gates. Production stays deferred until another supported interface also proves counter behavior after compaction/fork/archive/delete, source equivalence, bounded writes, and the release budgets.

## Retention and identity

- Codex keeps its accepted on-disk Analytics History, account partitions, sync, forecasts, and deletion semantics while adopting the bounded-memory requirements above.
- Claude Code and Grok retain their latest valid Integration Snapshot plus compact allowance observations until `Delete integration data`. Each latest snapshot has a 64 KiB bound. Their bounded detail history views cover the latest 84 days without deleting older records. `All` reads only the current period, capped at 31 elapsed days / 32 UTC files, and retains at most 256 display points per thumbnail; raw history is released after conversion. Hidden views and menu-only demand do not load thumbnail history. Source polling cadence is unchanged.
- Every chart point is a recorded observation. A previous latest-only cache seeds its one observation and supported windows; unavailable earlier history remains unavailable. Repeated cache reads never invent new observation times.
- Claude Code, Grok, and any future OpenCode integration use separate Local Installation Partitions. They do not sync between Macs or support cross-device comparisons. Stable provider account identity is unavailable for Claude and Grok, so recorded history does not establish account continuity through an unobserved login change.
- Claude and Grok estimates need at least two compatible observations spanning at least 60 seconds, a latest reading within 30 minutes and before reset, and no intervening gap over 30 minutes, reset, source change, or correction. Unsupported estimates remain withheld. Allowance charts never substitute token, cost, or session activity for allowance readings.
- A future OpenCode integration retains only a bounded rolling seven-day cache of at most 500 sessions.

## Privacy, diagnostics, and deletion

The OpenCode row is a future allowlist and does not authorize v1 collection.

| Integration | App-owned data allowed |
|---|---|
| Claude Code | Latest allowance windows and recorded observations, fixed window durations and starts, resets, receive time, and CLI version |
| Grok | Latest original finite used percentage and recorded remaining observations, period, provider-reported start when present, reset, measurement source, optional plan/prepaid/PAYG/unified-pool facts, observation time, and CLI version |
| OpenCode | Session identifiers and times, aggregate tokens and estimated cost, current saved provider/model, parent relation, keyed project identity, and short project name |

Codex Limits does not persist Claude model/session/cost, prompts, responses, OpenCode messages or parts, tool output, credentials, auth files, raw provider responses, child-process output, or full project paths for these Integrations. The same allowlist applies to logs and crash diagnostics. Diagnostics retain only the latest bounded redacted reason per Integration.

`Delete integration data` is available for Claude Code and Grok; OpenCode remains deferred. It first disables the Integration and cancels its work, then deletes its app-owned snapshot, retained allowance history, Derived Records, cache, executable preference, and exact Codex Limits-owned source configuration. It never deletes records owned by the integrated product. Grok deletion removes its app-owned snapshot, history, and executable preference after disable/cancellation; it preserves Grok Build’s files, settings, and login. Codex continues to use the separate `Delete analytics history` contract.

Disabling Codex pauses its account timer, local collection, history exchange, and new Assisted Insights work; it cancels any scheduled Reset Reminder. It preserves Codex history, sync preference, snapshots, and analytics settings for re-enable.

## Source setup

- **Claude Code:** setup may install the Codex Limits relay in user settings only when that file has no `statusLine` and after showing the footer consequence, possible higher-scope override, and eligible-plan requirement. The app-created relay outputs a useful minimal status line rather than a blank row. Disable or deletion removes the active config only when it still exactly matches what Codex Limits created; if setup created an otherwise empty settings file, exact removal deletes that file. Project, local-project, and managed settings are never scanned or modified. For manual user-owned composition, disabling stops app data writes through the enabled marker but cannot prevent Claude from invoking the user's command; Settings must explain how to remove that composition completely.
- **Grok:** enable its Beta Integration in Settings. Detect `~/.grok/bin/grok` and known Homebrew paths through file metadata, or select a regular executable with `Locate…`. Billing reads use the official CLI’s `_x.ai/billing` route. Missing login directs the user to `grok login`; the app starts no login flow, reads no auth files or cookies, and never calls the private billing backend directly. Disable cancels collection and preserves the cache; deletion removes only app-owned Grok data and its executable preference.
- **OpenCode:** no source setup ships in v1. The rejected local-server method, ambient TUI servers, auth-file reads, and direct internal-database reads are not fallbacks. A future source must be official, read-only, bounded, and independently measured.

## UX and accessibility acceptance

- Every switch and action is reachable with keyboard navigation and has a VoiceOver label and current value.
- Fresh, stale, expired, waiting, and error states are not distinguished by color alone.
- Cached rows keep stable dimensions while refreshing; no skeleton replaces valid data.
- Keyboard-initiated navigation and frequent data updates do not animate.
- Optional motion respects Reduce Motion and never delays interaction.
- Compact menu values expose full values and units to accessibility APIs.
- Visible UI contains no implementation notes, fixture names, debug output, or internal provider errors.

## Testing decisions

- Test new install, existing-install migration, all-disabled state, device-local preferences, menu source selection, selected-source disable, visible-source disable, and re-enable with stale cache.
- Test every readiness transition and recovery action without global loading UI.
- Test Fresh, Stale, Expired, and Unavailable around exact reset boundaries and clock/time-zone changes.
- Test in-flight request coalescing, priority, cancellation, generation guards, deadlines, rapid clicks, display-only boundaries, and late results. Grok tests additionally cover selected-menu cadence, automatic failure backoff and reset, the monotonic launch floor, and hidden/unselected suppression.
- Test zero automatic source operations for disabled Integrations, including after launch, wake, Settings close, and app relaunch.
- Test Claude missing windows, invalid percentages, concurrent relays, out-of-order completion, exact install/uninstall including a previously absent user settings file, data deletion, user-settings conflicts, and user-owned composition. Keep higher-scope settings outside the app's read boundary and test their override explanation as UI copy.
- Complete one eligible-account observation using a user-intended Claude Code response: confirm at least one supported allowance window reaches the allowlisted cache and UI, `Check for new observation` performs only a cache read, and disable restores only the exact Codex Limits-owned setup. Do not create a dummy prompt or retain account, session, model, prompt, response, transcript, or project evidence.
- Run Grok schema, protocol, process-group cleanup, timeout/cancellation, output-bound, cache/deletion, and lifecycle tests. Keep real account observations out of deterministic fixtures and public diagnostics.
- Test provider history across restart, repeated-cache deduplication, old-cache seeding, concurrent Claude writes, window/period and source separation, resets and corrections, gaps, exact forecast boundaries, optional Grok starts, bounded active reads, disable/re-enable, and explicit deletion. A single seeded observation must never produce a fabricated past or forecast.
- Preserve OpenCode aggregation fixtures, but run full server-side and lifecycle suites only when a future supported lighter source reopens the Integration.
- Test logs, persistence, and crash diagnostics against the privacy allowlists.
- Run the provisional release budgets on compact histories representing 90 days and ten years, every shipped Integration fixture at its accepted bounds, and the eight-hour lifecycle soak.

## v1 release boundary and gates

Claude Code and Grok are opt-in `Beta` Integrations in the development build; release acceptance waits for the remaining gates. OpenCode remains deferred. `Beta` appears in Settings and the Integration detail header, not beside every value. Grok also displays CLI-version provenance because its custom ACP billing extension is not a versioned public billing API.

| Release gate | Current evidence | Status |
|---|---|---|
| Grok and OpenCode source decision | Grok 1.0.25 accepts correctly prefixed ACP billing with CLI-owned authentication; OpenCode remains excluded by RSS/write budgets | Passed |
| Bounded Codex history and serialized demand-driven collection | 3,650-day fixture, 32-candidate reconciliation, idle process release, deterministic lifecycle tests | Passed |
| Claude relay, setup, privacy, deletion, executable selection, and boundary behavior | Packaged helper checks and deterministic Release tests | Passed |
| All-enabled idle comparison | Historical Codex-plus-Claude comparison passed; repeat with Grok enabled and quantify live provider-owned startup writes for the expanded scope | Pending |
| Eligible Claude account observation | Requires one user-intended response from a consenting Pro or Max tester | Pending |
| Eight-hour mixed lifecycle soak | Requires the user-confirmed network and sleep/wake cycles defined above | Pending |

`Scripts/validate-release.sh` rejects a release while this document is not exactly `Accepted for v1 implementation`. Passing deterministic tests or the short idle comparison cannot change that status; all Pending rows must have recorded evidence first.

Implementation progress before release acceptance is:

1. bounded Codex default reader, older-range access, eventual sync, and baseline measurements — implemented and measured on 2026-08-22;
2. shared Integration state, device-local Settings, menu metric selection, and serialized source work — implemented and deterministically tested on 2026-08-22;
3. Claude Code allowance, setup, exact disable, and app-owned data deletion — implemented, packaged, and deterministically tested on 2026-08-22; end-to-end eligible-account and lifecycle release checks remain;
4. Grok billing transport, validated snapshot model, Settings/workspace/menu integration — implemented on 2026-09-10, including retained Grok/Claude history and burndown charts, with a successful compiled collector read and 640 passing Release tests; signed native chart QA passed; expanded performance gates and eligible Claude observation remain;
5. OpenCode remains deferred until a supported lighter source passes its gates.

The PRD returns to `Accepted for v1 implementation` only when:

- provider spikes pass or narrow the scope explicitly; Grok has a working authenticated ACP source and OpenCode remains narrowed out of v1;
- the Codex-only baseline and expanded all-enabled budgets are reproducible; the 2026-08-22 Codex-plus-Claude comparison does not cover Grok, and the new idle comparison, provider-owned writes, and eight-hour soak remain release work;
- bounded Codex history has accepted default-reader, older-range, and eventual-sync implementation paths;
- provider measurement rules have deterministic fixtures;
- no open lifecycle, privacy, accessibility, or data-selection decision remains.

v1 excludes Claude and Grok OpenTelemetry, Grok Build Local Activity, OpenCode Go allowance, Claude Organization analytics, xAI API team billing, new Assisted Insights runners, per-capability visibility switches, and user-configurable Overview cards.

## Normative references

- [Domain language](../../CONTEXT.md)
- [Measurement contract](../MEASUREMENT-CONTRACT.md)
- [Product language](../PRODUCT-LANGUAGE.md)
- [CodexBar method comparison](../research/codexbar-method-comparison-2026-08-21.md)
- [Current Grok validation](../research/grok-build-validation-2026-09-10.md)
- [Historical v1 validation spike results](../research/multi-integration-v1-validation-spikes-2026-08-22.md)
- [Demand-driven bounded collection](../adr/0012-demand-driven-bounded-integration-collection.md)
- [Capability-driven Integration surfaces](../adr/0013-capability-driven-integration-surfaces.md)
- [Bounded range and eventual history reconciliation](../adr/0014-bounded-range-and-eventual-history-reconciliation.md)

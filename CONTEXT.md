# Codex Usage Analytics

This context describes how Codex Limits represents account allowance and local activity from supported coding-agent integrations, while preserving the deeper Codex guidance and analytics that require Codex-specific evidence.

## Language

**Integration**:
A user-managed coding-agent product that Codex Limits observes through an official local interface. An Integration may expose account allowance, local activity, or both.
_Avoid_: Vendor, provider when referring to the whole integrated product

**Enabled Integration**:
An Integration the user has chosen to include in Codex Limits. Only Enabled Integrations may perform source work or appear in the Integration Overview; enabling one does not imply that every Integration Capability is supported or currently available.
_Avoid_: Installed integration, detected integration, active provider

**Integration Snapshot**:
The latest normalized observation for one Integration and capability, carrying its source, source version, observed time, and Freshness. A snapshot never combines unlike facts from multiple Integrations.
_Avoid_: Combined provider state, live data when only last observed

**Integration Capability**:
A supported class of information exposed by an Integration: Account Allowance, Account Facts, Local Activity, Guidance, or Analysis. Capabilities are independent; supporting one never implies support for the others.
_Avoid_: Provider parity, reduced Codex feature set

**Unsupported Capability**:
An Integration Capability that the Integration does not expose under the current product contract. It is omitted from the reader experience rather than displayed as zero or temporarily unavailable.
_Avoid_: Missing data, zero usage, unavailable source

**Integration Overview**:
The at-a-glance surface that presents the strongest supported facts for every enabled Integration without combining unlike allowances or forcing identical cards.
_Avoid_: Combined allowance, provider leaderboard

**Menu Bar Metric**:
The single fixed, named metric selected from an Enabled Integration for display beside the menu bar icon, or None. The selection names both the Integration and quantity; Codex Limits never combines metrics from multiple Integrations.
_Avoid_: Primary provider, combined menu metric, most constrained integration

**Integration Readiness**:
The device-local ability of an Enabled Integration to produce its supported facts. Readiness describes setup and source compatibility independently from whether the Integration is enabled.
_Avoid_: Enabled when meaning ready, installed when meaning detected

**Freshness**:
The age and current availability of an Integration Snapshot relative to its source-specific policy. A failed refresh preserves the last valid snapshot and marks it stale; Freshness does not express accuracy.
_Avoid_: Confidence, live when the source is event-driven

**Expired Allowance Snapshot**:
An otherwise valid Account Allowance observation whose known reset boundary has passed without a post-reset observation. Its former percentage is not displayed as the current allowance.
_Avoid_: Stale percentage after reset, zero remaining

**Bounded Working Set**:
The fixed upper bound on history, source payload, decoded facts, and reader state kept in resident memory for the current operation or visible range. On-disk retention may grow without making the working set grow proportionally.
_Avoid_: Loading all retained history, retention limit when meaning memory limit

**Local Installation Partition**:
An on-device history boundary used when an Integration does not expose a stable supported account identity. It is never synchronized or joined with another Mac in v1.
_Avoid_: Anonymous account, shared unknown account

**Analytics Workspace**:
The unified, screen-aware product surface containing current guidance and switchable Graphs, Facts, and Insights views.
_Avoid_: Status widget, separate analytics app

**Local-only**:
A product boundary in which Codex-derived data, analysis, and derived history remain on the user’s device and are not transmitted as product telemetry.
_Avoid_: Private, anonymous cloud analytics

**Source Content**:
Prompts, responses, code, paths, commands, and tool output contained in existing Codex records.
_Avoid_: Metadata, usage data

**Derived Record**:
A compact fact, classification, aggregate, or fingerprint produced from Source Content without duplicating that content.
_Avoid_: Raw log copy, transcript

**Analytics History**:
Derived Records kept without a time limit until the user deletes them. `Delete analytics history` removes the entire store owned by Codex Limits, including account usage samples in the selected sync folder. Rebuild requires a separate user action and can restore only facts whose Codex sources remain available.
_Avoid_: Cloud history, raw archive

**Machine-local Time**:
Reader-facing dates and times shown using the Mac's current calendar and time-zone settings, including daylight-saving changes.
_Avoid_: Fixed CET, reader-facing UTC

**Rolling 24-hour Interval**:
The exact 86,400 seconds ending at the current instant on the Mac, shown in Machine-local Time. A daylight-saving transition may make its displayed clock times differ by one hour without changing its duration; stale observations do not move the interval into the past.
_Avoid_: Today, yesterday, calendar day

**Rolling Preset Range**:
A preset duration such as 3 days, 4 weeks, or 12 weeks ending at the current instant on the Mac. Available observations fill the range without moving its end to the latest observation.
_Avoid_: Preset ending at data freshness

**Selected-range Token Activity**:
Token Activity from complete Token Activity Intervals contained inside the selected interval. It may cover only part of the selected interval and never implies that missing or boundary-crossing time contained zero activity.
_Avoid_: Full-range total when observations cover only part of the range

**Observed Interval**:
The actual period between the readings that support a displayed fact. When it is shorter than the selected range, the product shows its start and end instead of replacing the fact with a coverage grade.
_Avoid_: Coverage label as a substitute for the actual period

**Token Activity Interval**:
The Token Activity measured between two account readings. A zero-token interval is an observation, while missing or future time remains empty; the product does not invent when non-zero activity occurred inside an interval.
_Avoid_: Hourly activity inferred by evenly spreading an interval total

**Allowance**:
The remaining account capacity reported for a Codex rate-limit window.
_Avoid_: Tokens, credits, balance

**Usage Remaining**:
The reader-facing percentage of Allowance that remains in a window. Codex Limits uses this orientation for every primary usage display.
_Avoid_: Usage left, allowance remaining, usage used

**Allowance Window**:
A bounded period with a reported allowance and a scheduled reset time.
_Avoid_: Subscription limit, weekly entitlement

**Current-window Range**:
The full current Allowance Window from its start through its scheduled reset. Observed series leave future time empty; the range does not stop at the latest observation.
_Avoid_: Current window to date, observed range

**Weekly Allowance Window**:
The Codex Allowance Window whose reported duration is 10,080 minutes. It is the primary window for the menu bar, current guidance, Runway, Suggested Pace, and default Usage remaining chart.
_Avoid_: Most depleted window, combined limit

**Account Movement**:
An observed change in allowance between two compatible account readings. A long interval limits knowledge of when movement happened inside it, but does not erase the known total movement.
_Avoid_: Charge, billed usage

**Allowance Break**:
A boundary created by a reset, correction, account change, or incompatible increase in Usage Remaining. No Runway pace calculation crosses it; observation restarts on its latest side.
_Avoid_: Negative allowance use, pace calculated through a reset

**Token Activity**:
The number of tokens reported for observed Codex activity, either by the account summary or by local task records. It is observed consumption, not a token entitlement, and is never projected into the future.
_Avoid_: Token allowance, token limit

**Account Token Activity**:
Token Activity reported by the account summary using one strongest available method. Lifetime-token intervals are primary; UTC Account Daily Token Buckets are a fallback and are never mixed with them in one selected-range total.
_Avoid_: Local tokens, weekly token allowance

**Account Reading Timeline**:
One chronological series of compatible readings for the same account and Allowance Window, merged from every synced installation. Installations provide additional observations of one account counter; their values are never added together.
_Avoid_: Per-Mac account totals, sum of installation counters

**Account Counter Break**:
A boundary where the lifetime-token counter decreases or readings otherwise become incompatible. No Token Activity Interval crosses the boundary; valid intervals on either side remain factual.
_Avoid_: Negative Token Activity, discarding every valid interval in the selected range

**Account Daily Token Bucket**:
Token Activity reported by the account API for a UTC calendar-day interval. It contributes to a selected-range total only when its whole interval is inside that range; changing its displayed timezone never turns it into a Machine-local calendar-day total.
_Avoid_: Local daily total, clipped daily bucket

**Current-window Token Activity**:
Selected-range Token Activity from the start of the current Allowance Window through the latest observation. While the window remains open, it is shown as activity "so far," never as a complete-window total.
_Avoid_: Complete weekly token total before reset

**Account Facts**:
Values returned directly by the account API, including lifetime tokens, peak daily tokens, longest running turn, streaks, credits, and spend-control state when available.
_Avoid_: Estimates, local diagnostics

**Local Token Activity**:
Token Activity observed in local task records and attributable to a task, agent, or model.
_Avoid_: Account total, billed tokens

**Local Coverage**:
An assessment of how much account-visible activity can be represented by local task records for the same period. It is numeric only when the source definitions and time boundaries align.
_Avoid_: Match rate, missing billing

**Allowance Intensity**:
The observed Account Movement associated with a unit of Token Activity under a particular workload mix.
_Avoid_: Token price, billing rate

**Equivalent Capacity**:
An extrapolation of how much Token Activity would correspond to a full allowance at the observed workload mix and Allowance Intensity.
_Avoid_: Weekly token allowance, guaranteed capacity

**Comparable Workload Cost**:
The Allowance Intensity of a workload cohort compared with its Reference Baseline.
_Avoid_: Limit reduction, price increase

**Comparable Work**:
Two bounded weekly intervals from the same account whose observed model, reasoning, cache, and Local Coverage mix passes the current measurement contract.
_Avoid_: Similar-looking task, same prompt

**Reference Baseline**:
The median of the four previous complete High-comparability weekly windows unless the user pins another qualifying historical period.
_Avoid_: Average week, official baseline

**Banked Reset**:
An available account reset that can restore eligible allowance windows when redeemed.
_Avoid_: Emergency reset, bonus credit

**Read-only Analytics**:
The part of Codex Limits that reads data, calculates metrics, shows guidance, sends reminders, and runs user-requested analysis without changing Codex state.
_Avoid_: Read-only product

**Reset Reminder**:
A local notification scheduled before the Next Known Expiry. It prompts the user to check the reset and never redeems it.
_Avoid_: Reset Automation, auto-use

**Reminder Lead Time**:
The interval between a Reset Reminder and the Next Known Expiry. The default is 24 hours.
_Avoid_: Trigger time, auto-use window

**Next Known Expiry**:
The earliest expiry among the banked-reset details currently available to the product. It is not necessarily the earliest expiry across all banked resets when detail coverage is incomplete.
_Avoid_: Oldest reset expiry

**Reset Detail Coverage**:
The number of banked-reset expiry details available compared with the authoritative reset count. The product shows incomplete coverage next to the reset count.
_Avoid_: Hidden details, reset confidence

**Local Activity**:
Codex work observed on the user’s machine, including task, agent, model, token, context, and tool activity when available.
_Avoid_: Billed usage, account charge

**Active Turn**:
A Codex turn between its observed start and completion. Waiting and polling remain part of the turn but are classified separately from execution.
_Avoid_: Open thread, foreground window

**Active Task Tree**:
A Task Tree in which at least one observable turn is active.
_Avoid_: Open project, open conversation

**Active Time**:
Observed elapsed time in the current Allowance Window during which at least one Active Task Tree is active. Overlapping activity counts once. Execution and waiting are separated when the source allows it.
_Avoid_: Compute time, billed time

**Estimated Active Time Available**:
A confidence-bounded range for additional Active Time before the current allowance is exhausted, based on recent comparable work. It appears only when Local Coverage is high enough.
_Avoid_: Runtime per week, guaranteed hours

**Concurrency**:
The number of Active Task Trees at a point in time.
_Avoid_: Open threads, running agents

**Project**:
The folder or project group presented by Codex, shown with the same short name. The product reuses this hierarchy and does not infer, rename, or replace it.
_Avoid_: Custom workspace, project alias

**Task**:
A root Codex task as presented by Codex. It is the stable root of a usage receipt.
_Avoid_: Project, inferred topic

**Task Tree**:
A Task together with the descendant agent tasks whose relationships are observable.
_Avoid_: Session when referring to the full hierarchy

**Usage Receipt**:
A factual summary of Local Activity for a Task Tree, with drill-down to agents and turns and kept distinct from Account Movement.
_Avoid_: Cost receipt, billing receipt

**Runway**:
The estimated time until the current allowance is exhausted at the Account Movement pace observed over the latest Rolling 24-hour Interval, or its shorter available portion.
_Avoid_: Runtime entitlement, hours per week

**Current Estimate**:
The future Usage Remaining projection from the latest account reading using the same recent pace as Runway. It is a derived estimate, never an observed account value.
_Avoid_: Actual usage, projection using a different pace from Runway

**Suggested Pace**:
The non-negative maximum future rate of allowance consumption, expressed in percentage points per day and derived from current Usage Remaining, time to reset, and the chosen safety buffer. It does not require historical pace observations; zero means the buffer has been reached.
_Avoid_: Official quota, guaranteed pace

**Insight**:
A structured observation or recommendation supported by named evidence, freshness, coverage, and confidence.
_Avoid_: Tip, verdict

**Usage Deviation**:
An observed usage rate outside the user’s personal reference range under comparable conditions. It appears as a passive Insight with the measured change, comparison period, Coverage, and Confidence, without claiming a cause.
_Avoid_: Anomaly, billing error, limit reduction

**Deterministic Insight**:
An Insight produced from local facts and explicit rules without invoking a model.
_Avoid_: AI insight, generated insight

**Codex-assisted Insight**:
A user-requested interpretation generated by Codex from bounded evidence. It sends a request to Codex and consumes the user’s allowance.
_Avoid_: Local insight, automatic insight

**Insight Execution Profile**:
The exact model and reasoning level used for a Codex-assisted Insight. The required initial profile is GPT-5.6 Luna Medium; when the current model catalog does not advertise that exact profile, the action is not shown and no fallback runs.
_Avoid_: Task model, inherited model

**Metadata-only Analysis**:
A Codex-assisted analysis whose evidence excludes Source Content. The user’s explicit analyze action is sufficient authorization to start it.
_Avoid_: Local analysis

**Source-backed Analysis**:
A Codex-assisted analysis whose evidence includes Source Content. It requires a preflight that identifies the content categories that will be sent.
_Avoid_: Full-context analysis

**Analytics Overhead**:
Local Activity from a Codex-assisted request and the bounded Account Movement observed during it. The product does not claim that concurrent account movement was caused by the analysis.
_Avoid_: Free analysis, background usage

**Coverage**:
The degree to which the expected source data for a metric or insight was available.
_Avoid_: Accuracy

**Confidence**:
The product’s assessment of how strongly the available evidence supports a derived metric or insight.
_Avoid_: Certainty

**Unavailable Reason**:
The shortest specific explanation of why a value cannot be calculated, such as a missing boundary reading, reset or correction, or account change.
_Avoid_: Not enough data without a reason, coverage jargon in the primary message

**Evidence Details**:
An optional drill-down containing a value's source, Observed Interval, Coverage, Confidence, and caveats. These details remain available without cluttering the primary result.
_Avoid_: Evidence metadata as the primary message

**Unattributed Movement**:
Account Movement that cannot be associated with observed Local Activity.
_Avoid_: Hidden charge, unexplained billing

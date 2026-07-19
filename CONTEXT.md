# Codex Usage Pacing

This context describes how to pace Codex usage safely between limit resets while making deliberate use of the available budget.

## Language

**Usage window**:
An independently resetting Codex allowance defined by its remaining budget and next automatic reset. A window may be weekly or shorter.
_Avoid_: Billing cycle, weekly limit as the name of the whole mechanism

**Main limit**:
The `codex` allowance that drives the menu-bar percentage, target pace, forecasts, and pace status.
_Avoid_: Total of all limits, active model

**Other limit**:
An independent model-specific allowance shown separately for reference. It is never added to the main limit and does not affect its forecast.
_Avoid_: Extra main budget, secondary usage window

**Remaining budget**:
The unused percentage of a usage window.
_Avoid_: Balance, credits

**Window reset**:
The automatic time at which a usage window renews.
_Avoid_: Manual reset, subscription renewal

**Emergency reset**:
An unguaranteed manual reset kept only as a last resort. It is never included in the remaining budget, target pace, or forecast; its availability may be shown for reference.
_Avoid_: Extra budget, backup allowance

**Target pace**:
The planned rate of use that brings the remaining budget to the safety buffer at the window reset. The interface expresses it as a percentage per day, switching to a percentage per hour during the final 24 hours.
_Avoid_: Daily limit, fixed allowance

**Safety buffer**:
The part of the remaining budget deliberately preserved at the window reset to reduce the risk of running out early. It defaults to 3% and can be changed by the user.
_Avoid_: Unused allowance, emergency reset

**Pace status**:
A plain-language comparison between the safety forecast and the target pace, expressed as `Slow down`, `On track`, or `Room to use more`.
_Avoid_: User score, productivity rating

**Expected forecast**:
The best estimate of the remaining budget at reset, weighted toward recent use and informed by earlier variation.
_Avoid_: Guaranteed outcome, long-term average

**Safety forecast**:
A deliberately conservative estimate used for the pace status. It does not assume that a future break from Codex will occur.
_Avoid_: Worst case, guaranteed minimum

**Burn-down chart**:
A chart for the current usage window with time and remaining-budget axes. It shows the observed usage curve, a straight path from 100% to the safety buffer, the current projection, the historical projection, and the current point; earlier windows inform the historical projection but are not drawn individually.
_Avoid_: Activity chart, task history

**Usage sample**:
A timestamped observation of the main limit's remaining budget and window reset. Its observation time is recorded locally; its remaining budget and window reset come from Codex.
_Avoid_: Token bucket, activity event

**Shared usage history**:
The combined usage samples recorded by Macs connected through the same optional sync folder. It excludes preferences, launch settings, credentials, and raw Codex responses.
_Avoid_: Shared app state, cloud backup

**Sync folder**:
An optional user-selected folder that connects the shared usage history of Macs signed in to the same Codex account. One sync folder represents one Codex account; the app does not identify or verify that account.
_Avoid_: Account store, settings sync

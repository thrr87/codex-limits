# Product language

Codex Limits uses clear, direct English. These rules apply to every label, tooltip, chart, notification, and insight.

## Orwell’s six rules

1. Use literal words. Avoid familiar metaphors and figures of speech.
2. Use a short word when it says the same thing as a long word.
3. Cut every word that adds no meaning.
4. Use active voice.
5. Prefer everyday English to jargon or foreign phrases.
6. Break a rule when following it would make the text harsh, false, or unclear.

## Product rules

- Name the quantity: `remaining`, `used`, `tokens`, or `percentage points`.
- Use Codex’s label `Usage remaining` for the primary allowance percentage.
- Separate account facts, local facts, and estimates.
- State uncertainty instead of hiding it.
- Name the source when two sources can disagree.
- Describe what changed; do not invent a cause.
- Use one canonical domain term for one concept.
- Put the action first in buttons.
- Keep tooltips to one fact or consequence.
- Do not call local activity billing, cost, waste, or efficiency.
- Do not claim that OpenAI changed a limit when the product only observed a change in intensity.
- Describe a usage deviation in `Insights`; do not call it an anomaly or send an alert.
- Use the weekly Codex window for the primary `Usage remaining`; name every other window.
- Withhold a Low-confidence estimate and say what data is missing.
- Do not call a partial sum of daily token buckets a weekly total.

## Time labels

Rolling ranges end now. Show their dates and clock labels in the Mac's current time zone; daylight-saving and time-zone changes do not change the elapsed range.

## Navigation labels

- `All` — strongest supported facts from every Enabled Integration.
- `Codex`, `Claude Code`, `Grok` — v1 Integration detail destinations shown only while enabled.
- `OpenCode` — reserved future destination; do not show them until a supported collector ships and the Integration is enabled.
- `Graphs` — Usage remaining, Token activity, Usage per token, and Concurrency charts.
- `Facts` — account facts, banked resets, other limits, and Usage receipts.
- `Insights` — structured observations and recommendations.

The current-state header remains visible while these views change.

## Integration settings

Use only the state that tells the user what can happen next:

- `Checking` — one explicitly requested compatibility or setup check is running.
- `Not found` — the user-managed Integration is not available on this Mac.
- `Set up` — the Integration is available but needs an explicit setup action.
- `Waiting for data` — setup succeeded but the source has not produced its first observation.
- `Ready` — the Integration can produce its supported facts; keep this status inside Settings.
- `Update required` — the installed CLI cannot provide the accepted source contract.
- A provider-specific error such as `Billing unavailable` — a shipped supported source failed and the user can retry or change setup. Do not expose errors for deferred Integrations.

Use `Last observed` for Claude Code and any other event-driven source. Use `Stale` only after the source-specific Freshness window and before the same known reset. Use `Expired` internally; reader copy should say `New usage observation needed` rather than exposing the implementation term. Use `Experimental` for Claude Code and `Beta` for Grok in Settings and the Integration detail header, not beside every value.

## Menu bar metric labels

The shipped v1 picker names both source and quantity:

- `None`
- `Codex — Weekly usage remaining`
- `Claude Code — 7-day usage remaining`
- `Grok — Current-period usage remaining`

Reserved future label, shown only after the corresponding collector ships:

- `OpenCode — 7-day local tokens`

Do not shorten picker labels to a bare Integration name. The compact menu bar itself may use `%`, `K`, or `M` once the picker and accessibility label establish the quantity.

## Source-specific actions

- Codex and Grok may use `Refresh` when the action starts a source read. Grok respects its thirty-second launch floor, including explicit actions. A future OpenCode surface may use it after its collector ships.
- Claude Code uses `Check for new observation` only to re-read the relay cache. Supporting copy says `Usage updates during Claude Code activity`.
- Use `Delete Claude Code data…` for the destructive Settings action and `Delete integration data` in its confirmation. The message must say that Claude Code's own data is not deleted.
- Use `Delete Grok data…` for Grok’s Settings action; explain that it removes only Codex Limits data and preserves Grok Build’s files and login.
- Use `Check again` for compatibility or setup recovery.
- Use `Locate…` when the user needs to choose an executable.
- Never show `Refresh all` in v1.

Grok names the returned weekly or monthly period. When the source marks unified billing, describe a shared Grok usage pool; never imply that its percentage measures only Grok Build activity. Optional plan, prepaid, and pay-as-you-go facts keep their own labels. Show CLI-version provenance in the Grok detail.

Claude Code and Grok use `Usage remaining` for their recorded burndown charts. Name Claude's `7-day` and `5-hour` windows separately and name Grok's returned weekly or monthly period. Describe points as `Recorded` and projections as estimates; never imply that a one-point cache reconstructs an earlier period. An empty or single-observation chart explains that more observations are needed. Retained history describes this Mac's observations and does not imply a verified account identity or cross-device coverage. Deletion copy includes recorded usage history.

In Claude Settings and the setup confirmation, `Waiting for data` explains that usage data is available on eligible Pro and Max accounts and appears after the first response in a session. The setup confirmation says Codex Limits changes the user status line and that project or managed settings can override it. Do not repeat plan eligibility in the menu bar or beside every value.

## Empty and expired states

- No Enabled Integrations: `No integrations enabled` with `Open Settings`.
- Enabled but not configured: use the Integration's specific setup state and one action.
- Claude without a first observation: the workspace uses `Use Claude Code to record usage` and `Usage appears after the first response in a session`; Settings adds the eligible Pro/Max constraint.
- Known reset passed: `New usage observation needed`; do not repeat the old percentage.
- A future OpenCode surface with missing cost omits the cost or says `Estimated cost unavailable`; it never displays `$0`.

Background refresh does not replace valid content with `Loading`, `Reading usage`, or a global progress message. Keep cached values visible and attach progress only to an explicit action.

History sync may show `Backfilling history` in Settings while its bounded cursor is visiting older daily files. Do not show that state in the menu bar or over cached charts, and do not say `Up to date` unless the current generation has no known backlog.

## Examples

| Avoid | Use |
|---|---|
| `37% left` or `37% allowance remaining` | `Usage remaining · 37%` |
| `You're burning through your quota` | `Usage increased faster than your baseline` |
| `Token efficiency` | `Allowance used per 1M local tokens` |
| `Workload cost` as a visible chart label | `Usage per token` |
| `Oldest reset expires` | `Next known expiry` |
| `3 resets available` when only one expiry is known | `3 banked resets · 1 expiry known` |
| `AI-powered analysis` | `Analyze with Codex` |
| `We detected hidden usage` | `Account and local totals differ` |
| `Your limit got worse` | `Comparable work used 1.3× more allowance` |
| `Usage anomaly detected` | `Usage increased faster than your baseline` |
| `Low confidence · 3.2 days` | `Not enough data · Account gap over 6 hours` |
| `Combined usage · 42%` | Separate Integration values |
| `OpenCode billing cost` | `OpenCode local estimated cost` |
| `Claude live usage` | `Claude Code · Last observed 8 min ago` |
| `Claude Code · Refresh` | `Usage updates during Claude Code activity` |
| `37% · Stale` after its reset | `New usage observation needed` |
| `OpenCode cost · $0` when absent | `Estimated cost unavailable` |
| `Menu bar source · Claude Code` | `Claude Code — 7-day usage remaining` |

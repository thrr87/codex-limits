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
- Describe `Current window` as the active allowance frame, not as a promise of future observations.
- Withhold a Low-confidence estimate and say what data is missing.
- Do not call a partial sum of daily token buckets a weekly total.

## Time labels

Rolling ranges end now. Show their dates and clock labels in the Mac's current time zone; daylight-saving and time-zone changes do not change the elapsed range.

## Navigation labels

- `Graphs` — Usage remaining, Token activity, Usage per token, and Concurrency charts.
- `Facts` — account facts, banked resets, other limits, and Usage receipts.
- `Insights` — structured observations and recommendations.

The current-state header remains visible while these views change.

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

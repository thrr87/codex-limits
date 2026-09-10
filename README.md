<h1 align="center">Codex Limits</h1>

<p align="center">
  <strong>See whether your Codex usage will last until reset and which local Tasks this Mac observed.</strong>
</p>

<p align="center">
  A macOS menu bar app for Codex usage, Tasks, agents, resets, and pace.
</p>

<p align="center">
  <a href="https://github.com/thrr87/codex-limits/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/thrr87/codex-limits/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-black">
  <img alt="Swift 5.10 or later" src="https://img.shields.io/badge/Swift-5.10%2B-F05138?logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

<p align="center">
  <img src="docs/images/codex-limits-graphs.png" width="440" alt="Graphs view showing weekly Usage remaining">
</p>

> [!NOTE]
> Codex Limits is an independent, unofficial project. OpenAI does not make or endorse it.

## What it shows

Codex shows Usage remaining. Codex Limits shows when it resets, how it changed, and which local Tasks this Mac observed. The current development build also includes opt-in Claude Code (Experimental) and Grok (Beta) Integrations with Usage remaining history. Claude records its seven-day and five-hour allowances during normal activity; Grok records its returned weekly or monthly usage pool. OpenCode remains deferred.

Open the menu to see:

- Weekly Usage remaining, the reset time, and banked resets.
- Runway and a suggested pace when the data supports an estimate.
- Account and local token activity.
- Active time, concurrency, and Usage Receipts for the Task Trees this Mac can read.
- Checks that run on this Mac and an optional `Analyze with Codex` action.
- Claude Code's last observed seven-day and five-hour Usage remaining, with recorded history when that Experimental Integration is enabled and an eligible Pro or Max account supplies the data.
- Grok Usage remaining, recorded history, its reset, and available plan, prepaid, and pay-as-you-go facts when Grok Beta is enabled.

Choose `All` for compact current-window charts beside each Integration’s remaining allowance and reset. Blue shows recorded usage remaining; the green dashed line shows the target. Select a row to open its detail.

Codex, Claude Code, and Grok share the same detail layout: Integration name, remaining allowance, reset, and chart. Codex keeps pace and runway under `Usage details`. Its `More` menu opens Token activity, Facts and reset reminders, or Insights.

<table>
  <tr>
    <td><img src="docs/images/codex-limits-facts.png" alt="Facts view showing account facts and banked resets"></td>
    <td><img src="docs/images/codex-limits-insights.png" alt="Insights view showing local checks and Analyze with Codex"></td>
  </tr>
  <tr>
    <td align="center"><strong>Facts</strong></td>
    <td align="center"><strong>Insights</strong></td>
  </tr>
</table>

## How to read the data

Codex Limits keeps three kinds of values separate:

- **Account facts** come from the Codex account API.
- **Local facts** come from Codex records on this Mac.
- **Derived estimates** name their Coverage and Confidence.

The app keeps weak estimates out of guidance and Insights. The Usage remaining chart may still show a Current or Past estimate when it has enough fresh points to show a useful direction. The chart names its source, Coverage, and Confidence.

Claude and Grok charts show actual observations recorded on this Mac. They start with available data; an older latest-only cache contributes one point. Their current estimates need at least two compatible observations separated by a minute, a fresh latest reading, and no gap over thirty minutes, reset, or correction. Token counts never stand in for an allowance reading.

## Features

- Uses the weekly Codex limit as the main Usage remaining value.
- Shows model-specific and shorter windows as Other limits.
- Records account usage history until you delete it.
- Shows the number of banked resets, known expiry times, and Reset Detail Coverage.
- Sends one local reminder before the next known banked-reset expiry. The default lead time is 24 hours.
- Shows local activity by Project, Task Tree, agent, model, reasoning level, and turn when the source has those facts.
- Compares periods only when it has sound start, end, and workload data. It does not claim a fixed token allowance.
- Runs local Insights on this Mac.
- Asks Codex to analyze selected data only after you click an analysis button.
- Lists the selected Source Content types—prompts, responses, code, paths, commands, and tool output—before you send them to Codex.
- Copies account usage samples to a private folder that you choose.
- Deletes Codex analytics history on this Mac and in the selected sync folder when you choose `Delete analytics history`.
- Refreshes Codex at launch, after wake, and every ten minutes only when its weekly metric is selected; visible or explicit reads remain bounded. Grok uses a ten-minute cadence only while selected for the menu bar, backs off after failures, and performs due reads when visible. Claude Code is event-driven and adds no polling timer.
- Runs as a native SwiftUI menu-bar app and uses Sparkle to verify and install signed updates.
- Does not redeem resets, change Codex settings, or control Tasks.

## How it works

1. Codex Limits starts your installed Codex CLI and reads account data through its local app server when Codex has demand.
2. It reads local Codex records without taking control of a Task.
3. If you explicitly set up Claude Code Experimental, Claude Code sends bounded allowance fields to a short-lived local helper during normal Claude activity; Codex Limits does not prompt Claude or poll it.
4. If you enable Grok Beta, the app reads billing through your official Grok Build CLI. The CLI manages its own login and service connection; no prompt or coding session is created.
5. It stores compact history files on your Mac and keeps each Codex account separate. Claude and Grok each retain their own local observation history until you delete it; their active charts read a bounded view of the latest 84 days.
6. It uses those sources to make provider-specific cards without combining their allowances.
7. It sends an analysis request to Codex only when you choose an `Analyze with Codex` action.

Coverage says how much needed data the app saw. Confidence says how well that data supports an estimate. Low-confidence chart lines do not change guidance or Insights.

## Privacy

Codex Limits keeps analytics local by default:

- It does not copy or store your Codex credentials.
- It does not read or store Claude credentials, prompts, responses, session identifiers, model names, transcripts, or project paths. Claude setup changes only the user status line after confirmation and never overwrites an existing status line.
- Grok reads use the official CLI’s supported ACP extension. Codex Limits does not read Grok credentials or cookies, call its private billing backend directly, or store raw CLI output.
- It sends no usage data to this project or its author.
- It stores account readings and local summaries in the app's Application Support directory.
- It does not copy prompts, responses, code, paths, commands, or tool output into Analytics History.
- Local Insights run on your Mac and consume no Codex allowance.
- `Analyze metadata` sends only the metadata shown in the app.
- `Analyze Source Content` shows each content type before you send it.
- Each request to Codex uses your Codex allowance. The buttons appear only when Codex offers the required model and reasoning level.
- Reset reminders use local macOS notifications. The app asks for permission when you first enable the reminder.
- If you enable history sync, it copies only Codex usage samples to the selected folder. Claude and Grok history, preferences, credentials, and raw Codex responses stay on your Mac.
- Synced JSON files contain observation times, remaining percentages, and reset times. Choose a folder that you do not share with other people.
- `Delete analytics history` removes Codex analytics history on this Mac and in the selected sync folder. It keeps your preferences and source Codex records.
- The Codex CLI contacts the Codex service during normal account reads and user-requested Codex analysis. Grok Build contacts its service during enabled usage reads.
- `Delete Claude Code data…` and `Delete Grok data…` disable that Integration and remove its app-owned history, snapshot, and setup or executable preference. The integrated product's own records and login remain intact.

Do not attach raw CLI output or screenshots containing account usage to public issues.

## Requirements

- macOS 14 or later
- Xcode 16.4 or later
- A signed-in standalone Codex CLI to use the Codex Integration. Known Homebrew and native installer locations are detected, and Settings offers `Locate…` for another executable path.
- Claude Code is optional. Its Experimental allowance card requires explicit setup and an eligible Pro or Max account; Free can run Claude Code but does not provide the required allowance fields.
- Grok Build is optional. Its Beta allowance card requires a compatible official CLI and a Grok login with available allowance data. Version 1.0.25 passed a real billing read on 2026-09-10.

Codex Limits does not use a Codex binary bundled with another app. Install and update each standalone CLI yourself. OpenCode is not included in v1.

## Build from source

Clone the repository and run:

```sh
Scripts/build-app.sh
```

The script creates an ad-hoc signed app at `.build/release/Codex Limits.app`. Launch it with:

```sh
open ".build/release/Codex Limits.app"
```

Stable releases include a universal app for Apple Silicon and Intel. The app is not Developer ID signed or notarized, so the first manual installation remains subject to macOS Gatekeeper. After that, the app can detect and install EdDSA-signed stable updates. Open `Package.swift` in Xcode to work on the source.

## Test

```sh
swift test -c release
```

The tests use made-up usage data. Do not commit exported account data or local app state as test data.

For a local Grok check, build and open the app, enable `Grok` in Settings, and select `Grok — Current-period usage remaining`. Check the Grok detail and `All` views, wait at least 30 seconds before an explicit refresh, then disable Grok and confirm its menu value disappears. See the [Grok validation note](docs/research/grok-build-validation-2026-09-10.md) for expected behavior and remaining release checks.

## Current limitations

- Multi-integration release acceptance remains pending: the all-enabled idle comparison and eight-hour lifecycle soak are incomplete. The live Claude observation is explicitly waived for the Experimental Integration. Local development testing can proceed.
- Claude and Grok sources do not provide a stable account identity. Their histories describe this local installation, do not sync, and cannot reconstruct usage from before observations were recorded.

- Existing 0.2.6 and older installations require one final manual update to a version that includes the in-app updater.
- Account and local values can differ because this Mac may not observe every Codex Task.
- Estimates need account readings near both ends of a time range and enough similar local work.
- `Analyze with Codex` appears only when Codex offers GPT-5.6 Luna with Medium reasoning.
- Codex CLI responses may change between versions. If parsing fails, update the CLI before reporting a problem.

## Security

Report vulnerabilities privately. See [SECURITY.md](.github/SECURITY.md) for instructions.

## License

MIT. See [LICENSE](LICENSE).

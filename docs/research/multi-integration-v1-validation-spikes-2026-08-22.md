# Multi-integration v1 validation spikes

> **Correction — 2026-09-10:** The Grok exclusion and Grok-specific no-source claims below are superseded. The August probe used bare `x.ai/billing`; ACP requires `_x.ai/billing` on the wire. Official stable 1.0.25 passed a real authenticated read with the corrected method. The historical 1.0.5 prefix case remains untested. Grok is now a development Beta; OpenCode remains deferred. The original Codex-plus-Claude idle result does not cover Grok, and the expanded all-enabled comparison, provider-owned Grok write measurement, eligible Claude observation, and eight-hour soak remain release work. See [current Grok validation](grok-build-validation-2026-09-10.md). Original evidence follows unchanged.

Date: 2026-08-22\
Status: Completed for this machine; Claude release gates remain

## Purpose

These spikes validate the smallest supported collection path for Claude Code, Grok, and OpenCode before production implementation. They use original fixtures and isolated local processes. No CodexBar source code was copied. CodexBar informed the list of questions to test, while provider-owned documentation and binaries define the contract.

## Verdict

| Integration | Result | v1 consequence |
|---|---|---|
| Claude Code | Implementation pass; release gates remain | Event-driven source, UI, exact setup/removal, and bounded relay are implemented; finish eligible-account and lifecycle release checks |
| Grok | No-go for the stable 1.0.5 ACP collector | `initialize` works but `x.ai/billing` returns `-32601`; defer from v1 without credential/private-backend fallbacks |
| OpenCode | No-go for the server collector | Defer OpenCode from v1 unless a supported, materially lighter read-only source is found |

## Claude Code 2.1.92 with 2.1.231 continuation

### Environment and checks

- Selected binary: `/opt/homebrew/bin/claude`, version `2.1.92`.
- The real user settings file was read only for structural metadata. It was valid JSON, contained only `model` and `permissions`, and had no `statusLine` entry. No command, permission value, credential, or other setting value was printed or persisted.
- No project or project-local Claude settings file existed in this repository at test time.
- The installed CLI accepts both `--settings <file-or-json>` and `--setting-sources <sources>`.
- A synthetic settings file containing a command `statusLine` loaded successfully through `claude --settings ... --version`. No Claude session, prompt, authentication, or network request was started.
- An original fixture parser accepted independently optional five-hour and seven-day windows, converted used percentage to remaining percentage, rejected values outside `0...100`, rejected input larger than 256 KiB, and omitted the fixture's `session_id` and `transcript_path` from its normalized result.
- A settings collision check accepted a document without `statusLine` and refused a document with an existing user-owned `statusLine`.

Anthropic's supported status-line contract exposes `rate_limits.five_hour` and `rate_limits.seven_day`, but only for eligible Claude.ai subscribers after the first response; either window may be absent. It is event-driven and can also be configured with an optional periodic refresh, which Codex Limits must not add. See [Customize your status line](https://code.claude.com/docs/en/statusline).

### Constraints not removed by the spike

- Setup changes Claude Code's visible footer and runs a local command during Claude activity. It therefore remains a user-confirmed action in Settings, never automatic discovery.
- Codex Limits must not overwrite or wrap a user-owned `statusLine` in the user settings file. It does not scan project, local-project, or managed settings; those higher-precedence scopes remain untouched and can override the installed user status line.
- The app cannot force fresh allowance data without generating Claude activity, so the UI must say `Last observed` and never simulate a refresh with a dummy prompt.
- Release still needs one user-confirmed observation on an eligible Claude account plus the eight-hour lifecycle soak. The eligible-account check must not use a dummy prompt or change the user's existing setup without confirmation.
- A continuation check found Claude Code `2.1.231` installed through the official Homebrew cask. It reported no active login in the Codex execution context. Anthropic documents that the Free plan does not include Claude Code allowance access and that status-line `rate_limits` appear only for Pro/Max subscribers after a response, so this machine cannot satisfy the eligible-account allowance gate without a different eligible account. Installation alone is still sufficient for deterministic setup and relay tests.

### Eligible-account release observation

This check can be completed later by one consenting Pro or Max tester; it does not require changing this machine's Free account. The tester enables Claude Code in Settings, reviews the footer consequence, and completes setup only when no user-owned status line conflicts. They then continue a Claude Code session with a response they already intended to request; Codex Limits must not create a dummy prompt. The gate passes when at least one five-hour or seven-day window reaches the app-owned allowlisted cache, renders as `Last observed`, and a manual check performs only a cache read. Disabling must stop writes and remove only the exact Codex Limits-owned status-line entry. Evidence records the Claude Code version, window presence, normalized percentages and resets, observation time, file permissions, and semantic before/after settings comparison; it records no account identity, session or model metadata, prompt, response, transcript, project path, credential, or raw event.

### Decision

The source is feasible and naturally cheap: Claude pushes a bounded event to a short-lived relay, while the app reads its own tiny normalized cache. The implementation now includes device-local enablement, menu metric selection, `All` and detail surfaces, exact setup/deactivation, app-owned data deletion, independent five-hour and seven-day lifetime handling, and one shared priority-aware source-work coordinator with Codex.

### Implemented relay and package checks

- Seven relay tests cover allowlist privacy, invalid and oversized input, out-of-order writers, equivalent-write suppression, tampered cache rejection, disabled-marker behavior, and a neutral non-empty footer when an event contains no eligible allowance.
- Thirteen setup/lifetime tests cover exact install/removal when user settings exist or are initially absent, settings added after setup, user-owned conflict preservation, modified configuration preservation, app-owned data deletion, suppression of an in-flight readiness result after disable, zero hidden/unselected launch reads until visible demand, QA path isolation, explicit executable validation, compatible snapshot preservation during an app-helper update, and independent reset behavior.
- The packaged helper passed strict bundle signature verification and remained executable inside `Contents/Helpers`.
- A later Release QA package check verified the isolated bundle identifier, the app and nested helper signatures, and matching arm64 architectures. The packaged helper produced `7d 60% remaining` from an original bounded fixture, wrote only the allowlisted `0600` snapshot fields, and produced `Usage unavailable` without a cache for an event with no eligible allowance.
- The universal release workflow now separately requires an executable, strictly signed `CodexLimitsClaudeRelay` containing both arm64 and x86_64 slices. The release validator refuses to proceed while the multi-integration PRD status remains `Needs revision`.
- On a synthetic event containing private session and model fields, the packaged helper emitted the expected status line, wrote a 179-byte `0600` cache containing only `version`, `observedAt`, `cliVersion`, `fiveHour`, and `sevenDay`, and did not rewrite an equivalent event inside 30 seconds.
- `/usr/bin/time -l` measured 7,159,808 bytes maximum RSS, 2,294,192 bytes peak memory footprint, and a wall time rounded to 0.00 seconds for that bounded event.
- A disabled-default UI QA checkpoint used 132,016 KiB RSS at 0.0% CPU after 73 seconds and had no app-owned child process. This was a short control before the completed comparison below and is not the eight-hour soak.

## Grok

The protocol/source distinction and exact runtime evidence are recorded in the [Grok ACP contract/runtime note](grok-build-acp-runtime-contract-2026-08-22.md).

### Environment and checks

- The initial restricted shell snapshot did not resolve `grok`; the continuation check found the user's working installer-managed executable at `/Users/piotrciechowicz/.grok/bin/grok`. No credential or auth file was read.
- On the continuation check, xAI's official `stable` channel returned version `1.0.5`. The installer documents both `https://x.ai/cli` and `https://storage.googleapis.com/grok-build-public-artifacts/cli` as artifact origins.
- The macOS arm64 1.0.5 binary was downloaded separately from both origins into `/private/tmp`, never installed or added to `PATH`. Both files were bit-for-bit identical: 134,349,648 bytes, SHA-256 `3dfa7f04fbb5427a8fbead286591543aaecb478b3a0ab222c4329eca1a3b2f86`.
- Static inspection reported a thin arm64 Mach-O with hardened-runtime metadata, identifier `xai-grok-pager`, and Team ID `5Y6N3AJ54S`. Apple's strict verifier rejected the two official, byte-identical copies even though the matching installed CLI executes normally; this standalone-package diagnostic is not an installation, auth, or subscription failure.
- The binary was not executed, no authentication command was invoked, and `~/.grok` remained unread and unchanged. The two temporary copies were deleted after recording the result.
- A continuation check found `/Users/piotrciechowicz/.grok/bin/grok` symlinked to the installer-managed download. It is stable `1.0.5`, has the same size and SHA-256 as both isolated downloads, and successfully executed `--version` and the bounded `doctor` diagnostic on macOS 26.5.2.
- The current official Homebrew Claude Code `2.1.231` binary independently fails the same strict `codesign` verification while executing normally. For these standalone CLI distributions, strict signature verification is therefore retained as diagnostic evidence but removed as a sole provenance or execution gate.
- An account query from the restricted Codex execution context was inconclusive: network access was unavailable and no usable Grok authentication was exposed in that context. It does not test the user's normal terminal session or subscription. No prompt or billable model request was sent.
- A fresh isolated home then ran the documented sequence correctly in ordinary mode and repeated it with the source-recommended `grok agent --no-leader stdio` mode. Both waited for `initialize` before sending `x.ai/billing` with a literal slash and empty parameters. `initialize` returned protocol and capability metadata; billing returned JSON-RPC error `-32601 Method not found` before authentication could matter.
- The final isolated `--no-leader` run used 51,363,840 bytes maximum child RSS and 0.179 seconds combined child user/system CPU. It emitted 3,614 bytes on stdout and 122 bytes on stderr, below the output bounds. Startup plus the one-second shutdown boundary took 1.527 seconds.
- Closing stdin did not produce graceful exit inside one second, so the harness terminated the complete process group. It was fully reaped with no surviving process. The isolated home contained 34 provider initialization files totaling 613,539 bytes; the temporary directory was then deleted.
- The data contract was pinned to xAI's provider-owned source at commit [`19d42e35`](https://github.com/xai-org/grok-build/blob/19d42e35c07a9c9244f03f6df0c4c353f970d4f9/crates/codegen/xai-grok-shell/src/extensions/billing.rs). That source defines the `x.ai/billing` extension, prefers `creditUsagePercent` plus `currentPeriod`, and retains deprecated `monthlyLimit`, `used`, and billing-period fields for compatibility.
- Original current-shape and legacy-shape fixtures normalized successfully. The fixture check rejected an unknown period type, a zero legacy limit, an invalid reset, and values outside the percentage/limit range.
- The current shape keeps weekly and monthly periods distinct. No unknown period is relabeled.

### Rejected source and future entry conditions

- Stable 1.0.5 does not expose billing on its supported external ACP route. The source implementation is used by the pager/TUI, but source presence does not make it callable by an external app.
- Codex Limits intentionally rejects the remaining known fallbacks: reading `~/.grok/auth.json`, reusing browser credentials, calling the private Grok billing backend, or scraping/parsing the interactive `/usage` TUI.
- Grok can return only when an official supported release exposes a read-only external billing method. That release must then pass authentication, personal/team behavior, zero-value ambiguity, timeout, cancellation, output, RSS, source-mutation, and complete cleanup gates.
- Executable identity validation belongs to explicit setup or detected replacement only. Ordinary refresh must never hash the 134 MB binary.

### Decision

The decoder contract remains useful future work and the local executable is viable, but the only accepted external source is absent from stable 1.0.5. Defer Grok from shipped v1. Do not implement a production process wrapper around a method that deterministically returns `Method not found`, and do not replace it with credential or private-backend access. A strict signature failure remains diagnostic evidence but is not the reason for deferral.

## OpenCode 1.18.11

### Isolation

- Selected binary: `/opt/homebrew/bin/opencode`, version `1.18.11`. A second user binary at `~/.opencode/bin/opencode` reported `1.15.12` but was not started because the supported newer binary already failed the resource gate.
- `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, and `XDG_STATE_HOME` pointed to a dedicated temporary directory. `HOME` was not changed. Real OpenCode session storage was not read or modified.
- The server used `--pure`, loopback-only binding, and Basic Auth. The password was test-only and is not recorded.

### Functional result

- `serve --help` advertises `--pure`, hostname `127.0.0.1`, disabled mDNS, and a default port of `0`.
- At runtime, `--port 0` listened on fixed port `4096`, not an operating-system-assigned random port.
- `/global/health` returned healthy with version `1.18.11`.
- Three empty synthetic sessions were created in the isolated database. `GET /session?limit=2` returned only the two newest sessions, proving a server-side count bound on this version.
- Session summaries included cumulative `cost` and token categories for input, output, reasoning, cache read, and cache write. Empty sessions correctly contained zeroes; their aggregation semantics were not proven.
- The server stopped on interrupt and no residual OpenCode process remained.

### Resource result

| Observation | Measured result |
|---|---:|
| Server process RSS after health/session requests | 754,240 KiB, approximately 736 MiB |
| CPU at the sampled instant | 0.3% |
| Isolated working-set files created | 3,654 |
| Isolated disk footprint | 67,316 KiB |
| `config/opencode/node_modules` | 62,632 KiB |
| `cache/opencode/models.json` | 4,168 KiB |

These writes occurred despite `--pure`; that option does not mean read-only or zero-initialization. The RSS exceeds the provisional per-Integration app budget by roughly two orders of magnitude, and the fixed port prevents safe concurrent random-port startup as specified.

### Decision

The short-lived local-server design is rejected for v1. A 736 MiB child process is user-visible system load even if it is terminated correctly. Do not implement periodic or launch-time OpenCode collection using this method.

OpenCode can return to scope only if an official supported interface supplies bounded session summaries with cost/token fields without loading the server runtime, or if a supported later release is measured to fit the same release budgets. `opencode session list --format json` is lighter but currently lacks the required cost/token facts; reading the internal SQLite database remains unsupported and is not an acceptable fallback.

## Codex performance baseline and bounded working set

### Environment

- Release build on an Apple M1 Pro with 32 GiB RAM.
- macOS 26.5.2, build 25F84.
- The QA build used an isolated bundle identifier and defaults suite. The installed production app remained running and was not modified or stopped.
- Process RSS and CPU were sampled from the operating system. Synthetic history fixtures contained no user data.

### Baseline before hardening

| Observation | Result |
|---|---:|
| QA parent, 60 samples every 10 seconds | 123,910.1 KiB average RSS; 124,192 KiB maximum; 0.0000% average CPU |
| QA `codex app-server --stdio` child at the end of the trace | 98,704 KiB RSS |
| QA parent and child combined | 222,720 KiB, approximately 217.5 MiB |
| Installed production parent and child at a comparable idle sample | 215,472 KiB, approximately 210.4 MiB |

The parent was CPU-idle, but the app-server remained alive between ten-minute account refreshes. Correctly idle CPU did not justify keeping roughly another 96 MiB resident for passive analytics.

### Implemented bounds and measured result

- The Codex protocol connection is still reused for related requests in one burst, then closes after five seconds without protocol work. A focused unit test proves that immediate reads reuse one initialized session and a read after the idle boundary creates a new session.
- The Analytics History reader keeps at most 6,000 samples from the latest 84 days. The latest eight days retain full resolution; older observations retain the first and last point per hourly/reset bucket and explicit comparison breaks.
- A ten-year fixture retained all 3,650 canonical daily files while publishing 85 reader samples. In the earlier 583-test Release run, the cold working-set load was 10.206 ms; a disconnected automatic refresh used the in-memory state and took 0.007 ms. A separate dense fixture stopped at exactly 6,000 samples.
- In a quick Release validation 23 seconds after launch, the QA parent used 122,208 KiB RSS at 0.0% CPU and had no child process. The installed production build still had its old persistent child, demonstrating that the disappearance was specific to the hardened QA build rather than an operating-system-wide event.
- Across the subsequent ten-minute Release trace, 60 samples taken every ten seconds averaged 122,056.5 KiB RSS with a 122,288 KiB maximum. Average and maximum sampled CPU were both 0.0000%; no child process appeared in any sample. Against the earlier combined QA baseline, steady idle RSS fell by approximately 98.3 MiB.
- After restoring complete sync semantics for the bounded-working-set slice, an idle check measured 122,032 KiB RSS at 0.0% CPU with no child process.
- The final QA source, including manifest/cursor sync and explicit older-range access, measured 124,656 KiB RSS at 0.0% CPU after 19 seconds with no child process. That QA instance was then stopped; the installed production process and its existing child were left untouched.

The spike rejected reading only the newest files during sync because it can silently omit older observations created while the shared folder is unavailable. The implemented ADR-0014 replacement uses a small writer manifest, a relaunch-safe round-robin cursor, recent-change priority, and at most 32 calendar-day candidates and daily-file reads per periodic pass. It also avoids rewriting unchanged merged days, so an idle pass does not create artificial revisions or disk churn.

The separate older-range reader accepts only an explicit interval no longer than 84 days, reports retained and covered bounds, returns at most 6,000 ordered samples, marks the result `exact` or `downsampled`, and checks cancellation between files. It does not add those samples to the default resident state.

### Test-health boundary

- `CodexClientTests` passed 43 of 43 tests before the idle change and 44 of 44 after adding its focused lifecycle test.
- The first baseline exposed 42 `UsageHistoryTests` failures among 49 tests. They shared one root cause: `updateMarkerAtomically` invoked `NSFileCoordinator` for ordinary local folders, where coordinated replacement plus atomic writing failed with Cocoa error 512. The shared function now uses an in-process lock plus atomic write for non-iCloud markers and retains `NSFileCoordinator` for ubiquitous locations.
- After adding working-set, range, cursor, convergence, malformed-repair, and no-op-write coverage, `UsageHistoryTests` passed 56 of 56. The concurrent-generation regression passed 20 repeated Debug runs.
- The complete pre-Grok-runtime Release suite passed 583 tests with zero failures and zero unexpected failures in 23.252 seconds. It includes the serialized-work, disabled-source, Claude relay, setup, lifetime, deletion, and QA-path isolation checks.
- After the Grok runtime no-go narrowed the shipped enum and menu metric set, review also found that explicit history refresh still selected the complete reconciliation path. Explicit and automatic refresh now share the 32-candidate bound; only a user-confirmed first folder connection may reconcile completely. A final PRD-to-code scheduling audit then found that the Codex timer remained armed when Claude or `None` supplied the menu metric. The timer now exists only while Codex supplies that metric; launch, wake, re-enable, and automatic refresh remain source-silent otherwise, while `All` and Codex detail can request a serialized due read. The Claude lifecycle audit added generation checks after every asynchronous setup, inspection, cache-read, disable, and deletion boundary so a superseded result cannot publish. It also removed hidden/unselected launch and notification cache reads: Claude now reads only for Settings, enablement, menu selection, or visible `All`/detail demand, and closing the workspace clears visible demand. The final completeness audit added device-local `Locate…` for Codex and Claude without a login shell or CLI launch, a useful Free-plan footer fallback, compatible-cache preservation during helper update, full menu accessibility values, source-free Freshness/reset boundary transitions, and a visible-demand-only `Earlier` history action with fixed cold-read ceilings. The complete Release suite passed 601 tests with zero failures and zero unexpected failures in 26.632 seconds. Regressions cover deferred Integration persistence, bounded explicit and automatic history reconciliation, cold-read writer/file/byte bounds, older-range cancellation, exact Claude settings removal and preservation, in-flight disable ordering, executable selection, reset expiry without another source read, and demand-driven Codex and Claude scheduling. That run measured the ten-year cold working-set load at 12.169 ms and disconnected automatic refresh at 0.007 ms.
- The live Codex protocol deadline now matches the PRD's ten-second maximum; the five-second idle-release boundary remains separate.
- `Scripts/measure-app-idle.sh --self-test` passed. The release comparison runs the sampler for 2,400 seconds at ten-second intervals in each state, discards the first 60 warm-up samples, and evaluates the final 180 samples. Its CSV includes parent and direct-child RSS, CPU, and child count.
- The QA app now constructs Claude setup paths entirely beneath its isolated Application Support directory and uses its packaged relay as the non-invoked availability fixture. All thirteen `ClaudeCodeSetupServiceTests` passed in the final focused Release run.
- A signed Release QA smoke test completed the visible enable, consent, setup, waiting-for-data, and disable flow. The QA fixture settings gained and then removed only the expected status line; its enabled marker and install record were removed on disable. The real `~/.claude/settings.json` retained the same SHA-256, size, permissions, and modification time before and after. Original QA defaults and data were restored, and generated test data was deleted.

### Completed 30-minute idle comparison

The Release QA build ran twice from the same restored defaults and an empty isolated QA data directory. The installed production app stayed running and was not modified. The first profile enabled only Codex; the second enabled Codex and Claude Code. Both selected the Codex weekly metric and kept Settings closed. Claude setup, authentication, the real Claude configuration, and real Claude data were not touched.

| Final 180 samples after warm-up | Codex only | Codex + Claude Code | Regression |
|---|---:|---:|---:|
| Average parent RSS | 110,072.622 KiB | 110,000.444 KiB | -72.178 KiB |
| Maximum parent RSS | 110,128 KiB | 110,112 KiB | -16 KiB |
| Final minus first parent RSS | +48 KiB | +48 KiB | 0 KiB |
| Average parent CPU | 0.000000% | 0.001111% | +0.001111 percentage points |
| p95 parent CPU | 0.0% | 0.0% | 0.0 percentage points |

The RSS gate permits a 10 MiB increase and the CPU gate permits a 0.2-percentage-point increase, so both passed with substantial margin. No child was retained at the end of either run. Short Codex app-server bursts appeared at the existing 600-second account-refresh cadence: one sampled burst in the Codex-only trace and three in the Codex-plus-Claude trace. The Claude implementation has no recurring collection timer and starts no provider child process; the all-enabled trace showed no child activity outside those Codex refresh boundaries. The original QA defaults and data directory were restored after both runs.

The eight-hour mixed lifecycle soak remains a release gate. The completed 30-minute comparison does not substitute for it.

The PRD now defines an exact 490-sample soak protocol, hourly lifecycle cycle, settling boundary, checkpoint evidence, and numerical pass criteria. The full run still requires user-confirmed real network-unavailable/recovery and sleep/wake events; synthetic events or unapproved system changes are not accepted as substitutes.

## Resulting implementation order

1. Measure and bound the existing Codex default reader, explicit older ranges, and eventual sync. **Completed.**
2. Implement the event-driven Claude Code path and its exact setup/uninstall safety. **Completed; long release measurements remain.**
3. Keep Grok out of the shipped v1 collector until an official external billing source appears.
4. Keep OpenCode out of the shipped v1 collector until its source gate changes.

The Codex baseline, bounded history, shared Integration state, Claude implementation gates, and 30-minute idle comparison are now recorded and implemented. Grok and OpenCode are explicitly outside v1 rather than unresolved implementation items. The multi-integration PRD remains `Needs revision` because the eligible-account Claude observation and eight-hour soak remain release gates.

# Grok Build billing validation

Date: 2026-09-10\
Status: Working development Beta; expanded release checks pending

## Protocol correction

The August 22 spike sent `x.ai/billing` directly on the JSON-RPC wire. ACP custom methods require an underscore, so the correct method is `_x.ai/billing`. The internal xAI handler name omits that transport prefix. The earlier `-32601` result did not prove that Grok lacked an external billing route. The historical 1.0.5 executable has not been retested with the corrected request.

Official Grok Build stable 1.0.25 passed these sequential probes:

| Probe | Result |
|---|---|
| Isolated provider home, `initialize` | Success |
| Isolated provider home, bare `x.ai/billing` | `-32601 Method not found` |
| Isolated provider home, `_x.ai/billing` | `-32000 Authentication required` |
| Normal CLI-managed login, `_x.ai/billing` | Valid weekly billing configuration and optional subscription tier |
| Compiled Swift collector using the same official CLI | Valid normalized snapshot, weekly period, CLI version 1.0.25, and a future reset |

The authenticated probe made no model request, created no coding session, and started no login flow. Codex Limits did not read credentials or call a private backend. Account values, reset dates, identifiers, and raw provider output are intentionally absent from this report.

## Measured process bounds

The authenticated protocol probe measured:

| Measure | Observation |
|---|---:|
| Wall time, including cleanup | 1.984 seconds |
| Maximum transient child RSS | 77,578,240 bytes |
| Child user + system CPU | 0.208 seconds |
| Captured stdout | 4,349 bytes |
| Captured stderr | 0 bytes |
| Process-group cleanup | Stopped with SIGTERM |

These are one-operation measurements, not an idle or endurance result. Live provider-owned initialization writes have not yet been quantified. The previous Codex-plus-Claude idle comparison does not cover the restored Grok scope.

## Implemented contract

The opt-in Grok Beta appears in Settings, `All`, its detail destination, and the `Grok — Current-period usage remaining` menu picker. Its collector starts `grok agent --no-leader stdio` in a temporary empty working directory, sends `initialize` followed by `_x.ai/billing`, and reads CLI-version metadata from `_meta.agentVersion`.

The entire fetch has a ten-second deadline. Its owned process group receives graceful termination, then forced cleanup after at most one second; cancellation waits for cleanup before another coordinated operation starts. Total stdout is capped at 1 MiB, stderr is discarded, and raw output is not persisted.

Only a selected Grok menu metric schedules ten-minute automatic reads. Enablement, visible `All`/detail, and explicit actions may request a due read. Every launch respects a monotonic thirty-second floor. Automatic failures back off for 600, 1,200, 2,400, then at most 3,600 seconds; a successful read resets the backoff. Hidden, unselected Grok performs no polling.

The latest snapshot is fresh for at most thirty minutes and expires at its known reset. A 64 KiB app-owned cache retains only the original finite used percentage, normalized period, optional provider-reported start, reset, observation time, measurement source, CLI version, and available plan/prepaid/PAYG/unified-pool facts. The snapshot has `0600` permissions and its app-owned parent has `0700`. A supplied start must be a supported finite date earlier than reset; a missing start remains absent and monthly boundaries are never invented. Missing optional facts remain absent. Current fields take precedence; legacy credit calculation is permitted only when both current fields are absent. A zero legacy limit is unavailable, while a present empty Cent object represents zero. Grok Build activity is not inferred from a shared usage pool.

The authorized history extension retains actual Grok allowance observations in a separate local journal until explicit deletion. Weekly and monthly series remain distinct. Its active chart reads only a bounded view of the latest 84 days; the earlier latest-only cache can seed one real point, without reconstructing an earlier period. Estimates require at least two compatible points spanning at least sixty seconds, a fresh latest point before reset, and no gap over thirty minutes, reset, or correction. The [measurement contract](../MEASUREMENT-CONTRACT.md) defines the full history bounds and forecast rules. Claude's seven-day and five-hour observations use the same isolated history contract.

Disable cancels collection and preserves the snapshot and history. `Delete Grok data…` disables collection and removes the app-owned snapshot, retained history, and executable preference; Grok Build’s files, settings, and login remain intact.

The follow-up workspace update aligns Codex with the simpler Grok detail layout and adds current-period thumbnails to `All`. The thumbnails use the same step interpolation as full charts for actual observations, a dashed target, and the latest actual point; they omit estimates. Full Codex views and reset reminders remain available through `More`. Current-period Claude/Grok reads are bounded to 31 elapsed days / 32 UTC files, and only the compact display data remains resident in `All`.

A second live Grok 1.0.25 probe on 2026-09-10 measured process I/O with macOS `proc_pid_rusage` v4. Across 49 samples through the successful billing response, the CLI reported 897,024 physical disk-write bytes and 1,552,384 logical-write bytes. The empty temporary working directory retained no files. Total probe time including cleanup was 1.735 seconds, child CPU was 0.211 seconds, peak child RSS was 80,003,072 bytes, and stdout was 4,349 bytes with no stderr. These counters measure the CLI through the reply, without reading credential files or retaining raw account output; they do not replace the idle comparison or lifecycle soak.

## Validation and release exceptions

The complete Release suite, including retained Grok/Claude history, shared burndown charts, and bounded current-period overview thumbnails, passed 644 tests with zero failures in 24.986 seconds. Coverage includes provider starts and old-cache migration, protocol/process cleanup, private daily journals and interrupted writes, bounded file-lock waits, overview/detail demand, deletion races, notification coalescing, forecast resets/corrections/gaps/source changes, missing current windows, and chart preference isolation. The release-validator self-check also passed. The Claude readiness-cancellation check now holds the shared coordinator and explicitly signals disable, eliminating its dependence on file-read duration; 30 consecutive local runs passed. Signed native packaging and a separate synthetic QA profile verified Grok’s weekly chart, Claude’s seven-day and five-hour charts, actual/target/current-estimate lines, point navigation, zoom, and isolated range preferences. Visible copy was checked for internal notes. Native QA caught and fixed an initial empty-view lifecycle issue that prevented asynchronous chart creation. The rebuilt user QA also displayed current-window thumbnails from the real Codex/Grok caches and the matching simplified Codex detail. Row navigation, `More`, Facts and reset reminders, and the collapsed usage details were checked in the signed native app; the prior QA profile and preferences were preserved. The synthetic profile was removed after validation. These checks and the earlier successful live Grok read do not prove the unperformed idle comparison or lifecycle soak.

The [multi-integration PRD](../prd/multi-integration-workspace.md) is accepted for release 0.3.0 with explicit owner exceptions in [ADR-0015](../adr/0015-ship-claude-as-experimental.md). The live Claude Pro/Max observation is waived for the experimental integration; the expanded all-enabled idle comparison and eight-hour mixed lifecycle soak are waived specifically for 0.3.0. Neither performance check was run. OpenCode remains deferred.

## Local testing

1. Build with `Scripts/build-app.sh`, then run `open ".build/release/Codex Limits.app"`.
2. Enable `Grok` in Settings. Use `Locate…` if necessary; if sign-in is required, run `grok login` yourself and retry.
3. Select `Grok — Current-period usage remaining`. Check `All` and Grok detail for the returned period, reset, and CLI version. Optional fields should appear only when available.
4. Wait at least thirty seconds before `Refresh`; rapid repeated clicks must not launch another CLI. Closing the workspace and choosing another menu source should leave no recurring Grok read.
5. Disable Grok. It should disappear from navigation and, if selected, leave the menu metric as `None`. Re-enabling may reuse the cached snapshot, subject to freshness and reset expiry.
6. Check Grok's Usage remaining chart. An existing latest-only cache initially contributes only its actual point; later successful reads add observations. Relaunch should retain them, while `Delete Grok data…` removes them. A forecast stays unavailable until enough compatible fresh observations exist. Use deterministic fixtures for resets, corrections, and long gaps; do not turn private account readings into test fixtures.

## Primary sources

- [ACP extension request prefix](https://agentclientprotocol.com/protocol/v1/extensibility#custom-requests).
- [Official Grok agent mode](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/15-agent-mode.md).
- [Official billing handler and response types](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/extensions/billing.rs), inspected September 10; source tree `SOURCE_REV` reported `c4ea71cfdbcdb21e32e41bc25a0043d7d4836714`.
- [Official ACP router](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/agent/mvp_agent/acp_agent.rs).
- [Official shared-pool explanation](https://docs.x.ai/grok/faq).

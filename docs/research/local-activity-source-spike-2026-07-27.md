# Read-only Local Activity sources in Codex CLI 0.145.0

Date: 2026-07-27
Issue: [#25 — Prove read-only Local Activity ingestion and Coverage](https://github.com/thrr87/codex-limits/issues/25)
Source baseline: installed stable `codex-cli 0.145.0`; official tag [`rust-v0.145.0`](https://github.com/openai/codex/tree/25af12f7e61572b0bc18ddb1008be543b91519b0), commit `25af12f7e61572b0bc18ddb1008be543b91519b0`

## Decision

Use a hybrid source:

1. Use stable `thread/list` with `useStateDbOnly: true` for bounded Task discovery and metadata.
2. Tail rollout JSONL incrementally for local token, turn, effective model, reasoning, compaction, and partial tool facts.
3. Do not use live thread notifications from the analytics app-server. A separate app-server process does not observe the in-memory event stream of a Task owned by another Codex process. `thread/list` and `thread/read` do not subscribe to it.
4. Do not call `thread/resume` to obtain a subscription. Resume loads or rejoins a Codex thread and makes the caller a subscriber. That crosses the product's read-only Task boundary.
5. Keep numeric Local Coverage **Unavailable**. The official protocol does not define ChatGPT account token activity as the same quantity as any local `TokenUsage` counter. Local breakdowns may still ship as local activity facts.

This decision is high confidence for Codex CLI 0.145.0. It must be checked again when the installed CLI version changes.

## Evidence boundary

This pass used only:

- the installed stable CLI's version and generated stable and experimental app-server schemas;
- official source and documentation from `openai/codex` at `rust-v0.145.0`;
- synthetic types and tests committed in that tag;
- one bounded local app-server probe using state-database-only `thread/list` and metadata-only `thread/read`.

The bounded probe necessarily read a real thread response. The protocol cannot omit `preview`, full path, or Git fields, so the probe discarded the response immediately. It retained and published no real Task IDs, paths, Source Content, account values, or credentials. It did not read a real rollout or account response.

The installed schema generator produced the relevant contracts in:

- `v2/ThreadListParams.json`;
- `v2/ThreadListResponse.json`;
- `v2/ThreadReadParams.json`;
- `v2/ThreadReadResponse.json`;
- `v2/ThreadTokenUsageUpdatedNotification.json`;
- `v2/GetAccountTokenUsageResponse.json`.

`useStateDbOnly`, `thread/read`, `parentThreadId` in returned `Thread` values, and `ThreadTokenUsageUpdatedNotification` are present in the stable schema. The `parentThreadId` and `ancestorThreadId` filters on `thread/list` require the experimental capability. The official schema-generation rules explain the stable and experimental split in the [app-server README](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/app-server/README.md#experimental-api-opt-in).

## A separate app-server does not receive another process's live Task events

### What the protocol promises

The official API overview says:

- `thread/start` and `thread/fork` auto-subscribe their connection;
- `thread/resume` reopens a thread and supplies the live subscription;
- `thread/read` reads a stored thread without resuming it;
- event notifications arrive after a client starts or resumes a thread.

See the [`thread/*` API overview](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/app-server/README.md#api-overview), [resume behavior](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/app-server/README.md#example-start-or-resume-a-thread), and [event notification contract](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/app-server/README.md#event-notifications).

### What the implementation does

The live listener reads events from a `CodexThread` held by that app-server's `ThreadManager`, then sends each translated event only to connection IDs subscribed to that thread. A thread-scoped sender drops the notification when there are no subscribed connections. The subscription registry and listener are in-memory objects owned by that app-server process. See:

- [`ensure_conversation_listener` and the listener loop](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/app-server/src/request_processors/thread_lifecycle.rs);
- [`ThreadStateManager` connection subscriptions](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/app-server/src/thread_state.rs);
- [`ThreadScopedOutgoingMessageSender`](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/app-server/src/outgoing_message.rs);
- [`thread/tokenUsage/updated` translation](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/app-server/src/bespoke_event_handling.rs).

`thread/list` and `thread/read` only build stored or process-local views. Neither calls the subscription path. `thread/resume` does: it loads or rejoins a live `CodexThread`, starts a listener, and adds the caller's connection. See [`thread_read_response_inner`](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/app-server/src/request_processors/thread_processor.rs) and the same file's `thread_resume_inner`.

### Conclusion

| Situation | Receives live Task notifications? |
|---|---|
| Separate app-server process using `thread/list` or `thread/read` | **No** |
| Second connection to the same app-server, but not subscribed to the thread | **No** |
| Connection that called `thread/start`, `thread/fork`, or `thread/resume` | **Yes** |
| Analytics client that tails the Task's rollout file | Not a protocol subscription; sees durable appended records |

Do not treat a `Thread.status` returned by the analytics app-server as the runtime status of a Task owned by another process. The implementation overlays status only for threads loaded in its own `ThreadManager`; another process's active Task can appear as `notLoaded`.

## `thread/list`

The stable 0.145.0 request supports:

- cursor and limit;
- sort by `created_at`, `updated_at`, or `recency_at`, ascending or descending;
- model-provider and source-kind filters;
- active or archived selection;
- exact working-directory filters;
- title search;
- `useStateDbOnly`.

The experimental capability adds direct-parent and ancestor filters. Returned `Thread` values already contain `parentThreadId` in the stable contract. See [`ThreadListParams`](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/app-server-protocol/src/protocol/v2/thread.rs) and [`Thread`](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/app-server-protocol/src/protocol/v2/thread_data.rs).

`useStateDbOnly: true` is the correct ordinary discovery mode. The schema defines it as returning from the state database without scanning JSONL rollouts to repair metadata. The local thread store routes this mode to its state-database listing functions. Omitted or false uses scan-and-repair behavior. See [`list_rollout_threads`](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/thread-store/src/local/list_threads.rs).

Important limits:

- The response always includes `preview`, normally the first user message, plus a full working directory and an unstable rollout path. The protocol offers no field projection. The collector must extract only approved metadata, reduce the directory to the Codex project label needed by the product, and discard the response object immediately. It must never log or persist `preview`, full paths, or Git remotes.
- `thread/list` does not expose the state database's `tokens_used` column.
- Status is local to the queried app-server's loaded-thread set.
- Relationship filters use persisted spawn edges and omit relationships that Codex does not record in that graph. The README explicitly excludes Review and Guardian threads from the descendant filter.

### Read-only nuance

`useStateDbOnly` prevents that request from scanning rollout files to repair thread metadata. It does not make the app-server process disk-read-only. App-server startup initializes SQLite, applies pending rollout backfills, and can move a damaged database aside before rebuilding it. See [`init_sqlite_state_db_with_fresh_start_on_corruption`](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/app-server/src/lib.rs) and [`codex_rollout::state_db::init`](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/rollout/src/state_db.rs).

The guarantee is therefore **no Task or account mutation by the selected request**, not zero writes to Codex-owned storage. Reuse one persistent app-server already needed for account reads. Do not launch a new process for each refresh.

## `thread/read`

`thread/read` accepts only:

- `threadId`;
- `includeTurns`, false by default.

It has no state-database-only option. It does not resume or subscribe to the thread. With `includeTurns: false`, it returns metadata and an empty turns array. With `includeTurns: true`, it reads persisted history; this is unsupported for paginated threads. See the [documented read behavior](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/app-server/README.md#example-read-a-thread), [`ThreadReadParams`](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/app-server-protocol/src/protocol/v2/thread.rs), and [`read_thread`](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/thread-store/src/local/read_thread.rs).

Even a metadata-only read may consult the rollout to improve metadata such as preview. Its response also includes the same source-content and path fields as `thread/list`. Use it only as a bounded fallback for one known thread when list metadata is insufficient. Do not use `includeTurns: true` in the Local Activity collector.

## Rollout JSONL contract

Every line is a `RolloutLine` with:

- a UTC timestamp string;
- an optional monotonic ordinal;
- a flattened tagged `RolloutItem`.

The item union includes:

- `session_meta`;
- `turn_context`;
- `event_msg`;
- `compacted`;
- response and other content-bearing records.

See [`RolloutLine`, `RolloutItem`, `SessionMeta`, and `TurnContextItem`](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/protocol/src/protocol.rs). The recorder writes one JSON object plus a newline and flushes after each record; rollouts live below the Codex sessions directory in date partitions. See [`JsonlWriter`](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/rollout/src/recorder.rs).

### Metadata whitelist

The fallback parser should recognize only these fields:

| Record | Allowed fields | Product use |
|---|---|---|
| `session_meta` | thread/session ID, forked-from ID, parent-thread ID, timestamp, source, thread source, agent role/nickname, CLI version, model provider, history mode, multi-agent version | Task identity, Task Tree, source version |
| `turn_context` | turn ID, effective model, effort, collaboration mode, multi-agent version | Per-turn workload mix |
| `event_msg.task_started` | turn ID, start time, context window, collaboration-mode kind | Turn interval start |
| `event_msg.task_complete` | turn ID, start/completion time, duration, time to first token, terminal error presence only | Turn interval end |
| `event_msg.turn_aborted` | turn ID and terminal state fields that exist in that source version | Interrupted interval |
| `event_msg.token_count` | numeric `info.total_token_usage`, `info.last_token_usage`, context window | Versioned local token observations |
| `event_msg.thread_settings_applied` | model, model provider, reasoning effort | Effective setting changes |
| `compacted` or durable compaction marker | IDs and window sequence fields only | Compaction count and boundaries |
| supported completed item tags | item class, status, timestamps, opaque IDs | Partial tool-class counts |

The parser must skip every content field, including messages, compacted text, response items, commands, arguments, output, diffs, code, URLs, prompts, paths, Git data, and tool payloads. It must not log a raw line or a decode error containing that line.

The official persistence policy is deliberately lossy. Token counts, turn start/completion, settings, and compaction-related records are durable. Tool records differ by legacy and paginated history modes, and many live begin/end events are transient. See [`is_persisted_rollout_item` and `should_persist_event_msg`](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/rollout/src/policy.rs). Therefore:

- turn timing is available when its versioned fields exist;
- effective model and effort are available from `turn_context`;
- compaction is available;
- tool class is partial;
- universal tool duration is unavailable;
- wait and poll time are unavailable unless a specific durable typed item proves them;
- Task active time and concurrency derived from turn intervals must disclose Local Coverage;
- Review and Guardian ancestry is incomplete.

### Incremental cursor contract

The implementation spike should persist, per source file:

- file identity from the operating system;
- thread ID from `session_meta`;
- byte offset after the last complete newline;
- last accepted ordinal when present;
- file size and modification time;
- a fixed-size replay fingerprint made only from accepted non-content fields, never from Source Content.
- a bounded checkpoint for the last accepted record, also made only from non-content fields.

The normalization state stores the source CLI version and history mode across incremental batches.

Rules:

1. Open rollout files read-only.
2. An unchanged file reads zero payload bytes. When metadata changes on the same file identity, verify one non-content checkpoint of at most 4 KiB, then read bytes after the durable offset.
3. If the final record has no newline, retain its start offset and retry after growth.
4. On rename, continue by file identity. Do not recount a move into the archived directory.
5. On identity replacement, verify the already processed prefix from non-content identities. If it matches, resume at the durable offset in a new source generation. If it does not match, require an explicit aggregate rebuild.
6. On truncation, start a new source generation and require an explicit aggregate rebuild.
7. Deduplicate records by `(thread ID, source generation, ordinal)` when ordinal exists. A verified continuation skips ordinals at or below its durable high-water mark. For older records without ordinal, use file identity plus byte offset and a non-content event key. The verified-prefix rule prevents a copied pre-ordinal history from replaying.
8. Never add `last_token_usage` values from replayed notifications.
9. Unknown record types or fields are skipped and counted as unsupported Coverage, not treated as corruption.
10. Do not rescan completed history on an ordinary refresh. Prefix verification and explicit rebuild are exceptional paths that may scan from zero.

## Token counter semantics

The local `TokenUsage` shape contains:

- input;
- cached input;
- cache-write input;
- output;
- reasoning output;
- total.

`TokenUsageInfo` contains cumulative `total_token_usage`, `last_token_usage`, and an optional model context window. `new_or_append` adds the latest usage to the cumulative fields. A resumed session seeds its state from the last persisted token-count record. See [`TokenUsage` and `TokenUsageInfo`](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/protocol/src/protocol.rs) and [`last_token_info_from_rollout`](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/core/src/session/mod.rs).

These counters are not uniformly exact:

- the public README says `thread/tokenUsage/updated` is accumulated, can be estimated, is persisted, and is replayed;
- `recompute_token_usage` estimates current history size and emits the ordinary token-count event shape;
- context-window fill operations can replace the total with a context-window value;
- the schema has no `estimated` flag.

The internal-only `rawResponse/completed` notification carries exact per-completion upstream usage, but it is not persisted or replayed and requires experimental raw events on a thread started by that app-server. It is unavailable to this read-only cross-process collector. See [the notification note](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/app-server/README.md#turn-events).

Collector behavior:

- keep each cumulative observation once;
- calculate a non-negative delta only inside one proven-continuous thread/source generation;
- on a decrease, replacement, missing predecessor, or version change, start a new segment and mark the delta unavailable;
- retain component values as local protocol facts;
- do not call them cost, billing, allowance, or account usage.

## Account and local token compatibility

`account/usage/read` returns:

- optional `lifetimeTokens`;
- optional daily buckets containing one `tokens` number;
- profile summary facts.

The app-server maps these fields directly from an opaque ChatGPT backend profile. Neither the protocol types nor backend-client types define whether account tokens include cached input, cache writes, reasoning output, local estimates, retries, subagents, other devices, or the same provider-side events as local `TokenUsage`. See:

- [`GetAccountTokenUsageResponse`](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/app-server-protocol/src/protocol/v2/account.rs);
- [`TokenUsageProfileStats`](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/backend-client/src/types.rs);
- [the account processor mapping](https://github.com/openai/codex/blob/25af12f7e61572b0bc18ddb1008be543b91519b0/codex-rs/app-server/src/request_processors/account_processor.rs).

No official 0.145.0 source establishes an equality such as:

`account lifetime-token delta = sum of local total tokens`

or:

`account daily tokens = sum of local blended totals`.

### Required product result

| Output | State |
|---|---|
| Account Token Activity | Available from the account API, with its own provenance |
| Local Token Activity by Task, agent, turn, model, and reasoning | Available or Partial from rollout metadata |
| Local component breakdown | Available or Partial; never billing |
| Numeric Local Coverage against Account Token Activity | **Unavailable** |
| Unattributed Movement in tokens | **Unavailable** |
| Qualitative source coverage | Available from observed/missing local intervals and source versions |

Do not divide one token total by the other. A future Codex release can enable numeric Local Coverage only if OpenAI publishes compatible definitions or adds a shared event identity and accounting contract.

## Capability matrix

| Fact | Stable app-server read | Experimental app-server read | Incremental rollout | Decision for 0.145.0 |
|---|---|---|---|---|
| Task ID and timestamps | `thread/list` | Same | `session_meta` | Stable list |
| CLI/source version | `Thread.cliVersion` | Same | `session_meta.cli_version` | Store per Task/source |
| Parent Task | Returned `parentThreadId` | Parent/ancestor server filters | `session_meta.parent_thread_id` | Stable result plus rollout |
| Full Task Tree | Partial | Spawn-edge descendants; Review and Guardian omitted | Partial parent IDs | Partial Coverage |
| Project label | Full working directory returned | Same | Full working directory present | Extract short local label, discard path |
| Cross-process live status | No | No | Infer only durable turn intervals | Unavailable as a live fact |
| Turn boundaries and duration | `thread/read(includeTurns: true)`, with history limits | Paginated list methods | Durable turn events | Rollout |
| Cumulative local tokens | No | Live notification only for owned/subscribed thread | Durable token-count events | Rollout, segmented |
| Exact per-completion tokens | No | Raw live event requires owned thread | Not persisted | Unavailable |
| Effective model and effort | No | Partial live settings | `turn_context` | Rollout |
| Tool class | Lossy and content-bearing | Paginated items, still content-bearing | History-mode-dependent | Partial rollout tags |
| Tool duration | No complete contract | No complete durable contract | Many begin/end events are transient | Unavailable |
| Wait or poll time | No | Partial live events | No universal durable pair | Unavailable |
| Compaction | Partial item projection | Partial | Durable markers | Rollout |
| Numeric account reconciliation | Account total exists separately | Same | Local total exists separately | Unavailable |

## Hard read-only boundary

The collector may call only the minimum read surface:

- `initialize`;
- `thread/list` with `useStateDbOnly: true`;
- optionally, bounded `thread/read` with `includeTurns: false`;
- existing account read methods owned by the account adapter.

It must never call:

- `thread/start`;
- `thread/resume`;
- `thread/fork`;
- `turn/start`;
- `turn/steer`;
- `turn/interrupt`;
- `review/start`;
- `thread/archive`, `thread/unarchive`, or `thread/delete`;
- thread name, metadata, settings, memory-mode, goal, compact, rollback, inject, shell-command, or background-terminal mutation methods;
- command or process execution methods;
- file write, copy, create, or remove methods;
- config write methods;
- account login, logout, reset-credit consumption, email, or other account mutation methods.

`thread/read` is safe at the Task-control level because the official contract says it reads without resuming. App-server startup is not disk-read-only, as noted above.

## Source-version record

Every normalized Local Activity event should carry:

- `source = codex-rollout-jsonl` or `codex-app-server-thread-list`;
- the Task's `cliVersion`;
- the collector's supported schema version;
- history mode when known;
- observation time;
- thread ID and event identity;
- Coverage and a named unsupported or discontinuity reason when applicable.

The Task's `cliVersion`, not the currently installed binary alone, selects compatibility behavior for historical records. Older records may omit ordinals, timestamps, duration, context-window fields, parent IDs, or cache-write tokens. Unknown future records must degrade to unavailable facts without stopping other sources.

## Open uncertainties

1. The 0.145.0 state database contains a `tokens_used` projection derived from the latest cumulative token-count event, but the stable app-server `Thread` response does not expose it. Direct SQLite access is not a supported app-server contract and should not ship as the primary adapter.
2. Compressed historical rollouts remain unavailable to the ordinary incremental tailer. An explicit rebuild may add a bounded materialization path later; ordinary refresh must not decompress completed history.
3. Tool, wait, and agent coverage changes by history mode and CLI version. The prototype keeps supported completed tool classes Partial and wait Unavailable.
4. Starting app-server can perform state-database maintenance. The measured warm-up cost must not be attributed to the rollout tailer.
5. No source in 0.145.0 proves account/local token compatibility. This is a product boundary, not merely an unimplemented parser.

## Fixture-backed prototype

The prototype implements the four approved seams:

- `ThreadProjectionSource` exposes only state-database-only list and metadata-only read requests. Its closed request type cannot express a Task-control method.
- `RolloutTailSource` opens a rollout read-only and persists file identity, source generation, byte offset, file size, modification time, latest ordinal, Task ID, a non-content processed-prefix fingerprint, and a bounded non-content checkpoint.
- `LocalActivityNormalizer` carries Task and token-segment state across incremental batches. It emits all supported facts with source metadata and emits named Unavailable or Partial facts instead of filling gaps.
- `LocalCoverageEvaluator` returns `comparable = false` and no percentage for CLI 0.145.0 because that source capability is not proven.

The historical fixture contains only synthetic IDs, timestamps, model metadata, numeric token counters, a tool class, and a compaction marker. The live-growing fixture proves that:

- an incomplete final line does not advance the durable offset;
- the line appears once after its newline arrives;
- a rename preserves file identity and does not rescan;
- identity replacement starts a new source generation;
- copied ordinal history does not replay because the non-content prefix fingerprint proves the prior offset;
- copied pre-ordinal history does not replay because the same fingerprint covers accepted facts without hashing Source Content;
- an older ordinal appended after a verified cursor does not emit again or lower the high-water mark;
- a replacement whose prefix cannot be proved returns `requiresRebuild` instead of claiming continuous additive history;
- truncate-and-regrow on the same file identity checks the last accepted bounded checkpoint and requests a rebuild when it changed;
- an unproved replacement clears the prior Task and ordinal state;
- stable `task_started` and `task_complete` records yield turn timing facts;
- an unchanged refresh reads zero payload bytes and decodes zero records;
- only whitelisted fields enter `RolloutRecord`; content-bearing and unknown records are skipped and counted.

## Measured overhead

Measurements ran on the fixture-backed Swift prototype in a debug XCTest process. They are a development baseline, not a production benchmark.

### Incremental rollout tailer

Representative fixture:

- 3,237,948 bytes;
- 20,001 complete records;
- one synthetic Task and 20,000 cumulative token observations.

Observed results:

| Work | Wall time | CPU time | Bytes read | Records decoded | Memory |
|---|---:|---:|---:|---:|---:|
| Explicit initial scan | 577.085 ms | Not isolated | 3,237,948 | 20,001 | 14,581,760-byte resident increase |
| 1,000 unchanged refreshes | 80.581 ms total; 0.081 ms/refresh | 80.283 ms total; 0.080 ms/refresh | 0 | 0 | 65,536-byte resident increase |
| One appended record plus checkpoint | 0.189 ms | Included in wall measurement | 325 | 1 | Below measurement resolution |

The whole isolated XCTest process reached 54,280,192 bytes maximum RSS.

### Persistent app-server

A separate stable `codex app-server --stdio` 0.145.0 process received only:

- `initialize`;
- `thread/list` with `limit: 1` and `useStateDbOnly: true`;
- `thread/read` with `includeTurns: false`.

Immediately after the reads it used 64,112 KiB RSS and 0.11 seconds of CPU time. After the first 15 seconds it used 102,912 KiB and 0.25 seconds. During the following 15-second warm-idle interval it stayed near 102,784 KiB and its reported CPU time remained 0.25 seconds.

The warm-up is consistent with the documented app-server initialization and state-database maintenance boundary. Local Activity must reuse the one persistent app-server already required for account reads. It must never start a second app-server for analytics.

### Recommended budgets

These budgets follow the measurement rather than precede it:

- An unchanged rollout refresh must read exactly zero payload bytes, decode zero records, and use no more than 1 ms wall and 0.5 ms CPU per checked file at the measured fixture scale.
- A changed-file refresh with at most 4 KiB appended must read no more than the appended bytes, one retained partial record, and one checkpoint of at most 4 KiB. It should finish within 5 ms per file.
- Ordinary refresh must never perform the 3.24 MB initial scan. An explicit rebuild at this scale should stay below 750 ms wall and 20 MB additional resident memory.
- File checks should run in bounded batches of at most 100 files before yielding, so the measured unchanged-file cost does not turn a large history into one long foreground task.
- Local Activity gets no separate app-server process or app-server memory budget. It reuses the account process; a second process is a failure.
- Production instrumentation should record aggregate bytes, record count, duration, unsupported count, and discontinuity reason only. It must not record paths, raw lines, IDs, or Source Content.

## Implementation gate for #12

#12 may proceed with local breakdowns only after the fixture-backed collector proves:

- no Task-control method is called;
- an unchanged refresh reads zero payload bytes, while a changed file reads only one bounded checkpoint plus appended or partial bytes;
- replay cannot increase a total twice;
- a partial final line cannot advance the cursor;
- rename or truncation creates no duplicate activity;
- raw Source Content never enters Derived Records or logs;
- source version and Coverage survive normalization;
- measured idle CPU, memory, bytes read, and refresh work are recorded.

Numeric Local Coverage, token-denominated Unattributed Movement, and any claim that local totals explain account totals remain out of scope until the token-definition contract changes.

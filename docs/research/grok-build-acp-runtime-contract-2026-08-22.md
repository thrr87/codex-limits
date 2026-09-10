# Grok Build ACP billing contract and runtime result

> **Correction — 2026-09-10:** The source-exclusion conclusion below is superseded. The probe used bare `x.ai/billing`; ACP requires `_x.ai/billing` on the JSON-RPC wire. Official stable 1.0.25 accepts the corrected method and passed a real authenticated read. The historical 1.0.5 binary has not been retested with the prefix, so its billing capability remains unproven. Grok is restored as a development Beta; expanded release checks remain pending. See [current validation](grok-build-validation-2026-09-10.md). The original observations and interpretation are retained below as historical evidence.

Date: 2026-08-22  
Status: Stable 1.0.5 external collector rejected for v1

## Verdict

The user's installed official Grok Build stable `1.0.5` binary executes normally, can start an external ACP agent, and completes `initialize`. It returns JSON-RPC `-32601 Method not found` only when Codex Limits asks that external ACP router for `x.ai/billing`; the result is identical with ordinary `agent stdio` and the source-recommended isolated `agent --no-leader stdio` mode. This does not diagnose a broken Grok installation or subscription.

The xAI source tree contains and routes a billing handler in a source snapshot that declares version `1.0.5`. xAI does not publish a matching repository tag or GitHub release that proves this snapshot built the distributed binary, whose local version string reports build `5115b46bc909`. Source capability therefore does not override the measured public surface of the user-installed executable.

Codex Limits defers Grok from shipped v1. It does not replace the missing method by reading credentials, reusing browser sessions, calling a private backend, or parsing the interactive TUI.

## Primary-source contract

xAI documents Grok Build agent mode as newline-delimited JSON-RPC 2.0 over the stdin and stdout of `grok agent stdio`. The source-recommended single-client form uses `--no-leader` so the caller owns the complete process rather than joining a shared leader. See [Agent mode](https://github.com/xai-org/grok-build/blob/9fabadea800fa6e2ed8ec91c4f45f02b7e2504f4/crates/codegen/xai-grok-pager/docs/user-guide/15-agent-mode.md#L45-L70) and the [bounded NDJSON reader](https://github.com/xai-org/grok-build/blob/9fabadea800fa6e2ed8ec91c4f45f02b7e2504f4/crates/codegen/xai-acp-lib/src/line_reader.rs#L1-L40).

The smallest billing flow is:

1. start `grok agent --no-leader stdio` with a caller-owned process group;
2. send `initialize` with protocol version `1`, no filesystem or terminal capabilities, and non-interactive startup hints;
3. wait for its response;
4. send `x.ai/billing` with empty parameters and a literal `/`;
5. close stdin, then enforce the caller's graceful and forced termination bounds.

`session/new` is unnecessary. It would create session, workspace, model, and persistence state without helping the process-global billing handler. The handler reads the process authentication manager directly. See the [ACP router](https://github.com/xai-org/grok-build/blob/9fabadea800fa6e2ed8ec91c4f45f02b7e2504f4/crates/codegen/xai-grok-shell/src/agent/mvp_agent/acp_agent.rs#L2180-L2465) and [billing auth gate](https://github.com/xai-org/grok-build/blob/9fabadea800fa6e2ed8ec91c4f45f02b7e2504f4/crates/codegen/xai-grok-shell/src/extensions/billing.rs#L200-L205).

An automatic collector must not invoke ACP `authenticate`; an unavailable cached login may otherwise enter an interactive flow. Authentication belongs only to an explicit user action in Settings. Billing requires first-party xAI OAuth/OIDC; a plain `XAI_API_KEY` does not satisfy the source's first-party auth predicate. See [authentication modes](https://github.com/xai-org/grok-build/blob/9fabadea800fa6e2ed8ec91c4f45f02b7e2504f4/crates/codegen/xai-grok-shell/src/auth/model.rs#L136-L151).

## Source-only response contract

The source handler prefers:

- `config.creditUsagePercent`;
- `config.currentPeriod.type`, `start`, and `end`;
- weekly and monthly period types kept distinct.

It retains legacy `monthlyLimit.val`, `used.val`, `billingPeriodStart`, and `billingPeriodEnd`. Optional facts include on-demand cap and usage, prepaid balance, unified-billing state, subscription tier, and bounded billing history. `config` may be null. The top-level `on_demand_enabled` and `subscription_tier` fields use snake case while the configuration uses camel case. See [billing types and fixtures](https://github.com/xai-org/grok-build/blob/9fabadea800fa6e2ed8ec91c4f45f02b7e2504f4/crates/codegen/xai-grok-shell/src/extensions/billing.rs#L13-L124).

Backend `productUsage` is not represented by the exposed type and cannot support a trustworthy Build-only breakdown. A future reader must label `creditUsagePercent` as the shared Grok usage pool, not usage created only by Grok Build.

The handler's internal HTTP request has a 15-second timeout and records a compact provider-owned unified-log entry after success. Codex Limits' stricter ten-second source deadline would take precedence, and successful future reads would remain demand-driven rather than frequent polling. See [billing request and logging](https://github.com/xai-org/grok-build/blob/9fabadea800fa6e2ed8ec91c4f45f02b7e2504f4/crates/codegen/xai-grok-shell/src/extensions/billing.rs#L200-L288).

## Executed stable 1.0.5 spike

The runtime test used `/Users/piotrciechowicz/.grok/bin/grok`, an installer-managed symlink to the stable `1.0.5` arm64 binary. Its 134,349,648 bytes and SHA-256 `3dfa7f04fbb5427a8fbead286591543aaecb478b3a0ab222c4329eca1a3b2f86` match independent downloads from both official xAI artifact origins.

The harness used a fresh isolated home, removed `XAI_API_KEY`, advertised no filesystem or terminal capability, sent no prompt, created no ACP session, and made no billable model request. The final `--no-leader` run produced:

| Observation | Result |
|---|---:|
| ACP `initialize` | Success |
| `x.ai/billing` | `-32601 Method not found` |
| Wall time including one-second shutdown boundary | 1.527 seconds |
| Child user + system CPU | 0.179 seconds |
| Maximum child RSS | 51,363,840 bytes |
| Captured stdout | 3,614 bytes |
| Captured stderr | 122 bytes |
| Isolated provider files | 34 files, 613,539 bytes |
| Graceful exit after stdin close | Did not finish within one second |
| Forced process-group cleanup | Complete; no surviving process |

Authentication and subscription tier cannot change `Method not found`, because routing fails before the billing auth gate. The user's working Grok subscription is therefore unrelated to this v1 source rejection.

## Re-entry gate

Grok may return when an official distributed release exposes a supported external read-only billing method. That exact executable must then pass:

- first-party personal and team authentication behavior without Codex Limits reading credentials;
- current and legacy schema fixtures, including zero-value ambiguity;
- the ten-second app deadline, cancellation, and one-second graceful-exit boundary;
- complete process-group cleanup and bounded output;
- transient RSS, CPU, and provider-owned write measurements;
- the shared lifecycle soak required of every shipped collector.

The exact installed bytes match independent downloads from both official xAI artifact origins and execute normally. Apple's strict verifier still rejects this standalone CLI packaging, as it also does for the working official Claude Code CLI. That diagnostic is neither an auth/subscription result nor a reason for Grok's deferral. Executable hashing belongs only to explicit setup or detected replacement and never to ordinary refresh.

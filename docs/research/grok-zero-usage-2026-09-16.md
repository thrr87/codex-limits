# Grok zero usage after a period reset

The 0.3.1 fix accepted a current period with an omitted `creditUsagePercent` but treated the percentage as unavailable. That interpretation was wrong for the current Grok credits schema.

## Provider evidence

The public grok.com application served [this JavaScript asset](https://cdn.grok.com/_next/static/chunks/3ezlkvn7-td91.js) on 2026-09-16. Its generated `fileDesc` contains `prod/grok/backend/proto/grok_build_billing.proto`:

- Syntax: `proto3`.
- Message: `grok_api_v2.GrokCreditsConfig`.
- `credit_usage_percent`: field 1, `TYPE_FLOAT`, singular, no `proto3_optional` flag and no oneof.
- `current_period`: field 8, `grok_api_v2.UsagePeriod`.
- `GetGrokCreditsConfigResponse.config` refers to that message.

The asset SHA-256 is `39f707417258763b6c3cb49bb31a61131a2705f6d4f16ce5be8fb1b4009652bc`; the decoded 9,266-byte descriptor SHA-256 is `37b0510d706ae2b9a8e582a11cfa2aa614110727c6e16fade942d2bd3c8e28f7`.

This is an implicit-presence numeric scalar. Its absent wire value is zero; [ProtoJSON omits default values for fields without presence](https://protobuf.dev/programming-guides/json/#presence-and-default-values). It is not an optional measurement whose absence means unknown.

The [official Grok CLI billing handler](https://github.com/xai-org/grok-build/blob/482711333c7195dc16a272777f86086d615e2afb/crates/codegen/xai-grok-shell/src/extensions/billing.rs) requests this credits configuration, decodes the percentage into a Rust `Option`, and preserves omission in ACP. Its [usage display](https://github.com/xai-org/grok-build/blob/482711333c7195dc16a272777f86086d615e2afb/crates/codegen/xai-grok-pager/src/app/effects/helpers.rs#L1461-L1471) falls back to zero. The schema evidence establishes why that zero is appropriate for a valid current-period response; the UI fallback alone was insufficient evidence.

## Decoder boundary

For a validated current weekly/monthly period, an omitted percentage decodes to 0% used / 100% remaining. Explicit values keep their existing finite-number validation and display clamp. Explicit null, boolean or malformed values remain rejected at the ACP boundary. Missing configuration, unknown period types, invalid dates and unusable legacy limits do not become zero usage.

Old 0.3.1 caches lacking a percentage remain readable, but are refreshed on demand instead of being considered a fresh numeric observation. Do not retrofit a zero into historical cache data: record the new successful response at its actual observation time.

## Reproduction

The installed Grok Build 1.0.30 returned a current weekly period without `creditUsagePercent`, `used` or `monthlyLimit`. A harness compiled from the production 0.3.1 collector reproduced `FAIL: current Grok usage percentage is unavailable`. The read used the existing ACP path, made no model request and retained no raw account response.

The same live check compiled with the corrected decoder returned 100% remaining and passed the snapshot cache round trip. The focused decoder regression first failed on the released implementation, then passed with the schema default applied.

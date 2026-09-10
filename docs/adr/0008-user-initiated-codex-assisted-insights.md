# User-initiated Codex-assisted insights

Deterministic analytics remains Local-only, but a user may explicitly invoke a separately labeled `Analyze with Codex` action to generate a Codex-assisted Insight from bounded evidence. The action must disclose that it sends a request to Codex and consumes allowance, and it must never run automatically. Metadata-only Analysis starts directly after the explicit action; Source-backed Analysis first shows a short preflight identifying the content categories that will be sent.

The product reads `model/list` before it exposes the action. It shows `Analyze with Codex` only when the catalog advertises the exact GPT-5.6 Luna Medium profile. If that profile is missing or catalog lookup fails, the action is absent. The product never falls back to GPT-5.5 Medium, Terra, Sol, another reasoning level, or the analyzed Task model. A stronger retry requires a new user action and an explicitly advertised profile.

The analysis Task receives only the bounded payload. It has no tools, cannot read more files, cannot change the workspace, and cannot control another Task. This explicit exception to ADR-0007 preserves user intent, privacy expectations, and control over analytics overhead.

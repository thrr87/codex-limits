# Keep account control read-only

Codex Limits reads account and activity data, calculates metrics, shows guidance, schedules local reminders, and runs user-requested Codex analysis, but it does not redeem resets, change Codex settings, or control tasks. Although the app-server exposes reset redemption, the product uses a Reset Reminder instead; this avoids hidden account changes and preserves user control.

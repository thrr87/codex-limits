# Retain analytics history until user deletion

Codex Limits keeps compact, account-partitioned Derived Records without a time limit until the user chooses `Delete analytics history`; Source Content is never copied into this store. This supersedes the 90-day retention rule in ADR-0006 for local account samples because long baselines, comparable-workload analysis, and personal trends lose value when old observations disappear. The existing user-selected folder remains limited to account usage samples; deep Task Tree, agent, model, Source Content-derived, and Codex-assisted records stay on the current Mac unless a separate decision expands that boundary.

Unlimited retention applies to the canonical on-disk store, not to resident memory or ordinary refresh work. Reader snapshots, chart queries, sync reconciliation, and analytics calculations use bounded ranges, indexes, or summaries; they do not keep or repeatedly decode every retained record. Long retention must not make steady-state RSS or ordinary refresh time grow proportionally with history age.

`Delete analytics history` removes the whole history owned by Codex Limits: every local Derived Record and every supported account-history generation in the selected sync folder, including records written by another installation. It preserves preferences. Deletion advances an empty sync generation so an offline Mac cannot restore an older generation later. If the selected folder is unavailable, the app keeps deletion pending, blocks imports from older generations, and does not claim that deletion is complete.

The app does not rebuild deleted history automatically. A separate explicit rebuild action may read only Codex sources that still exist. The product must not promise full recovery.

# Observer reports live in a durable user directory, and pre-release reports are not carried over

## Context

`2026-10-22_live_welcome_is_generated_and_agent_reports_leave_only_with_opt_in.md`
calls the observer's queue persistent, but pre-release observer builds kept it
in `insider-live` under the system temporary directory, which a reboot or
temporary-file cleaning can remove.

Two attempts to bring that queue along failed review. First, a one-time copy
with a completion marker could mark a copy done after a failure, and it
treated a queue created meanwhile as already migrated, which stranded the
old reports. Second, reading the old queue as a read-only extra source
counted reports twice when they were re-imported, hid valid reports at the
combined queue bound, and dropped its warning on submission.

## Decision

This supersedes the observer queue location implied by
`2026-10-22_live_welcome_is_generated_and_agent_reports_leave_only_with_opt_in.md`.
Everything else in it stands.

- The observer's reports directory is `INSIDER_LIVE_REPORTS_DIR` when set,
  else `insider-live` in the user's durable state directory:
  - `~/Library/Application Support` on macOS;
  - `$XDG_STATE_HOME` (when absolute) or `~/.local/state` on other Unix
    systems;
  - the local application data directory on Windows.
- Reports filed with pre-release builds in `$TMPDIR/insider-live` are not
  copied, read, or merged. Nothing there is changed. A person can open
  `observer-reports.jsonl` in that directory by hand.

## Why

The temporary-directory queue format was never released. Its contents are
smoke-test and agent-test reports, and the agent-test findings are already
recorded elsewhere. Carrying them over would need a migration that is safe
against partial failure, concurrent filings, and re-imports. That costs more
than the data is worth, and both attempts introduced defects of their own.

## Consequences

- An agent or developer who filed reports with a pre-release build must
  resubmit any they still care about.
- The observer has one queue, one ledger, and one place to look.

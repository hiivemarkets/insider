# Report submission states its authorization, a dry run vetoes every opt-in, and the welcome hash excludes the effective disclosure profile

## Decision

- **Dry run vetoes.** `mix insider.live reports submit --dry-run` never runs
  `gh`, whatever opt-in is present: `--confirm`, the observer's
  `config :insider, :live_report_submission, :github`, or the target's.
- **Authorization is stated before acting.** Every `reports submit` result
  carries `authorization`: `effective` (`dry_run`, `confirm`,
  `observer_config`, or `target_config`), `target` (the node a target opt-in
  covers, else `nil`), `opt_ins` (every opt-in present, strongest first), and
  `overridden_by` (`--dry-run` when it overrode one). A real submission
  writes the same record, with `will_submit`, to standard error as one
  `insider.live-authorization/v1` JSON line before its first `gh` call. The
  record names opt-ins and a node name only, never report text.
- **Reports cite a session.** The report context gains `session`: an
  explicit `report --session ID` (an ASCII identifier of at most 128
  characters, else `invalid_options`), else the session of the last target
  command against the same target. The node leaves it `nil`; older records
  are read with it as `nil`. `reports` and `reports submit` select by
  `--fingerprint` or `--session`, and `reports` groups by node and session.
- **Hash coverage.** The welcome's `effective_disclosure` (the node's current
  profile, its source, and what it discloses) is outside the hash, like
  `runtime`. The hash is the SHA-256 of every full-reference key except
  `hash`, `runtime`, and `effective_disclosure`. This supersedes the hash
  rule of `2026-10-22_live_welcome_is_generated_and_agent_reports_leave_only_with_opt_in.md`.

## Why

An agent test needed a guaranteed preview and had to leave the documented
command to get one, because a host opt-in could turn the plain command into a
real submission. The queue is shared across runs, and context named
only the last contacted node, so a run could not tell its reports apart.
The effective profile is a host setting that already changes the
disclosure rules an agent reads. It must be stated prominently
without making the contract's version change with it.

## Consequences

- Scripts that need a preview use `--dry-run`; it is safe under any host
  configuration.
- A consumer recomputing the hash must drop `effective_disclosure` as well.
- Adding an opt-in source means adding it to `opt_ins` and to this record.

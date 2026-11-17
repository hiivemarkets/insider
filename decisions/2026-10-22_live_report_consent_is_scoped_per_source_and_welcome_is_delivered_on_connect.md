# Live report consent is scoped per source, and the welcome is delivered on connect

Supersedes, in part,
[`2026-10-22_live_welcome_is_generated_and_agent_reports_leave_only_with_opt_in.md`](2026-10-22_live_welcome_is_generated_and_agent_reports_leave_only_with_opt_in.md):
its "Upstream only with an opt-in" rule, which let a target's configuration
authorize submission of every queued report. Everything else in it stands.

## Context

A review reproduced the gap: an observer queue holds reports filed locally
and imported from several nodes, and connecting to one node configured with
`:live_report_submission, :github` submitted another node's report without
`--confirm`. The same review found that the welcome was available only on
request, while the intent was that an agent connecting for the first time
receives it without asking.

## Decision

- **Consent follows the source.** Every observer queue row records its
  sources: `"observer"` for a local filing, the node name for each import,
  and `"unknown"` for rows written before sources existed. Deduplication
  keeps the union. `--confirm` and the observer's own
  `:live_report_submission` setting cover every report; a target's setting
  covers only reports whose every source is that target. Reports outside the
  opt-in stay pending and are counted as `not_authorized`.
- **Welcome on connect.** The first observer command against a target, of
  any operation, carries the whole welcome document under a top-level
  `"welcome"` key inside its single JSON document (the `subscribed` line for
  `watch`). Later commands carry a pointer with the delivered hash. Delivery
  is recorded per target, and only after the document carrying it was
  written, so a failed write leaves the next command to deliver it. No extra
  stdout document is printed.

## Consequences

- A merged report is never broader in consent than its narrowest source.
- An observer that has seen a target before shows only the pointer; a new
  reports directory, or a target not yet seen, receives the full document.

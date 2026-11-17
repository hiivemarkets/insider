# Live trends carry per-sample Poller series

## Context

Usability testing found that `trends` covered only Telemetry and Logger
summaries: port, binary, and mailbox growth was a first-to-last digest delta,
and agents sampled and computed rates by hand. `insider.live-trends/v1`
(decision `2026-10-22_live_summary_exemplars_trends_and_logger_bursts.md`)
admits additive fields.

## Decision

`insider.live-trends/v1` gains `"poller"`, `"poller_omitted"`, and
`"poller_untracked"`, folded from the window's Poller events as the digest
reads them, after the disclosure boundary.

- **Identity.** One series per metric and subject: `binary_bytes` and
  `port_count` (no subject) from `vm_sample`; `port_type` per port type from
  `port_top`; `message_queue_len` per process from `process_top` rankings
  and `process_sample`/`process_watch`, keyed by pid (subject: registered
  name, else initial call or pid), so two unregistered processes of one
  initial call never merge.
- **Units.** `bytes`, `ports`, `messages`; `per_min` is change per minute
  between the first and last point, an integer (the plain-term contract has
  no floats). `change` uses the trends rule: `flat` within 10%.
- **Points.** One per poller cycle (`cycle_id`): a later sample of a cycle
  replaces the earlier, in the points and in `max`.
- **Missing samples.** A process a ranking did not list has no point,
  never a zero. A port type counts zero only at a complete census: every
  port read (no `scan_limit`), every found type listed (`type_count`,
  nothing `omitted`), and below the 512-type bound. A type first seen later
  starts from a zero at each earlier complete census of the window, one per
  poller cycle (a later census of a cycle replaces the earlier, and the
  new point's own cycle gives no zero); an incomplete census never
  establishes a zero.
- **Coverage.** A mailbox series is `ranked` (rankings only), `watched`
  (every point a direct sample), or `mixed`; one watched point never makes a
  ranked stretch continuous.
- **Bounds.** 64 subjects per metric followed per window
  (`poller_untracked` counts samples of others), 500 recent points per
  series (the first point, the point count, the maximum, and the coverage
  count are kept apart, so compaction loses none of them), 10 series per
  metric shown (`poller_omitted`).

## Consequences

Agents get rates for leaks and backlogs from one call. A series is only
as continuous as its evidence: a ranked mailbox and an incomplete port
census leave gaps rather than invented zeros, so a reader must check
`coverage` and the points before reading a fall to zero as recovery.

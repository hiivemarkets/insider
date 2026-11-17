# Load reports localize missed scheduled operations

## Context

The `insider.load-report/v1` contract records one `missed_operations` total per
phase and fails the phase when it is nonzero. One retained run of the bounded
load profile reported ten missed operations in its instrumented phase, which
is exactly the work of one 10 ms tick at 1000 operations per second. The
report could not say which segment the misses fell in or whether a tick
deadline was overshot or work was left at a segment deadline, so the count
could neither be explained nor compared with later runs.

## Decision

Each phase summary carries a required `scheduling` section beside `host`:

- `missed_by_segment` counts misses in `warmup`, `steady`, `overload`, and
  `recovery`. Warmup precedes the measured interval, so its count is reported
  for localization only; `steady + overload + recovery` must equal
  `host.missed_operations`, and `overload` must equal
  `overload.missed_operations`.
- `missed_by_cause` separates `skipped_tick` (a tick deadline overshot by at
  least one whole tick) from `segment_end_remainder` (work still scheduled when
  the segment deadline passed). The two must sum to `host.missed_operations`.
- `max_tick_lag_us` records the largest observed overshoot of a tick or segment
  deadline inside the measured interval.

A report whose sums do not reconcile is invalid. The per-sample series keeps
only the cumulative `missed_operations` total. No pass/fail gate or profile
changes: any nonzero `missed_operations` still fails the phase.

`scripts/verify-load-evidence` re-derives file digests, manifest artifact
entries, profile binding, and identity consistency of an emitted evidence
directory offline. It requires `manifest.json` and `report.json` to be
byte-identical to their canonical encoding and recomputes `manifest.id` and
`report.id` from that encoding; a document whose bytes the canonical encoder
does not reproduce fails the directory rather than falling back to file
hashes. It does not validate a report against the current schema.

## Why

Attribution is cheap to record at the point where the workload loop already
decides that work was skipped or left over, and it is impossible to recover
afterwards from the total alone. Keeping the counters inside the existing
canonical report, with conservation rules enforced by the validator, means a
localized count cannot drift from the total it explains.

Alternatives rejected:

- Flat `missed_*` fields on `host`. Rejected to keep `host` a flat set of
  measurements and to make the reconciliation rules apply to one named section.
- Including warmup in the measured total. Rejected: it would change what
  `missed_operations` measures and therefore the gate.
- Per-sample cause counters. Rejected for now: samples already carry the
  cumulative total at each offset, and the extra keys would change the sample
  contract for a counter that normally changes once.
- Verifying evidence through `Insider.Load.Report.decode/1`. Rejected for the
  offline script: a schema change such as this one would make earlier retained
  evidence undecodable even though its bytes are intact.

## Consequences

- Reports produced before this change are no longer valid under the current
  validator; their retained bytes remain verifiable with
  `scripts/verify-load-evidence`.
- A nonzero miss count now names a segment and a mechanism. It still does not
  establish a cause on the host, and it grants no production or budget claim.
- Whether to add a lag-based gate, or per-sample attribution, is left to a
  later decision informed by retained runs.

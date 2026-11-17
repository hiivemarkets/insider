# The Recorder counts each eviction once, for its source, before deleting the entry

## Context

This record supersedes the eviction-accounting part of
`2026-10-22_recorder_reserves_per_source_shares_and_live_reads_are_paged.md`,
the bullet "Eviction accounting names the source". That record kept each
source's eviction count in the admission state, which the writer saves after
it has stored the new entry. The rest of that record stays in force.

Two review rounds showed that a collector killed
while evicting could leave the cumulative `evicted` counter and the source
counts disagreeing:

- The first form counted a source's evictions only in the saved state. A
  writer killed after evicting but before saving left `evicted` at 1 and
  every source at 0.
- The second form bumped a per-source atomic counter next to the global one,
  after deleting the entry. A writer killed between the two updates still
  left them disagreeing.

## Decision

- **One counter update per eviction.** Each share group has an atomic
  counter (`Handle.source_evictions`). An eviction adds 1 to its group's
  counter and only then deletes the entry. The Recorder keeps no separate
  global eviction counter: the `evicted` total reported by `status/1`, the
  freeze counters, and Live is the sum of the per-source counters.
- **The counts are conservative.** A writer killed after the count and
  before the deletion leaves an entry that is still retained but already
  counted. If that entry is evicted later, it is counted again. The counts
  therefore never fall short of the real evictions and can exceed them by
  the number of writers killed in that window. The total always equals the
  sum of the sources.
- **Receipt-range eviction stays exact.** `read_since/3` and a Live batch's
  `evicted` gap count the receipts missing from a cursor range, which does
  not depend on these counters.
- **Recovery rebuilds usage only.** The saved state keeps each source's
  retained events and bytes, which owner-death recovery rebuilds from the
  retained entries. The eviction counters are left as they are.

## Why

Exact counts would need an eviction journal that records the victim and its
group before deletion and settles it during recovery. That adds a write and a
cleanup to every eviction, for an error bounded by the number of collectors
killed while they were evicting. Overcounting keeps the loss visible: a
reader is told about at least every eviction that happened.

## Evidence

- `test/insider/recorder_shares_test.exs`:
  - A writer paused after evicting and before saving its state keeps the
    Logger eviction attributed after recovery. This failed on the previous
    revision.
  - A holder that counted an eviction and died before deleting the entry
    overcounts by one, and the entry is still retained.
  - 200 writers are killed while they are evicting. The total still covers
    every receipt that is no longer retained and equals the sum of the
    sources.

## Consequences

- `status/1`, `fill/1`, and Live `recorder.sources` document `evicted` as an
  upper bound after interrupted writes.
- A consumer that needs exact losses for a range uses the receipt-range
  `evicted` count.

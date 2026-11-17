# The Recorder reserves a share per event source, and Live reads are served in pages

## Context

A tool-comparison test on a demo shop node found two
problems with a rich Logger session at info level:

- the 4 MiB Recorder filled with Logger lines in about four minutes, and
  oldest-first eviction then took the early Poller samples the agent wanted
  for a trend;
- Insider's own processes grew to about 33 MB while serving large reads (the
  session Manager 16.3 MB, the Live owner 9.6 MB, the Session 7.7 MB).

A read made one collector call for up to 1,000 entries with a 16 MiB byte
bound, so the Session decoded and redacted the whole read, the Manager and
the owner each received a copy, and the owner then projected the events it
returned. Each process kept its grown heap after replying.

## Decision

- **Each event source has a reserved share of the Recorder.**
  `Insider.Recorder` takes `source_shares` (source to whole percentage, at
  most 16 sources) and `other_share` (the percentage every other source draws
  on together), summing to at most 100. Each share reserves that percentage
  of `max_events` and of `max_bytes`, rounded down. The default reserves
  `logger` 25, `telemetry` 15, `poller` 25, `otel` 10, `inspect` 5,
  `system_monitor` 5, and other sources 5, leaving 10 unreserved. The Live
  session Recorder uses the default.
- **A share reserves room without holding it.** A source may use any room
  no one else is using; shares only decide who is evicted.
- **Eviction order.** When a write needs room, the Recorder plans its
  victims before changing anything. A writer over its share (counting the
  incoming entry) takes its own oldest entries first, then the oldest of
  sources over their share; a writer within its share takes the oldest
  entries of sources over their share first, then its own. A normal write
  takes nothing else, so it never evicts the entries of a source within its
  share in both events and bytes; with no candidate it is dropped as
  `priority_protected`, as before.
- **Protected entries keep their precedence.** A normal write never evicts a
  protected entry. A protected write may evict any normal entry and then
  protected entries, never the freeze trigger, in the same own and
  over-share order before the rest. With one share group, eviction is the
  previous oldest-normal-then-oldest-protected order.
- **Eviction accounting names the source.** `fill/1` and `status/1` report
  `sources`: for each share group its `share_percent`, `reserved_events`,
  `reserved_bytes`, `retained_events`, `retained_bytes`, and `evicted`.
  Live `status` reports them as `recorder.sources`. The receipt-range
  `evicted` gap of a batch stays an exact count without sources: an evicted
  receipt's source is not kept, and keeping it would grow with every
  eviction.
- **Live reads are served in pages.** `Insider.Live.Batch` selects a read
  incrementally (`selection/3`, `add/2`, `finish/1`) from collector pages of
  at most 100 entries and 128 KiB of stored bytes. It keeps only the events
  it returns and counts the rest; pages after the first never move past the
  first page's newest receipt, so a read keeps one snapshot. The Session
  reports which bound ended each page (`"truncated_by"`), so a page cut by
  its byte bound is read on and one cut by its redaction deadline ends the
  read. The owner collects its garbage after replying to `events_since`
  and `stop` and after each push, and the Manager and Session after each
  page.
- **Insider reports its own memory.** Live `status` carries
  `insider_memory`: the `Process.info/2` memory of the owner, the Manager,
  the Session, and each collector, and the Recorder's tables with the event
  binaries they hold (`fill/1` `memory_bytes`).

## Why

Separate rings per source were rejected: they would hold room empty for a
quiet source and need a second set of bounds. A per-source cap was rejected
because a source alone should still be able to use the whole Recorder.
Shares as eviction floors keep one store, one receipt sequence, and the
existing bounds, and they make a flood pay for itself.

Paging was preferred to streaming batches out of the Session or reading the
Recorder from the owner: redaction stays in the Session under its trusted
classification policy, and the collector read contract only gains a field.

## Evidence

- On the base revision, a Live session of 64 events lost all three
  Telemetry events to 400 Logger lines; with shares, they and the Poller
  samples survive and `recorder.sources.logger.evicted` counts the loss
  (`test/insider/live/capacity_test.exs`).
- `bench/live_read_memory.exs`, 4 MiB of rich Logger events, a 1 MiB read
  and a read whose view hides every entry: the base peaked at 4.1 and 6.7 MB
  in the owner, 4.1 MB in the Manager, and 7.7 and 9.6 MB in the Session,
  and kept 2.5 to 9.6 MB per process after the read. With pages, the owner
  peaks at 2.9 and 0.7 MB, the Manager and Session at 0.3 MB, and they keep
  under 0.1 MB. The reads took 404 and 137 ms before and about 350 and
  110 ms after.
- `bench/recorder_shares.exs`: a flood that evicts on every write costs the
  same per write with shares as with one share (median p50 and p95 ratios
  about 1.0); the base took p50 49 µs and p95 198 µs on the same workload.

## Consequences

- A protected flood can still evict other sources' normal entries within
  their shares, after its own and over-share ones: crash evidence outranks
  samples.
- Shares act only when the Recorder is full; a session whose Recorder never
  fills behaves as before.
- The share of a source is fixed when the Recorder starts. Live does not
  expose shares as a start option; that, and per-source attribution of
  receipt-range evictions, are left to a later decision.
- A read makes one collector call per page, each draining the Logger and
  Telemetry inboxes, so a large read makes several calls instead of one.

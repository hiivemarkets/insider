# Live digest window losses are counted by a bounded read

Supersedes the loss-counting clause of
`2026-10-22_live_digest_reads_a_fixed_window_and_the_observer_prints_lean_compact_or_full_events.md`
("a read that ran past `upto` counts its receipt-range losses only within
the window (oldest receipts first)").

## Context

That clause assigned a read's aggregate losses to the window eviction-first,
assuming eviction removes the oldest receipts. The Recorder evicts normal
entries before protected ones whatever their age, so a later normal entry
can be evicted while older protected entries stay. A window of protected
receipts with one withheld receipt, read after a later normal receipt was
evicted, was reported with one `evicted` loss and no `redaction_withheld`
(found in review).

## Decision

- `events_since/3` takes `"upto"`, the newest receipt a read may return.
  The owner clips the collector read at `upto` before anything is selected
  (`Insider.Live.Batch.clip/2`), while the read still knows each withheld
  receipt: events and withheld receipts after it are left out, `next_cursor`
  stops there, and `evicted` is every receipt up to `next_cursor` that the
  read neither returned nor withheld. A continuation of the read never passes
  `upto`. The batch's `next_receipt` still names the newest receipt.
- A digest passes its window's end as `"upto"` on every read after the end
  is known, and folds batches as the read reports them; it never apportions
  aggregate counts. A batch whose `next_cursor` still passes `upto` is not
  folded: the window ends with `stopped_by` `read_past_window`.

## Consequences

- Window losses are exact for any eviction order. Losses after `upto` are
  reported by the read that reaches them.
- `"upto"` is a public read option and is listed in the welcome's
  `options.read`.

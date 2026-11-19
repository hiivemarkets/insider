# A view narrows only its own read unless the reader keeps it

## Decision

A read-time view (`"view"`, the observer's `--view-*` flags) narrows only the
read, or the subscription, that gives it, even when the read names a reader.
It never changes that reader's stored view on its own.

- A reader stores a view only by asking: `"view_keep" => true` (observer
  `--view-keep`) with a reader name and a non-empty view, on a read that
  reads (so not `baseline` with `"show"` or `"clear"`). Any other use of
  `"view_keep"` is refused with `invalid_options`, field `view_keep`.
- An empty view (`"view" => %{}`, observer `--view-clear`) clears the stored
  view, as before. `--view-clear` together with other view flags replaces the
  stored view with them, as `--view-keep` does; this keeps the documented
  meaning of that combination.
- A named read that gives no view applies the reader's stored view, and
  always says so: every result it narrowed carries a top-level
  `"stored_view"` (`"reader"`, `"view"`, `"hidden"`, `"source"`, `"note"`),
  and the note is the first line of `--human` text and of compact output.
  This covers events and pushed batches, digest, trends, trace, timeline,
  changes, mutations, baseline, and a subscription's reply. A compact
  `watch` prints the note once, before it subscribes.
- A read's `"source"` is `"reader"`: the reader's stored view as it is now,
  which `--view-clear` clears. A subscription that gives no view keeps the
  stored view it inherited when it subscribed, and later changes to the
  reader's stored view do not reach it. Its reply and pushed batches say
  `"source": "subscription_snapshot"`, and their note says that it is the
  view as it was at subscribe time and that another view needs a new
  subscription, not `--view-clear`.
- A read that stores or clears the stored view carries `"view_note"`, which
  is also its first line of text. A subscription that stores or clears it
  carries the note in its reply, and a compact `watch` prints it before it
  subscribes.
- The existing fields stay: `"reader"`, `"view"`, `filtered.view`,
  `"filtered_view"`, and `"view_note"`.

## Why

A newcomer ran `events --reader hunt --view-min-severity warning`. That view
silently became reader `hunt`'s stored view, so later `trace` and `timeline`
reads by `hunt` were narrowed too. The trace showed one orphan span, and its
text ended with `View of reader hunt hid 1071 events`; the agent concluded
that the trace was broken. The only notice that the view had been stored was
a `# note:` line at the bottom of a long output.

Rejected alternatives:

- Keep views sticky and make the notes louder. The read that stores a view
  is not the read that is misled, so a note on the storing read is easily
  missed, and a reader that wants a one-off narrow read (the common case)
  would have to clear the view after every such read.
- Remove stored views. A reader sharing a session with another agent still
  needs a lasting way to hide a known error signature or another agent's
  traffic; asking for it explicitly keeps that.
- Make `--view-clear` with other view flags clear the stored view and narrow
  only that read. It needs a second wire key for a rare combination, and it
  changes the documented meaning of that combination.

## Consequences

- Wire change: a read or subscription that gives a view with a reader no
  longer stores it. A client that relied on that must add `"view_keep" =>
  true`. `"view_keep"` is a new option of every read and of `subscribe/3`, and
  `"stored_view"` is a new top-level result field.
- `mutations` now stores and clears a stored view like every other read; it
  used to ignore both.
- A stored view can still hide events from a later read, but never silently:
  the read's first line and its `"stored_view"` name it and `--view-clear`.
- This leaves open whether a stored view should expire, and whether
  `--view-clear` should ever narrow a read without storing.

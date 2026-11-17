# Live digest defaults to the last minute by Recorder admission time

## Decision

A digest without `"since"` covers `"latest-60s"`: the events the Recorder
admitted in the last minute, up to the newest receipt when the digest starts.
`"since"` accepts `"latest-DURATION"` (a whole number of `ms`, `s`, `m`, or
`h`, 1 s to 24 h) beside an integer cursor and `"latest-N"`; `trends` accepts
the same values and keeps its session-start default.

A time window is measured on the Recorder's admission clock: the VM monotonic
microseconds taken with the receipt under the Recorder's write lock, carried
as `received_at_us`, and kept by the archive across amendments and after a
stop. Admission time follows receipt order; an event's own `wall_time` does
not and is never used to place the window. The start is found by a binary
search over cursors, each step an owner probe: the receipt and admission time
of the first disclosed event after a cursor, read past withheld receipts for
up to 1,000 entries, without a view, a lease renewal, or a cursor baseline.

The search never narrows past what it has shown to be old. A probe that meets
no disclosed event within its scan or time is undecided and is taken as
recent, so the window may start earlier than needed and says so with
`window.start_exact` `false`; a probe that reads to the newest receipt without
a disclosed event leaves the withheld receipts in the window, where the reads
report them as losses. A search the digest budget cannot finish is a
`timeout`, never a narrower or empty window.

`insider.live-digest/v1` gains additive fields: `window.since` (as asked),
`window.from_wall_time` (a time window's start as a wall time),
`window.start_exact`, `window.as_of`, `window.age_ms` (the newest event's age
by its `wall_time`), and a `window` (`since`, `first_receipt`, `last_receipt`)
on every hint. The human text's second line states the window, and each
`Next` line names the receipts and duration it was worked out over.

## Why

In testing, a digest without `--since` read a long session from its start,
ran out of its 3 s budget, and reported history about eight minutes old; the
agent had to find a receipt by hand. The question an agent asks first is
"what is wrong right now", so the default must be recent and must say which
window it read.

Event wall times cannot place the window. A Logger call can pass its own
time, a summary is stamped at its interval's end, and a Poller sample when it
was taken, so wall times are out of receipt order; a search over them
silently dropped recent events, as a review of an earlier window search
found. Admission time is monotonic in receipt order by construction, so a
binary search over it is exact, and the archive keeps it, so stopped
sessions behave the same.

Probes skip the lease and the cursor baseline so that probing never evicts
another reader's baseline (the owner keeps at most 64) or extends a session.
Taking an undecided probe as recent trades a possibly larger window for never
dropping a recent event; the flag keeps that trade visible.

## Consequences

- An event recorded in the window is in it whatever its `wall_time`; one
  recorded earlier is not, even if its `wall_time` is recent.
- `age_ms` and the human "newest event … ago" use event wall times, so a
  window of old-stamped events can read as older than its admission times.
- The window's start is exact unless `start_exact` is `false`; a later change
  that adds a Recorder index by admission time could make it always exact.
- `"since"` `0` keeps the previous whole-session behaviour, with a staleness
  line when its newest event is over a minute old.

# Live reads bound the events they return, and `watch` is one stream with one envelope

## Decision

- **Read bounds count returned events.** In `events_since/3` and every
  subscriber push, `"limit"` bounds the events returned and `"max_bytes"`
  their canonical JSON bytes (as `Insider.Live.JSON` would encode them); the
  first event is always returned. A separate `"scan_limit"` (1 to 1,000,
  default 1,000; 1,000 per push) bounds the retained events a read examines,
  whether its view shows or hides them. Events a view hides never count
  against `"limit"` or `"max_bytes"`, and an entry the redaction pass
  withholds never ends a read early: a read without a view takes `"limit"`
  entries and reads on past withheld ones within the scan budget. One public
  read keeps the snapshot it began with: its continuations never return or
  pass a receipt newer than its `next_receipt`. A read cut
  short by a bound ends just before the next event it would have returned,
  so the hidden events up to there are consumed and counted, and its
  receipt-range losses are recounted for that range.
- **`truncated_by` is part of the batch contract.** Every
  `insider.live-events/v1` batch carries `"truncated_by"`: `"limit"`,
  `"max_bytes"`, `"scan_limit"`, `"deadline"`, or `nil`. `"truncated"` keeps
  its meaning (more events wait at `next_cursor`).
- **Batches are contiguous.** Each subscriber batch starts at the
  `next_cursor` of the batch sent before it; a poll that is not sent never
  opens a hole.
- **The observer's `watch` prints one stream with one envelope.** Its first
  line (`"kind": "subscribed"`) is a full `insider.live-observer/v1`
  document: `schema`, `status`, `operation`, `target`, `installation`, the
  first-contact `welcome`, the session status as `result`, and the
  `insider.live-subscription/v1` reply as `subscription`. Every later line
  carries only its fields: `batch` lines `kind` and `result`; the final
  `stopped` line `kind`, `reason`, `events`, `next_cursor`, and, when the
  session ended, `state`. Error lines stay complete
  `insider.live-observer-error/v1` documents. The test fixture
  `tools/insider_lab/test/fixtures/live_watch_stream_v1.ndjson` pins each
  line's keys.

## Consequences

- This replaces, without a version change, the unreleased first form of the
  same contracts, in which a view's hidden events counted against
  `"limit"`/`"max_bytes"`, `"max_bytes"` counted stored bytes, and every
  `watch` line repeated the envelope. Insider is unpublished (see the README
  "Publication status"), no released consumer depends on either form, and
  the welcome document's hash changes with these contracts, so an agent that
  kept the old hash is told to read the welcome again.
- `insider.live-events/v1`, `insider.live-observer/v1`, and the observer's
  NDJSON stream keep their names. A later change to the stream shape needs a
  new stream version.
- A view read may examine up to 1,000 retained events per call; only the
  events it returns are fully projected through the disclosure boundary.

## Why

An agent test found that a sparse view starved (five samples from a
500-event read), that a late reader could not tail, and that `watch`
repeated about 1 KB of envelope per line and skipped receipt ranges between
batches. Counting only returned events, with a separate budget for the
work, keeps reads bounded while letting a narrow view make progress;
`truncated_by` tells the reader which bound to change.

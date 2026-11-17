# Live pairing marks are receipt cursors with masked labels

## Decision

A pairing mark (`Insider.Live.mark/2`, observer `mark`) is the session's
newest receipt when the mark is made, its time, its label and the reader that
made it. It is also recorded as a `live.mark` event (source `live`, so views
never hide it). A read since a mark starts after that receipt, so it holds
the mark's own event and everything after it:

- `"since" => "mark"` on `digest`, `trends` and `timeline`;
- cursor `"mark"` on `events_since`;
- `"mark:LABEL"` for the newest mark with that label;
- observer `--since-mark [LABEL]`.

An unknown label, or a session without marks, is the new error code
`mark_not_found`, with the newest labels. `marks/2` lists them
(`insider.live-marks/v1`). The new contract surface is additive:

- the `mark` and `marks` operations and their schemas;
- the `"mark"` cursor and since forms;
- `window.mark` on a digest, `mark` on a batch and a timeline;
- the bounds `marks_max` (256) and `mark_label_max_bytes` (120);
- the error code.

A label is operator text, normalised before it is kept:

1. It becomes one line: control characters turn into spaces and the ends are trimmed.
2. It is credential-masked (`Insider.Redaction.Credentials`) in every
   profile, so the strict profile keeps marks and masks labels by the same
   rule.
3. It is cut to 120 bytes at a character boundary.

A label of more than 1,024 bytes, or not valid UTF-8, is refused before any
work, so neither a mark nor a lookup can stall the owner. Masking comes before
cutting, so a cut never splits a secret out of the mask's reach. A lookup
label is normalised the same way, once, before the owner compares it with the
at most 256 kept labels; a refused one is never echoed. A session keeps its
newest 256 marks across amendments and after a stop, and counts the ones it
let go. A digest never counts Insider's own `live.mark` events (source
`live`); an application event of the same kind is counted.

## Why

An agent pairing with a programmer who clicks in the app had to guess a time
(`--since latest-60s`) or remember a cursor, and the window then held either
too little or the noise before the click. Making the mark a receipt cursor
reuses every read path unchanged: disclosure, gaps, views, the digest's fixed
window and the timeline scan. The mark is taken just before its own event is
recorded, so the window may also include events admitted during the mark
call; none from before it are included.

Asking the collector for the receipt of the recorded event would have changed
the collector session's record contract. Placing the window by wall time
would have brought back the ordering problems that the digest's
admission-time window
(`2026-10-24_live_digest_defaults_to_the_last_minute_by_recorder_admission_time.md`)
fixed.

Labels come from the operator, not the application, so the strict profile
keeps them. They can still hold a token pasted by mistake, which is why every
profile masks them.

## Consequences

- A read since a mark is exact in receipts and does not depend on clocks.
- Marks are bounded per session and are not part of `handoff`. A peer lists
  them with `marks`.
- A mark needs a running session. A stopped session keeps its marks, and they
  can still be read since.
- The mark's event is subject to the Recorder's eviction like any event. The
  mark itself (its cursor) is kept by the owner, so a read since an evicted
  mark's receipt still starts in the right place and reports the eviction as
  a gap.

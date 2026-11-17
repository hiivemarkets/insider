# Oracle runner bounds output redaction and withholds output past the bound

## Context

`decisions/2026-10-21_oracle_runner_uses_a_test_path_overlay_and_saves_versioned_runs.md`
saves `output.txt` only through a fail-closed output policy. It did not limit
the cost of that policy. Review found that redaction runs after the child
command's deadline, so the capture bound did not limit it. With 64 overlapping
passthrough values over a 1 MiB capture, redaction went past a 16-million-word
heap. With a one-byte value between separators it kept one span per two
bytes. The fallback also split the whole capture into a list of lines just to
count them.

## Decision

This adds to the 2026-10-21 record; it does not replace it. Redaction of the
captured output is bounded in time and in memory:

- All passthrough values are matched by one compiled pattern in a single
  left-to-right scan. Overlapping matches are merged as they are found, and
  each finished span is written straight into the output. Lines are kept or
  withheld in one more pass. No list of spans or lines is held.
- At most 64 values, 1 KiB each and 16 KiB in total. At most 16,384 replaced
  spans. A work budget of 2^27, where each match call is charged the length of
  the longest value.
- Past any bound the run saves nothing captured. `output.txt` is the fixed line
  `[insider.oracle: output withheld: <reason>]`. The record's `output` object
  gets an optional `withheld` field naming the reason:
  `secret_count_exceeded`, `secret_bytes_exceeded`, `redaction_work_exceeded`
  or `redaction_count_exceeded`. Every captured line counts as withheld; lines
  are counted by scanning for newlines, and a line split between head and tail
  without an omission is one line.
- `withheld` is absent on every other run, so the schema stays
  `insider.oracle-run/v1`. The decoder accepts it only with a known reason and
  zero redactions.

## Why

A fixed budget turns an input-dependent blow-up into a recorded, fail-closed
outcome. Saving partial output past a bound would need a second rule for what
part is safe to keep. Withholding everything keeps the existing guarantee
that no passthrough value is saved. Rejected alternatives:

- Per-value scans with a final sort: their work grows with the number of
  overlapping values.
- Raising the heap limit: it moves the ceiling without bounding the work.

## Consequences

- A run whose output would cost more than the bounds to redact still yields a
  complete record, with the exit status, suite and oracle report, but no
  diagnostics. The caller sees why in `output.withheld` and can narrow the
  passthrough set or the output.
- The bounds are constants, not switches. Raising them is a later decision.
- A legitimate run that prints a value more than 16,384 times, or that has 64
  short overlapping values over several MiB, is withheld rather than
  redacted.

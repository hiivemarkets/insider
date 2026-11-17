# Rich rendering runs no application code in the emitter, and keeps Ecto redaction from start-time metadata

## Context

`2026-10-22_live_disclosure_is_a_host_profile_and_credentials_are_always_masked.md`
said rich values render through each struct's own `Inspect` implementation,
which keeps fields an application already hides (for example Ecto
`redact: true`) hidden. Review showed that this runs application code in the
emitting process: a `report_cb`, a custom `Inspect` implementation, or a
custom calendar's callback can block the logging or Telemetry-emitting
process indefinitely, and `inspect` escaping let secrets past text masking.
This record supersedes that paragraph ("Rich values are rendered in the
emitting process… Structs render through their own `Inspect`
implementation…") and leaves the rest of that record in force.

## Decision

- **No application code in the emitter.** Rich rendering in a Logger or
  Telemetry handler never calls a `report_cb`, a struct `Inspect`
  implementation, or a calendar callback. Structs render field by field with
  a `"__struct__"` name. Only `Date`, `Time`, `NaiveDateTime`, and `DateTime`
  values in `Calendar.ISO` use their text form; other calendars render field
  by field. A report renders field by field under `"report"`, and its message
  is the sanitized report text.
- **Mask before rendering.** Every term is sanitized before any `inspect`
  (with `structs: false`) or `io_lib` formatting: credential-named pairs in
  maps, keyword lists, and two-element tuples are masked whatever the value
  type; strings and the leading characters of lists are text-masked; bytes
  that are not UTF-8 are withheld.
- **Bounded before it allocates.** Maps are read by iterator and tuples by
  index, up to 32 entries; only the first 8,192 bytes of a binary and the
  first 8,192 elements of a list are validated and scanned; chardata is
  walked under a part and byte bound. Depth 5, 2,048 nodes per inspected
  term, byte budgets, and a 50 ms per-payload deadline fail closed to a
  marker. Masking patterns compile in the live owner at session start.
- **Ecto redaction is preserved through trusted metadata, not emitter
  calls.** At session start the live owner (never an emitter) asks every
  loaded module that exports `__schema__/1` for
  `__schema__(:redact_fields)`, each call in its own process under one
  200 ms deadline, keeps answers that are short lists of atoms, and stores
  them as module → fields in a protected ETS table. Emitters only read the
  table; a listed field becomes `"[REDACTED:redacted_field]"` with a
  `redacted_field` mask record. A schema that does not answer in time, or is
  loaded after the session started, falls back to masking fields whose names
  look like credentials.

## Why

Collector failure must never block or slow the host application without
bound, so the emitter cannot run code it does not own. Credentials still
matter in development even when the data is anonymized: redact fields
usually hold tokens and password hashes. Asking schemas once, in the owner,
under a deadline, keeps that protection without putting application code on
the hot path. Reading `__schema__` from compiled abstract code was
considered; it depends on debug info being present and is harder to bound,
so the owner-side call with a kill-on-deadline worker per module was chosen.

## Consequences

- Fields an application hides only through a custom `Inspect`
  implementation (not Ecto's `redact: true`) are visible in rich output
  unless their names look like credentials.
- The schema table reflects modules loaded when the session started.
- Session start can take up to 200 ms longer; the owner's start reserve
  covers it.
- A calendar value outside `Calendar.ISO` is less readable (its fields, not
  its text).

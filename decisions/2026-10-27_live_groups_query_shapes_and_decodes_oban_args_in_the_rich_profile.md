# Live groups query shapes, and decodes Oban args in the rich profile

## Context

Testing found two misses:

- **Repeated queries:** on a slow page, two of three agent runs had the right repeated query spans in a flat trace list, but blamed another repeated query.
- **Oban args:** every run decoded Oban's args by hand. Oban Pro's decorator stores the decorated call's argument as a `term-` prefixed, unpadded Base64 Erlang term.

Grouping queries reads statement text. Decoding Oban args runs `binary_to_term` on application data in the emitting process. Both are disclosure and runtime-safety boundaries.

## Decision

- **Query shapes.** A query's shape is a hash of its statement with every literal, `$N` parameter and IN list replaced. No parameter, and no statement text, leaves the shape.
  - Under strict, where spans carry no statement, the table alone is the shape.
  - The caller comes from Ecto's own stacktrace (the repo's `stacktrace: true`), as the rich profile already records it. Otherwise it is the parent span's name, otherwise unknown, and the line says which.
  - `trace` and the digest compute groups at read time, over disclosed events, so a narrowed profile narrows them too.
- **Oban job names and counts in every profile.** `attributes.oban` on `oban.job.*` events holds the job id, worker, queue, attempt, max attempts, state, and the args' top-level keys. Keys must be identifier-shaped, and there are at most 16 of them. These are names and counts from the code, never an argument's value.
- **Decoded Oban args, rich only.** `payload.oban_args` holds the job's args, with each Oban Pro `term-` value decoded in the emitting process. The decoding:
  - accepts Base64 of at most 64 KiB;
  - uses `:erlang.binary_to_term/2` with `:safe`, so no new atom is created;
  - stops at a depth of 4;
  - leaves an undecodable value as it was.

  The result is rendered and credential-masked by `Insider.Collector.Rich`, up to 2,048 bytes.

## Why

The agent needs the repeated shape and its caller together, above the flat list, to pick the right N+1. A hash keeps a shape comparable without carrying the query. Oban job names are what an agent filters by. The decorated call's argument is evidence, so it is captured only where rich evidence is allowed, and decoded only with `:safe` and bounds, so no atom can be created and no size is unbounded.

## Consequences

- `insider.live-trace/v1` gains `repeated_queries`, `insider.live-digest/v1` gains `repeated_queries` and the `n_plus_one` anomaly, and `oban.job.*` events gain `attributes.oban` and `payload.oban_args`.
- Under strict, the job's worker, queue and argument keys are disclosed. They are code identifiers.
- A decorated term that references a function or another non-data term is rendered as Rich renders any term. It is never called.

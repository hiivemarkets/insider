# Live GraphQL outcome reads payloads only through the operation's selections

## Decision

`Insider.Collector.GraphqlOutcome` never treats a GraphQL response key as
structure. A response key is whatever the document's author chose, and an alias
can give any field any key: `__typename: password` puts a password under
`__typename`. A payload is read only through the current operation's own
selections, following inline fragments and named fragment spreads:

- the `__typename`, `errors`, `field`, and `type` fields are found by their
  schema names in the document, then read by the response key the document gave
  them;
- a top-level error's `path` is resolved segment by segment through the same
  selections to schema field names. A path that does not resolve is withheld and
  counted.

Selections are merged by response key, as GraphQL merges them. A key that
fields of different schema names share (possible on mutually exclusive
fragment types: `... on A { value: __typename } ... on B { value: password }`)
depends on the runtime type, so it is never read; for `errors` that makes the
outcome incomplete. A `__typename` value must be a GraphQL name and, when the
selection set has fragments with type conditions, one of those types.

An OpenTelemetry span has no selections. Its recorded result
(`graphql.response.result`) is read only for top-level `errors` and whether
`data` is present, never for payload names. A span's result is therefore
`errors` or `partial` when it has top-level errors, and `nil` (unknown) when it
has none. A span's error paths keep only segments that are themselves names.

Every kept name must still look like an identifier and be at most 48 bytes.
Each path segment is checked before it is appended, so an oversized segment is
withheld without the path being built.

The emitting process does bounded work:

- the document walk visits at most 2,048 selection nodes in all, nests
  fragments at most 8 deep in one selection set, expands a spread once per
  selection set, and reads the first 256 named fragments; hitting a bound, or
  a spread of an unknown fragment, makes `"complete"` false (4 levels of
  64-wide distinct spreads, 16,777,216 paths, take about 0.14 ms, against 5.22 s
  unbounded);

- names come from at most 64 top-level fields and 64 entries of each error list;
- counts are exact up to 4,096;
- when a bound leaves anything unexamined, `"complete"` is `false` and the
  result is never `ok`.

## Why

The outcome is published as value-free and reaches compact lines, digest
signatures, and trace text under the rich profile with no redaction. A review
reproduced a leak with a real Absinthe schema: a synthetic password value
appeared as a typename, a validation field, and a validation type.
Validating that a string is shaped like an identifier does not help, because a
value can be shaped like one.

Rejected alternatives:

- **Denylisting suspicious keys:** an alias can take any key.
- **Masking every payload name under rich:** loses the outcome agents need
  (`fields=[totalPrice]`), and the blueprint already records which field
  each key belongs to.
- **Reading the span result's payload with a "looks structural" heuristic:**
  that heuristic is exactly what the alias defeats.

## Consequences

- A client that renames `errors` or `__typename` is still read correctly,
  through its aliases.
- A schema whose validation payload is not an `errors` list of `field` and
  `type` fields reports no payload errors.
- A payload's validation errors are visible only on the Telemetry event
  (`absinthe.execute.operation.stop`), which joins the same trace. They are
  never visible on a span.
- Reading span payloads would need a recorded selection set or schema
  provenance, and is left to a later decision.

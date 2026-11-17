# Oracle reports stay v1 with additive targets and unverified context

## Context

The fixed Lab-only ExUnit oracle artifacts observe one application-env key or
one Telemetry event per selected test command. Agents investigating a candidate
often need several keys of the same application in one run, and they need a way
to tie a report line back to their own ticket, revision, or command record
without Insider growing a cross-run receipt store.

## Decision

Both oracle artifacts keep their `/v1` schemas. New capability is additive:

- The application-env oracle accepts either `INSIDER_ORACLE_KEY` or a bounded
  `INSIDER_ORACLE_KEYS` list of 1 to 16 distinct keys in the same application.
  Exactly one selector must be set; both or neither is a typed operational
  failure (`conflicting_key_selectors`, `missing_key_selector`), as are too
  many keys (`too_many_keys`) and repeated keys (`duplicate_key`). Each key
  keeps the existing 255-byte valid-UTF-8 bound and is still resolved only by
  comparing already-loaded atoms.
- A single-key report keeps the existing top-level per-key fields. A multi-key
  report carries a `targets` list with one entry of those same fields per key
  in request order and an aggregate top-level `status`/`unchanged`: `changed`
  if any key changed, otherwise `inconclusive` if any key is inconclusive,
  otherwise `unchanged`. Each key is fingerprinted with the same per-run HMAC
  key and 1 MiB serialization bound; values are never emitted.
- Both artifacts echo an optional `INSIDER_ORACLE_CONTEXT` verbatim as
  `context`. It is bounded to 1,024 bytes of printable UTF-8 without control
  characters, is `null` when unset, and fails closed as `invalid_context`
  otherwise. The artifacts never parse or act on it, and every report,
  including an `operational_failure`, declares
  `context_is_caller_supplied_and_unverified` beside
  `caller_must_bind_test_and_revision` in its `limitations`.

## Why

Bumping to `/v2` would force every consumer to change for callers who still
select one key, while the single-key shape itself did not need to change. New
top-level fields (`context`, `key_limit`, `context_byte_limit`) and the
optional `targets` list are ignorable by a v1 consumer that reads the fields it
already knows; the aggregate `status` keeps the existing status vocabulary.

Echoing an opaque handle is the smallest change that lets a caller correlate
output. Validating, signing, or storing that handle would make Insider the
owner of test and revision provenance, which the oracle decisions deliberately
leave with the agent. Treating the echo as unverified keeps that boundary and
avoids implying the report is bound to anything the artifact did not observe.

Rejected alternatives: a `/v2` schema with a `targets` list for the single-key
case too; a nested or JSON-typed context; interpreting the context as a test
path or revision; reporting a multi-key run as several lines, which would make
"missing output" ambiguous when a later line is lost.

## Consequences

- One selected command can observe up to 16 keys of one application with one
  output line and one aggregate status.
- A multi-key report has no top-level `key` or per-key fields; consumers read
  `targets`. Aggregation never promotes an inconclusive key to unchanged.
- The `context` field is caller-controlled text. It is evidence of what the
  caller asked to echo, not of which test or revision produced the report, and
  it can be anything printable, so it must not be displayed as trusted output.
- Cross-application key sets, verified provenance, cross-run receipts, and any
  further schema change remain later decisions.

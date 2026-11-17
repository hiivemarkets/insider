# Live severity comes from failure shapes, and unselected values leave drop records

## Context

An agent test of Insider Live found two gaps between the
welcome document and behaviour. `phoenix.router_dispatch.exception` and the
`phoenix.endpoint.stop` of a 500 were recorded as `info`: live sessions
register every Telemetry event with phase `event`, so only an `exception`
phase made an event an `error`, and a `min_severity` view of `error` hid the
failure. And a session started without `telemetry_measurements` returned
`measurements: {}` with empty `redactions`, although the welcome said every
withheld value is a drop record.

## Decision

- **Severity from shapes.** `Insider.Collector.Telemetry.Outcome` decides,
  in the emitting process, whether an event reports a failure: its name ends
  in `exception`, or its metadata has `result` `{:error, _}` or `:error`,
  `conn.status` or `status` 500 to 599, `kind` `:error`, `:exit`, or `:throw`,
  or an `error` that is neither `nil` nor `false`. Such an event is
  `error`. It reads only those shapes: a tag, a status class, an exception
  kind, and presence. No other metadata value is read, and the decision
  records nothing beyond the severity. The record-time gate uses the same
  rule for summary `errors` and the minimum-duration bypass, so the two
  cannot disagree. The welcome's `severity` table is generated from it.
- **Drop records at collection.** The Telemetry collector writes a `drop`
  record, under its policy id, for what an event did not record: one per
  withheld measurement whose name the collector's `nameable_measurements`
  option lists, one counting the other withheld measurements, and one
  counting withheld metadata keys. A name outside that list is never
  retained, as before. Live passes the host measurement allowlist, so an
  agent sees exactly the names it may select on its next start. The live
  boundary moves these records from the event to the read entry's
  `redactions`, beside its own drop and mask records.
- **The welcome says what is not collected.** Logger message content in the
  strict profile is not collected at all and leaves no record; the welcome
  says so instead of promising a record for every withheld value.

## Why

An agent filters by severity to find the failure; a failure filed as `info`
is lost exactly when it matters. Status classes, result tags, and exception
kinds are code-level facts about the outcome, not user data, and reading
them is already what the gate did to keep errors past a minimum duration.

A drop record is the only way an agent learns that a value exists and was
left out, rather than absent. Naming only host-approved measurement names
keeps the collector's rule that unknown keys are never retained, while
still telling the agent the one thing it needs: which measurement to ask
for.

## Consequences

- More events are `error`: every failed Ecto query, every 5xx response, every
  Oban plugin run with an error. A custom event that uses `kind`, `status`,
  `result`, or `error` with these shapes for something else is rated `error`
  too; the rule is documented so a reader can tell why.
- Every Telemetry event recorded with an allowlist policy now carries up to
  18 small `drop` records in its `redactions`, with exact counts; named
  records are dropped (and counted unnamed) when the manifest would exceed
  Event v1's 4,096-byte redaction bound, so the event is never lost; a
  strict live event typically carries two. Events grow by about 100 bytes per record.
- `Insider.Live.Report` context gains `last_local_operation` and
  `last_local_error_code` under the same `insider.live-report/v1` schema;
  records without them are read with them as `nil`.

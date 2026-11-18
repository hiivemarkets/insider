# Insider Live: OpenTelemetry traces and GraphQL

[Index](../README.md) · [Glossary](../glossary.md) · [Cheat sheet](../cheat-sheet.md)

Finished OpenTelemetry spans, request traces, request waits and bursts, the GraphQL outcome of a request, kept
traces and mutation records, and the loopback OTLP receiver that joins a frontend's spans to the backend's.

## Contents

- [OpenTelemetry spans and traces](#opentelemetry-spans-and-traces)
  - [Capture](#capture)
  - [Bounds and losses](#bounds-and-losses)
  - [Draining](#draining)
  - [Span events](#span-events)
- [Read one request as a trace](#read-one-request-as-a-trace)
  - [Trace result](#trace-result)
  - [Trace options and text](#trace-options-and-text)
  - [Hide and collapse](#hide-and-collapse)
- [Repeated query shapes](#repeated-query-shapes)
- [Oban jobs](#oban-jobs)
- [Pin a trace](#pin-a-trace)
  - [Failed, slow, and mutation traces are kept by default](#failed-slow-and-mutation-traces-are-kept-by-default)
- [Response values](#response-values)
- [Kept mutation records](#kept-mutation-records)
- [Timeline of a process or request](#timeline-of-a-process-or-request)
- [Request waits and bursts](#request-waits-and-bursts)
- [GraphQL outcome](#graphql-outcome)
  - [Outcome fields](#outcome-fields)
  - [How Insider reads a payload](#how-insider-reads-a-payload)
- [Frontend traces (OTLP HTTP receiver)](#frontend-traces-otlp-http-receiver)
  - [Receiver output](#receiver-output)
  - [Session binding and lease renewal](#session-binding-and-lease-renewal)

## OpenTelemetry spans and traces

A node instrumented with OpenTelemetry (`opentelemetry` and its Phoenix, Bandit, Ecto, Oban, Absinthe, Req, Tesla,
or Finch libraries) records each request as a tree of spans. The tree gives the parent and child of every segment,
timed, across processes. `:telemetry` events alone cannot give this. The `"otel"` component records those spans in
the session. `trace/3` reads one trace back with the Logger and Telemetry events of the same trace.

```sh
mix insider.live start "${N[@]}" --component logger --component otel --component telemetry
```

The start and amend option `"otel_min_duration_ms"` (observer `--otel-min-duration-ms`, 0 to 3,600,000, default 0)
drops shorter spans unless their status is error.

### Capture

The component needs the OpenTelemetry Erlang SDK on the node. `capabilities/0` reports it as `otel.sdk_present`.
Without the SDK, `start/1` returns `component_unavailable`. The component never adds, replaces, or reconfigures a
span processor, exporter, tracer, or sampler. The SDK ends every recorded span in `otel_span_utils:end_span/2`.
This function returns the finished span before the node's own processors receive it. The component traces that one
function with a match specification that sends only its return value. So each finished span reaches the otel
collector as one trace message, and the node's processors and exporters run exactly as before. A development node
configured with `traces_exporter: :none` still exports nothing anywhere. On OTP 28 and later the trace is an
isolated trace session. It cannot conflict with another tracer, and its removal touches nothing else. OTP 27 has
only node-global tracing, where a process has one tracer and cleanup could clear another tool's. So on OTP 27
`start/1` returns `component_unavailable` with reason `requires_otp_28`. Stopping the session removes the trace
(the receipt's `components.otel` is `absent`). The collector's exit removes it too.

### Bounds and losses

The otel component exists only where live observation is allowed (development, test, and ci). Its queue bound is
soft. A BEAM trace message is in the collector's queue before anything in Insider can refuse it. Refusing it
earlier would take a native tracer module. So Insider throttles the capture but does not control admission.

A pause check (a process that watches the queue) reads the collector's queue every millisecond. It pauses the trace
while more than 1,024 span messages wait, and resumes it at 256. While the trace is paused, ending spans send
nothing, and Insider does not observe them. Every read whose interval overlaps a pause reports it with a `nil`
count. The gap is `otel_paused_ongoing` when the pause lasts as the read is built. It is `otel_paused` when the
pause started since the reader's cursor was issued, or was ongoing then, and has ended.

A subscriber's batches follow the same rule. A span received while more than 1,024 wait is counted as `otel_shed`
without being built. So Insider releases its memory when it receives it. No count or byte bound applies to what
waits between two pause checks.

Measurements, not limits (OTP 29, spans of two attributes, one of 200 bytes): about 1,060 waiting spans (590 KiB)
at 38,000 spans a second from four processes. Up to 19,987 (9.6 MiB) and 30,367 (15 MiB) waited in two runs at
about 10 million a second from eight processes that end spans back to back. A delayed pause check let 80,000 spans
queue. 32 spans that each held a 1 MB attribute retained 32 MB with no pause, because the SDK's default attribute
value length is unlimited.

A hard bound (an optional span processor that the host configures) is a separate, later change. The decision is
`decisions/2026-10-22_live_otel_capture_is_a_soft_bounded_dev_only_throttle_with_unknown_pause_losses.md`.

Insider bounds each span's size when it builds its event: the name at 256 bytes, the status message at 1,024, the
rendered span attributes at 7,000, and the event at Event v1's 16 KiB. Insider counts every received span once:
recorded, refused by the Recorder (a `recorder_*` gap), `otel_invalid`, `otel_shed`, or filtered by the record-time
gate. The gate has two parts. `"exclude_origins"` reads the initial call of the process that ended the span, so
Oban's own polling queries are not recorded by default. `"otel_min_duration_ms"` drops shorter spans unless their
status is error. The `filtered` field counts both under `"otel"`.

### Draining

Each read first asks the otel collector to process the spans that ended before it, for at most one second. The
drain is bounded, not a complete barrier. If more spans wait than it processes in that second, it returns with the
rest still waiting (the collector's `pending`). A later read processes them, and nothing is lost. The read's call
to the collector has its own two-second bound and waits behind spans already queued. A call that runs out of time
makes the component's accounting unavailable for that read (`otel_accounting_unavailable`, `"count" => nil`). This
is a timeout, not a loss.

When the session seals its ingress or stops, the drain is terminal. What it cannot process within its second is
counted without being built, for at most half a second more. Insider reports it as `otel_abandoned` with its exact
count. If even that count cannot finish, the component's final accounting is unavailable and the gap is
`otel_accounting_unavailable`. So a span that ended is always recorded, shed, filtered, invalid, abandoned, or
under a reported unknown gap. Insider never discards it silently.

### Span events

A span is an `insider.event/v1` with `source` `"otel"` and `kind` `"otel.span"`. Its severity is `error` when its
status is error, otherwise `info`. A [GraphQL outcome](#graphql-outcome) can raise it. Its `wall_time` is the
span's end, and its `subject` is the process that ended it. It has `causality.trace_id` and `causality.span_id`.
`attributes` carries `trace_id` (32 lowercase hex digits), and `span_id` and `parent_span_id` (16 hex digits, or
`nil` for a root). It carries `name`, `span_kind` (`internal`, `server`, `client`, `producer`, or `consumer`),
`status` (`ok`, `error`, or `unset`), and `status_message`. It carries `service` (the tracer provider's
`service.name`) and `scope` (the instrumentation library). `capture` is `sdk`, or `ingest` for spans handed in with
`Insider.Collector.Otel.ingest/1`. It ends with `start_wall_time` (ISO 8601, microseconds) and `duration_us`.

In the rich profile `payload` carries `span_attributes`, rendered and masked like Telemetry metadata, and
`status_message`, the span's status description. The strict profile collects neither. It withholds a status message
recorded under rich with a drop record.

## Read one request as a trace

`trace(session_id, trace_id, options)` reads one trace: its spans as a tree, with the same trace's Logger and
Telemetry events in time order. The observer takes the id as `--trace-id` (`--trace` is the same flag) and needs a
session with `--component otel`.

```sh
mix insider.live trace "${N[@]}" --session SESSION_ID --trace-id TRACE_ID --human
mix insider.live trace "${N[@]}" --session SESSION_ID --trace-id TRACE_ID --human --collapse sql --hide auth
```

**Trace context.** The SDK keeps the active span's ids in the process's Logger metadata (`otel_trace_id`,
`otel_span_id`). A Logger event without explicit `trace_id` or `span_id` metadata takes them as its causality. So
does a Telemetry event whose policy names no correlation keys. Logger, Telemetry, and span events name their
process the same way: `subject` `%{"namespace" => "process", "scope" => node, "value" => "<0.1234.0>"}`.

### Trace result

`trace/3` reads the session's retained events through `events_since/3`, so the disclosure boundary applies. It
reads for at most 4 seconds, newest first. A first read from cursor 0 with `"upto"` 0 returns no event. It returns
the newest receipt and the session's cumulative losses since its start. Insider keeps these losses even when no
receipt exists yet. Then it reads pages of 500 receipts downwards, each with `"upto"` its upper receipt. So it
finds a recent trace or request in a long session even when the budget ends before the oldest receipt.

The first read's newest receipt bounds event selection and receipt-range accounting (such as `evicted`). Events
received after it are left out. Cumulative losses that have no receipt (`recorder_*` and ingress losses) are
reported as the largest total since session start that any of the scan's reads observed. So they can include losses
that happened during the scan. The scan's reads report those totals whatever cursor they start at, and they issue
no cursor baseline. So a cursor that another reader issued neither turns them into deltas nor moves that reader's
accounting.

It returns `insider.live-trace/v1`:

- `spans` and `root_span_ids`.
- `items` in time order: a span at its start, an event at its `wall_time`, and a parent before a child at the same
  time. Each item has `at`, `at_us`, `receipt`, `depth` in the span tree, `span_id` (the span it belongs to),
  `joined_by`, the disclosed `event`, and its `redactions`.
- `joined_by`: `trace_id` for an event that carries the trace id. `pid_window` for an event without any trace id
  whose process ended one of the trace's spans and whose time falls inside that span. The window also covers up to
  `window_slack_us` (1 ms) after the span's end when no span covers the event. Insider places such an event under
  the shortest such span. An event of another trace never joins.
- `unjoined`: `missing_parent_span_ids` and `missing_parents` (parents that were not captured: another service,
  before the session, evicted, or filtered), `events_without_time` (listed last), and `spans_without_process`
  (ingested spans, which cannot join by window).
- `scan`: `cursor` and `next_cursor`, the lowest and highest receipt read, `direction` `newest_first`, `reads`,
  `examined`, `unread`, `complete`, and `ended_by` (`deadline`, `no_progress`, or a read's error code).
- `gaps`: the reads' gaps by reason. Receipt-range losses are summed, and cumulative losses count once. When the
  scan ended early, `scan_truncated` (scope `receipt_range`) counts the receipts the scan did not reach.
- `truncated`, `truncated_by` (`limit` or `max_bytes`), and `omitted_items`. A scan that ended early is never
  reported as a plain empty result. An empty `items` list with a `scan_truncated` gap means that the rest of the
  session was not read.

### Trace options and text

`"limit"` (`--limit`) is 1 to 1,000 items, default 200. `"max_bytes"` (`--max-bytes`) is 1,024 to 1,048,576
canonical JSON bytes of the items, default 262,144. The first item is always returned. For `"hide"` and
`"collapse"`, see [Hide and collapse](#hide-and-collapse). `"human"` (`--human`) adds `text`.

`text` is the span tree. Each span is followed by its children and the events joined to it, in time order. It has
one line per span or event, with its offset from the trace's first item and the span's name, kind, duration,
status, and GraphQL outcome. It has at most `"limit"` lines and `"max_bytes"` bytes, and it counts the lines it
left out. Before the first item, the text states the reads' losses (`Lost: evicted 659 (receipt_range), …`) and an
unfinished scan (`Incomplete scan: ended by deadline; 100 older receipts unread`). These lines are outside the line
bound. `timeline` text does the same. Spans that no root reaches (a malformed parent cycle) follow in time order.
The observer's `trace --human` prints `text` alone.

### Hide and collapse

`"hide"` and `"collapse"` take up to 8 rules each. `sql` matches a span or event whose name contains `repo.query`
or starts with an SQL verb, or whose span attributes have `db.system` or `db.statement`. `auth` matches a name that
contains `authoriz` or `authenticat`. Any other text (up to 64 bytes, no whitespace) matches a prefix of the span
name or event kind.

`"hide"` drops the matching spans and events from `items` and `text`. What was under a hidden span hangs from its
nearest shown ancestor, and `depth` counts shown ancestors only. `"collapse"` folds each run of matching siblings
in `text` into one line that counts the run and everything under it, such as `… 830 sql (830 spans, 412.300ms):
my_app.repo.query:users ×600, …`. `omitted` counts both by rule: `%{"hidden" => %{"auth" => 12}, "collapsed" =>
%{"sql" => 830}}`. The text's first line repeats them. The observer takes `--hide sql,auth` and `--collapse sql`
(comma-separated, repeatable).

## Repeated query shapes

A trace result's `repeated_queries` groups the request's Ecto queries over the whole tree, not run by run. It
groups them by source table and statement shape, never by parameters (internal: `Insider.Live.QueryShapes`). A
query span is an `otel.span` named `….query:TABLE` (OpentelemetryEcto), or one that carries `source` or
`db.statement`. A query event is a repo's `*.repo.query` Telemetry event.

A trace counts its query spans when it has any, else its query events (`counted_from`). So a query recorded both
ways counts once.

The shape (8 hex digits) hashes the statement after a one-pass lexer normalizes it:

- Every literal becomes `?`: quoted strings with `''` and `E'…'` escapes, dollar-quoted strings, numbers in every
  form and sign, `TRUE`, `FALSE`, `NULL`, and `$1`-style parameters.
- Comments are dropped.
- A list, an `ARRAY[…]`, and a run of `VALUES` rows of literals fold to one.

A statement that cannot be read whole gets no shape, so no remaining literal is hashed. Examples are an
unterminated string, identifier, or comment, a statement that a renderer cut, and one over 16 KiB. Under strict,
spans carry no statement. Their group's shape is unknown (`label` `TABLE (shape unknown)`). Query events, which
disclose no table, are counted but not grouped (`repeated_queries_ungrouped`).

Each group has `source`, `shape`, `label` (the table, with its shape when the table has several), `count`,
`total_us`, and `from` with `from_kind`:

- `stacktrace`: the first application frame of Ecto's stacktrace, from a repo query event of the same table and
  shape. The repo needs `stacktrace: true`.
- `parent_span`: the query spans' parent.
- `nil`: unknown.

Groups repeated twice or more lead the text after its first lines, the most repeated first, at most 5, within
`max_bytes`. A line counts the groups it left out:

```text
Repeated queries in this request (by table and statement shape, never parameters):
  order_items × 25 from MyApp.Orders.list_items/2, 31 ms total
  users × 3 from span "resolve items" (no repo stacktrace recorded), 3.9 ms total
```

**N+1 in the digest.** The digest's `repeated_queries` lists, per trace in the window, the groups of a known shape
repeated 10 times or more (at most 5 traces). An unknown shape is no evidence of an N+1. Its anomalies add
`n_plus_one`, one per pattern (at most 3), with the command to read the trace (`trace --trace-id … --human`):

```text
N+1 queries in one request: order_items × 25 from …, 31 ms total (trace …).
```

Spans without a trace id are not grouped. `query_evidence` says what the
analysis read: `seen`, `examined` (at most 8,192 query spans and events), `omitted`, `cap`, `span_names_omitted`
(parent names past 8,192), and `complete`. The text says when queries were not examined.

## Oban jobs

An `oban.job.start`, `oban.job.stop`, or `oban.job.exception` event carries `attributes.oban` in every profile:
`job_id`, `worker`, `queue`, `attempt`, `max_attempts`, `state` (the stop's outcome, else the job's), and
`args_keys`. `args_keys` holds the args' top-level keys among the first 64 that the map yields (identifier-shaped,
at most 16), never a value. `args_keys_truncated` is set when there were more. This is constant work in the
emitting process, whatever the args hold. The rich profile keeps the args' top-level `term-` strings by reference
(at most 4, of at most 2 KiB each). When the event is read, `payload.oban_args` holds the args as the payload
rendered them, with those values decoded. Insider decodes unpadded or padded Base64 with `binary_to_term` and
`:safe`, so no atom is created. A compressed term (whose expansion is unbounded) and one that does not decode stay
as they were. The result is rendered and credential-masked like any rich value, at most 2,048 bytes.

`trace` and `timeline` text show the job in at most 400 characters, such as `worker=MyApp.Workers.SendReceipt
queue=default attempt=1/20 state=success args={…}`. Under strict the text shows `args_keys=[…]` instead of
`args={…}`. An Oban job's span (OpentelemetryOban, rich) shows its `worker`, `queue`, and `attempt`. Its args are
on the job's events.

## Pin a trace

The Recorder is bounded, so a busy session can evict a trace before an agent reads it. A crawl, for example, can
evict tens of thousands of events. `"retain" => true` (observer `trace --retain`) pins the trace. The owner copies
into a store apart from the Recorder (internal: `Insider.Live.Retention`) the trace's events that the Recorder (or
the archive) still holds, and every later event of the trace.

```sh
mix insider.live trace "${N[@]}" --session SESSION_ID --trace-id TRACE_ID --human --retain
mix insider.live start "${N[@]}" --component logger --component otel --component telemetry --retain-traces 4
```

The start and amend option `"retain_traces"` (observer `--retain-traces N`, 0 to 64, default 0) keeps the N most
recently active traces the same way. The owner copies new events on its push tick (every 500 ms, at most 1,000
entries and 100 ms a tick) and before `status` and `trace`. Kept events are raw, redaction-checked entries. `trace`
passes them through the session's disclosure boundary and the reader's view. It resolves the view against the trace
index, as a read's view is resolved. So a service or route view keeps a kept trace's correlated Logger and
Telemetry events. `trace` adds the kept events that its scan did not read.

The store holds at most 8 explicit pins, 4,096 events, and 4 MiB in all. Past a bound, the traces kept by default go
first (below), then the least recently active automatic trace, then the oldest events of the oldest pin. A ninth
pin lets the oldest pin go to the `retain_traces` pool.

A trace result's `retention` says `pinned` (`explicit`, `auto`, `failed`, `slow`, `mutation`, or `nil`) and `events`
kept. `restored` counts kept events that the scan did not find, because the Recorder had evicted them. `lost` counts
events dropped by the store's bound. `missed_receipts` counts receipts that the Recorder evicted before the owner
could copy them while the trace was kept. Some may have been its events. Its text says the same in a `Retained:`
line. The first time an agent reads a trace that is not kept after the Recorder evicted events in the scanned receipts,
`retention.hint` and a `Hint:` line say how to pin one. `status` reports `retention`: the bounds, `retain_traces`,
the pinned trace ids, events, bytes, `evicted_traces`, `dropped_events`, and `missed_receipts`. A stopped session
keeps its retention for its read-only window.

### Failed, slow, and mutation traces are kept by default

Insider keeps some traces without `retain_traces` or `--retain`, so a `trace` call right after a request that
failed, was slow, or ran a mutation finds it. Each reason has its own pool of at most 16 traces, the least recently
active let go first (`evicted_traces`), so a burst of failing background calls cannot push out a mutation trace.

- `failed`: a traced event with severity `error` or `critical`, such as an exception, a 5xx, a failed span, GraphQL
  errors, or a Logger error. On with the logger, telemetry, or otel component.
- `slow`: a traced Telemetry event whose `duration` or `total_time` measurement, or a span whose `duration_us`, is
  at least 500 ms (fixed, `status`'s `retention.slow_trace_ms`). On with the same components.
- `mutation`: an `absinthe.execute.operation.stop` whose outcome's `operation_type` is `mutation`. On with the
  telemetry component.

A trace with several reasons takes the strongest: mutation, then failed, then slow. Its events before the one that
made it notable come from a lookback: the last 4,096 traced events (and 4 MiB) of traces not yet kept, and of
automatic traces that `retain_traces` let go, so a large request survives until its stop or error arrives. The
store and the lookback together hold at most 8 MiB on the target. Events that fell out of the lookback count as the
trace's `lost`. Insider keeps these loss counters for the 2,048 traces whose counters were updated last. Past that,
the least recently updated counter goes, counted in `status`'s `retention.loss_counters_evicted`.

Default retention never costs what `--retain` and `retain_traces` keep. An automatic trace that turns notable stays
automatic until the pool lets it go, and only then takes its reason. Past the store's bounds, slow traces go first,
then failed, then mutation traces. A kept trace's `retention.pinned` names its reason, and its text says
`Retained: kept because it failed`, `kept because it was slow (≥ 500 ms)`, or `kept because it ran a GraphQL
mutation`. `status`'s `retention` adds `keep_failed_and_slow`, `keep_mutations`, `failed_traces`, `slow_traces`,
`mutation_traces`, each pool's `*_traces_max`, `slow_trace_ms`, `mutation_lookback_max` (the lookback's events, for
every reason), and `lookback_bytes_max`. The decisions are
`decisions/2026-10-25_live_keeps_mutation_traces_by_default_and_names_the_graphql_client.md`,
`decisions/2026-10-25_live_default_mutation_retention_never_costs_explicit_retention.md`, and
`decisions/2026-11-18_live_keeps_failed_and_slow_traces_by_default.md`.

## Response values

This needs the rich profile. `"values" => true` (observer `trace --values`) adds `values`: the response data of the
trace's GraphQL operations. Insider flattens it to `path = value` fields (`order.items[1].amount = "14154.60"`),
each with the operation and receipt it came from.

```sh
mix insider.live trace "${N[@]}" --session SESSION_ID --trace-id TRACE_ID --human --values --values-path 'order.total*'
```

Insider records the data on `absinthe.execute.operation.stop`, under the rich
profile only, as `payload.graphql_data`: the operation's response `data`. Insider never trusts a response key,
because an alias such as `label: password` can name any field. In the emitting process, Insider resolves each key
through the operation's merged selections to its schema field. It uses the [GraphQL
outcome](#how-insider-reads-a-payload) rules and bounds.

- A field whose schema name or key is credential-named is masked whole (`[REDACTED:credential_key]`, children and
  list items included).
- A key that no selection made is withheld (`[WITHHELD:unresolved_field]`). So is a key that fields of different
  names share on exclusive fragment types.
- Everything past 6 levels or 2,048 values is withheld the same way.

The rich renderer then renders and credential-masks the result (at most 32 entries per map or list, 5 levels, about
6 KiB per operation). Floats keep their exact text, as strings. The rest of that event's rich metadata leaves the
blueprint out.

`"values_paths"` (observer `--values-path PATTERN`, at most 8) keeps only matching paths and implies `values`. `*`
matches any text. The result and the text show at most 200 fields in all, each value at most 160 bytes of JSON. A
longer string is cut at a character boundary and ends in `…`. Any other long value becomes
`[WITHHELD:value_bytes]`. Such a field has `"truncated" => true`. The rest are counted per operation. An operation
stop that `"hide"` removed gives no values. Under the strict profile Insider refuses `values` with
`disclosure_denied` (`"field" => "values"`, `"required" => "rich"`). It refuses before it scans the session or
changes its retention, so a refused `"retain"` pins nothing. A trace with no recorded response data says where
values come from. When the reader's view hid events, it says that the operation stops may be among them
(`values.view_hidden`).

**Mutation inputs.** The values also show the inputs that a mutation received, under the path prefix `arguments.`
(`arguments.placeOrder.input.price.amount = "14.20"`). Insider records them with the response data, rich only, as
`payload.graphql_arguments`. They are the current mutation's top-level fields, by schema name. Each field has its
arguments by schema name, with their values after Absinthe's input conversion. Insider never records the raw
`variables`, whose names the client chooses. A credential-named argument is masked whole. Insider renders, masks,
and bounds the rest as it does the response data (at most 2,048 JSON bytes, taken from the data's budget).
`"values_paths"` selects among them as among the response fields.

## Kept mutation records

A session with the telemetry component keeps a compact record of each GraphQL mutation (an
`absinthe.execute.operation.stop` whose outcome's `operation_type` is `mutation`). A record holds only these
fields:

- `receipt`, `at`, `operation`, `result`, `error_count`, and `user_error_count`.
- `typenames`: the response types. A `ValidationError` inside a 200 is `result=ok types=[ValidationError]`.
- `trace_id`, `pid`, and `user_agent` (the client's, from `graphql.client`).
- `ids`: up to 8 record ids among its converted arguments, input objects inside lists included. An id is a field
  named `id` or ending in `Id` or `_id`, with an integer value or a string of at most 64 bytes that is not
  secret-shaped.

The owner copies the records from the Recorder on the same push tick as kept traces. It keeps them in a ring of at
most 4,096 records apart from the Recorder. So a later flood of logs or queries does not evict them.

`status`'s `mutations` counts every loss, with `records` and `swept_through`. `dropped` counts the oldest records
past 4,096. `missed_receipts` counts receipts that the Recorder evicted before a tick read them. Some may have been
mutations. Under the strict profile a record's `operation`, `typenames`, `user_agent`, and `ids` are withheld
(`nil` or `[]`). Kept records pass the reader's view (given or stored) as their operation stops would.

`mutations(session_id, options)` lists them as `insider.live-mutations/v1`: `records`, oldest first, and the ring's
accounting as `mutations`. `"id"` (observer `--id`) keeps the records whose `ids` hold it. `--human` prints one
line each.

```sh
mix insider.live mutations "${N[@]}" --session SESSION_ID --id 'RECORD_ID' --human
```

```text
Kept mutation: updateOrder result=ok types=[ValidationError] at ... (receipt 812, pid <0.4211.0>, user agent my-sync-client/2.3, trace 5bf9..., ids ord-123)
```

`trace` adds `mutations`: the kept records of the trace, each with `evicted` (whether a Recorder read still finds
its receipt). Its `text` names the records that its items do not show (`Kept mutation: setFeatureToggle
result=ok at ...`), as `evicted from the Recorder` or `still recorded, but not among the items shown`.

## Timeline of a process or request

`timeline(session_id, %{"pid" => pid})` (observer `--pid`) returns every source's events whose `subject.value` is
that process. `timeline(session_id, %{"request_id" => id})` (observer `--request-id`) returns a request's events.
These are the events that carry its id (Logger metadata `request_id`, or an `x-request-id` header of a conn in rich
Telemetry metadata). They include the events of their processes within the request's time window (the span of those
events, where a Telemetry event counts its duration). They include every event and span of the traces they carry.

```sh
mix insider.live timeline "${N[@]}" --session SESSION_ID --pid '<0.1234.0>' --human
mix insider.live timeline "${N[@]}" --session SESSION_ID --request-id REQUEST_ID
```

The result (`insider.live-timeline/v1`) has `subject`, `items`, `pids`, `trace_ids` to follow with `trace/3`, and,
for a request, `seeds` and `window`. `items` are as for `trace/3`, with `joined_by` `pid`, `request_id`,
`pid_window`, or `trace_id`. The same `unjoined`, `scan`, `gaps`, and bounds apply. Give exactly one of `"pid"` and
`"request_id"`. The other options are those of `trace/3`. In the strict profile Logger events carry no process or
trace context, so they join only through a request's Telemetry events.

## Request waits and bursts

A request can wait seconds before the application handles it while every handler looks fast. In dev,
`Phoenix.CodeReloader` and every plug before `Plug.Telemetry` run before Phoenix's endpoint telemetry starts. A
burst of requests from another client queues there, and pages hang with no slow handler to blame.

Each request stop event of the web server (`bandit.request.stop`, or `cowboy.request.stop`) and Phoenix's
`phoenix.endpoint.stop` carry `attributes.request`. The emitting process builds it from fixed fields. The server
has `role` `server` with `total_us`, `response_us` (to the response's start), `headers_us` (Bandit), `method`,
`status`, and `traced` (a `traceparent` header was sent). In the rich profile it adds `path`, `user_agent`, and
`remote_ip`. The endpoint has `role` `handler` with `handler_us`, `method`, and `status`. The work is bounded
whatever the request. Insider compares at most 64 headers by exact name. Each text field reads at most a 640-byte
prefix, credential-masks it, and only then cuts it to 128 bytes (`…[truncated]`). It drops a token that straddles
the scan. A value that is not UTF-8 is `nil`. A field that cannot be read never drops the request's timing. Timings
come from the `duration` measurement. Insider collects them when the measurement is selected, and rich collects
every measurement. Otherwise the request carries `"timing_withheld" => true`. The strict boundary withholds timings
(and a derived `wait_us`) with drop records unless the host allowlist names `duration`. Strict always withholds
path, user agent, and address. The digest counts `timing_withheld`.

Reads pair each server request with the endpoint stop that its process emitted inside it. Under Cowboy, which runs
Phoenix in a separate request process, they pair by the connection and stream (`"stream"`). The wait before the
endpoint is the time to the response's start (else the total) less the endpoint's time. A request served before
`Plug.Telemetry` (a static file, Tidewave, a health check) has no wait.

- **digest:** `requests` gives `requests`, `with_handler`, `waited_100ms`, `wait_p95_us`, the five `slowest_waits`
  (when each arrived, method, path, status, user agent, wait, total), and `bursts`. The digest pairs the window's
  first 8,192 request events.
- **trace and timeline:** a paired server event gets `wait_us` and `handler_us` in `attributes.request`. Its text
  line ends `waited 3.1 s before the endpoint`. The text adds a `Wait:` line for each of the three longest waits of
  100 ms or more.

A burst is a run of seconds at five times the usual rate, in which at least one second has 30 arrivals or more. The
usual rate is the median of the window's seconds with any arrival. Each burst has `at`, `seconds`, `requests`,
`peak_per_s`, `baseline_per_s`, and `max_wait_us`. It names its top three `sources` (user agent, else address, else
traced or untraced), each with how many were traced. It counts the other requests that overlapped it
(`others_overlapping`, `others_max_wait_us`).

Bursts and waits from 1 s lead the digest's `anomalies`:

```text
Request burst at 13:05:40: 120 requests in 1 s (usually 2/s), 120 from user agent sync-client/1.4; waits up to 7 s, 1 other request waited up to 5.9 s.
```

Insider's own reads and inspections reach the node over Erlang distribution, not its HTTP request path. So they
keep answering while requests are stalled (the welcome's "app hangs" recipe).

## GraphQL outcome

A GraphQL error is usually inside an HTTP 200 response. So neither the request's status nor its span's status shows
it. Two sources carry `attributes.graphql`, the value-free outcome. The first is an Absinthe operation's Telemetry
event (`absinthe.execute.operation.stop`, a quiet default when Absinthe is loaded). The second is its OpenTelemetry
span, from the `opentelemetry_absinthe` attributes `graphql.operation.name`, `graphql.operation.type`, and, when
the instrumentation records them, `graphql.response.errors` and `graphql.response.result`.

### Outcome fields

- `operation_name` and `operation_type` (`query`, `mutation`, or `subscription`).
- `result`: `ok`, `user_errors`, `partial` (errors with data), `errors` (errors without data), or `nil` (unknown).
  `user_errors` means no GraphQL error, but a top-level field's payload reports its own validation errors (an
  `errors` field of `field`s and `type`s).
- `complete`: `false` when a bound left something unexamined (more than 64 top-level fields, or more than 4,096
  errors). The result is then never `ok`.
- `error_count`, `error_codes` (each error's `extensions.code` or `code`), and `error_paths`
  (`order.items[].product`: schema field names, list indices as `[]`).
- `typenames` (each top-level field's `__typename`), `user_error_count`, `user_error_fields`, and
  `user_error_types`.
- `withheld`: names left out because they are not shaped like identifiers or are past the bound.
- `client` (Telemetry events, rich capture only): the `user_agent` (credential-masked, at most 256 bytes) and
  `remote_ip` of the request that the operation ran in. Absinthe's metadata carries no conn. So while a rich
  session records the operation stop, a handler on Phoenix's `[:phoenix, :endpoint, :start]` remembers the client
  (bounded and masked) in the request process. The request's `stop` or `exception` forgets it. An operation outside
  an endpoint request has no `client`. A client remembered by an earlier collection (one stopped mid-request) never
  counts for a later one. So the client is on the operation's event, not only on the request span.

GraphQL errors make the event `error`, and payload validation errors make it `warning`. The digest's
`error_signatures` include both, grouped by operation, result, codes, paths, and fields:

```text
absinthe.execute.operation.stop mutation placeOrder result=user_errors fields=[price]
```

Under the strict profile only `operation_type`, `result`, the counts, and `withheld` pass. Insider withholds each
name list, and `client`, with a drop record. A compact line shows `graphql=mutation:placeOrder result=user_errors
user_errors=1 fields=[price]`. A span's compact line shows its `name`, `span_kind`, `duration_us`, `status`,
outcome, and `trace` id.

### How Insider reads a payload

Insider never takes a response key for structure, because an alias can give any field any key (`__typename:
password`). It reads a payload only through the operation's own selections. It merges them by response key as
GraphQL merges them, and follows inline fragments and named fragment spreads.

- Insider finds `__typename`, `errors`, `field`, and `type` by their schema names, and reads them by the response
  keys that the document gave them.
- Insider never reads a key that fields of different names share on mutually exclusive fragment types.
- A `__typename` must be a GraphQL name. When the selection set has fragments, it must be one of their type
  conditions.
- Insider resolves an error path through the same selections to schema field names. It withholds a path that does
  not resolve. A span has no selections. So Insider reads its recorded result only for top-level errors and whether
  data is present. A span's result is `errors` or `partial` with top-level errors, and `nil` without. A payload's
  validation errors show only on the operation's Telemetry event, which joins the same trace. The decision is
  `decisions/2026-10-24_live_graphql_outcome_reads_payloads_only_through_the_operations_selections.md`.

Insider never reads error messages or any other value. Each list holds at most 6 distinct names of at most 48
bytes. Insider checks each path segment before it adds it. Names come from at most 64 top-level fields and 64
entries of each error list. Counts are exact up to 4,096 in total. The document walk runs in the emitting process
and is bounded: 2,048 selection nodes in all, fragments nested 8 deep in one selection set, a spread expanded once
per selection set, and the first 256 named fragments. A bound hit, or a spread of an unknown fragment, makes
`complete` false.

## Frontend traces (OTLP HTTP receiver)

`otlp-receive` runs a local OTLP/HTTP trace receiver in the observer. Spans from a process that is not a BEAM node,
such as a Next.js dev server, land in the same session as the node's own spans, and one `trace` shows both.

```sh
mix insider.live otlp-receive "${N[@]}" --session SESSION_ID
mix insider.live otlp-receive "${N[@]}" --session SESSION_ID --port 4319 --for 10m
```

It listens on `127.0.0.1:4318`. `--port` changes the port, and `0` picks a free port. `--bind ::1` uses the IPv6
loopback. Any non-loopback address is `non_loopback_bind`. A port in use is `port_unavailable`. It accepts `POST
/v1/traces` with a `Content-Length` body of `application/x-protobuf` or `application/json`, optionally gzip. The
body is at most 4 MiB before and after decompression. It takes one connection at a time. It answers with an OTLP
`ExportTraceServiceResponse`, with `partial_success` when spans were rejected. The observer only decodes. It sends
each span to the target's `ingest_spans/2`, with `service` from the resource's `service.name`. The session applies
the span contract, its disclosure profile, and credential masking there, exactly as for the node's own spans.

On the frontend side, point the dev server's OTLP exporter at the receiver, for example
`INSIDER_OTLP_ENDPOINT=http://127.0.0.1:4318/v1/traces` (development only). If the frontend's dev log prints each
request's trace id, pass that id to `trace`. Each `export` line of `otlp-receive` also lists its trace ids. The
boundary is recorded in
`decisions/2026-10-22_otlp_ingress_is_a_loopback_lab_receiver_that_only_the_target_masks.md`.

### Receiver output

It prints NDJSON:

- `listening`: the envelope, the session's status, `endpoint`, and `port`.
- `export`, one per request: `accepted`, `rejected`, `filtered`, `shed`, `duplicate`, and `traces`. `duplicate`
  counts spans that the session already recorded, as when an exporter resends an export. `traces` lists each
  validated trace id with its span count, never span content or resource values, which only the target masks.
- `refused`: the HTTP `status` and `reason` for a request that it could not read, or one of the two `503` cases
  below.
- `stopped`: the totals, when SIGTERM, `--for`, or the end of the session stops it.

`target_timeout` means that ingesting timed out twice. The receiver retries a timed-out chunk once, because the
outcome is unknown. The retry skips spans already recorded within the 16,384-id bound and the current collector.
The exporter may retry the export, and the receiver keeps receiving. `target_busy` means that the owner's admission
was full. The chunk was refused before it ran. The receiver does not retry it at once. The exporter retries the
export, and the receiver keeps receiving.

### Session binding and lease renewal

The receiver needs a session started with `--component otel`. Otherwise it returns `component_unavailable` before
it listens. It is bound to its session. Ingest runs in the live owner, ordered with `start` and `stop`. So after
that session ends, the owner refuses the next export (`partial_success`, the spans rejected) and the receiver
stops. A session started later never receives its spans. The receiver accepts the next connection only after it
wrote the previous report. So a stalled output holds clients back instead of queueing reports. The receiver renews
the session lease at a third of the lease. When a renewal fails because the owner is busy or timed out, the
receiver retries it once after a jittered quarter to half of the renewal interval. The delay is capped to leave 250
ms before the lease's estimated end, or it is skipped when less remains. Timers can fire late, so this is not a
delivery guarantee. After that, the next scheduled renewal takes over. A saturated target sees at most two renewals
per interval. The lease survives when the owner answers one of them before it expires
(`decisions/2026-10-22_otlp_receiver_renewal_retry_is_capped_by_the_lease.md`).

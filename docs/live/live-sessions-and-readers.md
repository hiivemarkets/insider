# Insider Live: sessions, readers and marks

[Index](../README.md) · [Glossary](../glossary.md) · [Cheat sheet](../cheat-sheet.md)

How a session's events are numbered and read, what a gap means, how the Recorder shares its space, how subscriptions and several readers work on one session, how pairing marks bound a window, how a chart shows the session to the programmer, and the units of event time.

## Contents

- [Cursors and gaps](#cursors-and-gaps)
  - [Read from a cursor](#read-from-a-cursor)
  - [Read bounds](#read-bounds)
  - [Read pages and memory](#read-pages-and-memory)
  - [Event shape and disclosure](#event-shape-and-disclosure)
  - [Disclosure manifest](#disclosure-manifest)
- [Gaps](#gaps)
- [Recorder shares](#recorder-shares)
- [Subscriptions](#subscriptions)
- [Several agents on one session](#several-agents-on-one-session)
  - [Named readers](#named-readers)
  - [Per-reader views](#per-reader-views)
  - [Stored views](#stored-views)
  - [Signature, service, route and trace views](#signature-service-route-and-trace-views)
  - [Protected stop](#protected-stop)
  - [Drain window](#drain-window)
- [Live amendment](#live-amendment)
- [Handoff](#handoff)
- [Pairing marks](#pairing-marks)
- [Pairing chart](#pairing-chart)
  - [Live chart](#live-chart)
- [Event time and units](#event-time-and-units)

## Cursors and gaps

### Read from a cursor

```sh
mix insider.live events "${N[@]}" --session SESSION_ID --cursor 0 --limit 100
mix insider.live events "${N[@]}" --session SESSION_ID --cursor 0 --view-source logger --view-min-severity error
mix insider.live events "${N[@]}" --session SESSION_ID --cursor 0 --format compact
mix insider.live events "${N[@]}" --session SESSION_ID --cursor latest --reader agent-b
mix insider.live events "${N[@]}" --session SESSION_ID --since-mark --format compact
```

The Recorder gives each event it admits a receipt. Receipts are consecutive and start at 1. Cursor `0` is the start of the session.

`events_since(id, cursor, options)` returns the events whose receipt is greater than `cursor`, in receipt order. It also returns `next_cursor`, which you pass to the next call. It does not need a freeze trigger.

Each read first drains the visible Logger and Telemetry inboxes. So the read shows the events that were emitted before the call. This guarantee does not cover concurrent emitters.

`next_receipt` is the newest receipt when the read began. A reader whose `next_cursor` equals it has caught up.

Cursor `"latest"` is that newest receipt. The batch is empty, and its `next_cursor` starts a tail. An agent that joins a running session uses it to skip the history.

A cursor is `invalid_cursor` when it is negative, when it is neither an integer nor `"latest"`, or when it is greater than the newest receipt. The error names `oldest_receipt` and `next_receipt`.

### Read bounds

Three options bound a read. Only the events that the read returns count against the first two.

| Option | Bound |
|---|---|
| `"limit"` | 1 to 500, default 50: events returned. |
| `"max_bytes"` | 1,024 to 1,048,576, default 65,536: canonical JSON bytes of the events returned. The first event is always returned. |
| `"scan_limit"` | 1 to 1,000, default 1,000: retained events the read examines. |

- `"max_bytes"` counts each event as `Insider.Live.JSON` would encode it.
- `"scan_limit"` counts every examined event, whether the view shows or hides it. This includes events that the redaction pass withholds.
- Without a view, a read examines `"limit"` events. It reads on past withheld events within the `"scan_limit"` budget. So a withheld event never ends a read early.

`"upto"` (an integer, default none) is the newest receipt the read may return. It must be at least the read's starting cursor (after `"latest"` resolves) and at most the newest receipt. Otherwise the read fails with `invalid_options` and field `"upto"`. So a read never moves its cursor back.

`"renew"` (a boolean, default `true`) set to `false` reads without renewing the lease. `chart --serve` reads this way, so a page left open never keeps a session alive.

The read stops at `upto`, and `next_cursor` never passes it. The read counts its receipt-range losses from the receipts up to `upto`. Each receipt up to `upto` that the read neither returned nor withheld was evicted. So the read never counts a loss after `upto`. `next_receipt` still names the newest receipt. A digest reads its window this way.

When `"limit"` or `"max_bytes"` stops a read, `next_cursor` is the receipt just before the first event that the read would show next. So the hidden events up to there are consumed and counted, not scanned again.

`truncated` says that more events wait at `next_cursor`. `truncated_by` names what ended the read:

- `"limit"` or `"max_bytes"`.
- `"scan_limit"`: the read examined its budget before it reached `"limit"`. A sparse view is never starved silently. The next read continues from `next_cursor`.
- `"deadline"`: redaction ran out of time.
- `nil`: the read reached its snapshot boundary. That is `upto` when given, else the newest receipt when the read began (`next_receipt`).

### Read pages and memory

The owner serves a read in pages of at most 100 entries and 128 KiB (`bounds.read_page_entries` and `bounds.read_page_bytes`).

- A page of the Recorder counts the stored bytes of its entries.
- A page of an amended or stopped session's archive counts the external term size of its entries. The archive's own bound uses the same measure.
- A page that joins the end of the archive to the Recorder gives the Recorder only what the archive part left of both budgets.

The first entry of a page is always taken. So a page holds at most 128 KiB, or one larger entry, plus at most the first Recorder entry after an archive part.

The owner keeps only the events that a read returns and counts the rest. So each process on the read path holds about one page besides its result. The owner, Manager, and Session collect their garbage after they reply.

`bench/live_read_memory.exs` runs three sessions in one owner, one after another. So later reads run while the earlier stopped sessions stay readable. The bench measures what a read adds over each process's collected heap:

- **1 MiB read of 139 large events (about 7 KiB each) from a full 4 MiB Recorder, empty owner:** the owner peaks at about 2.9 MB.
- **500-event read (about 2 KiB each) from about 2.1 MB of retained events, owner that holds one stopped session:** the owner peaks at about 2.3 MB.
- **Read through an amended session's archive, owner that holds two stopped sessions:** one run measured an owner peak of about 2.9 MB for the full read and 3.2 MB for a hidden scan. Another run measured 4.5 MB and 3.2 MB.

These peaks depend on the heap, so they vary between runs. The bench holds them to its bounds: 6 MiB for a full read and 4 MiB for a hidden scan. A process's collections size its heap for the data it holds. So peaks grow with retained state. The same hidden scan peaks at 0.7 MB in an empty owner.

The session Manager and Session peak at 0.3 to 0.7 MB, about one page. No process's state grows by more than about 1 KB across a read.

The owner keeps the archive of each readable stopped session. For a full 4 MiB Recorder, that is about 2.5 MB of heap, plus shared binaries outside the heap. The bench holds the owner to 4 MiB of heap per readable stopped session.

### Event shape and disclosure

Each event is `%{"receipt", "received_at_us", "priority", "event", "redactions"}`. `"event"` is the `insider.event/v1` wire map.

Each event first passes `Insider.Redaction` under the fixed `insider-live` policy. That policy bounds and validates every value and fails closed. It has no rules, because the transport caller is not trusted to make disclosure decisions. So every event then crosses the session's [disclosure profile](../disclosure-and-safety.md#disclosure-profiles).

The rich profile returns the event as recorded. The strict profile is a fixed live boundary (`insider-live-boundary/v1`). It keeps only opaque, shape-checked values:

- Causality: Insider keeps `trace_id` only as 32 lowercase hex digits, and `span_id` only as 16, not all zero, as in W3C trace context. It always withholds `logical_operation_id`, `parent_event_id`, and `process_generation`, because they are free-form.
- Logger supervisor identities: a `binary:` child or supervisor id becomes `binary-sha256:` and the SHA-256 of the value. Insider keeps atom, integer, pid, and tuple digests.
- Telemetry measurements: Insider keeps only names in the host allowlist, and only integer or decimal-float values. Telemetry metadata is always empty, and payloads are always `nil`.

Credential masking then applies in both profiles.

### Disclosure manifest

`"redactions"` is the disclosure manifest. It holds these records:

- The records of the redaction pass.
- `drop` records (`policy_id` `insider-live-telemetry`) for what the session did not select. Insider lifts them from the collector's `"omitted"` evidence.
- A `drop` record (`policy_id` `insider-live-boundary/v1`) for every value that the strict boundary withheld. This includes a payload that was recorded under rich and read after the host narrowed to strict, at `["key:payload"]`.
- A `mask` record for every masked credential.

A path addresses a list element as `index:N`, as in `["key:attributes", "key:summary", "key:exemplars", "index:0", "key:duration_us"]`.

The collector does not collect a Telemetry measurement that the session did not select with `"telemetry_measurements"`:

- When `NAME` is in the host measurement allowlist, its record names it (path `["key:attributes", "key:measurements", "key:NAME"]`). So you can select it on the next start.
- One record at `["key:attributes", "key:measurements"]` counts the rest, without their names.

In the strict profile, the collector does not collect Telemetry metadata keys. They leave one record at `["key:attributes", "key:metadata"]` with their count.

Insider removes the `"omitted"` attribute itself from the event. It withholds malformed evidence whole, with a boundary record at `["key:attributes", "key:omitted"]`.

The strict profile does not collect Logger message text, report fields, or metadata at all. They leave no record.

## Gaps

`"gaps"` is a list of `%{"reason", "count", "scope"}`. An empty list means no known loss. Losses are never silent.

**Scope `receipt_range`.** The count is exact for `cursor < receipt <= next_cursor`:

- `evicted`: receipts that the Recorder bound evicted. `status/1` `recorder.sources` names whose.
- `redaction_withheld`: events that the redaction pass refused. They still advance the cursor.

When a limit ends a read early, the read recounts both for the shorter range.

**Scope `since_cursor_issued`.** A read from cursor `0`, or from a cursor this session never issued, uses scope `since_session_start` instead. These are losses that never received a receipt. Each is a delta of a cumulative counter against the counter observed when the cursor was first issued. So a read from the same cursor repeats them, as it repeats the events. Cursor `0` never gets a baseline, so every read from it reports the losses since session start.

Recorder admission losses:

- `recorder_classification_failed`
- `recorder_contended`: a write gave up, because the Recorder's admission lock did not change hands within its stall bound.
- `recorder_event_id_conflict`, `recorder_eviction_limit`, `recorder_frozen`, `recorder_internal_error`, `recorder_invalid_event`, `recorder_oversized`, `recorder_priority_protected`, `recorder_rate_key_capacity`, `recorder_rate_limited`, and `recorder_unavailable`.

Ingress losses:

- `logger_shed`, `logger_invalid`, `telemetry_shed`, `telemetry_invalid`, `telemetry_handler_failures`, and `poller_events_invalid`.
- `telemetry_omissions_unrecorded`: events recorded without their omission evidence, because the evidence did not fit. The events themselves were kept.
- `calls_shed`: trace messages that arrived after a call-trace limit, and the results of those calls. `calls_invalid`.
- `calls_undrained`: trace messages that the call trace's buffer process still held, or had taken and not forwarded, when its last drain timed out at the trace's removal.
- `calls_undrained_unknown`: stops whose `calls_undrained` count is only a lower bound, because Insider could not prove the buffer's state.
- With the otel component, `otel_shed`: spans counted but not built, because more than 1,024 were waiting.
- `otel_invalid`: span records or ingested span maps outside the contract.
- `otel_abandoned`: spans still waiting when the session sealed or stopped and its drain ran out of time. They are counted and never built.
- `otel_paused` and `otel_paused_ongoing`, each with `"count" => nil`: the otel capture was paused during the read's interval, or is still paused when the read is built. So Insider did not observe the spans that ended meanwhile, and their number is unknown. See [OpenTelemetry spans and traces](live-otel-traces.md#opentelemetry-spans-and-traces).
- `telemetry_summary_lost`: a summarized event whose sample Insider could not store, because its summary table was gone. It is never counted as `summarized`.

Summary evidence losses (see [Filters, summaries, and views](live-digest-filters-and-trends.md#filters-summaries-and-views)):

- `telemetry_exemplar_lost`: exemplar candidates lost before their summary was recorded, or that arrived after it.
- `logger_exemplar_lost`: the first message of a Logger burst that was not recorded.
- `logger_summary_overflow`: burst distinctions folded into an overflow row past the 64-key cap.

**Scope `unknown`.** These gaps have `"count" => nil`:

- `logger_accounting_unavailable`, `telemetry_accounting_unavailable`, `otel_accounting_unavailable`, `calls_accounting_unavailable`, and `poller_accounting_unavailable`: Insider could not read a component's counters.
- In a terminal subscriber batch, `final_read_unavailable`: the last read failed.
- In a terminal subscriber batch, `final_read_withheld`: a revoked session disclosed nothing more.
- `segment_end_unread`: a stop or amendment could not copy the last events of a segment. Either its ingress could not be sealed, or the last copy failed. Every read that reaches that receipt reports it.

Insider keeps at most eight ranges of such boundaries. It merges older ones into one range that covers them and keeps their count. A read reports at most one such gap, with `"boundaries"`: the number of boundaries in the ranges it overlaps.

## Recorder shares

The session Recorder reserves each source a share of its events and bytes:

| Source | Share |
|---|---|
| `logger` | 25% |
| `telemetry` | 15% |
| `poller` | 25% |
| `otel` | 10% |
| `inspect` | 5% |
| `system_monitor` | 5% |
| every other source, together | 5% |

A share reserves room without holding it. So one source alone may fill the Recorder.

When the Recorder is full, a source over its share evicts its own oldest events. A source within its share takes the oldest events of sources over theirs. So a rich Logger flood at info evicts its own history. It never evicts the Poller samples or Telemetry events within their shares.

Normal events never evict protected events. Protected events are crashes, supervisor child terminations, invariant failures, and code, config, and deploy changes.

`status/1` reports `recorder.sources`. Per source, it gives `share_percent`, `reserved_events`, `reserved_bytes`, `retained_events`, `retained_bytes`, and `evicted`. A source's `evicted` is conservative. After a collector is killed mid-write, it can exceed the events that were really evicted. It never falls short. The `evicted` gap of a batch stays exact for its receipt range. The welcome document describes the shares under `recorder`.

## Subscriptions

```sh
mix insider.live watch "${N[@]}" --session SESSION_ID --for 30s --view-kind 'phoenix.*'
mix insider.live watch "${N[@]}" --session SESSION_ID --from-cursor latest --for 30s --view-min-severity warning
mix insider.live watch "${N[@]}" --session SESSION_ID --from-cursor latest --for 60s --format compact
```

The observer's `watch` prints pushed batches as NDJSON. It stops on SIGTERM, `--for`, `--max-events`, or the end of the session.

`subscribe(id, pid, options)` pushes `{:insider_live_events, session_id, batch}`. The batch has the `events_since/3` batch shape and passes through the subscriber's optional `"view"`, else its reader's stored view (see [Stored views](#stored-views)). `subscribe/3` also takes `"reader"`, which marks that reader `subscribed` in `status/1`, and `"view_keep"`, which keeps the subscription's view as the reader's stored view.

The subscription starts at `"cursor"`:

- `0` by default.
- An integer no newer than the newest receipt. A newer one is `invalid_cursor`.
- `"latest"`: the newest receipt when the subscription is made.

`"max_events"` (1 to 1,000,000, default unlimited) caps the total events pushed to that subscriber. No batch carries more than what remains. When the cap is spent, only the terminal batch follows, with no events.

The owner polls every 500 ms. Per batch, it examines at most 1,000 retained events and sends at most 100 events and 262,144 bytes (counted as for `events_since/3`). It sends a batch only when there are events, gaps, or filtered counts to report (see `filtered` in [Filters, summaries, and views](live-digest-filters-and-trends.md#filters-summaries-and-views)).

Every batch starts at the `next_cursor` of the batch before it. The first batch starts at the subscription's cursor. The owner does not send a poll whose view hid every event. The next batch that it sends covers those receipts and counts what the view hid.

A session has at most four subscribers. A new subscription by the same subscriber replaces the view and `"max_events"`. It moves the cursor only when `"cursor"` is given.

The owner monitors each subscriber and drops it on `DOWN`. This includes `:noconnection` for a remote pid. Sends use `:noconnect` and `:nosuspend`. So a busy distribution buffer cannot block the owner. The owner skips a local subscriber with more than 32 queued messages for that tick. A skipped or refused batch leaves its cursor in place. So nothing is lost before eviction, and a later batch reports any eviction.

When the session stops, expires, is revoked, or terminates, each subscriber receives one last batch. Its `"state"` is the ended state, and it carries the `"receipt"`. The owner reads it from the copy that a stop makes (see [Drain window](#drain-window)). A revoked session's last batch has no events, the gap `final_read_withheld`, and `"filtered" => nil`.

## Several agents on one session

A node has one session, and agents often share it. One agent starts it, others join, and one of them stops it. A read without `--session` uses the active session (see [Default session](live-api-and-transports.md#default-session)).

Recording options decide what the session records for every reader. They are components, Telemetry events, measurements, and filters. A view decides only what the read or subscription that passes it shows. Every configuration (`start/1`, `status/1`, `amend/2`) says so under `"scope"`.

### Named readers

Every read and session command takes `"reader"` (observer `--reader NAME`). The reads are `events_since/3`, `subscribe/3`, `digest/2`, `trends/2`, `trace/3`, `timeline/2`, `changes`, `mutations`, and `baseline`. The session commands are `mark`, `marks`, `status`, `handoff`, `renew`, `stop`, and `amend`.

A name is 1 to 32 letters, digits, `_`, `.`, or `-`. It starts with a letter or digit.

`status/1` lists `"readers"`. Each reader has:

- `"cursor"`: the `next_cursor` of its last read or delivered batch. A trace or timeline reads the session newest first, so it leaves the cursor as it was.
- `"behind"`: receipts up to `next_receipt`.
- `"last_seen_ms_ago"` and `"last_seen_at"`.
- `"subscribed"`.
- `"active"`: subscribed, or seen within `reader_active_ms` (30,000).
- `"view"`: its stored view, or `nil`.

Insider keeps at most 16 readers, the most recently seen. It does not list unnamed reads.

### Per-reader views

A view narrows only the read or subscription that gives it. It never changes what the session records or what another reader sees.

- A read that gives a `"view"` reads through it. The view applies to that read only, even with a reader name.
- A read that names a reader and gives a non-empty `"view"` with `"view_keep" => true` (observer `--view-keep`) also stores it as that reader's stored view.
- A later read by the same reader without a view applies the stored view. This includes `events_since/3`, `subscribe/3`, `digest/2`, `trends/2`, `trace/3`, `timeline/2`, `changes`, `mutations`, and `baseline`. A read that gives its own view reads through that view instead and leaves the stored view as it was.
- `"view" => %{}` (observer `--view-clear`) clears the stored view. `--view-clear` with other view flags replaces the stored view with them, as `--view-keep` does.

`"view_keep"` needs a reader and a non-empty view. Otherwise the read is refused with `invalid_options`, field `view_keep`.

A named reader's batch, pushed batches included, carries `"reader"` and the `"view"` it was read through. A view lookup that fails also fails the read. It leaves the stored view as it was.

Digest, trends, trace, and timeline results carry the reader and view too. They also carry what the view hid: `filtered.view`, or `"filtered_view"` for trends, trace, and timeline. Their `--human` text ends with one line that says how many events the view hid.

### Stored views

```sh
mix insider.live events "${N[@]}" --session SESSION_ID --cursor 0 --reader agent-a --view-exclude-signature MyApp.Worker --view-keep
mix insider.live digest "${N[@]}" --session SESSION_ID --reader agent-a --view-clear
```

A stored view narrows later reads that do not name it, so Insider always says when it applies, and when a read stores or clears one:

- A result that a stored view narrowed carries `"stored_view"` at the top level: `"reader"`, the `"view"`, `"hidden"` (the events it hid from this read, or `nil` where the read does not count them), `"source"`, and `"note"`. For a read, `"source"` is `"reader"` and the note reads `reader claude's stored view (kinds …, kept with --view-keep) hid N events from this read; --view-clear clears it`. Events and pushed batches, digest, trends, trace, timeline, changes, mutations, baseline, and a subscription's reply all carry it.
- A subscription that gives no view keeps the stored view it inherited when it subscribed; a later `--view-keep` or `--view-clear` does not reach it. Its reply and pushed batches say `"source": "subscription_snapshot"`, and their note says the view is the one stored when it subscribed and that another view needs a new subscription.
- `--human` text starts with that note as `Note: …`, and compact output starts with it as `# note: …`. A compact `watch` prints it once, before its `# subscribed` line.
- A read that stored or cleared the reader's view carries `"view_note"`: `this view is now reader claude's stored view for its later reads … until --view-clear; it hid N events here`, or `reader claude's stored view is cleared`. Its `--human` text and compact output start with it too. A subscription's reply carries it without the count, since it has read nothing yet, and a compact `watch` prints it before its `# subscribed` line. `baseline --show` and `--clear` read nothing, so they refuse `"view_keep"`.

### Signature, service, route and trace views

```sh
mix insider.live events "${N[@]}" --session SESSION_ID --cursor 0 --view-exclude-signature MyApp.Worker
mix insider.live events "${N[@]}" --session SESSION_ID --cursor 0 --view-trace TRACE_ID
```

Besides `sources`, `kinds`, `exclude_kinds`, and `min_severity`, a view takes these keys:

| Key | Observer flag | Hides or keeps |
|---|---|---|
| `exclude_signatures` (≤ 16) | `--view-exclude-signature` | Hides error signatures as the digest names them (list below). |
| `services` (≤ 8) | `--view-service` | Keeps the traces in which a span of that service took part. |
| `routes` (≤ 8) | `--view-route` | Keeps the traces in which a span with that route served. |
| `traces` (≤ 32) | `--view-trace` | Keeps those traces (32 lowercase hex digits). |

- **`exclude_signatures`:** a hex prefix of 8 to 64 digits matches a digest signature's `id` (`error_signatures[].id`) or a supervisor report's `reason_fingerprint`. A module name (such as `MyApp.Worker`) matches a signature or supervisor offender that names it. A fingerprint hides the supervisor reports of a crash loop. A module name hides every report that the module causes (supervisor, `gen_server`, and `proc_lib`). So a known crash loop, such as a misconfigured JWKS strategy, leaves the reader's digests.
- **`routes`:** a route matches `http.route` or `next.route`, exactly or as a path prefix. Insider knows routes only from spans ingested in the rich profile.

`services`, `routes`, and `traces` together scope the view. The view keeps an event when one of these is true:

- The event names a listed service or route itself.
- The event belongs, by its trace id, to a listed trace.
- The event belongs to a trace in which a recorded span named a listed service or route.

The otel collector indexes the services and routes of the newest 4,096 traces whose spans it recorded (`bounds.trace_index_max`). This covers spans from the node's SDK and from ingest alike. Rejected, filtered, shed, and duplicate spans add nothing. A stop or an amendment carries the index into the next segment and the drain window.

Credential masking applies to index labels. Insider refuses a view label that credential masking would change. Routes resolve only while the session's effective profile is rich. So a route learned under rich stops matching when the host narrows to strict.

Insider counts what the scope hides under `filtered.view.scope`. A view reads only events as they are disclosed. So it reveals nothing that its reader could not see, and its bounds keep the work of each read bounded. An event recorded before the span that names its trace was ingested is outside a scope while that span is missing.

### Protected stop

```sh
mix insider.live stop "${N[@]}" --session SESSION_ID --reader agent-a
mix insider.live stop "${N[@]}" --session SESSION_ID --reader agent-a --force
```

`stop(id, %{"reader" => name})` refuses with `readers_active` while another named reader is active. The error names:

- those readers.
- `retry_after_ms`: when the last one goes idle. It is `nil` while one is subscribed.
- the count of `unnamed_subscribers`.
- `reader_active_ms` and `stopped_readable_ms`.

A reader's own reads never hold its stop. An unnamed stop counts every named reader as another reader. `"force" => true` stops anyway.

The stopper cannot tell unnamed readers and subscribers apart. So they never hold a stop. Name your reads.

### Drain window

A stop copies the session's retained events into the owner. Then it seals the session's ingress (`Insider.Collector.Session.seal_ingress/2`):

- The Poller stops.
- Insider removes the otel capture, then drains the spans that ended before the removal.
- Insider removes the Telemetry handler and Logger filter, then drains their inboxes. Telemetry then records its pending summary intervals.

The stop then copies what arrived meanwhile. Only then does it stop the collector session. So the stop loses no recorded event or summary.

The final counters of each sealed component stay its evidence. So reads report the losses that it counted up to the seal. When Insider cannot read a component's final status, every later read of the session reports `<component>_accounting_unavailable`. This includes reads after amendments and in the drain window.

The session then stays readable for `stopped_readable_ms` (120,000). The record's `"readable_until"` gives the end. In that window:

- `events_since/3` reads the session like a running one, with views, bounds, gaps, and `filtered`. The batch has the ended `"state"`, `"lease_remaining_ms" => 0`, and `"readable_remaining_ms"`.
- Named reads update the session's readers in `status/1`.
- `renew/1`, `subscribe/3`, and `amend/2` return `session_terminal`.

After the window, reads return `session_terminal` too. The two most recently stopped sessions stay readable. A new session can start meanwhile. Insider does not keep an expired or revoked session readable.

## Live amendment

```sh
mix insider.live amend "${N[@]}" --session SESSION_ID --telemetry-measurement duration --reader agent-a
mix insider.live amend "${N[@]}" --session SESSION_ID --logger-level debug
mix insider.live amend "${N[@]}" --session SESSION_ID --reset watch-process --reset poller-interval-ms
```

`amend(id, options)` takes every start option and `"reader"`. Each option given replaces the session's value. A list replaces the whole list. `nil` returns an option to its default. The other options keep their values.

A kept Poller option (`poller_interval_ms`, `top_processes`, `top_ets_tables`, `watch_processes`) returns to its default when the amended `"components"` leave the poller out. This includes `"components" => nil` (observer `--reset component`), because the default components never include the poller. A Poller option given in the same amendment is still `invalid_options`.

Kept `"telemetry_events"` and `"telemetry_measurements"` return to their defaults the same way when the amended `"components"` leave `"telemetry"` out. Given in the same amendment, they are still `invalid_options`.

The owner validates the merged options as `start/1` would, before any side effect. Then it copies the running segment into the session's archive, stops its collectors, and starts new ones under the same session id.

Receipts stay consecutive. The next receipt is a `live.session_amended` event (source `live`) that every view shows. Its attributes carry `number`, `applied`, `by`, `requested`, `changed` (each effective option that changed), `from`, `to`, and `uncollected_ms`. `uncollected_ms` is the time from the seal of the old segment until the new one started, when no collector ran. Insider does not record events emitted in that pause. The event reports the pause.

Every cursor, reader, subscriber, and loss and filter baseline stays valid, because Insider carries the cumulative counters of earlier segments forward. A read whose cursor is before the amendment reads the archive first. The archive keeps at most 4,096 events and 8 MiB. Older events read as `evicted`.

The reply is `insider.live-amendment/v1` with the new configuration and the `amendment`. `status/1` lists the last eight under `"amendments"`.

- If the copy cannot complete in time, nothing changes (`timeout`).
- If the new options cannot start, the previous ones start again. The reply is `amend_failed` with `"rolled_back" => true`.
- If the previous options cannot start either, the session ends as `terminated` (`amend_failed`). It is readable like a stopped session, and the error carries its `status`.

## Handoff

```sh
mix insider.live handoff "${N[@]}" --session SESSION_ID
```

`handoff_record(id)` (observer `handoff`) returns `insider.live-handoff/v1`. It changes nothing. It holds:

- the `node`, the `welcome_hash`, `session_id`, `state`, `next_receipt`, and `readable_until`.
- the recording `configuration` with its `scope`: components, events, measurements, filters, `poller`, disclosure profile, lease, and `max_events`.
- the named `readers` with their cursors.
- `resume`: the observer commands that continue each reader and that join from `latest`.

## Pairing marks

An agent often watches while a programmer acts in the app ("click Confirm now"). The agent does not guess a time or a cursor. It marks the moment first, asks the programmer to act, then reads what came after the mark:

```sh
mix insider.live mark "${N[@]}" --session SESSION_ID --label 'about to click Confirm' --reader agent-a
# ask the programmer to click, wait for "done"
mix insider.live digest "${N[@]}" --session SESSION_ID --since-mark --human
mix insider.live marks "${N[@]}" --session SESSION_ID --human
```

`mark(id, %{"label" => label, "reader" => name})` returns `insider.live-mark/v1`:

- the `mark`: `index`, `label`, `label_truncated`, `reader`, `at`, and `cursor` (the newest receipt when the mark was made).
- whether its `live.mark` event was `recorded`, with the `reason` when not.
- the number of `marks` the session keeps.
- `next`: the command that reads since the mark.

A mark renews the lease. A stopped session takes no new mark.

Insider refuses a label of more than 1,024 bytes (`bounds.mark_label_input_max_bytes`), or one that is not valid UTF-8, before any work (`invalid_options`). Otherwise:

1. The label becomes one line. Control characters become spaces.
2. Credential masking applies in every disclosure profile.
3. Insider cuts the label to 120 bytes (`bounds.mark_label_max_bytes`) at a character boundary.

The strict profile keeps marks and masks labels by the same rules. A lookup label (`"mark:LABEL"`) follows the same rules once, before the owner compares it with the at most 256 kept labels. A refused lookup label is `invalid_options` (`since`, or `cursor` on `events_since/3`). Insider never echoes it.

A session keeps its newest 256 marks (`bounds.marks_max`), through amendments and after a stop. It counts the marks it let go.

A read since a mark starts after the mark's `cursor`. So it holds the mark's own `live.mark` event (source `live`, never hidden by a view) and everything after it. A digest leaves out only these marks. It counts an application event of the same kind from another source. `"mark"` reads since the newest mark, and `"mark:LABEL"` since the newest mark with that label:

- `digest/2` and `trends/2` take it as `"since"`. The digest's `window` names the `mark` with its `age_ms`. Its text says `Window: since mark 'about to click Confirm' (14:03:12 UTC, 18 s ago), …`. A digest never counts marks. When no other event came since the mark, the digest says so. The action may not have happened yet, or the session does not record it.
- A [known-normal baseline](live-digest-filters-and-trends.md#known-normal-baseline) folds a mark's window like any digest window: what is new since the mark leads. `baseline --since-mark` (or `"since" => "mark"`) marks a mark's window normal.
- `events_since/3` takes it as the cursor, and the batch's `mark` names it.
- `timeline/2` takes it as `"since"` and reads only the receipts after it.

An unknown label, or a session without marks, is `mark_not_found`, with the `labels` of the newest marks. `marks(id, options)` lists the marks oldest first (`insider.live-marks/v1`, each with its `age_ms`, and `dropped`). `"human"` adds one line per mark.

The observer flags are `mark --label`, `--since-mark [LABEL]` (on `digest`, `trends`, `events` in place of `--cursor`, and `timeline`), and `marks --human`.

## Pairing chart

Insider talks to the agent. The chart is for the programmer the agent pairs with: one page that shows what happened over time, with the marks on it and the anomalies flagged, readable in a few seconds.

The idea comes from [Orion](https://github.com/LivewareProblems/Orion), Thomas Depierre's distributed dynamic profiler for the BEAM. Its live chart of a traced function's latency showed how much one picture tells a programmer. Insider uses none of Orion's code: the chart is drawn in the observer from Insider's own session data.

```sh
mix insider.live chart "${N[@]}" --session SESSION_ID --since-mark
mix insider.live chart "${N[@]}" --session SESSION_ID --since latest-30m --out /tmp/checkout.html
```

`chart` writes one self-contained HTML file and prints its `path` (`insider.live-chart/v1`, with the `series` it drew, those `not_recorded`, the `headline`, the `reader` it used, and `complete` with any `incomplete` notes). Without `--out` the file goes under the system temp directory with a random name. Either way it is a new file with mode 0600: a path that exists, a symlink included, is refused (`invalid_options`, problem `exists`), never followed or replaced. The page:

- has a one-line headline: the most notable change and when, and how long after the mark before it, such as "Request waits rose to 8.5 s at 14:03:12, 2 s after 'about to click Confirm' (mark 1, 14:03:10)".
- draws, on the observer's local wall clock, each series the session recorded in the window: requests per second, request latency p50 and p95 (from the requests' recorded durations), the wait before the endpoint (as the digest pairs it), errors by signature (the top three and the rest), the longest mailbox, total and binary memory, and evicted events. Each panel's title names its unit. A series the window has no data for is left out, and a line says which, and why when the strict profile withheld the timing.
- shows each mark as a labelled dashed line, shades the window since the mark the chart starts at, and puts each of the digest's anomalies as a numbered marker at the peak of the series it is about, with its line as a caption. Labels of close marks take separate rows; a repeated label carries its mark's number (`about to retry (#2)`), and the marks are listed under the chart with their times.
- says above the chart what it could not read, and why: more than 20,000 events in the window (it keeps the newest and greys the rest), a digest that stopped early, events evicted before it read them. Missing data never looks like quiet.
- ends with the digest's lead lines (its first line, the anomalies, and the window), so a pasted page reads on its own.

The window is `--since` (as for `digest`, default `latest-15m`) or `--since-mark [LABEL]`. The chart reads through the ordinary read APIs: one digest of the window, the window's events with `events_since/3` (at most 20,000), the marks, and the status. So it shows exactly what those reads disclose under the session's profile: the strict profile shows no value it would withhold elsewhere. It reads with its own reader (`--reader`, default a new `chart-` name), so no other reader's cursor or view moves. Like any read, the static chart renews the lease once.

The page has no script, no font, no image and no link. Every string is HTML-escaped, and a Content-Security-Policy meta tag allows no script and only the page's own style block.

### Live chart

```sh
mix insider.live chart "${N[@]}" --session SESSION_ID --serve --for 30m
```

`--serve` serves the same page on the observer machine, refreshing about every second, and prints NDJSON: a `serving` line with the `url` to give the programmer, then a `stopped` line with its `reason` (`duration`, `session_ended`, or `interrupted`). New events, marks and the last minute's anomalies appear as they happen. The server runs in the observer (the Lab or the escript), never in the app node, and uses only OTP's `:gen_tcp`:

- It listens on 127.0.0.1 only, on a free port unless `--port` names one.
- The page is at a random 256-bit token in the URL's path; any other path is 404.
- A `Host` header other than `127.0.0.1:PORT` or `localhost:PORT` is 421, against DNS rebinding.
- Only GET is served (405 otherwise). It sends no CORS header, and a Content-Security-Policy that allows no script and no framing.
- It is read-only and reads with one reader.

The live chart renews no lease, its first read included: it reads the window with `events_since/3` and `"renew" => false`, then follows the session with a subscription, `status` and `marks`. A programmer watching the page never keeps a session alive. The page shows the session's state and how long its lease has left. When the host narrows the session's profile, the chart drops what it holds and reads the window again under the new profile. The chart stops at `--for` (default 30 minutes, at most 24 hours). When the session ends, the page says so ("The session ended (expired). This chart stopped updating."), stays up a few seconds without refreshing (never past `--for`), and the chart stops.

## Event time and units

Every live event carries `wall_time`, UTC RFC 3339 with microseconds:

- Logger: the event's own Logger time.
- Telemetry: when the event was emitted, read in the emitting process. For a summary event, it is when the collector recorded it, at the end of its interval.
- Poller: when the sample was taken.

`monotonic_time` orders events within one source. It is not a clock. Logger and Telemetry events carry their source's sequence number. Poller samples carry the VM monotonic clock in microseconds. Order events across sources by receipt.

Telemetry time measurements (`decode_time`, `duration`, `idle_time`, `query_time`, `queue_time`, and `total_time`) are in the emitting node's native time unit, as Telemetry reports them. Insider repeats each one that an event discloses as an integer in microseconds, under `attributes.durations_us` (`%{"duration" => 5001459}` beside `"duration" => 5001459000`). Insider derives these after the disclosure boundary. So a withheld measurement has no microsecond twin.

Summary statistics end in `_us`. Digest periods and spans end in `_ms`. The full welcome reference has the same table under `time`.

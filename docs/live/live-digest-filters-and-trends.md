# Insider Live: digest, filters and trends

[Index](../README.md) · [Glossary](../glossary.md) · [Cheat sheet](../cheat-sheet.md)

The one-call digest and its baseline, summary trends, the filters, summaries and reader views that keep a session quiet, and how an event's severity is decided.

## Contents

- [Digest](#digest)
  - [Digest window](#digest-window)
  - [Window fields and budget](#window-fields-and-budget)
  - [Anomalies](#anomalies)
  - [Observer traffic](#observer-traffic)
  - [Counts, crash loops and error signatures](#counts-crash-loops-and-error-signatures)
  - [Latency](#latency)
  - [Trends, processes and VM](#trends-processes-and-vm)
  - [Filtered counts and gaps](#filtered-counts-and-gaps)
- [Digest hints and text](#digest-hints-and-text)
  - [Call candidates](#call-candidates)
  - [Hint kinds](#hint-kinds)
  - [Hint commands](#hint-commands)
  - [Digest text](#digest-text)
- [Known-normal baseline](#known-normal-baseline)
- [Summary trends](#summary-trends)
  - [Telemetry and Logger series](#telemetry-and-logger-series)
  - [Poller series](#poller-series)
  - [Duration claims](#duration-claims)
- [Filters, summaries, and views](#filters-summaries-and-views)
  - [Quiet defaults](#quiet-defaults)
  - [Record-time filters](#record-time-filters)
  - [Filter options](#filter-options)
  - [Views](#views)
  - [Filtered counts](#filtered-counts)
- [Telemetry and Logger summaries](#telemetry-and-logger-summaries)
  - [Telemetry summaries](#telemetry-summaries)
  - [Exemplars](#exemplars)
  - [Duration scope](#duration-scope)
  - [Logger bursts](#logger-bursts)
- [Event severity](#event-severity)

## Digest

```sh
mix insider.live digest "${N[@]}" --session SESSION_ID
mix insider.live digest "${N[@]}" --session SESSION_ID --since latest-500 --human
mix insider.live digest "${N[@]}" --session SESSION_ID --since-mark 'about to click Confirm' --human
```

`digest(id, options)` answers "what is wrong right now" in one call. So neither an agent nor its partner developer has to join events by hand.

The digest reads a window of the session with `events_since/3`, at 500 events and 1 MiB per read. It reads through the same disclosure boundary, so it never shows more than a read would. It renews the lease.

It returns `insider.live-digest/v1`. The sections below describe its fields.

### Digest window

| Option | Meaning |
|---|---|
| `"since"` | Where the window starts (values below). Default `"latest-60s"`. |
| `"human"` | `true` adds `"text"`, a few plain-text lines to paste for the developer. Default `false`. |

`"since"` takes these values:

- `"mark"` or `"mark:LABEL"`: after the newest pairing mark, or the newest with that label. See [Pairing marks](live-sessions-and-readers.md#pairing-marks).
- `"latest-DURATION"`: a whole number of `ms`, `s`, `m`, or `h`, 1 s to 24 h. The window starts at the first event that the Recorder admitted that recently. So the old history of a long session neither hides nor delays fresh activity.
- An integer cursor: the window starts after that receipt. `0` is the session start.
- `"latest-N"`: the newest N receipts, N 1 to 4,096.

`trends` takes the same values, with default `0`.

The window ends at `upto`, the newest receipt when the digest starts. For `"latest-N"` and `"latest-DURATION"`, that is the newest receipt that the lookup saw. Otherwise it is the `next_receipt` of the first read. Every later read passes `"upto"`. So the digest leaves events that arrive during its reads for the next digest. If a read still passed `upto`, the digest ends the window with `stopped_by` `read_past_window` and does not fold the read in.

Insider measures a time window on the Recorder's admission clock. That clock is monotonic. Insider takes it with the receipt, and the archive keeps it. It follows receipt order. An event's own `wall_time` does not: a Logger call can pass its own time, and the Poller stamps a sample when it takes it. So an event recorded in the window stays in it whatever its `wall_time`. An event recorded earlier stays out.

Insider finds the start by a binary search of probes. A probe reads the receipt and admission time of the first disclosed event after a cursor. It reads past withheld receipts. The search runs within the same budget. It does not renew the lease or keep a cursor baseline.

A probe that meets no disclosed event within 1,000 entries or its time is undecided. Insider takes it as recent. The window then may start earlier than needed (`start_exact` `false`). It never drops a recent event. A search that the budget cannot finish is a `timeout`.

### Window fields and budget

`window` has these fields:

- `since`: as asked. A cursor, `"latest-N"`, or `"latest-DURATION"` in whole hours, else seconds, else milliseconds.
- `from_wall_time`: the start of a time window, `nil` otherwise.
- `start_exact`: `false` when Insider could not narrow the start of a time window exactly. The window may then include older events.
- `as_of`: when the digest was made.
- `age_ms`: how old the newest event of the window was then. `nil` without events.
- `cursor`, `upto`, `next_cursor` (at most `upto`), and `next_receipt` (the last read's).
- `events`, `reads`, `first_receipt`, `last_receipt`, `first_wall_time`, `last_wall_time`, and `span_ms`.
- `complete` and `stopped_by`.

One budget, `bounds.digest_budget_ms` (3,000 ms), starts before the digest reads anything. It is below the observer's default call timeout. It bounds the `"latest-N"` lookup and every read. Each call gets only what is left of the budget, plus the 200 ms margin that every owner call has. With no time left before the first read, the digest is `timeout`.

An unfinished window has `complete` `false`. Its `stopped_by` is `deadline`, `no_progress`, `read_past_window`, or the error code of a later read. To continue, set `"since"` to its `next_cursor`.

### Anomalies

`anomalies` (internal: `Insider.Live.Anomalies`) are the findings to read first, ranked. Each has a `kind`, a one-line `line`, and the next `command`. The kinds are:

- `request_burst`: each burst. When the Recorder evicted events in the window, the line says that other bursts may be missing.
- `pre_handler_wait`: the slowest wait before the endpoint, from 1 s.
- `n_plus_one`: a request whose one query shape repeated 10 times or more.
- `error_spike`: the most frequent error signature, from 5 events, not a supervisor report.
- `crash_loop`: each restart loop.
- `mailbox`: the longest mailbox, from 100 messages.
- `run_queue`: from 50 at the last VM sample.
- `evicted`: events that the Recorder evicted in the window, with `--max-events 4096`.

The text opens with them, right after its first line. It prints `Anomalies (most important first):`, then each numbered line followed by `next: …`. With none, it prints `Anomalies: none in this window.`

Every `command` runs as printed, with the session id filled in. A mailbox command names its process by registered name only when it has one, else by pid.

Each anomaly also has an `identity`: 16 hex digits that hash its kind and what it is about. Examples are a crash loop's offender and reason fingerprint, an error signature, a route, a process, or a key. It also has a `count` with its `unit`. The unit is `rate`, a count over the window's `span_ms` of at least a minute, or `level`. A [known-normal baseline](#known-normal-baseline) uses these fields.

`status` of a running session adds the `anomalies` of the last 60 s (`anomalies_window` `"latest-60s"`) and `anomalies_complete`. When Insider could not read the window whole within 1.5 s, `anomalies_note` says why: `incomplete: the read stopped (deadline) after N events …`, or, with `anomalies` `nil`, `could not be read (CODE)`. These reads renew no lease. They keep no cursor, baseline, or view. They never end or revoke the session. In a denied environment, Insider refuses them, and the status says so.

### Observer traffic

Insider counts requests to an observer's own endpoint apart. Examples are `/tidewave` and Tidewave's MCP calls. This works in the rich profile, where requests have paths. The count is in `requests.observer` (`requests`, `paths`). Insider leaves these requests out of the request waits and bursts. The text says so once after the anomalies: `Observer traffic: 40 requests to /tidewave (the observer's own calls) are left out of the anomalies.`

### Counts, crash loops and error signatures

`counts` gives events `by_kind`, `by_severity`, `by_source`, and `by_offender` (the `offender_id` of `supervisor_child_terminated` events).

`crash_loops` lists each child that terminated at least twice for the same reason in the window. Each entry has `offender_id` and its short `offender` name, `supervisor`, `restart_type`, `reason_class`, `reason_fingerprint`, `restarts`, `period_ms` (the median gap between their wall times), `period_min_ms`, `period_max_ms`, and the first and last receipt and wall time.

`error_signatures` lists the ten most frequent signatures of `error` and `critical` events. Each has `count`, `processes` (distinct pids), the kind and source, and the first and last receipt and wall time.

Insider builds a signature from code identifiers in the disclosed event:

- the kind.
- a supervisor's offender, reason class, and fingerprint prefix.
- a Logger event's `mfa`.
- the exception module, from `** (Name)`, `%Name{`, or a rendered struct's `"__struct__"`.
- a Telemetry event's `kind`, `reason`, `result`, and HTTP `status`.
- the first line of the message, with numbers, pids, references, and long hex runs replaced.

So one bug with many values is one signature. An HTML page (such as a debugger page) is `[html]`.

### Latency

`latency` has up to ten rows, slowest p95 first.

A row `from` `summaries` has:

- the kind's summary `count` and `errors` over the window.
- the latest interval's `p50_us` and `p95_us`, and the window's `max_us`.
- up to twelve `intervals`.
- `exemplars`: the window's three slowest exemplars and its first error. Each has `receipt`, `roles`, `duration_us`, and `error`. An exemplar whose duration the boundary withheld still names its receipt.
- `exemplars_lost`, summed over the window.
- `first_error_lost_intervals`: intervals whose `first_error_retained` is `false`.

Insider computes a row `from` `events` from the `durations_us` of the recorded events (`duration`, else `total_time`), by nearest rank.

Every row has `call_timeouts`. It counts the kind's `error` or `critical` events whose disclosed `result`, `reason`, or `error` holds the exit `{:timeout, {GenServer, :call, _}}` (or the `:gen_server` form). `logged_call_timeouts` counts the failing Logger events whose message holds it.

### Trends, processes and VM

`trends` holds up to ten Telemetry series of `trends/2` (see [Summary trends](#summary-trends)) over the last twelve intervals of the window. `logger_bursts` holds up to ten Logger burst series, most messages first.

`processes` lists up to five longest mailboxes that the Poller's process evidence showed: `message_queue_len` now, at the first sample, and the maximum. A row is one process, by `pid`. `process_top` rankings and `process_watch` samples of the same pid are one row. Two processes with one label (unregistered workers of one initial call) are two rows. A row's `process` is the registered name (`Shop.Pricing`) when any sample names it, else the initial call or the pid.

`vm` holds the first and last `vm_sample` of the window and, per integer metric, `first`, `last`, and `delta`. `vm.target` has the same for the node without Insider's own share. It takes `process_count`, `processes_bytes`, `ets_count`, and `ets_bytes`, less the Poller's `insider_process_count`, `insider_processes_bytes`, `insider_ets_tables`, and `insider_ets_bytes`. It is present when the Poller measured them, that is with `top_processes` and `top_ets_tables` above 0.

### Filtered counts and gaps

`filtered` is the `filtered` of the window's first read, since the window's start cursor, with its `scope`.

`gaps` holds:

- the receipt-range losses of the window's reads. Each read counts its own losses up to `upto`. So Insider never attributes a later eviction to the window, and never hides a withheld receipt in it.
- the first read's losses without a receipt.
- every `unknown` gap.

The digest also has `session_id`, `node`, `state`, `lease_remaining_ms`, and `disclosure_profile`.

## Digest hints and text

The digest ends with the functions to trace, the next commands to run, and, with `"human"`, a plain-text summary.

### Call candidates

`call_candidates` lists up to three functions that the crash and exception events of the window point at, most first. Each has `function`, `count`, `first_receipt`, and `kinds`.

A candidate is the first application frame of each event's disclosed stack (`{Mod, :fun, 3, ...}` or `Mod.fun/3`) that `--calls` would accept. It is never a function of a runtime (Elixir, OTP, Logger, Telemetry), preloaded, or Insider module.

### Hint kinds

`hints` give the next command to run. Each hint has:

- `kind`.
- `reason`: the counts it rests on.
- `evidence`.
- `command`: the observer command, with `"${N[@]}"` for the target flags. `nil` when there is none.
- `options`: the same change as `amend/2` options. `nil` when there is none.
- `manual`.
- `window` (`since`, `first_receipt`, `last_receipt`): the window that Insider worked the hint out over.

Call-trace hints:

- `trace_calls`: the `amend` that adds the calls component and traces a function with `--calls-results exceptions`. It keeps the session's components and traced functions. Insider suggests it for a crash loop or a function that two or more failures point at. For a child that keeps crashing with no frame of its own, it suggests the child's exported GenServer callbacks. It does not suggest a function that the session already traces.
- `trace_calls_unavailable`: the same before OTP 28, where call tracing is unavailable. It has `manual`, the `:recon_trace.calls/2` call to run by hand.

Flood hints apply to each share group that the Recorder evicted from and that holds more than its share of events or bytes (`status` `recorder.sources`, counted since the session started or was last amended):

- `reduce_logger`: a `--logger-summary` rule for the module, else the domain, whose Logger messages were most in the window. The session must accept it as a rule. Insider adds it to the session's rules. Insider never summarises reports, so it counts them apart, as `evidence.reports` by kind.
- `logger_reports`: only reports flood. It has no command, because no summary reduces reports. The reason names the kinds and points to `raise_capacity` for an event flood. For a flood over the byte share only, it says that the byte bound is fixed and that only smaller or fewer reports help.
- `reduce_telemetry`: a `--telemetry-summary` for the kind recorded most.
- `reduce_poller`: twice the Poller interval, up to 60,000 ms.
- `raise_capacity`: `--max-events 4096`, when `max_events` is below 4,096 and a source is over its share of events. It raises every source's share of events. The byte bound is fixed.
- `shared_readers`: with any flood, when two or more readers (named readers and `watch` subscribers) share the session. It has no command. It has `evidence.readers` and `evidence.evicted`. It says that the readers share one Recorder and that a read keeps nothing, so each reader loses the evicted events. It advises: read `digest` and `trends` rather than every event, summarise frequent kinds, narrow each reader with a view, and read often.

### Hint commands

```sh
mix insider.live amend "${N[@]}" --session SESSION_ID --logger-summary module:MyApp.Checkout
```

Insider compares a function as `--calls` resolves it. So `Mod.f/1`, `Elixir.Mod.f/1`, and `:"Elixir.Mod"` frames are one function. Insider does not suggest a function that the session traces in any spelling. It keeps the session's spelling. It writes a new function as `--calls` accepts it (`Mod.f/1`, `:mod.f/1`).

Every value in a `command` is single-quoted. A `'` inside it is written `'\''`. So a shell passes it through as one argument. Insider never offers a Logger origin that is not a valid rule: an unknown module, or a domain that is not lowercase segments of existing atoms.

An amendment's list replaces the session's list. So a hint has no `command` or `options` when the suggestion would pass the list's limit (16 `--calls`, 16 Logger rules, 16 Telemetry summaries). It then has `evidence.limit` and a `reason` that says the limit is reached.

Insider works hints out after the window's reads, from the session's configuration. An ended session has none. A session whose configuration Insider could not read within the digest budget has none.

An `events_since/3` batch from a running session that shows a crash or an exception carries `"hints"` too. It has a `trace_calls` (or `trace_calls_unavailable`) hint for each function that its events point at. The key is absent when there is none. It is also absent from the digest's own bounded reads. The observer's `--format compact` prints each hint as a `# hint:` line after the batch's `#` line.

### Digest text

The `"text"` summary has these lines, in order:

1. One line each for the window and its profile.
2. `Window:`: what was asked for, a time window's start in UTC, the receipt it ends at, and how old its newest event is. When `start_exact` is `false`, it says that the window may include older events.
3. A staleness line, when a window not limited in time has a newest event over a minute old. It gives the `--since latest-60s` that covers the last minute.
4. The severities.
5. Every crash loop with its period.
6. The slowest operation and the next two, with their exemplar receipts and losses. A p95 near 5 s reads "consistent with GenServer.call timeouts" only when that kind's `call_timeouts` or `logged_call_timeouts` shows the exit. Otherwise the text states only the latency.
7. Up to three trends and three bursts.
8. The declared duration scope note, when there is one (see [Duration claims](#duration-claims)).
9. The top three error signatures.
10. The longest mailbox.
11. The VM changes: the node's processes, process memory, and ETS without Insider's own, Insider's own beside them, ports, and binaries. A total that the Poller did not split says that it includes Insider's share.
12. The filtered totals and the losses.
13. One `Next (receipts A-B[, the last DURATION]):` line per hint: its reason, then its command or manual call.
14. How to continue an unfinished window.

## Known-normal baseline

```sh
mix insider.live baseline "${N[@]}" --session SESSION_ID --human
mix insider.live baseline "${N[@]}" --session SESSION_ID --since-mark --human
mix insider.live digest "${N[@]}" --session SESSION_ID --human --show-baseline
mix insider.live baseline "${N[@]}" --session SESSION_ID --show
mix insider.live baseline "${N[@]}" --session SESSION_ID --clear
```

A baseline marks the anomalies that a digest shows now as normal for this session. Examples are a dev restart loop or known noise. Later digests and `status` then lead with what is new and fold the rest into one line.

`baseline(session_id, options)` (observer `baseline`, optional `--since latest-5m` and `--human`) returns `insider.live-baseline/v1`. It marks every candidate anomaly of a window as normal for this session. The default window is `latest-5m`, read through the reader's view. It takes every qualifying wait, error signature, and mailbox, not only the one a digest shows. It keeps the earlier entries that the window does not have.

The baseline holds up to 64 entries of `kind`, `identity`, `count`, `span_ms`, and `unit` (see [Anomalies](#anomalies)), and `set_at`. It holds no name, path, message, or value. So no profile narrows it. A window without anomalies leaves the baseline as it was.

Later digests and `status` fold each candidate against the baseline. Then they choose the top new anomaly of each kind. So a known maximum never hides a new anomaly below it.

- `anomalies` keeps the new anomalies.
- `anomalies_known` keeps the baselined ones.
- `baseline` says when it was set and how many anomalies it hid.
- The text leads with what is new: `Anomalies (new first; 2 known-normal anomalies hidden, baseline set 14:02; --show-baseline):`, or `Anomalies: none new; 2 known-normal anomalies hidden (…)`.

A baselined anomaly comes back at 10 times its baselined rate or level. Insider compares counts over windows unrounded. The line then ends `Back above its baseline: 12x (2/min when marked normal at 14:02).`

- `digest --show-baseline` (`"show_baseline"`) lists the hidden anomalies after the new ones.
- `status` adds `anomalies_known` (a count) and `baseline_set_at`.
- `"show"` (`--show`) returns the baseline: kinds, identities, and rates.
- `"clear"` (`--clear`) removes it.
- `baseline --since-mark` (or `"since" => "mark"`) marks the window of a [pairing mark](live-sessions-and-readers.md#pairing-marks) normal.

Every baseline operation passes the same environment gate as a digest read. On a running session it renews the lease. `status` reads the baseline while it observes. The session keeps the baseline for its life and its read-only window.

## Summary trends

```sh
mix insider.live trends "${N[@]}" --session SESSION_ID
mix insider.live trends "${N[@]}" --session SESSION_ID --kind shop.pricing.lookup --human
mix insider.live trends "${N[@]}" --session SESSION_ID --kind logger_summary --windows 12
```

`trends(id, options)` (observer `trends`) returns `insider.live-trends/v1`: how each summary series moved across its windows. It reads the same window as a digest, within the same budget, and renews the lease.

| Option | Observer flag | Meaning |
|---|---|---|
| `"since"` | `--since`, `--since-mark` | As for the digest. Default `0`. |
| `"kinds"` | `--kind` | Up to 64 kinds to keep (list below). `[]`, the default, keeps all. |
| `"windows"` | `--windows` | The most recent windows listed per series, 1 to 500. Default 60. |
| `"human"` | `--human` | Adds `"text"`, one line per series. |

`"kinds"` takes summarised Telemetry kinds, `"logger_summary"` for the Logger bursts, and `vm_sample`, `port_top`, `process_top`, or `process_watch` for the Poller series.

Every value has a fixed unit, listed under `"units"`:

- durations in microseconds.
- rates in events per minute (`rate_per_min`). They are integers, because the plain-term contract has no floats.
- error shares in whole percent of the count.
- intervals in milliseconds.
- window bounds as ISO 8601 UTC.

`notes` says what the series say together. The result also has `filtered`, `gaps`, and the digest's `window`, `session_id`, `node`, `state`, and `disclosure_profile`.

### Telemetry and Logger series

`telemetry` holds one series per summarised kind, slowest last p95 first.

- Each window has `started_at`, `ended_at`, `interval_ms`, `count`, `rate_per_min`, `errors`, `error_pct`, `p50_us`, `p95_us`, `max_us`, `exemplars` (receipts), `exemplars_lost`, and `first_error_retained`.
- The series has `windows`, `duration_scope` (the latest summary's), `exemplars_lost` (the sum over its windows), `first_error_lost_windows`, and `change`.
- `change` gives, per rate, p95, max, errors, and error share, the `first` and `last` value, `delta`, and `direction`. `direction` is `flat` within 10% of the first value, else `rising` or `falling`. So the 6.25% precision of a percentile bucket never reads as a trend.

`logger` holds one series per Logger burst, most messages first. A series is keyed by template fingerprint, call site fingerprint, and level. Each level also has an overflow row.

- The series has `level`, `overflow`, `template`, `template_fingerprint`, `call_site`, `call_site_fingerprint`, `count`, `windows`, `peak_count`, up to three `exemplar_receipts`, `exemplars_lost`, `distinct_lost`, and the rate `change`.
- Each window has `count`, `rate_per_min`, `exemplar_receipt`, `exemplar_lost`, and `distinct_lost`.

### Poller series

`poller` holds one series per Poller metric and subject, one point per sample:

- `binary_bytes` and `port_count` per `vm_sample`.
- `port_type` per `port_top`. The subject is the port type.
- `message_queue_len` per process, from `process_top` rankings and `process_sample`/`process_watch`. The subject is its registered name, else its initial call or pid. The series also has `pid`.

Each series has:

- `unit`: `bytes`, `ports`, or `messages`.
- `source_kinds`.
- `coverage`, for a mailbox:
  - `ranked`: only from rankings. So there is no point where a ranking did not list the process, and never a zero.
  - `watched`: every point is a direct `process_watch` or `process_sample` of the process. A failed probe leaves an interval without a point.
  - `mixed`: both. The ranked stretch keeps its gaps.
- `windows`: points read. The samples of one poller cycle are one point. The later sample replaces the earlier.
- `first_at`, `last_at`, and `change` (as above).
- `per_min`: the change per minute between the first and last point. `null` for one point.
- `max`: over every point read, whatever the point bound kept.
- the most recent points: `at`, `value`, and `delta` from the previous point.

A port type counts zero ports only at a complete census. A complete census read every port (no `scan_limit` in `unavailable`). It listed every type it found (`type_count`, nothing `omitted`). It stayed below the type bound of 512, beyond which types fold into `other`. A type missing from any other scan has no point. A type first seen later starts from a zero at each earlier complete census of the window.

Insider shows at most 10 series per metric, largest last value first. `poller_omitted` counts the rest per metric. Insider follows at most 64 subjects per metric in a window. `poller_untracked` counts the samples of the others.

### Duration claims

Insider never infers a duration's scope. Only a kind that the session declared with `"telemetry_duration_scopes"` has `measured_in` `handler` or `caller`. The text then says "declared handler time" or "declared caller-observed latency".

When one declared handler series and one declared caller series are both present, a note says this: if both describe the same operation, the difference is time outside the handler, such as queueing. Insider does not establish that they describe the same operation.

An undeclared series emitted inside an OTP server reads "emitted inside OTP server M; scope not declared". It makes no other claim.

## Filters, summaries, and views

An idle development node can emit many events a second: every repository query (Oban's polling included) and every log line. Recording all of them costs work in every emitting process. It also evicts useful history from the bounded Recorder. So a live session filters at record time, in the process that logs or emits. Each reader can then narrow what it is shown. [Telemetry and Logger summaries](#telemetry-and-logger-summaries) describes the summary filters.

### Quiet defaults

A session started without options records:

- Logger events at `warning` or more severe.
- OTP SASL-domain reports (crash, supervisor, and progress reports) at `info` or more severe.
- The quiet default Telemetry events, when the node has them:
  - each Ecto repository's query event, from `:ecto_repos` and the repository's `:telemetry_prefix`, else Ecto's default prefix.
  - `phoenix.endpoint.stop` and `phoenix.router_dispatch.exception`, when Phoenix is loaded.
  - `oban.job.exception`, when Oban is loaded.
  - `absinthe.execute.operation.stop`, when Absinthe is loaded. It is one event per GraphQL operation, with its outcome (see [GraphQL outcome](live-otel-traces.md#graphql-outcome)).
  - `bandit.request.stop`, or `cowboy.request.stop` with cowboy_telemetry, when the server is loaded (see [Request waits and bursts](live-otel-traces.md#request-waits-and-bursts)).
- Of those, only events that take at least 100 ms (`"telemetry_min_duration_ms"`). Errors are always recorded. These events are recorded whatever their duration, because each is one per request, job, or operation: `phoenix.endpoint.stop`, `oban.job.stop`, `absinthe.execute.operation.stop`, `bandit.request.stop`, and `cowboy.request.stop`.
- Nothing that Oban's own machinery emits (`"exclude_origins"` `["oban"]`).

The session does not record every query or log line. It counts them (see [Filtered counts](#filtered-counts)).

### Record-time filters

```sh
mix insider.live start "${N[@]}" --component logger --logger-level info --logger-include module:MyApp.Checkout
mix insider.live start "${N[@]}" --component logger --logger-level info --logger-summary module:MyApp.Checkout --logger-summary-interval-ms 5000
mix insider.live start "${N[@]}" --component telemetry --telemetry-event 'my_app.*' --telemetry-min-duration-ms 0
mix insider.live start "${N[@]}" --component telemetry --telemetry-event 'my_app.*' --exclude-origin none
```

Record-time filters are start options. Insider compiles them once into a gate kept in `:persistent_term`. The Logger and Telemetry handlers consult the gate before they do anything else. A dropped event costs the decision and one counter increment. It gets no sequence number, no handler statistics, no normalization, and no inbox write.

A supervised gate owner process (internal: `Insider.Live.Gates`) starts before the session owner. It creates every gate, owns its summary table, and monitors the session owner. It erases the gate when the session ends, when the session owner dies, or when a start is interrupted. A restarted session owner reclaims its gates before it accepts a call.

Gate creation has a 500 ms deadline:

- A creation that the gate owner handles later creates nothing.
- Insider aborts a timed-out creation, and `start/1` returns `timeout`.
- The session owner's next creation also erases any gate it still held.

The session owner is the heir of each summary table. So a restart of the gate owner loses no summary: the tables pass to the session owner, and the restarted gate owner adopts the gates of live session owners. At most 8 gates exist at once. Past that, `start/1` returns `busy`.

### Filter options

| Option | Meaning |
|---|---|
| `"logger_level"` | The least severe Logger level recorded: `emergency`, `alert`, `critical`, `error`, `warning`, `notice`, `info`, or `debug`. Default `"warning"`. SASL-domain reports at `info` or more severe pass it. |
| `"logger_include"` | Up to 16 rules (shape below). When non-empty, Insider records only Logger events that match a rule. |
| `"logger_exclude"` | Up to 16 rules of the same shape. Insider does not record matching Logger events. |
| `"exclude_origins"` | Up to 16 origins (below). Default `["oban"]`. `[]` records every origin. |
| `"telemetry_min_duration_ms"` | 0 to 3,600,000. Default 100. Insider drops a shorter Telemetry event (below). |
| `"telemetry_event_min_duration_ms"` | A map from event kind to its own minimum. The record shows every event's effective minimum. |
| `"telemetry_summaries"` | Up to 16 recorded event kinds to summarize instead of recording each event. |
| `"telemetry_summary_interval_ms"` | 1,000 to 300,000. Default 10,000. |
| `"otel_min_duration_ms"` | With the otel component only, 0 to 3,600,000. Default 0 (below). |
| `"telemetry_duration_scopes"` | Up to 16 entries, a map from a summarised kind to `"handler"` or `"caller"`. Default `%{}`. |
| `"logger_summaries"` | Up to 16 rules of the `"logger_include"` shape (below). Needs the `"logger"` component. |
| `"logger_summary_interval_ms"` | 1,000 to 300,000. Default 10,000. |

- **Rule shape:** a map with exactly one key. `"domain"` is a segment list, a prefix of the event's `:domain`. `"application"` is the `:application` metadata, or any module of that application in `:mfa`. `"module"` is the `:mfa` module or a module in its namespace.
- **`"exclude_origins"`:** Insider does not record the Logger and Telemetry events of these origins, or the spans that their processes end. `"oban"` matches queries made through `Oban.Repo`. That is the `oban_conf` telemetry option that Ecto passes as `:options` metadata. It also matches processes started by the modules of Oban and its companion applications: `oban`, `oban_pro`, `oban_met`, and `oban_web`, whose plugins and reporters query on their own timers. It does not match job execution (`Oban.Queue.Executor`), because that work is the application's. `%{"application" => name}` and `%{"module" => name}` match the initial call of the emitting process. Insider resolves module namespaces once, at start. The observer's `--exclude-origin none` alone records every origin.
- **`"telemetry_min_duration_ms"`:** the filter uses the event's `duration`, else `total_time`. Insider records a shorter event when it is an error by the [severity rule](#event-severity). It never drops an event without a duration for this reason.
- **`"telemetry_event_min_duration_ms"`:** the built-in entries `phoenix.endpoint.stop`, `oban.job.stop`, `absinthe.execute.operation.stop`, `bandit.request.stop`, and `cowboy.request.stop` are 0.
- **`"otel_min_duration_ms"`:** the default records every span, because a trace with missing segments is hard to read. Insider does not record a shorter span unless its status is error.
- **`"telemetry_duration_scopes"`:** `"handler"` means that the code that handles the operation measured the duration. `"caller"` means that the code that waits for it measured it. Every key must be in `"telemetry_summaries"`. The observer flag is `--telemetry-duration-scope KIND=handler|caller`, repeatable. An undeclared kind's scope is `unknown`.
- **`"logger_summaries"`:** Insider counts a matching Logger message (not a report) that passes the other filters in its burst, instead of recording it. The burst key is the level, the normalised message template, and the call site. Insider records the first message of each burst in an interval in full as its exemplar. See [Logger bursts](#logger-bursts).

Every name resolves only to an atom that already exists. Insider counts a dropped event once, under the first filter that drops it. For Logger events, the order is level, include, exclude, origin. For Telemetry events, it is origin, summarized, minimum duration. Insider uses origin metadata only to decide. It never records or returns it.

### Views

```sh
mix insider.live events "${N[@]}" --session SESSION_ID --cursor 0 --view-source logger --view-min-severity error
mix insider.live watch "${N[@]}" --session SESSION_ID --for 30s --view-kind 'phoenix.*'
```

`events_since/3` and `subscribe/3` take an optional `"view"`. It narrows only that reader's events, over the same recorded stream. So several agents can read one session differently without hiding anything from each other. See [Per-reader views](live-sessions-and-readers.md#per-reader-views) for views that a named reader keeps.

A view is a map of:

- `"sources"`: a subset of `calls`, `inspect`, `logger`, `otel`, `poller`, and `telemetry`.
- `"kinds"` and `"exclude_kinds"`: up to 32 kinds. `"prefix.*"` matches a dotted prefix.
- `"min_severity"`: `debug`, `info`, `warning`, `error`, or `critical`.

Hidden events still advance the cursor. So a batch can be empty while `next_cursor` moves on. Hidden events never count against `"limit"` or `"max_bytes"`. Only `"scan_limit"` bounds them, and `truncated_by` says when it ended the read.

A malformed view is `invalid_options` with field `"view"`. A new subscription by the same subscriber replaces its view.

### Filtered counts

Every batch reports what it did not show, in `filtered`. So you can tell silence apart from inactivity:

```elixir
"filtered" => %{
  "scope" => "since_cursor_issued",   # or "since_session_start", as for gaps
  "logger" => %{"level" => 120, "include" => 0, "exclude" => 0, "origin" => 3},
  "telemetry" => %{
    "my_app.repo.query" => %{"origin" => 40, "summarized" => 0, "min_duration" => 12}
  },
  "otel" => %{"origin" => 30, "min_duration" => 0},   # only with the otel component
  "view" => %{"min_severity" => 2}   # this read's view only; %{} without a view
}
```

Record-time counts are deltas against the counts stored when the reader's cursor was first issued. Cursor `0`, or a cursor that this session never issued, reports since session start. So a read from the same cursor repeats them. Insider reads them when it builds the batch. View counts cover the events that this read hid.

The owner sends a subscriber a batch when it has events or gaps. It also sends one when only filtered counts changed, at most every 5,000 ms (`bounds.filtered_report_ms`). The counts of batches it did not send carry over. A terminal subscriber batch without a final read has `"filtered" => nil`.

## Telemetry and Logger summaries

A summary counts many events in one recorded event per interval. Telemetry summaries keep a histogram of durations. Logger bursts count messages per template and call site.

### Telemetry summaries

```sh
mix insider.live start "${N[@]}" --component telemetry --telemetry-event phoenix.endpoint.stop --telemetry-measurement duration --telemetry-summary phoenix.endpoint.stop --telemetry-summary-interval-ms 5000
```

A summarized event adds its sample to a fixed-size histogram in the emitting process, with one `:ets.update_counter/3` call. So all fields of a sample (count, error, duration, maximum) land in the same interval.

Once per interval in which it had samples, the Telemetry collector records one event of that kind with:

- `"lifecycle_phase" => "summary"`.
- `"projection" => "telemetry.summary/v1"`.
- `"summary" => %{"count", "errors", "timed", "duration_measurements", "duration_p50_us", "duration_p95_us", "duration_max_us", "interval_ms", "window_started_at", "window_ended_at", "exemplars", "exemplars_lost", "first_error_retained", "duration_scope"}`.
- severity `warning` when it counted an error.

`window_started_at` and `window_ended_at` are the wall-clock bounds of the interval (ISO 8601 UTC). `interval_ms` is its monotonic length. An interval without samples records nothing.

A percentile is the upper bound of its histogram bucket. It is never below the true value, at most 1/16 above it, and never above the interval maximum.

Insider derives the duration statistics from the measurements named in `"duration_measurements"` (`duration`, else `total_time`):

- In the strict profile, they cross the live boundary only when every one of those names is in the host measurement allowlist when the batch is built. Otherwise they are `nil`, and each has a `drop` record in `"redactions"`.
- The rich profile discloses every measurement. So rich summaries carry their bounded duration statistics without that check.
- A rich summary read after the host narrowed to strict is withheld by the same rule.

When a session stops or its lease expires, the final read of each subscriber first records the pending interval. So its terminal batch carries it. A revoked session records nothing more.

### Exemplars

`"exemplars"` names up to three of the interval's slowest events and its first error. Each is `%{"receipt", "roles", "duration_us", "error"}`, with roles `slowest` and/or `first_error`. Insider records each in full just before the summary, with `attributes.exemplar_of`. To open one, read from the receipt before it:

```sh
mix insider.live events "${N[@]}" --session SESSION_ID --cursor 41 --limit 1
```

That command opens receipt 42.

The emitting process learns from its one counter update whether a sample is a candidate. A candidate is the interval's first error, or one of the first four samples of the histogram bucket that holds the running maximum. So the slowest exemplar is exact to within one bucket (6.25%). A slow sample that arrived after the maximum moved to a higher bucket is not a candidate.

Other candidates share the collector's bounded inbox. The first error takes a reserved path, one slot per kind per interval. So Insider keeps it whenever it reaches the collector.

`"exemplars_lost"` counts the interval's candidates lost before the summary was recorded. A candidate is lost when the inbox was full, normalisation failed, the Recorder refused it, or its receipt was unknown.

`"first_error_retained"` is `nil` without errors. It is `true` when the first error is among the exemplars, and `false` when it was lost.

Candidates lost that way, or that arrive after their interval was summarised, are also the read gap `telemetry_exemplar_lost`. In strict, each exemplar's `duration_us` follows the summary's duration rule. Each withheld value has one drop record at `[key:attributes, key:summary, key:exemplars, index:N, key:duration_us]`.

### Duration scope

`"duration_scope"` is `%{"measured_in", "declared", "emitter"}`, or `nil` without exemplars.

- `measured_in` is `"handler"` or `"caller"`, with `declared` `true`, only for a kind in `"telemetry_duration_scopes"`. Otherwise it is `"unknown"`.
- `emitter` is `%{"context", "module"}`. `context` is `"otp_server"` when the exemplars were emitted in a process whose initial call is `{M, :init, 1}` (module M, without `Elixir.`). It is `"process"` otherwise, and `"mixed"` when they differ.

`emitter` reports where the events were emitted. It never says what their duration measured, because an OTP server can itself be the caller of another. Strict withholds `emitter.module` with a drop record.

### Logger bursts

```sh
mix insider.live start "${N[@]}" --component logger --logger-level info --logger-summary module:MyApp.Checkout --logger-summary-interval-ms 5000
mix insider.live trends "${N[@]}" --session SESSION_ID --kind logger_summary
```

With `"logger_summaries"`, Insider counts a matching message under its burst key:

- the level.
- the normalised message template: the message's first 160 bytes, or the format of a `{format, args}` message. Numbers, pids, and hex runs are masked.
- its call site (`mfa` and line).

So the same message with different values is one burst. Two messages from one logging helper are two bursts. Insider records the interval's first message of a burst in full as its exemplar. It counts the rest in `filtered.logger.summarized`.

Insider admits at most 64 distinct burst keys per interval. Past that, a level's messages fold into one overflow row, and Insider counts the folded distinctions.

Once per interval, the Logger collector records one `logger_summary` event per burst. Its severity is the burst's level. It has `"summary" => %{"count", "level", "template", "template_fingerprint", "call_site", "call_site_fingerprint", "call_sites", "exemplar_receipt", "exemplar_lost", "interval_ms", "window_started_at", "window_ended_at"}`.

The overflow row has `"overflow" => true` and `"distinct_lost"`. It has no template or call site (`template_fingerprint` `"overflow"`).

Lost burst exemplars are the read gap `logger_exemplar_lost`. Folded distinctions are `logger_summary_overflow`. Insider collects the template text only in the rich profile. Strict withholds `template` and `call_site` with drop records and keeps both fingerprints.

## Event severity

```sh
mix insider.live events "${N[@]}" --session SESSION_ID --cursor 0 --view-min-severity warning
```

Every event carries a `"severity"`. A view's `"min_severity"` keeps or hides the event by it. Insider generates the welcome document's `severity` table from the rules below.

- Logger: the Logger level.
  - `emergency`, `alert`, and `critical` are `critical`.
  - `error` is `error`, and `warning` is `warning`.
  - `notice` and `info` are `info`.
  - `debug` is `debug`.
- Poller samples are `debug`.
- OpenTelemetry spans:
  - `error` when their status is error, or their GraphQL outcome (`attributes.graphql`) has GraphQL errors.
  - `warning` when the outcome reports only payload validation errors.
  - `info` otherwise.
- Telemetry (internal: `Insider.Collector.Telemetry.Outcome`): an event is `error` when its name ends in `exception`, or when its metadata has a failure shape:
  - `result` `{:error, _}` or `:error`: a failed Ecto query, Finch, and Phoenix socket and channel joins.
  - `conn.status` or `status` 500 to 599: `phoenix.endpoint.stop`, `phoenix.router_dispatch.stop`, `bandit.request.stop`, and `phoenix.error_rendered`.
  - `kind` `:error`, `:exit`, or `:throw`.
  - an `error` that is neither `nil` nor `false`: `oban.plugin.stop` and `bandit.request.stop`.
  - an Absinthe `blueprint` whose result has GraphQL errors: `absinthe.execute.operation.stop`, even in an HTTP 200.
- An Absinthe operation whose payload reports only validation errors is `warning`. So is a summary that counted an error.
- Every other Telemetry event is `info`.

The decision runs in the emitting process. It reads only the event name and those shapes: a result's tag, a status class, an exception kind, and whether an error is present. It reads no other metadata value and records nothing about it.

A summary's `errors` and the minimum-duration bypass use the same rule. So the events that a summary counts as errors are the ones that a `"min_severity" => "error"` view keeps when they are recorded.

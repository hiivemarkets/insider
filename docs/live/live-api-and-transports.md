# Insider Live: API and transports

[Index](../README.md) · [Glossary](../glossary.md) · [Cheat sheet](../cheat-sheet.md)

The `Insider.Live` functions and start options, who may observe a node, the session lease, the cleanup receipt, and the two transports: Tidewave `project_eval` and the Lab observer node over Erlang distribution.

## Contents

- [Live observation](#live-observation)
  - [Functions](#functions)
  - [Start options](#start-options)
- [Environment and ownership](#environment-and-ownership)
- [Lease](#lease)
- [Stop and check the cleanup receipt](#stop-and-check-the-cleanup-receipt)
- [Tidewave `project_eval`](#tidewave-project_eval)
- [Observer node (Erlang distribution)](#observer-node-erlang-distribution)
  - [Boot the target](#boot-the-target)
  - [Observe from the command line](#observe-from-the-command-line)
  - [Load Insider into the target](#load-insider-into-the-target)
  - [Default session](#default-session)
  - [Observer flag reference](#observer-flag-reference)
  - [Recording flags for start and amend](#recording-flags-for-start-and-amend)
  - [Read flags](#read-flags)
  - [Argument errors](#argument-errors)
  - [Output formats](#output-formats)
  - [Watch stream](#watch-stream)
  - [Several agents at once: the escript](#several-agents-at-once-the-escript)
  - [Exit statuses and error codes](#exit-statuses-and-error-codes)

## Live observation

`Insider.Live` lets an agent observe a running node while the node keeps running. The node does not need Phoenix. `Insider.Live` is the transport-agnostic part, and it runs inside the target node.

Every argument and result is a plain term that can cross Erlang distribution: string-keyed maps, binaries, integers, booleans, `nil`, and lists. No struct, handle, pid, reference, or fun crosses the API. The one exception is the subscriber pid that a caller passes in. `Insider.Live.JSON` exposes the same operations. Each returns one canonical JSON binary (`{"ok":...}` or `{"error":...}`, with sorted keys and no whitespace). Two transports use the API:

- Tidewave `project_eval` in a Phoenix development server. See [Tidewave `project_eval`](#tidewave-project_eval).
- A separate, short-lived observer node over Erlang distribution, which calls these functions with `:erpc`. The Lab's `mix insider.live` and `insider-lab live` are this observer. See [Observer node](#observer-node-erlang-distribution).

An agent starts with `welcome/1`. It returns the [welcome document](live-welcome-and-reports.md#welcome-document), which Insider generates from this code. By default the document is an agent quick start. With `%{"full" => true}` it is the full reference. The agent reports Insider's own bugs, and any behaviour that differs from the document, with `report/1` (see [Agent reports](live-welcome-and-reports.md#agent-reports)).

### Functions

| Function | Returns | Renews the lease |
|---|---|---|
| `welcome/1` | `insider.live-welcome-quick-start/v1`, or `insider.live-welcome/v2` with `%{"full" => true}` | no |
| `capabilities/0` | `insider.live-capabilities/v1`: what the node allows now | no |
| `discover/1` | `insider.live-telemetry-discovery/v1` | no |
| `process/1`, `bin_leak/1`, `ports/1`, `alloc/1` | `insider.live-process/v1`, `insider.live-bin-leak/v1`, `insider.live-ports/v1`, `insider.live-alloc/v1` | no |
| `start/1` | `insider.live-session/v1` | starts it |
| `amend/2` | `insider.live-amendment/v1` | yes |
| `events_since/3` | `insider.live-events/v1` | yes |
| `digest/2` | `insider.live-digest/v1` | yes |
| `baseline/2` | `insider.live-baseline/v1` | yes |
| `trends/2` | `insider.live-trends/v1` | yes |
| `mark/2` | `insider.live-mark/v1` | yes |
| `marks/2` | `insider.live-marks/v1` | no |
| `trace/3` | `insider.live-trace/v1` | yes |
| `mutations/2` | `insider.live-mutations/v1` | yes |
| `changes/2` | `insider.live-changes/v1` | yes |
| `timeline/2` | `insider.live-timeline/v1` | yes |
| `renew/1` | `insider.live-lease/v1` with the renewed lease | yes |
| `status/1` | `insider.live-status/v1` | no |
| `stop/2` | `insider.live-status/v1` with the cleanup `receipt` | no |
| `handoff_record/1` | `insider.live-handoff/v1` | no |
| `subscribe/3`, `unsubscribe/2` | `insider.live-subscription/v1` | no |
| `ingest_spans/2` | `insider.live-ingest/v1` | no |
| `report/1` | `insider.live-report-receipt/v1` | no |
| `reports/0` | `insider.live-reports/v1` | no |

What each result holds:

- **`welcome/1`**: see [Welcome document](live-welcome-and-reports.md#welcome-document). Any other option is `invalid_options`. It never starts anything.
- **`capabilities/0`**: `insider_version`, `environment`, `environment_source`, `allowed`, `owner_running`, `owner_responsive`, `components`, `start_options`, `telemetry_measurements_allowed`, `active_session_id`, and `bounds`. It also holds `quiet_default_telemetry_events`, the Telemetry events that a session without options records on this node.
  - `otel` holds `sdk_present` (whether the node can load the OpenTelemetry SDK) and `sdk_running`.
  - `welcome` is a pointer: the quick start's `schema` (what its `read_with` commands return), the full reference's `hash`, and `full_reference` with the full reference's `schema` and how to read it.
  - The disclosure fields are `disclosure_profile`, `disclosure_profile_source`, `disclosure_profiles`, and `masking_policy_id` (see [Disclosure profiles](../disclosure-and-safety.md#disclosure-profiles)). It never starts anything.
- **`discover/1`**: the Telemetry event names this node can emit. Each name has its `sources` (`source` `handler`, `execute`, or `span`, and `module`). The result also holds `events_total`, `modules` (what the scan read and skipped), `truncated`, `truncated_by`, `elapsed_ms`, and `bounds`. The optional `"prefix"` is a segment list. It starts and runs nothing. See [Telemetry discovery](live-runtime-evidence.md#telemetry-discovery).
- **One-shot inspections**: `process/1` inspects one process by `"name"` or `"pid"` and summarises its mailbox by message shape. `alloc/1` needs recon. Each inspection is bounded, passes the disclosure profile and credential masking, and is recorded in a running session as an `inspect.*` event. See [One-shot inspections](live-runtime-evidence.md#one-shot-inspections).
- **`start/1`**: `session_id`, `cursor` `0`, `lease_ms`, `lease_remaining_ms`, `lease_expires_at`, and the accepted configuration. The configuration includes `disclosure_profile`, `masking_policy_id`, and `telemetry_event_prefixes`. That field lists each prefix entry of `"telemetry_events"` with the names it expanded to (`[]` without one). `telemetry_skipped_defaults` lists the quiet default events that the node lacks, each as `{"event": "phoenix.endpoint.stop", "reason": "not_on_target"}`, when the session asked for the defaults (`[]` otherwise). `telemetry_hint` appears when none was left.
- **`amend/2`**: the session's new configuration and `amendment`. It changes a running session's recording options without losing its history. Insider expands a `"telemetry_events"` prefix entry as for `start/1`, and the reply lists it under `telemetry_event_prefixes`. It lists `telemetry_skipped_defaults` and `telemetry_hint` as `start/1` does.
- **`events_since/3`**: `cursor`, `events`, `next_cursor`, `next_receipt`, `gaps`, `filtered`, `truncated`, `truncated_by`, `lease_remaining_ms`, `disclosure_profile` (the profile this read's events crossed), and `state`. The cursor is an integer or `"latest"`. It accepts an optional per-reader `"view"` and `"reader"` name. It also reads a stopped session during its retention window (see [Several agents on one session](live-sessions-and-readers.md#several-agents-on-one-session)).
- **`digest/2`** summarises a window of the session's events in one call. See [Digest](live-digest-filters-and-trends.md#digest). **`trends/2`** shows how each summary series moved across its windows, in fixed units. See [Summary trends](live-digest-filters-and-trends.md#summary-trends).
- **`baseline/2`** marks the current anomalies (kinds, hashed identities, counts) normal for this session, or shows or clears that baseline. Later digests and `status` fold them into one line and lead with what is new. See [Digest](live-digest-filters-and-trends.md#digest).
- **`mark/2`** marks the moment before a programmer acts, so that a later read starts after it. It takes `"label"` (required) and `"reader"`. **`marks/2`** lists a running or stopped session's marks, oldest first. See [Pairing marks](live-sessions-and-readers.md#pairing-marks).
- **`trace/3`**: one trace's spans as a tree, merged in time order with the session's Logger and Telemetry events of the same trace. **`mutations/2`**: the session's kept mutation records (operation, result, response typenames, time, trace, process, client user agent, argument ids), through the reader's view, optionally of one record id. See [OpenTelemetry spans and traces](live-otel-traces.md#opentelemetry-spans-and-traces).
- **`changes/2`**: each write to a watched in-memory value (start option `"watch_writes"`). Each write has its key, its value (rich), and its writer's process, GraphQL operation, route, user agent, user id (rich), and trace. See [Changes of in-memory values](live-runtime-evidence.md#changes-of-in-memory-values).
- **`timeline/2`**: every source's events for one process (`"pid"`) or one request (`"request_id"`) in time order.
- **`status/1`** of a running session: collector health, `next_receipt` (the newest receipt, `0` before the first), `recorder`, `insider_memory`, `readers`, `amendments`, and `telemetry_subscriptions`.
  - `recorder` holds `oldest_receipt` (`nil` when nothing is retained), `retained_events`, `retained_bytes`, `max_events`, `max_bytes`, `archived_events`, and `sources`, each source's share and evictions (see [Recorder shares](live-sessions-and-readers.md#recorder-shares)).
  - `insider_memory` holds `processes` (bytes per Insider process that serves the session), `processes_bytes`, `recorder_bytes` (the Recorder's tables and event binaries), and `total_bytes`.
  - `telemetry_subscriptions` holds each subscribed event's `event`, `state`, and `seen` (see [Telemetry discovery](live-runtime-evidence.md#telemetry-discovery)).
  - For an ended session, `status/1` returns the retained record with its cleanup `receipt`, `nil` for `recorder`, `insider_memory`, and `telemetry_subscriptions`, `readable_remaining_ms`, and its `readers`.
  - Both records carry the session's current `disclosure_profile`, `masking_policy_id`, and `scope`.
- **`stop/2`**: see [Stop and check the cleanup receipt](#stop-and-check-the-cleanup-receipt). `stop/1` is `stop/2` with `%{}`.
- **`handoff_record/1`**: what another agent needs to continue the session (the observer's `handoff`).
- **`subscribe/3`** returns the subscriber's `view`, `cursor` (where its next batch starts), and `max_events` (its remaining event budget, `nil` when unlimited). It takes the optional `"cursor"`, `"max_events"`, and `"view"`. `subscribe/2` is `subscribe/3` with `%{}`.
- **`report/1`**: the queued `insider.live-report/v1` record, `duplicate`, `evicted`, `queued`, and `queue_max`. **`reports/0`**: this node's queued `reports`, oldest first, `queue_max`, and the host's `submission` setting. See [Agent reports](live-welcome-and-reports.md#agent-reports).
- **`ingest_spans/2`** records span maps that another process exported, at most 512 per call. See the list below.

`ingest_spans/2` in detail:

- Insider records each span as an `otel.span` event of the running session. The span contract, disclosure profile, and credential masking apply, and `attributes.capture` is `"ingest"`.
- It returns `accepted`, `rejected`, `filtered`, `shed`, and `duplicate`.
- It is idempotent per `{trace_id, span_id}` only while the span id is among the last 16,384 that the session's otel collector recorded from an ingest. `seen_evicted` counts the ids it has forgotten. A retry of a forgotten span is recorded again.
- Dedupe is per otel collector. Every amendment resets it, even one rolled back into a replacement collector. So a span ingested before an amendment is recorded again after it, and `seen_evicted` does not count that reset.
- A `timeout` means the outcome is **unknown**: Insider recorded some, all, or none of the spans. A retry skips the spans that the first attempt recorded, within that bound.
- An ended session returns `session_terminal`. A session without the `"otel"` component returns `component_unavailable` (`reason` `component_not_running`).
- The Lab's `otlp-receive` calls it. See [Frontend traces](live-otel-traces.md#frontend-traces-otlp-http-receiver).

### Start options

`start/1` accepts a string-keyed map:

| Option | Values | Default |
|---|---|---|
| `"components"` | a non-empty subset of `"calls"`, `"logger"`, `"otel"`, `"poller"`, and `"telemetry"` | `["logger", "telemetry"]` when the node has quiet default Telemetry events, else `["logger"]` |
| `"telemetry_events"` | up to 64 event names, each a list of up to 8 lowercase segment strings | the quiet default events |
| `"telemetry_measurements"` | a subset of the host measurement allowlist, such as `["duration"]` | see below |
| `"disclosure"` | `"rich"` or `"strict"` | the host profile |
| `"max_events"` | Recorder event bound, 16 to 4,096 | 4,096 |
| `"lease_ms"` | lease, 1,000 to 900,000 | 120,000 |
| `"retain_traces"` | 0 to 64 | 0 |
| Filters, Poller, call traces | see below | |

- **`"components"`**: the quiet default events are described under [Filters, summaries, and views](live-digest-filters-and-trends.md#filters-summaries-and-views). The Poller samples VM-wide scalars and, by default, ranks processes and ETS tables (see [Process and ETS evidence](live-runtime-evidence.md#process-and-ets-evidence)). `"otel"` records finished OpenTelemetry spans. It needs the SDK on the node, else the start fails with `component_unavailable` (see [OpenTelemetry spans and traces](live-otel-traces.md#opentelemetry-spans-and-traces)).
- **`"telemetry_events"`**: an example name is `["phoenix", "endpoint", "stop"]`. With `"telemetry"` and without this option, the session records the quiet default events that exist on the node. It skips the others and lists them under `telemetry_skipped_defaults`. If none exists, the session runs without the telemetry component, and the result carries `telemetry_hint`. With no other component, the start is `invalid_options`. Each segment of a name given here must already be an atom on the node, so that a caller cannot create atoms (`unknown_telemetry_event`). Insider records the events with phase `:event`, and their kind is the dotted name.
  - An entry whose last segment is `"*"`, such as `["shop", "*"]`, is a prefix. It has 1 to 7 segments before the `"*"`. It stands for every name that `discover/1` finds below it when the session starts. The limit of 64 counts the names after expansion (see [Telemetry discovery](live-runtime-evidence.md#telemetry-discovery)).
- **`"telemetry_measurements"`**: the allowlist is `config :insider, :live_telemetry_measurements` (up to 16 lowercase atoms). By default it is `count`, `decode_time`, `duration`, `idle_time`, `query_time`, `queue_time`, and `total_time`. Any other configured value allows none. `capabilities/0` reports the allowlist as `telemetry_measurements_allowed`. In the strict profile, only these names and only numeric values leave the node, and none leave without this option. In the rich profile, Insider returns every measurement unless this option selects some.
- **`"disclosure"`**: a caller may ask for a stricter profile than the host's, never a richer one (`disclosure_denied`).
- **Logger content** depends on the profile. The rich profile collects the formatted message text, level, and rendered metadata, bounded and with credentials masked. The strict profile never collects message text. A strict Logger event keeps only level, domain, label, message type, and, for OTP supervisor reports, the bounded supervisor projection. Causality metadata passes only in the opaque shapes described under [Cursors and gaps](live-sessions-and-readers.md#cursors-and-gaps).
- **`"max_events"`**: the Recorder also has a fixed 4 MiB byte bound.
- **`"retain_traces"`**: keeps the events of the N most recently active traces apart from the Recorder, so that they survive its eviction. `trace` reports them as retention.
- **Filters**: `"logger_level"`, `"logger_include"`, `"logger_exclude"`, `"logger_summaries"`, `"logger_summary_interval_ms"`, `"exclude_origins"`, `"otel_min_duration_ms"`, `"telemetry_min_duration_ms"`, `"telemetry_event_min_duration_ms"`, `"telemetry_summaries"`, `"telemetry_summary_interval_ms"`, and `"telemetry_duration_scopes"`. See [Filters, summaries, and views](live-digest-filters-and-trends.md#filters-summaries-and-views). The session's `start/1` and `status/1` records carry the effective values under `"filters"`.
- **Poller**: `"poller_interval_ms"` (1,000 to 60,000, default 5,000), `"top_processes"` (0 to 5, default 5), `"top_ets_tables"` (0 to 10, default 5), `"top_ports"` (0 to 10, default 5), and `"watch_processes"` (up to 16 registered names). Each needs the `"poller"` component. The session's records carry the accepted values under `"poller"` (`nil` without the poller). See [Process and ETS evidence](live-runtime-evidence.md#process-and-ets-evidence).
- **Call traces**: `"calls"` (1 to 16 functions as `"MOD.FUN/ARITY"`, required with the component), `"calls_results"` (`"exceptions"` default, `"all"`, `"none"`), `"calls_max"` (1 to 10,000, default 100), `"calls_rate_max"` (1 to 10,000, default 50), `"calls_rate_ms"` (1 to 60,000, default 1,000), and `"calls_max_bytes"` (256 to 2,048, default 1,024). See [Call traces](live-runtime-evidence.md#call-traces).
  - `"watch_writes"` (1 to 8 functions as `"MOD.FUN/ARITY"`) records each call's key. Insider merges these functions into the traced functions, so `"calls"` may then be left out. See [Changes of in-memory values](live-runtime-evidence.md#changes-of-in-memory-values).
  - Each needs the `"calls"` component, which needs OTP 28 or later. The session's records carry the accepted values under `"calls"` (`nil` without it). An amendment whose components leave `"calls"` out drops them and removes the trace.

## Environment and ownership

Live observation is allowed only in development, test, and ci. The node resolves its environment from host facts, never from a caller:

1. `config :insider, environment: :development` wins. The value is one of `:development`, `:test`, `:ci`, `:staging`, or `:production`.
2. Otherwise, a node that Mix launched (`iex -S mix`, `mix phx.server`, `mix test`) maps its Mix environment (`dev`, `test`, `ci`, `staging`, `prod`).
3. A release with neither is `unconfigured`. Any other configured value is `unrecognized`.

Insider's application starts the live owner process (internal: `Insider.Live.Owner`) only when the resolved environment is allowed. Elsewhere every call except `capabilities/0` returns `environment_denied`. The collector session's own denial of staging and production still applies underneath.

The owner checks the environment on every observation, not only at start. Host configuration can change so that the node is no longer allowed. Then the next `start/1`, `events_since/3`, `renew/1`, or `subscribe/2` call, subscription tick, or lease check stops the active session as `revoked`, through the normal cleanup path. The call returns `environment_denied` with the session's `status` record. That cleanup can fail, for example when the session Manager does not respond. Collection may then still run. The owner then marks the revocation pending and replaces the lease timer with a 1 s cleanup retry.
Until the stop succeeds, it returns `environment_denied` with `"revocation_pending" => true`. `status/1`, `stop/1`, and `unsubscribe/2` stay available, so that a caller can always see and complete cleanup.

Calls are bounded. Each call takes one of 16 owner admission slots before the owner queues its message. When no slot is free, the call returns `busy`. Each call carries an absolute deadline. The owner refuses a request that it handles after that deadline. It also refuses a request when too little time remains for the request's worst-case collector calls. Both refusals happen before any side effect. So a caller that sees `timeout` never leaves a session that it does not know about.

The owner, not the caller, owns the one collector session. A Tidewave eval process or an `:erpc` call can exit between calls, and the session keeps running. Each node has only one collector session. So a host-started `Insider.Collector.Session` and a live session exclude each other. If the owner crashes, its collector session stops through the owner-down cleanup path, and the restarted owner knows no session.

## Lease

Each session has a lease. The start option `"lease_ms"` (observer flag `--lease-ms`) sets its length. The default is 120,000 ms (2 minutes). The range is 1,000 to 900,000 ms (1 s to 15 minutes).

These calls renew the lease: `events_since/3`, `digest/2`, `baseline/2`, `trends/2`, `mark/2`, `trace/3`, `timeline/2`, `changes/2`, `mutations/2`, `amend/2`, and `renew/1`. On the observer they are `events`, `digest`, `baseline`, `trends`, `mark`, `trace`, `timeline`, `changes`, `mutations`, `amend`, and `renew`. These calls do not renew it: `status/1`, `marks/2`, `handoff_record/1`, `stop/2`, `ingest_spans/2`, and subscriptions. The observer's `watch` and `otlp-receive` renew the lease themselves every third of the lease while they run. During a long pause, call `renew`:

```sh
mix insider.live renew "${N[@]}" --session SESSION_ID
#=> {…,"result":{"lease_expires_at":"…","lease_ms":120000,"lease_remaining_ms":120000,"schema":"insider.live-lease/v1","session_id":"live-…","state":"running"},…}
```

When the lease runs out, the owner stops the session through `Insider.Collector.Session.stop/1`, the normal cleanup path. The owner keeps the ended record. `status/1` then reports `"state" => "expired"`, `"reason" => "lease_expired"`, and the cleanup `receipt`.

An ended record has one of these states, each with its reason: `stopped` (`stop_requested`), `expired` (`lease_expired`), `revoked` (`environment_denied`), or `terminated`. A `terminated` record has `session_ended`, for example after a collector crash, a direct `Insider.Collector.Session.stop/1`, or a session-root reset. It has `amend_failed` when neither an amendment's options nor the previous ones could start again.

`renew/1` and `subscribe/2` check collector health first. So they return `session_terminal` rather than renew a session that already ended. The owner retains the last eight ended records and cancels an ended session's lease timer. A `stopped` session, and one `terminated` by `amend_failed`, stays readable for a while (see [Several agents on one session](live-sessions-and-readers.md#several-agents-on-one-session)).

## Stop and check the cleanup receipt

Stop the session when you are done. `stop/2` (observer `stop`) returns the ended session's `insider.live-status/v1` record. The record holds the collector cleanup `receipt` and `readable_until`. Repeating the stop returns the same record.

```sh
mix insider.live stop "${N[@]}" --session SESSION_ID
mix insider.live stop "${N[@]}" --session SESSION_ID --reader agent-a
mix insider.live stop "${N[@]}" --session SESSION_ID --reader agent-a --force
#=> {…,"result":{"readable_until":"…","receipt":{"cleanup":{"components":{…},"logger_filter":"absent","monitors":"dropped","recorder_ets":"absent","telemetry_handler":"absent",…},"id":"sha256:…","outcome":"stopped","schema":"insider.collector-session-receipt/v1",…},"state":"stopped",…},…}
```

`stop/2` takes the optional `"reader"` and `"force"`. With `"reader"`, the owner refuses with `readers_active` while another named reader is active. A reader is active when it read within the last 30 s or is subscribed. `"force"` stops the session anyway. After the stop, the session stays readable for 120 s, until `readable_until`, so that peers can drain it.

The receipt (`insider.collector-session-receipt/v1`) has these fields:

- `session_id` and `incarnation` name the collector session.
- `outcome` is `stopped` when every cleanup check passed. It is `cleanup_incomplete` when at least one check did not pass.
- `cleanup` is the inventory of what the collector removed. Each entry says what the stop verified:
  - `components`: one status per component. `not_started`, `absent`, `already_absent`, and `absent_after_force` are clean.
  - `logger_filter` and `telemetry_handler`: `absent` is clean.
  - `recorder_ets`: `absent` or `not_started` is clean.
  - `monitors`: `dropped` is clean.
  - `call_trace` (only with the `"calls"` component): clean when `traced_after` is `0`.
  - `policy_reference` is `dropped`, `session_timers` is `none_owned`, and `manager_ownership` is `pending_manager_removal`.
- `history_count` counts the session's history entries.
- `id` is `sha256:` and the SHA-256 of the canonical receipt without `id`.

`absent` means the stop checked that the resource is gone. `residual` means the resource is still present in the node after cleanup. `unavailable` or `inspection_unavailable` means the stop could not check it.

What to do next:

- `outcome` `stopped`: cleanup is complete, and nothing of the session runs.
- `outcome` `cleanup_incomplete`: look for the `cleanup` entries that are not clean. They name what still runs or could not be checked. File it with `report --category bug` and the receipt. Restarting the target node removes any residue.
- `"receipt_pending" => true` in the record: cleanup was still in progress when the session ended. The next `status/1` fetches the receipt.

A session that you abandon stops when its lease runs out, through the same cleanup. [Collectors](../collectors.md#supervised-collector-sessions) describes the collector session's receipts in general.

## Tidewave `project_eval`

Each `project_eval` runs in a new process, and the owner keeps the session across evals. Load Insider's compiled ebin into a Phoenix development server whose dependencies already include `jason` and `telemetry`. Then start it:

```elixir
Code.prepend_path("/path/to/insider/_build/dev/lib/insider/ebin")
{:ok, _started} = Application.ensure_all_started(:insider)

Insider.Live.JSON.start(%{
  "components" => ["logger", "telemetry"],
  "telemetry_events" => [["phoenix", "endpoint", "stop"], ["my_app", "repo", "query"]],
  "telemetry_measurements" => ["duration", "total_time"]
})
```

In later evals, read with the returned id and cursor, then stop:

```elixir
Insider.Live.JSON.events_since("live-…", 0, %{"limit" => 20})
Insider.Live.JSON.stop("live-…")
```

An agent on Tidewave reads `Insider.Live.JSON.welcome()` first. It files reports with `Insider.Live.JSON.report(%{"category" => "doc_mismatch", "message" => "…"})`.

Over HTTP, each eval is one MCP `tools/call`:

```sh
curl -s http://127.0.0.1:4000/tidewave/mcp -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_eval","arguments":{"code":"Insider.Live.JSON.capabilities()"}}}'
```

## Observer node (Erlang distribution)

The Lab's `mix insider.live` task, and `insider-lab live` in the escript, drive `Insider.Live` in another BEAM node on the same machine over Erlang distribution. The agent asks the running node directly instead of reading logs, one command per question. Each command is one short-lived observer:

1. The observer refuses a target whose host is not a loopback address, this machine's own host name, or a name that resolves only to loopback addresses.
2. It reads the cookie from `--cookie-file`. The file must be a regular file with no group or other permission bits (`0600` or stricter). The observer never takes the cookie from argv or the environment and never prints it.
3. It starts a hidden, uniquely named observer node that does not listen (`hidden: true, dist_listen: false`), so that it never registers with epmd. It connects to the one target and checks that the target runs the same Insider.
4. Each call is an `:erpc` call bounded by `--timeout-ms` (default 5,000, at most 60,000). The observer prints one canonical JSON document and stops distribution again.

The observer is development tooling. It grants no authority over a staging or production node, and `--load` cannot reach one.

### Boot the target

Start the target with a short name, and give it the cookie at boot from the same file. `elixir` has no cookie-file flag, and `--cookie` would put the cookie in argv (and `ps`). So an `-e` expression sets it before Mix starts the application. Without Phoenix:

```sh
(umask 077 && openssl rand -hex 24 > ~/.my_app.cookie)
elixir --sname my_app \
  -e 'Node.set_cookie(String.to_atom(String.trim(File.read!(Path.expand("~/.my_app.cookie")))))' \
  -S mix run --no-halt
```

With Phoenix, run `-S mix phx.server` instead (or `iex --sname my_app -e '…' -S mix phx.server`). The node is named `my_app@<short host name>`. Pass that exact name to `--node`, for example `my_app@$(hostname -s)`. The target refuses a different host part as an unknown node.

For a node that you did not start, see [Load Insider into the target](#load-insider-into-the-target).

### Observe from the command line

Run every command from `tools/insider_lab` in a checkout. With the escript from Hex (`mix escript.install hex insider_lab`), run `insider-lab live` in place of `mix insider.live`, from any directory. `mix insider.live --help` (or `help`) prints the operations, the quick start, and the target flags as text and exits `0`. `mix insider.live help OPERATION`, or `OPERATION --help`, prints that operation's flags with their value syntax and examples. Neither needs a target.

```sh
N=(--node "my_app@$(hostname -s)" --cookie-file "$HOME/.my_app.cookie")
mix insider.live welcome "${N[@]}"
#=> {…,"operation":"welcome","result":{"full_reference":{…},"hash":"…","quick_start":{…},"recipes":[…],"runtime":{"active_session_id":null,…},"schema":"insider.live-welcome-quick-start/v1",…},…}
mix insider.live welcome "${N[@]}" --full      # the whole reference
mix insider.live capabilities "${N[@]}"
#=> {"installation":{"action":"none",…},"operation":"capabilities","result":{"allowed":true,"environment":"development","owner_running":true,"schema":"insider.live-capabilities/v1","welcome":{"hash":"…",…},…},"schema":"insider.live-observer/v1","status":"ok","target":"my_app@host"}
mix insider.live discover "${N[@]}" --prefix my_app
#=> {…,"result":{"events":[{"event":"my_app.checkout.stop","sources":[{"module":"MyApp.Checkout","source":"execute"}]},…],"schema":"insider.live-telemetry-discovery/v1","truncated":false,…},…}
mix insider.live start "${N[@]}" --component logger --lease-ms 300000
#=> {…,"result":{"cursor":0,"session_id":"live-…","state":"running",…},"status":"ok",…}
mix insider.live events "${N[@]}" --session SESSION_ID --cursor 0 --limit 50
#=> {…,"result":{"events":[…],"gaps":[],"next_cursor":12,"truncated":false,"truncated_by":null,…},…}
mix insider.live events "${N[@]}" --session SESSION_ID --cursor latest   # empty batch at the newest receipt: tail from its next_cursor
mix insider.live events "${N[@]}" --session SESSION_ID --cursor 0 --format compact
#=> 12 05:01:51.107 logger supervisor_child_terminated error <0.214.0> offender=Shop.Inventory restart=permanent reason=abnormal fingerprint=b1f96d655cf7
#=> # batch cursor=0 next_cursor=12 next_receipt=12 events=12 state=running disclosure=rich gaps=none filtered=logger.level:120
mix insider.live digest "${N[@]}" --session SESSION_ID                  # counts, crash loops, error signatures, latency, VM deltas
mix insider.live digest "${N[@]}" --session SESSION_ID --since latest-1000 --human   # a few plain-text lines to paste for the developer
mix insider.live trends "${N[@]}" --session SESSION_ID --human   # each summary series across its windows
mix insider.live status "${N[@]}" --session SESSION_ID   # health, readers, recorder fill; does not renew the lease
mix insider.live renew "${N[@]}" --session SESSION_ID    # renews the lease during a long pause
mix insider.live watch "${N[@]}" --session SESSION_ID --from-cursor latest --for 60s   # NDJSON until the deadline, SIGTERM, session end, or target loss
mix insider.live events "${N[@]}" --session SESSION_ID --cursor latest --reader agent-b   # join as a named reader
mix insider.live amend "${N[@]}" --session SESSION_ID --telemetry-measurement duration --reader agent-a
#=> {…,"result":{"amendment":{"changed":["telemetry_measurements"],"marker_receipt":…,"uncollected_ms":…},"schema":"insider.live-amendment/v1",…},…}
mix insider.live handoff "${N[@]}" --session SESSION_ID   # node, welcome hash, configuration, readers' cursors
mix insider.live stop "${N[@]}" --session SESSION_ID --reader agent-a   # readers_active while agent-b reads; --force stops anyway
mix insider.live report --category doc_mismatch --message 'welcome says X; observed Y'
mix insider.live reports "${N[@]}"                  # copies the target's in-node reports, then lists
mix insider.live reports submit --dry-run    # always a preview, whatever opt-in is set
mix insider.live reports submit --confirm    # files them with gh
```

### Load Insider into the target

The observer can reach a node that you did not start, if two things are true. The node must already have a name (`--sname` or `--name`). A node without a name cannot be reached: restart it with one. You must also be able to read its cookie into a file with no group or other permission bits. A node started without an explicit cookie uses `~/.erlang.cookie`.

The target may not have Insider. Each case has its own error:

- A target without Insider fails with `insider_missing`.
- A target with a different Insider version, or without `Insider.Live`, fails with `insider_version_mismatch`.
- A target with Insider loaded but not started fails with `insider_not_started`.

```sh
mix insider.live welcome "${N[@]}" --load
mix insider.live alloc "${N[@]}" --load    # also pushes recon
```

`--load` only installs. On a target without Insider, it pushes the observer's own compiled Insider application with `:code.load_binary/3` over `:erpc`. It also pushes any of Insider's runtime dependencies (`jason`, `telemetry`) that the target cannot already resolve. It loads the application spec with the target's own `:insider` configuration and starts it. Where this same build is loaded but stopped, `--load` starts it.

`--load` compares builds, not only versions. Three values identify a build (internal: `Insider.Live.Build`): the loaded `:insider` application version, the commit it was compiled from, and a SHA-256 over the MD5 of every loaded `:insider` module.

A target that runs another build (another commit, the same commit with local changes, or the same modules under another version) is reported without `--load`. `--load` never replaces Insider code. It refuses with `load_build_differs` after `insider_version_mismatch`, and when any other build is loaded on the target, started or not. A target with any Insider module loaded (`Insider` or `Insider.*`, other than the Lab's `Insider.Lab.*`) but no `:insider` spec is a partial install. It also counts as another build.

The refusal reports both builds and whether a session is active (`session_active`: `true` with `session_id`, `false`, or `"unknown"` when the owner does not answer). It also names the remedy, `--force-load`. Only `--force-load` stops, purges, and replaces a different Insider. It ends any session, and the session's evidence does not survive, even if you stop the session first. So read and save what you need (`events`, `digest`, `handoff`) before you force-load. Only an explicit force ever replaces code.

The observer refuses `--load` and `--force-load` with `load_refused` unless the target reports development, test, or ci. The target applies the rule in [Environment and ownership](#environment-and-ownership): the `:insider` `:environment` setting (including `-insider environment …` on the target's command line), then the Mix environment when `:mix` is started, else `unconfigured`.

Insider does not support two observers that install into one target at first contact at the same time. It also does not support an Insider start during a first-contact install. The result of such a race is undefined. See `decisions/2026-10-23_observer_load_only_installs_and_only_force_replaces.md`.

The `installation` object in every document (in a `watch`, its `subscribed` line) reports the Insider version and `insider_commit`, the commit this observer's Insider was built from. It reports `observer_build` and `target_build`, the two build identities. `target_build` is `null` for an Insider from before builds were identified. It reports `same_build`, with a `remedy` when it is false. It also reports the action taken (`none`, `started`, or `loaded`) and the pushed applications.

### Default session

A node has at most one active session. A command without `--session` reads the node's active session. The observer asks the target's `capabilities` for `active_session_id` once it is connected.

- With no active session, the command fails with `invalid_options` for `--session` (`problem` `missing`, `active_session_id` `null`). Start one with `start`, or name a stopped one with `--session`.
- When the live owner does not answer, the node cannot say which session is active. The command then fails with the target error `unavailable`, reason `active_session_unknown`, not with a missing `--session`. Retry, or pass `--session`.
- `stop`, `amend`, and `otlp-receive` always need `--session`.
- `report`, `reports`, and `reports submit` use `--session` only to cite or select a session.

```sh
mix insider.live digest "${N[@]}" --human    # the node's active session
```

### Observer flag reference

Every operation takes the target flags `--node NAME@HOST` and `--cookie-file PATH`, with `--timeout-ms`, `--load`, and `--force-load`. Two exceptions apply: `report` takes no target, and `reports` and `reports submit` take an optional target.

In the table, **view** stands for `--reader` and the nine view flags (see [Read flags](#read-flags)). **recording** stands for the [recording flags](#recording-flags-for-start-and-amend).

| Operation | Required | Optional |
|---|---|---|
| `welcome` | | `--full`, `--reader` |
| `capabilities` | | `--reader` |
| `discover` | | `--prefix` |
| `process` | `--name` or `--pid` | `--frames`, `--messages` |
| `bin_leak` | | `--top`, `--human` |
| `ports` | | `--type`, `--owner`, `--top` |
| `alloc` | | `--top` |
| `start` | | recording |
| `amend` | `--session` | recording, `--reader`, `--reset` |
| `events` | `--cursor` or `--since-mark` | `--session`, `--limit`, `--max-bytes`, `--scan-limit`, `--format`, view |
| `digest` | | `--session`, `--since`, `--since-mark`, `--human`, `--show-baseline`, view |
| `baseline` | | `--session`, `--since`, `--since-mark`, `--clear`, `--show`, `--human`, view |
| `trends` | | `--session`, `--since`, `--since-mark`, `--human`, `--kind`, `--windows`, view |
| `mark` | `--label` | `--session`, `--reader` |
| `marks` | | `--session`, `--human`, `--reader` |
| `status`, `handoff`, `renew` | | `--session`, `--reader` |
| `stop` | `--session` | `--reader`, `--force` |
| `watch` | | `--session`, `--from-cursor`, `--for`, `--max-events`, `--format`, view |
| `trace` | `--trace-id` | `--session`, `--limit`, `--max-bytes`, `--human`, `--collapse`, `--hide`, `--retain`, `--values`, `--values-path`, view |
| `timeline` | `--pid` or `--request-id` | `--session`, `--since-mark`, `--limit`, `--max-bytes`, `--human`, view |
| `changes` | | `--session`, `--key`, `--human`, view |
| `mutations` | | `--session`, `--id`, `--human`, view |
| `otlp-receive` | `--session` | `--port`, `--bind`, `--for` |
| `chart` | | `--session`, `--since`, `--since-mark`, `--out`, `--serve`, `--port`, `--for`, `--reader` |
| `report` | `--category`, `--message` | `--session` |
| `reports` | | `--fingerprint`, `--session` |
| `reports submit` | | `--confirm`, `--dry-run`, `--fingerprint`, `--session` |

Notes:

- **One-shot inspections**: the observer flags are the API keys with dashes. `process` takes `--name NAME` (a registered name) or `--pid PID`, and `--frames N` and `--messages N`. `bin_leak` takes `--top N`, and `--human`, which prints the holders first as plain text. `ports` takes `--type TYPE`, `--owner NAME`, and `--top N`. `alloc` takes `--top N`. See [One-shot inspections](live-runtime-evidence.md#one-shot-inspections).
- `discover` takes `--prefix a.b`. The observer splits it on dots, and only the names below it are listed.
- `welcome --full` prints the whole reference.
- `trace` and `timeline` flags are described under [OpenTelemetry spans and traces](live-otel-traces.md#opentelemetry-spans-and-traces). `changes --key` is under [Changes of in-memory values](live-runtime-evidence.md#changes-of-in-memory-values).
- `otlp-receive` listens on `--port` (default 4318) at `--bind` (default `127.0.0.1`, loopback only) for `--for DURATION`. See [Frontend traces](live-otel-traces.md#frontend-traces-otlp-http-receiver).
- `chart` writes one page to `--out PATH`, a new file (default under the system temp directory, mode 0600; a path that exists, a symlink included, is refused), and prints its path. `--serve` serves it on 127.0.0.1 instead, on `--port` (default 0, a free port) for `--for DURATION` (default 30m), and prints the URL. `--port` and `--for` need `--serve`, and `--out` refuses it. See [Pairing chart](live-sessions-and-readers.md#pairing-chart).
- `report` requires `--category` and `--message`. Its context is the last target command this observer ran: its target, operation, error code, and session, and the welcome hash and environment from the last `welcome` or `capabilities`. `--session` cites a session explicitly. `reports` and `reports submit` select reports with `--fingerprint` and `--session`. `reports submit` accepts `--confirm` and `--dry-run`. See [Agent reports](live-welcome-and-reports.md#agent-reports).
- `--reader NAME` is accepted on `welcome`, `capabilities`, `amend`, `chart`, `mark`, `marks`, `status`, `handoff`, `renew`, `stop`, and on the nine read operations. Where nothing uses the name, the observer ignores it.
- `--trace` is `--trace-id`.
- `help OPERATION` ignores the target flags that a wrapper appends.
- A flag that an operation does not take names, in `accepted_by` and `expected`, the operations that do take it.

### Recording flags for start and amend

`start` takes these flags, which set the [start options](#start-options). Every flag may appear once unless it says repeatable.

- `--component` (repeatable).
- `--telemetry-event a.b.c` (repeatable). The observer splits it on dots into the segment list. `'a.*'`, quoted, is a [prefix](live-runtime-evidence.md#telemetry-discovery).
- `--telemetry-measurement` (repeatable). It must be in the target's `telemetry_measurements_allowed`. Otherwise the observer returns the target's `invalid_options` error unchanged.
- `--max-events` (the Recorder bound) and `--lease-ms`.
- `--disclosure rich|strict`. It may ask for a stricter profile than the target's. A richer one returns the target's `disclosure_denied`.
- `--retain-traces N` (0 to 64, default 0) keeps the events of the N most recently active traces apart from the Recorder. See [Pin a trace](live-otel-traces.md#pin-a-trace).
- `--watch-write MOD.FUN/ARITY` (repeatable, 1 to 8 functions) needs the `calls` component. See [Changes of in-memory values](live-runtime-evidence.md#changes-of-in-memory-values).
- Record-time filters (see [Filters, summaries, and views](live-digest-filters-and-trends.md#filters-summaries-and-views)): `--logger-level`, `--logger-include RULE` and `--logger-exclude RULE` (repeatable), `--logger-summary RULE` (repeatable), `--logger-summary-interval-ms`, `--exclude-origin ORIGIN` (repeatable), `--telemetry-min-duration-ms`, `--telemetry-event-min-duration KIND=MS` (repeatable), `--telemetry-summary KIND` (repeatable), `--telemetry-summary-interval-ms`, and `--telemetry-duration-scope KIND=handler|caller` (repeatable, each kind once).
- `--otel-min-duration-ms` (0 to 3,600,000, default 0) needs the `otel` component. Insider does not record a span shorter than this unless its status is error.
- Poller flags (see [Process and ETS evidence](live-runtime-evidence.md#process-and-ets-evidence)): `--poller-interval-ms`, `--top-processes`, `--top-ets-tables`, `--top-ports`, and `--watch-process NAME` (repeatable).
- Call-trace flags (see [Call traces](live-runtime-evidence.md#call-traces)): `--calls MOD.FUN/ARITY` (repeatable), `--calls-results`, `--calls-max`, `--calls-rate-max`, `--calls-rate-ms`, and `--calls-max-bytes`.

A RULE is `domain:otp.sasl`, `application:oban`, or `module:Oban.Stager`. An ORIGIN is `oban`, `application:NAME`, or `module:NAME`. `--exclude-origin none`, alone, records every origin.

`amend` takes every `start` flag. Each flag given replaces that option, and a repeated flag replaces the whole list. `--reset FLAG` (repeatable) sends that option as `nil`, which returns it to its default. FLAG is a `start` flag's name without the dashes, such as `--reset watch-process`. An amendment cannot both give and reset one flag. The target validates every value.

```sh
mix insider.live start "${N[@]}" --component telemetry --telemetry-event 'my_app.*' --telemetry-min-duration-ms 0
mix insider.live start "${N[@]}" --component calls --component telemetry --watch-write 'MyApp.Flags.put/2'
mix insider.live start "${N[@]}" --component otel --component logger --otel-min-duration-ms 5 --retain-traces 8
mix insider.live amend "${N[@]}" --session SESSION_ID --reset watch-process --reset poller-interval-ms
```

### Read flags

Nine operations read a session through a reader's view: `events`, `watch`, `digest`, `baseline`, `trends`, `trace`, `timeline`, `changes`, and `mutations`. Each takes `--reader NAME` and the nine view flags. These view flags are repeatable: `--view-source`, `--view-kind`, `--view-exclude-kind`, `--view-exclude-signature`, `--view-service`, `--view-route`, and `--view-trace`. `--view-min-severity` may appear once, and `--view-clear` is a boolean.

A view narrows only your own read. See [Filters, summaries, and views](live-digest-filters-and-trends.md#filters-summaries-and-views).

Cursors and windows:

- `events` requires exactly one of `--cursor` (an integer of at least 0, or `latest`) and `--since-mark`. It accepts `--limit`, `--max-bytes`, and `--scan-limit`.
- `--since-mark` alone reads after the newest pairing mark. `--since-mark LABEL` reads after the newest mark with that label. `events`, `digest`, `baseline`, `trends`, and `timeline` take it. See [Pairing marks](live-sessions-and-readers.md#pairing-marks).
- `--since` sets the window start of `digest`, `baseline`, and `trends`. A window starts at `--since` or at `--since-mark`, not both. The values are:
  - `N`, an integer cursor: the window starts after that receipt (`0` is the session start).
  - `latest-N`: the newest N receipts (N 1 to 4,096).
  - `latest-DURATION`: a whole number of `ms`, `s`, `m`, or `h`, 1 s to 24 h. The window starts at the first event the Recorder admitted that recently, by its admission clock.
  - `mark`, or `mark:LABEL`: the newest pairing mark, or the newest with that label.
- The `--since` default is `latest-60s` for `digest`, the session start for `trends`, and `latest-5m` for `baseline`.

Other read flags:

- `--human` prints plain text instead of JSON. `digest --human` prints the digest's `"text"`. It neither carries nor delivers the welcome.
- `digest --show-baseline` lists the known-normal anomalies that the baseline hid, after the new ones in the text. See [Known-normal baseline](live-digest-filters-and-trends.md#known-normal-baseline).
- `baseline --show` prints the baseline without changing it. `--clear` removes it, and cannot go with `--show`.
- `trends` takes `--kind KIND` (repeatable) and `--windows N`. KIND is a summarised Telemetry kind, `logger_summary` for the Logger bursts, or `vm_sample`, `port_top`, `process_top`, or `process_watch` for the Poller series. See [Summary trends](live-digest-filters-and-trends.md#summary-trends).
- `watch` takes `--from-cursor N|latest` and `--max-events N`, the subscription's `"cursor"` and `"max_events"`. `--max-events` on `start` remains the Recorder bound. `--for DURATION` is a whole number of `ms`, `s`, `m`, or `h`, up to 24 hours (`500ms`, `30s`, `5m`).
- `events` and `watch` take `--format` (see [Output formats](#output-formats)).

```sh
mix insider.live digest "${N[@]}" --session SESSION_ID --since-mark 'about to click Confirm' --human
mix insider.live digest "${N[@]}" --session SESSION_ID --human --show-baseline
mix insider.live watch "${N[@]}" --session SESSION_ID --for 30s --view-kind 'phoenix.*'
mix insider.live trends "${N[@]}" --session SESSION_ID --kind shop.pricing.lookup --human
```

### Argument errors

The observer checks the arguments before any connection. It returns `invalid_options` for a repeated option, an unknown flag, or a flag the operation does not take. It also returns it for a malformed rule, `KIND=MS`, or `KIND=SCOPE`, a missing required flag, a value without its flag, or a value of the wrong type.

The error's `details` hold `option` (the flag) and `problem`: `missing`, `unknown`, `not_accepted`, `repeated`, `malformed`, `out_of_range`, `requires_node`, or `positional_argument`. They also hold `expected` and `help`, the `help OPERATION` command. `expected` is the flag's value syntax, or, for a flag the operation does not take, the flags it does take.

These argument errors never echo a value, because the value may be a secret typed into the wrong place. The same holds for `non_loopback_host`, which names `--node` and its rule. It carries no `target`, and it leaves no node in the next report's context. The observer names a malformed value only by its flag, and a positional argument not at all. It names an unknown flag only when the flag is shaped like a flag name (lowercase words joined by dashes).

The observer passes errors that the target returns through unchanged. They can name a value they reject. For example, `unknown_telemetry_event` names the event, and `unknown_process_name` names the name.

### Output formats

`events` and `watch` take `--format`:

| Format | Output |
|---|---|
| `json` (default) | The JSON document, with each event cut to what varies |
| `full` | The document exactly as the target returns it |
| `compact` | One line per event: `RECEIPT TIME SOURCE KIND SEVERITY SUBJECT key=value…` |

In `json`, an entry keeps `receipt`, `event`, and non-empty `redactions`. The event drops `schema`, `node`, `boot_id`, `clock_id`, `source_instance_id`, `source_sequence`, `monotonic_time`, and `authority`. These are the same for every event, or only order one source. It also drops `causality`, `extensions`, `payload`, `redactions`, `subject`, and `wall_time` when they are null or empty. Causality keeps only the identifiers that are set.

A `compact` line shows the wall clock in UTC to the millisecond (`-` when unknown), the emitting pid (`-` when none), and the attributes that identify what happened:

- **Telemetry event**: its `durations_us` as `NAME_us` and its other numeric measurements. In the rich profile it adds the request `method`, `path`, `route`, and `status`, `kind`, the exception module as `reason` with its first message line, and the first line of `result`. Nothing else of a rendered `Plug.Conn` shows (no body, headers, assigns, or private fields).
- **Oban job event**: `worker`, `queue`, `attempt` (`1/20`), `state`, and `args=`. In the rich profile `args=` is JSON printed as is (decoded and masked at capture, at most 200 characters). Otherwise it is `args_keys=[…]`. An Oban job's span adds its `worker`, `queue`, and `attempt`.
- **Absinthe operation stop**: it leads with what decides a GraphQL question.
  - `graphql=TYPE:NAME`. Insider names an anonymous operation by its top-level fields.
  - Its outcome: `result=… errors=… codes=[…] paths=[…] user_errors=… fields=[…]`, with counts of 0 and empty lists left out.
  - `types=[…]`, the response typenames. A `ValidationError` inside a 200 shows here.
  - In the rich profile, `args=`: its converted arguments as `path:value` leaves under each top-level field, a lone `input` left out, at most 5 leaves of 48 characters, then `+N more` (masked at capture).
  - In the rich profile, `actor=` (the `id` of the GraphQL context's `actor`, `current_user`, `user`, or `viewer`) and `client=` (the request's user agent, `graphql.client`).
  - Then its durations and `trace` id.
- **Span**: `name`, `span_kind`, `duration_us`, `status`, GraphQL outcome, and `trace` id.
- **Summary**: `count`, `errors`, `p50_us`, `p95_us`, `max_us`, and `interval_ms`.
- **Supervisor report**: `offender`, `restart`, `reason`, and fingerprint prefix. **Other Logger event**: `domain`, `mfa`, and first message line.
- **Poller event**, what it measured: `vm_sample` its key VM metrics, with `port_count` and `binary_bytes`. `process_top` the longest mailbox and the first three of each ranking as `name:value`. `ets_top` the table count, the first three tables `by_memory` and `by_size`, and Insider's own tables and bytes. `port_top` the port count, its delta, OS processes, and the first three types as `type:count(+delta)` and owners. `process_sample` and `process_watch` the process's name, mailbox, memory, status, and current function. `poll_cycle` its status and skipped probes. Any event adds its `unavailable` fields or `omitted` ranking entries.
- A text that is an HTML page, such as a debugger page, prints as `[html N bytes]`.

Each compact batch ends with a `#` line: `cursor`, `next_cursor`, `next_receipt`, `events`, `truncated_by`, `state`, `disclosure` (the profile the events crossed), `gaps`, and every non-zero `filtered` count. `watch` adds `# subscribed …` (with the session's profile) and `# stopped …` lines. Errors stay JSON. A first contact prints a `# welcome:` line that names the welcome command, instead of delivering the quick start.

A compact batch also says what its `#` line implies:

- `# lost:` when events in its range were evicted, because the Recorder was full and dropped its oldest. When the first event shown is not the one after `--cursor`, the line says which it is.
- `# more:` when a bound (`--limit`, `--max-bytes`, `--scan-limit`) cut the read. The line gives the `--cursor` to continue from and how far the bound goes. A `watch` batch prints no `# more:`, because its stream goes on by itself.
- A `watch` that stops at `--max-events`, `--for`, or an interrupt says how to continue with `watch --from-cursor N` or `events --cursor N`.
- A `trace` or `timeline` cut by `--limit` or `--max-bytes` ends with the same advice. Their `Lost:` line, like the digest's, says why events were evicted and what keeps them.

### Watch stream

`watch` subscribes the observer process. It prints a `subscribed` line, then one `batch` line per pushed batch.

- Only the `subscribed` line carries the document envelope: `schema`, `status`, `operation`, `target`, `installation`, and on a first contact `welcome`. Its `result` is the session's status. Its `subscription` is the target's `insider.live-subscription/v1` reply, whose `cursor` is where the stream starts.
- Every later line carries only `kind` and its own fields. A `batch` line carries its `result`. Each batch's `cursor` is the previous batch's `next_cursor`.
- The final `stopped` line carries its `reason`, `events` (how many it printed), and `next_cursor`. A later `watch --from-cursor` or `events --cursor` resumes there without a gap.

A subscription does not renew the lease, so `watch` renews it every third of the lease. `watch` ends with the `stopped` line and exit `0` when `--for` elapses (`reason` `duration`), or when it printed `--max-events` events (`max_events`, and the target sends no more than that). It also ends so on SIGTERM (`interrupted`), for example `timeout 10 mix insider.live watch …` or `kill`. It ends so after the last batch when the session stops, expires, or terminates (`session_ended`, with its `state`).

When the target goes away, `watch` ends with a `target_down` error line and exit `1`. It unsubscribes on the way out. The observer can also be killed outright (`kill -9`, or Ctrl-C at the BREAK prompt). The owner's monitor then drops the subscriber when the connection closes.

```sh
mix insider.live watch "${N[@]}" --session SESSION_ID --from-cursor latest --for 60s --format compact
```

### Several agents at once: the escript

Every `mix insider.live` command first runs `mix compile`, which takes Mix's build lock. So concurrent commands from one checkout wait for each other ("Waiting for lock on the build directory"). Mix prints its Compiling and lock notices on stderr. Parse stdout alone, because stdout carries only the JSON.

The Lab escript needs no Mix at run time. Install it from Hex with `mix escript.install hex insider_lab` and run `insider-lab live`, or build it once in `tools/insider_lab` of a checkout and run `./insider-lab live`. Both take the same operations, flags, and output. Concurrent escript calls do not wait for each other.

```sh
mix escript.install hex insider_lab   # from Hex, once
insider-lab live status "${N[@]}" --session SESSION_ID
mix escript.build                     # or in tools/insider_lab of a checkout
./insider-lab live events "${N[@]}" --session SESSION_ID --cursor latest --reader agent-b
```

The escript keeps the Insider it was built with. `installation.insider_commit` in every document names that commit. Compare it with the welcome's `insider.commit`, and build again after the checkout changes. An escript installed from Hex reports no commit: compare `insider_version`, and install again to update. `--load` pushes the escript's own Insider.

### Exit statuses and error codes

Every document carries `schema` and `status`. In a `watch`, this holds for the `subscribed` line and any error line. The schema is `insider.live-observer/v1`, or `insider.live-observer-error/v1` for a failure. A target error keeps the target's own `insider.live-error/v1` map, marked `"source": "target"`. Observer errors are marked `"source": "observer"`. They use this closed vocabulary, with the Lab CLI exit statuses:

| Exit | Status | Codes |
|---|---|---|
| `0` | `ok` | none |
| `1` | `error` | any target error, `target_not_found`, `distribution_unavailable`, `connection_failed`, `target_down`, `remote_exception`, `unexpected_response`, `load_failed`, `report_queue_unavailable`, `report_submit_failed`, `port_unavailable` |
| `3` | `unsupported` | `insider_missing`, `insider_version_mismatch`, `insider_not_started`, `load_refused`, `load_build_differs` |
| `64` | `invalid_input` | `usage`, `invalid_options`, `invalid_node`, `non_loopback_host`, `non_loopback_bind`, `cookie_file_unreadable`, `cookie_file_permissions`, `cookie_file_invalid` |
| `70` | `catastrophic` | `observer_failed`, or stdout could not be written |
| `124` | `timeout` | `connect_timeout`, `rpc_timeout` |

The message of each observer error code:

- `usage`: "usage: mix insider.live OPERATION [--node NAME@HOST --cookie-file PATH] [OPTIONS]; mix insider.live --help lists the operations, help OPERATION shows one"
- `invalid_options`: "an option is missing, unknown, repeated, malformed or out of range; details name the option and its expected value"
- `invalid_node`: "--node must be NAME@HOST"
- `non_loopback_host`: "the target host is not loopback or this machine"
- `non_loopback_bind`: "--bind must be a loopback address such as 127.0.0.1 or ::1"
- `cookie_file_unreadable`: "the cookie file is missing or not a regular file"
- `cookie_file_permissions`: "the cookie file must be readable by its owner only"
- `cookie_file_invalid`: "the cookie file does not contain one printable cookie"
- `target_not_found`: "no node with that name is registered on the host"
- `distribution_unavailable`: "this VM cannot start a hidden observer node"
- `connection_failed`: "the target refused the connection (wrong cookie, or the host part differs from the node's own name)"
- `connect_timeout`: "connecting to the target timed out"
- `rpc_timeout`: "a remote call timed out"
- `target_down`: "the connection to the target was lost"
- `remote_exception`: "a remote call failed in the target". It names only the exception module and the called function. It echoes no remote value.
- `unexpected_response`: "the target returned a value outside the live contract"
- `insider_missing`: "the target does not have Insider loaded; --load pushes it"
- `insider_version_mismatch`: the target runs a different Insider. `--load` never replaces it. Pass `--force-load`, which replaces it and ends any session.
- `insider_not_started`: Insider is loaded but not started. `--load` starts it when it is this observer's build, and refuses another build (`load_build_differs`).
- `load_refused`: "--load is allowed only on development, test or ci targets"
- `load_build_differs`: the target has another Insider build loaded, and `--load` never replaces Insider code. Pass `--force-load`, which replaces it and ends any session.
- `load_failed`: "loading or starting Insider in the target failed"
- `report_queue_unavailable`: "the observer's local report queue could not be read or written"
- `report_submit_failed`: "gh failed for at least one report; see results for which were filed"
- `port_unavailable`: "the receiver could not listen on that port; it may be in use"
- `observer_failed`: "the observer failed unexpectedly"

The messages of `insider_version_mismatch`, `insider_not_started`, and `load_build_differs` also warn that a session's evidence does not survive `--force-load`. Read and save what you need (events, digest, handoff) before you force-load. See [Load Insider into the target](#load-insider-into-the-target).

The full welcome lists the same codes, statuses, exit codes, and messages under `errors.observer`. The observer's and the target's malformed-option code share one name, `invalid_options`. `source` and the exit status tell them apart.

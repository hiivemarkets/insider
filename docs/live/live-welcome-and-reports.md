# Insider Live: welcome, reports and error codes

[Index](../README.md) · [Glossary](../glossary.md) · [Cheat sheet](../cheat-sheet.md)

The generated welcome document an agent reads first, the reports an agent files about Insider
itself, and the closed error-code vocabulary.

## Contents

- [Welcome document](#welcome-document)
  - [Get the welcome](#get-the-welcome)
  - [Quick start](#quick-start)
- [Welcome recipes](#welcome-recipes)
- [Welcome full reference](#welcome-full-reference)
- [Welcome hash and delivery](#welcome-hash-and-delivery)
  - [Drift guard](#drift-guard)
- [Agent reports](#agent-reports)
  - [File a report](#file-a-report)
  - [Report queue in the node](#report-queue-in-the-node)
  - [Report queue on the observer](#report-queue-on-the-observer)
  - [Submit reports upstream](#submit-reports-upstream)
  - [Report context and groups](#report-context-and-groups)
- [Error codes](#error-codes)

## Welcome document

`Insider.Live.welcome/1` returns the runtime form of an `AGENTS.md` for this node.
`Insider.Live.JSON.welcome/1` and `mix insider.live welcome` on the observer return the same
document. Insider generates it from the tables that the code itself uses. So it cannot describe an
option, default, bound, or error code that the node does not have.

### Get the welcome

```bash
mix insider.live welcome "${N[@]}"
mix insider.live welcome "${N[@]}" --load
mix insider.live welcome "${N[@]}" --full
```

The document has two forms. Each form has its own schema, so a reader tells them apart by `schema`
alone:

| Form | `schema` | How to get it |
|---|---|---|
| Quick start (default) | `insider.live-welcome-quick-start/v1` | `welcome()`, `mix insider.live welcome "${N[@]}"` |
| Full reference | `insider.live-welcome/v2` | `welcome(%{"full" => true})`, `mix insider.live welcome "${N[@]}" --full` |

The full reference is version 2, because version 1 was what the default `welcome` returned. A reader
of `insider.live-welcome/v1` that calls the default now gets a document with a different schema. It
does not get a document with missing fields.

### Quick start

The quick start is small enough to read in one go. It holds these keys:

- `quick_start`: `setup` (`N=(--node NAME@HOST --cookie-file PATH)`), ten numbered `steps`, the six
  core `commands`, and `load`, the first-contact command. The core commands are `start`, `digest`,
  `events`, `watch`, `stop`, and `report`, with real flags. The steps say, in order:
  - where to run, and the escript for several agents.
  - `--load` on first contact.
  - the one-session rule, and joining from `latest`.
  - the quiet defaults. Recording options apply to every reader, and a view is your own.
  - "measurements are opt-in" in the strict profile. The rich profile returns every measurement
    unless `--telemetry-measurement` selects some.
  - the act-then-digest-then-read loop (`--format compact` for one line per event).
  - pairing with a programmer (`mark`, then read with `--since-mark`).
  - `filtered` and `gaps`.
  - how to stop, with the stop protection and the drain window.
  - the report duty.
- `recipes`: see [Welcome recipes](#welcome-recipes).
- `tandem`: how several agents share a session. It holds the escript (`build`, `run`, and
  `freshness`), the `scope` of recording options and views, the steps (named readers, joining,
  protected stop, drain window, amend, handoff), and their commands.
- `pairs_with`: the tools to use beside Insider. Each has `use_for` (when to use it), `detect` (how
  an agent tells it is there), `run` (how to run it), and `for_agents`. The tools are these:
  - Credo: static style and code-shape rules.
  - Argus: a static analysis tool for compiled beams.
  - recon: live process, memory, allocator, and port inspection beyond Insider's bounded reads.
  - Tidewave: evaluating code and reading logs in the dev node.
  - observer_cli: a terminal UI for a human, not for agents.

  `mix insider.live --help` prints the same list.
- `full_reference`: the full reference's `schema`, how to read it, and `help`. You read it with
  `mix insider.live welcome "${N[@]}" --full`, `Insider.Live.welcome(%{"full" => true})`, or the
  JSON twin.
- `effective_disclosure`: the profile that this node discloses with now. It holds `profile` (`rich`
  or `strict`) and its `source`, `means` (one sentence on what the profile lets leave the node), and
  where its rules are. Both forms carry it. Like `runtime`, it is outside the hash.
- `summary`, `insider`, `hash`, `hash_covers`, and `runtime`, as in the full reference. `hash` is
  the full reference's hash, and `hash_covers` says so.

## Welcome recipes

`recipes` gives, for each symptom, the commands to run and what to read. The symptom recipes read
with `digest` before `events`. The welcome has these 20 recipes, in this order:

1. **triage**: what is wrong right now. Run `digest`, and `digest --human` for the developer.
   See [Digest](live-digest-filters-and-trends.md#digest).
2. **latency**: requests, jobs, or calls are slow. Read the summaries of the slow operation's stop
   event: `count`, `errors`, `duration_p50_us`, `duration_p95_us`, `duration_max_us`, the
   exemplars to open, `exemplars_lost`, `first_error_retained`, and the `duration_scope` declared
   with `--telemetry-duration-scope`. Then read the digest's `latency` table and `trends`. See
   [Filters, summaries, and views](live-digest-filters-and-trends.md#filters-summaries-and-views).
3. **log flood**: the same error is logged over and over. Read the `--logger-summary` bursts per
   message template and call site, the 64-key overflow row, and the gaps `logger_exemplar_lost`
   and `logger_summary_overflow`. See
   [Filters, summaries, and views](live-digest-filters-and-trends.md#filters-summaries-and-views).
4. **crash loop**: a process keeps restarting. Read the digest's `crash_loops`, and the
   `supervisor_child_terminated` events: `offender_id`, `restart_type`, `reason_fingerprint`, and
   the period between `wall_time`s. See [Digest](live-digest-filters-and-trends.md#digest).
5. **lost events**: the digest says `Lost: evicted`. See
   [Cursors and gaps](live-sessions-and-readers.md#cursors-and-gaps).
6. **5xx**: requests fail with a server error. Read `phoenix.endpoint.stop`,
   `phoenix.router_dispatch.exception`, and `otel.span` with `--view-min-severity error`, which
   keeps the failing requests. Then run `trace` with a failing event's trace id. See
   [Read one request as a trace](live-otel-traces.md#read-one-request-as-a-trace).
7. **GraphQL error in a 200**: the response is HTTP 200, but the operation failed or its payload
   reports validation errors. See [GraphQL outcome](live-otel-traces.md#graphql-outcome).
8. **slow request**: one request takes too long, and you need to know where. Read the digest's
   `latency`, then the request's `trace`. Its span durations and depths show where the time went.
   Or read its `timeline` by request id. See
   [Timeline of a process or request](live-otel-traces.md#timeline-of-a-process-or-request).
9. **app hangs**: pages stall for seconds now and then, but each request looks fast. See
   [Request waits and bursts](live-otel-traces.md#request-waits-and-bursts).
10. **follow a frontend action**: one page load or form submit, from the Next.js server into this
    node. Run `otlp-receive`, then the action's `trace`. See
    [Frontend traces](live-otel-traces.md#frontend-traces-otlp-http-receiver).
11. **growing mailbox**: slower the longer it runs, and calls time out. Read the digest's
    `processes`, then `process_top`, then run `amend --watch-process`. See
    [Process and ETS evidence](live-runtime-evidence.md#process-and-ets-evidence).
12. **memory growth**: `ets_bytes` or process memory keeps rising. Read the digest's `vm`, then
    `vm_sample`, `ets_top`, and `process_top`, with Insider's own footprint apart. See
    [Process and ETS evidence](live-runtime-evidence.md#process-and-ets-evidence).
13. **binary leak**: binary memory keeps rising, and a process holds large binaries. See
    [One-shot inspections](live-runtime-evidence.md#one-shot-inspections).
14. **port leak**: `port_count` or OS processes keep rising. See
    [One-shot inspections](live-runtime-evidence.md#one-shot-inspections).
15. **growth over time**: ports, binary memory, or a mailbox keep rising, and you need the rate.
    See [Summary trends](live-digest-filters-and-trends.md#summary-trends).
16. **missing values**: events lack a measurement, an event, or log lines that you need. `amend`
    the running session instead of restarting it, then read the `live.session_amended` event. See
    [Live observation](live-api-and-transports.md#live-observation).
17. **several agents**: another agent runs or reads the session. Join with `--reader`, read
    `status` readers, and use `handoff`. See
    [Several agents on one session](live-sessions-and-readers.md#several-agents-on-one-session).
18. **pairing**: the programmer clicks in the app while you watch. See
    [Pairing marks](live-sessions-and-readers.md#pairing-marks).
19. **unknown event names**: you do not know which Telemetry events the node emits. Run
    `discover`, then `--telemetry-event 'PREFIX.*'`, then read `status` for
    `telemetry_subscriptions`. See [Telemetry discovery](live-runtime-evidence.md#telemetry-discovery).
20. **failing call**: why does this call fail, and with what arguments. See
    [Call traces](live-runtime-evidence.md#call-traces).

## Welcome full reference

`welcome(%{"full" => true})` is the full reference. It also holds `quick_start`, `recipes`, and
`tandem`, and these keys:

- `operations`: every `Insider.Live` function with its `Insider.Live.JSON` twin, the observer
  command that performs it, the option group it takes, and whether it renews the lease.
- `options`: the options of each operation that takes some, such as `start`, `read`, `subscribe`,
  `digest`, `trends`, `report`, and `welcome`. Each option has its type, default, bounds, and
  allowed values. It also holds `components`, `telemetry_measurements_allowed`, and `bounds`.
- `errors`: the closed error-code vocabulary with each code's message. Under `observer`, it holds
  the observer's own codes, each with its status, exit code, and message, and the exit status table.
- `transports`: the observer's commands (each with a summary and examples), flags, and example
  invocations. Under `options`, it holds every observer flag's value syntax (such as `module:NAME`
  for `--logger-include`), the `Insider.Live` option that the flag sets, and whether it repeats. It
  also holds the `help` commands and the Tidewave `project_eval` setup and examples.
- `guide`: what to do first, the act-then-read loop, and how to stop. It states the duty to report
  Insider bugs and every behaviour that differs from the document, with the exact report commands.
- `reports`: the report categories and bounds.
- `disclosure`: the disclosure contract. It holds the profiles, the host setting and its
  per-environment defaults, and the caller's narrow-only option. It also holds the strict boundary,
  the selection and masking policy ids, the masking reasons, the rich rendering bounds, and the
  rules per profile.
- `costs`: what a session costs the node.
- `filters`: the in-node filters. It holds the filter options, the quiet defaults, the filter order,
  summaries, and the `filtered` batch field.
- `severity`: how each source sets an event's severity, with the Telemetry failure rule row by row.
  See [Event severity](live-digest-filters-and-trends.md#event-severity).
- `time`: what `wall_time` and `monotonic_time` mean for each source, and the unit of every
  duration. See [Event time and units](live-sessions-and-readers.md#event-time-and-units).
- `insider`: the version, and the Git commit `HEAD` named when Insider was compiled. Insider reads
  the commit from the checkout's `.git` files. It is `nil` outside an Insider checkout. It does not
  show uncommitted changes.
- `runtime`: the node, its environment, whether the owner runs, the active session id, and this
  node's quiet default Telemetry events (`quiet_default_telemetry_events`). It holds the host's
  current disclosure profile (`disclosure_profile`, `disclosure_profile_source`,
  `disclosure_profiles`, `masking_policy_id`). It also holds `pairs_with_available`. See below.

`pairs_with_available` says, for each `pairs_with` tool, whether this node has it. A tool is there
when its module is already loaded, including one that `--load` pushed from a binary, such as recon.
A tool is also there when its beam is on the code path. Insider looks the beam up and never loads
it. For Argus, the tool is there when an executable is on the node's PATH. Insider never runs it.
The node's PATH can differ from the agent's shell.

## Welcome hash and delivery

`hash` is the SHA-256 of the canonical JSON (sorted keys, no whitespace) of every key of the full
reference except three. The excluded keys are `hash`, `runtime`, and `effective_disclosure` (the
node's current profile, a runtime fact). So the hash changes exactly when what the document promises
changes. That includes the host's measurement allowlist and report-submission setting. It never
changes with the node's runtime state or disclosure setting. The quick start carries the same hash.
`capabilities/0` carries it under `welcome`, so an agent that skipped the document learns of it.

The observer also delivers the quick start without being asked. The first command run against a
target node (any operation) carries it under a top-level `"welcome"` key inside its one JSON
document. Later commands carry a pointer to it: `schema`, `delivered`, `hash`, `read_with`, and
`full_reference`. `schema` is the quick start's schema, which `read_with` returns.
`full_reference.schema` is the full reference's schema. Printing `welcome`, with or without
`--full`, counts as delivery.

The observer records delivery per target node incarnation: its name and its distribution creation.
The creation changes when the node restarts. The record is in the observer's reports directory,
which every observer on the machine shares. The observer ignores a record without the creation, from
an earlier observer.

### Drift guard

Tests keep the document equal to the code. A test fails in these cases:

- An exported operation, an option, a default, a bound, an error code that the code can return, an
  observer command, or an observer flag is missing from the document.
- The document lists one that the code does not have.
- A quick start, recipe, or example command does not parse with the observer's own parser.

## Agent reports

Agents report Insider's own bugs and every difference between the welcome document and observed
behaviour. This works like a coding agent's issue-report channel.

### File a report

```bash
mix insider.live report --category doc_mismatch --message 'welcome says X; observed Y'
mix insider.live report --session SESSION_ID --category bug --message 'expected X; observed Y'
mix insider.live reports "${N[@]}"
mix insider.live reports submit --dry-run --session SESSION_ID
```

`report/1` takes `"category"` and `"message"`. The category is `bug`, `doc_mismatch`,
`missing_capability`, or `confusing_output`. The message is at most 2,048 bytes of UTF-8, without
control characters other than newline and tab.

Insider adds the context itself: `transport`, `insider_version`, `insider_commit`, `welcome_hash`,
`node`, `environment`, `last_operation`, `last_error_code`, `last_local_operation`, and
`last_local_error_code`. It never adds event payloads, option values, or error details.

- `last_operation` and `last_error_code` are the last call to the target. In the node, they are the
  last `Insider.Live` call.
- The `last_local_*` keys are the observer's last failure that reached no target, such as a `usage`
  error or a report-queue failure. They hold the operation that the command named, or `nil` when it
  named none. In the node, they are `nil`.
- The observer reads records written before these two keys existed with the keys as `nil`.

A report's fingerprint is the SHA-256 prefix of its category and its message, with case and
whitespace runs normalised. Reports stay on the machine until the developer sends them.

### Report queue in the node

In the node, Insider keeps a bounded queue in memory (internal: `Insider.Live.Reports`). It holds
100 reports and evicts the oldest first. A repeated fingerprint increments `count` instead of adding
a record. Production code may not write files, so the queue does not survive a node restart.

The queue starts beside the owner only where live observation is allowed. Elsewhere, `report/1` and
`reports/0` return `environment_denied`. Requests follow the owner's discipline. A request takes one
of 8 admission slots or gets `busy`. It has an absolute deadline. The queue refuses a queued request
after its deadline, before the request changes the queue. So a caller that saw `timeout` left no
report behind. The last operation and error code are one overwritten in-memory row, so tracking a
call never queues work.

### Report queue on the observer

The observer keeps the same bounded, deduplicated queue as JSONL in its reports directory, with
files of mode `0600`. The directory also holds the last target command's context and last local
failure, the ledger of submitted fingerprints, import watermarks, and the targets whose welcome the
observer delivered.

The directory is `INSIDER_LIVE_REPORTS_DIR` when it is set. Otherwise it is `insider-live` in the
user's durable state directory:

- `~/Library/Application Support` on macOS.
- `$XDG_STATE_HOME` (else `~/.local/state`) on other Unix systems.
- The local application data directory on Windows.

Pre-release observer builds kept the queue in the system temporary directory
(`$TMPDIR/insider-live`, from `System.tmp_dir!/0`). The observer does not carry over or read those
reports. To look at them, open `observer-reports.jsonl` there by hand.

The observer validates each row on read: record fields, fingerprint, canonical timestamps, bounded
context strings, and ledger and watermark shapes. It counts invalid rows in `invalid_lines` and
never lists or submits them. The ledger keeps an entry only while its fingerprint is queued (at most
100). A report that returns after eviction is linked to its existing issue by the upstream
fingerprint search.

`mix insider.live reports "${N[@]}"` copies a node's queue into the observer's queue. It adds only
the occurrences counted since the last import from that node. Each change takes a lock file in the
directory. A submission holds its own lock throughout, so concurrent observers cannot file a
fingerprint twice. The observer reports a lock left by a killed observer with its path
(`report_queue_unavailable`, reason `locked`). It never breaks the lock automatically.

### Submit reports upstream

```bash
mix insider.live reports submit --dry-run
mix insider.live reports submit --confirm --fingerprint 0123456789abcdef
```

`mix insider.live reports submit` files one GitHub issue per unsubmitted fingerprint on
`hiivemarkets/insider` through `gh`. It first searches for an existing issue with the same
fingerprint. It submits only with `--confirm`, or when the host sets `config :insider,
:live_report_submission, :github`.

- The observer's own setting, like `--confirm`, covers every queued report.
- A target's setting (with `--node`) covers only reports whose every source is that target. Reports
  filed locally, imported from any other node, or kept from the first queue format (source
  `unknown`) stay pending. The result counts them as `not_authorized`.
- Without an opt-in, or with `--dry-run`, it prints each issue it would create and runs nothing.
  `--dry-run` overrides every opt-in, including `--confirm`.

Its result's `authorization` names the `effective` opt-in (`dry_run` for a preview), its `target`,
every opt-in present (`opt_ins`), and `overridden_by` (`--dry-run` when it overrode one). A real
submission first writes that authorization to standard error as one `insider.live-authorization/v1`
JSON line, with `will_submit`. It does this before its first `gh` call.

`--fingerprint` (repeatable) and `--session` select the reports that it covers.
`selection.unmatched_fingerprints` lists any fingerprint that is not queued. The issue body carries
the node's name without its host part.

### Report context and groups

Every observer run on the machine shares the queue. A report's context cites a `session`. It is the
`report --session ID` value when given. Otherwise it is the session of the last target command. The
observer carries that session across commands against the same target, and `start` sets it.

A duplicate keeps only the newest context. So each queued report also carries `occurrences`: how
many times each `node` and `session` reported it. It keeps at most 16, least recently reported
first, and `count` stays the total.

`reports` adds `groups`, one per node and session that the occurrences cite, with its `fingerprints`
and `count`. It takes the same `--fingerprint` and `--session` selection. A session selection
matches any occurrence and adds `selected_count`. `reports submit` still files one issue per
fingerprint, with the total count.

## Error codes

Every error is `%{"schema" => "insider.live-error/v1", "code" => code, "message" => text}` plus
code-specific detail keys. The codes are a closed set:

| Code | Meaning |
|---|---|
| `environment_denied` | The node is not in development, test, or ci now, or a revocation is still cleaning up. Carries `environment`, `environment_source`, and `allowed`. See below. |
| `disclosure_denied` | `start/1` asked for a profile richer than the host's, or `trace/3` asked for `values` under strict. See below. |
| `invalid_options` | An option or request is malformed, unknown, or out of bounds. Carries `field`. See below. |
| `component_unavailable` | A requested component cannot run on this node. Carries `component` and `reason`. See below. |
| `untraceable_function` | A `"calls"` function cannot be traced. Carries `function` and `reason`: `unknown_atom`, `not_loaded`, `not_found`, or `protected`. |
| `unknown_telemetry_event` | A Telemetry event segment is not an existing atom, or a prefix entry matches no discovered event. Carries `event`, and for a prefix also `discovered` (`0`) and `complete`. |
| `unknown_process_name` | A `"watch_processes"` name, or an inspection's `"name"` or `"owner"`, is not an existing atom. So no process can be registered under it. Carries `name`. |
| `process_not_found` | No process is registered under the inspection's name, or its pid is not a live local process. Carries `name` or `pid`. |
| `protected_process` | `process/1` named a process that the host or the fixed OTP inventory protects. Insider never reads it. Carries `pid`. |
| `session_already_active` | A session is already active. Carries `active_session_id`, or `nil` when a host-owned collector session holds the slot. |
| `start_failed` | The collector session failed to start and left no session. Carries the startup `receipt` when one exists. See below. |
| `unknown_session` | No active or retained session has this id. |
| `readers_active` | `stop/2` refused, because another named reader read within `reader_active_ms` or is subscribed. See below. |
| `amend_failed` | The amended options could not start. Carries `rolled_back`: `true` with the `amendment` when the previous options run again, `false` with the ended session's `status` otherwise. |
| `session_terminal` | The session has ended. Carries its `status` record with the receipt. |
| `mark_not_found` | A read since a pairing mark found none: the session has no mark, or none with that label. Carries `label`, `marks` (how many the session keeps), and `labels` (the newest labels). |
| `invalid_cursor` | The cursor is not an integer of at least 0 or `"latest"`, or it is beyond the newest receipt. See below. |
| `invalid_subscriber` | The subscriber is not a pid. |
| `subscriber_limit` | The session already has four subscribers. |
| `busy` | An admission bound is full. Nothing was queued. See below. |
| `timeout` | The call exceeded its time bound. See below. |
| `unavailable` | The Insider application or the live owner is not running, or the session could not be read. See below. |

**`environment_denied`.** When the call revoked a session, it also carries the revoked session's
`status` record. While Insider retries the cleanup, it carries `"revocation_pending" => true`.

**`start_failed`.** The receipt's `outcome` is `startup_failed`, and `cleanup.startup` says why. A
start that ran past its budget (1 s, or less when the call's own deadline is earlier) has `timeout`,
with `start_budget_ms` and `start_elapsed_ms`. The start can be retried. Until Insider has removed
the timed-out start, a retry can return `session_already_active`.

**`disclosure_denied`.** Insider returns it in two cases:

- `start/1` asked for a disclosure profile richer than the host's. It carries `requested` and the
  host's `disclosure_profile`.
- `trace/3` asked for `values` while the session's profile is strict. It carries `field` (`values`),
  `required` (`rich`), `disclosure_profile`, and a `hint` to start a session with `--disclosure
  rich` where the host allows it.

**`invalid_options`.** For `report/1`, `field` is `category` or `message`. A start whose prefixes
expand past the event bound also carries `expanded` and `max`. Through the observer, it also carries
`option` (the flag that set the field) and `expected` (that flag's value syntax). For a view, it
carries `options` and `expected` per view flag.

**`component_unavailable`.** Each `component` and `reason` pair:

| `component` | `reason` | When |
|---|---|---|
| `calls` | `requires_otp_28` | `start/1` with the calls component on OTP 27 |
| `otel` | `opentelemetry_sdk_absent` | `start/1` with the otel component when the OpenTelemetry SDK is absent |
| `otel` | `requires_otp_28` | `start/1` with the otel component on OTP 27 |
| `otel` | `component_not_running` | `ingest_spans/2` on a session started without the otel component |
| `recon` | `not_loaded` | `alloc/1` when recon is not loaded |

**`readers_active`.** It carries `readers` (each with `name`, `cursor`, `last_seen_ms_ago`,
`last_seen_at`, and `subscribed`), `unnamed_subscribers`, `reader_active_ms`, `retry_after_ms`
(`nil` while a reader is subscribed), and `stopped_readable_ms`. `"force" => true` stops the session
anyway.

**`invalid_cursor`.** It carries `oldest_receipt` (the oldest retained receipt, `nil` when none is
retained) and `next_receipt` (the newest receipt, the largest valid cursor). Both are `nil` when
Insider could not read the session within the call's budget.

**`busy`.** Insider returns it in these cases:

- All 16 owner admission slots are taken.
- The collector session's own admission bound is full.
- On `start/1`, all 8 record-time gates are held. A record-time gate is a session's filter that
  decides each event when it is emitted.
- On `discover/1`, or `start/1` with a prefix, two discoveries already run.
- On an inspection, two inspections already run.

**`timeout`.** The owner refuses a request before any side effect when it handles the request after
its deadline, or without the reserve its work needs. For `ingest_spans/2`, the outcome is
**unknown**. The otel collector can have taken the spans and be recording them when the call stops
waiting. So some, all, or none of them can be recorded. A retry of the same spans skips a span only
while its span id is among the last 16,384 that the session's otel collector recorded from an
ingest. `seen_evicted` counts the ids it has forgotten. Insider records a retry of a forgotten span
again. Dedupe does not work across an amendment, which resets it.

**`unavailable`.** Insider also returns it in these cases:

- For `report/1` and `reports/0`: the report queue is not running.
- For `discover/1`: the discovery worker failed, for example over its heap guard.
- For an inspection: its worker failed. With `reason` `result_bytes`, its fixed fields alone
  exceeded the result bound.

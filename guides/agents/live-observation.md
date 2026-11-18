# Live observation for agents

`Insider.Live` lets you watch a running development, test, or CI node while
it keeps running: one bounded, leased session per node records Logger,
Telemetry, and Poller evidence, and you read it after a cursor. This page is
the operating contract. The authoritative, always-current version is the
**welcome document** the node itself returns; read it first.

## Read the welcome first

The welcome document is generated from the code the node runs. By default
it is an agent quick start (`insider.live-welcome-quick-start/v1`): the steps
in order, the six core observer commands with real flags, `--load` for first
contact, symptom recipes (triage, latency, crash loop, 5xx, growing mailbox,
memory growth, missing values, several agents, and unknown event names),
`tandem` for sharing a session, and `runtime`: the node, its
environment, the active
session, and its quiet default Telemetry events. The full reference
(`insider.live-welcome/v2`; `--full`, or
`%{"full" => true}`) adds every operation with its options, defaults, and
bounds, every error code of the node and the observer, the observer's value
syntax for every flag (such as `module:NAME`), both transports with example
invocations, and a longer guide.

- Observer node: first contact is
  `insider-lab live capabilities --node NAME@HOST --cookie-file PATH --load`
  after `mix escript.install hex insider_lab`, or the same operation with
  `mix insider.live` from `tools/insider_lab` in a checkout. `--load` loads
  Insider into a node without it. Until then, `welcome` returns
  `insider_missing`. Then run `welcome` with the same `--node` and
  `--cookie-file`, and add `--full` for the full reference. The first
  command run against a target node,
  whatever it is, also carries the quick start under `"welcome"`; later ones
  carry a pointer. `mix insider.live --help` and `help OPERATION` print the
  flags with their value syntax and examples, without a target.
- Parse stdout alone. It carries only the observer's documents; Mix prints
  its `Compiling` and `Waiting for lock on the build directory` notices
  (several `mix` commands in one checkout share that lock) on stderr. If
  your tool merges the two streams, or several agents share the checkout,
  run the escript instead (`insider-lab live …` from Hex, or
  `mix escript.build` once in the checkout, then `./insider-lab live …`): it
  starts no Mix, so neither notice appears.
- Tidewave: `project_eval` with `Insider.Live.JSON.welcome()`, or
  `Insider.Live.JSON.welcome(%{"full" => true})`.
- `capabilities` carries `welcome.hash` and the same commands, so you learn
  about the document even if you skipped it.

`hash` is the SHA-256 of the canonical JSON of every key of the full
reference except `hash` and `runtime`; the quick start carries the same
hash. It changes exactly when what the document promises changes. Keep it;
if `capabilities` later reports another hash, read the welcome again.

## Act, then read

1. Check `runtime.allowed`. If `runtime.active_session_id` is set, a session
   is already running; only one exists per node.
2. `start` with the fewest components that can show the effect. Without
   options a session is quiet: Logger warnings and worse, OTP reports, slow
   or failed queries, every request, nothing from Oban's own machinery (the
   welcome's `filters.quiet_defaults`; this node's default events are in
   `runtime.quiet_default_telemetry_events`). Widen it with the filter
   options, for example `logger_level` `debug` or
   `telemetry_min_duration_ms` `0`. Do not guess Telemetry event names:
   `discover` (`--prefix my_app`) lists the names the node can emit, with
   each name's source and module, and `--telemetry-event 'my_app.*'`
   subscribes to every discovered name below the prefix. `status` then
   reports `telemetry_subscriptions`: `subscribed` with `seen` 0 means the
   event was not emitted.
3. Act: send the request, run the job, or ask the developer to use the app.
   Pairing with a developer who clicks in the app: `mark` the moment first
   (`--label 'about to click Confirm'`), ask them to act, then read since the
   mark (`digest --since-mark --human`, `events --since-mark`): no time or
   cursor to guess.
4. `digest` the session first: counts by kind, severity, and offender, crash
   loops with their period, the top error signatures, latency tables, the
   longest mailboxes, and VM deltas in one call (`digest --human` prints a
   few lines to paste for the developer). Then read `events_since` from your
   cursor for detail (the observer's `--format compact` prints one line per
   event) and keep `next_cursor`. A non-empty
   `gaps` list means evidence was lost and says how much; `truncated` means
   more events are waiting, and `truncated_by` says which bound ended the
   read (`limit` and `max_bytes` count only events you are shown;
   `scan_limit` means a sparse view used its scan budget). Silence is not
   inactivity: `filtered` counts what each filter and your `view` did not
   show you. Joining a running session, read from cursor `"latest"` to skip
   its history; `status` reports `next_receipt` and the recorder's fill.
5. Repeat 3 and 4. Reads renew the lease; `status` and subscriptions do not,
   so call `renew` during long pauses.
6. `stop` when done and check the receipt's `outcome`. A session you abandon
   is stopped by its lease through the same cleanup.

## Sharing a session with other agents

- Name yourself on every read, watch, stop, and amend with `--reader NAME`
  (`"reader"`); `status` lists each named reader's cursor and when it last
  read. Join a running session from cursor `latest` instead of stopping it.
- Recording options (components, events, measurements, filters) apply to
  every reader. A view applies only to your own read. To change what is
  recorded, `amend` the running session: its history and every cursor stay,
  and every reader sees a `live.session_amended` event.
- `stop` refuses with `readers_active` while another named reader is
  active; `--force` stops anyway. A stopped session stays readable until
  `readable_until`, so peers can drain it.
- `handoff` prints what another agent needs to continue: node, welcome hash,
  session id, configuration, and each reader's cursor.
- Run several agents from the escript (`mix escript.install hex insider_lab`,
  or `mix escript.build` in `tools/insider_lab`), which never waits on Mix's
  build lock.

What leaves the node depends on its disclosure profile, which the welcome
states as `effective_disclosure`. Development and test default to `rich`:
events carry Logger message text and metadata, Telemetry metadata and
measurements, with credentials masked. Only in the `strict` profile (the ci
default) do event payloads, Logger message text, and Telemetry metadata never
leave the node. See the welcome's `disclosure` rules.

## Pairs well with

Insider shows what a running node does. Reach for these when the question
is a different one. The welcome's `pairs_with` lists the same table, and
`runtime.pairs_with_available` says which the node has.

| Tool | Use it for | Is it there? |
|---|---|---|
| Credo | Static style and consistency rules: code-shape checks Insider leaves out. `mix credo --strict`. | `"credo"` in `mix.lock` |
| Argus | A static analysis tool for compiled beams: OTP startup, shutdown and supervision structure, races, swallowed failures, unanswered messages, effects inside a transaction, ETS ownership, exposed secrets. `argus list` names the analyses; after `mix compile` (it never builds) run `argus analyze --project beams --root . --ebin _build/dev/lib/APP/ebin --analyses default,effects,ets,exposure --format json`, since the default set alone leaves out effects, ets, and exposure. | `argus` on `PATH` (`argus version`), and `souffle` on `PATH` |
| recon | Live process, memory, allocator and port inspection beyond Insider's bounded `process`, `bin_leak`, `ports`, and `alloc` reads, run in the node (Tidewave `project_eval` or a remote shell). | `"recon"` in `mix.lock`, or `runtime.pairs_with_available.recon` (true also after `--load` pushed it) |
| Tidewave | Evaluating code and reading logs in the running dev node (`project_eval`, `get_logs`) when Insider's evidence needs a why. | `"tidewave"` in `mix.lock`, and the dev server answers at `/tidewave/mcp` |
| observer_cli | A terminal UI for a human watching the node. Not for agents; use `digest`, `trends`, and `process` instead. | `"observer_cli"` in `mix.lock` |

## Report Insider's own bugs

You must report Insider bugs and every behaviour that differs from the
welcome document. Categories are a closed list: `bug`, `doc_mismatch` (cite
the welcome field you relied on), `missing_capability`, and
`confusing_output`. Write what you expected and what happened; never include
event payloads, log text, option values, or secrets. Insider adds the
context itself: its version and commit, the welcome hash, the node, the
environment, the last target operation and error code, and the observer's
last local failure (such as a `usage` error).

```sh
mix insider.live report --category doc_mismatch --message 'welcome says X; observed Y'
```

```elixir
Insider.Live.JSON.report(%{"category" => "doc_mismatch", "message" => "welcome says X; observed Y"})
```

Reports stay on the machine: the observer keeps a bounded JSONL queue, and
the node keeps a bounded in-memory queue that `mix insider.live reports
--node …` copies into it. Both deduplicate by fingerprint (the category and
the normalised message). `mix insider.live reports submit` files GitHub
issues on `hiivemarkets/insider` through `gh`, one per new fingerprint, only
with `--confirm` or when the host sets
`config :insider, :live_report_submission, :github`. Without either it
prints what it would send and runs nothing; `--dry-run` always previews,
overriding every opt-in. Submitting is the developer's decision, not yours.

The observer queue is shared by every run on the machine. A report's context
cites `report --session ID` when given, else the session of your last target
command; `reports` groups reports by node and session, and `--session` or
`--fingerprint` selects what `reports` and `reports submit` cover.

## Where the details are

The reference under `docs/live/` covers the environment rule, leases,
cursors and gaps, subscriptions, every error code, Tidewave setup, and the
observer node's target setup, `--load`, and exit statuses. Start with
[Live observation](../../docs/live/live-api-and-transports.md#live-observation),
the [cheat sheet](../../docs/cheat-sheet.md), or find your task in the
[documentation index](../../docs/README.md#use-insider-live).

## Other questions

Each operation that this guide does not cover has its own section:

- One request as a span tree: `trace`, in
  [Read one request as a trace](../../docs/live/live-otel-traces.md#read-one-request-as-a-trace).
  Keep it past eviction with `--retain`, in
  [Pin a trace](../../docs/live/live-otel-traces.md#pin-a-trace).
- GraphQL response values: `trace --values`, in
  [Response values](../../docs/live/live-otel-traces.md#response-values).
- Everything one process or one request did: `timeline`, in
  [Timeline of a process or request](../../docs/live/live-otel-traces.md#timeline-of-a-process-or-request).
- Who changed an in-memory value: `start --watch-write`, then `changes`, in
  [Changes of in-memory values](../../docs/live/live-runtime-evidence.md#changes-of-in-memory-values).
- Mutations that outlive the Recorder: `mutations`, in
  [Kept mutation records](../../docs/live/live-otel-traces.md#kept-mutation-records).
- Anomalies you already know about: `baseline`, in
  [Known-normal baseline](../../docs/live/live-digest-filters-and-trends.md#known-normal-baseline).
- A frontend's spans in the same trace: `otlp-receive`, in
  [Frontend traces](../../docs/live/live-otel-traces.md#frontend-traces-otlp-http-receiver).
- Reads without `--session`: the node's active session, in
  [Default session](../../docs/live/live-api-and-transports.md#default-session).
- What `stop` proves and what it does not:
  [Stop and check the cleanup receipt](../../docs/live/live-api-and-transports.md#stop-and-check-the-cleanup-receipt).

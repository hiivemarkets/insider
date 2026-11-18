defmodule Insider.Live.Welcome do
  @moduledoc false

  # The welcome documents (the quick start, `insider.live-welcome-quick-start/v1`,
  # and the full reference, `insider.live-welcome/v2`): what an agent connected
  # to this node may do, generated from the tables the code itself uses (the
  # option, bound, error, component, measurement, and report tables) plus the
  # operation, observer command, quick start, and recipe tables below, which
  # tests compare with the exported functions and the Lab observer's own
  # command table and parser. By default an agent gets the quick start; the
  # full reference is `welcome(%{"full" => true})`. `"hash"` is the SHA-256
  # of the canonical JSON of every key of the full reference except `"hash"`,
  # `"runtime"` and `"effective_disclosure"` (a runtime fact), so it changes exactly when what the document promises
  # changes, and not with the node's moment-to-moment state.

  alias Insider.Collector.Logger.Handler, as: LoggerHandler
  alias Insider.Collector.Telemetry.Outcome
  alias Insider.Event.Canonical
  alias Insider.Live.Disclosure
  alias Insider.Live.Discovery
  alias Insider.Live.Error
  alias Insider.Live.Filters
  alias Insider.Live.Inspect
  alias Insider.Live.Options
  alias Insider.Live.Owner
  alias Insider.Live.Report
  alias Insider.Live.Revision
  alias Insider.Recorder.Config, as: RecorderConfig

  # The full reference is v2: v1 was returned by the default `welcome`, which
  # now returns the quick start, a separate document with its own schema.
  @schema "insider.live-welcome/v2"
  @quick_start_schema "insider.live-welcome-quick-start/v1"
  @observer_command "mix insider.live"
  @observer_escript "insider-lab live"
  @target_placeholder "--node NAME@HOST --cookie-file PATH"

  # `"options"` names a group of `Insider.Live.Options.describe/0`;
  # `"observer"` is the observer command that performs the operation.
  @operations [
    %{
      "name" => "welcome",
      "arity" => 1,
      "observer" => "welcome",
      "options" => "welcome",
      "renews_lease" => false,
      "summary" =>
        "This document: by default the agent quick start and symptom recipes; with full, the whole reference. " <>
          "Read it first and keep its hash."
    },
    %{
      "name" => "capabilities",
      "arity" => 0,
      "observer" => "capabilities",
      "options" => nil,
      "renews_lease" => false,
      "summary" =>
        "What this node allows now, the active session id, bounds, and this document's hash. Starts nothing."
    },
    %{
      "name" => "discover",
      "arity" => 1,
      "observer" => "discover",
      "options" => "discover",
      "renews_lease" => false,
      "summary" =>
        "The Telemetry event names this node can emit, each with its sources (handler, execute, span) and module: " <>
          "names with an attached handler and literal event lists in :telemetry.execute and :telemetry.span calls of loaded " <>
          "application modules, read from debug info. Bounded in modules, names, and time; runs no application code and starts nothing."
    },
    %{
      "name" => "process",
      "arity" => 1,
      "observer" => "process",
      "options" => "process",
      "renews_lease" => false,
      "summary" =>
        "One process, once (by registered name or pid): status, initial and current function, queue length, memory, reductions, " <>
          "links by kind and monitors, the current stacktrace's top frames with file and line, its binaries' count and bytes, " <>
          "and its mailbox summarised by message shape and size class (types in place of values; the first N shapes; queued " <>
          "GenServer.calls whose callers already exited). Never a message value, a dictionary entry or sys:get_state. " <>
          "Like every inspection it is recorded in a running session as an inspect.* event."
    },
    %{
      "name" => "bin_leak",
      "arity" => 1,
      "observer" => "bin_leak",
      "options" => "bin_leak",
      "renews_lease" => false,
      "summary" =>
        "Garbage-collects every unprotected process and names biggest_holder, the process still referencing the most binary " <>
          "bytes after it (first in by_retained_bytes: a leak holds them), and ranks what it freed (by_freed_bytes: garbage, not a leak), " <>
          "each with name and initial call; Insider's own processes are summed apart. human adds text, the biggest holder first."
    },
    %{
      "name" => "ports",
      "arity" => 1,
      "observer" => "ports",
      "options" => "ports",
      "renews_lease" => false,
      "summary" =>
        "The node's ports counted by type (cat, tcp_inet) with their OS processes, from one read of at most bounds.inspect.ports_scanned_max ports, " <>
          "then the ports of one type or owner with owner name and pid, OS pid and I/O counters, and the owners holding most; top bounds each list. " <>
          "In the rich profile each port's command line; when its arguments name a credential anywhere or hold an escape, a control character, $ or a backtick, they are masked whole."
    },
    %{
      "name" => "alloc",
      "arity" => 1,
      "observer" => "alloc",
      "options" => "alloc",
      "renews_lease" => false,
      "summary" =>
        "The memory allocators through recon_alloc: allocated and used bytes, usage, bytes by allocator type, and the " <>
          "fragmentation of the largest allocator instances. component_unavailable without recon; --load pushes recon."
    },
    %{
      "name" => "start",
      "arity" => 1,
      "observer" => "start",
      "options" => "start",
      "renews_lease" => false,
      "summary" =>
        "Starts the node's one live session; returns session_id, cursor 0, and the lease."
    },
    %{
      "name" => "amend",
      "arity" => 2,
      "observer" => "amend",
      "options" => "amend",
      "renews_lease" => true,
      "summary" =>
        "Changes a running session's recording options (any start option; each one given replaces the session's value, null returns it to its default) " <>
          "without losing its history, cursors, readers or subscribers. Poller options return to their defaults when the components leave the poller out, " <>
          "and Telemetry events and measurements when they leave telemetry out. " <>
          "The next receipt is a live.session_amended event " <>
          "every reader sees through any view, with what changed and uncollected_ms, the pause in collection."
    },
    %{
      "name" => "events_since",
      "arity" => 3,
      "observer" => "events",
      "options" => "read",
      "renews_lease" => true,
      "summary" =>
        "Events after a cursor (an integer, \"latest\" for the newest receipt, or \"mark\" or \"mark:LABEL\" for after a pairing mark, " <>
          "with the batch's mark naming it) in receipt order, with " <>
          "next_cursor, gaps, filtered, truncated, and truncated_by. The options map is optional; its view " <>
          "narrows only this read (view_keep makes it the reader's stored view; a named read without a view applies " <>
          "the stored one and says so in stored_view), limit and max_bytes count only the events returned, and reader " <>
          "names you in status. upto bounds the read at a receipt between the starting cursor and the newest receipt: " <>
          "the read is complete when it reaches it, and counts losses only up to it. " <>
          "A stopped session stays readable for bounds.stopped_readable_ms. A batch that shows a crash or exception carries hints: " <>
          "the amend --calls command that traces the function its stack points at (or, before OTP 28, the recon_trace call)."
    },
    %{
      "name" => "digest",
      "arity" => 2,
      "observer" => "digest",
      "options" => "digest",
      "renews_lease" => true,
      "summary" =>
        "What is wrong right now, in one call: a window of events (by default the last 60 s; since a cursor, latest-N receipts, latest-DURATION, or a pairing mark: \"mark\" or \"mark:LABEL\") " <>
          "led by anomalies (request bursts, pre-handler waits of 1 s or more, N+1 queries (one query shape 10 times or more in one request), error spikes, restart loops, mailbox or run-queue pressure, evictions; " <>
          "ranked, one line each with the next command; human prints them first), then summarised as counts by kind, " <>
          "severity, source and supervisor offender, crash loops with their period and reason fingerprint, the top error " <>
          "signatures, latency tables from summaries (with the receipts of their exemplar events) and recorded durations, " <>
          "trends across summary windows, Logger bursts, the longest mailboxes, VM deltas (vm.target without Insider's own processes, " <>
          "memory and ETS), and the window's filtered and gaps. hints gives the next command with its reason: trace_calls (the amend " <>
          "--calls MOD.FUN/ARITY for a crash loop or repeated exception, from call_candidates), trace_calls_unavailable, and, for each " <>
          "source the Recorder evicted, reduce_logger, reduce_telemetry, reduce_poller, and raise_capacity, plus shared_readers when " <>
          "several readers share the evicting Recorder. human adds text, a short " <>
          "plain-text summary for the developer, with one Next: line per hint."
    },
    %{
      "name" => "baseline",
      "arity" => 2,
      "observer" => "baseline",
      "options" => "baseline",
      "renews_lease" => true,
      "summary" =>
        "Marks the anomalies of a window (default latest-5m) normal for this session: their kinds, hashed identities and rates, " <>
          "never their values. Later digests and status fold them into one line (\"1 known-normal anomaly hidden\") and lead " <>
          "with what is new; one at 10x its rate comes back, saying so. show returns the baseline, clear removes it; the " <>
          "session keeps it for its life and its read-only window."
    },
    %{
      "name" => "trends",
      "arity" => 2,
      "observer" => "trends",
      "options" => "trends",
      "renews_lease" => true,
      "summary" =>
        "How the summaries moved across their windows, with fixed units: per summarised Telemetry kind each window's " <>
          "started_at, ended_at, count, rate_per_min, errors, error_pct, p50_us, p95_us, max_us, exemplar receipts, " <>
          "exemplars_lost and first_error_retained, the change of rate, p95, max and errors from the first window to the last " <>
          "with its direction, and duration_scope (measured_in handler or caller only when the session declared it with " <>
          "telemetry_duration_scopes, else unknown; emitter is only where the exemplars were emitted); per Logger burst " <>
          "(template, call site and level, plus one overflow row per level) each window's count. " <>
          "poller lists Poller series per sample: binary_bytes and port_count per vm_sample, ports per type per port_top, " <>
          "and message_queue_len per ranked (process_top) or watched (process_watch) process, each with its unit, the change " <>
          "from the first sample to the last with its direction, per_min growth and max. " <>
          "kinds narrows the series, windows bounds how many are listed; human adds text."
    },
    %{
      "name" => "handoff_record",
      "arity" => 1,
      "observer" => "handoff",
      "options" => nil,
      "renews_lease" => false,
      "summary" =>
        "A record to hand the session to another agent: the node, this document's hash, the session id, its recording " <>
          "configuration (shared by every reader), the named readers' cursors, and the commands that resume them."
    },
    %{
      "name" => "trace",
      "arity" => 3,
      "observer" => "trace",
      "options" => "trace",
      "renews_lease" => true,
      "summary" =>
        "One trace by its W3C trace_id: the otel component's spans as a tree, merged in time order with the Logger and " <>
          "Telemetry events of the same trace, or of a span's process inside its time window. unjoined, scan, and gaps " <>
          "say what it could not join or read."
    },
    %{
      "name" => "mutations",
      "arity" => 2,
      "observer" => "mutations",
      "options" => "mutations",
      "renews_lease" => true,
      "summary" =>
        "The session's kept mutation records, which outlive the Recorder's eviction (with the telemetry component): each " <>
          "GraphQL mutation's operation, result, response typenames (a ValidationError inside a 200 says so), time, trace, " <>
          "process, the client's user agent, and the record ids among its arguments (rich only); id keeps one record's."
    },
    %{
      "name" => "changes",
      "arity" => 2,
      "observer" => "changes",
      "options" => "changes",
      "renews_lease" => true,
      "summary" =>
        "Who changed a watched in-memory value (start option watch_writes, with the calls component): each write, oldest " <>
          "first, with its key, its value (rich only), and its writer: the process, and the GraphQL operation, route, user " <>
          "agent, user id (rich) and trace id of the request it belonged to, from that process's events, else from the " <>
          "session's kept mutation record (status mutations), which outlives the Recorder's eviction."
    },
    %{
      "name" => "timeline",
      "arity" => 2,
      "observer" => "timeline",
      "options" => "timeline",
      "renews_lease" => true,
      "summary" =>
        "Every source's events for one process (pid) or one request (request_id: its events, its processes within its " <>
          "time window, and its traces), in time order, with the trace ids to follow with trace. Reads newest first; " <>
          "a scan_truncated gap counts the older receipts the budget did not reach. since keeps only receipts after a cursor " <>
          "or a pairing mark (\"mark\", \"mark:LABEL\")."
    },
    %{
      "name" => "mark",
      "arity" => 2,
      "observer" => "mark",
      "options" => "mark",
      "renews_lease" => true,
      "summary" =>
        "Pairing: marks the moment before the programmer acts (label: what is about to happen, such as about to click Confirm), " <>
          "as the newest receipt now, its time, label and reader, recorded as a live.mark event. Read since it with " <>
          "digest, trends or timeline since \"mark\" (or \"mark:LABEL\"), or events with cursor \"mark\": no time or cursor to guess. " <>
          "next is the command to run once they have acted. Labels are one line, credential-masked in every profile, at most " <>
          "bounds.mark_label_max_bytes bytes; a session keeps its newest bounds.marks_max marks through amendments and after a stop."
    },
    %{
      "name" => "marks",
      "arity" => 2,
      "observer" => "marks",
      "options" => "marks",
      "renews_lease" => false,
      "summary" =>
        "The session's pairing marks, oldest first: index, label, time, age_ms, reader, and the receipt each starts after; " <>
          "dropped counts older marks let go. A stopped session keeps its marks."
    },
    %{
      "name" => "renew",
      "arity" => 1,
      "observer" => "renew",
      "options" => nil,
      "renews_lease" => true,
      "summary" => "Renews the session lease."
    },
    %{
      "name" => "status",
      "arity" => 1,
      "observer" => "status",
      "options" => nil,
      "renews_lease" => false,
      "summary" =>
        "The running session with collector health, next_receipt (the newest receipt), recorder (oldest_receipt, " <>
          "retained_events, retained_bytes, archived_events, their bounds, and sources: each source's share and how many of its events were evicted), " <>
          "insider_memory (Insider's own processes and Recorder, in bytes), readers (name, cursor, behind, " <>
          "last_seen_ms_ago, subscribed, active), amendments, and telemetry_subscriptions (each event's state and seen " <>
          "count), and anomalies, the last 60 s's anomalies as digest ranks them (anomalies_window; anomalies_complete, with " <>
          "anomalies_note saying why when the window was not read whole; the read renews no lease, keeps no cursor or view, and " <>
          "never ends or revokes the session); or the retained record of an ended one with its " <>
          "cleanup receipt and readable_remaining_ms."
    },
    %{
      "name" => "stop",
      "arity" => 2,
      "observer" => "stop",
      "options" => "stop",
      "renews_lease" => false,
      "summary" =>
        "Stops the session and returns its record with the cleanup receipt; repeating it returns the same record. " <>
          "It refuses with readers_active while another named reader read within bounds.reader_active_ms or is subscribed, " <>
          "unless force. The stopped session stays readable until readable_until, so peers can drain it."
    },
    %{
      "name" => "subscribe",
      "arity" => 3,
      "observer" => "watch",
      "options" => "subscribe",
      "renews_lease" => false,
      "summary" =>
        "Pushes {:insider_live_events, session_id, batch} to a pid from its cursor (default 0, or \"latest\"), " <>
          "through the optional view (else the reader's stored view, named in stored_view), until its max_events are sent; " <>
          "each batch starts where the previous one ended. " <>
          "A reader name marks it subscribed in status. The observer's watch subscribes and renews the lease for you."
    },
    %{
      "name" => "unsubscribe",
      "arity" => 2,
      "observer" => "watch",
      "options" => nil,
      "renews_lease" => false,
      "summary" => "Removes a subscriber; removing an absent one succeeds."
    },
    %{
      "name" => "ingest_spans",
      "arity" => 2,
      "observer" => "otlp-receive",
      "options" => nil,
      "renews_lease" => false,
      "summary" =>
        "Records spans exported by another process (at most 512 span maps) as otel.span events of the running session, " <>
          "under its span contract, disclosure profile and credential masking, with attributes.capture ingest; " <>
          "returns accepted, rejected, filtered, shed and duplicate. Idempotent per trace_id and span_id: a span " <>
          "already recorded is a duplicate, not recorded again. A timeout means the outcome is unknown (some, all or " <>
          "none recorded); a retry skips spans whose ids are among the last 16,384 recorded, and seen_evicted counts the ids forgotten. " <>
          "Dedupe is per otel collector: every amendment, even one rolled back, resets it, so a span ingested before an amendment " <>
          "is recorded again after it, and seen_evicted does not count that reset. " <>
          "Needs a session with the otel component."
    },
    %{
      "name" => "report",
      "arity" => 1,
      "observer" => "report",
      "options" => "report",
      "renews_lease" => false,
      "summary" =>
        "Queues a report about Insider itself on this node; context is added automatically."
    },
    %{
      "name" => "reports",
      "arity" => 0,
      "observer" => "reports",
      "options" => nil,
      "renews_lease" => false,
      "summary" => "Lists the reports queued on this node."
    }
  ]

  # The Lab observer's commands. `"target"` says whether `--node` and
  # `--cookie-file` are required, optional, or not accepted; `--timeout-ms`
  # and `--load` go with them. `"summary"` and `"examples"` are the
  # observer's `help` text; a Lab test parses every example with the
  # observer's own parser, so an example that no longer parses fails it.
  @observer_target_flags ["--cookie-file", "--force-load", "--load", "--node", "--timeout-ms"]
  # Short receipts of an action: they neither carry nor deliver the welcome
  # quick start. The observer's delivery reads this list.
  @observer_receipts ["mark", "amend", "stop", "renew", "chart", "reports", "reports submit"]
  # The recording flags `start` takes and `amend` changes.
  @recording_flags [
    "--calls",
    "--calls-max",
    "--calls-max-bytes",
    "--calls-rate-max",
    "--calls-rate-ms",
    "--calls-results",
    "--component",
    "--disclosure",
    "--exclude-origin",
    "--lease-ms",
    "--logger-exclude",
    "--logger-include",
    "--logger-level",
    "--logger-summary",
    "--logger-summary-interval-ms",
    "--max-events",
    "--otel-min-duration-ms",
    "--poller-interval-ms",
    "--retain-traces",
    "--telemetry-duration-scope",
    "--telemetry-event",
    "--telemetry-event-min-duration",
    "--telemetry-measurement",
    "--telemetry-min-duration-ms",
    "--telemetry-summary",
    "--telemetry-summary-interval-ms",
    "--top-ets-tables",
    "--top-ports",
    "--top-processes",
    "--watch-process",
    "--watch-write"
  ]
  @observer_commands [
    %{
      "name" => "welcome",
      "target" => "required",
      "required" => [],
      "optional" => ["--full", "--reader"],
      "summary" =>
        "Prints the target's agent quick start and symptom recipes; --full prints the whole reference.",
      "examples" => [
        "#{@observer_command} welcome \"${N[@]}\"",
        "#{@observer_command} welcome \"${N[@]}\" --load",
        "#{@observer_command} welcome \"${N[@]}\" --full"
      ]
    },
    %{
      "name" => "capabilities",
      "target" => "required",
      "required" => [],
      "optional" => ["--reader"],
      "summary" =>
        "What the target allows now, its active session, bounds, quiet default Telemetry events, and the welcome hash.",
      "examples" => ["#{@observer_command} capabilities \"${N[@]}\""]
    },
    %{
      "name" => "discover",
      "target" => "required",
      "required" => [],
      "optional" => ["--prefix"],
      "summary" =>
        "Lists the Telemetry event names the target can emit, with each name's sources and module; --prefix keeps the names under a prefix.",
      "examples" => [
        "#{@observer_command} discover \"${N[@]}\"",
        "#{@observer_command} discover \"${N[@]}\" --prefix phoenix.router_dispatch"
      ]
    },
    %{
      "name" => "process",
      "target" => "required",
      "required" => [],
      "optional" => ["--frames", "--messages", "--name", "--pid"],
      "summary" =>
        "Inspects one process once, named by --name (a registered name) or --pid: process_info subset, stacktrace top " <>
          "frames, links, monitors, binaries, and its mailbox by message shape (never values). Recorded in a running session.",
      "examples" => [
        "#{@observer_command} process \"${N[@]}\" --name MyApp.Worker",
        "#{@observer_command} process \"${N[@]}\" --pid '<0.200.0>' --messages 20"
      ]
    },
    %{
      "name" => "bin_leak",
      "target" => "required",
      "required" => [],
      "optional" => ["--human", "--top"],
      "summary" =>
        "Garbage-collects every unprotected process once and names biggest_holder, the process still referencing the most " <>
          "binary bytes (first in by_retained_bytes), then ranks bytes freed (by_freed_bytes: garbage, not a leak). " <>
          "--human prints the holders first as plain text. Recorded in a running session.",
      "examples" => [
        "#{@observer_command} bin_leak \"${N[@]}\" --top 5",
        "#{@observer_command} bin_leak \"${N[@]}\" --human"
      ]
    },
    %{
      "name" => "ports",
      "target" => "required",
      "required" => [],
      "optional" => ["--owner", "--top", "--type"],
      "summary" =>
        "Counts the target's ports by type with their OS processes, and lists the ports of --type or --owner with owner, " <>
          "OS pid and I/O counters, and the owners holding most. Recorded in a running session.",
      "examples" => [
        "#{@observer_command} ports \"${N[@]}\"",
        "#{@observer_command} ports \"${N[@]}\" --type cat",
        "#{@observer_command} ports \"${N[@]}\" --owner MyApp.Worker --top 50"
      ]
    },
    %{
      "name" => "alloc",
      "target" => "required",
      "required" => [],
      "optional" => ["--top"],
      "summary" =>
        "Reports the target's memory allocators with recon_alloc (allocated, used, by type, fragmentation); " <>
          "needs recon on the target, which --load pushes.",
      "examples" => [
        "#{@observer_command} alloc \"${N[@]}\"",
        "#{@observer_command} alloc \"${N[@]}\" --load"
      ]
    },
    %{
      "name" => "start",
      "target" => "required",
      "required" => [],
      "optional" => @recording_flags,
      "summary" =>
        "Starts the target's one live session and prints its session_id. Its recording options (components, events, " <>
          "measurements, filters) apply to every reader; amend changes them later.",
      "examples" => [
        "#{@observer_command} start \"${N[@]}\"",
        "#{@observer_command} start \"${N[@]}\" --component logger --logger-level info --logger-include module:MyApp.Checkout",
        "#{@observer_command} start \"${N[@]}\" --component telemetry --telemetry-event phoenix.endpoint.stop " <>
          "--telemetry-measurement duration --telemetry-summary phoenix.endpoint.stop --telemetry-summary-interval-ms 5000",
        "#{@observer_command} start \"${N[@]}\" --component telemetry --telemetry-event 'my_app.*' --telemetry-min-duration-ms 0",
        "#{@observer_command} start \"${N[@]}\" --component logger --component otel --component telemetry --logger-level info"
      ]
    },
    %{
      "name" => "amend",
      "target" => "required",
      "required" => ["--session"],
      "optional" => Enum.sort(["--reader", "--reset" | @recording_flags]),
      "summary" =>
        "Changes the running session's recording options for every reader without losing its history; each flag given " <>
          "replaces that option (a repeated flag replaces the whole list), and --reset FLAG returns one to its default. " <>
          "Leaving the poller out of --component returns the poller options to their defaults. Readers see a live.session_amended event.",
      "examples" => [
        "#{@observer_command} amend \"${N[@]}\" --session SESSION_ID --telemetry-measurement duration --reader agent-a",
        "#{@observer_command} amend \"${N[@]}\" --session SESSION_ID --logger-level debug",
        "#{@observer_command} amend \"${N[@]}\" --session SESSION_ID --reset watch-process --reset poller-interval-ms"
      ]
    },
    %{
      "name" => "events",
      "target" => "required",
      "required" => [],
      "optional" => [
        "--cursor",
        "--format",
        "--limit",
        "--max-bytes",
        "--reader",
        "--scan-limit",
        "--session",
        "--since-mark",
        "--view-clear",
        "--view-exclude-kind",
        "--view-exclude-signature",
        "--view-keep",
        "--view-kind",
        "--view-min-severity",
        "--view-route",
        "--view-service",
        "--view-source",
        "--view-trace"
      ],
      "summary" =>
        "Reads events after a cursor (--cursor), or after a pairing mark (--since-mark: exactly one of the two), and renews the lease; " <>
          "pass next_cursor to the next read. A view narrows only your read; " <>
          "--reader names you in status so a peer's stop waits for you. " <>
          "--format compact prints one line per event; --format full keeps every envelope field.",
      "examples" => [
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 0 --limit 100",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 0 --view-source logger --view-min-severity error",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 0 --format compact",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor latest --reader agent-b",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --since-mark --format compact"
      ]
    },
    %{
      "name" => "digest",
      "target" => "required",
      "required" => [],
      "optional" => [
        "--human",
        "--reader",
        "--session",
        "--show-baseline",
        "--since",
        "--since-mark",
        "--view-clear",
        "--view-exclude-kind",
        "--view-exclude-signature",
        "--view-keep",
        "--view-kind",
        "--view-min-severity",
        "--view-route",
        "--view-service",
        "--view-source",
        "--view-trace"
      ],
      "summary" =>
        "Summarises the session (or the window after --since, or since a pairing mark with --since-mark) in one document: counts, crash loops and their period, " <>
          "top error signatures, latency tables, longest mailboxes, VM deltas, filtered and gaps. Renews the lease. " <>
          "--human prints a short plain-text summary to paste for the developer instead of JSON.",
      "examples" => [
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID --since latest-500 --human",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID --since-mark 'about to click Confirm' --human"
      ]
    },
    %{
      "name" => "mark",
      "target" => "required",
      "required" => ["--label"],
      "optional" => ["--reader", "--session"],
      "summary" =>
        "Pairing: marks the moment before the programmer acts. Mark, ask them to act, then digest --since-mark --human " <>
          "(the reply's next) reads only what came after; events, trends and timeline take --since-mark too. Renews the lease.",
      "examples" => [
        "#{@observer_command} mark \"${N[@]}\" --session SESSION_ID --label 'about to click Confirm' --reader agent-a"
      ]
    },
    %{
      "name" => "marks",
      "target" => "required",
      "required" => [],
      "optional" => ["--human", "--reader", "--session"],
      "summary" =>
        "Lists the session's pairing marks, oldest first, with each one's time, age, label, reader and receipt.",
      "examples" => ["#{@observer_command} marks \"${N[@]}\" --session SESSION_ID --human"]
    },
    %{
      "name" => "baseline",
      "target" => "required",
      "required" => [],
      "optional" => [
        "--clear",
        "--human",
        "--reader",
        "--session",
        "--show",
        "--since",
        "--since-mark",
        "--view-clear",
        "--view-exclude-kind",
        "--view-exclude-signature",
        "--view-keep",
        "--view-kind",
        "--view-min-severity",
        "--view-route",
        "--view-service",
        "--view-source",
        "--view-trace"
      ],
      "summary" =>
        "Marks the anomalies digest shows now as normal for this node (a dev restart loop, known noise), so later digests " <>
          "and status lead with what is new and fold the rest into one line; --show prints the baseline, --clear removes it.",
      "examples" => [
        "#{@observer_command} baseline \"${N[@]}\" --session SESSION_ID --human",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID --human --show-baseline"
      ]
    },
    %{
      "name" => "trace",
      "target" => "required",
      "required" => ["--trace-id"],
      "optional" => [
        "--collapse",
        "--hide",
        "--human",
        "--limit",
        "--max-bytes",
        "--reader",
        "--retain",
        "--session",
        "--values",
        "--values-path",
        "--view-clear",
        "--view-exclude-kind",
        "--view-exclude-signature",
        "--view-keep",
        "--view-kind",
        "--view-min-severity",
        "--view-route",
        "--view-service",
        "--view-source",
        "--view-trace"
      ],
      "summary" =>
        "Prints one trace: its spans as a tree with the same trace's Logger and Telemetry events in time order. " <>
          "A trace that failed, was slow (500 ms or more) or ran a GraphQL mutation survives the Recorder's eviction by default " <>
          "(its retention says why); --retain pins any other, so it and its later events survive too (or start with --retain-traces N); " <>
          "--values (rich profile) adds its GraphQL response values, narrowed with --values-path. " <>
          "--human prints the span tree as text, each span with its duration and outcome (a GraphQL operation's result kind, " <>
          "error codes and paths, or payload error fields); --collapse sql,auth folds each run of such siblings into one counted line " <>
          "and --hide drops them, both counted under omitted. Needs a session with --component otel.",
      "examples" => [
        "#{@observer_command} trace \"${N[@]}\" --session SESSION_ID --trace-id TRACE_ID --human",
        "#{@observer_command} trace \"${N[@]}\" --session SESSION_ID --trace-id TRACE_ID --human --collapse sql --hide auth",
        "#{@observer_command} trace \"${N[@]}\" --session SESSION_ID --trace-id TRACE_ID --human --retain",
        "#{@observer_command} trace \"${N[@]}\" --session SESSION_ID --trace-id TRACE_ID --human --values --values-path 'buyOrderV2.buyOrder.total*'"
      ]
    },
    %{
      "name" => "mutations",
      "target" => "required",
      "required" => [],
      "optional" => [
        "--human",
        "--id",
        "--reader",
        "--session",
        "--view-clear",
        "--view-exclude-kind",
        "--view-exclude-signature",
        "--view-keep",
        "--view-kind",
        "--view-min-severity",
        "--view-route",
        "--view-service",
        "--view-source",
        "--view-trace"
      ],
      "summary" =>
        "Prints the kept mutation records, one line each (operation, result, response types, time, user agent, trace, " <>
          "argument ids), even after the Recorder evicted their events; --id keeps those whose arguments name a record id.",
      "examples" => [
        "#{@observer_command} mutations \"${N[@]}\" --session SESSION_ID --id 'RECORD_ID' --human"
      ]
    },
    %{
      "name" => "changes",
      "target" => "required",
      "required" => [],
      "optional" => [
        "--human",
        "--key",
        "--reader",
        "--session",
        "--view-clear",
        "--view-exclude-kind",
        "--view-exclude-signature",
        "--view-keep",
        "--view-kind",
        "--view-min-severity",
        "--view-route",
        "--view-service",
        "--view-source",
        "--view-trace"
      ],
      "summary" =>
        "Prints who changed a watched in-memory value: start with --component calls --watch-write MOD.FUN/ARITY " <>
          "(the store's write function, such as an app's feature-flag store set/2, or Application.put_env/3), then each " <>
          "write's time, key, value (rich), and writer request (operation, route, user, trace).",
      "examples" => [
        "#{@observer_command} start \"${N[@]}\" --component calls --component telemetry --watch-write 'MyApp.Flags.put/2'",
        "#{@observer_command} changes \"${N[@]}\" --session SESSION_ID --key 'new-checkout' --human"
      ]
    },
    %{
      "name" => "timeline",
      "target" => "required",
      "required" => [],
      "optional" => [
        "--human",
        "--limit",
        "--max-bytes",
        "--pid",
        "--reader",
        "--request-id",
        "--session",
        "--since-mark",
        "--view-clear",
        "--view-exclude-kind",
        "--view-exclude-signature",
        "--view-keep",
        "--view-kind",
        "--view-min-severity",
        "--view-route",
        "--view-service",
        "--view-source",
        "--view-trace"
      ],
      "summary" =>
        "Prints every source's events for one process (--pid) or one request (--request-id) in time order; " <>
          "exactly one of the two. --since-mark keeps only what came after a pairing mark.",
      "examples" => [
        "#{@observer_command} timeline \"${N[@]}\" --session SESSION_ID --pid '<0.1234.0>' --human",
        "#{@observer_command} timeline \"${N[@]}\" --session SESSION_ID --request-id REQUEST_ID"
      ]
    },
    %{
      "name" => "trends",
      "target" => "required",
      "required" => [],
      "optional" => [
        "--human",
        "--kind",
        "--reader",
        "--session",
        "--since",
        "--since-mark",
        "--view-clear",
        "--view-exclude-kind",
        "--view-exclude-signature",
        "--view-keep",
        "--view-kind",
        "--view-min-severity",
        "--view-route",
        "--view-service",
        "--view-source",
        "--view-trace",
        "--windows"
      ],
      "summary" =>
        "Prints how each summary series moved across its windows (rate, p95, max, errors, each window's exemplar receipts " <>
          "and lost exemplar candidates), each Logger burst's count per window, and the Poller series (binary bytes, ports " <>
          "per type, mailbox lengths) per sample with growth per minute, in fixed units; --kind narrows to some kinds " <>
          "(logger_summary for the bursts; vm_sample, port_top, process_top or process_watch for the Poller series). " <>
          "Renews the lease. --human prints one line per series instead of JSON.",
      "examples" => [
        "#{@observer_command} trends \"${N[@]}\" --session SESSION_ID",
        "#{@observer_command} trends \"${N[@]}\" --session SESSION_ID --kind shop.pricing.lookup --human"
      ]
    },
    %{
      "name" => "status",
      "target" => "required",
      "required" => [],
      "optional" => ["--reader", "--session"],
      "summary" =>
        "The running session with collector health, its named readers (cursor, behind, last seen, subscribed) and " <>
          "amendments, or an ended session's record with its cleanup receipt and how long it stays readable.",
      "examples" => ["#{@observer_command} status \"${N[@]}\" --session SESSION_ID"]
    },
    %{
      "name" => "handoff",
      "target" => "required",
      "required" => [],
      "optional" => ["--reader", "--session"],
      "summary" =>
        "Prints a record to pass the session to another agent: node, welcome hash, session id, recording configuration, " <>
          "the named readers' cursors, and the commands that resume them.",
      "examples" => ["#{@observer_command} handoff \"${N[@]}\" --session SESSION_ID"]
    },
    %{
      "name" => "renew",
      "target" => "required",
      "required" => [],
      "optional" => ["--reader", "--session"],
      "summary" => "Renews the session lease.",
      "examples" => ["#{@observer_command} renew \"${N[@]}\" --session SESSION_ID"]
    },
    %{
      "name" => "stop",
      "target" => "required",
      "required" => ["--session"],
      "optional" => ["--force", "--reader"],
      "summary" =>
        "Stops the session and prints its cleanup receipt. Refuses with readers_active while another named reader is " <>
          "active, unless --force; the stopped session stays readable for a while so peers can drain it.",
      "examples" => [
        "#{@observer_command} stop \"${N[@]}\" --session SESSION_ID",
        "#{@observer_command} stop \"${N[@]}\" --session SESSION_ID --reader agent-a",
        "#{@observer_command} stop \"${N[@]}\" --session SESSION_ID --reader agent-a --force"
      ]
    },
    %{
      "name" => "watch",
      "target" => "required",
      "required" => [],
      "optional" => [
        "--for",
        "--format",
        "--from-cursor",
        "--max-events",
        "--reader",
        "--session",
        "--view-clear",
        "--view-exclude-kind",
        "--view-exclude-signature",
        "--view-keep",
        "--view-kind",
        "--view-min-severity",
        "--view-route",
        "--view-service",
        "--view-source",
        "--view-trace"
      ],
      "summary" =>
        "Prints pushed batches as NDJSON until SIGTERM, --for, --max-events, or the session ends, renewing the lease. " <>
          "A view narrows what it prints: --view-min-severity warning hides ordinary Telemetry events, which are info.",
      "examples" => [
        "#{@observer_command} watch \"${N[@]}\" --session SESSION_ID --for 30s --view-kind 'phoenix.*'",
        "#{@observer_command} watch \"${N[@]}\" --session SESSION_ID --from-cursor latest --for 30s --view-min-severity warning",
        "#{@observer_command} watch \"${N[@]}\" --session SESSION_ID --from-cursor latest --for 60s --format compact"
      ]
    },
    %{
      "name" => "otlp-receive",
      "target" => "required",
      "required" => ["--session"],
      "optional" => ["--bind", "--for", "--port"],
      "summary" =>
        "Receives OTLP/HTTP trace exports (protobuf or JSON, at most 4 MiB) on a loopback port and records each span in " <>
          "the session, as ingest_spans does; prints NDJSON: listening, then per export its counts and trace ids, " <>
          "until SIGTERM, --for, or the session ends, renewing the lease. Needs a session with --component otel.",
      "examples" => [
        "#{@observer_command} otlp-receive \"${N[@]}\" --session SESSION_ID",
        "#{@observer_command} otlp-receive \"${N[@]}\" --session SESSION_ID --port 4319 --for 10m"
      ]
    },
    %{
      "name" => "chart",
      "target" => "required",
      "required" => [],
      "optional" => [
        "--for",
        "--out",
        "--port",
        "--reader",
        "--serve",
        "--session",
        "--since",
        "--since-mark"
      ],
      "summary" =>
        "Draws the session for the programmer you pair with: requests, latency, waits, errors by signature, the longest " <>
          "mailbox, memory and evictions over time (local wall clock), the marks as lines, the window since a mark shaded, " <>
          "the digest's anomalies as numbered markers, a one-line headline, and the digest's lead lines under it. Writes " <>
          "one self-contained HTML file (inline SVG, no script, mode 0600) and prints its path; --serve serves it live on " <>
          "127.0.0.1 at a secret URL, refreshing every second, until --for (default 30m) or the session ends, without " <>
          "renewing the lease. It reads with its own reader (--reader, default chart-…), through the session's disclosure.",
      "examples" => [
        "#{@observer_command} chart \"${N[@]}\" --session SESSION_ID --since-mark",
        "#{@observer_command} chart \"${N[@]}\" --session SESSION_ID --serve --for 30m"
      ]
    },
    %{
      "name" => "report",
      "target" => "none",
      "required" => ["--category", "--message"],
      "optional" => ["--session"],
      "summary" =>
        "Files a report about Insider itself in the observer's local queue; needs no target. " <>
          "Its context cites --session, else the session of your last target command.",
      "examples" => [
        "#{@observer_command} report --category doc_mismatch --message 'welcome says X; observed Y'",
        "#{@observer_command} report --session SESSION_ID --category bug --message 'expected X; observed Y'"
      ]
    },
    %{
      "name" => "reports",
      "target" => "optional",
      "required" => [],
      "optional" => ["--fingerprint", "--session"],
      "summary" =>
        "Lists the local report queue, which every observer run on this machine shares, and groups it by node and session; " <>
          "--fingerprint and --session select reports. With a target, first copies the target's queue.",
      "examples" => [
        "#{@observer_command} reports",
        "#{@observer_command} reports --session SESSION_ID",
        "#{@observer_command} reports \"${N[@]}\""
      ]
    },
    %{
      "name" => "reports submit",
      "target" => "optional",
      "required" => [],
      "optional" => ["--confirm", "--dry-run", "--fingerprint", "--session"],
      "summary" =>
        "Prints the GitHub issues it would file; files them only with --confirm or a host opt-in. " <>
          "--dry-run always previews, whatever opt-in is present. The result's authorization names the effective opt-in; " <>
          "a real submission prints it to standard error before its first gh call. --fingerprint and --session select reports.",
      "examples" => [
        "#{@observer_command} reports submit --dry-run",
        "#{@observer_command} reports submit --dry-run --session SESSION_ID",
        "#{@observer_command} reports submit --confirm --fingerprint 0123456789abcdef"
      ]
    }
  ]
  @observer_repeatable [
    "--calls",
    "--collapse",
    "--component",
    "--exclude-origin",
    "--fingerprint",
    "--hide",
    "--kind",
    "--logger-exclude",
    "--logger-include",
    "--logger-summary",
    "--reset",
    "--telemetry-duration-scope",
    "--telemetry-event",
    "--telemetry-event-min-duration",
    "--telemetry-measurement",
    "--telemetry-summary",
    "--values-path",
    "--view-exclude-kind",
    "--view-exclude-signature",
    "--view-kind",
    "--view-route",
    "--view-service",
    "--view-source",
    "--view-trace",
    "--watch-process",
    "--watch-write"
  ]

  # The observer's exit statuses and its closed error vocabulary: code =>
  # {status, message}. The Lab observer uses these tables, so the document
  # cannot list a code or status the observer does not have.
  @observer_exit_statuses %{
    "ok" => 0,
    "error" => 1,
    "unsupported" => 3,
    "invalid_input" => 64,
    "catastrophic" => 70,
    "timeout" => 124
  }
  @observer_errors %{
    "usage" =>
      {"invalid_input",
       "usage: mix insider.live OPERATION [--node NAME@HOST --cookie-file PATH] [OPTIONS]; " <>
         "mix insider.live --help lists the operations, help OPERATION shows one"},
    "invalid_options" =>
      {"invalid_input",
       "an option is missing, unknown, repeated, malformed or out of range; " <>
         "details name the option and its expected value"},
    "invalid_node" => {"invalid_input", "--node must be NAME@HOST"},
    "non_loopback_host" => {"invalid_input", "the target host is not loopback or this machine"},
    "cookie_file_unreadable" =>
      {"invalid_input", "the cookie file is missing or not a regular file"},
    "cookie_file_permissions" =>
      {"invalid_input", "the cookie file must be readable by its owner only"},
    "cookie_file_invalid" =>
      {"invalid_input", "the cookie file does not contain one printable cookie"},
    "target_not_found" => {"error", "no node with that name is registered on the host"},
    "distribution_unavailable" => {"error", "this VM cannot start a hidden observer node"},
    "connection_failed" =>
      {"error",
       "the target refused the connection (wrong cookie, or the host part differs from the node's own name)"},
    "connect_timeout" => {"timeout", "connecting to the target timed out"},
    "rpc_timeout" => {"timeout", "a remote call timed out"},
    "target_down" => {"error", "the connection to the target was lost"},
    "remote_exception" => {"error", "a remote call failed in the target"},
    "unexpected_response" => {"error", "the target returned a value outside the live contract"},
    "insider_missing" =>
      {"unsupported", "the target does not have Insider loaded; --load pushes it"},
    "insider_version_mismatch" =>
      {"unsupported",
       "the target runs a different Insider; --load never replaces it: pass --force-load, which replaces it and ends any session. " <>
         "Its evidence does not survive: read and save what you need (events, digest, handoff) before force-loading"},
    "insider_not_started" =>
      {"unsupported",
       "Insider is loaded but not started; --load starts it when it is this observer's build, and refuses another build " <>
         "(load_build_differs: only --force-load replaces it, and ends any session, whose evidence does not survive: " <>
         "read and save what you need (events, digest, handoff) first)"},
    "load_refused" =>
      {"unsupported", "--load is allowed only on development, test or ci targets"},
    "load_build_differs" =>
      {"unsupported",
       "the target has another Insider build loaded, and --load never replaces Insider code; pass --force-load, which replaces it and ends any session. Its evidence does not survive, even if you stop it first: read and save what you need (events, digest, handoff) before force-loading"},
    "load_failed" => {"error", "loading or starting Insider in the target failed"},
    "report_queue_unavailable" =>
      {"error", "the observer's local report queue could not be read or written"},
    "report_submit_failed" =>
      {"error", "gh failed for at least one report; see results for which were filed"},
    "non_loopback_bind" =>
      {"invalid_input", "--bind must be a loopback address such as 127.0.0.1 or ::1"},
    "port_unavailable" =>
      {"error", "the receiver could not listen on that port; it may be in use"},
    "observer_failed" => {"catastrophic", "the observer failed unexpectedly"}
  }

  # The agent quick start: the first thing the default welcome shows. Every
  # command in it, and in the recipes, is parsed by a Lab test with the
  # observer's own parser.
  @reader_active_s div(Owner.bounds()["reader_active_ms"], 1_000)
  @stopped_readable_s div(Owner.bounds()["stopped_readable_ms"], 1_000)
  @quick_start_steps [
    "1. Get the observer. It is the CLI of the insider_lab package. The insider package, the library in this node, has no Mix tasks, so an app that depends only on insider has no #{@observer_command}. " <>
      "From Hex: mix escript.install hex insider_lab installs the insider-lab escript (put the directory Mix prints on PATH); then run insider-lab live in place of #{@observer_command}, from any directory. " <>
      "In an Insider checkout: run #{@observer_command} from tools/insider_lab, or build the escript there once (mix escript.build) and run ./insider-lab live. " <>
      "Every form takes the same operations, flags and output. Set N=(--node NAME@HOST --cookie-file PATH) (the cookie file must be mode 0600). " <>
      "Parse stdout alone: it carries only the JSON, and Mix prints its Compiling and \"Waiting for lock on the build directory\" notices on stderr, which a tool that merges the two streams puts in front of the JSON. " <>
      "With several agents, or such a tool, use the escript: it prints no Mix notices and never waits on Mix's build lock.",
    "2. First contact with a node: #{@observer_command} capabilities \"${N[@]}\" --load. --load pushes the observer's own Insider into a development, test or ci node without Insider, or starts this build where it is loaded. " <>
      "If a later command fails with insider_missing or insider_not_started, repeat it with --load. " <>
      "--load never replaces another Insider: insider_version_mismatch and load_build_differs need --force-load, which ends any session, so save its evidence (events, digest, handoff) first.",
    "3. Check that the welcome's runtime.allowed is true. One session exists per node: if active_session_id is set, join it (events --cursor latest --reader NAME) rather than stopping it.",
    "4. Start one session. Without options it is quiet: Logger warning and above, OTP crash and supervisor reports, and runtime.quiet_default_telemetry_events. " <>
      "Recording options (components, events, measurements, filters) apply to every reader of the session, and amend changes them without losing history; a --view-* flag narrows only your own read.",
    "5. Measurements are opt-in in the strict profile (runtime.disclosure_profile strict, the ci default): a Telemetry event carries no duration unless you start with --telemetry-measurement duration. The rich profile returns every measurement unless that flag selects some. EVENT below is a dotted event name such as phoenix.endpoint.stop; discover lists the names the node can emit. " <>
      "Leave --telemetry-event out to record the node's quiet default events: start lists the defaults this node lacks under telemetry_skipped_defaults, and telemetry_hint says when none exists.",
    "6. Act (send the request, run the job), then digest the session for the overview (crash loops, top errors, slowest operations with exemplar receipts to open, Logger bursts, VM changes; --human for a summary to paste for the developer), trends to see how summaries moved across their windows, and read events from cursor 0 (or latest, to join without the history) for detail, passing next_cursor to the next read. Reads and digests renew the lease; --format compact prints one line per event; --reader NAME lists you in status.",
    "7. Pairing with a programmer who acts in the app: mark the moment first (mark \"${N[@]}\" --session SESSION_ID --label 'about to click Confirm'), " <>
      "ask them to act, then digest \"${N[@]}\" --session SESSION_ID --since-mark --human reads only what came after the mark: no time or cursor to guess.",
    "8. Silence is not inactivity: check filtered and gaps in every batch before you conclude that nothing happened.",
    "9. Stop when you are done and check the receipt; an abandoned session stops when its lease expires. " <>
      "stop refuses with readers_active while another named reader read within #{@reader_active_s} s (--force stops anyway), and a stopped session stays readable for #{@stopped_readable_s} s so peers can drain it.",
    "10. Report Insider bugs and anything that differs from this document with report. help OPERATION shows one command's flags; welcome --full is the whole reference; tandem says how agents share a session."
  ]
  @quick_start_commands [
    "#{@observer_command} start \"${N[@]}\" --component logger --component telemetry --telemetry-event EVENT --telemetry-measurement duration --lease-ms 300000",
    "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID",
    "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 0 --limit 100",
    "#{@observer_command} watch \"${N[@]}\" --session SESSION_ID --for 60s",
    "#{@observer_command} stop \"${N[@]}\" --session SESSION_ID",
    "#{@observer_command} report --category doc_mismatch --message 'welcome says X; observed Y'"
  ]
  @quick_start_load "#{@observer_command} capabilities \"${N[@]}\" --load"
  @tandem_commands [
    "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor latest --reader agent-b",
    "#{@observer_command} status \"${N[@]}\" --session SESSION_ID",
    "#{@observer_command} amend \"${N[@]}\" --session SESSION_ID --telemetry-measurement duration --reader agent-a",
    "#{@observer_command} stop \"${N[@]}\" --session SESSION_ID --reader agent-a",
    "#{@observer_command} handoff \"${N[@]}\" --session SESSION_ID"
  ]

  # The tools that pair well with Insider, when to reach for each, and how to
  # tell it is there. `detect` is how the agent checks; `"probe"` is what
  # `available_pairs/0` checks on this node: a module already loaded (as
  # Insider's `--load` pushes recon from a binary) or its beam on the code
  # path (looked up, never loaded), or an executable on PATH (never run).
  @pairs_with [
    %{
      "tool" => "credo",
      "for_agents" => true,
      "use_for" =>
        "static style and consistency rules: the place for code-shape checks Insider leaves out",
      "detect" => "\"credo\" in mix.lock, or mix help credo succeeds",
      "run" => "mix credo --strict",
      "probe" => {:module, Credo}
    },
    %{
      "tool" => "argus",
      "for_agents" => true,
      "use_for" =>
        "A static analysis of compiled beams: OTP startup, shutdown and supervision structure, races, " <>
          "swallowed failures, unanswered messages, effects inside a transaction, ETS ownership, exposed secrets " <>
          "(argus list names every analysis)",
      "detect" => "an argus executable on PATH (argus version); it needs souffle on PATH",
      "run" =>
        "mix compile, then argus analyze --project beams --root . --ebin _build/dev/lib/APP/ebin " <>
          "--dep-ebin DEP_EBIN --analyses default,effects,ets,exposure --format json " <>
          "(the default set alone leaves out effects, ets and exposure); it reads the beams and never builds",
      "probe" => {:executable, "argus"}
    },
    %{
      "tool" => "recon",
      "for_agents" => true,
      "use_for" =>
        "live process, memory, allocator and port inspection beyond Insider's bounded process, bin_leak, ports and alloc reads",
      "detect" => "\"recon\" in mix.lock, or runtime.pairs_with_available.recon",
      "run" =>
        "in the node, through Tidewave project_eval or a remote shell, such as :recon.proc_count(:message_queue_len, 10)",
      "probe" => {:module, :recon}
    },
    %{
      "tool" => "tidewave",
      "for_agents" => true,
      "use_for" =>
        "evaluating code and reading logs in the running dev node (project_eval, get_logs) when Insider's evidence needs a why",
      "detect" => "\"tidewave\" in mix.lock, and the dev server answers at /tidewave/mcp",
      "run" => "an MCP tools/call of project_eval at http://HOST:PORT/tidewave/mcp",
      "probe" => {:module, Tidewave}
    },
    %{
      "tool" => "observer_cli",
      "for_agents" => false,
      "use_for" =>
        "a terminal UI for a human watching the node, not for agents (rated 2/5 for agents): prefer digest, trends and process",
      "detect" => "\"observer_cli\" in mix.lock",
      "run" => ":observer_cli.start() in an IEx shell on the node",
      "probe" => {:module, :observer_cli}
    }
  ]

  # Symptom recipes: which session to start and what to read for a symptom.
  @recipes [
    %{
      "symptom" => "triage: what is wrong right now",
      "commands" => [
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID --since latest-1000 --human"
      ],
      "look_for" =>
        "Start every investigation with a digest of the running session (start one with start \"${N[@]}\" if active_session_id is null, then act). " <>
          "Read its anomalies first: each is one line with the next command to run (--human prints them right after the first line). " <>
          "A Note: first line says your reader's stored view (kept with --view-keep) narrowed the read; --view-clear removes it. " <>
          "crash_loops names each restarting child with its period_ms and reason_fingerprint; error_signatures groups the errors by kind, " <>
          "offender, exception module and message head; latency lists the slowest Telemetry kinds (p50_us, p95_us, max_us); processes the longest mailboxes; " <>
          "vm the change of each VM metric over the window; filtered and gaps what was not recorded or lost. --human prints the same as a few lines for the developer. " <>
          "Then read the events behind a finding with events --view-kind KIND."
    },
    %{
      "symptom" => "latency: requests, jobs or calls are slow",
      "commands" => [
        "#{@observer_command} start \"${N[@]}\" --component telemetry --telemetry-event phoenix.endpoint.stop --telemetry-measurement duration --telemetry-summary phoenix.endpoint.stop --telemetry-summary-interval-ms 5000",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID",
        "#{@observer_command} trends \"${N[@]}\" --session SESSION_ID --human",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 41 --limit 1"
      ],
      "look_for" =>
        "Summarise the stop event of the slow operation (phoenix.endpoint.stop, a repo's query event, or your own span's stop event). " <>
          "The digest's latency table has one row per summarised or timed kind, slowest p95 first, with the summary intervals and exemplars: " <>
          "the receipts of the window's slowest summarised events (at most 3 per interval) and its first error. Open one by reading from the receipt before it: " <>
          "for exemplar receipt 42, events --cursor 41 --limit 1. Its metadata holds the outcome, such as the exit reason. " <>
          "Each interval records one summary event: event.attributes.summary has count, errors, duration_p50_us, duration_p95_us, duration_max_us, " <>
          "window_started_at, window_ended_at, exemplars, exemplars_lost, first_error_retained and duration_scope; " <>
          "a recorded event carries its durations in microseconds under event.attributes.durations_us. " <>
          "exemplars_lost counts the interval's candidates lost under load; first_error_retained false means the first error was lost, " <>
          "so the exemplars do not show it; the gap telemetry_exemplar_lost counts them since your cursor. " <>
          "trends shows each kind's windows and whether rate, p95 and errors rose, fell or stayed flat. " <>
          "duration_scope.measured_in is unknown unless you declare it at start: --telemetry-duration-scope KIND=handler for a kind " <>
          "timed inside the code that handles the operation, KIND=caller for one timed by the code that waits for it. " <>
          "duration_scope.emitter only says which process emitted the exemplars (an OTP server's module, or a plain process); " <>
          "it does not tell what the duration measured, since a server can itself be the caller of another. " <>
          "When one declared handler kind and one declared caller kind describe the same operation, a caller p95 above the handler p95 " <>
          "is time outside the handler, such as queueing; Insider cannot check that they do. " <>
          "Durations pinned near 5000000 us suggest GenServer.call timeouts; a row's call_timeouts counts the failing events that carry the exit " <>
          "{:timeout, {GenServer, :call, _}}, which is the evidence."
    },
    %{
      "symptom" => "log flood: the same error is logged over and over",
      "commands" => [
        "#{@observer_command} start \"${N[@]}\" --component logger --logger-level info --logger-summary module:MyApp.Checkout --logger-summary-interval-ms 5000",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID --human",
        "#{@observer_command} trends \"${N[@]}\" --session SESSION_ID --kind logger_summary"
      ],
      "look_for" =>
        "--logger-summary RULE counts the matching Logger messages per message template, call site and level instead of recording each one, " <>
          "so a flood neither fills the Recorder nor evicts other evidence; crash and supervisor reports are still recorded. " <>
          "The template is the message (or a {format, args} message's format) with numbers, pids and hex masked, so the same message " <>
          "with different values is one burst and two messages from one logging helper are two. " <>
          "Each interval records one logger_summary event per burst: event.attributes.summary has count, level, template, " <>
          "template_fingerprint, call_site (module, function, line), call_site_fingerprint and exemplar_receipt, the receipt of that " <>
          "interval's first message, recorded in full (exemplar_lost true when it was lost). " <>
          "At most 64 bursts are told apart per interval; beyond that each level's messages fold into one overflow row " <>
          "(overflow true, distinct_lost the folded distinctions), and the gaps logger_summary_overflow and logger_exemplar_lost count the losses. " <>
          "The digest's logger_bursts and trends list each burst's count per window; filtered.logger.summarized counts the folded messages."
    },
    %{
      "symptom" => "crash loop: a process keeps restarting",
      "commands" => [
        "#{@observer_command} start \"${N[@]}\" --component logger",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID",
        "#{@observer_command} amend \"${N[@]}\" --session SESSION_ID --component logger --component calls --calls MOD.FUN/ARITY --calls-results exceptions",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 1811 --view-kind call.exception",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 0 --view-kind supervisor_child_terminated"
      ],
      "look_for" =>
        "Trace the crashing function to see its failing call's arguments and exception: the digest's hints (kind trace_calls) give the exact " <>
          "amend command, with MOD.FUN/ARITY taken from the crash's stack (else the child's GenServer callbacks) and the session's components kept; " <>
          "an events read that shows a crash carries the same hint, and --format compact prints it as a # hint: line. " <>
          "Call tracing needs OTP 28 or later; on OTP 27 the hint (kind trace_calls_unavailable) says so and gives the recon_trace call to run by hand. " <>
          "After the amendment, the next crash records call.exception with the arguments and exception, and the digest's calls lists it. " <>
          "Read them from the amendment's receipt: --cursor is amend's result.amendment.marker_receipt (1811 here), so the read starts at the amendment " <>
          "and keeps every later call.exception (cursor latest would start after them); read on from next_cursor while truncated_by is scan_limit. " <>
          "The quiet defaults record OTP supervisor reports. The digest's crash_loops lists each child terminated at least twice for the same reason: " <>
          "offender, restart_type, reason_fingerprint, restarts, and period_ms (the median gap between their wall times). " <>
          "In each supervisor_child_terminated event, event.attributes.offender_id is the child, " <>
          "restart_type its restart type, and reason_fingerprint the reason (the same fingerprint means the same reason). " <>
          "The period is the gap between successive event.wall_time values."
    },
    %{
      "symptom" => "lost events: the digest says Lost: evicted",
      "commands" => [
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID --human",
        "#{@observer_command} amend \"${N[@]}\" --session SESSION_ID --logger-summary module:MyApp.Checkout",
        "#{@observer_command} status \"${N[@]}\" --session SESSION_ID"
      ],
      "look_for" =>
        "The Recorder holds max_events events, shared out by source (recorder.source_shares_percent); a source over its share evicts its own oldest. " <>
          "The digest's hints name each source that evicted (status recorder.sources: evicted, retained_events, reserved_events, share_percent) " <>
          "and the amendment that stops it: reduce_logger summarises the module (else domain) that logged most with --logger-summary, " <>
          "reduce_telemetry summarises the kind recorded most with --telemetry-summary, reduce_poller samples less often, and raise_capacity " <>
          "raises --max-events when the Recorder is below its bound. An amendment starts a new Recorder segment, so each source's evicted count " <>
          "starts again at 0: status after the next flood shows whether the amendment stopped it. " <>
          "Several readers share the one Recorder and a read keeps nothing, so with more readers (or spans from other services) it evicts sooner " <>
          "for all of them (the shared_readers hint): read digest and trends rather than every event, summarise frequent kinds, and read often."
    },
    %{
      "symptom" => "5xx: requests fail with a server error",
      "commands" => [
        "#{@observer_command} start \"${N[@]}\" --component logger --component otel --component telemetry --telemetry-event phoenix.endpoint.stop --telemetry-event phoenix.router_dispatch.exception --telemetry-measurement duration",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 0 --view-kind phoenix.endpoint.stop --view-kind phoenix.router_dispatch.exception --view-kind otel.span --view-min-severity error",
        "#{@observer_command} trace \"${N[@]}\" --session SESSION_ID --trace-id TRACE_ID --human"
      ],
      "look_for" =>
        "The digest's error_signatures groups the failures by kind, exception module and status. " <>
          "A 5xx phoenix.endpoint.stop, every phoenix.router_dispatch.exception, and every span whose status is error are severity error (see severity), so this view shows only failing requests. " <>
          "Take event.causality.trace_id of a failing one and read its trace: the request's span tree with the Logger lines and Telemetry events of the same trace, in time order; " <>
          "the error span's attributes.status_message (rich) says what failed, and unjoined says what could not be joined. " <>
          "Without OpenTelemetry on the node, start without --component otel and read the failing request's timeline with --pid event.subject.value. " <>
          "In the rich profile event.payload.metadata carries the conn and the exception's kind and reason."
    },
    %{
      "symptom" =>
        "GraphQL error in a 200: the response is HTTP 200 but the operation failed or its payload reports validation errors",
      "commands" => [
        "#{@observer_command} start \"${N[@]}\" --component logger --component otel --component telemetry --telemetry-event absinthe.execute.operation.stop",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 0 --view-kind absinthe.execute.operation.stop --view-kind otel.span --view-min-severity warning --format compact",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID --human",
        "#{@observer_command} trace \"${N[@]}\" --session SESSION_ID --trace-id TRACE_ID --human --collapse sql --hide auth"
      ],
      "look_for" =>
        "Absinthe's absinthe.execute.operation.stop (a quiet default when Absinthe is loaded) and the operation's span carry attributes.graphql, " <>
          "the value-free outcome: operation_type, operation_name, result (ok, user_errors, partial or errors), error_count with error_codes " <>
          "and error_paths, and, for a payload's own validation errors, user_error_count with user_error_fields (never messages or values). " <>
          "GraphQL errors are severity error and payload validation errors warning, whatever the HTTP status; the digest's error_signatures " <>
          "group both by operation, result, codes, paths and fields. The compact line shows graphql=TYPE:NAME result=... types=[...] and, in rich, args=, actor= and client=; a span's " <>
          "line shows trace=TRACE_ID, and the trace's text is the span tree with each span's duration and outcome. Under strict only the type, " <>
          "result and counts pass."
    },
    %{
      "symptom" => "slow request: one request takes too long and you need to know where",
      "commands" => [
        "#{@observer_command} start \"${N[@]}\" --component logger --component otel --component telemetry --telemetry-event phoenix.endpoint.stop --telemetry-measurement duration --logger-level info",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 0 --view-kind phoenix.endpoint.stop",
        "#{@observer_command} trace \"${N[@]}\" --session SESSION_ID --trace-id TRACE_ID --human",
        "#{@observer_command} timeline \"${N[@]}\" --session SESSION_ID --request-id REQUEST_ID --human"
      ],
      "look_for" =>
        "The digest's latency table gives the stop event's p50, p95 and max. " <>
          "Find the slow request's phoenix.endpoint.stop (attributes.measurements.duration) and its event.causality.trace_id, then read the trace: " <>
          "each span has attributes.duration_us and its depth in the tree, so the longest child of the root (a resolver, a repo query, an outbound call) is where the time went; " <>
          "many short repo query spans under one resolver are an N+1: repeated_queries (and the text's first lines) group the request's queries by table and statement shape across the whole tree, with their caller and total time. " <>
          "The text rendering (--human) shows each span's offset from the request start. " <>
          "If the node has no OpenTelemetry, use timeline with the request's id (Logger metadata request_id) or its pid."
    },
    %{
      "symptom" => "app hangs: pages stall for seconds now and then, but each request looks fast",
      "commands" => [
        "#{@observer_command} start \"${N[@]}\" --component logger --component otel --component telemetry",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID --since latest-5m --human",
        "#{@observer_command} trace \"${N[@]}\" --session SESSION_ID --trace-id TRACE_ID --human --collapse sql",
        "#{@observer_command} process \"${N[@]}\" --name Phoenix.CodeReloader.Server"
      ],
      "look_for" =>
        "The quiet defaults record the web server's request stop (bandit.request.stop, or cowboy.request.stop) beside " <>
          "phoenix.endpoint.stop, so the digest's Pre-handler waits line names the requests that waited before Phoenix's " <>
          "endpoint telemetry began (in dev the code reloader and every plug before Plug.Telemetry run there, so the " <>
          "endpoint's own duration looks fast), and its Request burst line flags arrivals far over the usual rate with " <>
          "their top sources (user agent or address in the rich profile, else traced and untraced counts) and the other " <>
          "requests they overlapped: a burst from another client that lines up with your waits is the trigger. A trace or " <>
          "timeline of a waiting request shows a Wait: line. Insider's inspection (process, digest, events, trace) runs " <>
          "over Erlang distribution, not through the HTTP request path, so it keeps answering while requests are stalled: " <>
          "inspect Phoenix.CodeReloader.Server (its message queue and current stacktrace) during a stall. Tools that " <>
          "reach the node over HTTP (Tidewave's project_eval) queue behind the same plugs."
    },
    %{
      "symptom" =>
        "follow a frontend action: one page load or form submit, from the Next.js server into this node",
      "commands" => [
        "#{@observer_command} start \"${N[@]}\" --component logger --component otel --lease-ms 300000",
        "#{@observer_command} otlp-receive \"${N[@]}\" --session SESSION_ID",
        "#{@observer_command} trace \"${N[@]}\" --session SESSION_ID --trace-id TRACE_ID --human"
      ],
      "look_for" =>
        "Keep otlp-receive running (it listens on 127.0.0.1:4318) and start the frontend's next dev with " <>
          "INSIDER_OTLP_ENDPOINT=http://127.0.0.1:4318/v1/traces and NEXT_PUBLIC_API_HOST pointing at this node. " <>
          "Do the action; the frontend's dev log may print each request's trace id, and " <>
          "each export line of otlp-receive lists its trace ids. Read that trace: spans with " <>
          "attributes.service set to the frontend's service name (capture ingest) are the Next.js server, the others are this node's " <>
          "(capture sdk); the Next fetch span to this node is the parent of this node's request span."
    },
    %{
      "symptom" => "growing mailbox: slower the longer it runs, calls time out",
      "commands" => [
        "#{@observer_command} start \"${N[@]}\" --component logger --component poller",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 0 --view-kind process_top",
        "#{@observer_command} amend \"${N[@]}\" --session SESSION_ID --watch-process NAME --poller-interval-ms 1000",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 0 --view-kind process_watch",
        "#{@observer_command} process \"${N[@]}\" --name NAME"
      ],
      "look_for" =>
        "The digest's processes lists the longest mailboxes the process_top events saw, with message_queue_len now, at the window's first sample, and its max. " <>
          "Each poller interval (poller_interval_ms, 5000 by default) records one process_top event. " <>
          "event.attributes.metrics.by_message_queue_len ranks the processes with waiting messages; each entry has name, initial_call, " <>
          "current_function (where it is now), message_queue_len, memory_bytes and reductions_delta (work since the previous scan, window_ms). " <>
          "A process whose message_queue_len grows from one process_top to the next is backed up; GenServer.call timeouts (durations near 5000000 us) are its callers. " <>
          "To follow it, amend the session with --watch-process NAME, where NAME is that entry's name, such as MyApp.Worker; " <>
          "the session keeps its id, history and cursors. " <>
          "Every interval then records a process_watch event for it. " <>
          "Insider's own processes are never ranked; they are summed under metrics.insider. " <>
          "process --name NAME then shows where it is (stacktrace.frames with file and line) and what waits: mailbox.shapes counts the queued " <>
          "messages by shape, such as {:\"$gen_call\", {pid, list}, {:price, binary}} for GenServer.call({:price, _}), and mailbox.calls.callers_exited " <>
          "counts calls whose callers already gave up: the server is answering callers that timed out."
    },
    %{
      "symptom" => "memory growth: ets_bytes or process memory keeps rising",
      "commands" => [
        "#{@observer_command} start \"${N[@]}\" --component poller",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 0 --view-kind vm_sample --view-kind ets_top --view-kind process_top"
      ],
      "look_for" =>
        "The digest's vm gives the change of each VM metric over the window, so a rising ets_bytes or processes_bytes shows at once. " <>
          "vm_sample carries insider_ets_bytes and insider_processes_bytes next to ets_bytes and processes_bytes: Insider's own Recorder buffer grows with every session, so subtract them first. " <>
          "ets_top ranks the application's tables by_memory and by_size, each with its table name and owner; process_top ranks processes by_memory. " <>
          "A table or process that keeps growing across samples is the leak; Insider's own tables and processes are under metrics.insider and never ranked."
    },
    %{
      "symptom" => "binary leak: binary memory keeps rising, a process holds large binaries",
      "commands" => [
        "#{@observer_command} start \"${N[@]}\" --component poller",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID",
        "#{@observer_command} bin_leak \"${N[@]}\" --top 5",
        "#{@observer_command} process \"${N[@]}\" --name NAME",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 0 --view-kind inspect.bin_leak --view-kind vm_sample"
      ],
      "look_for" =>
        "The digest's vm shows binary_bytes rising. bin_leak garbage-collects every unprotected process and names biggest_holder, " <>
          "the process that still references the most binary bytes after it (name, initial_call, binary_bytes_after, freed_bytes); " <>
          "by_retained_bytes ranks the rest of the holders with binary_bytes_before and binary_bytes_after (--human prints them first). " <>
          "A process that stays first with freed_bytes near 0, and grows when you run bin_leak again a little later, keeps its binaries on purpose: " <>
          "a list or map of small sub-binaries (binary_part, pattern-matched slices) pins each large binary it came from. " <>
          "by_freed_bytes is the opposite case, garbage not yet collected. process --name NAME gives that holder's binaries count and bytes " <>
          "and its stacktrace. Each bin_leak in a session is an inspect.bin_leak event, so the series can be read back; Insider's own processes are under insider."
    },
    %{
      "symptom" => "port leak: port_count or OS processes keep rising",
      "commands" => [
        "#{@observer_command} start \"${N[@]}\" --component logger --component poller --top-ports 5 --poller-interval-ms 2000",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 0 --view-kind port_top",
        "#{@observer_command} ports \"${N[@]}\" --type TYPE",
        "#{@observer_command} process \"${N[@]}\" --name NAME"
      ],
      "look_for" =>
        "The digest's vm shows port_count rising. Each poller interval records a port_top event: metrics.by_type counts the ports by type " <>
          "(the first word of the port name, such as cat or tcp_inet) with os_process_count and delta, the change since the previous census; " <>
          "port_count_delta and window_ms give the node's growth; by_owner names the processes holding the most ports with their top_type. " <>
          "A type whose delta stays positive is the leak. ports --type TYPE lists those ports with owner, owner_pid and os_pid, and owners ranks who opened them; " <>
          "process --name NAME on the owner shows links.ports (each open port is linked) and, in its mailbox shapes, unhandled port data " <>
          "such as {port, {:data, binary}}. Insider's own ports are counted under metrics.insider."
    },
    %{
      "symptom" =>
        "growth over time: ports, binary memory or a mailbox keep rising and you need the rate",
      "commands" => [
        "#{@observer_command} start \"${N[@]}\" --component poller --poller-interval-ms 5000 --watch-process NAME",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID --human",
        "#{@observer_command} trends \"${N[@]}\" --session SESSION_ID --kind vm_sample --kind port_top --kind process_watch --human",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 0 --view-kind port_top --format compact"
      ],
      "look_for" =>
        "trends' poller lists one series per sample: binary_bytes and port_count (vm_sample), ports per type (port_top), " <>
          "and message_queue_len per process, from process_top rankings (coverage ranked: no point where the process was not ranked) " <>
          "or a watched process (coverage watched: every point a direct sample; mixed: ranked stretches keep their gaps). " <>
          "A port type counts zero only at a complete census (no scan_limit); an incomplete one gives a missing type no point. " <>
          "Each has unit, change (first, last, delta, direction), " <>
          "per_min (growth per minute between the first and last sample) and max; a rising series with a steady per_min is a leak or backlog, " <>
          "not a spike. --format compact prints each port_top, ets_top and process_top ranking on one line."
    },
    %{
      "symptom" => "missing values: events lack a measurement, an event, or log lines you need",
      "commands" => [
        "#{@observer_command} amend \"${N[@]}\" --session SESSION_ID --telemetry-measurement duration",
        "#{@observer_command} amend \"${N[@]}\" --session SESSION_ID --component logger --component telemetry --telemetry-event EVENT --logger-level info",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 0 --view-kind live.session_amended"
      ],
      "look_for" =>
        "Do not stop and restart: amend changes the recording options of the running session and keeps its history and every reader's cursor. " <>
          "Each flag given replaces that option (a repeated flag replaces the whole list, so name every component you still need: " <>
          "add --component poller to keep the process evidence of a growing-mailbox investigation, whose poller options return to their defaults otherwise), " <>
          "and --reset FLAG, such as --reset watch-process, returns one option to its default. " <>
          "The next receipt is a live.session_amended event (every view shows it): attributes.changed, from, to, and uncollected_ms, the pause in collection. " <>
          "A Telemetry event's redactions name a measurement it did not record."
    },
    %{
      "symptom" => "several agents: another agent runs or reads the session",
      "commands" => [
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor latest --reader agent-b",
        "#{@observer_command} status \"${N[@]}\" --session SESSION_ID",
        "#{@observer_command} handoff \"${N[@]}\" --session SESSION_ID",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID --reader agent-b --view-exclude-signature MyApp.Auth.JwksStrategy --human",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor latest --reader agent-b --view-route /marketplace"
      ],
      "look_for" =>
        "A known error another agent or the environment keeps raising: hide it in your own view with --view-exclude-signature " <>
          "(digest error_signatures[].id, a crash loop's reason_fingerprint, or the module, which hides every report of a crash loop); the other agent's traffic: keep only your routes, services or traces. " <>
          "filtered.view counts what your view hid. Join with your own --reader name; status.readers shows each reader's cursor, behind, last_seen_ms_ago and subscribed. " <>
          "Readers share one Recorder and a read keeps nothing, so every reader adds pressure: prefer digest and trends, summarise frequent kinds, " <>
          "and read often (the digest's shared_readers hint says when evictions hit several readers). " <>
          "Recording options are shared, so amend changes them for everyone; views are yours. " <>
          "stop with --reader refuses (readers_active) while another named reader is active; after a stop, events still reads until readable_until. " <>
          "handoff prints what a peer needs to continue: node, welcome hash, session id, configuration, and each reader's cursor."
    },
    %{
      "symptom" => "pairing: the programmer clicks in the app while you watch",
      "commands" => [
        "#{@observer_command} chart \"${N[@]}\" --session SESSION_ID --serve",
        "#{@observer_command} mark \"${N[@]}\" --session SESSION_ID --label 'about to click Confirm' --reader agent-a",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID --since-mark --human",
        "#{@observer_command} marks \"${N[@]}\" --session SESSION_ID --human"
      ],
      "look_for" =>
        "Start chart --serve and give the programmer the URL it prints (127.0.0.1 only): it shows requests, waits, errors and the marks as they happen, " <>
          "and stops after --for or when the session ends; it never renews the lease. " <>
          "Mark right before each action, with a label that says what is about to happen, then ask the programmer to act and say when they are done. " <>
          "digest --since-mark reads only what came after the newest mark: its Window line names the mark, its time and age; " <>
          "Nothing recorded since the mark means the action has not happened yet, or this session does not record it (check filtered, or amend). " <>
          "--since-mark LABEL reads from an earlier mark; events --since-mark --format compact lists each event after it, " <>
          "and timeline --request-id ID --since-mark one request's. One mark per action keeps each read small; marks lists them."
    },
    %{
      "symptom" => "unknown event names: you do not know which Telemetry events the node emits",
      "commands" => [
        "#{@observer_command} discover \"${N[@]}\" --prefix my_app",
        "#{@observer_command} start \"${N[@]}\" --component telemetry --telemetry-event 'my_app.*' --telemetry-measurement duration --telemetry-min-duration-ms 0",
        "#{@observer_command} status \"${N[@]}\" --session SESSION_ID"
      ],
      "look_for" =>
        "discover lists each event name with its sources: handler (a handler is attached), execute or span (a literal event list in a loaded module's " <>
          ":telemetry.execute or :telemetry.span call; a span gives its start, stop and exception events), and the module. " <>
          "Names built at run time appear only once a handler is attached; truncated_by says whether a bound cut the scan. " <>
          "--telemetry-event PREFIX.* subscribes to every discovered name below the prefix when the session starts or is amended (quote it for the shell); " <>
          "the start result lists them under telemetry_event_prefixes, and they count against bounds.telemetry_events_max. " <>
          "status lists telemetry_subscriptions: state subscribed with seen 0 means the handler is attached and the event has not been emitted since the start or the last amend. " <>
          "An event with seen above 0 that you do not read was filtered (check filtered: min_duration, origin, summarized) or hidden by your view."
    },
    %{
      "symptom" => "failing call: why does this call fail, and with what arguments",
      "commands" => [
        "#{@observer_command} start \"${N[@]}\" --component logger --component calls --calls MyApp.Worker.handle_call/3",
        "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID",
        "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 0 --view-kind call.exception",
        "#{@observer_command} stop \"${N[@]}\" --session SESSION_ID"
      ],
      "look_for" =>
        "Trace the function a crash report or stacktrace names, as MOD.FUN/ARITY (its module must be loaded; amend adds the calls component to a running session). " <>
          "The trace belongs to the session, not to your command: it is removed at stop, at lease expiry and at amend, and the receipt's cleanup.call_trace " <>
          "lists the functions with traced_after 0. Each traced call is a call event (attributes.function and call_id; in the rich profile payload.arguments, " <>
          "rendered with credentials masked and capped at calls_max_bytes). Each call that raises, exits or throws is a call.exception (severity error) " <>
          "with the same call_id, duration_us, class and exception (such as ArithmeticError), and in rich payload.reason and payload.arguments: the arguments that failed. " <>
          "--calls-results all also records each return as call.return with payload.result; none records calls only. " <>
          "The digest's calls lists each function's calls, returns and exceptions, and each failure with the arguments of its first call. " <>
          "After calls_max calls no new call is traced but the results of running calls are still recorded; more than calls_rate_max trace messages " <>
          "within calls_rate_ms stop the trace; either records a call.stopped event with the reason. On OTP 27 the calls component is refused " <>
          "(component_unavailable, reason requires_otp_28)."
    }
  ]

  @disclosure_means %{
    "rich" =>
      "Events leave the node with their payloads: Logger message text and metadata, Telemetry metadata and measurements, rendered within bounds. Credentials are masked.",
    "strict" =>
      "Event payloads, Logger message text, and Telemetry metadata never leave the node; only allowlisted numeric measurements and W3C-shaped trace ids do. Credentials are masked."
  }

  @doc """
  The welcome document for this node's `runtime` facts. By default it is the
  agent quick start: the steps, the core commands, the symptom recipes, and
  where to read the full reference. With `full?` it is the whole hashed
  contract. Both carry the contract's hash.
  """
  @spec document(map(), boolean()) :: map()
  def document(runtime, full? \\ false)

  def document(runtime, true) when is_map(runtime) do
    contract = contract()

    Map.merge(contract, %{
      "hash" => hash(contract),
      "effective_disclosure" => effective_disclosure(runtime),
      "runtime" => runtime
    })
  end

  def document(runtime, false) when is_map(runtime) do
    contract = contract()

    contract
    |> Map.take(["summary", "insider", "quick_start", "recipes", "tandem", "pairs_with"])
    |> Map.merge(%{
      "schema" => @quick_start_schema,
      "hash" => hash(contract),
      "hash_covers" =>
        "the full reference (#{@schema}, welcome --full): every key except hash, runtime and effective_disclosure",
      "full_reference" => full_reference(),
      "effective_disclosure" => effective_disclosure(runtime),
      "runtime" => runtime
    })
  end

  # The profile this node discloses with now, stated before any rule that
  # depends on it. Like `runtime`, it is outside the hash.
  defp effective_disclosure(%{"disclosure_profile" => profile} = runtime)
       when profile in ["rich", "strict"] do
    %{
      "profile" => profile,
      "source" => runtime["disclosure_profile_source"],
      "means" => Map.fetch!(@disclosure_means, profile),
      "rules" =>
        "disclosure.rules.#{profile} and disclosure.rules.every_profile in welcome --full"
    }
  end

  defp effective_disclosure(_runtime), do: nil

  @doc "The full reference's schema."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc """
  Which of the tools in `pairs_with` this node has: a module already loaded
  (from a file, or from a binary such as the recon `--load` pushes) or its
  beam on the code path (looked up, never loaded), or an executable on PATH
  (never run).
  """
  @spec available_pairs() :: %{String.t() => boolean()}
  def available_pairs do
    Map.new(@pairs_with, fn %{"tool" => tool, "probe" => probe} -> {tool, available?(probe)} end)
  end

  defp available?({:module, module}) do
    :code.is_loaded(module) != false or
      is_list(:code.where_is_file(~c"#{Atom.to_string(module)}.beam"))
  end

  defp available?({:executable, name}), do: is_binary(System.find_executable(name))

  @doc "The quick start's schema, the default welcome."
  @spec quick_start_schema() :: String.t()
  def quick_start_schema, do: @quick_start_schema

  @doc "The hash of the current contract."
  @spec hash() :: String.t()
  def hash, do: hash(contract())

  defp hash(contract), do: Canonical.sha256(contract)
  @doc "Where capabilities point an agent that has not read the document."
  @spec pointer() :: map()
  def pointer do
    %{
      "schema" => @quick_start_schema,
      "hash" => hash(),
      "read_with" => %{
        "elixir" => "Insider.Live.welcome()",
        "json" => "Insider.Live.JSON.welcome()",
        "observer" => "#{@observer_command} welcome #{@target_placeholder}"
      },
      "full_reference" => full_reference(),
      "note" =>
        "Read the welcome quick start before acting. Its full reference lists every operation, option, " <>
          "bound, and error code, and how to report Insider bugs and behaviour that differs from it."
    }
  end

  defp full_reference do
    %{
      "schema" => @schema,
      "observer" => "#{@observer_command} welcome #{@target_placeholder} --full",
      "elixir" => "Insider.Live.welcome(%{\"full\" => true})",
      "json" => "Insider.Live.JSON.welcome(%{\"full\" => true})",
      "help" => "#{@observer_command} help OPERATION",
      "covers" =>
        "every operation, option (with the observer's value syntax), default, bound, and error code " <>
          "of the target and the observer, the filters, the disclosure rules, the costs, and the report duty"
    }
  end

  @spec operations() :: [map()]
  def operations, do: @operations

  @spec observer_commands() :: [map()]
  def observer_commands, do: @observer_commands

  @spec observer_target_flags() :: [String.t()]
  def observer_target_flags, do: @observer_target_flags

  @doc "The observer commands that neither carry nor deliver the welcome quick start."
  @spec observer_receipts() :: [String.t()]
  def observer_receipts, do: @observer_receipts

  @doc "The observer's error codes: code => {status, message}."
  @spec observer_errors() :: %{String.t() => {String.t(), String.t()}}
  def observer_errors, do: @observer_errors

  @doc "The observer's exit status for each status name."
  @spec observer_exit_statuses() :: %{String.t() => non_neg_integer()}
  def observer_exit_statuses, do: @observer_exit_statuses

  @doc "Every command of the quick start and the recipes, in order."
  @spec example_commands() :: [String.t()]
  def example_commands do
    [@quick_start_load | @quick_start_commands] ++
      Enum.flat_map(@recipes, & &1["commands"]) ++
      @tandem_commands ++
      Enum.flat_map(@observer_commands, & &1["examples"]) ++
      transports()["observer"]["examples"]
  end

  @doc """
  The value each observer flag takes, the `Insider.Live` option it sets
  (`nil` for the observer's own flags), and whether it repeats. A flag that
  means something else for one command has an entry under `"commands"`.
  Integer ranges are read from the option tables.
  """
  # Agents name themselves on every command, and refusing `status --reader`
  # only costs retries. Where nothing uses the name it is accepted and ignored.
  @reader_ignored "NAME: accepted so one set of flags fits every command; this command does not use it"

  @spec observer_options() :: %{String.t() => map()}
  def observer_options do
    options = Options.describe()
    start = options["start"]
    read = options["read"]
    subscribe = options["subscribe"]
    view = read["view"]["keys"]

    rule =
      "domain:a.b (a Logger domain prefix), application:NAME, or module:NAME (a module or its namespace)"

    [
      {"--node",
       "NAME@HOST: the target's node name as it registered, such as my_app@$(hostname -s); HOST must be loopback or this machine",
       nil},
      {"--cookie-file",
       "PATH: a regular file, mode 0600 or stricter, holding the target's cookie", nil},
      {"--timeout-ms",
       "INTEGER 1..60000 (default 5000): the bound on connecting and on each remote call", nil},
      {"--load",
       "no value: push this checkout's Insider into a target without Insider and start it, or start this build where it is loaded; never replaces another build (development, test or ci targets only)",
       nil},
      {"--force-load",
       "no value: --load that also replaces another Insider build, started or not, which ends any session; its evidence does not survive, so read and save what you need (events, digest, handoff) first",
       nil},
      {"--full", "no value: print the full reference instead of the quick start", "welcome.full"},
      {"--show-baseline",
       "no value: also list the known-normal anomalies the session's baseline hid, after the new ones",
       "digest.show_baseline"},
      {"--show", "no value: print the baseline without changing it", "baseline.show"},
      {"--clear", "no value: remove the baseline; digests and status show every anomaly again",
       "baseline.clear"},
      {"--session",
       "SESSION_ID: the session_id start returned, such as live-6; without it a read uses the node's active session " <>
         "(stop, amend and otlp-receive still need it)", "session_id"},
      {"--cursor",
       "INTEGER >= 0, or latest: 0 reads from the session start, latest from the newest receipt; then pass the last next_cursor",
       "cursor"},
      {"--limit", integer(read["limit"]) <> ": events returned", "read.limit"},
      {"--max-bytes", integer(read["max_bytes"]) <> ": JSON bytes of the events returned",
       "read.max_bytes"},
      {"--scan-limit",
       integer(read["scan_limit"]) <> ": retained events examined, shown or hidden by the view",
       "read.scan_limit"},
      {"--from-cursor",
       "INTEGER >= 0, or latest: where watch starts (default 0, the session start)",
       "subscribe.cursor"},
      {"--for",
       "DURATION: a whole number followed by ms, s, m, or h, at most 24h, such as 30s; watch or otlp-receive then stops",
       nil},
      {"--port",
       "INTEGER 0..65535 (default 4318, OTLP/HTTP's port): where otlp-receive listens; 0 picks a free port",
       nil},
      {"--out",
       "PATH: a new file where chart writes its page (default a new file under the system temp directory), mode 0600; a path that exists, a symlink included, is refused (invalid_options, problem exists)",
       nil},
      {"--serve",
       "no value: serve the chart live on 127.0.0.1 at a secret URL, refreshing every second, instead of writing a file; it renews no lease",
       nil},
      {"--bind",
       "ADDRESS: a loopback address literal, 127.0.0.1 (default) or ::1; any other address is refused",
       nil},
      {"--format",
       "json | compact | full (default json): json drops the event envelope fields that are null, empty or the same for every event " <>
         "(schema, node, boot_id, clock_id, source_instance_id, source_sequence, monotonic_time, authority, priority, received_at_us); " <>
         "compact prints one line per event (receipt, wall time, source, kind, severity, subject, key attributes; of a rendered conn only " <>
         "method, path and status, and an HTML page such as a debugger page as [html N bytes]) and a # line per batch with the disclosure profile; " <>
         "full prints events exactly as the target returns them", nil},
      {"--since",
       "latest-DURATION, INTEGER >= 0, or latest-N: the window. latest-DURATION (ms, s, m or h, 1 s to 24 h, such as latest-60s) starts at the " <>
         "first event the Recorder admitted that recently (not by the events' own wall times); an integer starts after that receipt " <>
         "(0 is the session start); latest-N is the newest N receipts " <>
         "(N 1..#{options["digest"]["since"]["last_max"]}). Default: latest-60s for digest, 0 (the session start) for trends",
       "digest.since"},
      {"--since-mark",
       "[LABEL]: pairing; read what came after the newest mark (mark), or the newest with this label (quote it). " <>
         "Without a label, the next argument must be another flag, or nothing. On digest and trends in place of --since; " <>
         "an unknown label is mark_not_found, which lists the newest labels", "digest.since"},
      {"--label",
       "TEXT: what is about to happen, such as 'about to click Confirm' (quoted); one line, at most " <>
         "#{options["mark"]["label"]["max_bytes"]} bytes (longer is cut), credential-masked in every profile; " <>
         "more than #{options["mark"]["label"]["input_max_bytes"]} bytes is refused",
       "mark.label"},
      {"--human",
       "no value: print a short plain-text summary for the developer instead of the JSON digest",
       "digest.human"},
      {"--collapse",
       "CATEGORY[,CATEGORY]: sql (database spans and repo query events), auth (authorization and authentication), " <>
         "or a span name or event kind prefix; folds each run of matching siblings in the --human tree into one counted line; " <>
         "repeatable, max #{options["trace"]["collapse"]["max_items"]}", "trace.collapse"},
      {"--hide",
       "CATEGORY[,CATEGORY]: as --collapse; drops matching spans and events from the items and the tree, and what was under " <>
         "a hidden span moves up; repeatable, max #{options["trace"]["hide"]["max_items"]}",
       "trace.hide"},
      {"--kind",
       "KIND: a summarised Telemetry kind such as shop.pricing.lookup, logger_summary for the Logger bursts, or " <>
         "vm_sample, port_top, process_top or process_watch for the Poller series; " <>
         "trends lists only these (max #{options["trends"]["kinds"]["max"]})", "trends.kinds"},
      {"--windows",
       integer(options["trends"]["windows"]) <>
         ": the most recent summary windows trends lists per series", "trends.windows"},
      {"--component", choice(start["components"]["allowed"]), "start.components"},
      {"--telemetry-event",
       "EVENT: a dotted event name such as phoenix.endpoint.stop, every segment already an atom on the target; " <>
         "or PREFIX.*, such as 'my_app.*' (quoted), for every name discover finds below PREFIX at start",
       "start.telemetry_events"},
      {"--prefix",
       "PREFIX: a dotted event-name prefix such as phoenix.router_dispatch; discover lists only the names below it",
       "discover.prefix"},
      {"--telemetry-measurement",
       "NAME: a measurement such as duration, from the target's telemetry_measurements_allowed (see capabilities)",
       "start.telemetry_measurements"},
      {"--lease-ms", integer(start["lease_ms"]), "start.lease_ms"},
      {"--max-events", integer(start["max_events"]) <> ": the Recorder's event bound",
       "start.max_events"},
      {"--retain-traces",
       integer(start["retain_traces"]) <>
         ": keep the events of the N most recently active traces apart from the Recorder, so they survive its " <>
         "eviction; 0 keeps none (explicit --retain pins stay)", "start.retain_traces"},
      {"--retain",
       "no value: pin this trace; it and its later events survive the Recorder's eviction, and the result's " <>
         "retention says what was kept, restored, and lost", "trace.retain"},
      {"--values",
       "no value: rich profile only (strict refuses with disclosure_denied); add the response values of the trace's " <>
         "GraphQL operations as path = value lines, credential-masked and bounded",
       "trace.values"},
      {"--values-path",
       "PATTERN: keep only value paths matching it, * matching any text, such as 'buyOrderV2.buyOrder.total*'; " <>
         "implies --values; repeatable, max #{options["trace"]["values_paths"]["max_items"]}",
       "trace.values_paths"},
      {"--disclosure",
       choice(start["disclosure"]["allowed"]) <> ", no richer than the host profile",
       "start.disclosure"},
      {"--logger-level",
       choice(start["logger_level"]["allowed"]) <>
         " (default #{start["logger_level"]["default"]})", "start.logger_level"},
      {"--logger-include", "RULE: " <> rule <> ", such as module:MyApp.Checkout",
       "start.logger_include"},
      {"--logger-exclude", "RULE: " <> rule <> ", such as domain:otp.sasl",
       "start.logger_exclude"},
      {"--logger-summary",
       "RULE: " <>
         rule <>
         ", such as module:MyApp.Checkout; its Logger messages are counted per message template, call site and level, a burst, " <>
         "instead of recorded", "start.logger_summaries"},
      {"--logger-summary-interval-ms", integer(start["logger_summary_interval_ms"]),
       "start.logger_summary_interval_ms"},
      {"--exclude-origin",
       "ORIGIN: oban, application:NAME, or module:NAME; or none, alone, to record every origin (default oban)",
       "start.exclude_origins"},
      {"--telemetry-min-duration-ms", integer(start["telemetry_min_duration_ms"]),
       "start.telemetry_min_duration_ms"},
      {"--telemetry-event-min-duration",
       "KIND=MS: an event kind and its minimum in milliseconds (0..#{start["telemetry_event_min_duration_ms"]["max"]}), such as phoenix.endpoint.stop=0",
       "start.telemetry_event_min_duration_ms"},
      {"--telemetry-summary",
       "KIND: a recorded event kind to summarise, such as phoenix.endpoint.stop",
       "start.telemetry_summaries"},
      {"--telemetry-duration-scope",
       "KIND=handler|caller: declares how a summarised kind's duration was measured, handler (inside the code that handles " <>
         "the operation) or caller (by the code that waits for it), such as phoenix.endpoint.stop=handler; an undeclared kind's " <>
         "duration_scope.measured_in is unknown", "start.telemetry_duration_scopes"},
      {"--telemetry-summary-interval-ms", integer(start["telemetry_summary_interval_ms"]),
       "start.telemetry_summary_interval_ms"},
      {"--poller-interval-ms", integer(start["poller_interval_ms"]), "start.poller_interval_ms"},
      {"--top-processes",
       integer(start["top_processes"]) <>
         ": entries in each process ranking; 0 scans no processes", "start.top_processes"},
      {"--top-ets-tables",
       integer(start["top_ets_tables"]) <> ": entries in each ETS ranking; 0 scans no tables",
       "start.top_ets_tables"},
      {"--top-ports",
       integer(start["top_ports"]) <>
         ": entries in each port_top ranking (types by count, owners by ports held); 0 counts no ports",
       "start.top_ports"},
      {"--name",
       "NAME: a registered process name such as MyApp.Worker or my_server; give --name or --pid",
       "process.name"},
      {"--pid",
       "PID: a local pid such as '<0.200.0>' (quote it for the shell), as events write it; give --name or --pid",
       "process.pid"},
      {"--frames", integer(options["process"]["frames"]) <> ": stacktrace frames returned",
       "process.frames"},
      {"--messages",
       integer(options["process"]["messages"]) <>
         ": the first queued messages whose shapes are listed", "process.messages"},
      {"--top", integer(options["bin_leak"]["top"]) <> ": processes in each bin_leak ranking",
       "bin_leak.top"},
      {"--type",
       "TYPE: a port type, a port's program name without a directory, such as cat or tcp_inet",
       "ports.type"},
      {"--owner",
       "NAME or PID: the process that owns the ports, such as MyApp.Worker or '<0.200.0>'",
       "ports.owner"},
      {"--watch-process",
       "NAME: a registered process name such as MyApp.Worker or my_server, sampled every poller interval",
       "start.watch_processes"},
      {"--otel-min-duration-ms",
       integer(start["otel_min_duration_ms"]) <> ": with --component otel",
       "start.otel_min_duration_ms"},
      {"--trace-id",
       "TRACE_ID: 32 lowercase hex digits, a W3C trace id such as event.causality.trace_id; --trace is the same flag",
       "trace_id"},
      {"--request-id",
       "REQUEST_ID: Plug's request id (Logger metadata request_id, or the x-request-id response header)",
       "timeline.request_id"},
      {"--id",
       "ID: a record id among a mutation's arguments (fields named id or ending in Id or _id), at most 64 bytes; " <>
         "rich only", "mutations.id"},
      {"--key",
       "KEY: one watched key (at most 128 bytes), as the write's first argument names it; without it, every key",
       "changes.key"},
      {"--watch-write",
       "MOD.FUN/ARITY: a loaded write function of an in-memory value (a feature-flag store's set/2, Application.put_env/3); " <>
         "each call records its key and writer (and its value under rich), within the calls bounds; repeatable, max " <>
         "#{start["watch_writes"]["max"]} (with --component calls)", "start.watch_writes"},
      {"--calls",
       "MOD.FUN/ARITY: a loaded function to trace, such as MyApp.Worker.handle_call/3 or :ets.insert/2; repeat for several (with --component calls)",
       "start.calls"},
      {"--calls-results", choice(start["calls_results"]["allowed"]) <> " (default exceptions)",
       "start.calls_results"},
      {"--calls-max", integer(start["calls_max"]) <> ": calls traced in total",
       "start.calls_max"},
      {"--calls-rate-max",
       integer(start["calls_rate_max"]) <>
         ": trace messages within --calls-rate-ms before the trace stops",
       "start.calls_rate_max"},
      {"--calls-rate-ms", integer(start["calls_rate_ms"]), "start.calls_rate_ms"},
      {"--calls-max-bytes",
       integer(start["calls_max_bytes"]) <>
         ": JSON bytes of each rendered argument list, result or reason",
       "start.calls_max_bytes"},
      {"--view-source", choice(view["sources"]["allowed"]), "view.sources"},
      {"--view-kind", "KIND, or a dotted prefix ending in .*, such as phoenix.*", "view.kinds"},
      {"--view-exclude-kind", "KIND, or a dotted prefix ending in .*, such as oban.*",
       "view.exclude_kinds"},
      {"--view-min-severity", choice(view["min_severity"]["allowed"]), "view.min_severity"},
      {"--view-exclude-signature",
       "SIGNATURE: a hex prefix (8 to 64 digits) of a digest error signature's id or of a supervisor report's " <>
         "reason_fingerprint, or a module name such as MyApp.Worker; hides that signature from your reads only",
       "view.exclude_signatures"},
      {"--view-service",
       "SERVICE: a span's service name, such as my-frontend; keeps the traces it took part in",
       "view.services"},
      {"--view-route",
       "ROUTE: a route template or path prefix starting with /, such as /marketplace; keeps the traces it served (rich profile)",
       "view.routes"},
      {"--view-trace", "TRACE_ID: 32 lowercase hex digits; keeps that trace's events",
       "view.traces"},
      {"--view-clear",
       "no value: clear your reader's stored view (with --reader); with other view flags, they replace it, as with --view-keep",
       nil},
      {"--view-keep",
       "no value: keep this read's view flags as your reader's stored view (needs --reader and a view flag): your later reads " <>
         "without view flags apply it and say so first (stored_view); without --view-keep a view narrows only its own read",
       "read.view_keep"},
      {"--category", choice(options["report"]["category"]["allowed"]), "report.category"},
      {"--message",
       "TEXT: at most #{options["report"]["message"]["max_bytes"]} bytes of UTF-8, quoted; no event payloads or secrets",
       "report.message"},
      {"--confirm", "no value: file the GitHub issues instead of printing them", nil},
      {"--reader",
       "NAME: 1 to 32 letters, digits, _, . or -, starting with a letter or digit, such as agent-a; names you in status",
       "read.reader"},
      {"--force", "no value: stop even while another named reader is active (readers_active)",
       "stop.force"},
      {"--reset",
       "FLAG: a recording flag's name without the dashes, such as watch-process; amend returns that option to its default " <>
         "(sends it as null). A flag is either given or reset in one amend",
       "amend.start_options"},
      {"--dry-run", "no value: print the GitHub issues and send nothing, overriding every opt-in",
       nil},
      {"--fingerprint",
       "FINGERPRINT: a report's 16 lowercase hex fingerprint, as reports lists it", nil}
    ]
    |> Map.new(fn {flag, value, sets} ->
      {flag, %{"value" => value, "sets" => sets, "repeatable" => flag in @observer_repeatable}}
    end)
    # On trends, --since sets the trends option.
    |> put_in(["--since", "commands"], %{
      "trends" => %{"sets" => "trends.since"},
      "baseline" => %{
        "value" =>
          "the window whose anomalies are marked normal (default latest-5m), as digest's --since",
        "sets" => "baseline.since"
      },
      "chart" => %{
        "value" =>
          "the window the chart draws (default latest-15m), as digest's --since: latest-DURATION, a cursor, or latest-N",
        "sets" => "digest.since"
      }
    })
    # chart --serve listens on a random loopback port by default, for 30 minutes.
    |> put_in(["--port", "commands"], %{
      "chart" => %{
        "value" =>
          "INTEGER 0..65535 (default 0, a free port): where chart --serve listens on 127.0.0.1",
        "sets" => nil
      }
    })
    |> put_in(["--for", "commands"], %{
      "chart" => %{
        "value" => "DURATION (default 30m, at most 24h), such as 10m: chart --serve then stops",
        "sets" => nil
      }
    })
    # --since-mark sets each read's start: events read after the mark's receipt.
    |> put_in(["--since-mark", "commands"], %{
      "chart" => %{"sets" => "digest.since"},
      "trends" => %{"sets" => "trends.since"},
      "baseline" => %{"sets" => "baseline.since"},
      "timeline" => %{"sets" => "timeline.since"},
      "events" => %{
        "value" =>
          "[LABEL]: pairing; read after the newest mark, or the newest with this label (quote it), in place of --cursor. " <>
            "Without a label, the next argument must be another flag, or nothing",
        "sets" => "cursor"
      }
    })
    # --pid names the inspected process on process, and the subject on timeline.
    |> put_in(["--pid", "commands"], %{
      "timeline" => %{
        "value" =>
          "PID: a process as events name it in event.subject.value, such as '<0.1234.0>'",
        "sets" => "timeline.pid"
      }
    })
    # On watch, --max-events is the subscription's total event budget; on
    # trace and timeline, --limit and --max-bytes bound the items returned.
    |> put_in(["--max-events", "commands"], %{
      "watch" => %{
        "value" =>
          integer(subscribe["max_events"]) <> ": events watch prints in total before it stops",
        "sets" => "subscribe.max_events"
      }
    })
    # --reader names the subscriber on watch, the stopper on stop, and the
    # amending reader on amend.
    |> put_in(["--reader", "commands"], %{
      "chart" => %{
        "value" =>
          "NAME: the chart's own reader (default a new chart-… name), so no other reader's cursor or view moves",
        "sets" => "digest.reader"
      },
      "watch" => %{"sets" => "subscribe.reader"},
      "digest" => %{"sets" => "digest.reader"},
      "trends" => %{"sets" => "trends.reader"},
      "trace" => %{"sets" => "trace.reader"},
      "changes" => %{"sets" => "changes.reader"},
      "mutations" => %{"sets" => "mutations.reader"},
      "baseline" => %{"sets" => "baseline.reader"},
      "timeline" => %{"sets" => "timeline.reader"},
      "mark" => %{
        "value" => "NAME: who marks, listed with the mark",
        "sets" => "mark.reader"
      },
      "status" => %{"value" => @reader_ignored, "sets" => nil},
      "welcome" => %{"value" => @reader_ignored, "sets" => nil},
      "capabilities" => %{"value" => @reader_ignored, "sets" => nil},
      "handoff" => %{"value" => @reader_ignored, "sets" => nil},
      "renew" => %{"value" => @reader_ignored, "sets" => nil},
      "marks" => %{"value" => @reader_ignored, "sets" => nil},
      "stop" => %{
        "value" =>
          "NAME: who stops; your own recent reads under this name do not count as another reader's",
        "sets" => "stop.reader"
      },
      "amend" => %{
        "value" => "NAME: who amends, shown in the live.session_amended event",
        "sets" => "amend.reader"
      }
    })
    |> put_in(["--limit", "commands"], %{
      "trace" => %{
        "value" => integer(options["trace"]["limit"]) <> ": items returned",
        "sets" => "trace.limit"
      },
      "timeline" => %{
        "value" => integer(options["timeline"]["limit"]) <> ": items returned",
        "sets" => "timeline.limit"
      }
    })
    |> put_in(["--max-bytes", "commands"], %{
      "trace" => %{
        "value" => integer(options["trace"]["max_bytes"]) <> ": JSON bytes of the items returned",
        "sets" => "trace.max_bytes"
      },
      "timeline" => %{
        "value" =>
          integer(options["timeline"]["max_bytes"]) <> ": JSON bytes of the items returned",
        "sets" => "timeline.max_bytes"
      }
    })
    |> put_in(["--human", "commands"], %{
      "bin_leak" => %{
        "value" =>
          "no value: print the binary holders as plain text, the biggest holder first, instead of the JSON result",
        "sets" => "bin_leak.human"
      },
      "trends" => %{
        "value" =>
          "no value: print one line per series for the developer instead of the JSON trends",
        "sets" => "trends.human"
      },
      "trace" => %{
        "value" =>
          "no value: print the span tree as plain text (each span's duration and outcome) instead of the JSON result",
        "sets" => "trace.human"
      },
      "timeline" => %{
        "value" => "no value: print an indented plain-text rendering instead of the JSON result",
        "sets" => "timeline.human"
      },
      "changes" => %{
        "value" =>
          "no value: print one line per write (its value under rich, and its writer) instead of the JSON result",
        "sets" => "changes.human"
      },
      "mutations" => %{
        "value" => "no value: print one line per kept mutation record instead of the JSON result",
        "sets" => "mutations.human"
      },
      "marks" => %{
        "value" =>
          "no value: print one line per mark (time, age, label, reader, the receipt it starts after) instead of the JSON result",
        "sets" => "marks.human"
      },
      "baseline" => %{
        "value" =>
          "no value: print what was marked normal, shown, or cleared instead of the JSON result",
        "sets" => "baseline.human"
      }
    })
    # --top bounds each inspection's own lists.
    |> put_in(["--top", "commands"], %{
      "ports" => %{
        "value" =>
          integer(options["ports"]["top"]) <> ": ports listed, and entries in types and owners",
        "sets" => "ports.top"
      },
      "alloc" => %{
        "value" => integer(options["alloc"]["top"]) <> ": allocator instances in fragmentation",
        "sets" => "alloc.top"
      }
    })
  end

  @doc """
  How `flag` is used by the observer `command`: its value and the option it
  sets, or `nil` for a flag the observer does not have.
  """
  @spec observer_option(String.t(), String.t()) :: map() | nil
  def observer_option(command, flag) do
    case Map.fetch(observer_options(), flag) do
      {:ok, option} -> Map.merge(option, get_in(option, ["commands", command]) || %{})
      :error -> nil
    end
  end

  defp integer(%{"min" => min, "max" => max, "default" => default}),
    do: "INTEGER #{min}..#{max} (default #{default})"

  defp choice(allowed), do: Enum.join(allowed, " | ")

  @spec version() :: String.t() | nil
  def version do
    case Application.spec(:insider, :vsn) do
      nil -> nil
      version -> List.to_string(version)
    end
  end

  @doc """
  Every part of the document the hash covers. It reads host configuration
  (the measurement allowlist and report submission), so it is built on each
  call.
  """
  @spec contract() :: map()
  def contract do
    options = Options.describe()

    %{
      "schema" => @schema,
      "hash_covers" => "every key except hash, runtime and effective_disclosure",
      "insider" => %{"version" => version(), "commit" => Revision.commit()},
      "summary" =>
        "Insider Live observes this running BEAM node while it keeps running: one bounded, leased " <>
          "session records Logger, Telemetry, Poller, and OpenTelemetry span evidence, and traced calls, that you read after a cursor, " <>
          "or one trace, process, or request at a time. " <>
          "It is development tooling, allowed only in development, test, and ci.",
      "quick_start" => %{
        "setup" => "N=(#{@target_placeholder})",
        "steps" => @quick_start_steps,
        "commands" => @quick_start_commands,
        "load" => @quick_start_load
      },
      "recipes" => @recipes,
      "pairs_with" => Enum.map(@pairs_with, &Map.delete(&1, "probe")),
      "guide" => guide(),
      "operations" => Enum.map(@operations, &operation/1),
      "options" => options,
      "components" => Options.components(),
      "telemetry_measurements_allowed" => options["start"]["telemetry_measurements"]["allowed"],
      "bounds" => Map.merge(Options.bounds(), Owner.bounds()),
      "recorder" => recorder(),
      "errors" => %{
        "schema" => "insider.live-error/v1",
        "codes" => Error.messages(),
        "observer" => %{
          "schema" => "insider.live-observer-error/v1",
          "note" =>
            "Observer errors carry source observer and exit with their status's exit code; " <>
              "a target error keeps the target's code, carries source target, and exits 1.",
          "exit_statuses" => @observer_exit_statuses,
          "codes" =>
            Map.new(@observer_errors, fn {code, {status, message}} ->
              {code,
               %{
                 "status" => status,
                 "exit" => Map.fetch!(@observer_exit_statuses, status),
                 "message" => message
               }}
            end)
        }
      },
      "reports" => %{
        "categories" => Options.report_categories(),
        "message_max_bytes" => options["report"]["message"]["max_bytes"],
        "queue_max" => Report.max_reports(),
        "context" => Report.context_keys(),
        "queue" =>
          "in this node's memory, bounded and deduplicated by fingerprint; " <>
            "`#{@observer_command} reports #{@target_placeholder}` copies them to the observer's queue",
        "submission" => Report.submission(),
        "issue_repository" => Report.repository()
      },
      "filters" => Filters.describe(),
      "severity" => severity(options["read"]["view"]),
      "time" => time(),
      "disclosure" => Disclosure.contract(),
      "costs" => [
        "A session attaches one Logger handler and, with telemetry, one handler per listed event, which runs in the emitting process.",
        "discover reads the object files of loaded application modules that import :telemetry.execute or :telemetry.span, " <>
          "in a worker under a #{Discovery.bounds()["deadline_ms"]} ms deadline; at most #{Discovery.bounds()["concurrent_max"]} run at once.",
        "The Poller samples VM-wide scalars on a timer. With top_processes or top_ets_tables (on by default with the poller) each sample also reads " <>
          "four scalar counters of every process and the metadata of every ETS table, never a message, an object, or a dictionary entry other than $initial_call; " <>
          "it keeps one reductions count per process between samples. With top_ports (on by default) it reads the name, owner and OS pid of every port " <>
          "and keeps one count per port type between samples. Protected OTP processes are never read.",
        "With otel, every span the SDK ends sends one trace message to the otel collector (an isolated trace session on OTP 28+, " <>
          "OTP 28 or later; refused on OTP 27); the SDK's processors and exporters are untouched. Above 1024 waiting spans the trace pauses (otel_paused, unknown count) and received spans are shed before being built.",
        "process, bin_leak, ports and alloc run once, in a worker under a #{Inspect.bounds()["deadline_ms"]} ms deadline and a heap guard; " <>
          "at most #{Inspect.bounds()["concurrent_max"]} run at once. process sends a few process_info requests to its target and, for a mailbox of at most " <>
          "#{Inspect.bounds()["mailbox_read_max"]} messages, has it copy its queue to a reader that keeps only the shapes. " <>
          "bin_leak garbage-collects every unprotected process once. No inspection reads a protected process.",
        "Only one session exists per node; a running one blocks other starts until it stops or its lease expires.",
        "An amendment stops and restarts the collectors; events emitted in that pause are not recorded (the live.session_amended event reports uncollected_ms). " <>
          "The session's earlier events are kept in the owner's memory (bounds.archived_events_max, archived_bytes_max), as are a stopped session's until readable_until.",
        "In the rich profile, each recorded Logger or Telemetry event is rendered in the emitting process within fixed size bounds and a per-payload work budget.",
        "The Recorder holds up to bounds.recorder_max_bytes of events. A read is served in pages of at most bounds.read_page_bytes, so serving it holds about one page besides the events it returns; status reports Insider's own memory as insider_memory."
      ],
      "tandem" => tandem(),
      "transports" => transports()
    }
  end

  # How several agents share one node: a lock-free observer, named readers,
  # protected stops with a drain window, live amendment, and handoff.
  defp tandem do
    %{
      "escript" => %{
        "install" =>
          "mix escript.install hex insider_lab installs insider-lab (put the directory Mix prints on PATH); install again to update",
        "build" =>
          "in an Insider checkout: mix escript.build, once, in tools/insider_lab (writes ./insider-lab); build again after the checkout changes",
        "run" =>
          "insider-lab live OPERATION (./insider-lab live for a checkout build) with the same operations, flags and output as #{@observer_command}. " <>
            "It starts no Mix, so concurrent agents never wait on the build lock that concurrent mix commands in one checkout share, " <>
            "and prints none of Mix's Compiling or \"Waiting for lock\" notices.",
        "freshness" =>
          "installation.insider_commit in every observer document is the commit the observer was built from (null for an escript installed from Hex: compare insider_version instead); " <>
            "if it differs from this document's insider.commit, build the escript again (or install it again from Hex). " <>
            "installation.same_build is false when the target runs another Insider build than the observer would push; --load never replaces it, --force-load does, ending any session: read and save what you need (events, digest, handoff) first"
      },
      "scope" => %{
        "recording" =>
          "components, Telemetry events, measurements and filters decide what the session records, for every reader; amend changes them for everyone",
        "view" =>
          "--view-* flags and the view option narrow only the read or watch that passes them, unless --view-keep keeps them " <>
            "as your reader's stored view; other readers are unaffected"
      },
      "steps" => [
        "Pass --reader NAME (your own name) to every read (events, watch, digest, trends, trace, timeline) and to stop and amend. status.readers lists each named reader with its cursor, behind, last_seen_ms_ago, subscribed and view.",
        "Your view is yours: --view-exclude-signature hides a known error signature (a digest signature id, a reason_fingerprint prefix, or a module), " <>
          "--view-service, --view-route and --view-trace keep only the traces you care about across services. " <>
          "A view narrows only the read that gives it; --view-keep keeps it as your stored view for your later reads, which then say so " <>
          "first (stored_view), and --view-clear clears it. It never changes what is recorded.",
        "Join a running session from cursor latest rather than starting another: one session exists per node.",
        "stop --reader NAME refuses with readers_active while another named reader read within #{@reader_active_s} s or is subscribed; " <>
          "the error names them and retry_after_ms. --force stops anyway.",
        "A stopped session stays readable for #{@stopped_readable_s} s (readable_until): a peer drains it with events from its cursor; renew and watch then return session_terminal.",
        "Need another measurement, event or log level? amend the running session: its history and every cursor stay, and each reader sees a live.session_amended event.",
        "Hand a session to another agent with handoff: node, welcome hash, session id, configuration, and each reader's cursor with the command that resumes it."
      ],
      "commands" => @tandem_commands
    }
  end

  defp operation(operation) do
    name = operation["name"]
    arity = operation["arity"]

    operation
    |> Map.drop(["arity"])
    |> Map.merge(%{
      "elixir" => "Insider.Live.#{name}/#{arity}",
      "json" => "Insider.Live.JSON.#{name}/#{arity}"
    })
  end

  # The Recorder's per-source shares, from the defaults it is started with.
  defp recorder do
    %{
      "source_shares_percent" =>
        Map.put(
          RecorderConfig.default_source_shares(),
          "other",
          RecorderConfig.default_other_share()
        ),
      "sharing" => [
        "Each source reserves this percentage of the Recorder's events (start max_events) and bytes (bounds.recorder_max_bytes); other covers every source without its own, together.",
        "A share reserves room without holding it: a source may fill room no one else is using.",
        "When the Recorder is full, a source over its share evicts its own oldest events first, and a source within its share takes the oldest events of sources over theirs. " <>
          "A flood from one source, such as rich Logger at info, so evicts its own history and never the events of a source within its share, such as early Poller samples.",
        "Protected events (crashes, supervisor child terminations, invariant failures, code, config, and deploy changes) are never evicted by normal events, and evict normal events of any source before protected ones.",
        "status recorder.sources reports each source's share_percent, reserved_events, reserved_bytes, retained_events, retained_bytes, and evicted count."
      ]
    }
  end

  # How each source sets an event's severity, from the tables the collectors
  # use. A read view's `min_severity` keeps events at or above a level.
  defp severity(view) do
    %{
      "order" => view["keys"]["min_severity"]["allowed"],
      "logger" =>
        Map.new(LoggerHandler.severities(), fn {level, severity} ->
          {Atom.to_string(level), Atom.to_string(severity)}
        end),
      "inspect" => "info",
      "poller" => "debug",
      "otel" => %{
        "status error, or a GraphQL error (attributes.graphql result partial or errors)" =>
          "error",
        "attributes.graphql result user_errors (payload validation errors only)" => "warning",
        "otherwise" => "info"
      },
      "telemetry" =>
        Outcome.rules() ++
          [
            %{
              "when" =>
                "an Absinthe operation whose payload reports only validation errors (attributes.graphql result user_errors)",
              "examples" => ["absinthe.execute.operation.stop"],
              "severity" => "warning"
            },
            %{
              "when" => "a summary whose errors count is above 0",
              "examples" => [],
              "severity" => "warning"
            },
            %{"when" => "any other event", "examples" => [], "severity" => "info"}
          ],
      "telemetry_rule" =>
        "The first matching row applies. Only the event name and these metadata shapes are read: " <>
          "a result's tag, an HTTP status class, an exception kind, whether an error is present. " <>
          "A summary's errors count the events these rows rate error, and they pass every minimum duration."
    }
  end

  # What each event's time fields mean, per source, and the unit of every
  # duration an event carries.
  defp time do
    %{
      "wall_time" => %{
        "format" => "UTC RFC 3339 with microseconds, such as 2026-10-22T05:01:51.107000Z",
        "logger" => "the Logger event's own time (its :time metadata)",
        "telemetry" =>
          "when the event was emitted, read in the emitting process; a summary event's is when the collector recorded it, at the end of its interval",
        "poller" => "when the sample was taken",
        "otel" =>
          "when the span ended, from its start time and duration; attributes.start_wall_time is when it started",
        "calls" =>
          "when the call, return, or exception happened, from the trace message's timestamp; a call.stopped event's is when the trace stopped",
        "inspect" =>
          "when the inspection's result was recorded, just after it ran; the result's own at is when it returned"
      },
      "monotonic_time" =>
        "an ordering key within one source, not a clock: Logger, Telemetry and otel events carry their source's sequence number, " <>
          "Poller samples and calls events the VM monotonic clock in microseconds. Order events across sources by receipt.",
      "durations" =>
        "Telemetry time measurements (#{Enum.join(Disclosure.time_measurements(), ", ")}) are in the emitting node's native time unit, " <>
          "as Telemetry reports them; every one an event discloses as an integer is repeated in microseconds under attributes.durations_us. " <>
          "Summary statistics end in _us (microseconds); Poller sample_duration_us is microseconds; digest periods and spans end in _ms."
    }
  end

  defp guide do
    categories = Enum.join(Options.report_categories(), ", ")

    %{
      "first" => [
        "Check runtime.allowed. Live observation works only where the node resolves to development, test, or ci.",
        "If runtime.active_session_id is set, a session is already running and only one exists per node: read it, or ask the developer before you stop it.",
        "Keep this document's hash. capabilities reports the current hash; if it changes, read this document again."
      ],
      "loop" => [
        "Start one session with the fewest components that can show the effect. Without options a session is quiet: " <>
          "see filters.quiet_defaults; widen it with the filter options, for example logger_level debug or telemetry_min_duration_ms 0.",
        "Silence is not inactivity: every batch reports filtered counts per filter. If what you expect is missing, check filtered before you conclude nothing happened.",
        "Act: send the request, run the job, or ask the developer to use the app.",
        "Read: digest the session for the overview (counts, crash loops with their period, top error signatures, latency tables, longest mailboxes, VM deltas), " <>
          "then events_since with the session_id and your cursor for detail, keeping next_cursor for the next read. Cursor 0 is the start of the session.",
        "A non-empty gaps list means evidence was lost; losses are never silent. truncated means more events are waiting at next_cursor, and truncated_by names the bound that ended the read: " <>
          "limit or max_bytes (events returned), or scan_limit (a sparse view examined its budget of events; read on from next_cursor). " <>
          "An evicted gap counts the events the full Recorder dropped; status recorder.sources names whose (see recorder). " <>
          "To join a running session without its history, read from cursor \"latest\"; status reports next_receipt and the recorder's fill.",
        "Repeat act then read. Reads renew the lease; status and subscriptions do not. Call renew during long pauses or the lease stops the session.",
        "Prefer reading after each action. Use the observer's watch, or subscribe, only when you need events pushed as they happen."
      ],
      "stop" => [
        "Call stop when you are done and check the receipt's outcome. Pass --reader with your name: stop refuses with readers_active while another named reader " <>
          "read within bounds.reader_active_ms or is subscribed; --force stops anyway. The stopped session stays readable until readable_until.",
        "If you leave without stopping, the lease stops the session through the same cleanup; status then reports state expired with the receipt.",
        "Errors carry a closed code from errors.codes; session_terminal carries the ended session's status."
      ],
      "report" => [
        "You must report Insider bugs and every behaviour that differs from this document. Use doc_mismatch for a difference and cite the field of this document you relied on.",
        "Also report missing capabilities and confusing output. Categories: #{categories}.",
        "Write what you expected and what happened. Never include event payloads, log text, option values, or secrets; Insider adds the context itself.",
        "Observer: #{@observer_command} report --category doc_mismatch --message 'TEXT'. " <>
          "Tidewave: Insider.Live.JSON.report(%{\"category\" => \"doc_mismatch\", \"message\" => \"TEXT\"}).",
        "Reports stay on this machine. The developer reviews them with `#{@observer_command} reports` and sends them upstream with `#{@observer_command} reports submit`; " <>
          "`#{@observer_command} reports submit --dry-run` only previews, whatever opt-in is set.",
        "The queue is shared by every observer run on this machine. A report's context cites `--session` when you give it, else the session of your last target command; " <>
          "`reports` groups reports by node and session, and `--session` or `--fingerprint` selects them."
      ]
    }
  end

  defp transports do
    %{
      "observer" => %{
        "invocation" => @observer_command,
        "escript" => @observer_escript,
        "package" =>
          "insider_lab: the escript and #{@observer_command}. The insider package, the library in the node, has no Mix tasks. Both release at the same version.",
        "escript_install" =>
          "mix escript.install hex insider_lab, then insider-lab live OPERATION",
        "escript_build" =>
          "mix escript.build in tools/insider_lab of an Insider checkout, then ./insider-lab live OPERATION; see tandem.escript",
        "run_from" =>
          "any directory for the escript installed from Hex; tools/insider_lab of an Insider checkout for #{@observer_command}",
        "target_flags" => @observer_target_flags,
        "repeatable" => @observer_repeatable,
        "commands" => @observer_commands,
        "options" => observer_options(),
        "help" => [
          "#{@observer_command} --help",
          "#{@observer_command} help OPERATION",
          "#{@observer_command} OPERATION --help"
        ],
        "output" =>
          "One canonical JSON document per command (help prints text); schema insider.live-observer/v1, or insider.live-observer-error/v1 with a closed code from errors.observer and its exit status. " <>
            "watch prints NDJSON: its first line (kind subscribed) carries the schema, status, operation, target, installation, and subscription, and each later line (kind batch, then stopped with next_cursor) only its kind and fields. " <>
            "events and watch take --format: json (default) drops the event envelope fields that are null, empty, or the same for every event; full prints events as the target returns them; " <>
            "compact prints one line per event and one line starting with # per batch (next_cursor, truncation, disclosure profile, gaps, filtered), while errors stay JSON. " <>
            "digest --human prints plain text; it neither carries nor delivers the welcome. " <>
            "The first command run against a target node carries the welcome quick start under \"welcome\" (a compact read prints a # line naming the welcome command instead), " <>
            "unless it is a receipt (#{Enum.join(@observer_receipts, ", ")}): receipts never carry it, and the next other command does. " <>
            "After delivery only capabilities carries a pointer with the delivered hash; other commands carry no welcome. " <>
            "Delivery is recorded per node name and distribution creation, which changes when the node restarts, in the observer's reports directory, which every observer on this machine shares; printing welcome counts as delivery. " <>
            "installation is the whole report (builds, action, pushed applications, environment, remedy) on capabilities, after a load, and while the target runs another build; " <>
            "every other document carries only same_build, insider_version and insider_commit.",
        "setup" => "N=(#{@target_placeholder})",
        "examples" => [
          "#{@observer_command} welcome \"${N[@]}\"",
          "#{@observer_command} welcome \"${N[@]}\" --full",
          "#{@observer_command} capabilities \"${N[@]}\"",
          "#{@observer_command} discover \"${N[@]}\"",
          "#{@observer_command} process \"${N[@]}\" --name MyApp.Worker",
          "#{@observer_command} bin_leak \"${N[@]}\"",
          "#{@observer_command} ports \"${N[@]}\" --type cat",
          "#{@observer_command} start \"${N[@]}\" --component logger --lease-ms 300000",
          "#{@observer_command} events \"${N[@]}\" --session SESSION_ID --cursor 0 --limit 50",
          "#{@observer_command} digest \"${N[@]}\" --session SESSION_ID --human",
          "#{@observer_command} watch \"${N[@]}\" --session SESSION_ID",
          "#{@observer_command} stop \"${N[@]}\" --session SESSION_ID",
          "#{@observer_command} amend \"${N[@]}\" --session SESSION_ID --telemetry-measurement duration",
          "#{@observer_command} handoff \"${N[@]}\" --session SESSION_ID",
          "#{@observer_command} report --category doc_mismatch --message 'TEXT'",
          "#{@observer_command} reports \"${N[@]}\"",
          "#{@observer_command} reports submit"
        ]
      },
      "tidewave" => %{
        "tool" => "project_eval",
        "setup" =>
          "Each project_eval runs in a new process and the session survives between evals. " <>
            "If Insider is not loaded: Code.prepend_path(\"/path/to/insider/_build/dev/lib/insider/ebin\"); " <>
            "Application.ensure_all_started(:insider).",
        "examples" => [
          "Insider.Live.JSON.welcome()",
          "Insider.Live.JSON.welcome(%{\"full\" => true})",
          "Insider.Live.JSON.capabilities()",
          "Insider.Live.JSON.discover(%{\"prefix\" => [\"phoenix\"]})",
          "Insider.Live.JSON.process(%{\"name\" => \"MyApp.Worker\"})",
          "Insider.Live.JSON.ports(%{\"type\" => \"cat\"})",
          "Insider.Live.JSON.start(%{\"components\" => [\"logger\"]})",
          "Insider.Live.JSON.events_since(\"SESSION_ID\", 0, %{\"limit\" => 50})",
          "Insider.Live.JSON.digest(\"SESSION_ID\", %{\"since\" => \"latest-500\", \"human\" => true})",
          "Insider.Live.JSON.stop(\"SESSION_ID\")",
          "Insider.Live.JSON.report(%{\"category\" => \"doc_mismatch\", \"message\" => \"TEXT\"})",
          "Insider.Live.JSON.reports()"
        ]
      }
    }
  end
end

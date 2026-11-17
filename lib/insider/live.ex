defmodule Insider.Live do
  @moduledoc """
  Transport-agnostic live observation of the node it runs in.

  One live collector session records bounded Logger, Telemetry, and Poller
  evidence. A supervised owner under `Insider.Supervisor`, never the caller,
  owns the session, so short-lived transport processes such as a Tidewave
  `project_eval` or an `:erpc` call from an observer node can start, read, and
  stop it across separate calls. A renewable lease stops an abandoned session
  through the normal collector cleanup path.

  Every argument and return value is a distribution-safe plain term:
  string-keyed maps, binaries, integers, booleans, `nil`, and lists. The only
  process identifier the API accepts is a subscriber pid; none is returned.
  Errors are `{:error, map}` with a closed `"code"` vocabulary documented in
  [Error codes](docs/live/live-welcome-and-reports.md#error-codes); the
  [documentation index](docs/README.md) lists the rest of the reference.
  `Insider.Live.JSON` returns the same
  results as canonical JSON.

  An agent should start with `welcome/1`: by default an agent quick start
  (the steps, the core observer commands, and symptom recipes), and with
  `%{"full" => true}` a document generated from this code that lists every
  operation, option, default, bound, and error code, the transports with
  example invocations, and how to report Insider bugs and behaviour that
  differs from the document with `report/1`.

  Live observation is available only in development, test, and ci, as
  resolved from host configuration by the node itself; callers cannot assert
  an environment. It is not a production collector.
  """

  alias Insider.Collector.Admission
  alias Insider.Live.Anomalies
  alias Insider.Live.Changes
  alias Insider.Live.Mutations
  alias Insider.Collector.Otel
  alias Insider.Live.Disclosure
  alias Insider.Live.Digest
  alias Insider.Live.Discovery
  alias Insider.Live.Environment
  alias Insider.Live.Error
  alias Insider.Live.Hints
  alias Insider.Live.Inspect
  alias Insider.Live.InspectOptions
  alias Insider.Live.Options
  alias Insider.Live.Owner
  alias Insider.Live.Reports
  alias Insider.Live.Trends
  alias Insider.Live.Timeline
  alias Insider.Live.TimelineScan
  alias Insider.Live.Welcome
  alias Insider.Redaction.Credentials

  @call_timeout_ms 5_000
  @control_timeout_ms 3_000
  @stop_timeout_ms 10_000
  @amend_timeout_ms 15_000
  @capabilities_timeout_ms 1_000
  @record_timeout_ms 1_500
  @outer_margin_ms 200

  @type result :: {:ok, map()} | {:error, map()}

  @doc """
  Reports what this node can observe, without starting anything.

  `"welcome"` carries the welcome document's hash and how to read it, and
  `"quiet_default_telemetry_events"` the Telemetry events a session without
  options records on this node.

  It includes the host's disclosure profile and the credential masking
  policy id.
  """
  @spec capabilities() :: map()
  def capabilities do
    {owner_running, owner_responsive, active} = owner_state()

    Environment.resolve()
    |> Environment.describe()
    |> Map.merge(%{
      "schema" => "insider.live-capabilities/v1",
      "insider_version" => Welcome.version(),
      "owner_running" => owner_running,
      "owner_responsive" => owner_responsive,
      "components" => Options.components(),
      "start_options" => Options.start_keys(),
      "telemetry_measurements_allowed" =>
        Disclosure.measurement_allowlist() |> Map.keys() |> Enum.sort(),
      "active_session_id" => active,
      "quiet_default_telemetry_events" => Insider.Live.Filters.default_telemetry_events(),
      "bounds" => Map.merge(Options.bounds(), Owner.bounds()),
      "welcome" => Welcome.pointer(),
      # The otel component needs the SDK on this node; spans end only while
      # the SDK application runs.
      "otel" => %{
        "sdk_present" => Insider.Collector.Otel.Tracing.sdk_present?(),
        "sdk_running" => Insider.Collector.Otel.Tracing.sdk_running?()
      }
    })
    |> Map.merge(Disclosure.describe())
    |> tracked("capabilities")
  end

  @doc """
  Returns the welcome document for an agent.

  By default it is the agent quick start (`insider.live-welcome-quick-start/v1`):
  the steps, the core observer commands with their flags, the symptom
  recipes, where to read the full reference, and `"runtime"`. With
  `%{"full" => true}` it is the full reference (`insider.live-welcome/v2`),
  generated from the code's own tables: the operations with their
  options, defaults, and bounds, the target's and the observer's error codes,
  components, allowed measurement names, the transports with example
  invocations and the observer's value syntax for every flag, a short guide
  (what to do first, the act-then-read loop, how to stop, and the duty to
  report), and `"runtime"`: this node, its environment, the active session,
  and this node's quiet default Telemetry events. `"hash"` covers every key
  of the full reference except `"hash"` and `"runtime"`; both forms carry
  it. Any other option is `{:error, map}` with code `"invalid_options"`.
  """
  @spec welcome(map()) :: map() | {:error, map()}
  def welcome(options \\ %{}) do
    case Options.welcome(options) do
      {:ok, full?} -> runtime() |> Welcome.document(full?) |> tracked("welcome")
      {:error, _error} = invalid -> tracked(invalid, "welcome")
    end
  end

  defp runtime do
    {owner_running, owner_responsive, active} = owner_state()

    Environment.resolve()
    |> Environment.describe()
    |> Map.merge(%{
      "node" => Atom.to_string(node()),
      "owner_running" => owner_running,
      "owner_responsive" => owner_responsive,
      "active_session_id" => active,
      "quiet_default_telemetry_events" => Insider.Live.Filters.default_telemetry_events(),
      "pairs_with_available" => Welcome.available_pairs()
    })
    |> Map.merge(Disclosure.describe())
  end

  @doc """
  Starts the live session.

  Options: `"components"` (a non-empty subset of `"calls"`, `"logger"`,
  `"otel"`, `"poller"`, and `"telemetry"`; `"otel"` records finished
  OpenTelemetry spans and needs the SDK on the node; default `["logger", "telemetry"]` when the node has quiet
  default Telemetry events, else `["logger"]`), `"telemetry_events"` (event
  names as lists of existing-atom strings, recorded with phase `:event`;
  default: the quiet default events that exist on this node), `"telemetry_measurements"`
  (measurement names to project), `"disclosure"` (`"rich"` or `"strict"`, no richer than the host
  profile; default the host profile), `"max_events"`, and `"lease_ms"`.
  Logger message text and metadata are collected only in the rich profile.

  With the telemetry component and without `"telemetry_events"`, a quiet
  default whose application or atoms the node lacks is skipped, never
  refused. The result lists each under `"telemetry_skipped_defaults"` as
  `%{"event" => "phoenix.endpoint.stop", "reason" => "not_on_target"}`
  (`[]` otherwise). When no default is left, the session runs without the
  telemetry component and the result carries `"telemetry_hint"`. With no
  other component, the start is `invalid_options`. An explicit name that is
  not already an atom stays `unknown_telemetry_event`.

  A `"telemetry_events"` entry whose last segment is `"*"`, such as
  `["shop", "*"]`, is a prefix: it stands for every event name `discover/1`
  finds below it now, counted against the event bound after expansion. The
  result lists each prefix's names under `"telemetry_event_prefixes"`.

  Record-time filters, applied in the emitting process before anything is
  recorded: `"logger_level"` (default `"warning"`), `"logger_include"`,
  `"logger_exclude"`, `"exclude_origins"` (default `["oban"]`),
  `"telemetry_min_duration_ms"` (default 100),
  `"telemetry_event_min_duration_ms"`, `"telemetry_summaries"`,
  `"telemetry_summary_interval_ms"`, `"telemetry_duration_scopes"` (a map of
  summarised kind to `"handler"` or `"caller"`, how its duration was
  measured; an undeclared kind's scope is unknown), `"logger_summaries"`
  (Logger rules whose messages are counted per message template, call site,
  and level, a burst, instead of recorded; at most 64 bursts per interval,
  the rest folded into one overflow row per level), and
  `"logger_summary_interval_ms"`. See
  [Filters, summaries, and views](docs/live/live-digest-filters-and-trends.md#filters-summaries-and-views).

  Poller options, with the poller component: `"poller_interval_ms"` (default
  5,000), `"top_processes"` and `"top_ets_tables"` (entries in each process
  and ETS ranking; default 5), and `"watch_processes"` (registered names to
  sample every interval). See
  [Process and ETS evidence](docs/live/live-runtime-evidence.md#process-and-ets-evidence).

  Call-trace options, with the calls component (OTP 28 and later): `"calls"`
  (functions to trace as `"MOD.FUN/ARITY"`, required), `"calls_results"`
  (`"exceptions"`, `"all"`, or `"none"`), `"calls_max"`, `"calls_rate_max"`,
  `"calls_rate_ms"`, and `"calls_max_bytes"`. See
  [Call traces](docs/live/live-runtime-evidence.md#call-traces).
  """
  @spec start(map()) :: result()
  def start(options) do
    result =
      with :ok <- prefix_allowed(options),
           {:ok, options, prefixes} <- Discovery.expand_prefixes(options),
           {:ok, session} <- call({:start, options}, @call_timeout_ms) do
        {:ok, Map.put(session, "telemetry_event_prefixes", prefixes)}
      end

    tracked(result, "start")
  end

  # A prefix is expanded by a scan in this process, which needs the
  # environment to be allowed first.
  defp prefix_allowed(options), do: if(Discovery.prefixes?(options), do: allowed(), else: :ok)

  @doc """
  Lists the Telemetry event names this node can emit, without starting or
  running anything: names with an attached handler (`:telemetry.list_handlers/1`,
  except Insider's own) and literal event lists passed to
  `:telemetry.execute/2,3` and `:telemetry.span/3` (expanded to `:start`,
  `:stop`, and `:exception`) in loaded application modules, read from their
  debug info. Each name carries its `"sources"`: the source (`"handler"`,
  `"execute"`, or `"span"`) and the module.

  Option `"prefix"`, a list of segments such as `["shop"]`, keeps only the
  names under it. The scan is bounded in modules, names, and time, and
  `"truncated_by"` names what bounded it. At most two discoveries run at
  once (`busy`).
  """
  @spec discover(map()) :: result()
  def discover(options \\ %{}) do
    result =
      with :ok <- allowed(),
           {:ok, prefix} <- Options.discover(options),
           do: Discovery.discover(prefix)

    tracked(result, "discover")
  end

  @doc """
  Inspects one process once (`insider.live-process/v1`): a `process_info`
  subset (status, initial and current function, queue length, memory,
  reductions, links by kind, monitors), the current stacktrace's top
  frames with file and line, its binaries' count and bytes, and a mailbox
  summary: queued messages counted by shape and size class, the shapes of
  the first `"messages"`, and how many queued `GenServer.call`s come from
  callers that already exited. A shape is a message's structure with types
  in place of values, such as `{:"$gen_call", {pid, list}, {:price, binary}}`;
  no message value, dictionary entry, or state is ever read. The mailbox is
  read only up to `bounds.inspect.mailbox_read_max` messages.

  Options: `"name"` (a registered name such as `"MyApp.Worker"`) or
  `"pid"` (a local pid such as `"<0.200.0>"`), `"frames"`, and
  `"messages"`. A protected process is `protected_process`; an absent one
  `process_not_found`.

  Like every inspection, the result passes the disclosure profile and
  credential masking (`"redactions"`), and when a session runs it is also
  recorded in it as an `inspect.process` event; `"session"` says whether.
  """
  @spec process(map()) :: result()
  def process(options),
    do: options |> inspection("process", &InspectOptions.process/1) |> tracked("process")

  @doc """
  Finds binary leaks once (`insider.live-bin-leak/v1`), after
  `recon:bin_leak/1`: every unprotected process's binaries are measured,
  it is garbage collected, and measured again. `"by_retained_bytes"` ranks
  what each process still references after the collection (a leak keeps
  it); `"by_freed_bytes"` ranks what the collection released. Insider's
  own processes are summed apart. Option `"top"`: entries per ranking.
  """
  @spec bin_leak(map()) :: result()
  def bin_leak(options \\ %{}),
    do: options |> inspection("bin_leak", &InspectOptions.bin_leak/1) |> tracked("bin_leak")

  @doc """
  Lists the node's ports once (`insider.live-ports/v1`): counts by type
  (the first word of the port's name, such as `cat`) with their OS
  processes, then the ports matching `"type"` and `"owner"` (a registered
  name or pid) with their owner, OS pid, and I/O counters, and the owners
  holding the most of them, all from one read of at most
  `bounds.inspect.ports_scanned_max` ports. Option `"top"` bounds each
  list. A port's full name is returned only in the rich profile; when its
  arguments name a credential anywhere or hold anything a shell may rewrite
  (an escape, a control character, `$`, a backtick), the whole argument
  list is masked.
  """
  @spec ports(map()) :: result()
  def ports(options \\ %{}),
    do: options |> inspection("ports", &InspectOptions.ports/1) |> tracked("ports")

  @doc """
  Reports the VM's memory allocators once (`insider.live-alloc/v1`) with
  `recon_alloc`: allocated and used bytes, the share in use, bytes by
  allocator type, and the fragmentation of the `"top"` allocator instances
  with the largest multiblock carriers. Without recon on the node it is
  `component_unavailable` (component `recon`); the observer's `--load`
  pushes recon with Insider.
  """
  @spec alloc(map()) :: result()
  def alloc(options \\ %{}),
    do: options |> inspection("alloc", &InspectOptions.alloc/1) |> tracked("alloc")

  # The owner names the profile, the protected targets, and the session;
  # the inspection runs here, in a bounded worker. The masked result with
  # its metadata is then cut to the result bound (less the room the session
  # status takes), and only that exported result is projected into the
  # session.
  defp inspection(options, kind, parse) do
    with :ok <- allowed(),
         {:ok, parsed} <- parse.(options),
         {:ok, context} <- call({:inspect_context}, @control_timeout_ms),
         {:ok, result} <- Inspect.run(kind, parsed, context.profile, context.protection),
         {:ok, result} <- export(kind, result, context.profile) do
      {:ok, Map.put(result, "session", record_inspection(context.session_id, kind, result))}
    end
  end

  defp export(kind, result, profile) do
    {result, masks} = Credentials.mask(result)

    result =
      Map.merge(result, %{
        "node" => Atom.to_string(node()),
        "at" => DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
        "disclosure_profile" => Atom.to_string(profile),
        "redactions" => masks
      })

    case Inspect.fit_result(kind, result) do
      {:ok, result} -> {:ok, result}
      :too_large -> {:error, Error.new("unavailable", %{"reason" => "result_bytes"})}
    end
  end

  defp record_inspection(nil, _kind, _result), do: nil

  defp record_inspection(id, kind, result) do
    attributes = Inspect.event_attributes(kind, result)
    subject = if kind == "process", do: result["pid"]

    case call({:record_inspection, id, kind, attributes, subject}, @record_timeout_ms) do
      {:ok, recorded} ->
        recorded

      # The owner did not answer in time, so the write may have happened.
      {:error, %{"code" => "timeout"}} ->
        %{"session_id" => id, "recorded" => nil, "reason" => "outcome_unknown"}

      {:error, error} ->
        %{"session_id" => id, "recorded" => false, "reason" => error["code"]}
    end
  end

  @doc """
  Returns redacted events with a receipt greater than `cursor`, in receipt
  order, with explicit `"gaps"`, and renews the lease.

  `cursor` is an integer of at least 0, or `"latest"`: the newest receipt
  once the read has drained the collector inboxes, so the batch is empty and
  its `"next_cursor"` starts a tail; or `"mark"` (`"mark:LABEL"`): after the
  newest pairing mark (with that label, see `mark/2`), with the batch's
  `"mark"` naming it, else `mark_not_found`.

  Options: `"limit"` (events returned), `"max_bytes"` (canonical JSON bytes
  of the events returned), `"scan_limit"` (retained events examined),
  `"upto"` (the newest receipt the read may return, from the starting
  cursor, after `"latest"` resolves, to the newest receipt, else
  `invalid_options`; losses are counted only up to it), and `"view"`, a
  read-time filter that narrows only this reader's events.
  `"truncated_by"` names the bound that ended a truncated read. A read is
  complete when it reaches its snapshot boundary: `"upto"` when given, else
  the newest receipt when it began. Every batch reports `"filtered"` counts.
  Pass the returned `"next_cursor"` to the next call.
  """
  @spec events_since(String.t(), non_neg_integer() | String.t(), map()) :: result()
  def events_since(session_id, cursor, options \\ %{}) do
    {:events_since, session_id, cursor, options}
    |> call(@call_timeout_ms)
    |> tracked("events_since")
  end

  @doc """
  Marks the moment before an action as `insider.live-mark/v1`, for pairing
  with a programmer who acts in the app while the agent watches: mark
  ("about to click Confirm"), ask them to act, then read since the mark
  (`digest/2`, `trends/2` and `timeline/2` with `"since" => "mark"`,
  `events_since/3` with cursor `"mark"`; `"mark:LABEL"` for the newest mark
  with that label) instead of guessing a time or a cursor.

  Options: `"label"` (required; one line, credential-masked in every
  profile, at most `bounds.mark_label_max_bytes` bytes) and `"reader"`. The
  mark is the newest receipt now (`"cursor"`: a read since it starts after
  it), its time, label and reader, and is recorded as a `live.mark` event
  (`"recorded"` says whether; views never hide it). A session keeps its
  newest `bounds.marks_max` marks, through amendments and after a stop.
  `"next"` is the command to read since it. It renews the lease.
  """
  @spec mark(String.t(), map()) :: result()
  def mark(session_id, options) do
    with {:ok, request} <- Options.mark(options),
         {:ok, marked} <- call({:mark, session_id, request}, @record_timeout_ms) do
      {:ok,
       Map.put(
         marked,
         "next",
         "mix insider.live digest \"${N[@]}\" --session #{session_id} --since-mark --human"
       )}
    end
    |> tracked("mark")
  end

  @doc """
  Lists a running or stopped session's pairing marks as
  `insider.live-marks/v1`, oldest first, each with its `"age_ms"`, and how
  many older marks it let go (`"dropped"`). `"human"` adds `"text"`, one
  line per mark.
  """
  @spec marks(String.t(), map()) :: result()
  def marks(session_id, options \\ %{}) do
    with {:ok, %{human: human}} <- Options.marks(options) do
      call({:marks, session_id, human}, @control_timeout_ms)
    end
    |> tracked("marks")
  end

  @doc """
  Summarises a window of the session's events as `insider.live-digest/v1`,
  and renews the lease.

  The window starts at `"since"`: by default `"latest-60s"`, the first
  event the Recorder admitted in the last minute (`"latest-DURATION"` in
  whole `ms`, `s`, `m`, or `h`, 1 s to 24 h, measured on the Recorder's
  admission clock, not the events' own wall times); an integer cursor
  (0 is the session start); `"latest-N"` for the newest N receipts; or
  `"mark"` (`"mark:LABEL"`), after the newest pairing mark (with that label,
  see `mark/2`), with `"window"` `"mark"` naming it. It
  ends at `"upto"`, the newest receipt when the digest starts; events that arrive
  while it reads are left for the next digest. It is read with
  `events_since/3`, through the same disclosure boundary, and returns
  `"counts"` by kind, severity, source, and supervisor offender,
  `"crash_loops"` with their period and reason fingerprint, the top
  `"error_signatures"`, the `"latency"` tables from summaries and recorded
  durations with the summaries' exemplar receipts, `"trends"` across the
  summary windows (as `trends/2`), the Logger `"logger_bursts"`, the longest
  mailboxes (`"processes"`), `"vm"` deltas, and the window's `"filtered"`
  and `"gaps"`. One budget,
  `bounds.digest_budget_ms`, covers the `"latest-N"` lookup or the time
  window's start search and every read; a search it cannot finish is a
  `"timeout"`, and a start it could not narrow exactly has
  `"start_exact" => false`. The `"window"` says what was asked for
  (`"since"`), its start (`"from_wall_time"`), when the digest was made
  (`"as_of"`), and the age of its newest event (`"age_ms"`), and each hint
  names the `"window"` it was worked out over;
  an unfinished `"window"` has `"complete" => false` and the
  `"next_cursor"` to continue from. `"human" => true` adds `"text"`, a
  short plain-text summary for the developer.
  """
  @spec digest(String.t(), map()) :: result()
  def digest(session_id, options \\ %{}),
    do: session_id |> read_digest(options) |> tracked("digest")

  # One deadline, set before anything is read, bounds the `latest-N` lookup,
  # every read, and then the session's hint context (its configuration and
  # the Recorder's per-source usage as of the last read); each call gets
  # only what is left of it. A context that could not be read in time, or
  # an ended session's, leaves the digest without hints.
  @digest_context_ms 500
  @digest_context_floor_ms 50

  # A digest's or trends window reads with `events_since`, and a time
  # window's start is found with the owner's probes.
  # Every read of the window is the reader's, through its view.
  defp window_reader(session_id, reading) do
    fn
      cursor, %{"probe" => true}, budget ->
        call({:probe, session_id, cursor}, budget)

      cursor, options, budget ->
        call({:events_since, session_id, cursor, Map.merge(options, reading)}, budget)
    end
  end

  # The read options naming the reader and its view: the view given, or a
  # named reader's own view (asked of the owner once, so every read of one
  # operation uses the same view). Returns them and the effective view.
  defp reading(session_id, %{reader: reader, view: view}) do
    # A lookup that fails fails the read: reading on without the reader's
    # view would show it what its view hides, and would clear the view it
    # keeps. A view given (`nil` when cleared) is sent as given.
    stored =
      case {reader, view} do
        {nil, :keep} -> {:ok, :none}
        {reader, :keep} -> call({:reader_view, session_id, reader}, @control_timeout_ms)
        {_reader, given} -> {:ok, {:given, given}}
      end

    with {:ok, found} <- stored do
      {send?, view} =
        case found do
          :none -> {false, nil}
          {:given, given} -> {true, given}
          own -> {own != nil, own}
        end

      options =
        %{}
        |> then(&if(reader, do: Map.put(&1, "reader", reader), else: &1))
        |> then(&if(send?, do: Map.put(&1, "view", view), else: &1))

      {:ok, options, view}
    end
  end

  # A result read through a view says which reader read it, the view, and
  # what the view hid; a human text adds one line about it.
  defp put_reading(result, reader, view, hidden, human? \\ false) do
    result =
      result
      |> Map.put("view", view)
      |> then(&if(reader, do: Map.put(&1, "reader", reader), else: &1))

    if human? && view && Map.has_key?(result, "text"),
      do: Map.update!(result, "text", &(&1 <> "\n" <> view_line(reader, hidden))),
      else: result
  end

  defp view_line(reader, hidden) do
    hidden = hidden || %{}
    total = hidden |> Map.values() |> Enum.sum()

    detail =
      hidden
      |> Enum.reject(fn {_filter, count} -> count == 0 end)
      |> Enum.sort()
      |> Enum.map_join(", ", fn {filter, count} -> "#{filter} #{count}" end)

    who = if reader, do: "View of reader #{reader}", else: "This view"
    detail = if detail == "", do: "", else: " (#{detail})"
    "#{who} hid #{total} events#{detail}; recording unchanged, other readers unaffected."
  end

  # A view the reader set on an earlier read hides events from this digest
  # without this read naming it (it can hide the events that decide a
  # question), so the text says so right after its first line.
  defp put_stored_view(digest, reader, view, hidden) do
    digest = put_reading(digest, reader, view, hidden)
    total = (hidden || %{}) |> Map.values() |> Enum.sum()

    if total == 0 do
      digest
    else
      filters =
        view
        |> Enum.sort()
        |> Enum.map_join("; ", fn {key, values} ->
          "#{key} #{Enum.join(List.wrap(values), ", ")}"
        end)

      note =
        "Note: reader #{reader}'s stored view (set by an earlier read: #{filters}) hid #{total} events " <>
          "from this digest; add --view-clear to read everything."

      Map.update!(digest, "text", fn text ->
        [header | rest] = String.split(text, "\n", parts: 2)
        Enum.join([header, note | rest], "\n")
      end)
    end
  end

  # A window since a pairing mark starts at the mark the owner finds now,
  # before the digest's own budget starts.
  defp since_mark(session_id, {:mark, label}) do
    with {:ok, mark} <- call({:mark_lookup, session_id, label}, @control_timeout_ms),
         do: {:ok, {:mark, mark}}
  end

  defp since_mark(_session_id, since), do: {:ok, since}

  defp read_digest(session_id, options) do
    with {:ok, %{since: since, human: human} = parsed} <- Options.digest(options),
         {:ok, since} <- since_mark(session_id, since),
         {:ok, reading, view} <- reading(session_id, parsed) do
      deadline = System.monotonic_time(:millisecond) + Options.digest_budget_ms()
      reader = window_reader(session_id, reading)

      context = fn ->
        remaining = deadline - System.monotonic_time(:millisecond)

        with true <- remaining >= @digest_context_floor_ms,
             {:ok, context} <-
               call({:hint_context, session_id}, min(remaining, @digest_context_ms)) do
          # The kept mutation records the reader's view shows name writers
          # whose request events were evicted (`Insider.Live.Changes`).
          kept =
            case call({:mutations, session_id, [], reading}, min(remaining, @digest_context_ms)) do
              {:ok, %{"records" => records}} -> records
              _unavailable -> []
            end

          context |> Hints.context() |> Map.put(:mutations, kept)
        else
          _none -> nil
        end
      end

      case Digest.read(session_id, since, reader, deadline, Atom.to_string(node()), context) do
        {:ok, digest} ->
          digest =
            digest
            |> Anomalies.fold(known_normal(session_id))
            |> Map.put("show_baseline", parsed.show_baseline)

          digest = if human, do: Map.put(digest, "text", Digest.text(digest)), else: digest
          hidden = get_in(digest, ["filtered", "view"])

          if human and parsed.view == :keep and view != nil,
            do: {:ok, put_stored_view(digest, parsed.reader, view, hidden)},
            else: {:ok, put_reading(digest, parsed.reader, view, hidden, human)}

        other ->
          other
      end
    end
  end

  @doc """
  Returns one trace as `insider.live-trace/v1`: the spans the session
  recorded with this W3C `trace_id` (32 lowercase hex digits) merged in time
  order with the Logger and Telemetry events of the same trace, and renews
  the lease.

  An event joins by its trace id; an event without one joins when the
  process that emitted it ended one of the trace's spans and its time falls
  inside that span. Each item has `"at"`, `"depth"` in the span tree,
  `"span_id"` (the span it belongs to), `"joined_by"`, and the disclosed
  `"event"`. `"unjoined"` says what could not be joined (parent spans that
  were not captured, events without a time), `"scan"` how much of the
  session was read (`"complete"` is false when the read budget ran out),
  and `"gaps"` what the reads lost. Options: `"limit"` (items, default
  200), `"max_bytes"` (default 262,144), and `"human"`, which adds
  `"text"`, an indented plain-text rendering.
  """
  @spec trace(String.t(), String.t(), map()) :: result()
  def trace(session_id, trace_id, options \\ %{}) do
    with {:ok, parsed} <- Options.trace(trace_id, options),
         {:ok, reading, view} <- reading(session_id, parsed),
         {:ok, kept} <- trace_retention(session_id, parsed, reading),
         {:ok, scan, ending} <- scan_session(session_id, reading) do
      scan = Timeline.retained(scan, kept["entries"], kept["retention"])
      parsed = Map.merge(parsed, %{ending: ending, hint: pin_hint(session_id, parsed, scan)})

      trace =
        scan |> Timeline.trace(parsed) |> put_kept_mutations(session_id, parsed.trace_id, reading)

      {:ok, scan_reading(trace, parsed, view, scan)}
    end
    |> tracked("trace")
  end

  # The session's kept mutation records of the trace (`Insider.Live.Mutations`)
  # through the reader's view, which outlive the Recorder's eviction; the
  # text names those the items do not show: evicted, or (still held) left
  # out by the scan's budget or the trace's bounds.
  defp put_kept_mutations(trace, session_id, trace_id, reading) do
    records =
      case call({:mutations, session_id, [trace_id: trace_id], reading}, @control_timeout_ms) do
        {:ok, %{"records" => records}} -> records
        _unavailable -> []
      end

    shown = MapSet.new(trace["items"], & &1["receipt"])

    lines =
      for record <- records, not MapSet.member?(shown, record["receipt"]) do
        Mutations.line(
          record,
          if(record["evicted"],
            do: "evicted from the Recorder",
            else: "still recorded, but not among the items shown"
          )
        )
      end

    trace = Map.put(trace, "mutations", records)

    if lines != [] and is_binary(trace["text"]) do
      [header | rest] = String.split(trace["text"], "\n", parts: 2)
      Map.put(trace, "text", Enum.join([header | lines] ++ rest, "\n"))
    else
      trace
    end
  end

  # What per-trace retention keeps of the trace (`Insider.Live.Retention`)
  # through the reader's view, pinning it first with `"retain"`. The owner
  # refuses values outside the rich profile before it changes anything.
  defp trace_retention(session_id, parsed, reading) do
    request = %{retain: parsed.retain, values: parsed.values, reading: reading}
    call({:trace_retention, session_id, parsed.trace_id, request}, @call_timeout_ms)
  end

  # The first time a trace that retention does not keep is read after the
  # Recorder evicted events in the range scanned, it says how to keep it.
  defp pin_hint(session_id, parsed, scan) do
    if is_nil(scan.retention) and Timeline.evicted(scan) > 0 do
      case call({:retention_hint, session_id, parsed.trace_id}, @control_timeout_ms) do
        {:ok, true} ->
          "pin a trace while the Recorder still holds it: trace --trace-id #{parsed.trace_id} --retain " <>
            "keeps it and its later events; --retain-traces N (start or amend) keeps the N most recently active traces"

        _no ->
          nil
      end
    end
  end

  @doc """
  Returns the correlated timeline of one process (`"pid"`, as events name it
  in `subject.value`) or one request (`"request_id"`, Plug's request id) as
  `insider.live-timeline/v1`, across every source, and renews the lease.

  A request's events are those carrying its id, the events of its
  processes within its time window, and the events and spans of its
  traces. Options as for `trace/3`, plus exactly one of `"pid"` and
  `"request_id"`.
  """
  @spec timeline(String.t(), map()) :: result()
  def timeline(session_id, options) do
    with {:ok, parsed} <- Options.timeline(options),
         {:ok, since} <- since_mark(session_id, parsed.since),
         {:ok, reading, view} <- reading(session_id, parsed),
         {:ok, scan, ending} <- scan_session(session_id, reading, since_floor(since)) do
      parsed = Map.merge(parsed, %{ending: ending, mark: mark_of(since)})
      timeline = Timeline.timeline(scan, parsed)
      {:ok, scan_reading(timeline, parsed, view, scan)}
    end
    |> tracked("timeline")
  end

  @changes_rows 256

  @doc """
  Lists the session's kept mutation records (`Insider.Live.Mutations`) as
  `insider.live-mutations/v1`, oldest first, through the reader's view:
  each mutation's operation, result, response typenames, time, trace,
  process, the client's user agent, and the record ids among its
  arguments (rich only), with the ring's accounting. `"id"` keeps the
  records whose arguments name that id; `"human"` adds `"text"`. The
  records outlive the Recorder's eviction. It renews the lease.
  """
  @spec mutations(String.t(), map()) :: result()
  def mutations(session_id, options \\ %{}) do
    with {:ok, parsed} <- Options.mutations(options),
         {:ok, reading, view} <- reading(session_id, parsed),
         filters = if(parsed.id, do: [id: parsed.id], else: []),
         {:ok, kept} <- call({:mutations, session_id, filters, reading}, @control_timeout_ms) do
      records = kept["records"]
      accounting = kept["accounting"]

      result =
        %{
          "schema" => "insider.live-mutations/v1",
          "session_id" => session_id,
          "id" => parsed.id,
          "records" => records,
          "mutations" => accounting
        }
        |> put_reading(parsed.reader, view, nil)

      header =
        "Kept mutations#{if parsed.id, do: " with id #{parsed.id}", else: ""}: #{length(records)} " <>
          "(the ring keeps #{accounting["records"]} of at most #{accounting["mutations_max"]}; " <>
          "dropped #{accounting["dropped"]}, missed_receipts #{accounting["missed_receipts"]})"

      text = Enum.join([header | Enum.map(records, &Mutations.line/1)], "\n")
      {:ok, if(parsed.human, do: Map.put(result, "text", text), else: result)}
    end
    |> tracked("mutations")
  end

  @doc """
  Returns who changed watched in-memory values (`"watch_writes"`) as
  `insider.live-changes/v1`: each write, oldest first, with its key, its
  value (rich only), and its writer (the process, and the GraphQL
  operation, route, user agent, user id, and trace id of the request it
  belonged to, from that process's events, else from the session's kept
  mutation record). `"key"` keeps one key's writes; `"human"` adds `"text"`.
  It reads the session newest first, within the correlated budget, through
  the reader's view, and renews the lease.
  """
  @spec changes(String.t(), map()) :: result()
  def changes(session_id, options \\ %{}) do
    with {:ok, parsed} <- Options.changes(options),
         {:ok, reading, view} <- reading(session_id, parsed),
         {:ok, scan, ending} <- scan_session(session_id, reading),
         {:ok, kept} <- call({:mutations, session_id, [], reading}, @control_timeout_ms) do
      changes =
        scan.entries
        |> Enum.reverse()
        |> Changes.of(key: parsed.key, mutations: kept["records"])

      # Counts cover every write read; the rows are the newest
      # @changes_rows. A gap (evicted, or older receipts the budget left
      # unread) makes the counts lower bounds.
      report = Timeline.scan_report(scan, %{ending: ending})
      complete = report["gaps"] == []
      shown = Enum.take(changes, -@changes_rows)

      result =
        %{
          "schema" => "insider.live-changes/v1",
          "session_id" => session_id,
          "key" => parsed.key,
          "writes" => length(changes),
          "shown" => length(shown),
          "omitted" => length(changes) - length(shown),
          "changes" => shown,
          "repeated" => Changes.repeated(changes, complete),
          "mutations" => kept["accounting"]
        }
        |> Map.merge(report)
        |> put_reading(parsed.reader, view, Map.get(scan, :view_hidden))

      text = Enum.join(Changes.lines(shown, parsed.key, length(changes)), "\n")

      incomplete =
        if complete,
          do: "",
          else:
            "\nIncomplete: " <>
              Enum.map_join(report["gaps"], ", ", &"#{&1["count"] || "?"} #{&1["reason"]}") <>
              "; earlier writes may be missing"

      {:ok, if(parsed.human, do: Map.put(result, "text", text <> incomplete), else: result)}
    end
    |> tracked("changes")
  end

  # Newest first, within the correlated budget (`Insider.Live.TimelineScan`).
  # Each read is bounded by what is left of the budget.
  defp scan_session(session_id, reading, floor \\ 0) do
    budget = Options.correlated_budget_ms()
    deadline = System.monotonic_time(:millisecond) + budget

    reader = fn id, cursor, options ->
      remaining = deadline - System.monotonic_time(:millisecond)
      request = TimelineScan.request(id, cursor, Map.merge(options, reading))
      call(request, max(min(remaining, @call_timeout_ms), 1))
    end

    TimelineScan.run(session_id, reader, budget, floor: floor)
  end

  # The receipt a read since a cursor or a pairing mark starts after.
  defp since_floor({:cursor, cursor}), do: cursor
  defp since_floor({:mark, mark}), do: mark["cursor"]

  defp mark_of({:mark, mark}), do: mark
  defp mark_of(_since), do: nil

  # What the reader's view hid across a scan's pages is `"filtered_view"`.
  defp scan_reading(result, parsed, view, scan) do
    result
    |> put_reading(parsed.reader, view, nil)
    |> Map.put("filtered_view", Map.get(scan, :view_hidden) || %{})
    |> then(fn result ->
      if parsed.human && view && is_binary(result["text"]),
        do:
          Map.update!(
            result,
            "text",
            &(&1 <> "\n" <> view_line(parsed.reader, result["filtered_view"]))
          ),
        else: result
    end)
  end

  @doc """
  Trends across a window's summary windows, as `insider.live-trends/v1`, and
  renews the lease.

  The window is a digest's (`"since"`, read through `events_since/3` within
  `bounds.digest_budget_ms`). For each summarised Telemetry kind,
  `"telemetry"` lists its windows (`started_at`, `ended_at`, `count`,
  `rate_per_min`, `errors`, `error_pct`, `p50_us`, `p95_us`, `max_us`, the
  exemplar receipts, `exemplars_lost`, and `first_error_retained`) and the
  change of rate, p95, max, errors and error share from the first window to
  the last, with its direction. Its `"duration_scope"` is the summaries':
  `"measured_in"` is `"handler"` or `"caller"` only when the session
  declared it (`"telemetry_duration_scopes"`), else `"unknown"`, and
  `"emitter"` is only the context the exemplars were emitted in. A note
  compares a declared handler series with a declared caller series only
  conditionally: Insider does not establish that they describe the same
  operation. `"logger"` lists each Logger burst's windows, one series per
  template fingerprint, call site fingerprint, and level, and each level's
  overflow row. `"poller"` lists Poller series, one point per poller cycle:
  `binary_bytes` and `port_count` per `vm_sample`, ports per type per
  `port_top` (a zero only at a complete census), and `message_queue_len`
  per ranked or watched process (`"coverage"` `ranked`, `watched`, or
  `mixed`), each with `"unit"`, `"change"`, `"per_min"`, `"max"`, and its
  points; `"poller_omitted"` and `"poller_untracked"` count what the bounds
  left out. `"units"` names every value's fixed unit, and `"notes"` what
  the series show together. Options: `"since"`, `"kinds"` (the Telemetry
  kinds to show, `"logger_summary"` for the bursts, and `"vm_sample"`,
  `"port_top"`, `"process_top"` or `"process_watch"` for the Poller
  series), `"windows"` (the most recent windows per series), and
  `"human"`, which adds `"text"`.
  """
  @spec trends(String.t(), map()) :: result()
  def trends(session_id, options \\ %{}) do
    result =
      with {:ok, %{since: since, human: human, kinds: kinds, windows: windows} = parsed} <-
             Options.trends(options),
           {:ok, since} <- since_mark(session_id, since),
           deadline = System.monotonic_time(:millisecond) + Options.digest_budget_ms(),
           {:ok, reading, view} <- reading(session_id, parsed),
           reader = window_reader(session_id, reading),
           {:ok, digest, rows} <-
             Digest.read_window(session_id, since, reader, deadline, Atom.to_string(node())) do
        document = Trends.document(digest, rows, kinds, windows)
        document = if human, do: Map.put(document, "text", Trends.text(document)), else: document
        hidden = get_in(digest, ["filtered", "view"])

        {:ok,
         document
         |> put_reading(parsed.reader, view, hidden, human)
         |> Map.put("filtered_view", hidden || %{})}
      end

    tracked(result, "trends")
  end

  @doc "Renews the session lease."
  @spec renew(String.t()) :: result()
  def renew(session_id), do: {:renew, session_id} |> call(@control_timeout_ms) |> tracked("renew")

  @doc """
  Reports a running session, or the retained record of an ended one.

  A running session's record carries `"next_receipt"`, the newest receipt;
  `"recorder"`: `"oldest_receipt"`, `"retained_events"`, `"retained_bytes"`,
  `"max_events"`, `"max_bytes"`, `"archived_events"` (events kept from
  before the last amendment), and `"sources"`, each share group's
  `"share_percent"`, `"reserved_events"`, `"reserved_bytes"`,
  `"retained_events"`, `"retained_bytes"`, and `"evicted"` (conservative:
  after a collector is killed mid-write it can exceed the events really
  evicted, never fall short; a batch's `"evicted"` gap stays exact); and
  `"insider_memory"`: `"processes"` (bytes per Insider process serving the
  session), `"processes_bytes"`, `"recorder_bytes"` (the Recorder's tables
  and event binaries), and `"total_bytes"`. It lists `"readers"`, each
  named reader with its `"cursor"`, `"behind"`, `"last_seen_ms_ago"`,
  `"last_seen_at"`, `"subscribed"`, and `"active"`, and the latest
  `"amendments"`. An ended session still readable after a stop carries
  `"readable_remaining_ms"` and its readers.
  """
  @spec status(String.t()) :: result()
  def status(session_id) do
    case call({:status, session_id}, @control_timeout_ms) do
      {:ok, %{"state" => "running"} = status} -> {:ok, put_anomalies(status, session_id)}
      other -> other
    end
    |> tracked("status")
  end

  # A running session's status leads with the last minute's anomalies
  # (`Insider.Live.Anomalies`), from observing reads: they renew no lease,
  # keep no cursor or view, and never end or revoke the session (a denied
  # environment is refused, not acted on). At most @status_anomalies_ms.
  @status_anomalies_ms 1_500

  defp put_anomalies(status, session_id) do
    deadline = System.monotonic_time(:millisecond) + @status_anomalies_ms
    {:ok, %{since: since}} = Options.digest(%{"since" => Anomalies.status_window()})

    reader = fn
      cursor, %{"probe" => true}, budget ->
        call({:probe, session_id, cursor, :observe}, budget)

      cursor, options, budget ->
        call({:events_since, session_id, cursor, options, :observe}, budget)
    end

    result =
      case Digest.read(session_id, since, reader, deadline, Atom.to_string(node())) do
        {:ok, digest} -> {:ok, Anomalies.fold(digest, known_normal(session_id, :observe))}
        other -> other
      end

    Map.merge(status, Anomalies.status(result))
  end

  # The session's known-normal baseline, or `nil` (none, or unreadable).
  # `status` reads it observing: no lease renewed, no session revoked.
  defp known_normal(session_id, mode \\ :get) do
    case call({:known_normal, session_id, mode}, @control_timeout_ms) do
      {:ok, baseline} -> baseline
      _unavailable -> nil
    end
  end

  @doc """
  Marks the anomalies of a digest window normal for this session, as
  `insider.live-baseline/v1`: every candidate's kind, hashed identity, and
  count over its window (never its line, names, or values), with the
  earlier entries the window does not have. Later digests and `status` fold them into one
  line and lead with what is new; one that reaches ten times its baseline
  comes back, saying so. `"since"` is the window (default `latest-5m`),
  read through the reader's view; `"show"` returns the baseline, `"clear"`
  removes it. The session keeps it for its life and its read-only window.
  A window without anomalies leaves the baseline as it was.
  """
  @spec baseline(String.t(), map()) :: result()
  def baseline(session_id, options \\ %{}) do
    with {:ok, parsed} <- Options.baseline(options) do
      session_id |> put_baseline(parsed) |> baseline_text(session_id, parsed)
    end
    |> tracked("baseline")
  end

  defp put_baseline(session_id, %{action: :show}) do
    with {:ok, baseline} <- call({:known_normal, session_id, :get}, @control_timeout_ms),
         do: {:ok, baseline, nil}
  end

  defp put_baseline(session_id, %{action: :clear}) do
    with {:ok, previous} <- call({:known_normal, session_id, {:put, nil}}, @control_timeout_ms),
         do: {:ok, nil, previous}
  end

  defp put_baseline(session_id, %{action: :set} = parsed) do
    options =
      %{"since" => since_option(parsed.since)}
      |> then(&if(parsed.reader, do: Map.put(&1, "reader", parsed.reader), else: &1))
      |> then(&if(parsed.view != :keep, do: Map.put(&1, "view", parsed.view), else: &1))

    # Every candidate of the window is marked, with the earlier entries the
    # window does not have, so baselining again marks what is shown now.
    with {:ok, digest} <- read_digest(session_id, options),
         {:ok, previous} <- call({:known_normal, session_id, :get}, @control_timeout_ms) do
      anomalies = Anomalies.candidates(digest)
      since = get_in(digest, ["window", "since"])

      if anomalies == [] do
        {:ok, previous, {:unchanged, since}}
      else
        set_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        baseline = Anomalies.baseline(digest, set_at, since, previous)

        with {:ok, previous} <-
               call({:known_normal, session_id, {:put, baseline}}, @control_timeout_ms),
             do: {:ok, baseline, {:set, previous, anomalies}}
      end
    end
  end

  defp since_option({:cursor, cursor}), do: cursor
  defp since_option({:last, last}), do: "latest-#{last}"
  defp since_option({:recent, ms}), do: "latest-#{ms}ms"
  defp since_option({:mark, nil}), do: "mark"
  defp since_option({:mark, label}), do: "mark:" <> label

  defp baseline_text({:ok, baseline, outcome}, session_id, parsed) do
    result = %{
      "schema" => "insider.live-baseline/v1",
      "session_id" => session_id,
      "action" => Atom.to_string(parsed.action),
      "baseline" => baseline
    }

    text =
      case {parsed.action, outcome} do
        {:show, _none} ->
          Anomalies.baseline_lines(baseline)

        {:clear, nil} ->
          "No baseline was set; digests and status show every anomaly."

        {:clear, previous} ->
          n = length(previous["entries"])

          "Cleared the baseline (#{n} #{if n == 1, do: "signature", else: "signatures"}); " <>
            "digests and status show every anomaly again."

        {:set, {:unchanged, since}} ->
          "No anomalies #{window_words(since)} to mark normal; the baseline is unchanged."

        {:set, {:set, _previous, anomalies}} ->
          n = length(anomalies)

          Enum.join(
            [
              "Marked #{n} #{if n == 1, do: "anomaly", else: "anomalies"} normal for this session at " <>
                "#{String.slice(baseline["set_at"], 11, 5)} (window #{window_words(baseline["since"])}):"
              | Enum.map(anomalies, &"  - #{&1["line"]}")
            ] ++
              [
                "Later digests and status hide them unless one reaches 10x its rate; see them with " <>
                  "digest --show-baseline, clear with: mix insider.live baseline \"${N[@]}\" --session #{session_id} --clear"
              ],
            "\n"
          )
      end

    {:ok, if(parsed.human, do: Map.put(result, "text", text), else: result)}
  end

  defp baseline_text(error, _session_id, _parsed), do: error

  defp window_words(since) when is_integer(since), do: "since receipt #{since}"
  defp window_words(since), do: "in #{since}"

  @doc """
  Stops the session and returns its record with the cleanup receipt.

  It refuses with `"readers_active"` while another named reader read within
  `reader_active_ms` or is subscribed, unless `"force"` is `true`. Unnamed
  readers never hold a stop. `"reader"` names who stops, so that reader's own reads do not
  count. A stopped session stays readable with `events_since/3` for
  `stopped_readable_ms` (its record's `"readable_until"`), so peers can
  drain it. Stopping an ended session returns its record again.
  """
  @spec stop(String.t(), map()) :: result()
  def stop(session_id, options \\ %{}),
    do: {:stop, session_id, options} |> call(@stop_timeout_ms) |> tracked("stop")

  @doc """
  Changes a running session's recording options without losing its
  history: every start option given replaces the session's value (a list
  replaces the whole list) and the rest keep theirs. `"reader"` names who
  amends.

  The session keeps its id, cursors, readers, and subscribers. Its events so
  far stay readable, and the next receipt is a `live.session_amended` event
  that every reader sees through any view: what changed, from and to, and
  `"uncollected_ms"`, the pause in collection while the collectors
  restarted. Returns `insider.live-amendment/v1`; `"amend_failed"` when the
  new options could not start (`"rolled_back"` says whether the previous
  ones run again).

  A `"telemetry_events"` prefix entry such as `["shop", "*"]` is expanded
  as `start/1` expands it, in this process before the owner is asked, and
  the result lists each prefix's names under `"telemetry_event_prefixes"`.
  """
  @spec amend(String.t(), map()) :: result()
  def amend(session_id, options) do
    result =
      with :ok <- prefix_allowed(options),
           {:ok, options, prefixes} <- Discovery.expand_prefixes(options),
           {:ok, amended} <- call({:amend, session_id, options}, @amend_timeout_ms) do
        {:ok, Map.put(amended, "telemetry_event_prefixes", prefixes)}
      end

    tracked(result, "amend")
  end

  @doc """
  A handoff record (`insider.live-handoff/v1`) for passing a session to
  another agent: the node, the welcome hash, the session id and state, its
  recording configuration (which every reader shares), its named readers
  with their cursors, the newest receipt, and the commands that resume it.
  It reads the session's status and changes nothing. The observer command
  is `handoff`. (`handoff/1` is the name the production-artifact boundary
  reserves for a host delivery client, so this is `handoff_record/1`.)
  """
  @spec handoff_record(String.t()) :: result()
  def handoff_record(session_id) do
    case {:status, session_id} |> call(@control_timeout_ms) do
      {:ok, status} -> {:ok, build_handoff(status)} |> tracked("handoff_record")
      {:error, _error} = failure -> tracked(failure, "handoff_record")
    end
  end

  defp build_handoff(status) do
    id = status["session_id"]

    resume =
      Enum.map(status["readers"], fn reader ->
        "mix insider.live events \"${N[@]}\" --session #{id} --cursor #{reader["cursor"]} --reader #{reader["name"]}"
      end)

    %{
      "schema" => "insider.live-handoff/v1",
      "node" => Atom.to_string(node()),
      "welcome_hash" => Welcome.hash(),
      "session_id" => id,
      "state" => status["state"],
      "next_receipt" => status["next_receipt"],
      "readable_until" => status["readable_until"],
      "configuration" =>
        Map.take(status, [
          "components",
          "disclosure_profile",
          "filters",
          "lease_ms",
          "max_events",
          "poller",
          "scope",
          "telemetry_events",
          "telemetry_measurements"
        ]),
      "readers" =>
        Enum.map(status["readers"], &Map.take(&1, ["name", "cursor", "behind", "last_seen_at"])),
      "resume" => %{
        "observer" => resume,
        "join" =>
          "mix insider.live events \"${N[@]}\" --session #{id} --cursor latest --reader NAME",
        "note" =>
          "Continue from a reader's cursor with your own --reader name; recording options are shared by every reader, views are yours."
      }
    }
  end

  @doc """
  Pushes `{:insider_live_events, session_id, batch}` messages to `pid`.

  A batch has the `events_since/3` shape, and each batch starts at the
  `"next_cursor"` of the one before it. The owner monitors `pid` and drops
  it when it exits or its node disconnects. The subscription does not renew
  the lease and ends with one batch whose `"state"` is terminal and which
  carries the `"receipt"`. Options: `"cursor"` (default 0; an integer no
  newer than the newest receipt, or `"latest"`), `"max_events"` (the events
  pushed in total; then nothing more is sent but the terminal batch), and
  `"view"`, as for `events_since/3`. Subscribing again replaces the view and
  `"max_events"`, and moves the cursor only when one is given.
  """
  @spec subscribe(String.t(), pid(), map()) :: result()
  def subscribe(session_id, pid, options \\ %{}),
    do:
      {:subscribe, session_id, pid, options}
      |> call(@control_timeout_ms)
      |> tracked("subscribe")

  @doc "Removes a subscriber; removing an absent one succeeds."
  @spec unsubscribe(String.t(), pid()) :: result()
  def unsubscribe(session_id, pid),
    do: {:unsubscribe, session_id, pid} |> call(@control_timeout_ms) |> tracked("unsubscribe")

  @doc """
  Records spans exported by another process, such as a frontend server, in
  the running session as `otel.span` events.

  `spans` is a list of at most `Insider.Collector.Otel.ingest_max/0` plain
  span maps (`"trace_id"`, `"span_id"`, `"parent_span_id"`, `"name"`,
  `"span_kind"`, `"status"`, `"status_message"`, `"service"`, `"scope"`,
  `"start_time_us"`, `"duration_us"`, `"attributes"`, and `"pid"`). The
  session's otel component applies the span contract, its disclosure
  profile, and credential masking to each one, exactly as to the node's own
  spans, and records it with `"capture"` `"ingest"`. The result counts the
  spans `"accepted"`, `"rejected"` by the contract, `"filtered"`, `"shed"`
  under load, and `"duplicate"`.

  Ingest is idempotent per `{trace_id, span_id}` within one otel collector
  of the session: a span already recorded from an ingest is counted as
  `"duplicate"` and not recorded again (the collector remembers the last
  16,384 recorded ids; one it forgets is counted as `seen_evicted` in the
  otel component's status). Every amendment replaces the collector, even
  one rolled back into a replacement, and so resets dedupe: a span ingested
  before it is recorded again after it, and `seen_evicted` does not count
  that reset.

  A `timeout` means the outcome is **unknown**: the collector may have
  taken the spans and still be recording them when the call stops waiting,
  so some, all, or none may be recorded. A retry of the same spans does not
  duplicate a span while its id is among the last 16,384 recorded; a
  forgotten id is recorded again, and `seen_evicted` counts the forgotten
  ones; a retry across an amendment is recorded again.

  An ended session is `session_terminal`, and a session started without the
  `"otel"` component `component_unavailable`. The Lab's `otlp-receive`
  calls this for each OTLP/HTTP trace export it receives.
  """
  @spec ingest_spans(String.t(), [map()]) :: result()
  def ingest_spans(session_id, spans) do
    result =
      with :ok <- ingestible(spans),
           do: call({:ingest_spans, session_id, spans}, @call_timeout_ms)

    tracked(result, "ingest_spans")
  end

  defp ingestible(spans) when is_list(spans) do
    if length(spans) <= Otel.ingest_max(),
      do: :ok,
      else: {:error, Error.new("invalid_options", %{"field" => "spans"})}
  end

  defp ingestible(_spans), do: {:error, Error.new("invalid_options", %{"field" => "spans"})}

  @doc """
  Queues a report about Insider itself on this node.

  Report Insider bugs and any behaviour that differs from `welcome/1`.
  Options: `"category"`, one of `"bug"`, `"doc_mismatch"`,
  `"missing_capability"`, or `"confusing_output"`, and `"message"`, a
  printable text of at most 2,048 bytes. Insider adds the context itself: its
  version and commit, the welcome hash, the node, the environment, and the
  last operation and error code, never event payloads or option values.

  The queue is bounded memory in this node: a report whose fingerprint
  (category and normalised message) is already queued increments its
  `"count"`, and the oldest report is evicted beyond 100. Nothing leaves the
  node; the Lab observer's `reports` command copies the queue and its
  `reports submit` files GitHub issues only when the operator or host allows.
  """
  @spec report(map()) :: result()
  def report(options) do
    with :ok <- allowed(),
         {:ok, report} <- Options.report(options) do
      queue_result(Reports.report(report))
    end
  end

  @doc "Lists the reports queued on this node, oldest first."
  @spec reports() :: result()
  def reports do
    with :ok <- allowed(), do: queue_result(Reports.list())
  end

  defp allowed do
    environment = Environment.resolve()

    if Environment.allowed?(environment),
      do: :ok,
      else: {:error, Error.new("environment_denied", Environment.describe(environment))}
  end

  defp queue_result({:ok, result}), do: {:ok, result}

  defp queue_result({:error, reason}) when reason in [:unavailable, :busy, :timeout],
    do: {:error, Error.new(Atom.to_string(reason))}

  defp tracked(result, operation) do
    :ok = Reports.record_call(operation, result)
    result
  end

  # Every call acquires one bounded owner admission slot before its message
  # is queued and carries an absolute deadline. The owner refuses a request
  # it handles too late, so a `timeout` here never hides a side effect.
  defp call(request, budget_ms) do
    with pid when is_pid(pid) <- Process.whereis(Owner),
         {:ok, admission} <- Owner.admission(pid) do
      case Admission.acquire(admission, Owner.admitted_calls_max()) do
        :ok ->
          deadline = System.monotonic_time(:millisecond) + budget_ms
          message = {:admitted, admission, deadline, request}
          GenServer.call(pid, message, budget_ms + @outer_margin_ms)

        :overloaded ->
          {:error, Error.new("busy")}
      end
    else
      _absent -> owner_unavailable()
    end
  catch
    :exit, {:timeout, _call} -> {:error, Error.new("timeout")}
    :exit, _reason -> owner_unavailable()
  end

  defp owner_unavailable do
    with :ok <- allowed(), do: {:error, Error.new("unavailable")}
  end

  defp owner_state do
    case {Process.whereis(Owner), call({:active_session_id}, @capabilities_timeout_ms)} do
      {nil, _result} -> {false, false, nil}
      {_pid, {:ok, active}} -> {true, true, active}
      {_pid, {:error, _error}} -> {true, false, nil}
    end
  end
end

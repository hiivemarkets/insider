defmodule Insider.Lab.Live.CLI do
  @moduledoc false

  # `mix insider.live` and `insider-lab live`: one observer invocation per
  # command. Every one-shot operation writes exactly one canonical JSON
  # document; `watch` writes NDJSON until it is interrupted, the session ends
  # or the target goes down. `report` and `reports` work on the observer's
  # local report queue (`Insider.Lab.Live.Reports`); `reports` with a target
  # first copies the target's in-node queue into it.

  alias Insider.Adapter.CLI.Wire
  alias Insider.Event.Canonical
  alias Insider.Lab.Live.Chart
  alias Insider.Lab.Live.Format
  alias Insider.Lab.Live.Help
  alias Insider.Lab.Live.Installation
  alias Insider.Lab.Live.Invocation
  alias Insider.Lab.Live.Observer
  alias Insider.Lab.Live.Otlp
  alias Insider.Lab.Live.Reports
  alias Insider.Lab.Live.Watch
  alias Insider.Live.Options
  alias Insider.Live.Welcome

  @schema "insider.live-observer/v1"
  @error_schema "insider.live-observer-error/v1"
  @default_timeout_ms 5_000
  @max_timeout_ms 60_000
  @duration_units %{"ms" => 1, "s" => 1_000, "m" => 60_000, "h" => 3_600_000}
  @max_duration_ms 86_400_000
  # OTLP/HTTP's registered port.
  @default_otlp_port 4318

  # `--node` and `--cookie-file` name the target; `--timeout-ms`, `--load` and `--force-load`
  # apply only with one. Each operation's target is required, optional, or
  # not accepted. `Insider.Live.Welcome` documents this table, and a test
  # keeps the two equal.
  @target_flags [:node, :cookie_file, :timeout_ms, :load, :force_load]
  # Record-time filters (`start`) and read-time views (`events`, `watch`).
  @filter_repeatable [
    :logger_include,
    :logger_exclude,
    :logger_summary,
    :exclude_origin,
    :telemetry_event_min_duration,
    :telemetry_summary,
    :telemetry_duration_scope
  ]
  @filter_single [
    :logger_level,
    :logger_summary_interval_ms,
    :telemetry_min_duration_ms,
    :telemetry_summary_interval_ms,
    :otel_min_duration_ms
  ]
  @view_repeatable [
    :view_source,
    :view_kind,
    :view_exclude_kind,
    :view_exclude_signature,
    :view_service,
    :view_route,
    :view_trace
  ]
  @view_options @view_repeatable ++ [:view_min_severity, :view_clear]
  # Every read names its reader and reads through its view.
  @reading [:reader] ++ @view_options
  # The Poller's options (`Insider.Live.PollerOptions`).
  @poller_single [:poller_interval_ms, :top_processes, :top_ets_tables, :top_ports]
  # The call trace's options (`Insider.Live.CallsOptions`).
  @calls_single [:calls_results, :calls_max, :calls_rate_max, :calls_rate_ms, :calls_max_bytes]
  @repeatable [
                :component,
                :telemetry_event,
                :telemetry_measurement,
                :watch_process,
                :calls,
                :reset,
                :fingerprint,
                :kind,
                :collapse,
                :hide,
                :values_path,
                :watch_write
              ] ++
                @filter_repeatable ++ @view_repeatable
  # The recording options `start` takes; `amend` takes the same.
  @recording [
               :component,
               :telemetry_event,
               :telemetry_measurement,
               :lease_ms,
               :max_events,
               :retain_traces,
               :watch_write,
               :disclosure
             ] ++
               @filter_repeatable ++
               @filter_single ++ @poller_single ++ [:watch_process, :calls] ++ @calls_single
  # `amend --reset FLAG` sends that recording option as `nil`, which returns
  # it to its default: FLAG is the flag's name without the dashes, mapped to
  # the start option it sets.
  @plural %{
    component: "components",
    telemetry_event: "telemetry_events",
    telemetry_measurement: "telemetry_measurements",
    exclude_origin: "exclude_origins",
    logger_summary: "logger_summaries",
    telemetry_event_min_duration: "telemetry_event_min_duration_ms",
    telemetry_summary: "telemetry_summaries",
    telemetry_duration_scope: "telemetry_duration_scopes",
    watch_process: "watch_processes"
  }
  @resettable Map.new(@recording, fn flag ->
                {String.replace(Atom.to_string(flag), "_", "-"),
                 Map.get(@plural, flag, Atom.to_string(flag))}
              end)
  @fingerprint ~r/\A[0-9a-f]{16}\z/
  @session_id ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/
  @operations %{
    "welcome" => {:required, [], [:full, :reader]},
    "capabilities" => {:required, [], [:reader]},
    "discover" => {:required, [], [:prefix]},
    "process" => {:required, [], [:name, :pid, :frames, :messages]},
    "bin_leak" => {:required, [], [:top, :human]},
    "ports" => {:required, [], [:type, :owner, :top]},
    "alloc" => {:required, [], [:top]},
    "start" => {:required, [], @recording},
    "amend" => {:required, [:session], @recording ++ [:reader, :reset]},
    "events" =>
      {:required, [],
       [:session, :cursor, :since_mark, :limit, :max_bytes, :scan_limit, :format] ++ @reading},
    "digest" =>
      {:required, [], [:session, :since, :since_mark, :human, :show_baseline] ++ @reading},
    "baseline" =>
      {:required, [], [:session, :since, :since_mark, :clear, :show, :human] ++ @reading},
    "trends" =>
      {:required, [], [:session, :since, :since_mark, :human, :kind, :windows] ++ @reading},
    "mark" => {:required, [:label], [:session, :reader]},
    "marks" => {:required, [], [:session, :human, :reader]},
    "status" => {:required, [], [:session, :reader]},
    "handoff" => {:required, [], [:session, :reader]},
    "renew" => {:required, [], [:session, :reader]},
    "stop" => {:required, [:session], [:reader, :force]},
    "watch" => {:required, [], [:session, :from_cursor, :for, :max_events, :format] ++ @reading},
    "trace" =>
      {:required, [:trace_id],
       [:session, :limit, :max_bytes, :human, :collapse, :hide, :retain, :values, :values_path] ++
         @reading},
    "timeline" =>
      {:required, [],
       [:session, :pid, :request_id, :since_mark, :limit, :max_bytes, :human] ++ @reading},
    "changes" => {:required, [], [:session, :key, :human] ++ @reading},
    "mutations" => {:required, [], [:session, :id, :human] ++ @reading},
    "otlp-receive" => {:required, [:session], [:port, :bind, :for]},
    "chart" =>
      {:required, [], [:session, :since, :since_mark, :out, :serve, :port, :for, :reader]},
    "report" => {:none, [:category, :message], [:session]},
    "reports" => {:optional, [], [:fingerprint, :session]},
    "reports submit" => {:optional, [], [:confirm, :dry_run, :fingerprint, :session]}
  }
  # Every switch keeps each occurrence, so a repeated singleton is rejected
  # instead of OptionParser silently keeping its last value.
  @switches [
    full: [:boolean, :keep],
    show_baseline: [:boolean, :keep],
    clear: [:boolean, :keep],
    show: [:boolean, :keep],
    node: [:string, :keep],
    cookie_file: [:string, :keep],
    timeout_ms: [:integer, :keep],
    load: [:boolean, :keep],
    force_load: [:boolean, :keep],
    session: [:string, :keep],
    cursor: [:string, :keep],
    limit: [:integer, :keep],
    max_bytes: [:integer, :keep],
    scan_limit: [:integer, :keep],
    from_cursor: [:string, :keep],
    for: [:string, :keep],
    lease_ms: [:integer, :keep],
    max_events: [:integer, :keep],
    component: [:string, :keep],
    telemetry_event: [:string, :keep],
    collapse: [:string, :keep],
    key: [:string, :keep],
    id: [:string, :keep],
    watch_write: [:string, :keep],
    hide: [:string, :keep],
    retain: [:boolean, :keep],
    retain_traces: [:integer, :keep],
    values: [:boolean, :keep],
    values_path: [:string, :keep],
    telemetry_measurement: [:string, :keep],
    prefix: [:string, :keep],
    category: [:string, :keep],
    message: [:string, :keep],
    confirm: [:boolean, :keep],
    dry_run: [:boolean, :keep],
    fingerprint: [:string, :keep],
    logger_level: [:string, :keep],
    logger_include: [:string, :keep],
    logger_exclude: [:string, :keep],
    logger_summary: [:string, :keep],
    logger_summary_interval_ms: [:integer, :keep],
    exclude_origin: [:string, :keep],
    telemetry_min_duration_ms: [:integer, :keep],
    telemetry_event_min_duration: [:string, :keep],
    telemetry_summary: [:string, :keep],
    telemetry_summary_interval_ms: [:integer, :keep],
    telemetry_duration_scope: [:string, :keep],
    view_source: [:string, :keep],
    view_kind: [:string, :keep],
    view_exclude_kind: [:string, :keep],
    view_min_severity: [:string, :keep],
    view_exclude_signature: [:string, :keep],
    view_service: [:string, :keep],
    view_route: [:string, :keep],
    view_trace: [:string, :keep],
    view_clear: [:boolean, :keep],
    disclosure: [:string, :keep],
    poller_interval_ms: [:integer, :keep],
    top_processes: [:integer, :keep],
    top_ets_tables: [:integer, :keep],
    top_ports: [:integer, :keep],
    name: [:string, :keep],
    pid: [:string, :keep],
    frames: [:integer, :keep],
    messages: [:integer, :keep],
    top: [:integer, :keep],
    type: [:string, :keep],
    owner: [:string, :keep],
    watch_process: [:string, :keep],
    calls: [:string, :keep],
    calls_results: [:string, :keep],
    calls_max: [:integer, :keep],
    calls_rate_max: [:integer, :keep],
    calls_rate_ms: [:integer, :keep],
    calls_max_bytes: [:integer, :keep],
    format: [:string, :keep],
    since: [:string, :keep],
    since_mark: [:string, :keep],
    out: [:string, :keep],
    serve: [:boolean, :keep],
    label: [:string, :keep],
    human: [:boolean, :keep],
    kind: [:string, :keep],
    windows: [:integer, :keep],
    reader: [:string, :keep],
    force: [:boolean, :keep],
    reset: [:string, :keep],
    otel_min_duration_ms: [:integer, :keep],
    trace_id: [:string, :keep],
    request_id: [:string, :keep],
    port: [:integer, :keep],
    bind: [:string, :keep]
  ]

  # The exit statuses and the closed observer error vocabulary (code =>
  # {status, message}) are the welcome document's own tables.
  @exit_statuses Welcome.observer_exit_statuses()
  @codes Welcome.observer_errors()
  @quick_start_schema Welcome.quick_start_schema()
  @welcome_schemas [Welcome.schema(), Welcome.quick_start_schema()]
  # Short receipts of an action, which neither carry nor deliver the welcome
  # quick start: a first command among them leaves it for the next one.
  @receipts Welcome.observer_receipts()

  @doc false
  @spec switches() :: keyword()
  def switches, do: @switches

  @doc false
  @spec codes() :: %{String.t() => {String.t(), String.t()}}
  def codes, do: @codes

  @doc false
  @spec exit_statuses() :: %{String.t() => non_neg_integer()}
  def exit_statuses, do: @exit_statuses

  @doc false
  @spec operations() :: %{String.t() => {atom(), [atom()], [atom()]}}
  def operations, do: @operations

  @doc false
  @spec target_flags() :: [atom()]
  def target_flags, do: @target_flags

  @doc false
  @spec repeatable() :: [atom()]
  def repeatable, do: @repeatable

  @doc """
  Runs one observer command, writing its output through `writer`, and
  returns the exit status. `--help`, `help OPERATION`, and `OPERATION
  --help` write usage text instead and return `0`.

  Options: `:invocation` (the command that was run, named in help, usage
  errors, and the target's commands it prints: `"mix insider.live"`, the
  default, or `"insider-lab live"`), `:reports_directory` (default
  `Reports.default_directory/0`), `:gh` (the `gh` runner, default
  `Reports.gh/1`), `:submission` (the observer's own
  `Insider.Live.Report.submission/0` setting), and `:notice` (where
  `reports submit` prints its effective authorization before its first `gh`
  call, default standard error).
  """
  @spec run([String.t()], (iodata() -> term()), keyword()) :: non_neg_integer()
  def run(arguments, writer, options \\ [])
      when is_list(arguments) and is_function(writer, 1) and is_list(options) do
    environment = environment(options)
    writer = Invocation.writer(writer, environment.invocation)

    case parse(arguments, environment.invocation) do
      {:ok, command} ->
        execute(Map.put(command, :environment, environment), writer)

      {:help, text} ->
        emit_help(writer, text)

      {:error, code, details} ->
        Reports.remember_local(environment.reports_directory, attempted(arguments), code)
        emit_failure(writer, code, details)
    end
  rescue
    _error -> emit_failure(writer, "observer_failed", %{})
  end

  defp environment(options) do
    %{
      invocation: Keyword.get(options, :invocation, Invocation.default()),
      reports_directory:
        Keyword.get_lazy(options, :reports_directory, &Reports.default_directory/0),
      gh: Keyword.get(options, :gh, &Reports.gh/1),
      submission: Keyword.get_lazy(options, :submission, &Insider.Live.Report.submission/0),
      notice: Keyword.get(options, :notice, &IO.write(:stderr, &1))
    }
  end

  # The operation a command that failed to parse named, if it named one; any
  # other argument is the caller's text and is never recorded.
  defp attempted(["reports", "submit" | _arguments]), do: "reports submit"
  defp attempted([operation | _arguments]) when is_map_key(@operations, operation), do: operation
  defp attempted(_arguments), do: nil

  @doc """
  Parses one observer command line without running it: `{:ok, command}`,
  `{:help, text}`, or `{:error, code, details}`. Help and the `help` of an
  error name `invocation`, the command that was run. The welcome's quick
  start, recipes, and examples are checked with it.
  """
  @spec parse([String.t()], String.t()) ::
          {:ok, map()} | {:help, String.t()} | {:error, String.t(), map()}
  def parse(arguments, invocation \\ Invocation.default())

  def parse(arguments, invocation) when arguments in [["--help"], ["-h"], ["help"]],
    do: {:help, Help.overview(invocation)}

  # `help OPERATION` ignores the target flags a wrapper appends, so
  # `il help trace` is not a usage error.
  def parse(["help" | operation], invocation),
    do:
      operation
      |> Enum.take_while(&(not String.starts_with?(&1, "-")))
      |> Enum.join(" ")
      |> help(invocation)

  def parse(["reports", "submit" | arguments], invocation),
    do: parse_operation("reports submit", arguments, invocation)

  def parse([operation | arguments], invocation)
      when is_map_key(@operations, operation) and operation != "reports submit",
      do: parse_operation(operation, arguments, invocation)

  def parse(_arguments, invocation), do: usage(invocation)

  defp help(operation, invocation) when is_map_key(@operations, operation),
    do: {:help, Help.operation(operation, invocation)}

  defp help(_operation, invocation), do: usage(invocation)

  defp usage(invocation) do
    {:error, "usage",
     %{
       "operations" => Enum.sort(Map.keys(@operations)),
       "help" => "#{invocation} --help"
     }}
  end

  defp parse_operation(operation, arguments, invocation) do
    {options, positional, invalid} =
      arguments |> optional_values() |> OptionParser.parse(strict: @switches)

    if Enum.any?(invalid, fn {flag, _value} -> flag in ["--help", "-h"] end) do
      {:help, Help.operation(operation, invocation)}
    else
      operation
      |> validate(options, positional, invalid)
      |> explain(operation, invocation)
    end
  end

  defp validate(operation, options, positional, invalid) do
    {target_mode, required, _optional} = Map.fetch!(@operations, operation)
    target_required = if target_mode == :required, do: [:node, :cookie_file], else: []

    with :ok <- switches(invalid),
         :ok <- positional(positional),
         :ok <- only(options, accepted(operation)),
         :ok <- present(options, target_required ++ required),
         :ok <- target_complete(options),
         :ok <- single(options),
         {:ok, timeout_ms} <- timeout(options),
         {:ok, target} <- target(options),
         {:ok, arguments} <- operation_arguments(operation, options) do
      {:ok,
       %{
         operation: operation,
         target: target,
         cookie_file: Keyword.get(options, :cookie_file),
         timeout_ms: timeout_ms,
         load: load_mode(options),
         welcome: nil,
         incarnation: nil,
         arguments: arguments,
         given: options |> Keyword.keys() |> Enum.uniq() |> Enum.map(&option_name/1)
       }}
    end
  end

  # The switches an operation accepts: the target flags unless it takes no
  # target, then its required and optional ones.
  defp accepted(operation) do
    {target_mode, required, optional} = Map.fetch!(@operations, operation)
    if(target_mode == :none, do: [], else: @target_flags) ++ required ++ optional
  end

  # Every invalid option names the flag, the problem, and the value it
  # expects (or, for a flag it does not take, the flags it does), and points
  # to the command's help.
  defp invalid(flag, problem, extra \\ %{}),
    do: {:error, "invalid_options", Map.merge(extra, %{"option" => flag, "problem" => problem})}

  defp explain({:error, "invalid_options", details}, operation, invocation) do
    {:error, "invalid_options",
     Map.merge(details, %{
       "expected" => expected(operation, details),
       "help" => "#{invocation} help #{operation}"
     })}
  end

  defp explain(result, _operation, _invocation), do: result

  defp expected(operation, %{"problem" => problem} = details)
       when problem in ["unknown", "not_accepted", "positional_argument"] do
    flags = operation |> accepted() |> Enum.map(&option_name/1) |> Enum.join(", ")

    works_on =
      case details do
        %{"accepted_by" => [_ | _] = by, "option" => flag} ->
          "#{flag} is not a #{operation} flag; it works on #{by |> Enum.sort() |> Enum.join(", ")}. "

        _other ->
          ""
      end

    works_on <> "#{operation} takes every value after its flag; its flags are #{flags}"
  end

  defp expected(operation, %{"option" => flag}), do: Help.value(operation, flag)

  # OptionParser reports an unknown switch, or a known one without a valid
  # value (`--cursor abc`, or a trailing `--session`). No error echoes a
  # value, which may be a secret typed into the wrong place: an unknown flag
  # is named only when it is shaped like a flag name (lowercase words joined
  # by dashes), and a positional argument is never named.
  @flag_shape ~r/\A--[a-z]+(-[a-z]+)*\z/

  defp switches([]), do: :ok

  defp switches([{flag, _value} | _rest]) do
    known = Enum.map(Keyword.keys(@switches), &option_name/1)

    cond do
      flag in known -> invalid(flag, "malformed")
      byte_size(flag) <= 40 and Regex.match?(@flag_shape, flag) -> invalid(flag, "unknown")
      true -> invalid(nil, "unknown")
    end
  end

  defp positional([]), do: :ok
  defp positional([_argument | _rest]), do: invalid(nil, "positional_argument")

  defp only(options, allowed) do
    case options |> Keyword.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.uniq() do
      [] ->
        :ok

      [first | _rest] = extra ->
        invalid(option_name(first), "not_accepted", %{
          "unexpected" => Enum.map(extra, &option_name/1),
          "accepted_by" => accepted_by(first)
        })
    end
  end

  # The operations that take a flag, for an error about one that does not.
  defp accepted_by(flag) do
    Enum.sort(
      for {operation, {_target, required, optional}} <- @operations,
          flag in required or flag in optional,
          do: operation
    )
  end

  defp present(options, required) do
    case Enum.reject(required, &Keyword.has_key?(options, &1)) do
      [] ->
        :ok

      [first | _rest] = missing ->
        invalid(option_name(first), "missing", %{"missing" => Enum.map(missing, &option_name/1)})
    end
  end

  # `--force-load` is `--load` that may also end a running session.
  defp load_mode(options) do
    cond do
      Keyword.get(options, :force_load, false) -> :force
      Keyword.get(options, :load, false) -> :load
      true -> false
    end
  end

  # An optional target is all or nothing: `--node` needs `--cookie-file`, and
  # `--cookie-file`, `--timeout-ms`, `--load` and `--force-load` need `--node`.
  defp target_complete(options) do
    if Keyword.has_key?(options, :node) do
      present(options, [:cookie_file])
    else
      case Enum.find(@target_flags, &Keyword.has_key?(options, &1)) do
        nil -> :ok
        flag -> invalid(option_name(flag), "requires_node")
      end
    end
  end

  defp single(options) do
    repeated =
      options
      |> Keyword.keys()
      |> Enum.frequencies()
      |> Enum.filter(fn {key, count} -> count > 1 and key not in @repeatable end)
      |> Enum.map(&option_name(elem(&1, 0)))

    case repeated do
      [] -> :ok
      [first | _rest] -> invalid(first, "repeated", %{"repeated" => repeated})
    end
  end

  defp timeout(options) do
    case Keyword.get(options, :timeout_ms, @default_timeout_ms) do
      value when value in 1..@max_timeout_ms -> {:ok, value}
      _out_of_range -> invalid("--timeout-ms", "out_of_range")
    end
  end

  defp target(options) do
    case Keyword.fetch(options, :node) do
      {:ok, node} -> Observer.parse_target(node)
      :error -> {:ok, nil}
    end
  end

  defp option_name(key), do: "--" <> String.replace(Atom.to_string(key), "_", "-")

  # Values pass through to `Insider.Live` unchanged apart from splitting a
  # dotted Telemetry event name into its segments; the target validates them.
  defp operation_arguments("start", options), do: recording(options)

  # Each recording flag given replaces that option on the running session,
  # and each `--reset FLAG` returns one to its default; the target merges
  # and validates them as for start.
  defp operation_arguments("amend", options) do
    with {:ok, amend} <- recording(options),
         {:ok, amend} <- put_resets(amend, Keyword.get_values(options, :reset)) do
      {:ok,
       %{
         session: session(options),
         options: put_value(amend, "reader", Keyword.get(options, :reader))
       }}
    end
  end

  defp operation_arguments("events", options) do
    with {:ok, cursor} <- read_start(options),
         {:ok, read} <- put_positive(%{}, "limit", Keyword.get(options, :limit), "--limit"),
         {:ok, read} <-
           put_positive(read, "max_bytes", Keyword.get(options, :max_bytes), "--max-bytes"),
         {:ok, read} <-
           put_positive(read, "scan_limit", Keyword.get(options, :scan_limit), "--scan-limit"),
         {:ok, format} <- format(Keyword.get(options, :format)) do
      {:ok,
       %{
         session: session(options),
         cursor: cursor,
         options: read |> put_view(options) |> put_value("reader", Keyword.get(options, :reader)),
         format: format
       }}
    end
  end

  # `--since` is an integer cursor or `latest-N`, which the target validates;
  # `--since-mark` is a pairing mark, in its place.
  defp operation_arguments(operation, options) when operation in ["digest", "trends"] do
    human? = Keyword.get(options, :human, false)

    with {:ok, since} <- window_since(options) do
      window =
        %{}
        |> put_value("since", since)
        |> put_list("kinds", Keyword.get_values(options, :kind))
        |> put_value("windows", Keyword.get(options, :windows))
        |> put_view(options)
        |> put_value("reader", Keyword.get(options, :reader))
        |> put_value("show_baseline", Keyword.get(options, :show_baseline))

      {:ok,
       %{
         session: session(options),
         options: if(human?, do: Map.put(window, "human", true), else: window),
         human?: human?
       }}
    end
  end

  defp operation_arguments("mark", options) do
    {:ok,
     %{
       session: session(options),
       options:
         %{"label" => Keyword.fetch!(options, :label)}
         |> put_value("reader", Keyword.get(options, :reader))
     }}
  end

  defp operation_arguments("marks", options) do
    human? = Keyword.get(options, :human, false)

    {:ok,
     %{
       session: session(options),
       options: if(human?, do: %{"human" => true}, else: %{}),
       human?: human?
     }}
  end

  # The report is validated here by the same rule the node applies; an
  # explicit `--session` is the session its context cites.
  defp operation_arguments("report", options) do
    report = %{
      "category" => Keyword.fetch!(options, :category),
      "message" => Keyword.fetch!(options, :message)
    }

    with {:ok, session} <- cited_session(options) do
      case Options.report(report) do
        {:ok, report} -> {:ok, Map.put(report, :session, session)}
        {:error, %{"field" => "category"}} -> invalid("--category", "malformed")
        {:error, _invalid} -> invalid("--message", "malformed")
      end
    end
  end

  defp operation_arguments("reports", options) do
    with {:ok, selection} <- selection(options), do: {:ok, %{selection: selection}}
  end

  defp operation_arguments("reports submit", options) do
    with {:ok, selection} <- selection(options) do
      {:ok,
       %{
         confirm?: Keyword.get(options, :confirm, false),
         dry_run?: Keyword.get(options, :dry_run, false),
         selection: selection
       }}
    end
  end

  # `--from-cursor` and `--max-events` are subscription options the target
  # validates; `--for` is the observer's own deadline.
  defp operation_arguments("watch", options) do
    with {:ok, subscribe} <- put_from_cursor(%{}, Keyword.get(options, :from_cursor)),
         {:ok, subscribe} <-
           put_positive(
             subscribe,
             "max_events",
             Keyword.get(options, :max_events),
             "--max-events"
           ),
         {:ok, for_ms} <- duration(Keyword.get(options, :for)),
         {:ok, format} <- format(Keyword.get(options, :format)) do
      {:ok,
       %{
         session: session(options),
         options:
           subscribe |> put_view(options) |> put_value("reader", Keyword.get(options, :reader)),
         for_ms: for_ms,
         format: format
       }}
    end
  end

  # The dotted prefix is split into segments; the target validates them.
  defp operation_arguments("discover", options) do
    case Keyword.get(options, :prefix) do
      nil ->
        {:ok, %{}}

      prefix ->
        segments = String.split(prefix, ".")

        if Enum.all?(segments, &(&1 != "")),
          do: {:ok, %{"prefix" => segments}},
          else: invalid("--prefix", "malformed")
    end
  end

  # The trace id and the subject pass through; the target validates them.
  # `--collapse` and `--hide` take comma-separated categories or prefixes
  # and repeat.
  defp operation_arguments("trace", options) do
    with {:ok, bounds} <- correlated_bounds(options) do
      bounds =
        Enum.reduce([collapse: "collapse", hide: "hide"], bounds, fn {flag, key}, bounds ->
          case Keyword.get_values(options, flag) do
            [] -> bounds
            values -> Map.put(bounds, key, Enum.flat_map(values, &String.split(&1, ",")))
          end
        end)

      bounds =
        bounds
        |> then(
          &if(Keyword.get(options, :retain, false), do: Map.put(&1, "retain", true), else: &1)
        )
        |> then(
          &if(Keyword.get(options, :values, false), do: Map.put(&1, "values", true), else: &1)
        )
        |> put_list("values_paths", Keyword.get_values(options, :values_path))

      {:ok,
       %{
         session: session(options),
         trace_id: Keyword.fetch!(options, :trace_id),
         options: bounds,
         human?: Keyword.get(options, :human, false)
       }}
    end
  end

  # `--bind` is a loopback address literal, never a name, so what is bound
  # is what was checked; `--port 0` picks a free port.
  # `chart` writes one page (`--out`, default under the system temp
  # directory) or, with `--serve`, serves it live on 127.0.0.1 for `--for`
  # (default 30 minutes) on `--port` (default 0, a random port). It reads
  # with its own reader: `--reader`, else a new `chart-` name.
  defp operation_arguments("chart", options) do
    serve? = Keyword.get(options, :serve, false)
    live_only = Enum.filter([:port, :for], &Keyword.has_key?(options, &1))

    with :ok <- chart_flags(serve?, Keyword.has_key?(options, :out), live_only),
         {:ok, since} <- window_since(options),
         {:ok, port} <- port(Keyword.get(options, :port, 0)),
         {:ok, for_ms} <- duration(Keyword.get(options, :for, "30m")) do
      {:ok,
       %{
         session: session(options),
         since: since,
         out: Keyword.get(options, :out),
         serve?: serve?,
         port: port,
         for_ms: for_ms,
         reader: Keyword.get_lazy(options, :reader, &chart_reader/0)
       }}
    end
  end

  defp operation_arguments("otlp-receive", options) do
    with {:ok, bind} <- bind(Keyword.get(options, :bind)),
         {:ok, port} <- port(Keyword.get(options, :port, @default_otlp_port)),
         {:ok, for_ms} <- duration(Keyword.get(options, :for)) do
      {:ok,
       %{
         session: session(options),
         options: %{bind: bind, port: port, for_ms: for_ms}
       }}
    end
  end

  defp operation_arguments("timeline", options) do
    subject =
      %{}
      |> put_value("pid", Keyword.get(options, :pid))
      |> put_value("request_id", Keyword.get(options, :request_id))

    with :ok <- one_subject(subject),
         {:ok, bounds} <- correlated_bounds(options) do
      {:ok,
       %{
         session: session(options),
         options:
           bounds
           |> Map.merge(subject)
           |> put_value(
             "since",
             options |> Keyword.get(:since_mark) |> then(&(&1 && mark_since(&1)))
           ),
         human?: Keyword.get(options, :human, false)
       }}
    end
  end

  # The inspections' values pass through; the target validates them and
  # resolves names and pids (`--name` or `--pid`, never both).
  defp operation_arguments("process", options) do
    {:ok,
     %{}
     |> put_value("name", Keyword.get(options, :name))
     |> put_value("pid", Keyword.get(options, :pid))
     |> put_value("frames", Keyword.get(options, :frames))
     |> put_value("messages", Keyword.get(options, :messages))}
  end

  defp operation_arguments("ports", options) do
    {:ok,
     %{}
     |> put_value("type", Keyword.get(options, :type))
     |> put_value("owner", Keyword.get(options, :owner))
     |> put_value("top", Keyword.get(options, :top))}
  end

  # `--human` prints the result's text, the biggest holder first.
  defp operation_arguments("bin_leak", options) do
    human? = Keyword.get(options, :human, false)
    leak = put_value(%{}, "top", Keyword.get(options, :top))
    {:ok, %{options: if(human?, do: Map.put(leak, "human", true), else: leak), human?: human?}}
  end

  defp operation_arguments("alloc", options),
    do: {:ok, put_value(%{}, "top", Keyword.get(options, :top))}

  defp operation_arguments("welcome", options),
    do: {:ok, %{full?: Keyword.get(options, :full, false)}}

  defp operation_arguments("capabilities", _options), do: {:ok, %{}}

  # `baseline` marks the window's anomalies normal, or shows or clears the
  # baseline.
  defp operation_arguments("baseline", options) do
    human? = Keyword.get(options, :human, false)

    with {:ok, since} <- window_since(options) do
      baseline =
        %{}
        |> put_value("since", since)
        |> put_value("clear", Keyword.get(options, :clear))
        |> put_value("show", Keyword.get(options, :show))
        |> put_view(options)
        |> put_value("reader", Keyword.get(options, :reader))

      {:ok,
       %{
         session: session(options),
         options: if(human?, do: Map.put(baseline, "human", true), else: baseline),
         human?: human?
       }}
    end
  end

  defp operation_arguments("mutations", options),
    do: operation_arguments("changes", options, "id", Keyword.get(options, :id))

  defp operation_arguments("changes", options),
    do: operation_arguments("changes", options, "key", Keyword.get(options, :key))

  defp operation_arguments("stop", options) do
    stop =
      %{}
      |> put_value("reader", Keyword.get(options, :reader))
      |> put_value("force", Keyword.get(options, :force))

    {:ok, %{session: session(options), options: stop}}
  end

  defp operation_arguments(_operation, options),
    do: {:ok, %{session: session(options)}}

  # A read of the kept records (`changes`, `mutations`): one selector, the
  # reader and its view, and human text.
  defp operation_arguments(_read, options, selector, value) do
    changes =
      %{}
      |> put_value(selector, value)
      |> put_view(options)
      |> put_value("reader", Keyword.get(options, :reader))

    human? = Keyword.get(options, :human, false)

    {:ok,
     %{
       session: session(options),
       options: if(human?, do: Map.put(changes, "human", true), else: changes),
       human?: human?
     }}
  end

  # A reset names a recording flag that this amendment does not also give.
  defp put_resets(amend, flags) do
    Enum.reduce_while(flags, {:ok, amend}, fn flag, {:ok, amend} ->
      case Map.fetch(@resettable, flag) do
        {:ok, key} when not is_map_key(amend, key) -> {:cont, {:ok, Map.put(amend, key, nil)}}
        _unknown_or_given -> {:halt, invalid("--reset", "malformed")}
      end
    end)
  end

  defp format(nil), do: {:ok, hd(Format.formats())}

  defp format(format),
    do: if(format in Format.formats(), do: {:ok, format}, else: invalid("--format", "malformed"))

  defp since(text) do
    case Integer.parse(text) do
      {cursor, ""} -> cursor
      _other -> text
    end
  end

  defp recording(options) do
    start =
      %{}
      |> put_list("components", Keyword.get_values(options, :component))
      |> put_list("telemetry_measurements", Keyword.get_values(options, :telemetry_measurement))
      |> put_list("watch_writes", Keyword.get_values(options, :watch_write))
      |> put_present("disclosure", Keyword.get(options, :disclosure))

    with {:ok, start} <- put_events(start, Keyword.get_values(options, :telemetry_event)),
         {:ok, start} <-
           put_positive(start, "lease_ms", Keyword.get(options, :lease_ms), "--lease-ms"),
         {:ok, start} <-
           put_positive(start, "max_events", Keyword.get(options, :max_events), "--max-events"),
         {:ok, start} <-
           put_count(
             start,
             "retain_traces",
             Keyword.get(options, :retain_traces),
             "--retain-traces"
           ) do
      with {:ok, start} <- put_filters(start, options),
           do: {:ok, start |> put_poller(options) |> put_calls(options)}
    end
  end

  # A session id cited in a report context or selecting reports. Session
  # ids are `live-` and a base-36 counter; any ASCII identifier of that
  # alphabet is accepted, so a session of another node can be cited, and
  # anything else (invalid UTF-8, control characters, spaces) is refused
  # before it reaches the queue or the output. The value is never echoed.
  # A read without --session reads the node's one active session, found once
  # connected, rather than failing with "--session is required". stop, amend and otlp-receive still require it.
  defp session(options), do: Keyword.get(options, :session, :active)

  defp cited_session(options) do
    case Keyword.get(options, :session) do
      nil ->
        {:ok, nil}

      session ->
        if String.match?(session, @session_id),
          do: {:ok, session},
          else: invalid("--session", "malformed")
    end
  end

  defp selection(options) do
    fingerprints = options |> Keyword.get_values(:fingerprint) |> Enum.uniq()

    if Enum.all?(fingerprints, &String.match?(&1, @fingerprint)) do
      with {:ok, session} <- cited_session(options),
           do: {:ok, %{fingerprints: fingerprints, session: session}}
    else
      invalid("--fingerprint", "malformed")
    end
  end

  defp correlated_bounds(options) do
    with {:ok, bounds} <- put_positive(%{}, "limit", Keyword.get(options, :limit), "--limit"),
         {:ok, bounds} <-
           put_positive(bounds, "max_bytes", Keyword.get(options, :max_bytes), "--max-bytes") do
      bounds = bounds |> put_view(options) |> put_value("reader", Keyword.get(options, :reader))

      {:ok,
       if(Keyword.get(options, :human, false), do: Map.put(bounds, "human", true), else: bounds)}
    end
  end

  defp one_subject(subject) when map_size(subject) == 1, do: :ok

  defp one_subject(subject) when map_size(subject) == 0,
    do: invalid("--pid", "missing", %{"missing" => ["--pid", "--request-id"]})

  defp one_subject(_subject),
    do: invalid("--request-id", "not_accepted", %{"unexpected" => ["--request-id"]})

  # Record-time filters. A rule is `domain:a.b`, `application:name`, or
  # `module:Name`; an origin is also `oban`, and `--exclude-origin none`
  # alone records every origin. Values pass through; the target validates.
  defp put_filters(start, options) do
    with {:ok, include} <- rules(options, :logger_include, false),
         {:ok, exclude} <- rules(options, :logger_exclude, false),
         {:ok, bursts} <- rules(options, :logger_summary, false),
         {:ok, origins} <- origins(Keyword.get_values(options, :exclude_origin)),
         {:ok, minimums} <- minimums(Keyword.get_values(options, :telemetry_event_min_duration)),
         {:ok, scopes} <- scopes(Keyword.get_values(options, :telemetry_duration_scope)) do
      {:ok,
       start
       |> put_value("logger_level", Keyword.get(options, :logger_level))
       |> put_list("logger_include", include)
       |> put_list("logger_exclude", exclude)
       |> put_list("logger_summaries", bursts)
       |> put_value(
         "logger_summary_interval_ms",
         Keyword.get(options, :logger_summary_interval_ms)
       )
       |> put_value("exclude_origins", origins)
       |> put_value("telemetry_min_duration_ms", Keyword.get(options, :telemetry_min_duration_ms))
       |> put_value("telemetry_event_min_duration_ms", minimums)
       |> put_list("telemetry_summaries", Keyword.get_values(options, :telemetry_summary))
       |> put_value(
         "telemetry_summary_interval_ms",
         Keyword.get(options, :telemetry_summary_interval_ms)
       )
       |> put_value("otel_min_duration_ms", Keyword.get(options, :otel_min_duration_ms))
       |> put_value("telemetry_duration_scopes", scopes)}
    end
  end

  # Poller options pass through; the target validates them and resolves
  # each watched name.
  defp put_poller(start, options) do
    start
    |> put_value("poller_interval_ms", Keyword.get(options, :poller_interval_ms))
    |> put_value("top_processes", Keyword.get(options, :top_processes))
    |> put_value("top_ets_tables", Keyword.get(options, :top_ets_tables))
    |> put_value("top_ports", Keyword.get(options, :top_ports))
    |> put_list("watch_processes", Keyword.get_values(options, :watch_process))
  end

  # Call-trace options pass through; the target validates them and resolves
  # each function.
  defp put_calls(start, options) do
    start
    |> put_list("calls", Keyword.get_values(options, :calls))
    |> put_value("calls_results", Keyword.get(options, :calls_results))
    |> put_value("calls_max", Keyword.get(options, :calls_max))
    |> put_value("calls_rate_max", Keyword.get(options, :calls_rate_max))
    |> put_value("calls_rate_ms", Keyword.get(options, :calls_rate_ms))
    |> put_value("calls_max_bytes", Keyword.get(options, :calls_max_bytes))
  end

  defp rules(options, key, origin?) do
    options
    |> Keyword.get_values(key)
    |> Enum.reduce_while({:ok, []}, fn text, {:ok, rules} ->
      case rule(text, origin?) do
        {:ok, rule} -> {:cont, {:ok, rules ++ [rule]}}
        :error -> {:halt, invalid(option_name(key), "malformed")}
      end
    end)
  end

  defp rule("oban", true), do: {:ok, "oban"}
  defp rule("domain:" <> domain, false), do: {:ok, %{"domain" => String.split(domain, ".")}}
  defp rule("application:" <> name, _origin?) when name != "", do: {:ok, %{"application" => name}}
  defp rule("module:" <> name, _origin?) when name != "", do: {:ok, %{"module" => name}}
  defp rule(_text, _origin?), do: :error

  defp origins([]), do: {:ok, nil}
  defp origins(["none"]), do: {:ok, []}

  defp origins(values) do
    if "none" in values,
      do: invalid("--exclude-origin", "malformed"),
      else: rules(Enum.map(values, &{:exclude_origin, &1}), :exclude_origin, true)
  end

  defp minimums([]), do: {:ok, nil}

  defp minimums(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn text, {:ok, minimums} ->
      with [kind, milliseconds] <- String.split(text, "=", parts: 2),
           {value, ""} <- Integer.parse(milliseconds),
           false <- Map.has_key?(minimums, kind) do
        {:cont, {:ok, Map.put(minimums, kind, value)}}
      else
        _invalid ->
          {:halt, invalid("--telemetry-event-min-duration", "malformed")}
      end
    end)
  end

  # `KIND=handler` or `KIND=caller`, each kind once; the target checks that
  # every kind is summarised.
  defp scopes([]), do: {:ok, nil}

  defp scopes(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn text, {:ok, scopes} ->
      with [kind, scope] when kind != "" and scope in ["handler", "caller"] <-
             String.split(text, "=", parts: 2),
           false <- Map.has_key?(scopes, kind) do
        {:cont, {:ok, Map.put(scopes, kind, scope)}}
      else
        _invalid -> {:halt, invalid("--telemetry-duration-scope", "malformed")}
      end
    end)
  end

  # A read-time view, for every read. Without view flags, a named reader
  # reads through its own view; `--view-clear` (alone) clears it.
  defp put_view(map, options) do
    view =
      %{}
      |> put_list("sources", Keyword.get_values(options, :view_source))
      |> put_list("kinds", Keyword.get_values(options, :view_kind))
      |> put_list("exclude_kinds", Keyword.get_values(options, :view_exclude_kind))
      |> put_value("min_severity", Keyword.get(options, :view_min_severity))
      |> put_list("exclude_signatures", Keyword.get_values(options, :view_exclude_signature))
      |> put_list("services", Keyword.get_values(options, :view_service))
      |> put_list("routes", Keyword.get_values(options, :view_route))
      |> put_list("traces", Keyword.get_values(options, :view_trace))

    cond do
      view != %{} -> Map.put(map, "view", view)
      Keyword.get(options, :view_clear, false) -> Map.put(map, "view", %{})
      true -> map
    end
  end

  defp put_value(map, _key, nil), do: map
  defp put_value(map, key, value), do: Map.put(map, key, value)

  defp put_list(map, _key, []), do: map
  defp put_list(map, key, values), do: Map.put(map, key, values)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_events(start, []), do: {:ok, start}

  defp put_events(start, events) do
    names = Enum.map(events, &String.split(&1, "."))

    if Enum.all?(names, fn segments -> Enum.all?(segments, &(&1 != "")) end),
      do: {:ok, Map.put(start, "telemetry_events", names)},
      else: invalid("--telemetry-event", "malformed")
  end

  defp put_positive(map, _key, nil, _option), do: {:ok, map}
  defp put_positive(map, key, value, _option) when value > 0, do: {:ok, Map.put(map, key, value)}
  defp put_positive(_map, _key, _value, option), do: invalid(option, "out_of_range")

  defp put_count(map, _key, nil, _option), do: {:ok, map}
  defp put_count(map, key, value, _option) when value >= 0, do: {:ok, Map.put(map, key, value)}
  defp put_count(_map, _key, _value, option), do: invalid(option, "out_of_range")

  # A cursor is an integer of at least 0, or `latest` for the newest receipt.
  # `--since-mark` takes an optional label: bare (last, or before another
  # flag) it reads since the newest mark, so it is given an empty value.
  # `--trace` is `--trace-id`, the name agents try first.
  defp optional_values(["--trace" | rest]), do: ["--trace-id" | optional_values(rest)]

  defp optional_values(["--trace=" <> trace_id | rest]),
    do: ["--trace-id=" <> trace_id | optional_values(rest)]

  defp optional_values(["--since-mark"]), do: ["--since-mark", ""]

  defp optional_values(["--since-mark", "--" <> _flag = next | rest]),
    do: ["--since-mark", "" | optional_values([next | rest])]

  defp optional_values(["--since-mark", label | rest]),
    do: ["--since-mark", label | optional_values(rest)]

  defp optional_values([argument | rest]), do: [argument | optional_values(rest)]
  defp optional_values([]), do: []

  defp mark_since(""), do: "mark"
  defp mark_since(label), do: "mark:" <> label

  # --out writes the static page; --port and --for only shape --serve.
  defp chart_flags(true, true, _live_only),
    do: invalid("--out", "not_accepted", %{"unexpected" => ["--out"]})

  defp chart_flags(false, _out?, [first | _rest] = live_only),
    do:
      invalid(option_name(first), "not_accepted", %{
        "unexpected" => Enum.map(live_only, &option_name/1)
      })

  defp chart_flags(_serve?, _out?, _live_only), do: :ok

  defp chart_reader, do: "chart-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

  # A window starts at --since or at a pairing mark (--since-mark), not both.
  defp window_since(options) do
    case {Keyword.get(options, :since), Keyword.get(options, :since_mark)} do
      {nil, nil} -> {:ok, nil}
      {since, nil} -> {:ok, since(since)}
      {nil, label} -> {:ok, mark_since(label)}
      _both -> invalid("--since-mark", "not_accepted", %{"unexpected" => ["--since-mark"]})
    end
  end

  # An events read starts after --cursor or after a pairing mark: exactly one.
  defp read_start(options) do
    case {Keyword.get(options, :cursor), Keyword.get(options, :since_mark)} do
      {nil, nil} -> invalid("--cursor", "missing", %{"missing" => ["--cursor", "--since-mark"]})
      {cursor, nil} -> cursor(cursor, "--cursor")
      {nil, label} -> {:ok, mark_since(label)}
      _both -> invalid("--since-mark", "not_accepted", %{"unexpected" => ["--since-mark"]})
    end
  end

  defp cursor("latest", _option), do: {:ok, "latest"}

  defp cursor(text, option) do
    case Integer.parse(text) do
      {value, ""} when value >= 0 -> {:ok, value}
      {_negative, ""} -> invalid(option, "out_of_range")
      _invalid -> invalid(option, "malformed")
    end
  end

  defp put_from_cursor(map, nil), do: {:ok, map}

  defp put_from_cursor(map, text) do
    with {:ok, cursor} <- cursor(text, "--from-cursor"), do: {:ok, Map.put(map, "cursor", cursor)}
  end

  # `--for` is a positive whole number of ms, s, m, or h, at most 24 hours.
  defp duration(nil), do: {:ok, nil}

  defp duration(text) do
    case Regex.run(~r/\A([1-9][0-9]{0,8})(ms|s|m|h)\z/, text) do
      [_text, amount, unit] ->
        milliseconds = String.to_integer(amount) * Map.fetch!(@duration_units, unit)

        if milliseconds <= @max_duration_ms,
          do: {:ok, milliseconds},
          else: invalid("--for", "out_of_range")

      nil ->
        invalid("--for", "malformed")
    end
  end

  defp bind(nil), do: {:ok, {127, 0, 0, 1}}

  defp bind(text) do
    case :inet.parse_strict_address(String.to_charlist(text)) do
      {:ok, address} ->
        if Observer.loopback_address?(address),
          do: {:ok, address},
          else:
            {:error, "non_loopback_bind",
             %{"option" => "--bind", "expected" => Help.value("otlp-receive", "--bind")}}

      {:error, _reason} ->
        invalid("--bind", "malformed")
    end
  end

  defp port(port) when port in 0..65_535, do: {:ok, port}
  defp port(_port), do: invalid("--port", "out_of_range")

  defp execute(%{target: nil} = command, writer) do
    command |> local(nil, nil) |> finish(command, writer)
  end

  defp execute(command, writer) do
    with :ok <- Observer.ensure_loopback(command.target),
         {:ok, cookie} <- Observer.read_cookie(command.cookie_file) do
      command.target
      |> Observer.with_target(cookie, command.timeout_ms, &observe(&1, command, writer))
      |> case do
        {:observed, outcome, observed} -> finish(outcome, observed, writer)
        failure -> finish(failure, command, writer)
      end
    else
      # A refused host is not echoed, neither as the document's target nor
      # in the next report's context.
      {:error, "non_loopback_host" = code, details} ->
        emit_failure(writer, code, details, %{command | target: nil})

      {:error, code, details} ->
        emit_failure(writer, code, details, command)
    end
  end

  defp observe(node, command, writer) do
    with {:ok, installation} <- Installation.ensure(node, command.load, command.timeout_ms),
         {:ok, command} <- active_session(node, command) do
      command = %{command | incarnation: incarnation(node, command.timeout_ms)}
      command = %{command | welcome: connection_welcome(node, command)}
      installation = Installation.for_operation(installation, command.operation)
      {:observed, perform(node, command, installation, writer), command}
    end
  end

  defp active_session(node, %{arguments: %{session: :active} = arguments} = command) do
    case Observer.call(node, Insider.Live, :capabilities, [], command.timeout_ms) do
      {:ok, %{"active_session_id" => id}} when is_binary(id) ->
        {:ok, %{command | arguments: %{arguments | session: id}}}

      # Only an owner that answered can say no session is active; otherwise
      # the session is unknown, not absent.
      {:ok, %{"owner_responsive" => true}} ->
        {:error, "invalid_options",
         %{
           "option" => "--session",
           "problem" => "missing",
           "missing" => ["--session"],
           "active_session_id" => nil,
           "expected" =>
             "SESSION_ID: no session is active on the node, so there is none to default to; " <>
               "start one with start, or name a stopped one with --session",
           "help" => "#{command.environment.invocation} help #{command.operation}"
         }}

      {:ok, %{} = capabilities} ->
        {:target_error,
         Insider.Live.Error.new("unavailable", %{
           "reason" => "active_session_unknown",
           "owner_running" => capabilities["owner_running"],
           "owner_responsive" => capabilities["owner_responsive"],
           "expected" =>
             "the live owner did not answer, so the active session is unknown; retry, or pass --session"
         })}

      {:ok, _other} ->
        {:error, "unexpected_response", %{"function" => "capabilities"}}

      failure ->
        failure
    end
  end

  defp active_session(_node, command), do: {:ok, command}

  # The target node's distribution creation, which changes when the node
  # restarts, so a restarted node with the same name is a new target.
  defp incarnation(node, timeout_ms) do
    case Observer.call(node, :erlang, :system_info, [:creation], timeout_ms) do
      {:ok, creation} when is_integer(creation) and creation >= 0 -> creation
      _unknown -> nil
    end
  end

  # The first command run against a target node that is not a receipt (nor
  # `welcome` itself, which needs none) carries the target's welcome quick
  # start under `"welcome"`, inside the one JSON document the command prints.
  # Once it was delivered, only `capabilities`, the discovery command, carries
  # a pointer with the hash that was delivered; other commands carry nothing.
  # If the document cannot be read, or the delivery cannot be recorded, the
  # pointer still says how to read it.
  defp connection_welcome(_node, %{operation: operation})
       when operation == "welcome" or operation in @receipts,
       do: nil

  defp connection_welcome(node, %{incarnation: creation} = command) when is_integer(creation) do
    directory = command.environment.reports_directory

    with nil <- Reports.welcomed(directory, command.target.text, creation),
         {:ok, %{"schema" => @quick_start_schema, "hash" => hash} = welcome}
         when is_binary(hash) <-
           Observer.call(node, Insider.Live, :welcome, [], command.timeout_ms) do
      {:document, welcome}
    else
      delivered when is_binary(delivered) -> delivered_welcome(command, delivered)
      _unreadable -> {:pointer, welcome_pointer(nil)}
    end
  end

  defp connection_welcome(_node, _command), do: {:pointer, welcome_pointer(nil)}

  defp delivered_welcome(%{operation: "capabilities"}, delivered),
    do: {:pointer, welcome_pointer(delivered)}

  defp delivered_welcome(_command, _delivered), do: nil

  defp welcome_pointer(delivered) do
    hash = if is_binary(delivered), do: delivered

    Welcome.pointer()
    |> Map.put("hash", hash)
    |> Map.put("delivered", is_binary(hash))
  end

  defp put_welcome(document, %{welcome: {_kind, welcome}}),
    do: Map.put(document, "welcome", welcome)

  defp put_welcome(document, _command), do: document

  # Delivery is recorded only once a document carrying the quick start, or
  # the `welcome` command's own output, has been written, so a failed write
  # leaves the next command to deliver it.
  defp mark_welcomed(document, %{incarnation: creation} = command) when is_integer(creation) do
    case delivered_hash(document, command) do
      nil ->
        :ok

      hash ->
        Reports.mark_welcomed(
          command.environment.reports_directory,
          command.target.text,
          creation,
          hash
        )
    end
  end

  defp mark_welcomed(_document, _command), do: :ok

  defp delivered_hash(
         %{"welcome" => %{"schema" => @quick_start_schema, "hash" => hash}},
         _command
       )
       when is_binary(hash),
       do: hash

  defp delivered_hash(
         %{"status" => "ok", "result" => %{"schema" => schema, "hash" => hash}},
         %{operation: "welcome"}
       )
       when schema in @welcome_schemas and is_binary(hash),
       do: hash

  defp delivered_hash(_document, _command), do: nil

  # The first line (`subscribed`) carries the envelope: schema, status,
  # operation, target, installation and, on a first contact, the welcome.
  # Every later line of the stream (`batch`, then `stopped`) carries only its
  # `kind` and its own fields. `--format` shapes each line as for `events`.
  # `otlp-receive` streams the same way, starting
  # with `listening`, then one `export` or `refused` line per request.
  defp perform(node, %{operation: "watch"} = command, installation, writer) do
    %{session: session, options: options, for_ms: for_ms} = command.arguments
    emit_line = stream_emitter(command, installation, writer)

    node
    |> Watch.run(session, command.timeout_ms, emit_line, options, for_ms: for_ms)
    |> stream_done()
  end

  defp perform(
         node,
         %{operation: "chart", arguments: %{serve?: true} = args} = command,
         installation,
         writer
       ) do
    emit_line = stream_emitter(command, installation, writer)

    node
    |> Chart.Run.serve(args, command.timeout_ms, emit_line)
    |> stream_done()
  end

  defp perform(node, %{operation: "chart", arguments: args} = command, installation, _writer) do
    path = args.out || Chart.Run.default_path(args.session)

    case Chart.Run.write(node, args, path, command.timeout_ms) do
      {:ok, written} -> {:done, document(command, installation, %{"result" => written})}
      other -> other
    end
  end

  defp perform(node, %{operation: "otlp-receive"} = command, installation, writer) do
    %{session: session, options: options} = command.arguments
    emit_line = stream_emitter(command, installation, writer)

    node
    |> Otlp.run(session, command.timeout_ms, emit_line, options)
    |> stream_done()
  end

  defp perform(node, %{operation: "reports" <> _} = command, installation, _writer) do
    with {:ok, queued} <- live_result(node, :reports, [], command.timeout_ms),
         {:ok, imported} <-
           Reports.import(
             command.environment.reports_directory,
             command.target.text,
             queued["reports"]
           ) do
      local(command, installation, %{"imported" => imported, "submission" => queued["submission"]})
    end
  end

  defp perform(node, command, installation, _writer) do
    case live_call(node, command) do
      {:ok, result} -> {:done, document(command, installation, %{"result" => result})}
      {:target_error, error} -> {:target_error, error}
      {:error, _code, _details} = failure -> failure
    end
  end

  defp stream_emitter(command, installation, writer) do
    fn kind, fields ->
      line = stream_line(command, installation, kind, fields)

      case render(writer, command, line) do
        :ok ->
          :ok

        {:error, :unportable} ->
          emit(writer, failure_document("unexpected_response", %{"kind" => kind}, command))

        written ->
          written
      end
    end
  end

  defp stream_done({:stopped, fields}), do: {:done, Map.put(fields, "kind", "stopped")}
  defp stream_done(other), do: other

  defp local(%{operation: "report"} = command, nil, nil) do
    case Reports.file(
           command.environment.reports_directory,
           command.arguments,
           DateTime.utc_now()
         ) do
      {:ok, receipt} -> {:done, document(command, nil, %{"result" => receipt})}
      failure -> failure
    end
  end

  defp local(%{operation: "reports"} = command, installation, imported) do
    case Reports.list(command.environment.reports_directory, command.arguments.selection) do
      {:ok, listed} ->
        {:done, document(command, installation, %{"result" => with_import(listed, imported)})}

      failure ->
        failure
    end
  end

  defp local(%{operation: "reports submit"} = command, installation, imported) do
    environment = command.environment
    available = opt_ins(command, environment.submission, imported)
    dry_run? = command.arguments.dry_run?
    opt_in = if dry_run?, do: nil, else: List.first(available)

    authorization = %{
      "effective" => opt_in_name(opt_in) || "dry_run",
      "target" => opt_in_target(opt_in),
      "opt_ins" => Enum.map(available, &opt_in_name/1),
      "overridden_by" => if(dry_run? and available != [], do: "--dry-run")
    }

    announce = fn authorization ->
      environment.notice.([
        Canonical.encode(%{
          "schema" => "insider.live-authorization/v1",
          "operation" => "reports submit",
          "authorization" => authorization
        }),
        "\n"
      ])
    end

    case Reports.submit(environment.reports_directory, opt_in, environment.gh,
           selection: command.arguments.selection,
           authorization: authorization,
           announce: announce
         ) do
      {:ok, submitted} ->
        submitted = with_import(submitted, imported)

        if Enum.any?(Map.get(submitted, "results", []), &(&1["status"] == "failed")),
          do: {:error, "report_submit_failed", submitted},
          else: {:done, document(command, installation, %{"result" => submitted})}

      failure ->
        failure
    end
  end

  # Every opt-in present, strongest first: the operator's `--confirm`, this
  # observer's own host setting, or the target's. A target's own setting
  # covers only reports that came solely from it. `--dry-run` overrides them
  # all.
  defp opt_ins(command, submission, imported) do
    [
      command.arguments.confirm? && "confirm",
      submission == "github" && "observer_config",
      match?(%{"submission" => "github"}, imported) && {"target_config", command.target.text}
    ]
    |> Enum.filter(& &1)
  end

  defp opt_in_name({kind, _target}), do: kind
  defp opt_in_name(kind), do: kind

  defp opt_in_target({_kind, target}), do: target
  defp opt_in_target(_kind), do: nil

  defp with_import(result, nil), do: result

  defp with_import(result, target) do
    Map.merge(result, %{
      "imported_from_target" => target["imported"],
      "target_submission" => target["submission"]
    })
  end

  # The `Insider.Live` function each plain operation calls. The names are
  # literal atoms: the observer VM need not have `Insider.Live` loaded, so an
  # operation string cannot be turned into an existing atom.
  defp live_call(node, %{operation: "capabilities", timeout_ms: timeout_ms}),
    do: map_result(Observer.call(node, Insider.Live, :capabilities, [], timeout_ms))

  defp live_call(node, %{operation: "welcome", arguments: %{full?: full?}} = command) do
    arguments = if full?, do: [%{"full" => true}], else: []
    map_result(Observer.call(node, Insider.Live, :welcome, arguments, command.timeout_ms))
  end

  defp live_call(node, %{operation: "discover"} = command),
    do: live_result(node, :discover, [command.arguments], command.timeout_ms)

  defp live_call(node, %{operation: "process"} = command),
    do: live_result(node, :process, [command.arguments], command.timeout_ms)

  defp live_call(node, %{operation: "bin_leak"} = command),
    do: live_result(node, :bin_leak, [command.arguments.options], command.timeout_ms)

  defp live_call(node, %{operation: "ports"} = command),
    do: live_result(node, :ports, [command.arguments], command.timeout_ms)

  defp live_call(node, %{operation: "alloc"} = command),
    do: live_result(node, :alloc, [command.arguments], command.timeout_ms)

  defp live_call(node, %{operation: "start"} = command),
    do: live_result(node, :start, [command.arguments], command.timeout_ms)

  defp live_call(node, %{operation: "events", arguments: arguments} = command),
    do:
      live_result(
        node,
        :events_since,
        [arguments.session, arguments.cursor, arguments.options],
        command.timeout_ms
      )

  defp live_call(node, %{operation: operation, arguments: arguments} = command)
       when operation in ["digest", "trends"] do
    function = if operation == "digest", do: :digest, else: :trends
    live_result(node, function, [arguments.session, arguments.options], command.timeout_ms)
  end

  # A stop without `--reader` or `--force` calls `stop/1`, as before.
  defp live_call(
         node,
         %{operation: "stop", arguments: %{session: session, options: options}} = command
       ) do
    arguments = if options == %{}, do: [session], else: [session, options]
    live_result(node, :stop, arguments, command.timeout_ms)
  end

  defp live_call(node, %{operation: "amend", arguments: arguments} = command),
    do: live_result(node, :amend, [arguments.session, arguments.options], command.timeout_ms)

  defp live_call(node, %{operation: "trace", arguments: arguments} = command),
    do:
      live_result(
        node,
        :trace,
        [arguments.session, arguments.trace_id, arguments.options],
        command.timeout_ms
      )

  defp live_call(node, %{operation: "timeline", arguments: arguments} = command),
    do: live_result(node, :timeline, [arguments.session, arguments.options], command.timeout_ms)

  defp live_call(node, %{operation: operation, arguments: arguments} = command)
       when operation in ["mark", "marks"],
       do:
         live_result(
           node,
           if(operation == "mark", do: :mark, else: :marks),
           [arguments.session, arguments.options],
           command.timeout_ms
         )

  defp live_call(node, %{operation: "changes", arguments: arguments} = command),
    do: live_result(node, :changes, [arguments.session, arguments.options], command.timeout_ms)

  defp live_call(node, %{operation: "baseline", arguments: arguments} = command),
    do: live_result(node, :baseline, [arguments.session, arguments.options], command.timeout_ms)

  defp live_call(node, %{operation: "mutations", arguments: arguments} = command),
    do: live_result(node, :mutations, [arguments.session, arguments.options], command.timeout_ms)

  defp live_call(node, %{operation: operation, arguments: %{session: session}} = command) do
    # The observer's `handoff` calls `Insider.Live.handoff_record/1`.
    function =
      Map.fetch!(
        %{"status" => :status, "renew" => :renew, "handoff" => :handoff_record},
        operation
      )

    live_result(node, function, [session], command.timeout_ms)
  end

  defp map_result({:ok, result}) when is_map(result), do: {:ok, result}
  defp map_result({:ok, _other}), do: {:error, "unexpected_response", %{}}
  defp map_result(failure), do: failure

  @doc false
  @spec live_result(node(), atom(), list(), pos_integer()) ::
          {:ok, map()} | {:target_error, map()} | Observer.failure()
  def live_result(node, function, arguments, timeout_ms) do
    case Observer.call(node, Insider.Live, function, arguments, timeout_ms) do
      {:ok, {:ok, result}} when is_map(result) -> {:ok, result}
      {:ok, {:error, error}} when is_map(error) -> {:target_error, error}
      {:ok, _other} -> {:error, "unexpected_response", %{"function" => Atom.to_string(function)}}
      failure -> failure
    end
  end

  defp finish({:done, document}, command, writer) do
    remember(command, nil, document["result"])

    case Format.render(command.operation, command.arguments, document) do
      {:json, document} -> emit_document(writer, document, 0, command)
      {:text, text} -> emit_text(writer, text)
    end
  end

  defp finish({:exit, status}, command, _writer) do
    remember(command, nil, nil)
    status
  end

  defp finish({:target_error, error}, command, writer) do
    remember(command, error["code"], nil)

    document =
      put_welcome(
        %{
          "schema" => @error_schema,
          "status" => "error",
          "operation" => command.operation,
          "target" => command.target.text,
          "error" => error |> Map.put("source", "target") |> with_flags(command)
        },
        command
      )

    emit_document(writer, document, @exit_statuses["error"], command)
  end

  defp finish({:error, code, details}, command, writer),
    do: emit_failure(writer, code, details, command)

  # A watch line in the command's `--format`. Only JSON carries the welcome,
  # so only JSON output records its delivery.
  defp render(writer, command, document) do
    case Format.render(command.operation, command.arguments, document) do
      {:json, document} ->
        with :ok <- emit(writer, document) do
          mark_welcomed(document, command)
          :ok
        end

      {:text, text} ->
        write(writer, text)
    end
  end

  defp emit_text(writer, text) do
    case write(writer, text) do
      :ok -> @exit_statuses["ok"]
      {:error, _reason} -> @exit_statuses["catastrophic"]
    end
  end

  # A target `invalid_options` error names the `Insider.Live` option in
  # `"field"`; the observer adds the flag that sets it and that flag's value
  # syntax (every view flag, with each one's syntax, for a malformed view).
  # When several flags set the field, those the command gave are named
  # (`--since`, not `--since-mark`, for a malformed window).
  defp with_flags(
         %{"code" => "invalid_options", "field" => field} = error,
         %{operation: operation} = command
       )
       when is_binary(field) do
    flags =
      for key <- accepted(operation),
          flag = option_name(key),
          %{"sets" => sets} when is_binary(sets) <- [Welcome.observer_option(operation, flag)],
          field in String.split(sets, "."),
          do: flag

    flags =
      case Enum.filter(flags, &(&1 in Map.get(command, :given, []))) do
        [] -> flags
        given -> given
      end

    case flags do
      [] ->
        error

      [flag] ->
        Map.merge(error, %{"option" => flag, "expected" => Help.value(operation, flag)})

      flags ->
        Map.merge(error, %{
          "options" => flags,
          "expected" => Map.new(flags, &{&1, Help.value(operation, &1)})
        })
    end
  end

  defp with_flags(error, _command), do: error

  # The last target command and its outcome become the context of the next
  # `report`. `capabilities` and `welcome` also carry the welcome hash and the
  # target's environment. A failure of a command that reaches no target (or
  # of `reports`, which is not a target call) is the last local failure.
  defp remember(%{target: nil} = command, code, _result), do: remember_local(command, code)

  defp remember(%{operation: "reports" <> _} = command, code, _result),
    do: remember_local(command, code)

  defp remember(command, code, result) do
    {hash, environment} =
      case {command.operation, result} do
        {"capabilities", %{"welcome" => %{"hash" => hash}, "environment" => environment}} ->
          {hash, environment}

        {"welcome", %{"hash" => hash, "runtime" => %{"environment" => environment}}} ->
          {hash, environment}

        _other ->
          {nil, nil}
      end

    Reports.remember(command.environment.reports_directory, %{
      "node" => command.target.text,
      "session" => remembered_session(command, result),
      "operation" => command.operation,
      "error_code" => code,
      "welcome_hash" => if(is_binary(hash), do: hash),
      "environment" => if(is_binary(environment), do: environment)
    })
  end

  # The session a command named, or the one `start` created.
  defp remembered_session(%{arguments: %{session: session}}, _result) when is_binary(session),
    do: session

  defp remembered_session(%{operation: "start"}, %{"session_id" => session})
       when is_binary(session),
       do: session

  defp remembered_session(_command, _result), do: nil

  defp remember_local(_command, nil), do: :ok

  defp remember_local(command, code),
    do: Reports.remember_local(command.environment.reports_directory, command.operation, code)

  defp stream_line(command, installation, kind, fields)
       when kind in ["subscribed", "listening", "serving"],
       do: document(command, installation, Map.put(fields, "kind", kind))

  defp stream_line(_command, _installation, kind, fields), do: Map.put(fields, "kind", kind)

  defp document(command, installation, fields) do
    %{"schema" => @schema, "status" => "ok", "operation" => command.operation}
    |> put_target(command, installation)
    |> Map.merge(fields)
    |> put_welcome(command)
  end

  defp put_target(document, %{target: nil}, _installation), do: document

  defp put_target(document, command, installation),
    do: Map.merge(document, %{"target" => command.target.text, "installation" => installation})

  defp emit_help(writer, text) do
    case write(writer, text) do
      :ok -> @exit_statuses["ok"]
      {:error, _reason} -> @exit_statuses["catastrophic"]
    end
  end

  defp emit_failure(writer, code, details, command \\ nil) do
    if command, do: remember(command, code, nil)
    {status, _message} = Map.fetch!(@codes, code)
    emit(writer, failure_document(code, details, command), Map.fetch!(@exit_statuses, status))
  end

  defp failure_document(code, details, command) do
    {status, message} = Map.fetch!(@codes, code)

    put_command(
      %{
        "schema" => @error_schema,
        "status" => status,
        "error" => %{
          "source" => "observer",
          "code" => code,
          "message" => message,
          "details" => details
        }
      },
      command
    )
  end

  defp put_command(document, nil), do: document

  defp put_command(document, %{target: nil} = command),
    do: Map.put(document, "operation", command.operation)

  defp put_command(document, command),
    do: Map.merge(document, %{"operation" => command.operation, "target" => command.target.text})

  # A target value that cannot be projected to portable JSON is reported as
  # `unexpected_response` instead of being written partially.
  defp emit_document(writer, document, status, command) do
    case emit(writer, document) do
      :ok ->
        mark_welcomed(document, command)
        status

      {:error, :unportable} ->
        emit_failure(writer, "unexpected_response", %{}, command)

      {:error, :write_failed} ->
        @exit_statuses["catastrophic"]
    end
  end

  defp emit(writer, document, status) do
    case emit(writer, document) do
      :ok -> status
      {:error, _reason} -> @exit_statuses["catastrophic"]
    end
  end

  @doc false
  @spec emit((iodata() -> term()), map()) :: :ok | {:error, :unportable | :write_failed}
  def emit(writer, document) do
    case Wire.encode(document) do
      {:ok, bytes} -> write(writer, [bytes, "\n"])
      :error -> {:error, :unportable}
    end
  end

  defp write(writer, bytes) do
    case writer.(bytes) do
      :ok -> :ok
      _failed -> {:error, :write_failed}
    end
  rescue
    _error -> {:error, :write_failed}
  end
end

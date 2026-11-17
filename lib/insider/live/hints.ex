defmodule Insider.Live.Hints do
  @moduledoc false

  # The next command an agent should run, worked out from the evidence a
  # read or a digest already disclosed and the session's own configuration.
  # Each hint is a plain map:
  #
  # - `"kind"`: `trace_calls`, `trace_calls_unavailable`, `reduce_logger`,
  #   `reduce_telemetry`, `reduce_poller`, `raise_capacity`, or
  #   `shared_readers` (a flood while several readers share the Recorder);
  # - `"reason"`: why, with the counts it rests on;
  # - `"evidence"`: those counts;
  # - `"command"`: the exact observer command (`"${N[@]}"` is the target flags, as
  #   in the welcome), or `nil` when there is none to run;
  # - `"options"`: the same change as the `Insider.Live.amend/2` options map,
  #   so a Tidewave agent can apply it, or `nil`;
  # - `"manual"`: for `trace_calls_unavailable`, the recon_trace call to run
  #   by hand instead.
  #
  # A call-trace hint names a function taken from the evidence: the first
  # application frame of a crash's or exception's stack (`{Mod, :fun, 3,
  # ...}` or `Mod.fun/3`), else, for a supervised child that keeps crashing,
  # the GenServer callbacks its module exports. A function must resolve as
  # `--calls` would (`Insider.Live.CallsOptions.function/1`), so a hint never
  # names one the session would refuse. It is offered only when the node can
  # trace calls (OTP 28 and later); otherwise the hint says so and gives the
  # recon_trace call.
  #
  # An eviction hint names the share groups whose entries the Recorder
  # evicted and are over their share (the flood), with the counts from
  # `status` (since the session started), and the amendment that stops it:
  # a Logger summary rule for the module (else the domain) that logged most
  # in the window, a Telemetry summary for the kind recorded most, a slower
  # Poller, and, when the session's Recorder is below its bound, a larger
  # one.

  alias Insider.Collector.Calls.Tracing
  alias Insider.Live.CallsOptions
  alias Insider.Live.Filters

  @command "mix insider.live amend \"${N[@]}\""
  @error_severities ["error", "critical"]
  @runtime_apps [
    :compiler,
    :crypto,
    :eex,
    :elixir,
    :ex_unit,
    :iex,
    :inets,
    :insider,
    :kernel,
    :logger,
    :mix,
    :public_key,
    :runtime_tools,
    :sasl,
    :ssl,
    :stdlib,
    :telemetry
  ]
  @callbacks [{"handle_call", 3}, {"handle_cast", 2}, {"handle_info", 2}]
  @tuple_frame ~r/\{((?:[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)|:"Elixir\.[A-Z][A-Za-z0-9_.]*"|:"?[a-z][A-Za-z0-9_@]*"?), :"?([a-z_][A-Za-z0-9_]*[?!]?)"?, (\d{1,3}),/
  @elixir_frame ~r/(?<![\w.])([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\.([a-z_][A-Za-z0-9_]*[?!]?)\/(\d{1,3})\b/
  @texts_max 32
  @text_bytes 16_384
  @functions_max 3
  @poller_interval_max 60_000
  # The Logger kinds a summary rule folds: messages, never reports.
  @summarisable ["logger_message", "logger_format"]
  @kind ~r/\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*\z/

  @type context :: %{
          session_id: String.t(),
          components: [String.t()],
          calls: [String.t()],
          calls_available: :ok | {:error, String.t()},
          filters: map(),
          max_events: pos_integer() | nil,
          max_events_bound: pos_integer(),
          poller_interval_ms: pos_integer() | nil,
          sources: map(),
          readers: non_neg_integer()
        }

  @doc """
  A hint context from a session's `status/1` record (or the owner's
  configuration of a session, with its `"session_id"`). `calls_available`
  defaults to whether this node can trace calls.
  """
  @spec context(map(), :ok | {:error, String.t()} | nil) :: context()
  def context(status, calls_available \\ nil) do
    filters = status["filters"] || %{}

    %{
      session_id: status["session_id"],
      components: status["components"] || [],
      calls: get_in(status, ["calls", "functions"]) || [],
      calls_available: calls_available || availability(),
      filters: filters,
      max_events: status["max_events"],
      max_events_bound: 4_096,
      poller_interval_ms: get_in(status, ["poller", "interval_ms"]),
      sources: get_in(status, ["recorder", "sources"]) || %{},
      readers: status["reader_count"] || length(status["readers"] || [])
    }
  end

  @doc "Whether this node can trace calls: `:ok`, or why not."
  @spec availability() :: :ok | {:error, String.t()}
  def availability do
    case Tracing.preflight() do
      :ok -> :ok
      {:error, :requires_otp_28} -> {:error, "requires_otp_28"}
    end
  end

  ## Evidence

  @doc "An empty evidence fold."
  @spec new() :: map()
  def new, do: %{functions: %{}, crashed: %{}, logger: %{}, logger_reports: %{}, telemetry: %{}}

  @doc """
  Adds one disclosed event: a failing crash or exception event adds the
  function its stack points at, a supervisor child termination its child's
  module, a Logger event its module (else domain), and a recorded Telemetry
  event its kind.
  """
  @spec add(map(), map(), integer()) :: map()
  def add(evidence, %{"source" => "logger"} = event, receipt) do
    evidence
    |> logger_origin(event)
    |> crashed(event)
    |> function(event, receipt)
  end

  def add(evidence, %{"source" => "telemetry", "kind" => kind} = event, receipt) do
    evidence =
      case event do
        %{"attributes" => %{"lifecycle_phase" => "summary"}} -> evidence
        _recorded -> %{evidence | telemetry: bump(evidence.telemetry, kind)}
      end

    function(evidence, event, receipt)
  end

  def add(evidence, _event, _receipt), do: evidence

  defp logger_origin(evidence, %{"kind" => "logger_summary"}), do: evidence

  # Only messages can be summarised (`Insider.Collector.Gate`): a report
  # (crash, supervisor, or any other report message) is always recorded, so
  # reports are counted by kind, apart from the origins a rule could reduce.
  defp logger_origin(evidence, %{"kind" => kind}) when kind not in @summarisable,
    do: %{evidence | logger_reports: bump(evidence.logger_reports, kind)}

  # The origin is kept as the Logger rule that would match it, so a rule is
  # never rebuilt from text.
  defp logger_origin(evidence, event) do
    origin =
      case module_of(get_in(event, ["payload", "metadata", "mfa"])) do
        nil -> domain(get_in(event, ["attributes", "domain"]))
        module -> %{"module" => module}
      end

    if origin, do: %{evidence | logger: bump(evidence.logger, origin)}, else: evidence
  end

  defp crashed(
         evidence,
         %{
           "kind" => "supervisor_child_terminated",
           "attributes" => %{"offender_id" => "atom:" <> name}
         }
       ),
       do: %{evidence | crashed: bump(evidence.crashed, display(name))}

  defp crashed(evidence, _event), do: evidence

  defp function(evidence, %{"severity" => severity} = event, receipt)
       when severity in @error_severities do
    if failure?(event) do
      case frame(event) do
        nil ->
          evidence

        spec ->
          row =
            Map.get(evidence.functions, spec, %{
              "function" => spec,
              "count" => 0,
              "first_receipt" => receipt
            })

          row = %{row | "count" => row["count"] + 1}
          row = Map.update(row, "kinds", [event["kind"]], &Enum.uniq(&1 ++ [event["kind"]]))
          %{evidence | functions: Map.put(evidence.functions, spec, row)}
      end
    else
      evidence
    end
  end

  defp function(evidence, _event, _receipt), do: evidence

  # Crash reports, supervisor reports, a Logger message that formats an
  # exception, and a Telemetry exception (or a failure with a stacktrace).
  defp failure?(%{"source" => "logger", "kind" => kind})
       when kind in ["process_crashed", "supervisor_child_terminated"],
       do: true

  defp failure?(%{"source" => "logger", "attributes" => %{"label" => "gen_server.terminate"}}),
    do: true

  defp failure?(%{"source" => "logger"} = event) do
    case get_in(event, ["payload", "message"]) do
      text when is_binary(text) -> String.contains?(text, "** (")
      _none -> false
    end
  end

  defp failure?(%{"source" => "telemetry", "kind" => kind} = event) do
    String.ends_with?(kind, "exception") or
      is_list(get_in(event, ["payload", "metadata", "stacktrace"]))
  end

  @doc """
  The first application function in an event's disclosed payload that a
  call trace could trace, as `MOD.FUN/ARITY`, or `nil`.
  """
  @spec frame(map()) :: String.t() | nil
  def frame(event) do
    payload = if is_map(event["payload"]), do: event["payload"], else: %{}
    message = if is_binary(payload["message"]), do: [payload["message"]], else: []

    # Texts in payload order: a stack's first frame first.
    (message ++ Enum.reverse(texts(Map.delete(payload, "message"), [])))
    |> Enum.take(@texts_max)
    |> Enum.find_value(&first_frame/1)
  end

  defp texts(value, acc) when is_binary(value), do: [value | acc]

  defp texts(value, acc) when is_map(value),
    do: value |> Enum.sort() |> Enum.reduce(acc, fn {_key, item}, acc -> texts(item, acc) end)

  defp texts(value, acc) when is_list(value), do: Enum.reduce(value, acc, &texts/2)
  defp texts(_value, acc), do: acc

  defp first_frame(text) do
    text = binary_part(text, 0, min(byte_size(text), @text_bytes))

    (Regex.scan(@tuple_frame, text, return: :index) ++
       Regex.scan(@elixir_frame, text, return: :index))
    |> Enum.sort_by(fn [{start, _length} | _groups] -> start end)
    |> Enum.find_value(fn [_whole | groups] ->
      [module, name, arity] =
        Enum.map(groups, fn {start, length} -> binary_part(text, start, length) end)

      application_spec(module, name, arity)
    end)
  end

  defp application_spec(module, name, arity) do
    # `:"name"` reads as `:name`, and `:"Elixir.Mod"` as `Elixir.Mod`.
    module = module |> String.replace("\"", "") |> String.replace_prefix(":Elixir.", "Elixir.")
    spec = "#{module}.#{name}/#{arity}"

    with {:ok, {mod, _fun, _arity} = mfa} <- CallsOptions.function(spec),
         false <- Application.get_application(mod) in @runtime_apps do
      spec_of(mfa)
    else
      _not_application -> nil
    end
  end

  @doc "The digest's `call_candidates`: functions crashes pointed at, most first."
  @spec candidates(map()) :: [map()]
  def candidates(evidence) do
    evidence.functions
    |> Map.values()
    |> Enum.sort_by(&{-&1["count"], &1["first_receipt"]})
    |> Enum.take(@functions_max)
  end

  ## Hints

  @doc """
  The hints for a digest: call traces for its crash loops and repeated
  exceptions, and the amendments that stop the Recorder's evictions.
  """
  @spec digest(map(), map(), context()) :: [map()]
  def digest(digest, evidence, context) do
    loops = Map.new(digest["crash_loops"] || [], &{&1["offender"], &1})

    functions =
      evidence.functions
      |> Map.values()
      |> Enum.filter(&(&1["count"] >= 2 or Map.has_key?(loops, module_part(&1["function"]))))
      |> Enum.sort_by(&{-&1["count"], &1["first_receipt"]})

    traced = functions |> Enum.map(&module_part(&1["function"])) |> MapSet.new()

    # A child that keeps crashing with no frame of its own module: its
    # GenServer callbacks.
    fallback =
      for {offender, loop} <- Enum.sort(loops),
          not MapSet.member?(traced, offender),
          specs = callbacks(offender),
          specs != [],
          do: %{"function" => specs, "count" => loop["restarts"], "crash_loop" => loop}

    trace =
      Enum.map(functions, fn row ->
        Map.put(row, "crash_loop", Map.get(loops, module_part(row["function"])))
      end) ++ fallback

    trace_hints(trace, context) ++ eviction_hints(digest, evidence, context)
  end

  @doc """
  The hints for one events batch: a call trace for each function a crash
  or exception the batch shows points at.
  """
  @spec batch([map()], context()) :: [map()]
  def batch(entries, context) do
    evidence =
      Enum.reduce(entries, new(), fn
        %{"receipt" => receipt, "event" => %{} = event}, evidence -> add(evidence, event, receipt)
        _entry, evidence -> evidence
      end)

    evidence.functions
    |> Map.values()
    |> Enum.sort_by(&{-&1["count"], &1["first_receipt"]})
    |> Enum.map(&Map.put(&1, "crash_loop", nil))
    |> trace_hints(context)
  end

  defp trace_hints([], _context), do: []

  defp trace_hints(rows, context) do
    rows
    |> Enum.reject(fn row ->
      Enum.all?(List.wrap(row["function"]), &(mfa(&1) in traced(context)))
    end)
    |> Enum.take(@functions_max)
    |> Enum.map(&trace_hint(&1, context))
  end

  defp trace_hint(row, %{calls_available: :ok} = context) do
    functions = List.wrap(row["function"])
    # One spelling per function: the session's own, then each new one.
    traced = traced(context)
    calls = context.calls ++ Enum.reject(Enum.uniq(functions), &(mfa(&1) in traced))
    components = Enum.uniq(context.components ++ ["calls"])
    max = CallsOptions.max_functions()

    if length(calls) > max do
      %{
        "kind" => "trace_calls",
        "reason" =>
          why(row) <>
            ". The session already traces #{length(context.calls)} functions, the most --calls allows is #{max}: " <>
            "amend with the --calls you still need and #{Enum.join(functions, ", ")} to trace it",
        "evidence" => Map.put(evidence(row), "limit", max),
        "command" => nil,
        "options" => nil,
        "manual" => nil
      }
    else
      options = %{"components" => components, "calls" => calls, "calls_results" => "exceptions"}

      flags =
        Enum.map(components, &{"--component", &1}) ++
          Enum.map(calls, &{"--calls", &1}) ++ [{"--calls-results", "exceptions"}]

      %{
        "kind" => "trace_calls",
        "reason" =>
          why(row) <>
            ". Trace #{Enum.join(functions, ", ")} to record each failing call's arguments and exception " <>
            "(call.exception events, and the digest's calls), then reproduce the failure",
        "evidence" => evidence(row),
        "command" => command(context, flags),
        "options" => options,
        "manual" => nil
      }
    end
  end

  defp trace_hint(row, %{calls_available: {:error, reason}}) do
    manual =
      row["function"]
      |> List.wrap()
      |> Enum.map_join("; ", fn spec ->
        {module, name, arity} = split(spec)
        ":recon_trace.calls({#{module}, :#{name}, #{arity}}, 10)"
      end)

    %{
      "kind" => "trace_calls_unavailable",
      "reason" =>
        why(row) <>
          ". Insider's call trace (--component calls) needs OTP 28 or later (#{reason}, this node runs OTP #{otp_release()}); " <>
          "trace it by hand from a remote shell with recon_trace instead",
      "evidence" => evidence(row),
      "command" => nil,
      "options" => nil,
      "manual" => manual
    }
  end

  defp why(%{"crash_loop" => %{} = loop, "function" => functions}) when is_list(functions) do
    "#{loop["offender"]} terminated #{loop["restarts"]} times#{period(loop)} and its crashes name no function; " <>
      "these are its GenServer callbacks"
  end

  defp why(%{"crash_loop" => %{} = loop} = row) do
    "#{loop["offender"]} terminated #{loop["restarts"]} times#{period(loop)}; #{row["count"]} crash reports " <>
      "point at #{row["function"]} (first at receipt #{row["first_receipt"]})"
  end

  defp why(row) do
    "#{row["count"]} failures point at #{row["function"]} (#{Enum.join(row["kinds"] || [], ", ")}, first at receipt #{row["first_receipt"]})"
  end

  defp period(%{"period_ms" => ms}) when is_integer(ms),
    do: ", every " <> :erlang.float_to_binary(ms / 1_000, decimals: 1) <> " s"

  defp period(_loop), do: ""

  defp evidence(row) do
    %{
      "functions" => List.wrap(row["function"]),
      "count" => row["count"],
      "first_receipt" => row["first_receipt"],
      "crash_loop" => row["crash_loop"] && row["crash_loop"]["offender"]
    }
  end

  defp callbacks(offender) do
    for {name, arity} <- @callbacks,
        {:ok, mfa} <- [CallsOptions.function("#{offender}.#{name}/#{arity}")],
        do: spec_of(mfa)
  end

  # The functions a session traces, as `--calls` resolves them, so two
  # spellings of one function (`Mod.f/1`, `Elixir.Mod.f/1`) are one.
  defp traced(context), do: context.calls |> Enum.map(&mfa/1) |> MapSet.new()

  defp mfa(spec) do
    case CallsOptions.function(spec) do
      {:ok, mfa} -> mfa
      {:error, _invalid} -> spec
    end
  end

  # A function as `--calls` accepts it: `Mod.fun/2` for an Elixir module,
  # `:mod.fun/2` for an Erlang one.
  defp spec_of({module, function, arity}) do
    name =
      case Atom.to_string(module) do
        "Elixir." <> alias -> alias
        erlang -> ":" <> erlang
      end

    "#{name}.#{function}/#{arity}"
  end

  ## Evictions

  # A source floods when the Recorder evicted its entries and it holds more
  # than its share of the events or of the bytes.
  defp eviction_hints(digest, evidence, context) do
    floods =
      context.sources
      |> Enum.filter(fn {_group, s} ->
        (s["evicted"] || 0) > 0 and (over_events?(s) or over_bytes?(s))
      end)
      |> Enum.sort_by(fn {group, s} -> {-s["evicted"], group} end)

    case floods do
      [] ->
        []

      floods ->
        Enum.flat_map(floods, &source_hint(&1, digest, evidence, context)) ++
          capacity(floods, context) ++ shared_readers(floods, context)
    end
  end

  # Readers share the session's one Recorder, and a read never keeps an
  # event: what one reader has not read yet is evicted for all of them.
  defp shared_readers(floods, %{readers: readers}) when is_integer(readers) and readers > 1 do
    evicted = floods |> Enum.map(fn {_group, s} -> s["evicted"] end) |> Enum.sum()

    [
      %{
        "kind" => "shared_readers",
        "reason" =>
          "#{readers} readers share this session's one Recorder, and reading never keeps an event, so each reader loses " <>
            "the #{evicted} evicted events whether or not another read them. With several readers, read summaries " <>
            "(digest, trends) rather than every event, summarise the frequent kinds at record time (--telemetry-summary, " <>
            "--logger-summary, as the hints above say), narrow each reader with --view-* flags (a view filters a read, not " <>
            "the Recorder), and read often enough that your cursor stays ahead of eviction",
        "evidence" => %{"readers" => readers, "evicted" => evicted},
        "command" => nil,
        "options" => nil,
        "manual" => nil
      }
    ]
  end

  defp shared_readers(_floods, _context), do: []

  defp source_hint({"logger", s}, _digest, evidence, context) do
    existing = context.filters["logger_summaries"] || []

    # The origin that logged most and that a session would accept as a
    # rule; an origin with shell or rule syntax is never offered.
    candidate =
      evidence.logger
      |> Enum.sort_by(fn {rule, count} -> {-count, rule_text(rule)} end)
      |> Enum.find(fn {rule, _count} -> rule not in existing and Filters.logger_rule?(rule) end)

    case candidate do
      nil ->
        reports_hint(s, evidence.logger_reports, context)

      {rule, count} ->
        origin = rule_text(rule)
        reports = evidence.logger_reports
        extra = %{"origin" => origin, "events" => count}
        extra = if reports == %{}, do: extra, else: Map.put(extra, "reports", reports)

        why =
          evicted("logger", s) <>
            "; #{count} of the window's Logger messages came from #{origin}. Summarise its messages " <>
            "(one logger_summary event per message template and interval) instead of recording each" <>
            reports_note(reports)

        [
          extend("reduce_logger", "logger", s, why, extra, context, {
            "logger_summaries",
            existing ++ [rule],
            Filters.max_rules(),
            "--logger-summary",
            &rule_text/1
          })
        ]
    end
  end

  defp source_hint({"telemetry", s}, _digest, evidence, context) do
    existing = context.filters["telemetry_summaries"] || []

    candidate =
      evidence.telemetry
      |> Enum.sort_by(fn {kind, count} -> {-count, kind} end)
      |> Enum.find(fn {kind, _count} -> kind not in existing and Regex.match?(@kind, kind) end)

    case candidate do
      nil ->
        []

      {kind, count} ->
        why =
          evicted("telemetry", s) <>
            "; #{count} of the window's recorded Telemetry events were #{kind}. Summarise it (one summary " <>
            "event per interval with count, errors and percentiles) instead of recording each"

        [
          extend(
            "reduce_telemetry",
            "telemetry",
            s,
            why,
            %{"kind" => kind, "events" => count},
            context,
            {"telemetry_summaries", existing ++ [kind], Filters.max_summaries(),
             "--telemetry-summary", & &1}
          )
        ]
    end
  end

  defp source_hint({"poller", s}, _digest, _evidence, %{poller_interval_ms: interval} = context)
       when is_integer(interval) and interval < @poller_interval_max do
    slower = min(interval * 2, @poller_interval_max)

    [
      %{
        "kind" => "reduce_poller",
        "reason" =>
          evicted("poller", s) <>
            "; sample half as often (every #{slower} ms instead of #{interval} ms)",
        "evidence" => source_evidence("poller", s, %{"interval_ms" => interval}),
        "command" => command(context, [{"--poller-interval-ms", slower}]),
        "options" => %{"poller_interval_ms" => slower},
        "manual" => nil
      }
    ]
  end

  defp source_hint(_source, _digest, _evidence, _context), do: []

  defp reports_note(reports) when map_size(reports) == 0, do: ""

  defp reports_note(reports) do
    "; the window's #{reports |> Map.values() |> Enum.sum()} reports are always recorded, a summary does not reduce them"
  end

  # A flood of reports: no summary rule reduces it. A larger Recorder keeps
  # more of it; otherwise the fix is in what reports.
  defp reports_hint(_s, reports, _context) when map_size(reports) == 0, do: []

  defp reports_hint(s, reports, context) do
    total = reports |> Map.values() |> Enum.sum()

    kinds =
      reports |> Enum.sort() |> Enum.map_join(", ", fn {kind, count} -> "#{kind} #{count}" end)

    # More events help only a flood over its event share, as for
    # raise_capacity; the byte bound is fixed.
    capacity =
      cond do
        not over_events?(s) ->
          "the Recorder's byte bound is fixed and logger is over its byte share, so more events would not help" <>
            "; only smaller or fewer reports do"

        is_integer(context.max_events) and context.max_events < context.max_events_bound ->
          "a larger Recorder keeps more of them (raise_capacity: --max-events #{context.max_events_bound})"

        true ->
          "the Recorder is at its event bound"
      end

    [
      %{
        "kind" => "logger_reports",
        "reason" =>
          evicted("logger", s) <>
            "; #{total} of the window's Logger events were reports (#{kinds}), which are always recorded and never " <>
            "summarised because they carry crash and supervisor evidence, so --logger-summary cannot reduce them; " <>
            capacity <> ", or stop what keeps reporting them",
        "evidence" => source_evidence("logger", s, %{"reports" => reports}),
        "command" => nil,
        "options" => nil,
        "manual" => nil
      }
    ]
  end

  # A larger Recorder raises every source's share of events; the byte bound
  # is fixed, so only a flood over its event share is helped.
  defp capacity(floods, %{max_events: max, max_events_bound: bound} = context)
       when is_integer(max) and max < bound do
    case Enum.filter(floods, fn {_group, s} -> over_events?(s) end) do
      [] -> []
      floods -> capacity_hint(floods, max, bound, context)
    end
  end

  defp capacity(_floods, _context), do: []

  defp capacity_hint(floods, max, bound, context) do
    counts = Enum.map_join(floods, ", ", fn {group, s} -> "#{group} #{s["evicted"]}" end)

    [
      %{
        "kind" => "raise_capacity",
        "reason" =>
          "The Recorder holds #{max} events and has evicted (#{counts}); each source's share (welcome recorder.source_shares_percent) " <>
            "is a percentage of it, so a larger Recorder keeps more of every source",
        "evidence" => %{
          "max_events" => max,
          "evicted" => Map.new(floods, fn {g, s} -> {g, s["evicted"]} end)
        },
        "command" => command(context, [{"--max-events", bound}]),
        "options" => %{"max_events" => bound},
        "manual" => nil
      }
    ]
  end

  # A list option's whole new value, or, when it would pass the option's
  # limit, why it cannot be added.
  defp extend(kind, group, s, why, extra, context, {option, list, max, flag, text}) do
    if length(list) > max do
      %{
        "kind" => kind,
        "reason" =>
          why <>
            "; but the session's #{option} already has #{length(list) - 1}, the most allowed is #{max}: " <>
            "amend it with the entries you still need",
        "evidence" => source_evidence(group, s, Map.put(extra, "limit", max)),
        "command" => nil,
        "options" => nil,
        "manual" => nil
      }
    else
      %{
        "kind" => kind,
        "reason" => why,
        "evidence" => source_evidence(group, s, extra),
        "command" => command(context, Enum.map(list, &{flag, text.(&1)})),
        "options" => %{option => list},
        "manual" => nil
      }
    end
  end

  defp over_events?(s), do: (s["retained_events"] || 0) >= (s["reserved_events"] || 0)

  defp over_bytes?(%{"retained_bytes" => retained, "reserved_bytes" => reserved})
       when is_integer(retained) and is_integer(reserved),
       do: retained >= reserved

  defp over_bytes?(_s), do: false

  defp evicted(group, s) do
    holds =
      [
        over_events?(s) &&
          "#{s["retained_events"]} events against its #{s["share_percent"]}% share of #{s["reserved_events"]}",
        over_bytes?(s) &&
          "#{s["retained_bytes"]} bytes against its #{s["share_percent"]}% share of #{s["reserved_bytes"]} bytes"
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" and ")

    "The Recorder evicted #{s["evicted"]} #{group} events since the session started or was last amended: " <>
      "#{group} holds #{holds}, so it evicts its own oldest"
  end

  defp source_evidence(group, s, extra) do
    Map.merge(
      %{
        "source" => group,
        "evicted" => s["evicted"],
        "retained_events" => s["retained_events"],
        "reserved_events" => s["reserved_events"],
        "retained_bytes" => s["retained_bytes"],
        "reserved_bytes" => s["reserved_bytes"],
        "share_percent" => s["share_percent"]
      },
      extra
    )
  end

  defp rule_text(%{"module" => name}), do: "module:" <> name
  defp rule_text(%{"domain" => segments}), do: "domain:" <> Enum.join(segments, ".")
  defp rule_text(%{"application" => name}), do: "application:" <> name

  ## Text

  @doc """
  One `Next:` line per hint for the human digest; with a `window` label,
  `Next (LABEL):`, the window the hint was worked out over.
  """
  @spec lines([map()], String.t() | nil) :: [String.t()]
  def lines(hints, window \\ nil) do
    next = if window, do: "Next (#{window}):", else: "Next:"

    Enum.map(hints, fn
      %{"command" => command, "reason" => reason} when is_binary(command) ->
        "#{next} #{reason}: #{command}"

      %{"manual" => manual, "reason" => reason} when is_binary(manual) ->
        "#{next} #{reason}: #{manual}"

      %{"reason" => reason} ->
        "#{next} #{reason}."
    end)
  end

  ## Helpers

  # Every value is single-quoted (a quote inside is `'\''`), so a shell
  # passes it through as one argument whatever it holds; `"${N[@]}"` stays the
  # welcome's placeholder for the target flags.
  defp command(context, flags) do
    [{"--session", context.session_id} | flags]
    |> Enum.map(fn {flag, value} -> flag <> " " <> shell_quote(to_string(value)) end)
    |> then(&Enum.join([@command | &1], " "))
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp bump(map, key), do: Map.update(map, key, 1, &(&1 + 1))

  defp module_of(mfa) when is_binary(mfa) do
    case Regex.run(~r/\A\{([A-Z][A-Za-z0-9_.]*), :/, mfa) do
      [_match, module] -> module
      nil -> nil
    end
  end

  defp module_of(_mfa), do: nil

  defp domain(segments) when is_list(segments) and segments != [],
    do: if(Enum.all?(segments, &is_binary/1), do: %{"domain" => segments})

  defp domain(_segments), do: nil

  defp module_part(spec) when is_binary(spec) do
    {module, _name, _arity} = split(spec)
    module
  end

  defp module_part(_specs), do: nil

  defp split(spec) do
    [head, arity] = String.split(spec, "/", parts: 2)
    [name | reversed] = head |> String.split(".") |> Enum.reverse()
    {reversed |> Enum.reverse() |> Enum.join("."), name, arity}
  end

  defp display("Elixir." <> name), do: name
  defp display(name), do: name

  defp otp_release, do: List.to_string(:erlang.system_info(:otp_release))
end

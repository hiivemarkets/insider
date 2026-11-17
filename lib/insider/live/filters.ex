defmodule Insider.Live.Filters do
  @moduledoc false

  # Record-time filters and summaries for a live session, and the quiet
  # defaults. `start/3` validates the caller's string-keyed options and
  # compiles them into an `Insider.Collector.Gate` spec; the gate then decides
  # in each emitting process whether an event is recorded. `report/3` turns
  # the gate's cumulative counts into the `"filtered"` field of a batch, so a
  # quiet session can always be told apart from an idle one.
  #
  # Names a caller supplies resolve only to atoms that already exist, so no
  # option creates atoms. Origin rules match the emitting process's initial
  # call and are expanded to module sets here, once, so the emitting process
  # does a map lookup and nothing more.

  alias Insider.Collector.Gate
  alias Insider.Live.Error
  alias Insider.Live.Options
  alias Insider.Protocol.Value

  @start_keys [
    "exclude_origins",
    "logger_exclude",
    "logger_include",
    "logger_level",
    "logger_summaries",
    "logger_summary_interval_ms",
    "otel_min_duration_ms",
    "telemetry_duration_scopes",
    "telemetry_event_min_duration_ms",
    "telemetry_min_duration_ms",
    "telemetry_summaries",
    "telemetry_summary_interval_ms"
  ]
  @level_atoms %{
    "emergency" => :emergency,
    "alert" => :alert,
    "critical" => :critical,
    "error" => :error,
    "warning" => :warning,
    "notice" => :notice,
    "info" => :info,
    "debug" => :debug
  }
  @default_level "warning"
  @default_origins ["oban"]
  @min_duration_ms %{"default" => 100, "max" => 3_600_000, "min" => 0}
  # A span is one segment of a trace; a trace with segments missing is hard
  # to read, so every span is recorded unless the caller says otherwise.
  @otel_min_duration_ms %{"default" => 0, "max" => 3_600_000, "min" => 0}
  @summary_interval_ms %{"default" => 10_000, "max" => 300_000, "min" => 1_000}
  @max_rules 16
  @max_summaries 16
  @duration_scopes ["handler", "caller"]
  @max_domain_segments 8
  @max_repos 8
  @no_defaults_hint "no default Telemetry events exist on this node; pass --telemetry-event or use discover"
  @segment ~r/\A[a-z][a-z0-9_]*\z/
  @module_name ~r/\A[A-Za-z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*\z/
  # Events that stand for one unit of work (a request, a job) are recorded
  # whatever their duration unless the caller says otherwise.
  @event_minimums %{
    "absinthe.execute.operation.stop" => 0,
    "bandit.request.stop" => 0,
    "cowboy.request.stop" => 0,
    "oban.job.stop" => 0,
    "phoenix.endpoint.stop" => 0
  }
  # Quiet-default events other than the repositories' query events. Each is
  # used only when its application is loaded and its atoms already exist.
  @known_events [
    {:phoenix, ["phoenix", "endpoint", "stop"]},
    {:phoenix, ["phoenix", "router_dispatch", "exception"]},
    {:oban, ["oban", "job", "exception"]},
    {:absinthe, ["absinthe", "execute", "operation", "stop"]},
    # The web server's request stop: with Phoenix's endpoint stop, the wait
    # before the endpoint (`Insider.Collector.RequestTiming`).
    {:bandit, ["bandit", "request", "stop"]},
    {:cowboy_telemetry, ["cowboy", "request", "stop"]}
  ]
  # The one Oban process that runs application code: a job. Its queries and
  # logs are the application's, not Oban's.
  @oban_job_modules [Oban.Queue.Executor]
  @oban_applications [:oban, :oban_met, :oban_pro, :oban_web]

  @type parsed :: %{spec: Gate.spec(), config: map()}

  @spec start_keys() :: [String.t()]
  def start_keys, do: @start_keys

  @doc "The most rules a Logger rule list (such as `logger_summaries`) takes."
  @spec max_rules() :: pos_integer()
  def max_rules, do: @max_rules

  @doc "The most kinds `telemetry_summaries` takes."
  @spec max_summaries() :: pos_integer()
  def max_summaries, do: @max_summaries

  @doc """
  Whether `rule` is a Logger rule (`%{"domain" => [...]}`,
  `%{"application" => name}`, or `%{"module" => name}`) a session would
  accept: well-formed, and naming only atoms that already exist.
  """
  @spec logger_rule?(term()) :: boolean()
  def logger_rule?(rule), do: match?({:ok, _parsed}, logger_rule(rule))

  @doc """
  The default components: Logger, plus Telemetry when this node has quiet
  default events to record.
  """
  @spec default_components() :: [String.t()]
  def default_components do
    if default_telemetry_events() == [], do: ["logger"], else: ["logger", "telemetry"]
  end

  @doc """
  The quiet default Telemetry events on this node, as segment lists: each
  configured Ecto repository's query event (`ecto_repos` and its
  `telemetry_prefix`), Phoenix's endpoint stop and router dispatch exception,
  Oban's job exception, Absinthe's operation stop (which carries the
  GraphQL outcome), and Bandit's (or Cowboy's) request stop (which, with
  the endpoint stop, gives each request's wait before the endpoint), for
  the applications that are loaded.
  """
  @spec default_telemetry_events() :: [[String.t()]]
  def default_telemetry_events, do: elem(telemetry_defaults(), 0)

  @doc """
  The quiet default Telemetry events split by whether this node has them:
  `{recorded, skipped}`. A default is skipped when its application is not
  loaded or one of its segments is not already an atom here, so a session
  that records the defaults never creates an atom and never refuses one.
  `skipped_defaults/1` describes the skipped ones.
  """
  @spec telemetry_defaults() :: {[[String.t()]], [[String.t()]]}
  def telemetry_defaults do
    {repos, missing_repos} = repo_events()

    {known, missing} =
      Enum.split_with(@known_events, fn {application, segments} ->
        loaded?(application) and existing?(segments)
      end)

    {Enum.uniq(repos ++ Enum.map(known, &elem(&1, 1))),
     Enum.uniq(missing_repos ++ Enum.map(missing, &elem(&1, 1)))}
  end

  @doc """
  The skipped defaults as a start or amendment result lists them under
  `"telemetry_skipped_defaults"`: each event's dotted name and the reason.
  """
  @spec skipped_defaults([[String.t()]]) :: [map()]
  def skipped_defaults(skipped) do
    for segments <- skipped,
        do: %{"event" => Enum.join(segments, "."), "reason" => "not_on_target"}
  end

  @doc "The one-line hint for a node where no default Telemetry event exists."
  @spec no_defaults_hint() :: String.t()
  def no_defaults_hint, do: @no_defaults_hint

  @doc """
  Validates the filter options. `components` are the session's component
  atoms and `events` its `{segments, atoms}` Telemetry events.
  """
  @spec start(map(), [atom()], [{[String.t()], [atom()]}]) :: {:ok, parsed()} | {:error, map()}
  def start(options, components, events) do
    kinds = Map.new(events, fn {segments, atoms} -> {Enum.join(segments, "."), atoms} end)

    with {:ok, level} <- level(Map.get(options, "logger_level", @default_level)),
         {:ok, include} <- logger_rules(options, "logger_include"),
         {:ok, exclude} <- logger_rules(options, "logger_exclude"),
         {:ok, bursts} <- logger_summaries(options, components),
         {:ok, burst_interval} <-
           Options.bounded_integer(options, "logger_summary_interval_ms", @summary_interval_ms),
         {:ok, origins} <- origins(Map.get(options, "exclude_origins", @default_origins)),
         {:ok, minimum} <-
           Options.bounded_integer(options, "telemetry_min_duration_ms", @min_duration_ms),
         {:ok, per_event} <- event_minimums(options, kinds),
         {:ok, summaries} <- summaries(Map.get(options, "telemetry_summaries", []), kinds),
         {:ok, scopes} <-
           duration_scopes(Map.get(options, "telemetry_duration_scopes", %{}), summaries),
         {:ok, interval} <-
           Options.bounded_integer(
             options,
             "telemetry_summary_interval_ms",
             @summary_interval_ms
           ),
         {:ok, otel_minimum} <- otel_minimum(options, components) do
      minimums =
        Map.new(kinds, fn {kind, _atoms} ->
          {kind, Map.get(per_event, kind, Map.get(@event_minimums, kind, minimum))}
        end)

      spec = %{
        logger:
          if(:logger in components,
            do: %{
              level: Map.fetch!(@level_atoms, level),
              include: include.matcher,
              exclude: exclude.matcher,
              summary: bursts.matcher,
              summary_interval_ms: burst_interval
            }
          ),
        origin: origins.origin,
        telemetry:
          Enum.map(kinds, fn {kind, atoms} ->
            %{
              name: atoms,
              kind: kind,
              min_duration_ms: Map.fetch!(minimums, kind),
              summary: kind in summaries,
              duration_scope: Map.get(scopes, kind)
            }
          end),
        summary_interval_ms: interval,
        otel: if(:otel in components, do: %{min_duration_ms: otel_minimum})
      }

      {:ok,
       %{
         spec: spec,
         config:
           %{
             "logger_level" => level,
             "logger_include" => include.echo,
             "logger_exclude" => exclude.echo,
             "logger_summaries" => bursts.echo,
             "logger_summary_interval_ms" => burst_interval,
             "exclude_origins" => origins.echo,
             "telemetry_min_duration_ms" => minimum,
             "telemetry_event_min_duration_ms" => minimums,
             "telemetry_summaries" => Enum.sort(summaries),
             "telemetry_summary_interval_ms" => interval,
             "telemetry_duration_scopes" => scopes
           }
           |> put_otel(:otel in components, otel_minimum)
       }}
    end
  end

  # Logger bursts need the Logger component.
  defp logger_summaries(options, components) do
    case logger_rules(options, "logger_summaries") do
      {:ok, %{matcher: %{}}} = result ->
        if :logger in components, do: result, else: invalid("logger_summaries")

      other ->
        other
    end
  end

  @doc """
  The `"filtered"` field of a batch. `counts` are the gate's cumulative
  counts and `baseline` those stored when the reader's cursor was issued
  (`nil` reports since session start). `view` holds the read-time counts.
  """
  @spec report(map(), map() | nil, map() | nil) :: map()
  def report(counts, baseline, view) do
    base = baseline || %{}

    Enum.reduce(
      counts,
      %{
        "scope" => if(is_nil(baseline), do: "since_session_start", else: "since_cursor_issued"),
        "logger" => %{},
        "telemetry" => %{},
        "view" => view || %{}
      },
      fn {key, count}, report ->
        delta = max(count - Map.get(base, key, 0), 0)

        case key do
          {"logger", filter} ->
            put_in(report, ["logger", filter], delta)

          {"telemetry", kind, filter} ->
            update_in(
              report,
              ["telemetry"],
              &Map.update(&1, kind, %{filter => delta}, fn counts ->
                Map.put(counts, filter, delta)
              end)
            )

          {"otel", filter} ->
            put_in(report, [Access.key("otel", %{}), filter], delta)

          _loss ->
            report
        end
      end
    )
  end

  @doc """
  Gaps for summary evidence the session lost, as deltas since `baseline`,
  in the batch gap shape. They are losses, not filtered events: summary
  samples the gate could not store (`telemetry_summary_lost`), exemplars
  that never reached a summary (`telemetry_exemplar_lost`,
  `logger_exemplar_lost`), and Logger burst distinctions folded into an
  overflow row (`logger_summary_overflow`).
  """
  @spec loss_gaps(map(), map() | nil) :: [map()]
  def loss_gaps(counts, baseline) do
    scope = if is_nil(baseline), do: "since_session_start", else: "since_cursor_issued"

    for {key, reason} <- [
          {{"summary_lost"}, "telemetry_summary_lost"},
          {{"exemplar_lost", "telemetry"}, "telemetry_exemplar_lost"},
          {{"exemplar_lost", "logger"}, "logger_exemplar_lost"},
          {{"summary_overflow", "logger"}, "logger_summary_overflow"}
        ],
        lost = Map.get(counts, key, 0) - Map.get(baseline || %{}, key, 0),
        lost > 0,
        do: %{"reason" => reason, "count" => lost, "scope" => scope}
  end

  @doc "Whether a report counts any filtered event."
  @spec any?(map() | nil) :: boolean()
  def any?(%{"logger" => logger, "telemetry" => telemetry, "view" => view} = report) do
    Enum.any?(Map.values(logger), &(&1 > 0)) or
      Enum.any?(telemetry, fn {_kind, counts} -> Enum.any?(Map.values(counts), &(&1 > 0)) end) or
      Enum.any?(Map.values(Map.get(report, "otel", %{})), &(&1 > 0)) or
      Enum.any?(Map.values(view), &(&1 > 0))
  end

  def any?(_report), do: false

  @doc """
  The filter options with their defaults and bounds, for the welcome
  document's `"start"` option group.
  """
  @spec describe_options() :: map()
  def describe_options do
    rule = "a map with exactly one of \"domain\" (segment list), \"application\", or \"module\""

    %{
      "logger_level" => %{
        "type" => "string",
        "default" => @default_level,
        "allowed" => Gate.levels(),
        "note" =>
          "the least severe Logger level recorded; OTP SASL-domain reports (crash, supervisor, progress) pass it"
      },
      "logger_include" => %{
        "type" => "list of rules",
        "default" => [],
        "max" => @max_rules,
        "rule" => rule,
        "note" => "when non-empty, only Logger events matching a rule are recorded"
      },
      "logger_exclude" => %{
        "type" => "list of rules",
        "default" => [],
        "max" => @max_rules,
        "rule" => rule,
        "note" => "Logger events matching a rule are not recorded"
      },
      "logger_summaries" => %{
        "type" => "list of rules",
        "default" => [],
        "max" => @max_rules,
        "rule" => rule,
        "requires_component" => "logger",
        "note" =>
          "Logger messages (not reports) that pass the other filters and match a rule are counted per level, " <>
            "message template and call site (a burst) instead of being recorded: one logger_summary event per burst " <>
            "per interval, its first message recorded as the exemplar; at most #{Gate.max_bursts()} bursts per " <>
            "interval, messages of further bursts are counted in one overflow row per level"
      },
      "logger_summary_interval_ms" => Map.put(@summary_interval_ms, "type", "integer"),
      "exclude_origins" => %{
        "type" => "list of origins",
        "default" => @default_origins,
        "max" => @max_rules,
        "origin" => "\"oban\", or a map with exactly one of \"application\" or \"module\"",
        "note" =>
          "Logger and Telemetry events emitted by these processes, and spans they end, are not recorded; [] records every origin"
      },
      "otel_min_duration_ms" =>
        Map.merge(@otel_min_duration_ms, %{
          "type" => "integer",
          "requires_component" => "otel",
          "note" => "a span shorter than this is not recorded unless its status is error"
        }),
      "telemetry_min_duration_ms" => Map.put(@min_duration_ms, "type", "integer"),
      "telemetry_event_min_duration_ms" => %{
        "type" => "map of event kind to integer",
        "default" => @event_minimums,
        "max" => @min_duration_ms["max"],
        "note" =>
          "per-event minimum duration; an event below it is not recorded unless severity.telemetry rates it error"
      },
      "telemetry_summaries" => %{
        "type" => "list of event kinds",
        "default" => [],
        "max" => @max_summaries,
        "note" =>
          "each listed event is folded into one summary event per interval instead of being recorded"
      },
      "telemetry_summary_interval_ms" => Map.put(@summary_interval_ms, "type", "integer"),
      "telemetry_duration_scopes" => %{
        "type" => "map of summarised event kind to \"handler\" or \"caller\"",
        "default" => %{},
        "max" => @max_summaries,
        "allowed" => @duration_scopes,
        "note" =>
          "declares what a summarised event's duration measures: handler (time inside the code that handles the " <>
            "request, without any wait before it) or caller (the latency the caller saw, waits included); " <>
            "summary duration_scope.measured_in is unknown for every kind not declared here"
      }
    }
  end

  @doc """
  The quiet defaults, the filter order, and the `"filtered"` batch field,
  for the welcome document's `"filters"` section.
  """
  @spec describe() :: map()
  def describe do
    %{
      "available" => @start_keys,
      "quiet_defaults" => %{
        "components" => "logger, plus telemetry when the node has default events",
        "telemetry_events" =>
          "each Ecto repository's query event, phoenix.endpoint.stop, " <>
            "phoenix.router_dispatch.exception, oban.job.exception, " <>
            "absinthe.execute.operation.stop, bandit.request.stop, cowboy.request.stop (when loaded)",
        "logger_level" => @default_level,
        "exclude_origins" => @default_origins,
        "telemetry_min_duration_ms" => @min_duration_ms["default"],
        "telemetry_event_min_duration_ms" => @event_minimums,
        "otel_min_duration_ms" => @otel_min_duration_ms["default"],
        "always_recorded" => [
          "Logger events at the level or more severe",
          "OTP crash, supervisor, and SASL reports",
          "Telemetry errors: every event severity.telemetry rates error"
        ]
      },
      "order" => Gate.filter_names(),
      "durations" =>
        "duration, else total_time, in native units; an event without either is never dropped for duration",
      "oban_origin" =>
        "Oban.Repo queries (telemetry option oban_conf) and processes started by modules of oban, oban_pro, oban_met, or oban_web, " <>
          "except job execution (Oban.Queue.Executor)",
      "summary" => %{
        "attribute" => "summary",
        "lifecycle_phase" => "summary",
        "fields" => [
          "count",
          "errors",
          "timed",
          "duration_measurements",
          "duration_p50_us",
          "duration_p95_us",
          "duration_max_us",
          "interval_ms",
          "window_started_at",
          "window_ended_at",
          "exemplars",
          "exemplars_lost",
          "first_error_retained",
          "duration_scope"
        ],
        "errors" => "the folded events that severity.telemetry rates error",
        "precision" =>
          "percentiles are histogram bucket upper bounds: at most 1/16 above the true value, never above the maximum",
        "consistency" => "every sample's fields, the maximum included, land in one interval",
        "window" =>
          "window_started_at and window_ended_at are the wall times (ISO 8601, UTC) the interval began and ended; " <>
            "interval_ms is its length on the monotonic clock",
        "exemplars" =>
          "up to 3 of the interval's slowest events (role slowest, to within one histogram bucket) and its first error " <>
            "(role first_error), recorded just before the summary: each has receipt, roles, duration_us and error. " <>
            "Read one with events --cursor RECEIPT-1 --limit 1; its attributes.exemplar_of names the summary's kind. " <>
            "Exemplars are summarised events too: the summarized count includes them. The first error always reaches " <>
            "the collector through a slot reserved per kind and interval, never the shared inbox",
        "exemplars_lost" =>
          "the candidates of this interval lost before the summary was recorded: the collector's inbox was full, " <>
            "the event could not be normalised, the Recorder refused it, or its receipt was unknown; a candidate " <>
            "that arrives after its summary is counted in the read gap telemetry_exemplar_lost only",
        "first_error_retained" =>
          "null when errors is 0; true when the interval's first error is among exemplars; false when it was lost",
        "duration_scope" =>
          "null without exemplars; else measured_in (handler or caller when telemetry_duration_scopes declares the " <>
            "kind, then declared true; else unknown, declared false) and emitter, the observed context of the " <>
            "processes that emitted the exemplars: context otp_server (module, the server's callback module), " <>
            "process, or mixed (module null). The emitter is never a claim about scope: a server that calls " <>
            "another server measures a caller's wait",
        "gaps" =>
          "telemetry_exemplar_lost counts every lost candidate, telemetry_summary_lost every sample that could " <>
            "not be stored",
        "disclosure" =>
          "strict: the duration statistics and exemplar durations are disclosed only when every name in " <>
            "duration_measurements is in the host measurement allowlist, else nil with a drop record (one per " <>
            "exemplar, path index:N), and duration_scope.emitter.module is withheld; rich: disclosed without that check",
        "empty_interval" => "no summary event; the summarized count still shows folded events",
        "session_end" =>
          "a subscriber's final read on stop or lease expiry first records the pending interval; " <>
            "a revoked session records nothing more"
      },
      "logger_summary" => %{
        "kind" => "logger_summary",
        "attribute" => "summary",
        "fields" => [
          "count",
          "level",
          "template",
          "template_fingerprint",
          "call_site",
          "call_site_fingerprint",
          "call_sites",
          "exemplar_receipt",
          "exemplar_lost",
          "overflow",
          "distinct_lost",
          "interval_ms",
          "window_started_at",
          "window_ended_at"
        ],
        "row" =>
          "one event per burst per interval: a level, message template and call site (module, function/arity, " <>
            "line from Logger metadata); two templates at one call site are two bursts, messages that differ only " <>
            "in numbers, pids, references or long hex runs are one. Severity is the level's (see severity), so " <>
            "--view-min-severity error keeps error bursts",
        "exemplar" =>
          "the interval's first message of the burst is recorded as an ordinary Logger event; exemplar_receipt " <>
            "is its receipt. exemplar_lost is true when it never reached the Recorder (inbox full, not normalised, " <>
            "refused, or still in flight when the burst was recorded); the read gap logger_exemplar_lost counts these",
        "template" =>
          "the message's first line, at most its first 160 bytes, with numbers, pids, references and long hex runs " <>
            "replaced; a format message's template is its format string. Rich: recorded; strict: null. " <>
            "template_fingerprint (16 hex) tells templates apart in both",
        "bound" =>
          "at most #{Gate.max_bursts()} bursts per interval, admitted as they first occur; messages of any other " <>
            "burst are counted in one overflow row per level (overflow true, template and call_site null, " <>
            "template_fingerprint and call_site_fingerprint overflow, call_sites null), whose distinct_lost counts the " <>
            "bursts folded into it (a lower bound: hashed, collisions undercount); the read gap " <>
            "logger_summary_overflow counts them too. Other rows have overflow false and distinct_lost 0",
        "disclosure" =>
          "strict: call_site and template are withheld with drop records; the fingerprints tell bursts apart"
      },
      "filtered" => %{
        "scope" => ["since_cursor_issued", "since_session_start"],
        "logger" => Gate.filter_names()["logger"],
        "otel" => Gate.filter_names()["otel"],
        "telemetry" => Gate.filter_names()["telemetry"],
        "view" => "read-time counts of this reader's view for this batch"
      }
    }
  end

  defp level(level) when is_map_key(@level_atoms, level), do: {:ok, level}
  defp level(_level), do: invalid("logger_level")

  defp logger_rules(options, field) do
    case Map.get(options, field, []) do
      [] ->
        {:ok, %{matcher: nil, echo: []}}

      rules ->
        with true <- Value.bounded_list?(rules, @max_rules),
             {:ok, parsed} <- map_all(rules, &logger_rule/1) do
          {:ok, %{matcher: matcher(parsed), echo: Enum.map(parsed, &elem(&1, 1))}}
        else
          _invalid -> invalid(field)
        end
    end
  end

  defp logger_rule(%{"domain" => segments} = rule) when map_size(rule) == 1 do
    if Value.bounded_list?(segments, @max_domain_segments) and segments != [] and
         Enum.all?(segments, &segment?/1) and existing?(segments),
       do: {:ok, {{:domain, Enum.map(segments, &String.to_existing_atom/1)}, rule}},
       else: :error
  end

  defp logger_rule(rule), do: process_rule(rule)

  defp process_rule(%{"application" => name} = rule) when map_size(rule) == 1 do
    if segment?(name) and existing?([name]),
      do: {:ok, {{:application, String.to_existing_atom(name)}, rule}},
      else: :error
  end

  defp process_rule(%{"module" => name} = rule) when map_size(rule) == 1 do
    case module_atom(name) do
      {:ok, module} -> {:ok, {{:module, module}, rule}}
      :error -> :error
    end
  end

  defp process_rule(_rule), do: :error

  defp origins(origins) do
    with true <- origins == [] or Value.bounded_list?(origins, @max_rules),
         true <- origins == Enum.uniq(origins),
         {:ok, parsed} <- map_all(origins, &origin/1) do
      oban? = Enum.any?(parsed, &match?({:oban, _echo}, &1))
      rules = for {rule, _echo} <- parsed, rule != :oban, do: rule
      modules = matcher(Enum.map(rules, &{&1, nil})).modules
      modules = if oban?, do: Map.merge(modules, oban_modules()), else: modules
      origin = if parsed == [], do: nil, else: %{oban_conf: oban?, modules: modules}
      {:ok, %{origin: origin, echo: Enum.map(parsed, &elem(&1, 1))}}
    else
      _invalid -> invalid("exclude_origins")
    end
  end

  defp origin("oban"), do: {:ok, {:oban, "oban"}}

  defp origin(rule) when is_map(rule), do: process_rule(rule)

  defp origin(_origin), do: :error

  # Application rules match the `:application` Logger metadata and every
  # module of the application; module rules match the module and its
  # namespace (`Oban` matches `Oban.Stager`).
  defp matcher(parsed) do
    rules = Enum.map(parsed, &elem(&1, 0))
    applications = for {:application, application} <- rules, do: application
    modules = for {:module, module} <- rules, do: module

    %{
      domains: for({:domain, domain} <- rules, do: domain),
      applications: Map.new(applications, &{&1, true}),
      modules:
        Map.new(
          Enum.flat_map(applications, &application_modules/1) ++
            Enum.flat_map(modules, &namespace_modules/1),
          &{&1, true}
        )
    }
  end

  # Oban's own machinery spans its companion applications: Pro's plugins
  # (such as Oban.Pro.Refresher), Met's reporters, and Web's cache run
  # queries on their own timers, as Oban's producers and stager do.
  defp oban_modules do
    @oban_applications
    |> Enum.flat_map(&application_modules/1)
    |> Enum.reject(&(&1 in @oban_job_modules))
    |> Map.new(&{&1, true})
  end

  defp application_modules(application) do
    case Application.spec(application, :modules) do
      modules when is_list(modules) -> modules
      nil -> []
    end
  end

  # A namespace is resolved once, at session start, from every loaded
  # application's module list and every loaded module.
  defp namespace_modules(module) do
    prefix = Atom.to_string(module) <> "."

    candidates =
      Enum.map(:code.all_loaded(), &elem(&1, 0)) ++
        for {application, _description, _version} <- Application.loaded_applications(),
            candidate <- application_modules(application),
            do: candidate

    [module | Enum.filter(candidates, &String.starts_with?(Atom.to_string(&1), prefix))]
  end

  defp module_atom(name) when is_binary(name) and byte_size(name) in 1..128 do
    if String.match?(name, @module_name) do
      full = if name =~ ~r/\A[A-Z]/, do: "Elixir." <> name, else: name

      if existing?([full]), do: {:ok, String.to_existing_atom(full)}, else: :error
    else
      :error
    end
  end

  defp module_atom(_name), do: :error

  defp event_minimums(options, kinds) do
    case Map.get(options, "telemetry_event_min_duration_ms", %{}) do
      minimums when is_map(minimums) and not is_struct(minimums) ->
        if map_size(minimums) <= map_size(kinds) and
             Enum.all?(minimums, fn {kind, value} ->
               is_map_key(kinds, kind) and is_integer(value) and
                 value in @min_duration_ms["min"]..@min_duration_ms["max"]
             end),
           do: {:ok, minimums},
           else: invalid("telemetry_event_min_duration_ms")

      _invalid ->
        invalid("telemetry_event_min_duration_ms")
    end
  end

  defp summaries([], _kinds), do: {:ok, []}

  defp summaries(summaries, kinds) do
    if Value.bounded_list?(summaries, @max_summaries) and summaries == Enum.uniq(summaries) and
         Enum.all?(summaries, &(is_binary(&1) and is_map_key(kinds, &1))),
       do: {:ok, summaries},
       else: invalid("telemetry_summaries")
  end

  # The span minimum needs the otel component, as the Telemetry options need
  # theirs.
  defp otel_minimum(options, components) do
    cond do
      :otel in components ->
        Options.bounded_integer(options, "otel_min_duration_ms", @otel_min_duration_ms)

      Map.has_key?(options, "otel_min_duration_ms") ->
        invalid("otel_min_duration_ms")

      true ->
        {:ok, nil}
    end
  end

  defp put_otel(config, true, minimum), do: Map.put(config, "otel_min_duration_ms", minimum)
  defp put_otel(config, false, _minimum), do: config

  # A declared duration scope names what a summarised event's duration
  # measures; the collector cannot tell it from where the event is emitted.
  defp duration_scopes(scopes, summaries) when is_map(scopes) and not is_struct(scopes) do
    if map_size(scopes) <= @max_summaries and
         Enum.all?(scopes, fn {kind, scope} ->
           kind in summaries and scope in @duration_scopes
         end),
       do: {:ok, scopes},
       else: invalid("telemetry_duration_scopes")
  end

  defp duration_scopes(_scopes, _summaries), do: invalid("telemetry_duration_scopes")

  # Ecto's default prefix is the repository module's underscored segments
  # (`MyApp.Repo` emits `[:my_app, :repo, :query]`) unless the repository
  # configuration sets `:telemetry_prefix`. Only application configuration
  # is read, so no repository callback runs. Returns `{found, missing}`:
  # the query events whose atoms exist, and those whose atoms do not, each
  # at most `@max_repos`.
  defp repo_events do
    for {application, _description, _version} <- Application.loaded_applications(),
        repo <- configured_repos(application),
        segments <- repo_event(application, repo),
        reduce: {[], []} do
      {found, missing} ->
        if existing?(segments),
          do: {bounded_append(found, segments), missing},
          else: {found, bounded_append(missing, segments)}
    end
  end

  defp bounded_append(events, segments),
    do: if(length(events) < @max_repos, do: events ++ [segments], else: events)

  defp configured_repos(application) do
    case Application.get_env(application, :ecto_repos, []) do
      repos when is_list(repos) -> Enum.filter(repos, &is_atom/1)
      _other -> []
    end
  end

  defp repo_event(application, repo) do
    prefix =
      case Application.get_env(application, repo, []) do
        config when is_list(config) -> Keyword.get(config, :telemetry_prefix)
        _other -> nil
      end

    segments =
      case prefix do
        nil -> default_prefix(repo)
        atoms when is_list(atoms) -> Enum.map(atoms, &atom_segment/1)
        _other -> nil
      end

    with segments when is_list(segments) and segments != [] <- segments,
         event = segments ++ ["query"],
         true <- length(event) <= @max_domain_segments,
         true <- Enum.all?(event, &segment?/1) do
      [event]
    else
      _invalid -> []
    end
  rescue
    _error -> []
  end

  defp default_prefix(repo), do: repo |> Module.split() |> Enum.map(&Macro.underscore/1)

  defp atom_segment(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp atom_segment(_value), do: ""

  defp loaded?(application), do: Application.spec(application, :vsn) != nil

  defp segment?(value),
    do: is_binary(value) and byte_size(value) in 1..64 and String.match?(value, @segment)

  defp existing?(strings) do
    Enum.each(strings, &String.to_existing_atom/1)
    true
  rescue
    ArgumentError -> false
  end

  defp map_all(values, mapper) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, mapped} ->
      case mapper.(value) do
        {:ok, item} -> {:cont, {:ok, [item | mapped]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, mapped} -> {:ok, Enum.reverse(mapped)}
      :error -> :error
    end
  end

  defp invalid(field), do: {:error, Error.new("invalid_options", %{"field" => field})}
end

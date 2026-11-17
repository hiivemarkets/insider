defmodule Insider.Lab.PrivacyCorpus do
  @moduledoc """
  Runs a caller-supplied synthetic privacy corpus through the exact Logger and
  Telemetry ingress code paths and reports which field names survive.

  Every item is handed to the real collector handlers
  (`Insider.Collector.Logger.Handler.log/2` and
  `Insider.Collector.Telemetry.Handler.handle_event/4`) with the Logger
  settings derived from the selected `Insider.Collector.IngressProfile` and the
  caller's exact `Insider.Collector.Telemetry.Policy`. No allowlist is
  reimplemented here. The report lists retained field paths, suppression
  counts, and the item/field coordinates of every declared canary token that
  appears in projected output, plus each item's source, disposition, and
  handler-classified event kind, the caller's policy id and fingerprint, and
  fixed settings, bounds, and limitation names. It never contains the value
  of a retained field.

  The corpus content and the review of every retained field are human work.
  A report with no canary hits is bounded evidence about the supplied items
  only; it does not prove application coverage or authorize observation.
  """

  alias Insider.Collector.IngressProfile
  alias Insider.Collector.Logger, as: LoggerCollector
  alias Insider.Collector.Logger.Handler, as: LoggerHandler
  alias Insider.Collector.Telemetry.Handler, as: TelemetryHandler
  alias Insider.Collector.Telemetry.Policy, as: TelemetryPolicy
  alias Insider.Event

  @schema "insider.privacy-corpus-report/v1"
  @corpus_schema "insider.privacy-corpus/v1"
  @max_items 4_096
  @max_item_bytes 65_536
  @max_canary_tokens 32
  @max_canary_bytes 128
  @max_event_segments 8
  @max_atom_bytes 64
  @option_keys [:environment, :telemetry_policy]
  @corpus_keys ["canary_tokens", "items", "schema", "telemetry_policy"]
  @logger_required ["level", "message", "source"]
  @logger_keys ["metadata" | @logger_required]
  @telemetry_required ["event_name", "source"]
  @telemetry_keys ["measurements", "metadata" | @telemetry_required]
  @policy_keys ["correlation", "events", "id", "measurements", "metadata"]
  @event_rule_keys ["kind", "lifecycle", "name", "phase"]
  @phases %{"event" => :event, "exception" => :exception, "start" => :start, "stop" => :stop}
  @correlation_targets %{
    "logical_operation_id" => :logical_operation_id,
    "parent_event_id" => :parent_event_id,
    "process_generation" => :process_generation,
    "span_id" => :span_id,
    "trace_id" => :trace_id
  }
  @levels %{
    "alert" => :alert,
    "critical" => :critical,
    "debug" => :debug,
    "emergency" => :emergency,
    "error" => :error,
    "info" => :info,
    "notice" => :notice,
    "warning" => :warning
  }
  @fixed "privacy-corpus"
  # The collector records each handled event's emission time; the corpus
  # keeps the field with a fixed value so its report is deterministic.
  @fixed_wall_time ~U[1970-01-01 00:00:00.000000Z]
  @inbox_size 1
  @counter_count 9

  # Collector status names for the bounded handler counters. Logger indexes
  # mirror `Insider.Collector.Logger.status_map/1`; Telemetry indexes mirror
  # `Insider.Collector.Telemetry.status_map/1`.
  @logger_counters %{
    4 => "invalid",
    7 => "payload",
    8 => "message_semantics",
    9 => "metadata"
  }
  @telemetry_counters %{
    4 => "invalid",
    7 => "handler_failures",
    8 => "measurements",
    9 => "metadata"
  }

  # Event fields populated from fixed collector configuration or sequencing,
  # never from corpus content. They are reported once, not per item.
  @envelope_fields [
    "authority",
    "boot_id",
    "clock_id",
    "extensions",
    "id",
    "monotonic_time",
    "node",
    "redactions",
    "schema",
    "source_instance_id",
    "source_sequence"
  ]

  @controls [
    "bounded_items_bytes_and_canary_tokens",
    "field_values_are_never_reported",
    "no_atoms_created_from_corpus",
    "projection_uses_collector_handler_code_paths",
    "unknown_item_shapes_fail_closed"
  ]
  @limitations [
    "charlist_and_integer_encoded_text_is_not_matched",
    "hashed_or_truncated_derivatives_are_not_matched",
    "json_corpora_cannot_express_pids_tuples_or_atoms",
    "recorder_classification_and_lifecycle_health_are_not_exercised",
    "retained_field_review_requires_human_judgment",
    "synthetic_corpus_does_not_prove_application_coverage"
  ]

  @type reason ::
          :invalid_options
          | :invalid_corpus
          | :corpus_limit_exceeded
          | :canary_token_unused
          | :telemetry_policy_required
          | :telemetry_policy_atom_missing
          | :invalid_telemetry_policy
          | :privacy_corpus_failed
          | {:invalid_item, non_neg_integer()}
          | {:item_limit_exceeded, non_neg_integer()}

  @doc """
  Projects every corpus item through the selected ingress profile.

  `corpus` is a map with the `insider.privacy-corpus/v1` shape: `"schema"`,
  `"canary_tokens"`, `"items"`, and optionally a `"telemetry_policy"` wire
  object. Options are `environment:` (any `IngressProfile` environment) and an
  optional `telemetry_policy:` struct, which may not be combined with an
  embedded wire policy.
  """
  @spec run(map(), keyword()) :: {:ok, map()} | {:error, reason()}
  def run(corpus, options) when is_map(corpus) and is_list(options) do
    with {:ok, environment, policy_option} <- options(options),
         {:ok, profile} <- profile(environment),
         {:ok, settings} <- logger_settings(profile),
         true <- exact_keys?(corpus, @corpus_keys, ["canary_tokens", "items", "schema"]),
         true <- corpus["schema"] == @corpus_schema,
         {:ok, canaries} <- canary_tokens(corpus["canary_tokens"]),
         {:ok, policy} <- resolve_policy(Map.get(corpus, "telemetry_policy"), policy_option),
         {:ok, items} <- items(corpus["items"], policy),
         :ok <- canaries_observed(corpus["items"], canaries) do
      projections = project(items, settings, policy)
      {:ok, report(corpus, profile, settings, policy, projections, canaries)}
    else
      false -> {:error, :invalid_corpus}
      {:error, _reason} = failure -> failure
    end
  rescue
    _error -> {:error, :privacy_corpus_failed}
  catch
    _kind, _reason -> {:error, :privacy_corpus_failed}
  end

  def run(_corpus, _options), do: {:error, :invalid_options}

  @doc """
  Builds a Telemetry policy from its JSON wire shape.

  Event-name segments, projection sources, and correlation sources resolve only
  to atoms that already exist in this VM; a missing atom fails closed.
  """
  @spec telemetry_policy(term()) ::
          {:ok, TelemetryPolicy.t()}
          | {:error, :invalid_telemetry_policy | :telemetry_policy_atom_missing}
  def telemetry_policy(wire) when is_map(wire) do
    with true <- exact_keys?(wire, @policy_keys, ["events", "id"]),
         {:ok, events} <- policy_events(wire["events"]),
         {:ok, metadata} <- policy_projection(Map.get(wire, "metadata", %{})),
         {:ok, measurements} <- policy_projection(Map.get(wire, "measurements", %{})),
         {:ok, correlation} <- policy_correlation(Map.get(wire, "correlation", %{})),
         {:ok, policy} <-
           TelemetryPolicy.new(
             id: wire["id"],
             events: events,
             metadata: metadata,
             measurements: measurements,
             correlation: correlation
           ) do
      {:ok, policy}
    else
      {:error, :telemetry_policy_atom_missing} = failure -> failure
      _failure -> {:error, :invalid_telemetry_policy}
    end
  rescue
    _error -> {:error, :invalid_telemetry_policy}
  end

  def telemetry_policy(_wire), do: {:error, :invalid_telemetry_policy}

  defp options(options) do
    with true <- Keyword.keyword?(options),
         keys = Keyword.keys(options),
         true <- keys == Enum.uniq(keys) and Enum.all?(keys, &(&1 in @option_keys)),
         environment when is_atom(environment) and not is_nil(environment) <-
           Keyword.get(options, :environment),
         policy = Keyword.get(options, :telemetry_policy),
         true <- is_nil(policy) or TelemetryPolicy.valid?(policy) do
      {:ok, environment, policy}
    else
      _failure -> {:error, :invalid_options}
    end
  end

  defp profile(environment) do
    case IngressProfile.new(environment) do
      {:ok, profile} -> {:ok, profile}
      {:error, _reason} -> {:error, :invalid_options}
    end
  end

  defp logger_settings(profile) do
    case LoggerCollector.profile_settings(profile) do
      {:ok, settings} -> {:ok, settings}
      {:error, _reason} -> {:error, :invalid_options}
    end
  end

  defp canary_tokens(tokens) when is_list(tokens) do
    cond do
      length(tokens) > @max_canary_tokens -> {:error, :corpus_limit_exceeded}
      Enum.uniq(tokens) != tokens -> {:error, :invalid_corpus}
      Enum.all?(tokens, &bounded_text?(&1, @max_canary_bytes)) -> {:ok, tokens}
      true -> {:error, :invalid_corpus}
    end
  end

  defp canary_tokens(_tokens), do: {:error, :invalid_corpus}

  defp resolve_policy(nil, nil), do: {:ok, nil}
  defp resolve_policy(nil, %TelemetryPolicy{} = policy), do: {:ok, policy}
  defp resolve_policy(wire, nil) when is_map(wire), do: telemetry_policy(wire)
  defp resolve_policy(_wire, _policy), do: {:error, :invalid_options}

  defp items(items, policy) when is_list(items) do
    if length(items) > @max_items do
      {:error, :corpus_limit_exceeded}
    else
      items
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, normalized} ->
        case item(item, index, policy) do
          {:ok, value} -> {:cont, {:ok, [{index, value} | normalized]}}
          {:error, _reason} = failure -> {:halt, failure}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        failure -> failure
      end
    end
  end

  defp items(_items, _policy), do: {:error, :invalid_corpus}

  defp item(item, index, policy) when is_map(item) and not is_struct(item) do
    cond do
      :erlang.external_size(item) > @max_item_bytes ->
        {:error, {:item_limit_exceeded, index}}

      item["source"] == "logger" ->
        logger_item(item, index)

      item["source"] == "telemetry" and is_nil(policy) ->
        {:error, :telemetry_policy_required}

      item["source"] == "telemetry" ->
        telemetry_item(item, index)

      true ->
        {:error, {:invalid_item, index}}
    end
  end

  defp item(_item, index, _policy), do: {:error, {:invalid_item, index}}

  defp logger_item(item, index) do
    with true <- exact_keys?(item, @logger_keys, @logger_required),
         {:ok, level} <- Map.fetch(@levels, item["level"]),
         {:ok, message} <- logger_message(item["message"]),
         {:ok, metadata} <- rekey(Map.get(item, "metadata", %{})) do
      {:ok, {:logger, %{level: level, msg: message, meta: metadata}}}
    else
      _failure -> {:error, {:invalid_item, index}}
    end
  end

  defp logger_message(%{"type" => "string", "value" => value} = message)
       when map_size(message) == 2 and is_binary(value),
       do: {:ok, {:string, value}}

  defp logger_message(%{"type" => "report", "report" => report} = message)
       when map_size(message) == 2 and is_map(report) do
    with {:ok, rekeyed} <- rekey(report), do: {:ok, {:report, rekeyed}}
  end

  defp logger_message(
         %{"type" => "format", "format" => format, "arguments" => arguments} = message
       )
       when map_size(message) == 3 and is_binary(format) and is_list(arguments),
       do: {:ok, {String.to_charlist(format), arguments}}

  # Elixir callers may pass native OTP message terms for full fidelity.
  defp logger_message({:string, _value} = message), do: {:ok, message}
  defp logger_message({:report, report} = message) when is_map(report), do: {:ok, message}

  defp logger_message({format, arguments} = message)
       when is_list(format) and is_list(arguments),
       do: {:ok, message}

  defp logger_message(_message), do: :error

  defp telemetry_item(item, index) do
    with true <- exact_keys?(item, @telemetry_keys, @telemetry_required),
         {:ok, event_name} <- event_name(item["event_name"]),
         {:ok, measurements} <- rekey(Map.get(item, "measurements", %{})),
         {:ok, metadata} <- rekey(Map.get(item, "metadata", %{})) do
      {:ok, {:telemetry, event_name, measurements, metadata}}
    else
      _failure -> {:error, {:invalid_item, index}}
    end
  end

  # A name whose segments all resolve to existing atoms can match a policy
  # rule; any other bounded name is passed through unchanged, and the handler
  # drops it exactly as it drops an unconfigured event.
  defp event_name(name)
       when is_list(name) and name != [] and length(name) <= @max_event_segments do
    cond do
      Enum.all?(name, &is_atom/1) ->
        {:ok, name}

      Enum.all?(name, &bounded_text?(&1, @max_atom_bytes)) ->
        case existing_atoms(name) do
          {:ok, atoms} -> {:ok, atoms}
          :error -> {:ok, name}
        end

      true ->
        :error
    end
  end

  defp event_name(_name), do: :error

  defp existing_atoms(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, atoms} ->
      case existing_atom(name) do
        {:ok, atom} -> {:cont, {:ok, [atom | atoms]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  # Handlers look up only atom keys they themselves reference, so a key is
  # renamed to its existing atom when one exists and otherwise left as text.
  # The outcome is identical either way; no atom is created.
  defp rekey(map) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, rekeyed} ->
      key = rekey_key(key)

      if Map.has_key?(rekeyed, key),
        do: {:halt, :error},
        else: {:cont, {:ok, Map.put(rekeyed, key, value)}}
    end)
  end

  defp rekey(_map), do: :error

  defp rekey_key(key) when is_binary(key) do
    case existing_atom(key) do
      {:ok, atom} -> atom
      :error -> key
    end
  end

  defp rekey_key(key), do: key

  defp existing_atom(value) when is_binary(value) and byte_size(value) <= 255 do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> :error
  end

  defp existing_atom(_value), do: :error

  # Every declared token must occur somewhere in the supplied items; otherwise
  # a run with no hits would be vacuous. Tokens are matched in binary keys and
  # values only, exactly as `hits/4` matches projected output, so a token that
  # occurs only as an atom, boolean, or number fails closed instead of passing
  # this gate and then being invisible in the output.
  defp canaries_observed(items, canaries) do
    observed = Enum.reduce(items, MapSet.new(), &tokens_in(&1, canaries, &2))

    if Enum.all?(canaries, &MapSet.member?(observed, &1)),
      do: :ok,
      else: {:error, :canary_token_unused}
  end

  defp tokens_in(value, canaries, observed) when is_binary(value) do
    Enum.reduce(canaries, observed, fn token, observed ->
      if String.contains?(value, token), do: MapSet.put(observed, token), else: observed
    end)
  end

  defp tokens_in(value, canaries, observed) when is_map(value) do
    Enum.reduce(value, observed, fn {key, item}, observed ->
      observed = tokens_in(key, canaries, observed)
      tokens_in(item, canaries, observed)
    end)
  end

  defp tokens_in(value, canaries, observed) when is_list(value),
    do: Enum.reduce(value, observed, &tokens_in(&1, canaries, &2))

  defp tokens_in(value, canaries, observed) when is_tuple(value),
    do: value |> Tuple.to_list() |> tokens_in(canaries, observed)

  defp tokens_in(_value, _canaries, observed), do: observed

  defp project(items, settings, policy) do
    logger = logger_config(settings)
    telemetry = telemetry_config(policy)

    try do
      Enum.map(items, fn
        {index, {:logger, log_event}} ->
          project_logger(index, log_event, logger)

        {index, {:telemetry, name, measurements, metadata}} ->
          project_telemetry(index, name, measurements, metadata, telemetry)
      end)
    after
      :ets.delete(logger.inbox)
      if telemetry, do: :ets.delete(telemetry.inbox)
    end
  end

  defp logger_config(settings) do
    %{
      authority: @fixed,
      boot_id: @fixed,
      clock_id: @fixed,
      include_payload: settings.include_payload,
      include_message_semantics: settings.include_message_semantics,
      structural_only: settings.structural_only,
      inbox: :ets.new(__MODULE__, [:set, :public]),
      inbox_size: @inbox_size,
      node: @fixed,
      sequence: :atomics.new(1, []),
      source_instance_id: @fixed <> "-logger",
      stats: :counters.new(@counter_count, [:atomics])
    }
  end

  defp telemetry_config(nil), do: nil

  defp telemetry_config(%TelemetryPolicy{} = policy) do
    %{
      correlation: policy.correlation,
      events: policy.events,
      measurements: policy.measurements,
      metadata: policy.metadata,
      policy_id: policy.id,
      inbox: :ets.new(__MODULE__, [:set, :public]),
      inbox_size: @inbox_size,
      sequence: :atomics.new(1, []),
      stats: :counters.new(@counter_count, [:atomics])
    }
  end

  defp project_logger(index, log_event, config) do
    before = counters(config.stats)
    :ok = LoggerHandler.log(log_event, %{config: config})
    suppressed = counter_deltas(before, counters(config.stats), @logger_counters)

    event =
      case take_inbox(config.inbox) do
        [%Event{} = event] -> {:ok, event}
        _rows -> :dropped
      end

    projection(index, "logger", event, suppressed)
  end

  defp project_telemetry(index, name, measurements, metadata, config) do
    before = counters(config.stats)
    :ok = TelemetryHandler.handle_event(name, measurements, metadata, config)
    suppressed = counter_deltas(before, counters(config.stats), @telemetry_counters)

    event =
      case take_inbox(config.inbox) do
        [{sequence, shape}] -> telemetry_event(shape, sequence)
        _rows -> :dropped
      end

    projection(index, "telemetry", event, suppressed)
  end

  defp take_inbox(inbox) do
    rows = :ets.tab2list(inbox)
    :ets.delete_all_objects(inbox)

    Enum.map(rows, fn
      {_slot, _sequence, %Event{} = event} -> event
      {_slot, sequence, shape} -> {sequence, shape}
    end)
  end

  # Mirrors the Event assembled by `Insider.Collector.Telemetry` from a handler
  # shape, with fixed values in every configuration-derived field.
  defp telemetry_event(shape, sequence) do
    Event.new(
      id: @fixed <> "-telemetry-" <> Integer.to_string(sequence, 36),
      node: @fixed,
      boot_id: @fixed,
      source: "telemetry",
      kind: shape.kind,
      severity: if(shape.phase == :exception or shape.error, do: :error, else: :info),
      monotonic_time: sequence,
      clock_id: @fixed,
      source_instance_id: @fixed <> "-telemetry",
      source_sequence: sequence,
      wall_time: if(Map.has_key?(shape, :wall_time_us), do: @fixed_wall_time),
      subject: %{
        "namespace" => "process",
        "scope" => @fixed,
        "value" => shape.emitter_pid
      },
      causality: shape.causality,
      attributes:
        put_omitted(
          %{
            "event_name" => shape.event_name,
            "lifecycle_phase" => Atom.to_string(shape.phase),
            "measurements" => shape.measurements,
            "metadata" => shape.metadata,
            "projection" => "telemetry.allowlist/v1"
          },
          Map.get(shape, :omitted)
        ),
      payload: nil,
      authority: @fixed,
      redactions: [],
      extensions: %{}
    )
    |> case do
      {:ok, event} -> {:ok, event}
      {:error, _error} -> :dropped
    end
  end

  # The collector's omission evidence: counts, the policy id, and only
  # nameable measurement names, so it is retained exactly as live retains it.
  defp put_omitted(attributes, nil), do: attributes
  defp put_omitted(attributes, omitted), do: Map.put(attributes, "omitted", omitted)

  defp projection(index, source, {:ok, %Event{} = event}, suppressed) do
    wire = Event.to_wire_map(event)

    %{
      index: index,
      source: source,
      disposition: "recorded",
      kind: event.kind,
      retained:
        wire |> Map.drop(@envelope_fields) |> leaf_paths(nil) |> Enum.uniq() |> Enum.sort(),
      suppressed: suppressed,
      wire: wire
    }
  end

  defp projection(index, source, :dropped, suppressed) do
    %{
      index: index,
      source: source,
      disposition: "dropped",
      kind: nil,
      retained: [],
      suppressed: suppressed,
      wire: %{}
    }
  end

  defp counters(stats), do: Enum.map(1..@counter_count, &:counters.get(stats, &1))

  defp counter_deltas(before, afterwards, names) do
    names
    |> Enum.sort()
    |> Map.new(fn {position, name} ->
      {name, Enum.at(afterwards, position - 1) - Enum.at(before, position - 1)}
    end)
  end

  # A list shares its parent's path; maps nested inside a list extend it, so
  # every canary hit coordinate is also a reported retained path or its prefix.
  defp leaf_paths(value, prefix) when is_map(value) do
    Enum.flat_map(value, fn {key, item} -> leaf_paths(item, path(prefix, key)) end)
  end

  defp leaf_paths(value, prefix) when is_list(value),
    do: value |> Enum.flat_map(&leaf_paths(&1, prefix)) |> Enum.uniq()

  defp leaf_paths(nil, _prefix), do: []
  defp leaf_paths(_value, nil), do: []
  defp leaf_paths(_value, prefix), do: [prefix]

  defp path(nil, key), do: path_key(key)
  defp path(prefix, key), do: prefix <> "." <> path_key(key)

  defp path_key(key) when is_binary(key), do: key
  defp path_key(key) when is_atom(key), do: Atom.to_string(key)
  defp path_key(_key), do: "$other_key"

  defp canary_hits(projections, canaries) do
    projections
    |> Enum.flat_map(fn projection ->
      projection.wire
      |> hits(nil, canaries, [])
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&%{"index" => projection.index, "field" => &1})
    end)
  end

  defp hits(value, prefix, canaries, found) when is_map(value) do
    Enum.reduce(value, found, fn {key, item}, found ->
      key_path = path(prefix, key)

      found =
        if is_binary(key) and contains_canary?(key, canaries), do: [key_path | found], else: found

      hits(item, key_path, canaries, found)
    end)
  end

  defp hits(value, prefix, canaries, found) when is_list(value),
    do: Enum.reduce(value, found, &hits(&1, prefix, canaries, &2))

  defp hits(value, prefix, canaries, found) when is_binary(value) and is_binary(prefix) do
    if contains_canary?(value, canaries), do: [prefix | found], else: found
  end

  defp hits(_value, _prefix, _canaries, found), do: found

  defp contains_canary?(text, canaries), do: Enum.any?(canaries, &String.contains?(text, &1))

  defp report(corpus, profile, settings, policy, projections, canaries) do
    hits = canary_hits(projections, canaries)

    %{
      "schema" => @schema,
      "classification" => "privacy_corpus_report",
      "status" => if(hits == [], do: "no_canary_hits", else: "canary_hits"),
      "environment" => Atom.to_string(profile.environment),
      "ingress_profile_fingerprint" => profile.fingerprint,
      "logger_settings" => %{
        "include_message_semantics" => settings.include_message_semantics,
        "include_payload" => settings.include_payload,
        "structural_only" => settings.structural_only
      },
      "telemetry_policy" => policy_reference(policy),
      "corpus_fingerprint" => fingerprint(corpus),
      "item_count" => length(projections),
      "canary_token_count" => length(canaries),
      "canary_hit_count" => length(hits),
      "canary_hits" => hits,
      "items" => Enum.map(projections, &item_report/1),
      "retained_fields_union" =>
        projections |> Enum.flat_map(& &1.retained) |> Enum.uniq() |> Enum.sort(),
      "suppressed_totals" => %{
        "logger" => totals(projections, "logger", @logger_counters),
        "telemetry" => totals(projections, "telemetry", @telemetry_counters)
      },
      "envelope_fields" => @envelope_fields,
      "bounds" => %{
        "max_canary_token_bytes" => @max_canary_bytes,
        "max_canary_tokens" => @max_canary_tokens,
        "max_item_bytes" => @max_item_bytes,
        "max_items" => @max_items
      },
      "controls" => @controls,
      "limitations" => @limitations
    }
  end

  defp item_report(projection) do
    %{
      "index" => projection.index,
      "source" => projection.source,
      "disposition" => projection.disposition,
      "kind" => projection.kind,
      "retained_fields" => projection.retained,
      "suppressed" => projection.suppressed
    }
  end

  defp totals(projections, source, names) do
    names
    |> Map.values()
    |> Map.new(fn name ->
      total =
        projections
        |> Enum.filter(&(&1.source == source))
        |> Enum.reduce(0, &(&2 + Map.fetch!(&1.suppressed, name)))

      {name, total}
    end)
  end

  defp policy_reference(nil), do: nil

  defp policy_reference(%TelemetryPolicy{} = policy),
    do: %{"id" => policy.id, "fingerprint" => policy.fingerprint}

  defp policy_events(events) when is_list(events) and events != [] do
    Enum.reduce_while(events, {:ok, []}, fn rule, {:ok, rules} ->
      case policy_event(rule) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | rules]}}
        failure -> {:halt, failure}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      failure -> failure
    end
  end

  defp policy_events(_events), do: :error

  defp policy_event(rule) when is_map(rule) do
    with true <- exact_keys?(rule, @event_rule_keys, @event_rule_keys),
         {:ok, phase} <- Map.fetch(@phases, rule["phase"]),
         {:ok, name} <- policy_atoms(rule["name"]) do
      {:ok, [name: name, kind: rule["kind"], lifecycle: rule["lifecycle"], phase: phase]}
    else
      {:error, _reason} = failure -> failure
      _failure -> :error
    end
  end

  defp policy_event(_rule), do: :error

  defp policy_atoms(names) when is_list(names) and names != [] do
    if Enum.all?(names, &bounded_text?(&1, @max_atom_bytes)) do
      case existing_atoms(names) do
        {:ok, atoms} -> {:ok, atoms}
        :error -> {:error, :telemetry_policy_atom_missing}
      end
    else
      :error
    end
  end

  defp policy_atoms(_names), do: :error

  defp policy_projection(projection) when is_map(projection) do
    projection
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn
      {source, output}, {:ok, entries} when is_binary(output) ->
        case policy_atoms([source]) do
          {:ok, [atom]} -> {:cont, {:ok, [{atom, output} | entries]}}
          failure -> {:halt, failure}
        end

      _entry, _accumulated ->
        {:halt, :error}
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      failure -> failure
    end
  end

  defp policy_projection(_projection), do: :error

  defp policy_correlation(correlation) when is_map(correlation) do
    correlation
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {target, source}, {:ok, entries} ->
      with {:ok, target_atom} <- Map.fetch(@correlation_targets, target),
           {:ok, [source_atom]} <- policy_atoms([source]) do
        {:cont, {:ok, [{target_atom, source_atom} | entries]}}
      else
        {:error, _reason} = failure -> {:halt, failure}
        _failure -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      failure -> failure
    end
  end

  defp policy_correlation(_correlation), do: :error

  defp exact_keys?(map, allowed, required) when is_map(map) and not is_struct(map) do
    keys = Map.keys(map)
    Enum.all?(keys, &(&1 in allowed)) and Enum.all?(required, &(&1 in keys))
  end

  defp exact_keys?(_map, _allowed, _required), do: false

  defp bounded_text?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp fingerprint(value) do
    digest =
      value
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "sha256:" <> digest
  end
end

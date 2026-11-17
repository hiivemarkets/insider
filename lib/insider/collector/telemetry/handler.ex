defmodule Insider.Collector.Telemetry.Handler do
  @moduledoc false

  alias Insider.Collector.Gate
  alias Insider.Collector.Rich
  alias Insider.Collector.Telemetry.Omitted
  alias Insider.Collector.GraphqlClient
  alias Insider.Collector.GraphqlOutcome
  alias Insider.Collector.ObanJob
  alias Insider.Collector.RequestTiming
  alias Insider.Collector.Telemetry.Outcome

  @max_scalar_bytes 256
  @minimum_integer -9_223_372_036_854_775_808
  @maximum_integer 9_223_372_036_854_775_807

  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event(event_name, measurements, metadata, config) do
    # The record-time gate decides first; a dropped or summarised event costs
    # nothing more.
    case Gate.telemetry(Map.get(config, :gate), event_name, measurements, metadata) do
      :record -> admit(event_name, measurements, metadata, config)
      :drop -> :ok
      {:exemplar, exemplar} -> candidate(event_name, measurements, metadata, config, exemplar)
    end

    :ok
  rescue
    _error -> safe_failure(config)
  catch
    _kind, _reason -> safe_failure(config)
  end

  defp admit(event_name, measurements, metadata, config) do
    bump(config.stats, 1)
    sequence = :atomics.add_get(config.sequence, 1, 1)

    case normalize(event_name, measurements, metadata, config) do
      {:ok, shape} -> enqueue(config, sequence, shape)
      :error -> bump(config.stats, 4)
    end
  end

  @doc """
  Hands a summarised event that may become one of its summary's exemplars
  to the collector, as the emitting process does after the gate's decision.
  It goes like a recorded one, marked, with the context it was emitted in.
  It is already counted as summarised, so it touches no received,
  enqueued, or shed counter: the collector decides whether it is recorded.

  The interval's first error has a slot of its own per kind and interval,
  so a full inbox never costs it. Any other candidate that finds its inbox
  slot taken, or one that cannot be normalised, is lost and counted: in the
  collector's status, in its interval's summary, and in the gate.
  """
  @spec candidate([atom()], map(), map(), map(), Insider.Collector.Summary.exemplar()) :: :ok
  def candidate(
        event_name,
        measurements,
        metadata,
        config,
        {generation, _d, first_error?} = exemplar
      ) do
    sequence = :atomics.add_get(config.sequence, 1, 1)

    case normalize(event_name, measurements, metadata, config) do
      {:ok, shape} ->
        shape = Map.merge(shape, %{exemplar: exemplar, emitter: emitter()})

        slot =
          if first_error?,
            do: {:first_error, shape.kind, generation},
            else: rem(sequence - 1, config.inbox_size)

        if not :ets.insert_new(config.inbox, {slot, sequence, shape}),
          do: lose(event_name, config, exemplar, 11)

      :error ->
        lose(event_name, config, exemplar, 12)
    end

    :ok
  end

  defp lose(event_name, config, exemplar, counter) do
    bump(config.stats, counter)
    _counted = Gate.telemetry_exemplar_lost(Map.get(config, :gate), event_name, exemplar)
    :ok
  end

  # The context the event was emitted in, read only for candidates. A
  # process started by `:proc_lib` for a behaviour (a GenServer,
  # `:gen_statem`, or `:gen_event` server) has its callback module's
  # `init/1` as its initial call. That says where the event was emitted,
  # not what its duration measured: a server that calls another server
  # measures its own wait as a caller.
  defp emitter do
    case Process.get(:"$initial_call") do
      {module, :init, 1} when is_atom(module) -> {:otp_server, module}
      _other -> :process
    end
  end

  defp normalize(event_name, measurements, metadata, config)
       when is_list(event_name) and is_map(measurements) and is_map(metadata) do
    with {:ok, rule} <- Map.fetch(config.events, List.to_tuple(event_name)) do
      {:ok,
       Map.merge(
         %{
           kind: rule.kind,
           phase: rule.phase,
           lifecycle: rule.lifecycle,
           event_name: Enum.map(rule.name, &Atom.to_string/1),
           emitter_pid: self() |> :erlang.pid_to_list() |> to_string(),
           # The event's wall time is when it was emitted, not when the
           # collector drained it.
           wall_time_us: System.os_time(:microsecond),
           error: Outcome.error?(rule.name, metadata),
           graphql:
             if(GraphqlOutcome.event?(rule.name),
               do: metadata |> GraphqlOutcome.from_metadata() |> put_client(config)
             ),
           oban: if(ObanJob.event?(rule.name), do: ObanJob.attributes(metadata)),
           request:
             if(RequestTiming.event?(rule.name),
               do:
                 RequestTiming.from(
                   rule.name,
                   measurements,
                   metadata,
                   request_collection(config)
                 )
             )
         },
         content(rule, measurements, metadata, config)
       )}
    else
      _failure -> :error
    end
  end

  defp normalize(_event_name, _measurements, _metadata, _config), do: :error

  # An Oban job's `term-` args, kept for decoding when read
  # (`Insider.Collector.ObanJob`).
  defp put_oban_terms(payload, nil), do: payload
  defp put_oban_terms(payload, terms), do: Map.put(payload, "oban_terms", terms)

  # Rich capture names the client of the request the operation ran in.
  defp put_client(%{} = outcome, %{rich: true} = config) do
    case GraphqlClient.current(Map.get(config, :client_generation)) do
      nil -> outcome
      client -> Map.put(outcome, "client", client)
    end
  end

  defp put_client(outcome, _config), do: outcome

  # Request timings are the `duration` measurement's: collected when it is
  # selected, or when rich collection takes every measurement.
  defp request_collection(config) do
    rich? = Map.get(config, :rich, false)
    selection = config.measurements

    %{
      rich: rich?,
      timed: is_map_key(selection, :duration) or (rich? and map_size(selection) == 0)
    }
  end

  # Each content clause works out the exact number of withheld measurements
  # and metadata keys for the event's omission evidence
  # (`Insider.Collector.Telemetry.Omitted`), and adds at most 256 per event
  # to the status counters, which are bounded evidence, not a manifest.
  defp content(%{failure_event: true}, measurements, metadata, config) do
    withheld_measurements = map_size(measurements)
    withheld_metadata = failure_withheld_count(metadata)
    count_suppressed(config, withheld_measurements, withheld_metadata)
    names = withheld_names(measurements, config, fn _key -> true end)

    projected(empty_causality(), %{}, failure_metadata(metadata))
    |> Map.put(:omitted, omitted(names, withheld_measurements, withheld_metadata, config))
  end

  # Rich capture keeps every metadata key in the payload and every
  # measurement, or only the selected ones; unselected ones are suppressed.
  defp content(rule, measurements, metadata, %{rich: true} = config) do
    {withheld, names} =
      if map_size(config.measurements) > 0 do
        selected = Enum.count(config.measurements, &is_map_key(measurements, elem(&1, 0)))
        unselected? = &(not is_map_key(config.measurements, &1))
        {map_size(measurements) - selected, withheld_names(measurements, config, unselected?)}
      else
        {0, []}
      end

    count_suppressed(config, withheld, 0)

    %{
      causality: causality(metadata, config.correlation),
      measurements: Rich.measurements(measurements, config.measurements),
      metadata: %{},
      payload:
        cond do
          GraphqlOutcome.event?(rule.name) ->
            Rich.graphql_payload(metadata)

          ObanJob.event?(rule.name) ->
            metadata
            |> Rich.telemetry_payload()
            |> put_oban_terms(ObanJob.terms(metadata))

          true ->
            Rich.telemetry_payload(metadata)
        end,
      projection: "telemetry.rich/v1",
      omitted: omitted(names, withheld, 0, config)
    }
  end

  defp content(_rule, measurements, metadata, config) do
    withheld_measurements = withheld_count(measurements, config.measurements, %{})
    withheld_metadata = withheld_count(metadata, config.metadata, config.correlation)
    count_suppressed(config, withheld_measurements, withheld_metadata)

    names =
      if withheld_measurements > 0,
        do:
          withheld_names(measurements, config, fn key ->
            not admitted?(Map.fetch!(measurements, key), key, config.measurements, %{})
          end),
        else: []

    projected(
      causality(metadata, config.correlation),
      project(measurements, config.measurements),
      project(metadata, config.metadata)
    )
    |> Map.put(:omitted, omitted(names, withheld_measurements, withheld_metadata, config))
  end

  defp count_suppressed(config, measurements, metadata) do
    bump(config.stats, 8, min(measurements, 256))
    bump(config.stats, 9, min(metadata, 256))
  end

  defp projected(causality, measurements, metadata) do
    %{
      causality: causality,
      measurements: measurements,
      metadata: metadata,
      payload: nil,
      projection: "telemetry.allowlist/v1"
    }
  end

  @doc """
  Prepares the nameable measurements for the handler configuration, once,
  when the collector starts: each atom with its name, sorted by name. The
  emitting process then only folds over this list of at most 16 entries.
  """
  @spec nameable([atom()]) :: %{nameable_measurements: [{atom(), String.t()}]}
  def nameable(names),
    do: %{
      nameable_measurements:
        names |> Enum.map(&{&1, Atom.to_string(&1)}) |> Enum.sort_by(&elem(&1, 1))
    }

  defp omitted(names, measurements, metadata, config),
    do: Omitted.new(config.policy_id, measurements, names, metadata)

  # One bounded fold over the configured vocabulary, in its sorted order.
  defp withheld_names(measurements, config, withheld?) do
    for {key, name} <- Map.get(config, :nameable_measurements, []),
        is_map_key(measurements, key),
        withheld?.(key),
        do: name
  end

  # The policy's correlation keys win. Without one, the trace and span ids
  # are the OpenTelemetry context of the emitting process: the SDK keeps the
  # active span's ids in the process's Logger metadata (`otel_trace_id`,
  # `otel_span_id`), so an event joins the trace it was emitted in.
  defp causality(metadata, configured) do
    process = otel_context(configured)

    %{
      trace_id: correlation(metadata, configured, :trace_id) || process[:trace_id],
      span_id: correlation(metadata, configured, :span_id) || process[:span_id],
      parent_event_id: correlation(metadata, configured, :parent_event_id),
      logical_operation_id: correlation(metadata, configured, :logical_operation_id),
      process_generation: correlation(metadata, configured, :process_generation)
    }
  end

  defp otel_context(configured) when is_map_key(configured, :trace_id), do: %{}

  defp otel_context(_configured) do
    case :logger.get_process_metadata() do
      %{otel_trace_id: trace_id, otel_span_id: span_id} ->
        %{
          trace_id: correlation_value(:trace_id, trace_id),
          span_id: correlation_value(:span_id, span_id)
        }

      _none ->
        %{}
    end
  end

  defp empty_causality do
    %{
      trace_id: nil,
      span_id: nil,
      parent_event_id: nil,
      logical_operation_id: nil,
      process_generation: nil
    }
  end

  defp failure_metadata(%{kind: kind}) when kind in [:error, :exit, :throw],
    do: %{"failure_kind" => Atom.to_string(kind)}

  defp failure_metadata(_metadata), do: %{}

  defp correlation(metadata, configured, target) do
    case Map.fetch(configured, target) do
      {:ok, source} -> correlation_value(target, Map.get(metadata, source))
      :error -> nil
    end
  end

  defp correlation_value(:trace_id, value) when is_binary(value) and byte_size(value) == 16 do
    if nonzero?(value), do: Base.encode16(value, case: :lower), else: nil
  end

  defp correlation_value(:span_id, value) when is_binary(value) and byte_size(value) == 8 do
    if nonzero?(value), do: Base.encode16(value, case: :lower), else: nil
  end

  defp correlation_value(:trace_id, value) when is_binary(value) and byte_size(value) == 32 do
    if lower_hex?(value) and nonzero_hex?(value), do: :binary.copy(value), else: nil
  end

  defp correlation_value(:span_id, value) when is_binary(value) and byte_size(value) == 16 do
    if lower_hex?(value) and nonzero_hex?(value), do: :binary.copy(value), else: nil
  end

  defp correlation_value(target, value)
       when target not in [:trace_id, :span_id] and
              is_binary(value) and byte_size(value) in 1..128 do
    if String.valid?(value), do: :binary.copy(value), else: nil
  end

  defp correlation_value(target, value)
       when target not in [:trace_id, :span_id] and is_integer(value) and
              value in 0..@maximum_integer,
       do: Integer.to_string(value)

  defp correlation_value(_target, _value), do: nil

  defp project(values, projection) do
    Enum.reduce(projection, %{}, fn {source, output}, result ->
      case scalar(Map.get(values, source)) do
        {:ok, value} -> Map.put(result, output, value)
        :error -> result
      end
    end)
  end

  defp scalar(nil), do: {:ok, nil}
  defp scalar(value) when is_boolean(value), do: {:ok, value}

  defp scalar(value) when is_integer(value) and value in @minimum_integer..@maximum_integer,
    do: {:ok, value}

  defp scalar(value) when is_float(value) do
    encoded = :erlang.float_to_binary(value, [:short])
    if byte_size(encoded) <= @max_scalar_bytes, do: {:ok, encoded}, else: :error
  rescue
    _error -> :error
  end

  defp scalar(value) when is_atom(value) do
    value |> Atom.to_string() |> bounded_scalar()
  end

  defp scalar(value) when is_binary(value), do: bounded_scalar(value)
  defp scalar(_value), do: :error

  defp bounded_scalar(value) when byte_size(value) <= @max_scalar_bytes do
    if String.valid?(value), do: {:ok, :binary.copy(value)}, else: :error
  end

  defp bounded_scalar(_value), do: :error

  defp enqueue(config, sequence, shape) do
    slot = rem(sequence - 1, config.inbox_size)

    if :ets.insert_new(config.inbox, {slot, sequence, shape}) do
      bump(config.stats, 2)
    else
      bump(config.stats, 3)
    end
  end

  defp safe_failure(%{stats: stats}) do
    bump(stats, 7)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp safe_failure(_config), do: :ok
  defp nonzero?(value), do: value != :binary.copy(<<0>>, byte_size(value))

  defp nonzero_hex?(value), do: value != :binary.copy("0", byte_size(value))

  defp lower_hex?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte in ?0..?9 or byte in ?a..?f end)
  end

  # The exact number withheld, read from the map size and the configured
  # sources only; an unknown key or value is never retained.
  # A configured field counts as admitted only if its scalar/correlation value
  # actually survives projection; malformed configured values are visible drops.
  defp withheld_count(values, projection, correlation) do
    sources = (Map.keys(projection) ++ Map.values(correlation)) |> Enum.uniq()

    admitted =
      Enum.count(sources, fn source ->
        Map.has_key?(values, source) and
          admitted?(Map.fetch!(values, source), source, projection, correlation)
      end)

    max(map_size(values) - admitted, 0)
  end

  defp admitted?(value, source, projection, correlation) do
    projected? = Map.has_key?(projection, source) and match?({:ok, _value}, scalar(value))

    correlated? =
      Enum.any?(correlation, fn {target, configured_source} ->
        configured_source == source and not is_nil(correlation_value(target, value))
      end)

    projected? or correlated?
  end

  defp failure_withheld_count(metadata) do
    admitted =
      if match?(%{kind: kind} when kind in [:error, :exit, :throw], metadata), do: 1, else: 0

    max(map_size(metadata) - admitted, 0)
  end

  defp bump(stats, index), do: :counters.add(stats, index, 1)
  defp bump(_stats, _index, 0), do: :ok
  defp bump(stats, index, amount), do: :counters.add(stats, index, amount)
end

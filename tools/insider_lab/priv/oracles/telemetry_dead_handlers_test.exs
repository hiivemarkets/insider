defmodule InsiderLab.TelemetryDeadHandlersOracleArtifact do
  @moduledoc false

  @event_variable "INSIDER_ORACLE_TELEMETRY_EVENT"
  @context_variable "INSIDER_ORACLE_CONTEXT"
  @maximum_event_bytes 2_048
  @maximum_segments 16
  @maximum_segment_bytes 255
  @maximum_context_bytes 1_024
  @maximum_handlers 1_024
  @capture_timeout_ms 1_000
  @capture_heap_words 262_144
  @prefix "INSIDER_TELEMETRY_DEAD_HANDLERS_ORACLE="
  @schema "insider.telemetry-dead-handlers-oracle/v1"

  def install do
    case bounded_context() do
      {:ok, context} -> install(context)
      {:error, reason} -> emit(operational_failure(reason, nil))
    end
  end

  defp install(context) do
    case bounded_event() do
      {:ok, event_names} -> install_after_suite(event_names, context)
      {:error, reason} -> emit(operational_failure(reason, context))
    end
  end

  @doc false
  def validate_context_input(encoded) when is_binary(encoded) do
    if byte_size(encoded) in 1..@maximum_context_bytes and String.valid?(encoded) and
         String.printable?(encoded) and
         not Enum.any?(String.to_charlist(encoded), &(&1 < 0x20 or &1 == 0x7F)) do
      {:ok, encoded}
    else
      {:error, "invalid_context"}
    end
  end

  def validate_context_input(_encoded), do: {:error, "invalid_context"}

  @doc false
  def validate_event_input(encoded) when is_binary(encoded) do
    with true <- byte_size(encoded) in 1..@maximum_event_bytes,
         true <- String.valid?(encoded),
         segments <- String.split(encoded, ",", trim: false),
         true <- length(segments) in 1..@maximum_segments,
         true <- Enum.all?(segments, &(byte_size(&1) in 1..@maximum_segment_bytes)) do
      {:ok, segments}
    else
      _error -> {:error, "invalid_event_name"}
    end
  end

  def validate_event_input(_encoded), do: {:error, "invalid_event_name"}

  defp bounded_context do
    case System.fetch_env(@context_variable) do
      {:ok, encoded} -> validate_context_input(encoded)
      :error -> {:ok, nil}
    end
  end

  defp bounded_event do
    case System.fetch_env(@event_variable) do
      {:ok, encoded} -> validate_event_input(encoded)
      :error -> {:error, "invalid_event_name"}
    end
  end

  defp install_after_suite(event_names, context) do
    initial = capture(event_names)

    ExUnit.after_suite(fn _result ->
      final = capture(event_names)
      emit(comparison(event_names, initial, final, context))
    end)
  end

  defp capture(event_names) do
    case existing_event(event_names) do
      {:ok, event} -> bounded_capture(event)
      :not_loaded -> %{observed: true, count: 0, truncated: false, reason: nil}
    end
  end

  defp existing_event(event_names) do
    Enum.reduce_while(event_names, {:ok, []}, fn name, {:ok, event} ->
      try do
        {:cont, {:ok, [String.to_existing_atom(name) | event]}}
      rescue
        ArgumentError -> {:halt, :not_loaded}
      end
    end)
    |> case do
      {:ok, event} -> {:ok, Enum.reverse(event)}
      :not_loaded -> :not_loaded
    end
  end

  defp bounded_capture(event) do
    parent = self()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn -> send(parent, {self(), capture_handlers(event)}) end,
        [
          :monitor,
          {:max_heap_size, %{size: @capture_heap_words, kill: true, error_logger: false}}
        ]
      )

    receive do
      {^pid, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        unobserved("capture_failed")
    after
      @capture_timeout_ms ->
        Process.exit(pid, :kill)
        await_down(monitor, pid)
        unobserved("capture_timeout")
    end
  end

  defp capture_handlers(event) do
    handlers = :telemetry.list_handlers(event)

    if length(handlers) <= @maximum_handlers do
      count =
        Enum.count(handlers, fn handler ->
          handler[:event_name] == event and dead_telemetry_test_handler?(handler)
        end)

      %{observed: true, count: count, truncated: false, reason: nil}
    else
      %{observed: false, count: nil, truncated: true, reason: "handler_limit_exceeded"}
    end
  rescue
    _error -> unobserved("capture_failed")
  catch
    _kind, _reason -> unobserved("capture_failed")
  end

  defp dead_telemetry_test_handler?(%{
         function: function,
         config: %{dest_pid: destination}
       })
       when is_function(function, 4) and is_pid(destination) do
    function_identity(function) == {:telemetry_test, :handle_event, 4} and
      not Process.alive?(destination)
  end

  defp dead_telemetry_test_handler?(_handler), do: false

  defp function_identity(function) do
    with {:module, module} <- Function.info(function, :module),
         {:name, name} <- Function.info(function, :name),
         {:arity, arity} <- Function.info(function, :arity) do
      {module, name, arity}
    else
      _unknown -> :unknown
    end
  end

  defp await_down(monitor, pid) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      @capture_timeout_ms -> Process.demonitor(monitor, [:flush])
    end
  end

  defp comparison(event_names, initial, final, context) do
    delta = delta(initial, final)

    base(event_names, context)
    |> Map.merge(%{
      "status" => status(delta),
      "initial_dead_handler_count" => nullable(initial.count),
      "final_dead_handler_count" => nullable(final.count),
      "delta" => nullable(delta),
      "initial_observed" => initial.observed,
      "final_observed" => final.observed,
      "initial_truncated" => initial.truncated,
      "final_truncated" => final.truncated,
      "initial_reason" => nullable(initial.reason),
      "final_reason" => nullable(final.reason)
    })
  end

  defp delta(%{observed: true, count: initial}, %{observed: true, count: final}),
    do: final - initial

  defp delta(_initial, _final), do: nil

  defp status(delta) when is_integer(delta) and delta > 0, do: "increased"
  defp status(0), do: "unchanged"
  defp status(delta) when is_integer(delta) and delta < 0, do: "decreased"
  defp status(nil), do: "inconclusive"

  defp unobserved(reason),
    do: %{observed: false, count: nil, truncated: false, reason: reason}

  defp nullable(nil), do: :null
  defp nullable(value), do: value

  defp operational_failure(reason, context),
    do:
      limits()
      |> Map.merge(%{
        "schema" => @schema,
        "status" => "operational_failure",
        "reason" => reason,
        "context" => nullable(context),
        "limitations" => limitations()
      })

  defp base(event_names, context),
    do:
      limits()
      |> Map.merge(%{
        "schema" => @schema,
        "event" => event_names,
        "context" => nullable(context),
        "limitations" => limitations()
      })

  defp limits,
    do: %{
      "event_byte_limit" => @maximum_event_bytes,
      "event_segment_limit" => @maximum_segments,
      "event_segment_byte_limit" => @maximum_segment_bytes,
      "context_byte_limit" => @maximum_context_bytes,
      "handler_limit" => @maximum_handlers,
      "capture_timeout_ms" => @capture_timeout_ms,
      "capture_heap_words" => @capture_heap_words
    }

  defp limitations,
    do: [
      "caller_must_bind_test_and_revision",
      "context_is_caller_supplied_and_unverified",
      "only_telemetry_test_dead_destinations_are_counted",
      "prefix_lookup_descendants_affect_bounds",
      "handler_snapshot_is_not_atomic",
      "count_change_does_not_establish_causality"
    ]

  defp emit(report), do: IO.puts([@prefix, :json.encode(report)])
end

InsiderLab.TelemetryDeadHandlersOracleArtifact.install()

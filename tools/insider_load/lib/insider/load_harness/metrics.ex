defmodule Insider.LoadHarness.Metrics do
  @moduledoc """
  Bounded scalar-only host/runtime measurements for the load harness.

  `snapshot/0` captures cumulative VM counters and current resource gauges.
  `delta/2` converts two snapshots into interval measurements. Scheduler wall
  time is observed only when the host has already enabled it; this module does
  not mutate that node-global VM setting.
  """

  @maximum_scalar 9_007_199_254_740_991
  @measurement_keys [
    "wall_time_us",
    "cpu_time_us",
    "reductions",
    "context_switches",
    "garbage_collections",
    "garbage_words_reclaimed",
    "memory_bytes",
    "process_count",
    "port_count",
    "ets_count",
    "scheduler_utilization_permyriad"
  ]
  @report_keys [
    "cpu_time_us",
    "garbage_collections",
    "garbage_words_reclaimed",
    "memory_bytes",
    "port_count",
    "process_count",
    "scheduler_utilization_permyriad"
  ]
  @counter_keys [
    "wall_time_us",
    "cpu_time_us",
    "reductions",
    "context_switches",
    "garbage_collections",
    "garbage_words_reclaimed"
  ]

  @enforce_keys [:values, :available]
  defstruct [:values, :available]

  @opaque t :: %__MODULE__{
            values: %{required(String.t()) => non_neg_integer()},
            available: %{required(String.t()) => boolean()}
          }

  @type measurement :: %{
          required(:values) => %{required(String.t()) => non_neg_integer()},
          required(:available) => %{required(String.t()) => boolean()}
        }

  @spec snapshot() :: t()
  def snapshot do
    {wall_time_us, wall_available?} = statistic_total(:wall_clock, 1_000)
    {cpu_time_us, cpu_available?} = statistic_total(:runtime, 1_000)
    {reductions, reductions_available?} = statistic_total(:reductions, 1)
    {context_switches, context_switches_available?} = statistic_total(:context_switches, 1)
    {collections, reclaimed, garbage_available?} = garbage_collection()
    {scheduler_active, scheduler_total, scheduler_available?} = scheduler_wall_time()

    {memory_bytes, memory_available?} = runtime_value(fn -> :erlang.memory(:total) end)

    {process_count, process_available?} =
      runtime_value(fn -> :erlang.system_info(:process_count) end)

    {port_count, port_available?} = runtime_value(fn -> :erlang.system_info(:port_count) end)
    {ets_count, ets_available?} = runtime_value(fn -> :erlang.system_info(:ets_count) end)

    %__MODULE__{
      values: %{
        "wall_time_us" => wall_time_us,
        "cpu_time_us" => cpu_time_us,
        "reductions" => reductions,
        "context_switches" => context_switches,
        "garbage_collections" => collections,
        "garbage_words_reclaimed" => reclaimed,
        "memory_bytes" => memory_bytes,
        "process_count" => process_count,
        "port_count" => port_count,
        "ets_count" => ets_count,
        "scheduler_active" => scheduler_active,
        "scheduler_total" => scheduler_total
      },
      available: %{
        "wall_time_us" => wall_available?,
        "cpu_time_us" => cpu_available?,
        "reductions" => reductions_available?,
        "context_switches" => context_switches_available?,
        "garbage_collections" => garbage_available?,
        "garbage_words_reclaimed" => garbage_available?,
        "memory_bytes" => memory_available?,
        "process_count" => process_available?,
        "port_count" => port_available?,
        "ets_count" => ets_available?,
        "scheduler_utilization_permyriad" => scheduler_available?
      }
    }
  end

  @spec delta(t(), t()) :: measurement()
  def delta(%__MODULE__{} = earlier, %__MODULE__{} = later) do
    available = availability_delta(earlier, later)

    values = %{
      "wall_time_us" => counter_delta(earlier, later, "wall_time_us"),
      "cpu_time_us" => counter_delta(earlier, later, "cpu_time_us"),
      "reductions" => counter_delta(earlier, later, "reductions"),
      "context_switches" => counter_delta(earlier, later, "context_switches"),
      "garbage_collections" => counter_delta(earlier, later, "garbage_collections"),
      "garbage_words_reclaimed" => counter_delta(earlier, later, "garbage_words_reclaimed"),
      "memory_bytes" => gauge(later, "memory_bytes", available),
      "process_count" => gauge(later, "process_count", available),
      "port_count" => gauge(later, "port_count", available),
      "ets_count" => gauge(later, "ets_count", available),
      "scheduler_utilization_permyriad" => scheduler_utilization(earlier, later, available)
    }

    %{values: values, available: available}
  end

  @doc "Projects an interval measurement to the exact runtime keys accepted by Report."
  @spec report_runtime(measurement()) :: %{required(String.t()) => non_neg_integer()}
  def report_runtime(%{values: values, available: available}) do
    Map.new(@report_keys, fn key ->
      value = if available[key], do: Map.fetch!(values, key), else: 0
      {key, value}
    end)
  end

  @spec measurement_keys() :: [String.t()]
  def measurement_keys, do: @measurement_keys

  defp availability_delta(earlier, later) do
    availability =
      Map.new(@measurement_keys, fn key ->
        {key, earlier.available[key] == true and later.available[key] == true}
      end)

    availability =
      Enum.reduce(@counter_keys, availability, fn key, acc ->
        monotonic? = later.values[key] >= earlier.values[key]
        Map.update!(acc, key, &(&1 and monotonic?))
      end)

    scheduler_monotonic? =
      later.values["scheduler_active"] >= earlier.values["scheduler_active"] and
        later.values["scheduler_total"] > earlier.values["scheduler_total"]

    Map.update!(
      availability,
      "scheduler_utilization_permyriad",
      &(&1 and scheduler_monotonic?)
    )
  end

  defp counter_delta(earlier, later, key) do
    if earlier.available[key] and later.available[key] do
      max(Map.fetch!(later.values, key) - Map.fetch!(earlier.values, key), 0)
      |> bounded()
    else
      0
    end
  end

  defp gauge(later, key, available),
    do: if(available[key], do: Map.fetch!(later.values, key), else: 0)

  defp scheduler_utilization(earlier, later, available) do
    if available["scheduler_utilization_permyriad"] do
      active = max(later.values["scheduler_active"] - earlier.values["scheduler_active"], 0)
      total = max(later.values["scheduler_total"] - earlier.values["scheduler_total"], 0)

      if total > 0, do: min(div(active * 10_000, total), 10_000), else: 0
    else
      0
    end
  end

  defp statistic_total(kind, multiplier) do
    case :erlang.statistics(kind) do
      {total, _since_last_call} when is_integer(total) and total >= 0 ->
        {bounded(total * multiplier), true}

      _other ->
        {0, false}
    end
  rescue
    _error -> {0, false}
  catch
    _kind, _reason -> {0, false}
  end

  defp garbage_collection do
    case :erlang.statistics(:garbage_collection) do
      {collections, reclaimed, _legacy}
      when is_integer(collections) and collections >= 0 and is_integer(reclaimed) and
             reclaimed >= 0 ->
        {bounded(collections), bounded(reclaimed), true}

      _other ->
        {0, 0, false}
    end
  rescue
    _error -> {0, 0, false}
  catch
    _kind, _reason -> {0, 0, false}
  end

  defp scheduler_wall_time do
    case :erlang.statistics(:scheduler_wall_time) do
      entries when is_list(entries) ->
        Enum.reduce_while(entries, {0, 0, true}, fn
          {_id, active, total}, {active_sum, total_sum, true}
          when is_integer(active) and active >= 0 and is_integer(total) and total >= 0 ->
            {:cont, {bounded(active_sum + active), bounded(total_sum + total), true}}

          _entry, _accumulator ->
            {:halt, {0, 0, false}}
        end)

      _other ->
        {0, 0, false}
    end
  rescue
    _error -> {0, 0, false}
  catch
    _kind, _reason -> {0, 0, false}
  end

  defp runtime_value(fun) do
    case fun.() do
      value when is_integer(value) and value >= 0 -> {bounded(value), true}
      _other -> {0, false}
    end
  rescue
    _error -> {0, false}
  catch
    _kind, _reason -> {0, false}
  end

  defp bounded(value), do: value |> max(0) |> min(@maximum_scalar)
end

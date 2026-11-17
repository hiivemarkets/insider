defmodule Insider.Collector.SystemMonitor.Policy do
  @moduledoc """
  Bounded, pure-data policy for ERTS system-event collection.

  Legacy node-global monitoring is an explicit compatibility selection. Trusted
  environment, target, and runtime-feature facts come from `Insider.Policy.Context`
  at collector startup, never from this caller-created event policy.
  """

  alias Insider.Protocol.Value

  @event_order [
    :long_gc,
    :long_message_queue,
    :long_schedule,
    :large_heap,
    :busy_port,
    :busy_dist_port
  ]
  @keys [:events, :legacy_node_global]
  @max_time_ms 60_000
  @max_heap_words 1_000_000_000
  @max_integer 9_223_372_036_854_775_807

  @enforce_keys @keys
  defstruct @keys

  @type event_option ::
          {:long_gc, pos_integer()}
          | {:long_message_queue, {non_neg_integer(), pos_integer()}}
          | {:long_schedule, pos_integer()}
          | {:large_heap, pos_integer()}
          | {:busy_port, true}
          | {:busy_dist_port, true}

  @type t :: %__MODULE__{
          events: [event_option()],
          legacy_node_global: boolean()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_policy}
  def new(options) do
    with true <- Value.bounded_list?(options, length(@keys)),
         true <- Keyword.keyword?(options),
         keys = Keyword.keys(options),
         true <- Enum.uniq(keys) == keys,
         true <- Enum.all?(keys, &(&1 in @keys)),
         true <- :events in keys,
         {:ok, events} <- normalize_events(Keyword.fetch!(options, :events)) do
      policy = %__MODULE__{
        events: events,
        legacy_node_global: Keyword.get(options, :legacy_node_global, false)
      }

      if valid?(policy), do: {:ok, policy}, else: {:error, :invalid_policy}
    else
      _failure -> {:error, :invalid_policy}
    end
  rescue
    _error -> {:error, :invalid_policy}
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = policy) when map_size(policy) == 3 do
    is_boolean(policy.legacy_node_global) and
      match?({:ok, events} when events == policy.events, normalize_events(policy.events))
  rescue
    _error -> false
  end

  def valid?(_policy), do: false

  defp normalize_events(events) do
    with true <- Value.bounded_list?(events, length(@event_order)),
         true <- Keyword.keyword?(events),
         keys = Keyword.keys(events),
         true <- keys != [] and Enum.uniq(keys) == keys,
         true <- Enum.all?(events, &valid_event?/1) do
      values = Map.new(events)

      normalized =
        for event <- @event_order,
            Map.has_key?(values, event),
            do: {event, Map.fetch!(values, event)}

      {:ok, normalized}
    else
      _failure -> {:error, :invalid_events}
    end
  end

  defp valid_event?({event, true}) when event in [:busy_port, :busy_dist_port], do: true

  defp valid_event?({event, threshold}) when event in [:long_gc, :long_schedule],
    do: bounded_integer?(threshold, 1, @max_time_ms)

  defp valid_event?({:long_message_queue, {disable, enable}}),
    do:
      bounded_integer?(disable, 0, @max_integer) and
        bounded_integer?(enable, 1, @max_integer) and disable < enable

  defp valid_event?({:large_heap, threshold}),
    do: bounded_integer?(threshold, 1, @max_heap_words)

  defp valid_event?(_event), do: false

  defp bounded_integer?(value, minimum, maximum),
    do: is_integer(value) and value >= minimum and value <= maximum
end

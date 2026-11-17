defmodule Insider.Event.Ordering do
  @moduledoc "Ordering rules for immutable normalized events."

  alias Insider.Event

  @type relation :: :before | :after | :concurrent | :same_position | :equal | :conflict

  @spec stream_key(Event.t()) ::
          {String.t(), String.t(), String.t(), String.t(), String.t()}
  def stream_key(%Event{} = event),
    do: {event.node, event.boot_id, event.clock_id, event.source, event.source_instance_id}

  @spec compare(Event.t(), Event.t()) :: relation()
  def compare(%Event{} = left, %Event{} = right) do
    cond do
      left == right -> :equal
      left.id == right.id -> :conflict
      mutual_parents?(left, right) -> :conflict
      right.causality.parent_event_id == left.id -> parent_relation(left, right, :before)
      left.causality.parent_event_id == right.id -> parent_relation(left, right, :after)
      stream_key(left) != stream_key(right) -> :concurrent
      true -> stream_relation(left, right)
    end
  end

  defp mutual_parents?(left, right),
    do: left.causality.parent_event_id == right.id and right.causality.parent_event_id == left.id

  defp parent_relation(left, right, expected) do
    if stream_key(left) == stream_key(right) and
         stream_relation(left, right) not in [expected, :equal],
       do: :conflict,
       else: expected
  end

  defp stream_relation(left, right) do
    cond do
      left.source_sequence == right.source_sequence and
          left.monotonic_time == right.monotonic_time ->
        :same_position

      left.source_sequence == right.source_sequence ->
        :conflict

      left.source_sequence < right.source_sequence and
          left.monotonic_time <= right.monotonic_time ->
        :before

      left.source_sequence > right.source_sequence and
          left.monotonic_time >= right.monotonic_time ->
        :after

      true ->
        :conflict
    end
  end
end

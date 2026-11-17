defmodule Insider.Event.Value do
  @moduledoc false

  @integer_min -9_223_372_036_854_775_808
  @integer_max 9_223_372_036_854_775_807
  @max_depth 8
  @max_width 128
  @max_string_bytes 4_096

  @spec valid?(term(), pos_integer()) :: boolean()
  def valid?(value, max_encoded_bytes)
      when is_integer(max_encoded_bytes) and max_encoded_bytes > 0,
      do: match?({:ok, _remaining}, consume(value, 0, max_encoded_bytes))

  @spec valid_map?(term(), non_neg_integer(), pos_integer()) :: boolean()
  def valid_map?(value, maximum_entries, max_encoded_bytes)
      when is_map(value) and not is_struct(value) and map_size(value) <= maximum_entries,
      do: valid?(value, max_encoded_bytes)

  def valid_map?(_value, _maximum_entries, _max_encoded_bytes), do: false

  @spec valid_list?(term(), non_neg_integer(), pos_integer()) :: boolean()
  def valid_list?(value, maximum, max_encoded_bytes) do
    with {:ok, remaining} <- subtract(max_encoded_bytes, 2),
         {:ok, _remaining} <- consume_list(value, 0, maximum, 0, remaining) do
      true
    else
      _error -> false
    end
  end

  defp consume(_value, depth, _remaining) when depth > @max_depth, do: :error
  defp consume(nil, _depth, remaining), do: subtract(remaining, 4)
  defp consume(true, _depth, remaining), do: subtract(remaining, 4)
  defp consume(false, _depth, remaining), do: subtract(remaining, 5)

  defp consume(value, _depth, remaining) when is_integer(value) do
    if value >= @integer_min and value <= @integer_max,
      do: subtract(remaining, value |> Integer.to_string() |> byte_size()),
      else: :error
  end

  defp consume(value, _depth, remaining) when is_binary(value) do
    if byte_size(value) <= @max_string_bytes and String.valid?(value),
      do: subtract(remaining, encoded_scalar_size(value)),
      else: :error
  end

  defp consume(value, depth, remaining) when is_list(value) do
    with {:ok, remaining} <- subtract(remaining, 2) do
      consume_list(value, depth, @max_width, 0, remaining)
    end
  end

  defp consume(value, depth, remaining) when is_map(value) and not is_struct(value) do
    if map_size(value) <= @max_width do
      with {:ok, remaining} <- subtract(remaining, 2) do
        consume_map(Map.to_list(value), depth, 0, remaining)
      end
    else
      :error
    end
  end

  defp consume(_value, _depth, _remaining), do: :error

  defp consume_list([], _depth, _maximum, _count, remaining), do: {:ok, remaining}
  defp consume_list(_value, _depth, maximum, count, _remaining) when count >= maximum, do: :error

  defp consume_list([head | tail], depth, maximum, count, remaining) do
    comma_bytes = if count == 0, do: 0, else: 1

    with {:ok, remaining} <- subtract(remaining, comma_bytes),
         {:ok, remaining} <- consume(head, depth + 1, remaining) do
      consume_list(tail, depth, maximum, count + 1, remaining)
    end
  end

  defp consume_list(_improper, _depth, _maximum, _count, _remaining), do: :error

  defp consume_map([], _depth, _count, remaining), do: {:ok, remaining}

  defp consume_map([{key, value} | rest], depth, count, remaining) when is_binary(key) do
    comma_bytes = if count == 0, do: 0, else: 1

    with true <- byte_size(key) <= @max_string_bytes and String.valid?(key),
         {:ok, remaining} <- subtract(remaining, comma_bytes + encoded_scalar_size(key) + 1),
         {:ok, remaining} <- consume(value, depth + 1, remaining) do
      consume_map(rest, depth, count + 1, remaining)
    else
      _error -> :error
    end
  end

  defp consume_map(_entries, _depth, _count, _remaining), do: :error

  defp encoded_scalar_size(value),
    do: value |> Jason.encode_to_iodata!() |> :erlang.iolist_size()

  defp subtract(remaining, used) when remaining >= used, do: {:ok, remaining - used}
  defp subtract(_remaining, _used), do: :error
end

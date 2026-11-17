defmodule Insider.Collector.Logger.Shape do
  @moduledoc false

  @max_nodes 32
  @max_depth 5
  @max_width 16
  @max_binary_bytes 256

  @spec encode(term()) :: term()
  def encode(term) do
    {value, _remaining} = encode(term, 0, @max_nodes)
    value
  rescue
    _error -> %{"type" => "unavailable"}
  catch
    _kind, _reason -> %{"type" => "unavailable"}
  end

  defp encode(_term, _depth, 0), do: {%{"type" => "truncated"}, 0}

  defp encode(_term, depth, remaining) when depth >= @max_depth,
    do: {%{"type" => "depth_limit"}, remaining - 1}

  defp encode(nil, _depth, remaining), do: {nil, remaining - 1}
  defp encode(value, _depth, remaining) when is_boolean(value), do: {value, remaining - 1}

  defp encode(value, _depth, remaining)
       when is_integer(value) and
              value >= -9_223_372_036_854_775_808 and
              value <= 9_223_372_036_854_775_807,
       do: {value, remaining - 1}

  defp encode(value, _depth, remaining) when is_integer(value),
    do:
      {%{"type" => "integer", "range" => "outside_int64", "sign" => integer_sign(value)},
       remaining - 1}

  defp encode(value, _depth, remaining) when is_float(value),
    do: {Float.to_string(value), remaining - 1}

  defp encode(value, _depth, remaining) when is_atom(value),
    do: {value |> Atom.to_string() |> truncate(), remaining - 1}

  defp encode(value, _depth, remaining) when is_binary(value) do
    encoded =
      case bounded_text(value) do
        {:ok, text} -> text
        :error -> %{"type" => "binary", "bytes" => byte_size(value)}
      end

    {encoded, remaining - 1}
  end

  defp encode(value, depth, remaining) when is_list(value),
    do: encode_list(value, depth + 1, remaining - 1, [], 0)

  defp encode(value, depth, remaining) when is_tuple(value) do
    count = min(tuple_size(value), @max_width)

    {items, remaining} =
      if count == 0 do
        {[], remaining - 1}
      else
        Enum.reduce_while(0..(count - 1), {[], remaining - 1}, fn index, {items, left} ->
          if left == 0 do
            {:halt, {items, left}}
          else
            {item, left} = encode(elem(value, index), depth + 1, left)
            {:cont, {[item | items], left}}
          end
        end)
      end

    {%{"type" => "tuple", "items" => Enum.reverse(items), "size" => tuple_size(value)}, remaining}
  end

  defp encode(value, depth, remaining) when is_map(value) and not is_struct(value) do
    encode_map(:maps.iterator(value), depth + 1, remaining - 1, %{}, 0, map_size(value))
  end

  defp encode(value, _depth, remaining) when is_pid(value),
    do: {value |> :erlang.pid_to_list() |> to_string(), remaining - 1}

  defp encode(value, _depth, remaining) when is_port(value),
    do: {%{"type" => "port"}, remaining - 1}

  defp encode(value, _depth, remaining) when is_reference(value),
    do: {%{"type" => "reference"}, remaining - 1}

  defp encode(value, _depth, remaining) when is_function(value),
    do: {%{"type" => "function"}, remaining - 1}

  defp encode(_value, _depth, remaining), do: {%{"type" => "term"}, remaining - 1}

  defp encode_list([], _depth, remaining, items, _count), do: {Enum.reverse(items), remaining}

  defp encode_list(_rest, _depth, remaining, items, count)
       when remaining == 0 or count == @max_width do
    {Enum.reverse(items) ++ [%{"type" => "truncated"}], remaining}
  end

  defp encode_list([head | tail], depth, remaining, items, count) do
    {item, remaining} = encode(head, depth, remaining)
    encode_list(tail, depth, remaining, [item | items], count + 1)
  end

  defp encode_list(_improper, _depth, remaining, items, _count),
    do: {Enum.reverse([%{"type" => "improper_tail"} | items]), remaining}

  defp encode_map(_iterator, _depth, remaining, values, count, size)
       when remaining == 0 or count == @max_width,
       do: {Map.put(values, "$insider_truncated", size - count), remaining}

  defp encode_map(iterator, depth, remaining, values, count, size) do
    case :maps.next(iterator) do
      :none ->
        {values, remaining}

      {key, value, next} ->
        {value, remaining} = encode(value, depth, remaining)
        key = map_key(key, count)
        encode_map(next, depth, remaining, Map.put(values, key, value), count + 1, size)
    end
  end

  defp map_key(key, _count) when is_atom(key), do: key |> Atom.to_string() |> truncate()

  defp map_key(key, _count) when is_binary(key) do
    case bounded_text(key) do
      {:ok, text} -> text
      :error -> "$binary_key"
    end
  end

  defp map_key(key, _count) when is_integer(key), do: "$integer_key_" <> integer_sign(key)
  defp map_key(_key, count), do: "$other_key_" <> Integer.to_string(count)

  defp truncate(value) when byte_size(value) <= @max_binary_bytes, do: :binary.copy(value)
  defp truncate(value), do: value |> binary_part(0, @max_binary_bytes) |> :binary.copy()

  defp bounded_text(value) when byte_size(value) <= @max_binary_bytes do
    if String.valid?(value), do: {:ok, :binary.copy(value)}, else: :error
  end

  defp bounded_text(value) do
    value
    |> binary_part(0, @max_binary_bytes)
    |> valid_prefix()
  end

  defp valid_prefix(value) when byte_size(value) == 0, do: :error

  defp valid_prefix(value) do
    if String.valid?(value),
      do: {:ok, :binary.copy(value)},
      else: value |> binary_part(0, byte_size(value) - 1) |> valid_prefix()
  end

  defp integer_sign(value) when value < 0, do: "negative"
  defp integer_sign(_value), do: "positive"
end

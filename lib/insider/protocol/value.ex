defmodule Insider.Protocol.Value do
  @moduledoc false

  @max_depth 8
  @max_width 1_000

  @spec summary(term()) :: map()
  def summary(value) when is_binary(value), do: %{type: "binary", bytes: byte_size(value)}
  def summary(value) when is_map(value), do: %{type: "map", entries: map_size(value)}
  def summary(value) when is_list(value), do: %{type: "list"}
  def summary(value) when is_tuple(value), do: %{type: "tuple", elements: tuple_size(value)}
  def summary(value) when is_atom(value), do: %{type: "atom"}
  def summary(value) when is_integer(value), do: %{type: "integer"}
  def summary(value) when is_float(value), do: %{type: "float"}
  def summary(value) when is_pid(value), do: %{type: "pid"}
  def summary(value) when is_port(value), do: %{type: "port"}
  def summary(value) when is_reference(value), do: %{type: "reference"}
  def summary(value) when is_function(value), do: %{type: "function"}
  def summary(_value), do: %{type: "other"}

  @spec bounded_data?(term(), pos_integer()) :: boolean()
  def bounded_data?(value, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    safe_external_size?(value, max_bytes) and data_shape?(value, 0)
  end

  @doc false
  @spec bounded_list?(term(), non_neg_integer()) :: boolean()
  def bounded_list?(value, maximum) when is_integer(maximum) and maximum >= 0,
    do: bounded_list_length?(value, maximum, 0)

  defp safe_external_size?(value, max_bytes) do
    :erlang.external_size(value) <= max_bytes
  rescue
    _error -> false
  end

  defp data_shape?(_value, depth) when depth > @max_depth, do: false
  defp data_shape?(value, _depth) when is_nil(value) or is_boolean(value), do: true
  defp data_shape?(value, _depth) when is_number(value) or is_atom(value), do: true
  defp data_shape?(value, _depth) when is_binary(value), do: true

  defp data_shape?(value, depth) when is_map(value) and map_size(value) <= @max_width do
    value
    |> Map.to_list()
    |> Enum.all?(fn {key, item} ->
      valid_key?(key) and data_shape?(item, depth + 1)
    end)
  end

  defp data_shape?(value, depth) when is_tuple(value) and tuple_size(value) <= @max_width do
    value
    |> Tuple.to_list()
    |> Enum.all?(&data_shape?(&1, depth + 1))
  end

  defp data_shape?(value, depth) when is_list(value) do
    data_list?(value, depth, 0)
  end

  defp data_shape?(_value, _depth), do: false

  defp data_list?([], _depth, _count), do: true
  defp data_list?(_list, _depth, count) when count >= @max_width, do: false

  defp data_list?([head | tail], depth, count) do
    data_shape?(head, depth + 1) and data_list?(tail, depth, count + 1)
  end

  defp data_list?(_improper_tail, _depth, _count), do: false

  defp bounded_list_length?([], _maximum, _count), do: true
  defp bounded_list_length?(_value, maximum, count) when count >= maximum, do: false

  defp bounded_list_length?([_head | tail], maximum, count),
    do: bounded_list_length?(tail, maximum, count + 1)

  defp bounded_list_length?(_value, _maximum, _count), do: false

  defp valid_key?(key), do: is_atom(key) or is_binary(key) or is_integer(key)
end

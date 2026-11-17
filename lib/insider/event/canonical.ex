defmodule Insider.Event.Canonical do
  @moduledoc false

  @spec encode(term()) :: binary()
  def encode(value), do: value |> encode_value() |> IO.iodata_to_binary()

  @spec sha256(term()) :: String.t()
  def sha256(value), do: value |> encode() |> sha256_binary()

  @spec sha256_binary(binary()) :: String.t()
  def sha256_binary(value) when is_binary(value),
    do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp encode_value(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _item} -> key end)
      |> Enum.map_join(",", fn {key, item} ->
        [Jason.encode_to_iodata!(key), ?:, encode_value(item)]
      end)

    [?{, entries, ?}]
  end

  defp encode_value(value) when is_list(value) do
    [?[, Enum.map_join(value, ",", &encode_value/1), ?]]
  end

  defp encode_value(value), do: Jason.encode_to_iodata!(value)
end

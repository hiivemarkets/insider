defmodule Insider.Observability.Codec do
  @moduledoc false

  alias Insider.Event.Canonical
  alias Insider.Protocol.Error

  @spec decode(
          term(),
          pos_integer(),
          (map() -> {:ok, term()} | {:error, Error.t()}),
          {:error, Error.t()},
          {:error, Error.t()}
        ) :: {:ok, term()} | {:error, Error.t()}
  def decode(binary, maximum_bytes, decode_map, invalid, limit_exceeded)
      when is_binary(binary) and is_function(decode_map, 1) do
    if byte_size(binary) <= maximum_bytes do
      decode_bounded(binary, decode_map, invalid)
    else
      limit_exceeded
    end
  end

  def decode(_value, _maximum_bytes, _decode_map, invalid, _limit_exceeded), do: invalid

  @spec encode_validated(
          term(),
          (term() -> {:ok, term()} | {:error, Error.t()}),
          (term() -> map())
        ) :: {:ok, binary()} | {:error, Error.t()}
  def encode_validated(value, validate, to_wire_map)
      when is_function(validate, 1) and is_function(to_wire_map, 1) do
    with {:ok, valid_value} <- validate.(value) do
      {:ok, valid_value |> to_wire_map.() |> Canonical.encode()}
    end
  end

  defp decode_bounded(binary, decode_map, invalid) do
    with {:ok, wire} <- Jason.decode(binary),
         true <- Canonical.encode(wire) == binary,
         {:ok, value} <- decode_map.(wire) do
      {:ok, value}
    else
      {:error, %Jason.DecodeError{}} -> invalid
      {:error, %Error{}} = error -> error
      false -> invalid
    end
  rescue
    _error -> invalid
  catch
    _kind, _reason -> invalid
  end
end

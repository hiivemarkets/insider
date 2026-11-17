defmodule Insider.Sentinel.Verification.Ingress do
  @moduledoc false

  alias Insider.Event.Canonical

  @spec canonical_decode(term(), pos_integer(), (map() -> term())) :: term()
  def canonical_decode(binary, maximum_bytes, decode_map)
      when is_binary(binary) and byte_size(binary) <= maximum_bytes do
    with {:ok, wire} <- Jason.decode(binary),
         true <- Canonical.encode(wire) == binary do
      decode_map.(wire)
    else
      {:error, %Jason.DecodeError{}} -> {:ingress_error, :invalid_json}
      false -> {:ingress_error, :noncanonical_encoding}
    end
  rescue
    _error -> {:ingress_error, :decoding_failed}
  end

  def canonical_decode(binary, _maximum_bytes, _decode_map) when is_binary(binary),
    do: {:ingress_error, :limit_exceeded}

  def canonical_decode(_value, _maximum_bytes, _decode_map),
    do: {:ingress_error, :invalid_encoding}

  @spec identity?(term()) :: boolean()
  def identity?(identity) do
    case identity do
      %{"id" => id, "version" => version}
      when map_size(identity) == 2 and is_binary(id) and byte_size(id) in 1..128 and
             is_integer(version) and version in 1..1_000_000 ->
        Regex.match?(~r/\A[a-z][a-z0-9_.-]*\z/, id)

      _other ->
        false
    end
  end
end

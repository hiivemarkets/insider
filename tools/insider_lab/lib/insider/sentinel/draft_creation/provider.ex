defmodule Insider.Sentinel.DraftCreation.Provider do
  @moduledoc """
  Behaviour for an explicitly configured draft-creation provider.

  Implementations must use `idempotency_key` as provider-native idempotency,
  must stop work when the monotonic deadline expires, and must return only
  bounded wire data. This contract authorizes draft creation only; merge and
  deployment must never be exposed by an implementation.
  """

  alias Insider.Event.Canonical
  alias Insider.Protocol.Value
  alias Insider.Sentinel.DraftCreation.Identity

  @maximum_response_bytes 16_384

  @type deadline :: integer()
  @type idempotency_key :: binary()
  @type request :: %{String.t() => term()}
  @type response :: %{String.t() => term()}

  @callback identity() :: Identity.provider()
  @callback create(request(), idempotency_key(), deadline()) ::
              {:ok, response()} | {:error, atom()}

  @doc false
  @spec maximum_response_bytes() :: pos_integer()
  def maximum_response_bytes, do: @maximum_response_bytes

  @doc false
  @spec response?(term()) :: boolean()
  def response?(response) when is_map(response) and not is_struct(response) do
    Value.bounded_data?(response, @maximum_response_bytes) and
      byte_size(Canonical.encode(response)) <= @maximum_response_bytes and
      match?({:ok, ^response}, Jason.decode(Canonical.encode(response)))
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  def response?(_value), do: false
end

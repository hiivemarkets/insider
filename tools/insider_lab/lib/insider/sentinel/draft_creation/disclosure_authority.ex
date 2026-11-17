defmodule Insider.Sentinel.DraftCreation.DisclosureAuthority do
  @moduledoc """
  Behaviour for an explicitly configured disclosure-policy authority.

  The authority evaluates an exact payload reference for one exact provider.
  Returned references are opaque policy-decision identifiers. Content hashes
  establish record identity; they do not establish the authority's authenticity.
  """

  alias Insider.Sentinel.DraftCreation.Identity

  @maximum_decision_reference_bytes 512

  @type deadline :: integer()
  @type decision_reference :: binary()
  @type payload_reference :: %{required(String.t()) => term()}

  @callback identity() :: Identity.authority()
  @callback authorize(payload_reference(), Identity.provider(), deadline()) ::
              {:approved, decision_reference()} | {:denied, atom()}

  @doc false
  @spec decision_reference?(term()) :: boolean()
  def decision_reference?(value),
    do:
      is_binary(value) and byte_size(value) in 1..@maximum_decision_reference_bytes and
        String.valid?(value)
end

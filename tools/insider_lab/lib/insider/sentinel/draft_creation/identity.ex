defmodule Insider.Sentinel.DraftCreation.Identity do
  @moduledoc """
  Validators for the portable provider and disclosure-authority identities used
  by the draft-creation gate. An identity selects a module only from the host's
  configured allowlist; it can never resolve a module by itself.
  """

  alias Insider.Detectors.Input
  alias Insider.Protocol.Error
  alias Insider.Sentinel.Verification.Ingress

  @type authority :: map()
  @type provider :: map()

  @spec provider?(term()) :: boolean()
  def provider?(
        %{
          "destination_fingerprint" => destination_fingerprint,
          "id" => id,
          "version" => version
        } = identity
      ) do
    map_size(identity) == 3 and Ingress.identity?(%{"id" => id, "version" => version}) and
      Input.digest?(destination_fingerprint)
  end

  def provider?(_value), do: false

  @spec disclosure_authority?(term()) :: boolean()
  def disclosure_authority?(identity), do: Ingress.identity?(identity)

  @spec validate_provider(term()) :: {:ok, provider()} | {:error, Error.t()}
  def validate_provider(identity) do
    if provider?(identity), do: {:ok, identity}, else: invalid(:provider_identity)
  end

  @spec validate_disclosure_authority(term()) :: {:ok, authority()} | {:error, Error.t()}
  def validate_disclosure_authority(identity) do
    if disclosure_authority?(identity),
      do: {:ok, identity},
      else: invalid(:disclosure_authority_identity)
  end

  defp invalid(reason),
    do:
      {:error,
       Error.new(:invalid_request, "draft-creation identity is invalid", %{reason: reason})}
end

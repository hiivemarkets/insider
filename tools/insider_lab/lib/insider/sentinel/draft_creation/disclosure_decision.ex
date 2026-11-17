defmodule Insider.Sentinel.DraftCreation.DisclosureDecision do
  @moduledoc """
  A canonical record of one disclosure authority's draft-creation decision.

  Standalone validation establishes only the record's content identity. Trusting
  an approval requires exact recomputation from the payload, provider, authority,
  and opaque decision reference supplied by the configured authority boundary.
  SHA-256 provides identity, not authenticity.
  """

  alias Insider.Detectors.Input
  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value
  alias Insider.Sentinel.DraftCreation.DisclosureAuthority
  alias Insider.Sentinel.DraftCreation.Identity
  alias Insider.Sentinel.Verification.Ingress

  @schema "insider.draft-creation-disclosure-decision/v1"
  @maximum_bytes 16_384
  @maximum_term_bytes 32_768
  @maximum_payload_bytes 2_097_152
  @maximum_schema_bytes 128
  @fields [
    :schema,
    :id,
    :status,
    :purpose,
    :audience,
    :controls,
    :trust,
    :payload,
    :provider,
    :authority,
    :decision_reference,
    :integrity
  ]
  @wire_keys @fields |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  @status "approved_for_draft_creation"
  @purpose "authorize_exact_payload_for_draft_creation"
  @audience "configured_draft_creation_provider"
  @controls %{
    "deploy" => "prohibited",
    "draft" => true,
    "merge" => "prohibited",
    "publication" => "draft_only",
    "review_required" => true
  }
  @trust %{
    "authorization" => "requires_exact_recomputation",
    "hashes" => "identity_not_authenticity",
    "standalone_validation" => "record_identity_only"
  }

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec new(term(), term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(payload, provider, authority, decision_reference) do
    with true <- valid_payload_reference?(payload),
         {:ok, provider} <- Identity.validate_provider(provider),
         {:ok, authority} <- Identity.validate_disclosure_authority(authority),
         true <- DisclosureAuthority.decision_reference?(decision_reference) do
      body = %{
        "schema" => @schema,
        "status" => @status,
        "purpose" => @purpose,
        "audience" => @audience,
        "controls" => @controls,
        "trust" => @trust,
        "payload" => payload,
        "provider" => provider,
        "authority" => authority,
        "decision_reference" => decision_reference
      }

      digest = Canonical.sha256(body)

      body
      |> Map.merge(%{
        "id" => "sha256:" <> digest,
        "integrity" => %{"algorithm" => "sha256", "content_digest" => digest}
      })
      |> decode_map()
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> invalid(:construction_failed)
    end
  rescue
    _error -> invalid(:construction_failed)
  catch
    _kind, _reason -> invalid(:construction_failed)
  end

  @doc "Validates canonical structure and record identity, not trusted approval."
  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = decision) do
    wire = to_wire_map(decision)

    with true <- Enum.sort(Map.keys(Map.from_struct(decision))) == Enum.sort(@fields),
         true <- decision.schema == @schema,
         true <- decision.status == @status,
         true <- decision.purpose == @purpose,
         true <- decision.audience == @audience,
         true <- decision.controls == @controls,
         true <- decision.trust == @trust,
         true <- valid_payload_reference?(decision.payload),
         true <- Identity.provider?(decision.provider),
         true <- Identity.disclosure_authority?(decision.authority),
         true <- DisclosureAuthority.decision_reference?(decision.decision_reference),
         true <- Value.bounded_data?(wire, @maximum_term_bytes),
         true <- valid_integrity?(decision.integrity),
         true <- decision.id == "sha256:" <> decision.integrity["content_digest"],
         true <- decision.integrity["content_digest"] == Canonical.sha256(content(decision)),
         encoded <- Canonical.encode(wire),
         {:ok, decoded} <- Jason.decode(encoded),
         true <- decoded == wire,
         true <- byte_size(encoded) <= @maximum_bytes do
      {:ok, decision}
    else
      _other -> invalid(:invalid_decision)
    end
  rescue
    _error -> invalid(:validation_failed)
  catch
    _kind, _reason -> invalid(:validation_failed)
  end

  def validate(_value), do: invalid(:invalid_value)

  @doc "Recomputes the record from the exact authority-bound inputs."
  @spec validate_with(term(), term(), term(), term(), term()) ::
          {:ok, t()} | {:error, Error.t()}
  def validate_with(decision, payload, provider, authority, decision_reference) do
    with {:ok, valid} <- validate(decision),
         {:ok, expected} <- new(payload, provider, authority, decision_reference),
         true <- to_wire_map(valid) == to_wire_map(expected) do
      {:ok, valid}
    else
      _other -> integrity_failed()
    end
  rescue
    _error -> integrity_failed()
  catch
    _kind, _reason -> integrity_failed()
  end

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(decision) do
    with {:ok, valid} <- validate(decision), do: {:ok, Canonical.encode(to_wire_map(valid))}
  end

  @spec decode(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode(value) do
    value
    |> Ingress.canonical_decode(@maximum_bytes, &decode_map/1)
    |> normalize_decode()
  end

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(wire) when is_map(wire) and not is_struct(wire) do
    case Map.fetch(wire, "schema") do
      {:ok, @schema} -> decode_current(wire)
      {:ok, schema} -> unsupported_schema(schema)
      :error -> unsupported_schema(nil)
    end
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode_map(_value), do: invalid(:invalid_value)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = decision) do
    %{
      "schema" => decision.schema,
      "id" => decision.id,
      "status" => decision.status,
      "purpose" => decision.purpose,
      "audience" => decision.audience,
      "controls" => decision.controls,
      "trust" => decision.trust,
      "payload" => decision.payload,
      "provider" => decision.provider,
      "authority" => decision.authority,
      "decision_reference" => decision.decision_reference,
      "integrity" => decision.integrity
    }
  end

  defp decode_current(wire) do
    if map_size(wire) == length(@wire_keys) and Enum.sort(Map.keys(wire)) == @wire_keys do
      wire
      |> then(fn value ->
        %__MODULE__{
          schema: value["schema"],
          id: value["id"],
          status: value["status"],
          purpose: value["purpose"],
          audience: value["audience"],
          controls: value["controls"],
          trust: value["trust"],
          payload: value["payload"],
          provider: value["provider"],
          authority: value["authority"],
          decision_reference: value["decision_reference"],
          integrity: value["integrity"]
        }
      end)
      |> validate()
    else
      invalid(:invalid_envelope)
    end
  end

  defp valid_payload_reference?(
         %{
           "byte_size" => byte_size,
           "canonical_sha256" => digest,
           "schema" => schema
         } = reference
       ) do
    map_size(reference) == 3 and is_integer(byte_size) and
      byte_size in 1..@maximum_payload_bytes and Input.digest?(digest) and
      is_binary(schema) and byte_size(schema) in 1..@maximum_schema_bytes and
      String.valid?(schema)
  end

  defp valid_payload_reference?(_value), do: false

  defp valid_integrity?(%{"algorithm" => "sha256", "content_digest" => digest} = integrity),
    do: map_size(integrity) == 2 and Input.digest?(digest)

  defp valid_integrity?(_value), do: false

  defp content(decision),
    do: decision |> to_wire_map() |> Map.drop(["id", "integrity"])

  defp normalize_decode({:ingress_error, :limit_exceeded}), do: limit_exceeded()
  defp normalize_decode({:ingress_error, reason}), do: invalid(reason)
  defp normalize_decode(result), do: result

  defp invalid(reason),
    do:
      {:error,
       Error.new(:invalid_request, "draft-creation disclosure decision is invalid", %{
         reason: reason
       })}

  defp integrity_failed,
    do:
      {:error,
       Error.new(:operation_failed, "draft-creation disclosure decision evidence differs")}

  defp limit_exceeded,
    do:
      {:error,
       Error.new(:invalid_request, "draft-creation disclosure decision exceeds its limit")}

  defp unsupported_schema(schema),
    do:
      {:error,
       Error.new(:invalid_request, "draft-creation disclosure decision schema is unsupported", %{
         schema: Value.summary(schema)
       })}
end

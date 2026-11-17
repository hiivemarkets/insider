defmodule Insider.Sentinel.DraftCreation.Receipt do
  @moduledoc """
  A canonical local record of one draft-provider attempt.

  Created and existing outcomes are provider-reported, not independently
  verified remote state. An unknown outcome is retained after a deadline because
  terminating the local callback cannot prove that an external effect did not
  occur. Exactly-once behavior therefore depends on provider-native idempotency.
  Standalone validation proves only structure and content identity; callers
  trust a receipt only after `validate_with/2` recomputes it from the request.
  """

  alias Insider.Detectors.Input
  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value
  alias Insider.Sentinel.DraftCreation.Identity
  alias Insider.Sentinel.DraftCreation.Request
  alias Insider.Sentinel.Verification.Ingress

  @schema "insider.draft-creation-receipt/v1"
  @maximum_bytes 16_384
  @maximum_term_bytes 32_768
  @maximum_reference_bytes 1_024
  @fields [
    :schema,
    :id,
    :outcome,
    :controls,
    :request,
    :provider,
    :disclosure,
    :draft,
    :trust,
    :integrity
  ]
  @wire_keys @fields |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  @outcomes ~w(provider_reported_created provider_reported_existing provider_reported_rejected provider_outcome_unknown provider_output_invalid)
  @controls %{
    "deploy" => "prohibited",
    "draft" => true,
    "merge" => "prohibited",
    "review_required" => true
  }
  @trust %{
    "exactly_once" => "requires_provider_native_idempotency",
    "remote_state" => "not_independently_verified",
    "scope" => "local_provider_attempt"
  }

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec new(term(), binary(), binary() | nil) :: {:ok, t()} | {:error, Error.t()}
  def new(request, outcome, draft_reference) do
    with {:ok, request} <- Request.validate(request),
         true <- outcome in @outcomes,
         true <- valid_draft?(outcome, draft_reference),
         {:ok, request_bytes} <- Request.canonical_binary(request) do
      body = %{
        "schema" => @schema,
        "outcome" => outcome,
        "controls" => @controls,
        "request" => request_reference(request, request_bytes),
        "provider" => request.provider,
        "disclosure" => %{"decision_id" => request.disclosure_decision["id"]},
        "draft" => draft(outcome, draft_reference),
        "trust" => @trust
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

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = receipt) do
    wire = to_wire_map(receipt)

    with true <- Enum.sort(Map.keys(Map.from_struct(receipt))) == Enum.sort(@fields),
         true <- receipt.schema == @schema,
         true <- receipt.outcome in @outcomes,
         true <- receipt.controls == @controls,
         true <- valid_request_reference?(receipt.request),
         true <- Identity.provider?(receipt.provider),
         true <- valid_disclosure?(receipt.disclosure),
         true <- valid_draft_map?(receipt.outcome, receipt.draft),
         true <- receipt.trust == @trust,
         true <- Value.bounded_data?(wire, @maximum_term_bytes),
         true <- valid_integrity?(receipt.integrity),
         true <- receipt.id == "sha256:" <> receipt.integrity["content_digest"],
         true <- receipt.integrity["content_digest"] == Canonical.sha256(content(receipt)),
         encoded <- Canonical.encode(wire),
         {:ok, decoded} <- Jason.decode(encoded),
         true <- decoded == wire,
         true <- byte_size(encoded) <= @maximum_bytes do
      {:ok, receipt}
    else
      _other -> invalid(:invalid_receipt)
    end
  rescue
    _error -> invalid(:validation_failed)
  catch
    _kind, _reason -> invalid(:validation_failed)
  end

  def validate(_value), do: invalid(:invalid_value)

  @doc "Recomputes the receipt from the exact request and recorded provider outcome."
  @spec validate_with(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate_with(receipt, request) do
    with {:ok, valid} <- validate(receipt),
         {:ok, expected} <- new(request, valid.outcome, valid.draft["reference"]),
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
  def canonical_binary(receipt) do
    with {:ok, valid} <- validate(receipt), do: {:ok, Canonical.encode(to_wire_map(valid))}
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
  def to_wire_map(%__MODULE__{} = receipt),
    do: %{
      "schema" => receipt.schema,
      "id" => receipt.id,
      "outcome" => receipt.outcome,
      "controls" => receipt.controls,
      "request" => receipt.request,
      "provider" => receipt.provider,
      "disclosure" => receipt.disclosure,
      "draft" => receipt.draft,
      "trust" => receipt.trust,
      "integrity" => receipt.integrity
    }

  defp request_reference(request, bytes),
    do: %{
      "byte_size" => byte_size(bytes),
      "canonical_sha256" => Canonical.sha256_binary(bytes),
      "id" => request.id,
      "idempotency_key" => request.idempotency_key,
      "intent_id" => request.intent_id,
      "schema" => request.schema
    }

  defp valid_request_reference?(
         %{
           "byte_size" => bytes,
           "canonical_sha256" => canonical_sha256,
           "id" => "sha256:" <> id,
           "idempotency_key" => "sha256:" <> key,
           "intent_id" => "sha256:" <> intent,
           "schema" => "insider.draft-creation-request/v1"
         } = reference
       ),
       do:
         map_size(reference) == 6 and is_integer(bytes) and bytes in 1..262_144 and
           Input.digest?(canonical_sha256) and Input.digest?(id) and Input.digest?(key) and
           Input.digest?(intent)

  defp valid_request_reference?(_value), do: false

  defp valid_disclosure?(%{"decision_id" => "sha256:" <> digest} = disclosure),
    do: map_size(disclosure) == 1 and Input.digest?(digest)

  defp valid_disclosure?(_value), do: false

  defp valid_draft?(outcome, reference)
       when outcome in ["provider_reported_created", "provider_reported_existing"],
       do:
         is_binary(reference) and byte_size(reference) in 1..@maximum_reference_bytes and
           String.valid?(reference)

  defp valid_draft?(outcome, nil),
    do: outcome in (@outcomes -- ["provider_reported_created", "provider_reported_existing"])

  defp valid_draft?(_outcome, _reference), do: false

  defp draft("provider_reported_created", reference),
    do: %{"provider_reported" => true, "reference" => reference, "state" => "created"}

  defp draft("provider_reported_existing", reference),
    do: %{"provider_reported" => true, "reference" => reference, "state" => "existing"}

  defp draft(outcome, nil),
    do: %{"provider_reported" => false, "reference" => nil, "state" => outcome}

  defp valid_draft_map?(
         "provider_reported_created",
         %{
           "provider_reported" => true,
           "reference" => reference,
           "state" => "created"
         } = draft
       ),
       do: map_size(draft) == 3 and valid_draft?("provider_reported_created", reference)

  defp valid_draft_map?(
         "provider_reported_existing",
         %{
           "provider_reported" => true,
           "reference" => reference,
           "state" => "existing"
         } = draft
       ),
       do: map_size(draft) == 3 and valid_draft?("provider_reported_existing", reference)

  defp valid_draft_map?(
         outcome,
         %{
           "provider_reported" => false,
           "reference" => nil,
           "state" => outcome
         } = draft
       ),
       do:
         map_size(draft) == 3 and
           outcome in (@outcomes -- ["provider_reported_created", "provider_reported_existing"])

  defp valid_draft_map?(_outcome, _draft), do: false

  defp decode_current(wire) do
    if map_size(wire) == length(@wire_keys) and Enum.sort(Map.keys(wire)) == @wire_keys do
      wire
      |> then(fn value ->
        %__MODULE__{
          schema: value["schema"],
          id: value["id"],
          outcome: value["outcome"],
          controls: value["controls"],
          request: value["request"],
          provider: value["provider"],
          disclosure: value["disclosure"],
          draft: value["draft"],
          trust: value["trust"],
          integrity: value["integrity"]
        }
      end)
      |> validate()
    else
      invalid(:invalid_envelope)
    end
  end

  defp valid_integrity?(%{"algorithm" => "sha256", "content_digest" => digest} = integrity),
    do: map_size(integrity) == 2 and Input.digest?(digest)

  defp valid_integrity?(_value), do: false
  defp content(receipt), do: receipt |> to_wire_map() |> Map.drop(["id", "integrity"])
  defp normalize_decode({:ingress_error, :limit_exceeded}), do: limit_exceeded()
  defp normalize_decode({:ingress_error, reason}), do: invalid(reason)
  defp normalize_decode(result), do: result

  defp invalid(reason),
    do:
      {:error,
       Error.new(:invalid_draft_creation_receipt, "draft-creation receipt is invalid", %{
         reason: reason
       })}

  defp limit_exceeded,
    do:
      {:error,
       Error.new(
         :draft_creation_receipt_limit_exceeded,
         "draft-creation receipt exceeds its limit"
       )}

  defp integrity_failed,
    do:
      {:error,
       Error.new(
         :draft_creation_receipt_integrity_failed,
         "draft-creation receipt does not match the supplied request"
       )}

  defp unsupported_schema(schema),
    do:
      {:error,
       Error.new(
         :unsupported_draft_creation_receipt_schema,
         "draft-creation receipt schema is unsupported",
         %{schema: Value.summary(schema)}
       )}
end

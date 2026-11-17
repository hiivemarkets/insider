defmodule Insider.Sentinel.DraftCreation.Request do
  @moduledoc """
  A canonical, disclosure-approved request for one provider-created draft.

  The request binds a verified draft proposal and inert candidate submission to
  one exact coding-agent handoff and one configured provider destination. Its
  idempotency key deliberately excludes the renewable disclosure decision, so
  reauthorization cannot select a second draft. This artifact grants no merge,
  deployment, credential, or unrestricted repository authority.
  """

  alias Insider.Detectors.Input
  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value
  alias Insider.Sentinel.CodingAgent.CandidateSubmission
  alias Insider.Sentinel.CodingAgent.Handoff
  alias Insider.Sentinel.DraftCreation.DisclosureDecision
  alias Insider.Sentinel.DraftCreation.Identity
  alias Insider.Sentinel.DraftProposal
  alias Insider.Sentinel.Verification.Ingress

  @schema "insider.draft-creation-request/v1"
  @payload_schema "insider.draft-creation-payload/v1"
  @intent_schema "insider.draft-creation-intent/v1"
  @idempotency_schema "insider.draft-creation-idempotency/v1"
  @maximum_bytes 262_144
  @maximum_term_bytes 524_288
  @maximum_handoff_bytes 1_572_864
  @fields [
    :schema,
    :id,
    :kind,
    :controls,
    :intent_id,
    :idempotency_key,
    :provider,
    :proposal,
    :submission,
    :handoff,
    :disclosure_decision,
    :integrity
  ]
  @wire_keys @fields |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  @payload_keys ~w(controls handoff idempotency_key intent_id kind proposal provider schema submission)
  @controls %{
    "credentials" => "none",
    "deploy" => "prohibited",
    "draft" => true,
    "merge" => "prohibited",
    "network_effect" => "configured_provider_only",
    "publication" => "draft_only",
    "repository_mutation" => "draft_creation_only",
    "review_required" => true
  }

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @doc "Builds a request after an authority has approved its exact provider-visible payload."
  @spec new(term(), term(), term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(proposal, submission, handoff, provider, disclosure_decision) do
    with {:ok, payload} <- build_payload(proposal, submission, handoff, provider),
         {:ok, disclosure_decision} <- DisclosureDecision.validate(disclosure_decision),
         true <- disclosure_decision.payload == reference(@payload_schema, payload),
         true <- disclosure_decision.provider == payload["provider"] do
      body =
        payload
        |> Map.put("schema", @schema)
        |> Map.put("disclosure_decision", DisclosureDecision.to_wire_map(disclosure_decision))

      digest = Canonical.sha256(body)

      body
      |> Map.merge(%{
        "id" => "sha256:" <> digest,
        "integrity" => %{"algorithm" => "sha256", "content_digest" => digest}
      })
      |> decode_map()
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> invalid(:disclosure_binding_mismatch)
    end
  rescue
    _error -> invalid(:construction_failed)
  catch
    _kind, _reason -> invalid(:construction_failed)
  end

  @doc "Returns the exact payload reference a trusted authority must approve."
  @spec payload_reference(term(), term(), term(), term()) ::
          {:ok, map()} | {:error, Error.t()}
  def payload_reference(proposal, submission, handoff, provider) do
    with {:ok, payload} <- build_payload(proposal, submission, handoff, provider) do
      {:ok, reference(@payload_schema, payload)}
    end
  rescue
    _error -> invalid(:payload_reference_failed)
  catch
    _kind, _reason -> invalid(:payload_reference_failed)
  end

  @doc "Validates canonical structure and content identity, not authority authenticity."
  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = request) do
    wire = to_wire_map(request)

    with true <- Enum.sort(Map.keys(Map.from_struct(request))) == Enum.sort(@fields),
         true <- request.schema == @schema,
         true <- request.kind == "create_human_reviewed_draft",
         {:ok, payload} <- request |> provider_payload() |> validate_payload(),
         {:ok, decision} <- DisclosureDecision.decode_map(request.disclosure_decision),
         true <- decision.payload == reference(@payload_schema, payload),
         true <- decision.provider == request.provider,
         true <- bounded_term?(wire),
         true <- valid_integrity?(request.integrity),
         true <- request.id == "sha256:" <> request.integrity["content_digest"],
         true <- request.integrity["content_digest"] == Canonical.sha256(content(request)),
         encoded <- Canonical.encode(wire),
         {:ok, decoded} <- Jason.decode(encoded),
         true <- decoded == wire,
         true <- byte_size(encoded) <= @maximum_bytes do
      {:ok, request}
    else
      _other -> invalid(:invalid_request)
    end
  rescue
    _error -> invalid(:validation_failed)
  catch
    _kind, _reason -> invalid(:validation_failed)
  end

  def validate(_value), do: invalid(:invalid_value)

  @doc "Recomputes the provider-visible payload from the exact source artifacts."
  @spec validate_with(term(), term(), term(), term(), term()) ::
          {:ok, t()} | {:error, Error.t()}
  def validate_with(request, proposal, submission, handoff, provider) do
    with {:ok, valid} <- validate(request),
         {:ok, expected_payload} <- build_payload(proposal, submission, handoff, provider),
         true <- provider_payload(valid) == expected_payload do
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
  def canonical_binary(request) do
    with {:ok, valid} <- validate(request), do: {:ok, Canonical.encode(to_wire_map(valid))}
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
  def to_wire_map(%__MODULE__{} = request) do
    %{
      "schema" => request.schema,
      "id" => request.id,
      "kind" => request.kind,
      "controls" => request.controls,
      "intent_id" => request.intent_id,
      "idempotency_key" => request.idempotency_key,
      "provider" => request.provider,
      "proposal" => request.proposal,
      "submission" => request.submission,
      "handoff" => request.handoff,
      "disclosure_decision" => request.disclosure_decision,
      "integrity" => request.integrity
    }
  end

  defp build_payload(proposal, submission, handoff, provider) do
    with {:ok, proposal} <- DraftProposal.validate(proposal),
         {:ok, submission} <- CandidateSubmission.validate(submission),
         {:ok, handoff} <- Handoff.validate(handoff),
         {:ok, handoff_bytes} <- Handoff.canonical_binary(handoff),
         {:ok, provider} <- Identity.validate_provider(provider),
         handoff_reference <- handoff_reference(handoff, handoff_bytes),
         true <- submission.handoff == handoff_reference,
         {:ok, candidate} <- CandidateSubmission.candidate(submission),
         {:ok, expected_submission} <- CandidateSubmission.new(handoff, candidate),
         true <-
           CandidateSubmission.to_wire_map(submission) ==
             CandidateSubmission.to_wire_map(expected_submission),
         true <- same_evidence_graph?(proposal, handoff),
         true <- same_candidate?(proposal.evidence["candidate"], submission.candidate) do
      proposal_wire = DraftProposal.to_wire_map(proposal)
      submission_wire = CandidateSubmission.to_wire_map(submission)

      intent_id = intent_id(proposal_wire, submission_wire, submission.candidate, provider)
      idempotency_key = idempotency_key(intent_id)

      payload = %{
        "schema" => @payload_schema,
        "kind" => "create_human_reviewed_draft",
        "controls" => @controls,
        "intent_id" => intent_id,
        "idempotency_key" => idempotency_key,
        "provider" => provider,
        "proposal" => proposal_wire,
        "submission" => submission_wire,
        "handoff" => handoff_reference
      }

      validate_payload(payload)
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> invalid(:source_binding_mismatch)
    end
  end

  defp validate_payload(payload)
       when is_map(payload) and not is_struct(payload) and map_size(payload) == 9 do
    with true <- Enum.sort(Map.keys(payload)) == @payload_keys,
         true <- payload["schema"] == @payload_schema,
         true <- payload["kind"] == "create_human_reviewed_draft",
         true <- payload["controls"] == @controls,
         true <- Identity.provider?(payload["provider"]),
         true <- valid_handoff_reference?(payload["handoff"]),
         {:ok, proposal} <- DraftProposal.decode_map(payload["proposal"]),
         {:ok, submission} <- CandidateSubmission.decode_map(payload["submission"]),
         true <- submission.handoff == payload["handoff"],
         true <- same_candidate?(proposal.evidence["candidate"], submission.candidate),
         expected_intent <-
           intent_id(
             payload["proposal"],
             payload["submission"],
             submission.candidate,
             payload["provider"]
           ),
         true <- payload["intent_id"] == expected_intent,
         true <- payload["idempotency_key"] == idempotency_key(expected_intent),
         true <- bounded_term?(payload),
         encoded <- Canonical.encode(payload),
         {:ok, decoded} <- Jason.decode(encoded),
         true <- decoded == payload,
         true <- byte_size(encoded) <= @maximum_bytes do
      {:ok, payload}
    else
      _other -> invalid(:invalid_payload)
    end
  rescue
    _error -> invalid(:invalid_payload)
  catch
    _kind, _reason -> invalid(:invalid_payload)
  end

  defp validate_payload(_value), do: invalid(:invalid_payload)

  defp intent_id(proposal, submission, candidate, provider) do
    digest =
      Canonical.sha256(%{
        "schema" => @intent_schema,
        "proposal" => proposal,
        "submission" => submission,
        "candidate" => candidate,
        "provider" => provider
      })

    "sha256:" <> digest
  end

  defp idempotency_key(intent_id) do
    digest = Canonical.sha256(%{"schema" => @idempotency_schema, "intent_id" => intent_id})
    "sha256:" <> digest
  end

  defp handoff_reference(handoff, bytes) do
    %{
      "byte_size" => byte_size(bytes),
      "content_sha256" => binary_digest(bytes),
      "id" => handoff.id,
      "schema" => handoff.schema
    }
  end

  defp valid_handoff_reference?(
         %{
           "byte_size" => byte_size,
           "content_sha256" => digest,
           "id" => "sha256:" <> id_digest,
           "schema" => "insider.coding-agent-handoff/v1"
         } = reference
       ) do
    map_size(reference) == 4 and is_integer(byte_size) and
      byte_size in 1..@maximum_handoff_bytes and Input.digest?(digest) and
      Input.digest?(id_digest)
  end

  defp valid_handoff_reference?(_value), do: false

  defp same_candidate?(left, right) when is_map(left) and is_map(right),
    do: Canonical.encode(left) == Canonical.encode(right)

  defp same_candidate?(_left, _right), do: false

  defp same_evidence_graph?(proposal, handoff) do
    matches_reference?(handoff.evidence["capsule"], proposal.sources["capsule"]) and
      matches_reference?(
        handoff.evidence["sentinel_manifest"],
        proposal.sources["sentinel_manifest"]
      )
  end

  defp matches_reference?(wire, reference) when is_map(wire) and is_map(reference) do
    bytes = Canonical.encode(wire)

    reference == %{
      "byte_size" => byte_size(bytes),
      "canonical_sha256" => binary_digest(bytes),
      "id" => wire["id"],
      "schema" => wire["schema"]
    }
  end

  defp matches_reference?(_wire, _reference), do: false

  defp reference(schema, payload) do
    bytes = Canonical.encode(payload)

    %{
      "byte_size" => byte_size(bytes),
      "canonical_sha256" => binary_digest(bytes),
      "schema" => schema
    }
  end

  defp decode_current(wire) do
    if map_size(wire) == length(@wire_keys) and Enum.sort(Map.keys(wire)) == @wire_keys do
      wire
      |> then(fn value ->
        %__MODULE__{
          schema: value["schema"],
          id: value["id"],
          kind: value["kind"],
          controls: value["controls"],
          intent_id: value["intent_id"],
          idempotency_key: value["idempotency_key"],
          provider: value["provider"],
          proposal: value["proposal"],
          submission: value["submission"],
          handoff: value["handoff"],
          disclosure_decision: value["disclosure_decision"],
          integrity: value["integrity"]
        }
      end)
      |> validate()
    else
      invalid(:invalid_envelope)
    end
  end

  defp content(request), do: request |> to_wire_map() |> Map.drop(["id", "integrity"])

  defp provider_payload(request) do
    %{
      "schema" => @payload_schema,
      "kind" => request.kind,
      "controls" => request.controls,
      "intent_id" => request.intent_id,
      "idempotency_key" => request.idempotency_key,
      "provider" => request.provider,
      "proposal" => request.proposal,
      "submission" => request.submission,
      "handoff" => request.handoff
    }
  end

  defp bounded_term?(value) do
    # Nested proposal/submission artifacts enforce their own shape bounds. This
    # envelope adds a detached-term ceiling without rejecting their valid depth.
    :erlang.external_size(value) <= @maximum_term_bytes
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_integrity?(%{"algorithm" => "sha256", "content_digest" => digest} = integrity),
    do: map_size(integrity) == 2 and Input.digest?(digest)

  defp valid_integrity?(_value), do: false
  defp binary_digest(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
  defp normalize_decode({:ingress_error, :limit_exceeded}), do: limit_exceeded()
  defp normalize_decode({:ingress_error, reason}), do: invalid(reason)
  defp normalize_decode(result), do: result

  defp invalid(reason),
    do:
      {:error,
       Error.new(:invalid_draft_creation_request, "draft-creation request is invalid", %{
         reason: reason
       })}

  defp integrity_failed,
    do:
      {:error,
       Error.new(
         :draft_creation_request_integrity_failed,
         "draft-creation request does not match the supplied evidence"
       )}

  defp limit_exceeded,
    do:
      {:error,
       Error.new(
         :draft_creation_request_limit_exceeded,
         "draft-creation request exceeds its limit"
       )}

  defp unsupported_schema(schema),
    do:
      {:error,
       Error.new(
         :unsupported_draft_creation_request_schema,
         "draft-creation request schema is unsupported",
         %{schema: Value.summary(schema)}
       )}
end

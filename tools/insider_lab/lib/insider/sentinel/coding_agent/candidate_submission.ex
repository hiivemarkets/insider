defmodule Insider.Sentinel.CodingAgent.CandidateSubmission do
  @moduledoc """
  A bounded, inert candidate returned for independent verification.

  This artifact binds existing `Verification.Candidate` data to one exact
  coding-agent handoff. It does not apply the candidate and cannot claim that
  the candidate repairs anything.
  """

  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value
  alias Insider.Sentinel.CodingAgent.Handoff
  alias Insider.Sentinel.Verification.Candidate
  alias Insider.Sentinel.Verification.Ingress

  @schema "insider.coding-agent-candidate-submission/v1"
  @maximum_bytes 32_768
  @maximum_term_bytes 65_536
  @fields [:schema, :id, :kind, :controls, :status, :handoff, :candidate, :integrity]
  @wire_keys @fields |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  @controls %{
    "application" => "none",
    "deploy" => "prohibited",
    "disclosure" => "unattested",
    "merge" => "prohibited",
    "network_effect" => "none",
    "provider_creation" => "blocked",
    "publication" => "blocked",
    "repository_mutation" => "none",
    "verification" => "required"
  }
  @status %{
    "candidate" => "declared_unverified",
    "draft_eligible" => false,
    "repair_claim" => "none"
  }

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(handoff, candidate) do
    with {:ok, handoff} <- Handoff.validate(handoff),
         {:ok, handoff_bytes} <- Handoff.canonical_binary(handoff),
         {:ok, candidate} <- Candidate.validate(candidate) do
      body = %{
        "schema" => @schema,
        "kind" => "inert_candidate_submission",
        "controls" => @controls,
        "status" => @status,
        "handoff" => reference(handoff.schema, handoff.id, handoff_bytes),
        "candidate" => Candidate.to_wire_map(candidate)
      }

      digest = Canonical.sha256(body)

      body
      |> Map.merge(%{
        "id" => "sha256:" <> digest,
        "integrity" => %{"algorithm" => "sha256", "content_digest" => digest}
      })
      |> decode_map()
    end
  rescue
    _error -> invalid(:construction_failed)
  catch
    _kind, _reason -> invalid(:construction_failed)
  end

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = submission) do
    wire = to_wire_map(submission)

    with true <- Enum.sort(Map.keys(Map.from_struct(submission))) == Enum.sort(@fields),
         true <- submission.schema == @schema,
         true <- submission.kind == "inert_candidate_submission",
         true <- submission.controls == @controls,
         true <- submission.status == @status,
         true <- valid_reference?(submission.handoff),
         {:ok, _candidate} <- Candidate.decode_map(submission.candidate),
         true <- Value.bounded_data?(wire, @maximum_term_bytes),
         true <- valid_integrity?(submission.integrity),
         true <- submission.id == "sha256:" <> submission.integrity["content_digest"],
         true <- submission.integrity["content_digest"] == Canonical.sha256(content(submission)),
         encoded <- Canonical.encode(wire),
         {:ok, decoded} <- Jason.decode(encoded),
         true <- decoded == wire,
         true <- byte_size(encoded) <= @maximum_bytes do
      {:ok, submission}
    else
      _other -> invalid(:invalid_submission)
    end
  rescue
    _error -> invalid(:validation_failed)
  catch
    _kind, _reason -> invalid(:validation_failed)
  end

  def validate(_value), do: invalid(:invalid_value)

  @doc "Revalidates the exact handoff graph and candidate binding."
  @spec validate_with_evidence(term(), term(), term(), term(), term(), term(), term()) ::
          {:ok, t()} | {:error, Error.t()}
  def validate_with_evidence(
        submission,
        handoff,
        candidate,
        capsule,
        manifest,
        regression,
        confirmation_runs
      ) do
    with {:ok, valid_handoff} <-
           Handoff.validate_with_evidence(
             handoff,
             capsule,
             manifest,
             regression,
             confirmation_runs
           ),
         {:ok, valid} <- validate(submission),
         {:ok, expected} <- new(valid_handoff, candidate),
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

  @spec candidate(term()) :: {:ok, Candidate.t()} | {:error, Error.t()}
  def candidate(submission) do
    with {:ok, valid} <- validate(submission), do: Candidate.decode_map(valid.candidate)
  end

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(submission) do
    with {:ok, valid} <- validate(submission), do: {:ok, Canonical.encode(to_wire_map(valid))}
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
  def to_wire_map(%__MODULE__{} = submission),
    do: %{
      "schema" => submission.schema,
      "id" => submission.id,
      "kind" => submission.kind,
      "controls" => submission.controls,
      "status" => submission.status,
      "handoff" => submission.handoff,
      "candidate" => submission.candidate,
      "integrity" => submission.integrity
    }

  defp decode_current(wire) do
    if Enum.sort(Map.keys(wire)) == @wire_keys do
      wire
      |> then(fn value ->
        %__MODULE__{
          schema: value["schema"],
          id: value["id"],
          kind: value["kind"],
          controls: value["controls"],
          status: value["status"],
          handoff: value["handoff"],
          candidate: value["candidate"],
          integrity: value["integrity"]
        }
      end)
      |> validate()
    else
      invalid(:invalid_envelope)
    end
  end

  defp reference(schema, id, bytes),
    do: %{
      "byte_size" => byte_size(bytes),
      "content_sha256" => binary_digest(bytes),
      "id" => id,
      "schema" => schema
    }

  defp valid_reference?(
         %{
           "byte_size" => byte_size,
           "content_sha256" => digest,
           "id" => "sha256:" <> id_digest,
           "schema" => "insider.coding-agent-handoff/v1"
         } = reference
       ),
       do:
         map_size(reference) == 4 and is_integer(byte_size) and byte_size in 1..1_572_864 and
           digest?(digest) and digest?(id_digest)

  defp valid_reference?(_value), do: false
  defp content(submission), do: submission |> to_wire_map() |> Map.drop(["id", "integrity"])

  defp valid_integrity?(%{"algorithm" => "sha256", "content_digest" => digest} = value),
    do: map_size(value) == 2 and digest?(digest)

  defp valid_integrity?(_value), do: false

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp digest?(_value), do: false
  defp binary_digest(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
  defp normalize_decode({:ingress_error, :limit_exceeded}), do: limit_exceeded()
  defp normalize_decode({:ingress_error, reason}), do: invalid(reason)
  defp normalize_decode(result), do: result

  defp invalid(reason),
    do:
      {:error,
       Error.new(:invalid_candidate_submission, "coding-agent candidate submission is invalid", %{
         reason: reason
       })}

  defp integrity_failed,
    do:
      {:error,
       Error.new(:candidate_submission_integrity_failed, "candidate submission evidence differs")}

  defp limit_exceeded,
    do:
      {:error,
       Error.new(:candidate_submission_limit_exceeded, "candidate submission exceeds its limit")}

  defp unsupported_schema(schema),
    do:
      {:error,
       Error.new(
         :unsupported_candidate_submission_schema,
         "candidate submission schema is unsupported",
         %{
           schema: Value.summary(schema)
         }
       )}
end

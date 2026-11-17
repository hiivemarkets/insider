defmodule Insider.Sentinel.DraftProposal do
  @moduledoc """
  A canonical, side-effect-free proposal derived from exact repair evidence.

  The artifact is suitable for local agent handoff only. It grants no repository,
  network, provider, merge, or deployment authority. Publication remains blocked
  because candidate and verification disclosure have not been attested.
  """

  alias Insider.Event.Canonical
  alias Insider.Detectors.Input
  alias Insider.Incident.Capsule
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value
  alias Insider.Sentinel.Manifest, as: SentinelManifest
  alias Insider.Sentinel.RepairReport.Manifest, as: RepairReportManifest
  alias Insider.Sentinel.Verification.Record, as: VerificationRecord
  alias Insider.Sentinel.Verification.Ingress

  @schema "insider.draft-proposal/v1"
  @maximum_bytes 131_072
  @maximum_term_bytes 262_144
  @fields [
    :schema,
    :id,
    :kind,
    :controls,
    :eligibility,
    :disclosure,
    :sources,
    :evidence,
    :matrix,
    :integrity
  ]
  @wire_keys @fields |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  @source_keys ~w(capsule repair_report sentinel_manifest verification_record)
  @controls %{
    "draft" => true,
    "merge_prohibited" => true,
    "network_effect" => "none",
    "repository_mutation" => "none",
    "review_required" => true
  }
  @eligibility %{
    "evidence" => "eligible",
    "provider_creation" => "blocked",
    "publication" => "blocked",
    "reasons" => ["candidate_disclosure_attestation_missing"]
  }
  @disclosure %{
    "attestation_id" => nil,
    "candidate" => "unattested",
    "status" => "missing",
    "verification" => "unattested"
  }

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec new(term(), term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(capsule, sentinel_manifest, verification, repair_report) do
    with {:ok, capsule} <- Capsule.validate(capsule),
         {:ok, sentinel_manifest} <-
           SentinelManifest.validate_with_capsule(sentinel_manifest, capsule),
         {:ok, verification} <- VerificationRecord.validate(verification),
         {:ok, repair_report} <-
           RepairReportManifest.validate_with_evidence(
             repair_report,
             capsule,
             sentinel_manifest,
             verification
           ),
         [] <- ineligible_reasons(repair_report, verification),
         {:ok, sources} <- source_refs(capsule, sentinel_manifest, verification, repair_report) do
      body = %{
        "schema" => @schema,
        "kind" => "offline_draft_pr_proposal",
        "controls" => @controls,
        "eligibility" => @eligibility,
        "disclosure" => @disclosure,
        "sources" => sources,
        "evidence" => evidence(repair_report),
        "matrix" => repair_report.matrix
      }

      digest = Canonical.sha256(body)

      body
      |> Map.merge(%{
        "id" => "sha256:" <> digest,
        "integrity" => %{"algorithm" => "sha256", "content_digest" => digest}
      })
      |> from_wire()
      |> validate()
    else
      reasons when is_list(reasons) -> ineligible(reasons)
      {:error, %Error{} = error} -> {:error, error}
    end
  rescue
    _error -> invalid(:construction_failed)
  catch
    _kind, _reason -> invalid(:construction_failed)
  end

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = proposal) do
    wire = to_wire_map(proposal)

    with true <- Enum.sort(Map.keys(Map.from_struct(proposal))) == Enum.sort(@fields),
         true <- proposal.schema == @schema,
         true <- proposal.kind == "offline_draft_pr_proposal",
         true <- proposal.controls == @controls,
         true <- proposal.eligibility == @eligibility,
         true <- proposal.disclosure == @disclosure,
         true <- valid_sources?(proposal.sources),
         true <- valid_evidence?(proposal.evidence),
         true <- valid_matrix?(proposal.matrix),
         true <- Value.bounded_data?(wire, @maximum_term_bytes),
         true <- valid_integrity?(proposal.integrity),
         true <- proposal.id == "sha256:" <> proposal.integrity["content_digest"],
         true <- proposal.integrity["content_digest"] == Canonical.sha256(content(proposal)),
         encoded <- Canonical.encode(wire),
         {:ok, decoded} <- Jason.decode(encoded),
         true <- decoded == wire,
         true <- byte_size(encoded) <= @maximum_bytes do
      {:ok, proposal}
    else
      _other -> invalid(:invalid_proposal)
    end
  rescue
    _error -> invalid(:validation_failed)
  catch
    _kind, _reason -> invalid(:validation_failed)
  end

  def validate(_value), do: invalid(:invalid_value)

  @doc "Recomputes a proposal from the exact evidence graph before accepting it."
  @spec validate_with_evidence(term(), term(), term(), term(), term()) ::
          {:ok, t()} | {:error, Error.t()}
  def validate_with_evidence(proposal, capsule, sentinel_manifest, verification, repair_report) do
    with {:ok, valid} <- validate(proposal),
         {:ok, expected} <- new(capsule, sentinel_manifest, verification, repair_report),
         true <- to_wire_map(valid) == to_wire_map(expected) do
      {:ok, valid}
    else
      {:error, %Error{code: :draft_proposal_ineligible} = error} -> {:error, error}
      _other -> integrity_failed()
    end
  rescue
    _error -> integrity_failed()
  catch
    _kind, _reason -> integrity_failed()
  end

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(proposal) do
    case validate(proposal) do
      {:ok, valid} -> {:ok, Canonical.encode(to_wire_map(valid))}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec decode(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode(value) do
    value
    |> Ingress.canonical_decode(@maximum_bytes, &decode_map/1)
    |> decode_result()
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
  def to_wire_map(%__MODULE__{} = proposal),
    do: %{
      "schema" => proposal.schema,
      "id" => proposal.id,
      "kind" => proposal.kind,
      "controls" => proposal.controls,
      "eligibility" => proposal.eligibility,
      "disclosure" => proposal.disclosure,
      "sources" => proposal.sources,
      "evidence" => proposal.evidence,
      "matrix" => proposal.matrix,
      "integrity" => proposal.integrity
    }

  defp ineligible_reasons(report, verification) do
    matrix = report.matrix

    []
    |> reason_unless(verification.status == "verified", "verification_not_verified")
    |> reason_unless(verification.reasons == [], "verification_has_reasons")
    |> reason_unless(
      report.verdict == %{"reasons" => [], "status" => "verified"},
      "report_not_verified"
    )
    |> reason_unless(
      verification.executor_counts == %{"active" => 0, "quarantined" => 0},
      "executor_not_clean"
    )
    |> reason_unless(matrix_phases?(matrix), "replay_matrix_invalid")
    |> reason_unless(matrix_evidence_complete?(matrix), "evidence_incomplete")
    |> reason_unless(matrix_cleanup_complete?(matrix), "cleanup_incomplete")
    |> reason_unless(matrix_findings_match?(matrix), "replay_outcome_mismatch")
    |> reason_unless(after_gates_passed?(matrix), "verification_gate_failed")
    |> reason_unless(provenance_matches?(report.provenance), "provenance_mismatch")
    |> Enum.sort()
  end

  defp reason_unless(reasons, true, _reason), do: reasons
  defp reason_unless(reasons, false, reason), do: [reason | reasons]

  defp matrix_phases?(matrix),
    do: Enum.map(matrix, & &1["phase"]) == ~w(source before before after after)

  defp matrix_evidence_complete?(matrix),
    do: Enum.all?(matrix, &(&1["operational"] == "completed" and &1["evidence"] == "complete"))

  defp matrix_cleanup_complete?(matrix) do
    Enum.all?(matrix, fn row ->
      row["cleanup"] == "complete" and
        row["cleanup_release"] in ["complete", "failed"] and
        row["cleanup_remaining_count"] == 0 and
        is_nil(row["cleanup_remaining_fingerprint"])
    end)
  end

  defp matrix_findings_match?(matrix) do
    Enum.all?(Enum.take(matrix, 3), &(&1["finding"] == "observed")) and
      Enum.all?(Enum.drop(matrix, 3), &(&1["finding"] == "absent"))
  end

  defp after_gates_passed?(matrix),
    do: Enum.all?(Enum.drop(matrix, 3), &(&1["gates"] == "passed"))

  defp provenance_matches?(%{"comparison" => comparison}) do
    get_in(comparison, ["code", "status"]) == "changed" and
      Enum.all?(~w(configuration dependencies runtime target), fn component ->
        get_in(comparison, [component, "status"]) == "same"
      end)
  end

  defp provenance_matches?(_value), do: false

  defp evidence(report) do
    %{
      "candidate" => report.diffs["candidate"],
      "finding" => report.causal_summary["finding"],
      "verdict" => report.verdict
    }
  end

  defp source_refs(capsule, sentinel_manifest, verification, repair_report) do
    with {:ok, capsule_bytes} <- Capsule.canonical_binary(capsule),
         {:ok, manifest_bytes} <- SentinelManifest.canonical_binary(sentinel_manifest),
         {:ok, verification_bytes} <- VerificationRecord.canonical_binary(verification),
         {:ok, report_bytes} <- RepairReportManifest.canonical_binary(repair_report) do
      {:ok,
       %{
         "capsule" => reference(capsule, capsule_bytes),
         "repair_report" => reference(repair_report, report_bytes),
         "sentinel_manifest" => reference(sentinel_manifest, manifest_bytes),
         "verification_record" => reference(verification, verification_bytes)
       }}
    end
  end

  defp reference(artifact, bytes),
    do: %{
      "byte_size" => byte_size(bytes),
      "canonical_sha256" => Canonical.sha256_binary(bytes),
      "id" => artifact.id,
      "schema" => artifact.schema
    }

  defp valid_sources?(sources) when is_map(sources) and map_size(sources) == 4 do
    Enum.sort(Map.keys(sources)) == @source_keys and
      Enum.all?(sources, fn {_name, ref} -> valid_ref?(ref) end)
  end

  defp valid_sources?(_value), do: false

  defp valid_ref?(
         %{
           "byte_size" => bytes,
           "canonical_sha256" => digest,
           "id" => "sha256:" <> id_digest,
           "schema" => schema
         } = ref
       ),
       do:
         map_size(ref) == 4 and is_integer(bytes) and bytes > 0 and digest?(digest) and
           Input.digest?(id_digest) and is_binary(schema) and byte_size(schema) in 1..128

  defp valid_ref?(_value), do: false

  defp valid_evidence?(
         %{
           "candidate" => candidate,
           "finding" => finding,
           "verdict" => %{"reasons" => [], "status" => "verified"}
         } = evidence
       ),
       do:
         map_size(evidence) == 3 and is_map(candidate) and is_map(finding) and
           is_binary(candidate["id"]) and is_binary(finding["fingerprint"])

  defp valid_evidence?(_value), do: false

  defp valid_matrix?([_, _, _, _, _] = matrix) do
    matrix_phases?(matrix) and matrix_evidence_complete?(matrix) and
      matrix_cleanup_complete?(matrix) and matrix_findings_match?(matrix) and
      after_gates_passed?(matrix)
  end

  defp valid_matrix?(_value), do: false

  defp decode_result({:ingress_error, :limit_exceeded}), do: limit_exceeded()
  defp decode_result({:ingress_error, reason}), do: invalid(reason)
  defp decode_result(result), do: result

  defp decode_current(wire) do
    if map_size(wire) == length(@wire_keys) and Enum.sort(Map.keys(wire)) == @wire_keys,
      do: wire |> from_wire() |> validate(),
      else: invalid(:invalid_envelope)
  end

  defp from_wire(wire) do
    %__MODULE__{
      schema: wire["schema"],
      id: wire["id"],
      kind: wire["kind"],
      controls: wire["controls"],
      eligibility: wire["eligibility"],
      disclosure: wire["disclosure"],
      sources: wire["sources"],
      evidence: wire["evidence"],
      matrix: wire["matrix"],
      integrity: wire["integrity"]
    }
  end

  defp content(proposal) do
    Map.take(
      to_wire_map(proposal),
      ~w(controls disclosure eligibility evidence kind matrix schema sources)
    )
  end

  defp valid_integrity?(integrity) do
    case integrity do
      %{"algorithm" => "sha256", "content_digest" => digest}
      when map_size(integrity) == 2 ->
        digest?(digest)

      _other ->
        false
    end
  end

  defp digest?(value), do: Input.digest?(value)

  defp invalid(reason),
    do:
      {:error, Error.new(:invalid_draft_proposal, "draft proposal is invalid", %{reason: reason})}

  defp ineligible(reasons),
    do:
      {:error,
       Error.new(
         :draft_proposal_ineligible,
         "repair evidence is not eligible for a draft proposal",
         %{
           reasons: reasons
         }
       )}

  defp integrity_failed,
    do:
      {:error,
       Error.new(
         :draft_proposal_integrity_failed,
         "draft proposal does not match the supplied evidence"
       )}

  defp limit_exceeded,
    do:
      {:error,
       Error.new(:draft_proposal_limit_exceeded, "draft proposal exceeds its static limit")}

  defp unsupported_schema(schema),
    do:
      {:error,
       Error.new(:unsupported_draft_proposal_schema, "draft proposal schema is unsupported", %{
         schema: Value.summary(schema)
       })}
end

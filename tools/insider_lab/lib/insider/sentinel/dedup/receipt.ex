defmodule Insider.Sentinel.Dedup.Receipt do
  @moduledoc """
  A privacy-minimal, canonical outcome record for offline Sentinel deduplication.

  A receipt retains only content-addressed artifact references, a hashed group
  identifier, a bounded evidence-byte total, and bounded accepted-artifact
  counters. It never embeds a capsule, proposal, candidate diff, finding
  payload, or caller-supplied secret-capable data.
  """

  alias Insider.Detectors.Input
  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value
  alias Insider.Sentinel.Verification.Ingress

  @schema "insider.dedup-receipt/v1"
  @maximum_bytes 8_192
  @maximum_term_bytes 16_384
  @fields [
    :schema,
    :id,
    :outcome,
    :capacity,
    :group,
    :artifacts,
    :evidence_bytes,
    :counts,
    :integrity
  ]
  @wire_keys @fields |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  @outcomes ["new_evidence", "duplicate", "capacity_refused"]
  @capacity ["none", "groups", "artifacts_per_group", "receipts", "retained_bytes"]
  @maximum_capsule_bytes 1_048_576
  @maximum_proposal_bytes 131_072
  # The complete proposal graph has three required, nonempty canonical documents.
  # These maxima mirror SentinelManifest, Verification.Record, and RepairReport.Manifest.
  @maximum_manifest_bytes 65_536
  @maximum_verification_bytes 262_144
  @maximum_repair_report_bytes 262_144
  @minimum_required_graph_bytes 3
  @maximum_required_graph_bytes @maximum_manifest_bytes + @maximum_verification_bytes +
                                  @maximum_repair_report_bytes
  @maximum_accepted_artifacts 4_096
  @maximum_artifacts_per_group 32
  @maximum_groups 128
  @maximum_retained_bytes 16_777_216
  @maximum_evidence_bytes 2_097_152

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         true <- Keyword.keys(options) == Enum.uniq(Keyword.keys(options)),
         true <-
           Enum.sort(Keyword.keys(options)) == Enum.sort(@fields -- [:schema, :id, :integrity]),
         body <- %{
           "schema" => @schema,
           "outcome" => Keyword.fetch!(options, :outcome),
           "capacity" => Keyword.fetch!(options, :capacity),
           "group" => Keyword.fetch!(options, :group),
           "artifacts" => Keyword.fetch!(options, :artifacts),
           "evidence_bytes" => Keyword.fetch!(options, :evidence_bytes),
           "counts" => Keyword.fetch!(options, :counts)
         },
         digest <- Canonical.sha256(body) do
      body
      |> Map.merge(%{
        "id" => "sha256:" <> digest,
        "integrity" => %{"algorithm" => "sha256", "content_digest" => digest}
      })
      |> decode_map()
    else
      _other -> invalid(:construction_failed)
    end
  rescue
    _error -> invalid(:construction_failed)
  catch
    _kind, _reason -> invalid(:construction_failed)
  end

  def new(_options), do: invalid(:invalid_options)

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = receipt) do
    wire = to_wire_map(receipt)

    with true <- Enum.sort(Map.keys(Map.from_struct(receipt))) == Enum.sort(@fields),
         true <- receipt.schema == @schema,
         true <- receipt.outcome in @outcomes,
         true <- valid_capacity?(receipt.outcome, receipt.capacity),
         true <- digest_id?(receipt.group),
         true <- valid_artifacts?(receipt.artifacts),
         true <- valid_evidence_bytes?(receipt.evidence_bytes, receipt.artifacts),
         true <- valid_counts?(receipt.counts),
         true <-
           valid_outcome_counts?(
             receipt.outcome,
             receipt.capacity,
             receipt.artifacts,
             receipt.evidence_bytes,
             receipt.counts
           ),
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
  def to_wire_map(%__MODULE__{} = receipt) do
    %{
      "schema" => receipt.schema,
      "id" => receipt.id,
      "outcome" => receipt.outcome,
      "capacity" => receipt.capacity,
      "group" => receipt.group,
      "artifacts" => receipt.artifacts,
      "evidence_bytes" => receipt.evidence_bytes,
      "counts" => receipt.counts,
      "integrity" => receipt.integrity
    }
  end

  @doc false
  @spec artifact_reference?(term()) :: boolean()
  def artifact_reference?(
        %{
          "byte_size" => bytes,
          "canonical_sha256" => canonical_sha256,
          "id" => "sha256:" <> id_digest,
          "schema" => schema
        } = reference
      ) do
    map_size(reference) == 4 and is_integer(bytes) and bytes > 0 and digest?(canonical_sha256) and
      Input.digest?(id_digest) and is_binary(schema) and byte_size(schema) in 1..128
  end

  def artifact_reference?(_value), do: false

  defp artifact_reference?(reference, schema, maximum_bytes) do
    artifact_reference?(reference) and reference["schema"] == schema and
      reference["byte_size"] <= maximum_bytes
  end

  defp valid_capacity?("capacity_refused", capacity), do: capacity in (@capacity -- ["none"])
  defp valid_capacity?(outcome, "none"), do: outcome in (@outcomes -- ["capacity_refused"])
  defp valid_capacity?(_outcome, _capacity), do: false

  defp valid_artifacts?(%{"capsule" => capsule, "proposal" => nil} = artifacts),
    do:
      map_size(artifacts) == 2 and
        artifact_reference?(capsule, "insider.incident-capsule/v1", @maximum_capsule_bytes)

  defp valid_artifacts?(%{"capsule" => capsule, "proposal" => proposal} = artifacts),
    do:
      map_size(artifacts) == 2 and
        artifact_reference?(capsule, "insider.incident-capsule/v1", @maximum_capsule_bytes) and
        artifact_reference?(proposal, "insider.draft-proposal/v1", @maximum_proposal_bytes)

  defp valid_artifacts?(_value), do: false

  # This scalar is the total canonical evidence bound to the receipt's
  # artifact: a capsule alone, or its capsule plus the complete proposal
  # evidence graph. It exposes no evidence contents or extra references.
  defp valid_evidence_bytes?(evidence_bytes, %{"capsule" => capsule, "proposal" => nil}),
    do:
      is_integer(evidence_bytes) and evidence_bytes == capsule["byte_size"] and
        evidence_bytes <= @maximum_evidence_bytes

  defp valid_evidence_bytes?(evidence_bytes, %{"capsule" => capsule, "proposal" => proposal}),
    do:
      is_integer(evidence_bytes) and
        evidence_bytes in (capsule["byte_size"] + proposal["byte_size"] +
                             @minimum_required_graph_bytes)..(capsule["byte_size"] +
                                                                proposal["byte_size"] +
                                                                @maximum_required_graph_bytes) and
        evidence_bytes <= @maximum_evidence_bytes

  defp valid_evidence_bytes?(_value, _artifacts), do: false

  defp valid_counts?(
         %{
           "accepted_artifacts" => accepted,
           "artifacts_in_group" => artifacts,
           "groups" => groups,
           "retained_bytes" => retained_bytes
         } =
           counts
       ),
       do:
         map_size(counts) == 4 and accepted in 0..@maximum_accepted_artifacts and
           artifacts in 0..@maximum_artifacts_per_group and groups in 0..@maximum_groups and
           retained_bytes in 0..@maximum_retained_bytes and artifacts <= accepted and
           groups <= accepted and retained_bytes >= accepted

  defp valid_counts?(_value), do: false

  defp valid_outcome_counts?(outcome, capacity, artifact_refs, evidence_bytes, counts) do
    accepted = counts["accepted_artifacts"]
    artifacts_in_group = counts["artifacts_in_group"]
    groups = counts["groups"]
    retained_bytes = counts["retained_bytes"]
    capsule_bytes = artifact_refs["capsule"]["byte_size"]
    proposal? = is_map(artifact_refs["proposal"])

    case {outcome, capacity} do
      {outcome, "none"} when outcome in ["new_evidence", "duplicate"] ->
        if proposal?,
          do:
            accepted >= 2 and artifacts_in_group >= 2 and groups >= 1 and
              retained_bytes >= evidence_bytes,
          else:
            accepted >= 1 and artifacts_in_group >= 1 and groups >= 1 and
              retained_bytes >= evidence_bytes

      {"capacity_refused", "groups"} ->
        not proposal? and accepted >= 1 and artifacts_in_group == 0 and groups >= 1

      {"capacity_refused", "artifacts_per_group"} ->
        accepted >= 1 and artifacts_in_group >= 1 and groups >= 1 and
          (not proposal? or retained_bytes >= capsule_bytes)

      {"capacity_refused", "receipts"} ->
        accepted >= 1 and groups >= 1 and
          (not proposal? or (artifacts_in_group >= 1 and retained_bytes >= capsule_bytes))

      {"capacity_refused", "retained_bytes"} ->
        if proposal?,
          do:
            accepted >= 1 and artifacts_in_group >= 1 and groups >= 1 and
              retained_bytes >= capsule_bytes,
          else: true

      _other ->
        false
    end
  end

  defp valid_integrity?(%{"algorithm" => "sha256", "content_digest" => digest} = integrity),
    do: map_size(integrity) == 2 and digest?(digest)

  defp valid_integrity?(_value), do: false

  defp digest_id?("sha256:" <> digest), do: digest?(digest)
  defp digest_id?(_value), do: false
  defp digest?(value), do: Input.digest?(value)

  defp content(receipt), do: receipt |> to_wire_map() |> Map.drop(~w(id integrity))

  defp decode_current(wire) do
    if map_size(wire) == length(@wire_keys) and Enum.sort(Map.keys(wire)) == @wire_keys do
      %__MODULE__{
        schema: wire["schema"],
        id: wire["id"],
        outcome: wire["outcome"],
        capacity: wire["capacity"],
        group: wire["group"],
        artifacts: wire["artifacts"],
        evidence_bytes: wire["evidence_bytes"],
        counts: wire["counts"],
        integrity: wire["integrity"]
      }
      |> validate()
    else
      invalid(:invalid_envelope)
    end
  end

  defp normalize_decode({:ingress_error, :limit_exceeded}), do: limit_exceeded()
  defp normalize_decode({:ingress_error, reason}), do: invalid(reason)
  defp normalize_decode(result), do: result

  defp invalid(reason),
    do: {:error, Error.new(:invalid_dedup_receipt, "dedup receipt is invalid", %{reason: reason})}

  defp limit_exceeded,
    do:
      {:error, Error.new(:dedup_receipt_limit_exceeded, "dedup receipt exceeds its static limit")}

  defp unsupported_schema(schema),
    do:
      {:error,
       Error.new(:unsupported_dedup_receipt_schema, "dedup receipt schema is unsupported", %{
         schema: Value.summary(schema)
       })}
end

defmodule Insider.Sentinel.Confirmation.Record do
  @moduledoc "A bounded, content-addressed result of one clean-target confirmation run."

  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Protocol.StrictOptions
  alias Insider.Event.Value
  alias Insider.Sentinel.ExternalProcess.Receipt, as: ExternalReceipt

  @schema "insider.confirmation-record/v1"
  @external_schema "insider.confirmation-record/v2"
  @outcomes [
    "infrastructure_failure",
    "matching_failure",
    "nonreproduced",
    "repaired",
    "unrelated_failure"
  ]
  @operational_statuses ["cancelled", "completed", "error", "timeout"]
  @keys [
    "capsule_id",
    "cleanup",
    "confirmed",
    "evidence",
    "expected_fingerprint",
    "id",
    "integrity",
    "manifest_id",
    "observed_fingerprints",
    "observed_target_fingerprint",
    "operational_reason",
    "operational_status",
    "outcome",
    "outcome_reason",
    "requested_target_fingerprint",
    "scenario_id",
    "schema",
    "uncertainty"
  ]
  @maximum_bytes 16_384
  @option_keys [
    :capsule_id,
    :cleanup,
    :confirmed,
    :evidence,
    :expected_fingerprint,
    :manifest_id,
    :observed_fingerprints,
    :observed_target_fingerprint,
    :operational_reason,
    :operational_status,
    :outcome,
    :outcome_reason,
    :requested_target_fingerprint,
    :scenario_id,
    :uncertainty
  ]

  @fields Enum.map(@keys, &String.to_atom/1)
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options), do: StrictOptions.build(options, @option_keys, &build/1, &invalid/1)

  defp build(options) do
    evidence = Keyword.get(options, :evidence)

    content = %{
      "schema" =>
        if(is_map(evidence) and Map.has_key?(evidence, "external_execution"),
          do: @external_schema,
          else: @schema
        ),
      "manifest_id" => Keyword.get(options, :manifest_id),
      "capsule_id" => Keyword.get(options, :capsule_id),
      "scenario_id" => Keyword.get(options, :scenario_id),
      "requested_target_fingerprint" => Keyword.get(options, :requested_target_fingerprint),
      "observed_target_fingerprint" => Keyword.get(options, :observed_target_fingerprint),
      "operational_status" => Keyword.get(options, :operational_status),
      "operational_reason" => Keyword.get(options, :operational_reason),
      "outcome" => Keyword.get(options, :outcome),
      "confirmed" => Keyword.fetch!(options, :confirmed),
      "expected_fingerprint" => Keyword.get(options, :expected_fingerprint),
      "observed_fingerprints" => Keyword.get(options, :observed_fingerprints, []),
      "evidence" => evidence,
      "cleanup" => Keyword.get(options, :cleanup),
      "outcome_reason" => Keyword.get(options, :outcome_reason),
      "uncertainty" => Keyword.get(options, :uncertainty, [])
    }

    digest = hash(content)

    from_wire(
      Map.merge(content, %{
        "id" => "sha256:" <> digest,
        "integrity" => %{"algorithm" => "sha256", "content_digest" => digest}
      })
    )
  end

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = record) do
    wire = to_wire_map(record)
    digest = record.integrity["content_digest"]

    if exact_struct?(record) and valid_wire?(wire) and
         record.id == "sha256:" <> digest and
         digest == hash(Map.drop(wire, ["id", "integrity"])) and
         byte_size(Canonical.encode(wire)) <= @maximum_bytes do
      {:ok, record}
    else
      invalid(:invalid_record)
    end
  rescue
    _error -> invalid(:validation_failed)
  end

  def validate(_record), do: invalid(:invalid_record)

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(record) do
    with {:ok, valid} <- validate(record), do: {:ok, Canonical.encode(to_wire_map(valid))}
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(binary) when is_binary(binary) and byte_size(binary) <= @maximum_bytes do
    with {:ok, wire} <- Jason.decode(binary),
         true <- Canonical.encode(wire) == binary,
         {:ok, record} <- decode_map(wire) do
      {:ok, record}
    else
      false -> invalid(:noncanonical_encoding)
      {:error, %Jason.DecodeError{}} -> invalid(:invalid_json)
      {:error, %Error{} = error} -> {:error, error}
    end
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode(binary) when is_binary(binary), do: limit_exceeded()
  def decode(_binary), do: invalid(:invalid_encoding)

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(%{"schema" => schema}) when schema not in [@schema, @external_schema],
    do: unsupported_schema(schema)

  def decode_map(%{"schema" => schema} = wire) when schema in [@schema, @external_schema],
    do: from_wire(wire)

  def decode_map(wire) when is_map(wire) and not is_struct(wire), do: unsupported_schema(nil)
  def decode_map(_wire), do: invalid(:invalid_value)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = record) do
    record
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp from_wire(wire) when is_map(wire) and not is_struct(wire) do
    if map_size(wire) == length(@keys) and Enum.sort(Map.keys(wire)) == @keys do
      record =
        struct!(
          __MODULE__,
          Map.new(wire, fn {key, value} -> {String.to_existing_atom(key), value} end)
        )

      validate(record)
    else
      invalid(:invalid_envelope)
    end
  end

  defp from_wire(_wire), do: invalid(:invalid_envelope)

  defp valid_wire?(wire) do
    expected = wire["expected_fingerprint"]
    observed = wire["observed_fingerprints"]
    evidence = wire["evidence"]
    cleanup = wire["cleanup"]

    wire["schema"] in [@schema, @external_schema] and id?(wire["id"]) and id?(wire["manifest_id"]) and
      id?(wire["capsule_id"]) and id?(wire["scenario_id"]) and
      valid_integrity?(wire["integrity"]) and
      digest?(wire["requested_target_fingerprint"]) and
      optional_digest?(wire["observed_target_fingerprint"]) and
      digest?(expected) and wire["operational_status"] in @operational_statuses and
      valid_operational_reason?(wire["operational_status"], wire["operational_reason"]) and
      wire["outcome"] in @outcomes and is_boolean(wire["confirmed"]) and
      Value.valid_list?(observed, 16, 2_048) and Enum.all?(observed, &digest?/1) and
      observed == Enum.sort(observed) and observed == Enum.uniq(observed) and
      valid_evidence?(evidence, wire["schema"], wire) and valid_cleanup?(cleanup) and
      evidence_cleanup_coherent?(evidence, cleanup) and
      valid_outcome_reason?(wire["outcome_reason"]) and
      Value.valid_list?(wire["uncertainty"], 16, 4_096) and
      Enum.all?(wire["uncertainty"], &is_binary/1) and confirmation_coherent?(wire)
  end

  defp valid_evidence?(
         %{
           "lease_execution" => lease_execution,
           "armed_before_scenario" => armed_before_scenario,
           "complete" => complete,
           "dropped" => dropped,
           "finalized_after_scenario" => finalized_after_scenario,
           "gaps" => gaps,
           "observation_run_fingerprint" => observation_run_fingerprint,
           "observer" => observer,
           "owner_fingerprint" => owner_fingerprint,
           "receipt_digest" => receipt_digest,
           "repair_oracle" => repair_oracle,
           "scenario_status" => scenario_status,
           "status" => status,
           "truncated" => truncated
         } = evidence,
         @schema,
         _wire
       ),
       do:
         map_size(evidence) == 14 and is_boolean(armed_before_scenario) and is_boolean(complete) and
           is_integer(dropped) and dropped >= 0 and is_boolean(finalized_after_scenario) and
           is_integer(gaps) and gaps >= 0 and is_boolean(truncated) and
           status == evidence_status(evidence) and
           digest?(receipt_digest) and optional_id?(owner_fingerprint) and
           optional_id?(observation_run_fingerprint) and optional_identity?(observer) and
           lease_execution in [nil, "confirmed"] and
           scenario_status in [nil, "completed", "failed"] and
           valid_oracle?(repair_oracle) and evidence_identity_coherent?(evidence)

  defp valid_evidence?(%{"external_execution" => external} = evidence, @external_schema, wire) do
    base = Map.delete(evidence, "external_execution")

    with true <- map_size(evidence) == 15,
         true <- valid_evidence?(base, @schema, wire),
         {:ok, valid_external} <- ExternalReceipt.validate(external) do
      report = valid_external["report"]

      valid_external["owner_fingerprint"] == evidence["owner_fingerprint"] and
        valid_external["target_fingerprint"] == wire["observed_target_fingerprint"] and
        report["scenario_id"] == wire["scenario_id"] and
        report["expected_fingerprint"] == wire["expected_fingerprint"] and
        report["observed_fingerprints"] == wire["observed_fingerprints"] and
        report["scenario_status"] == evidence["scenario_status"] and
        report["observer"] == evidence["observer"] and
        external_exit_coherent?(valid_external, evidence, wire)
    else
      _other -> false
    end
  end

  defp valid_evidence?(_evidence, _schema, _wire), do: false

  defp external_exit_coherent?(%{"exit_status" => 0}, _evidence, _wire), do: true

  defp external_exit_coherent?(external, evidence, wire),
    do:
      external["exit_status"] in 1..255 and is_nil(evidence["repair_oracle"]) and
        evidence["scenario_status"] == "failed" and
        wire["observed_fingerprints"] == [wire["expected_fingerprint"]]

  defp valid_cleanup?(
         %{
           "status" => status,
           "release" => release,
           "remaining_count" => remaining_count,
           "remaining_fingerprint" => remaining_fingerprint
         } = cleanup
       ),
       do:
         map_size(cleanup) == 4 and
           cleanup_coherent?(status, release, remaining_count, remaining_fingerprint)

  defp valid_cleanup?(_cleanup), do: false

  defp cleanup_coherent?("complete", release, 0, nil),
    do: release in ["complete", "failed", "not_required"]

  defp cleanup_coherent?("partial", release, remaining_count, remaining_fingerprint),
    do:
      release in ["complete", "failed"] and is_integer(remaining_count) and
        remaining_count > 0 and id?(remaining_fingerprint)

  defp cleanup_coherent?("uncertain", release, 0, nil),
    do: release in ["complete", "failed", "not_attempted"]

  defp cleanup_coherent?("unknown", release, 0, nil),
    do: release in ["not_attempted", "not_required"]

  defp cleanup_coherent?(_status, _release, _remaining_count, _remaining_fingerprint), do: false

  defp evidence_cleanup_coherent?(%{"lease_execution" => "confirmed"}, cleanup),
    do: cleanup["release"] in ["complete", "failed"]

  defp evidence_cleanup_coherent?(_evidence, _cleanup), do: true

  defp valid_outcome_reason?(nil), do: true

  defp valid_outcome_reason?(reason) when is_binary(reason),
    do:
      reason in [
        "evidence_unavailable",
        "invalid_body_receipt",
        "observer_failed",
        "scenario_failed"
      ]

  defp valid_outcome_reason?(_reason), do: false

  defp valid_operational_reason?("completed", nil), do: true
  defp valid_operational_reason?("cancelled", "sandbox_cancelled"), do: true
  defp valid_operational_reason?("error", "sandbox_failed"), do: true
  defp valid_operational_reason?("timeout", "sandbox_timeout"), do: true
  defp valid_operational_reason?(_status, _reason), do: false

  defp confirmation_coherent?(wire) do
    outcome = derived_outcome(wire)

    should_confirm =
      outcome == "matching_failure" and wire["operational_status"] == "completed" and
        wire["cleanup"]["status"] == "complete"

    operational_coherent?(wire) and wire["outcome"] == outcome and
      wire["confirmed"] == should_confirm and reason_coherent?(wire)
  end

  defp operational_coherent?(%{"operational_status" => "completed", "cleanup" => cleanup}),
    do: cleanup["status"] == "complete"

  defp operational_coherent?(_wire), do: true

  defp derived_outcome(wire) do
    evidence = wire["evidence"]
    expected? = wire["expected_fingerprint"] in wire["observed_fingerprints"]
    exact_target? = wire["observed_target_fingerprint"] == wire["requested_target_fingerprint"]

    complete? =
      evidence_status(evidence) == "complete" and evidence["lease_execution"] == "confirmed" and
        not is_nil(evidence["owner_fingerprint"]) and
        evidence["owner_fingerprint"] == evidence["observation_run_fingerprint"] and exact_target?

    cond do
      not complete? -> "infrastructure_failure"
      expected? -> "matching_failure"
      evidence["scenario_status"] != "completed" -> "infrastructure_failure"
      wire["observed_fingerprints"] != [] -> "unrelated_failure"
      get_in(evidence, ["repair_oracle", "status"]) == "passed" -> "repaired"
      true -> "nonreproduced"
    end
  end

  defp evidence_status(evidence) do
    if evidence["armed_before_scenario"] and evidence["complete"] and
         evidence["finalized_after_scenario"] and evidence["dropped"] == 0 and
         evidence["gaps"] == 0 and not evidence["truncated"],
       do: "complete",
       else: "incomplete"
  end

  defp evidence_identity_coherent?(%{"status" => "incomplete"}), do: true

  defp evidence_identity_coherent?(evidence) do
    evidence["lease_execution"] == "confirmed" and identity?(evidence["observer"]) and
      id?(evidence["owner_fingerprint"]) and id?(evidence["observation_run_fingerprint"]) and
      evidence["owner_fingerprint"] == evidence["observation_run_fingerprint"] and
      evidence["scenario_status"] in ["completed", "failed"]
  end

  defp reason_coherent?(%{"outcome" => outcome, "outcome_reason" => nil})
       when outcome in ["matching_failure", "nonreproduced", "repaired", "unrelated_failure"],
       do: true

  defp reason_coherent?(%{
         "outcome" => "infrastructure_failure",
         "evidence" => evidence,
         "outcome_reason" => reason
       }) do
    cond do
      evidence["scenario_status"] == nil and evidence["owner_fingerprint"] == nil ->
        reason in ["evidence_unavailable", "invalid_body_receipt"]

      evidence["owner_fingerprint"] == nil ->
        reason == "invalid_body_receipt"

      evidence_status(evidence) == "incomplete" ->
        reason == "observer_failed"

      evidence["scenario_status"] == "failed" ->
        reason == "scenario_failed"

      true ->
        false
    end
  end

  defp reason_coherent?(_wire), do: false

  defp valid_oracle?(nil), do: true

  defp valid_oracle?(
         %{"identity" => identity, "receipt_digest" => receipt_digest, "status" => status} =
           oracle
       ),
       do:
         map_size(oracle) == 3 and identity?(identity) and digest?(receipt_digest) and
           status in ["failed", "passed"]

  defp valid_oracle?(_oracle), do: false

  defp optional_identity?(nil), do: true
  defp optional_identity?(identity), do: identity?(identity)

  defp identity?(%{"id" => id, "version" => version} = identity),
    do:
      map_size(identity) == 2 and is_binary(id) and byte_size(id) in 1..128 and
        String.match?(id, ~r/\A[a-z][a-z0-9_.-]*\z/) and is_integer(version) and
        version in 1..1_000_000

  defp identity?(_identity), do: false
  defp optional_id?(nil), do: true
  defp optional_id?(value), do: id?(value)

  defp exact_struct?(record),
    do: Enum.sort(Map.keys(Map.from_struct(record))) == Enum.sort(@fields)

  defp id?("sha256:" <> digest), do: digest?(digest)
  defp id?(_id), do: false

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp digest?(_value), do: false
  defp optional_digest?(nil), do: true
  defp optional_digest?(value), do: digest?(value)

  defp valid_integrity?(%{"algorithm" => "sha256", "content_digest" => digest} = integrity),
    do: map_size(integrity) == 2 and digest?(digest)

  defp valid_integrity?(_integrity), do: false

  defp hash(value),
    do: :sha256 |> :crypto.hash(Canonical.encode(value)) |> Base.encode16(case: :lower)

  defp invalid(reason),
    do:
      {:error,
       Error.new(:invalid_confirmation_record, "confirmation record is invalid", %{reason: reason})}

  defp limit_exceeded,
    do:
      {:error,
       Error.new(
         :confirmation_record_limit_exceeded,
         "confirmation record exceeds its static limit"
       )}

  defp unsupported_schema(schema),
    do:
      {:error,
       Error.new(
         :unsupported_confirmation_record_schema,
         "confirmation record schema is unsupported",
         %{schema: Insider.Protocol.Value.summary(schema)}
       )}
end

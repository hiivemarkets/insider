defmodule Insider.Sentinel.Confirmation.Receipt do
  @moduledoc """
  Bounded terminal evidence returned by a trusted confirmation target adapter.

  An adapter arms its configured observer before executing the scenario against
  the live lease, finalizes that same observation run afterwards, and returns
  only after all work it owns has stopped. `{:ok, receipt}` describes a
  completed attempt even when the scenario or observer failed; outer body
  errors are reserved for lifecycle failures.
  """

  alias Insider.Protocol.Error
  alias Insider.Protocol.StrictOptions
  alias Insider.Event.Value
  alias Insider.Protocol.Value, as: ProtocolValue
  alias Insider.Sentinel.ExternalProcess.Receipt, as: ExternalReceipt

  @schema "insider.confirmation-body-receipt/v1"
  @external_schema "insider.confirmation-body-receipt/v2"
  @option_keys [
    :capsule_id,
    :evidence,
    :expected_fingerprint,
    :lease_execution,
    :manifest_id,
    :observation_run_fingerprint,
    :observed_incident_fingerprints,
    :observed_target_fingerprint,
    :observer,
    :owner_fingerprint,
    :reason,
    :repair_oracle,
    :scenario_id,
    :scenario_status,
    :target_id
  ]
  @keys [
    "capsule_id",
    "evidence",
    "expected_fingerprint",
    "lease_execution",
    "manifest_id",
    "observation_run_fingerprint",
    "observed_incident_fingerprints",
    "observed_target_fingerprint",
    "observer",
    "owner_fingerprint",
    "reason",
    "repair_oracle",
    "scenario_id",
    "scenario_status",
    "schema",
    "target_id"
  ]
  @external_option_keys Enum.sort([:external_execution | @option_keys])
  @external_keys Enum.sort(["external_execution" | @keys])

  @spec new(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def new(options), do: StrictOptions.build(options, @option_keys, &build/1, &invalid/1)

  @doc false
  @spec new_external(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def new_external(options) do
    StrictOptions.build(options, @external_option_keys, &build_external/1, &invalid/1)
  end

  defp build(options) do
    receipt = %{
      "schema" => @schema,
      "manifest_id" => Keyword.get(options, :manifest_id),
      "capsule_id" => Keyword.get(options, :capsule_id),
      "scenario_id" => Keyword.get(options, :scenario_id),
      "target_id" => Keyword.get(options, :target_id),
      "expected_fingerprint" => Keyword.get(options, :expected_fingerprint),
      "owner_fingerprint" => Keyword.get(options, :owner_fingerprint),
      "observed_target_fingerprint" => Keyword.get(options, :observed_target_fingerprint),
      "observation_run_fingerprint" => Keyword.get(options, :observation_run_fingerprint),
      "observer" => Keyword.get(options, :observer),
      "lease_execution" => Keyword.get(options, :lease_execution),
      "scenario_status" => Keyword.get(options, :scenario_status),
      "observed_incident_fingerprints" =>
        Keyword.fetch!(options, :observed_incident_fingerprints),
      "evidence" => Keyword.get(options, :evidence),
      "repair_oracle" => Keyword.get(options, :repair_oracle),
      "reason" => Keyword.get(options, :reason)
    }

    validate(receipt)
  end

  defp build_external(options) do
    options
    |> Keyword.delete(:external_execution)
    |> build()
    |> case do
      {:ok, receipt} ->
        receipt
        |> Map.put("schema", @external_schema)
        |> Map.put("external_execution", Keyword.fetch!(options, :external_execution))
        |> validate()

      error ->
        error
    end
  end

  @spec validate(term()) :: {:ok, map()} | {:error, Error.t()}
  def validate(%{"schema" => @external_schema} = receipt) do
    with true <- map_size(receipt) == length(@external_keys),
         true <- Enum.sort(Map.keys(receipt)) == @external_keys,
         {:ok, external} <- ExternalReceipt.validate(receipt["external_execution"]),
         {:ok, _v1} <-
           receipt |> Map.delete("external_execution") |> Map.put("schema", @schema) |> validate(),
         true <- external_coherent?(receipt, external),
         true <- ProtocolValue.bounded_data?(receipt, 24_576) do
      {:ok, receipt}
    else
      _other -> invalid(:invalid_external_receipt)
    end
  rescue
    _error -> invalid(:validation_failed)
  end

  def validate(receipt) when is_map(receipt) and not is_struct(receipt) do
    fingerprints = receipt["observed_incident_fingerprints"]

    if map_size(receipt) == length(@keys) and Enum.sort(Map.keys(receipt)) == @keys and
         receipt["schema"] == @schema and
         Enum.all?(["manifest_id", "capsule_id", "scenario_id", "target_id"], &id?(receipt[&1])) and
         Enum.all?(["expected_fingerprint", "observed_target_fingerprint"], &digest?(receipt[&1])) and
         id?(receipt["owner_fingerprint"]) and id?(receipt["observation_run_fingerprint"]) and
         identity?(receipt["observer"]) and receipt["lease_execution"] == "confirmed" and
         receipt["scenario_status"] in ["completed", "failed"] and
         Value.valid_list?(fingerprints, 16, 2_048) and Enum.all?(fingerprints, &digest?/1) and
         fingerprints == Enum.sort(fingerprints) and fingerprints == Enum.uniq(fingerprints) and
         evidence?(receipt["evidence"]) and oracle?(receipt["repair_oracle"]) and
         receipt["reason"] in [nil, "observer_failed", "scenario_failed"] and coherent?(receipt) and
         ProtocolValue.bounded_data?(receipt, 8_192) do
      {:ok, receipt}
    else
      invalid(:invalid_receipt)
    end
  rescue
    _error -> invalid(:validation_failed)
  end

  def validate(_receipt), do: invalid(:invalid_receipt)

  defp external_coherent?(receipt, external) do
    report = external["report"]

    external["owner_fingerprint"] == receipt["owner_fingerprint"] and
      external["target_fingerprint"] == receipt["observed_target_fingerprint"] and
      report["scenario_id"] == receipt["scenario_id"] and
      report["expected_fingerprint"] == receipt["expected_fingerprint"] and
      report["observer"] == receipt["observer"] and
      report["observed_fingerprints"] == receipt["observed_incident_fingerprints"] and
      report["scenario_status"] == receipt["scenario_status"] and
      external["status"] == "exited" and external_exit_coherent?(receipt, external)
  end

  defp external_exit_coherent?(_receipt, %{"exit_status" => 0}), do: true

  defp external_exit_coherent?(receipt, %{"exit_status" => exit_status}) do
    exit_status in 1..255 and is_nil(receipt["repair_oracle"]) and
      receipt["scenario_status"] == "failed" and receipt["reason"] == "scenario_failed" and
      receipt["observed_incident_fingerprints"] == [receipt["expected_fingerprint"]]
  end

  defp evidence?(
         %{
           "armed_before_scenario" => armed_before_scenario,
           "complete" => complete,
           "dropped" => dropped,
           "finalized_after_scenario" => finalized_after_scenario,
           "gaps" => gaps,
           "truncated" => truncated
         } = evidence
       ),
       do:
         map_size(evidence) == 6 and is_boolean(armed_before_scenario) and is_boolean(complete) and
           is_integer(dropped) and dropped >= 0 and is_boolean(finalized_after_scenario) and
           is_integer(gaps) and gaps >= 0 and is_boolean(truncated)

  defp evidence?(_evidence), do: false
  defp oracle?(nil), do: true

  defp oracle?(
         %{"identity" => identity, "receipt_digest" => digest, "status" => status} = oracle
       ),
       do:
         map_size(oracle) == 3 and identity?(identity) and digest?(digest) and
           status in ["failed", "passed"]

  defp oracle?(_oracle), do: false

  defp coherent?(receipt) do
    complete =
      receipt["evidence"]["armed_before_scenario"] and
        receipt["evidence"]["finalized_after_scenario"] and receipt["evidence"]["complete"] and
        receipt["evidence"]["dropped"] == 0 and receipt["evidence"]["gaps"] == 0 and
        not receipt["evidence"]["truncated"]

    cond do
      receipt["reason"] == "observer_failed" ->
        not complete

      receipt["reason"] == "scenario_failed" ->
        receipt["scenario_status"] == "failed" and complete

      receipt["reason"] == nil ->
        receipt["scenario_status"] == "completed" and complete

      true ->
        false
    end
  end

  defp identity?(%{"id" => id, "version" => version} = identity),
    do:
      map_size(identity) == 2 and vocabulary?(id) and is_integer(version) and
        version in 1..1_000_000

  defp identity?(_identity), do: false
  defp id?("sha256:" <> digest), do: digest?(digest)
  defp id?(_id), do: false

  defp digest?(digest) when is_binary(digest) and byte_size(digest) == 64,
    do: String.match?(digest, ~r/\A[0-9a-f]{64}\z/)

  defp digest?(_digest), do: false

  defp vocabulary?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: String.match?(value, ~r/\A[a-z][a-z0-9_.-]*\z/)

  defp vocabulary?(_value), do: false

  defp invalid(reason),
    do:
      {:error,
       Error.new(:invalid_confirmation_receipt, "confirmation body receipt is invalid", %{
         reason: reason
       })}
end

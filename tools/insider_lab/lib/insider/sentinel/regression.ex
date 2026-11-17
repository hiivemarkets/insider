defmodule Insider.Sentinel.Regression do
  @moduledoc """
  A bounded, canonical recipe for proving a confirmed incident still fails.

  A regression embeds the exact source confirmation and scenario as data. Its
  SHA-256 identity detects accidental or malicious rewriting when the expected
  digest is trusted separately; it is not authenticity or proof of failure.
  `classify/2` requires two distinct fresh confirmation records and deliberately
  cannot make a passing-after claim.
  """

  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value
  alias Insider.Scenario
  alias Insider.Sentinel.Confirmation.Record

  @schema "insider.regression/v1"
  @wire_keys [
    "confirmed_record",
    "execution_policy",
    "expectation",
    "id",
    "integrity",
    "scenario",
    "schema"
  ]
  @maximum_bytes 131_072
  @execution_policy %{
    "cleanup" => "required",
    "purpose" => "regression",
    "required_runs" => 2,
    "source_mutation" => "prohibited",
    "target_class" => "disposable"
  }

  @enforce_keys [
    :schema,
    :id,
    :confirmed_record,
    :scenario,
    :expectation,
    :execution_policy,
    :integrity
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec materialize(Record.t(), Scenario.t()) :: {:ok, t()} | {:error, Error.t()}
  def materialize(record, scenario) do
    with {:ok, valid_record} <- Record.validate(record),
         {:ok, valid_scenario} <- Scenario.validate(scenario),
         :ok <- eligible(valid_record, valid_scenario) do
      expectation = expectation(valid_record)

      content = %{
        "confirmed_record" => Record.to_wire_map(valid_record),
        "execution_policy" => @execution_policy,
        "expectation" => expectation,
        "scenario" => Scenario.to_wire_map(valid_scenario),
        "schema" => @schema
      }

      digest = hash(content)

      %__MODULE__{
        schema: @schema,
        id: "sha256:" <> digest,
        confirmed_record: content["confirmed_record"],
        scenario: content["scenario"],
        expectation: expectation,
        execution_policy: @execution_policy,
        integrity: %{"algorithm" => "sha256", "content_digest" => digest}
      }
      |> validate()
    else
      {:error, %Error{code: code}}
      when code in [
             :invalid_confirmation_record,
             :invalid_scenario,
             :scenario_integrity_failed,
             :scenario_limit_exceeded,
             :unsupported_scenario_schema
           ] ->
        ineligible(:invalid_source)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  rescue
    _error -> invalid(:materialization_failed)
  catch
    _kind, _reason -> invalid(:materialization_failed)
  end

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = regression) do
    with true <- exact_struct?(regression),
         true <- regression.schema == @schema,
         true <- regression.execution_policy == @execution_policy,
         true <- valid_integrity?(regression.integrity),
         true <- valid_expectation?(regression.expectation),
         {:ok, record} <- Record.decode_map(regression.confirmed_record),
         {:ok, scenario} <- Scenario.decode_map(regression.scenario),
         :ok <- eligible(record, scenario),
         true <- regression.expectation == expectation(record),
         true <- regression.id == "sha256:" <> regression.integrity["content_digest"],
         true <- regression.integrity["content_digest"] == hash(content(regression)),
         true <- byte_size(Canonical.encode(to_wire_map(regression))) <= @maximum_bytes do
      {:ok, regression}
    else
      _other -> invalid(:invalid_regression)
    end
  rescue
    _error -> invalid(:validation_failed)
  catch
    _kind, _reason -> invalid(:validation_failed)
  end

  def validate(_value), do: invalid(:invalid_value)

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(regression) do
    with {:ok, valid} <- validate(regression),
         do: {:ok, valid |> to_wire_map() |> Canonical.encode()}
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(binary) when is_binary(binary) and byte_size(binary) <= @maximum_bytes do
    case Jason.decode(binary) do
      {:ok, wire} -> decode_canonical(wire, binary)
      {:error, %Jason.DecodeError{}} -> invalid(:invalid_json)
    end
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode(binary) when is_binary(binary), do: limit_exceeded()
  def decode(_value), do: invalid(:invalid_encoding)

  defp decode_canonical(wire, binary) do
    if Canonical.encode(wire) == binary,
      do: decode_map(wire),
      else: invalid(:noncanonical_encoding)
  end

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(%{"schema" => schema}) when schema != @schema, do: unsupported_schema(schema)

  def decode_map(
        %{
          "schema" => @schema,
          "id" => id,
          "confirmed_record" => confirmed_record,
          "scenario" => scenario,
          "expectation" => expectation,
          "execution_policy" => execution_policy,
          "integrity" => integrity
        } = wire
      )
      when map_size(wire) == length(@wire_keys) do
    validate(%__MODULE__{
      schema: @schema,
      id: id,
      confirmed_record: confirmed_record,
      scenario: scenario,
      expectation: expectation,
      execution_policy: execution_policy,
      integrity: integrity
    })
  rescue
    _error -> invalid(:decoding_failed)
  end

  def decode_map(%{"schema" => @schema}), do: invalid(:invalid_envelope)
  def decode_map(value) when is_map(value) and not is_struct(value), do: unsupported_schema(nil)
  def decode_map(_value), do: invalid(:invalid_value)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = regression) do
    %{
      "schema" => regression.schema,
      "id" => regression.id,
      "confirmed_record" => regression.confirmed_record,
      "scenario" => regression.scenario,
      "expectation" => regression.expectation,
      "execution_policy" => regression.execution_policy,
      "integrity" => regression.integrity
    }
  end

  @doc """
  Classifies exactly two fresh confirmation records against a regression.

  The stable result is data, not a new evidence artifact. A `failed` result
  means both fresh runs reproduced the bound failure. Every other valid run
  combination is `inconclusive`; positive repair proof belongs to verification.
  """
  @spec classify(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def classify(regression, records) do
    with {:ok, valid_regression} <- validate(regression),
         {:ok, valid_records} <- validate_runs(records) do
      sorted = Enum.sort_by(valid_records, & &1.id)

      case classification_reason(valid_regression, sorted) do
        nil -> {:ok, evaluation(valid_regression, sorted, "failed", "consistent_failure")}
        reason -> {:ok, evaluation(valid_regression, sorted, "inconclusive", reason)}
      end
    end
  rescue
    _error -> invalid_runs(:classification_failed)
  catch
    _kind, _reason -> invalid_runs(:classification_failed)
  end

  defp validate_runs(records) do
    with true <- Value.bounded_list?(records, 2),
         [first, second] <- records do
      Enum.reduce_while([first, second], {:ok, []}, fn record, {:ok, acc} ->
        case Record.validate(record) do
          {:ok, valid} -> {:cont, {:ok, [valid | acc]}}
          {:error, %Error{}} -> {:halt, invalid_runs(:invalid_run_record)}
        end
      end)
    else
      _other -> invalid_runs(:required_runs)
    end
  end

  defp classification_reason(regression, [first, second] = records) do
    source = regression.confirmed_record
    source_run = source["evidence"]["observation_run_fingerprint"]
    run_ids = Enum.map(records, & &1.id)
    observation_runs = Enum.map(records, & &1.evidence["observation_run_fingerprint"])

    cond do
      source["id"] in run_ids or source_run in observation_runs ->
        "source_record_reuse"

      first.id == second.id or Enum.uniq(observation_runs) != observation_runs ->
        "duplicate_run"

      Enum.any?(records, &(&1.capsule_id != source["capsule_id"])) ->
        "wrong_capsule"

      Enum.any?(records, &(&1.manifest_id != source["manifest_id"])) ->
        "wrong_manifest"

      Enum.any?(records, &(&1.scenario_id != regression.scenario["id"])) ->
        "wrong_scenario"

      Enum.any?(
        records,
        &(&1.expected_fingerprint != regression.expectation["incident_fingerprint"])
      ) ->
        "wrong_expected_fingerprint"

      Enum.any?(records, &(&1.evidence["observer"] != regression.expectation["observer"])) ->
        "wrong_observer"

      Enum.any?(records, &wrong_target?(&1, source["observed_target_fingerprint"])) ->
        "wrong_target"

      Enum.any?(records, &(not is_nil(&1.evidence["repair_oracle"]))) ->
        "repair_evidence_present"

      Enum.any?(records, &(&1.uncertainty != [])) ->
        "uncertainty_present"

      Enum.any?(records, &(not complete_run?(&1))) ->
        "incomplete_run"

      Enum.any?(records, &(&1.outcome == "unrelated_failure")) ->
        "unrelated_failure"

      Enum.any?(records, &(&1.outcome == "nonreproduced")) ->
        "nonreproduced"

      Enum.any?(records, &(not matching_run?(&1))) ->
        "not_confirmed_matching_failure"

      true ->
        nil
    end
  end

  defp evaluation(regression, records, status, reason) do
    %{
      "reason" => reason,
      "regression_id" => regression.id,
      "run_record_ids" => Enum.map(records, & &1.id),
      "schema" => "insider.regression-evaluation/v1",
      "status" => status
    }
  end

  defp eligible(record, scenario) do
    expected = record.expected_fingerprint

    if matching_run?(record) and complete_run?(record) and record.scenario_id == scenario.id and
         expected in record.observed_fingerprints and
         expected in scenario.expected_incident_fingerprints and
         is_map(record.evidence["observer"]) and
         record.uncertainty == [] and is_nil(record.evidence["repair_oracle"]),
       do: :ok,
       else: ineligible(:source_not_eligible)
  end

  defp matching_run?(record),
    do:
      record.confirmed and record.outcome == "matching_failure" and
        record.operational_status == "completed" and is_nil(record.operational_reason)

  defp complete_run?(record) do
    evidence = record.evidence

    record.cleanup["status"] == "complete" and record.cleanup["release"] in ["complete", "failed"] and
      record.cleanup["remaining_count"] == 0 and
      is_nil(record.cleanup["remaining_fingerprint"]) and evidence["status"] == "complete" and
      evidence["complete"] and
      evidence["armed_before_scenario"] and evidence["finalized_after_scenario"] and
      evidence["dropped"] == 0 and evidence["gaps"] == 0 and not evidence["truncated"] and
      evidence["lease_execution"] == "confirmed" and
      evidence["owner_fingerprint"] == evidence["observation_run_fingerprint"]
  end

  defp wrong_target?(record, baseline) do
    record.requested_target_fingerprint != baseline or
      record.observed_target_fingerprint != baseline
  end

  defp expectation(record) do
    %{
      "incident_fingerprint" => record.expected_fingerprint,
      "observer" => record.evidence["observer"]
    }
  end

  defp valid_expectation?(
         %{"incident_fingerprint" => fingerprint, "observer" => observer} = expectation
       ),
       do: map_size(expectation) == 2 and digest?(fingerprint) and valid_observer?(observer)

  defp valid_expectation?(_expectation), do: false

  defp valid_observer?(%{"id" => id, "version" => version} = observer),
    do:
      map_size(observer) == 2 and is_binary(id) and byte_size(id) in 1..128 and
        String.match?(id, ~r/\A[a-z][a-z0-9_.-]*\z/) and is_integer(version) and
        version in 1..1_000_000

  defp valid_observer?(_observer), do: false

  defp content(regression), do: regression |> to_wire_map() |> Map.drop(["id", "integrity"])

  defp exact_struct?(regression),
    do:
      Enum.sort(Map.keys(Map.from_struct(regression))) ==
        Enum.sort(@enforce_keys)

  defp valid_integrity?(%{"algorithm" => "sha256", "content_digest" => digest} = integrity),
    do: map_size(integrity) == 2 and digest?(digest)

  defp valid_integrity?(_integrity), do: false

  defp digest?(digest) when is_binary(digest) and byte_size(digest) == 64,
    do: String.match?(digest, ~r/\A[0-9a-f]{64}\z/)

  defp digest?(_digest), do: false

  defp hash(value),
    do: :sha256 |> :crypto.hash(Canonical.encode(value)) |> Base.encode16(case: :lower)

  defp invalid(reason),
    do: {:error, Error.new(:invalid_regression, "regression is invalid", %{reason: reason})}

  defp ineligible(reason),
    do:
      {:error,
       Error.new(:regression_ineligible, "confirmation cannot materialize a regression", %{
         reason: reason
       })}

  defp invalid_runs(reason),
    do:
      {:error,
       Error.new(:invalid_regression_runs, "regression runs are invalid", %{reason: reason})}

  defp limit_exceeded,
    do:
      {:error, Error.new(:regression_limit_exceeded, "regression exceeds its static byte limit")}

  defp unsupported_schema(schema),
    do:
      {:error,
       Error.new(:unsupported_regression_schema, "regression schema is unsupported", %{
         schema: Insider.Protocol.Value.summary(schema)
       })}
end

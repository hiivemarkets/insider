defmodule Insider.Sentinel.Verification.Record do
  @moduledoc "A canonical derived verdict for bounded failing-before and passing-after evidence."

  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value
  alias Insider.Sentinel.Confirmation.Record, as: ConfirmationRecord
  alias Insider.Sentinel.Regression
  alias Insider.Sentinel.Verification.Candidate
  alias Insider.Sentinel.Verification.Ingress
  alias Insider.Sentinel.Verification.Receipt

  @schema "insider.verification-record/v1"
  @keys [
    "after_attempts",
    "before_records",
    "candidate",
    "executor_counts",
    "id",
    "integrity",
    "oracle",
    "reasons",
    "regression",
    "schema",
    "status"
  ]
  @fields [
    :schema,
    :id,
    :regression,
    :candidate,
    :before_records,
    :after_attempts,
    :executor_counts,
    :oracle,
    :status,
    :reasons,
    :integrity
  ]
  @maximum_bytes 262_144
  @enforce_keys @fields
  defstruct @fields
  @type t :: %__MODULE__{}

  @spec new(Regression.t(), Candidate.t(), map(), list(), list(), map()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(regression, candidate, oracle, before_records, after_attempts, counts) do
    with {:ok, regression} <- Regression.validate(regression),
         {:ok, candidate} <- Candidate.validate(candidate),
         {:ok, before_wire} <- normalize_before(before_records),
         {:ok, after_wire} <- normalize_after(after_attempts),
         true <- valid_identity?(oracle),
         true <- valid_counts?(counts) do
      wire_counts = %{"active" => counts.active, "quarantined" => counts.quarantined}

      reasons =
        derive_reasons(regression, candidate, oracle, before_wire, after_wire, wire_counts)

      status = if reasons == [], do: "verified", else: "invalid"

      body = %{
        "schema" => @schema,
        "regression" => Regression.to_wire_map(regression),
        "candidate" => Candidate.to_wire_map(candidate),
        "before_records" => before_wire,
        "after_attempts" => after_wire,
        "executor_counts" => wire_counts,
        "oracle" => oracle,
        "status" => status,
        "reasons" => reasons
      }

      digest = hash(body)

      validate(%__MODULE__{
        schema: @schema,
        id: "sha256:" <> digest,
        regression: body["regression"],
        candidate: body["candidate"],
        before_records: before_wire,
        after_attempts: after_wire,
        executor_counts: wire_counts,
        oracle: oracle,
        status: status,
        reasons: reasons,
        integrity: %{"algorithm" => "sha256", "content_digest" => digest}
      })
    else
      _other -> invalid(:invalid_evidence)
    end
  rescue
    _error -> invalid(:construction_failed)
  end

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = record) do
    with true <- Enum.sort(Map.keys(Map.from_struct(record))) == Enum.sort(@fields),
         true <- record.schema == @schema,
         {:ok, regression} <- Regression.decode_map(record.regression),
         {:ok, candidate} <- Candidate.decode_map(record.candidate),
         {:ok, before_wire} <- normalize_before_wire(record.before_records),
         {:ok, after_wire} <- normalize_after_wire(record.after_attempts),
         true <- valid_wire_counts?(record.executor_counts),
         true <- valid_identity?(record.oracle),
         reasons <-
           derive_reasons(
             regression,
             candidate,
             record.oracle,
             before_wire,
             after_wire,
             record.executor_counts
           ),
         true <- record.reasons == reasons and reasons == Enum.sort(Enum.uniq(reasons)),
         true <- record.status == if(reasons == [], do: "verified", else: "invalid"),
         true <- valid_integrity?(record.integrity),
         true <- record.id == "sha256:" <> record.integrity["content_digest"],
         true <- record.integrity["content_digest"] == hash(content(record)),
         true <- byte_size(Canonical.encode(to_wire_map(record))) <= @maximum_bytes do
      {:ok, record}
    else
      _other -> invalid(:invalid_record)
    end
  rescue
    _error -> invalid(:validation_failed)
  end

  def validate(_value), do: invalid(:invalid_value)

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(record) do
    with {:ok, valid} <- validate(record), do: {:ok, Canonical.encode(to_wire_map(valid))}
  end

  @spec decode(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode(value) do
    case Ingress.canonical_decode(value, @maximum_bytes, &decode_map/1) do
      {:ingress_error, :limit_exceeded} ->
        {:error,
         Error.new(
           :verification_record_limit_exceeded,
           "verification record exceeds its static limit"
         )}

      {:ingress_error, reason} ->
        invalid(reason)

      result ->
        result
    end
  end

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(%{"schema" => schema}) when schema != @schema,
    do:
      {:error,
       Error.new(
         :unsupported_verification_record_schema,
         "verification record schema is unsupported",
         %{schema: Insider.Protocol.Value.summary(schema)}
       )}

  def decode_map(%{"schema" => @schema} = wire) when map_size(wire) == length(@keys) do
    if Enum.sort(Map.keys(wire)) == @keys do
      validate(%__MODULE__{
        schema: wire["schema"],
        id: wire["id"],
        regression: wire["regression"],
        candidate: wire["candidate"],
        before_records: wire["before_records"],
        after_attempts: wire["after_attempts"],
        executor_counts: wire["executor_counts"],
        oracle: wire["oracle"],
        status: wire["status"],
        reasons: wire["reasons"],
        integrity: wire["integrity"]
      })
    else
      invalid(:invalid_envelope)
    end
  end

  def decode_map(%{"schema" => @schema}), do: invalid(:invalid_envelope)

  def decode_map(value) when is_map(value) and not is_struct(value),
    do: decode_map(%{"schema" => nil})

  def decode_map(_value), do: invalid(:invalid_value)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(record),
    do: %{
      "schema" => record.schema,
      "id" => record.id,
      "regression" => record.regression,
      "candidate" => record.candidate,
      "before_records" => record.before_records,
      "after_attempts" => record.after_attempts,
      "executor_counts" => record.executor_counts,
      "oracle" => record.oracle,
      "status" => record.status,
      "reasons" => record.reasons,
      "integrity" => record.integrity
    }

  defp normalize_before(records) do
    with true <- Value.bounded_list?(records, 2), [first, second] <- records do
      normalize_before_items([first, second])
    else
      _ -> :error
    end
  end

  defp normalize_before_items(records) do
    {:ok,
     Enum.map(records, fn
       %ConfirmationRecord{} = record -> ConfirmationRecord.to_wire_map(record)
       nil -> nil
     end)}
  rescue
    _error -> :error
  end

  defp normalize_before_wire(records) do
    with true <- Value.bounded_list?(records, 2), [first, second] <- records do
      normalize_before_wire_items([first, second])
    else
      _ -> :error
    end
  end

  defp normalize_before_wire_items(records) do
    Enum.reduce_while(records, {:ok, []}, fn
      nil, {:ok, acc} ->
        {:cont, {:ok, [nil | acc]}}

      wire, {:ok, acc} ->
        case ConfirmationRecord.decode_map(wire) do
          {:ok, record} -> {:cont, {:ok, [ConfirmationRecord.to_wire_map(record) | acc]}}
          _ -> {:halt, :error}
        end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      other -> other
    end
  end

  defp normalize_after(attempts), do: normalize_after_wire(attempts)

  defp normalize_after_wire(attempts) do
    with true <- Value.bounded_list?(attempts, 2),
         [first, second] <- attempts,
         true <- Enum.all?([first, second], &valid_attempt?/1) do
      {:ok, [first, second]}
    else
      _ -> :error
    end
  end

  defp valid_attempt?(
         %{
           "cleanup" => cleanup,
           "owner_fingerprint" => owner,
           "receipt" => receipt,
           "status" => status,
           "target_fingerprint" => target,
           "uncertainty" => uncertainty
         } = attempt
       ) do
    map_size(attempt) == 6 and status in ["cancelled", "completed", "error", "timeout"] and
      (is_nil(owner) or id?(owner)) and
      (is_nil(target) or digest?(target)) and valid_cleanup?(cleanup) and
      (is_nil(receipt) or is_map(receipt)) and Value.bounded_list?(uncertainty, 16) and
      Enum.all?(uncertainty, &(is_binary(&1) and byte_size(&1) <= 256))
  end

  defp valid_attempt?(_), do: false

  defp valid_cleanup?(
         %{
           "release" => release,
           "remaining_count" => count,
           "remaining_fingerprint" => fingerprint,
           "status" => status
         } = cleanup
       ),
       do:
         map_size(cleanup) == 4 and status in ["complete", "partial", "uncertain", "unknown"] and
           release in ["complete", "failed", "not_attempted", "not_required"] and
           is_integer(count) and count >= 0 and (is_nil(fingerprint) or id?(fingerprint))

  defp valid_cleanup?(_), do: false

  defp valid_counts?(%{active: active, quarantined: quarantined}),
    do: valid_count_pair?(active, quarantined)

  defp valid_counts?(_), do: false

  defp valid_wire_counts?(%{"active" => active, "quarantined" => quarantined} = counts),
    do: map_size(counts) == 2 and valid_count_pair?(active, quarantined)

  defp valid_wire_counts?(_), do: false

  defp valid_count_pair?(active, quarantined),
    do: is_integer(active) and active >= 0 and is_integer(quarantined) and quarantined >= 0

  defp derive_reasons(regression, candidate, oracle, before_wire, attempts, counts) do
    before =
      Enum.map(before_wire, fn
        nil -> nil
        wire -> elem(ConfirmationRecord.decode_map(wire), 1)
      end)

    before_reason =
      case before do
        [%ConfirmationRecord{} = first, %ConfirmationRecord{} = second] ->
          case Regression.classify(regression, [first, second]) do
            {:ok, %{"status" => "failed"}} -> []
            _ -> ["passing_before"]
          end

        _ ->
          ["before_run_failed"]
      end

    {after_reasons, cross} =
      if before_reason == [] do
        baseline = regression.confirmed_record["observed_target_fingerprint"]

        after_reasons =
          attempts |> Enum.flat_map(&attempt_reasons(&1, regression, candidate, oracle, baseline))

        receipts =
          Enum.flat_map(attempts, fn attempt ->
            case Receipt.validate(attempt["receipt"]) do
              {:ok, receipt} -> [receipt]
              _ -> []
            end
          end)

        cross =
          case receipts do
            [first, second] ->
              cond do
                first["post_provenance"] != second["post_provenance"] ->
                  ["post_provenance_mismatch"]

                first["oracle"]["receipt_digest"] == second["oracle"]["receipt_digest"] ->
                  ["duplicate_after_run"]

                Enum.at(attempts, 0)["owner_fingerprint"] ==
                    Enum.at(attempts, 1)["owner_fingerprint"] ->
                  ["duplicate_after_run"]

                first["observation_run_fingerprint"] ==
                    second["observation_run_fingerprint"] ->
                  ["duplicate_after_run"]

                true ->
                  []
              end

            _other ->
              []
          end

        {after_reasons, cross}
      else
        {[], []}
      end

    count_reasons =
      if counts == %{"active" => 0, "quarantined" => 0}, do: [], else: ["executor_leak"]

    Enum.sort(Enum.uniq(before_reason ++ after_reasons ++ cross ++ count_reasons))
  end

  defp attempt_reasons(attempt, regression, candidate, oracle, baseline) do
    operational = if attempt["status"] == "completed", do: [], else: ["after_run_failed"]
    uncertainty = if attempt["uncertainty"] == [], do: [], else: ["after_uncertain"]
    target = if attempt["target_fingerprint"] == baseline, do: [], else: ["target_mismatch"]
    cleanup = if complete_cleanup?(attempt["cleanup"]), do: [], else: ["resource_leak"]

    case Receipt.validate(attempt["receipt"]) do
      {:ok, receipt} ->
        operational ++
          uncertainty ++
          target ++
          cleanup ++ receipt_reasons(receipt, attempt, regression, candidate, oracle, baseline)

      _ ->
        operational ++
          uncertainty ++ target ++ cleanup ++ [invalid_receipt_reason(attempt["receipt"])]
    end
  end

  defp invalid_receipt_reason(%{"gates" => gates}) when is_map(gates) and map_size(gates) != 3,
    do: "missing_gate"

  defp invalid_receipt_reason(_), do: "invalid_after_receipt"

  defp receipt_reasons(receipt, attempt, regression, candidate, oracle, baseline) do
    expected = regression.expectation["incident_fingerprint"]

    bindings =
      if receipt["regression_id"] == regression.id and receipt["candidate_id"] == candidate.id and
           receipt["scenario_id"] == regression.scenario["id"] and
           receipt["expected_fingerprint"] == expected and
           receipt["observer"] == regression.expectation["observer"] and
           receipt["oracle"]["identity"] == oracle and
           receipt["owner_fingerprint"] == attempt["owner_fingerprint"] and
           receipt["observation_run_fingerprint"] == attempt["owner_fingerprint"] and
           receipt["pre_provenance"]["fingerprint"] == baseline,
         do: [],
         else: ["receipt_binding_mismatch"]

    observed =
      cond do
        expected in receipt["observed_fingerprints"] -> ["failing_after"]
        receipt["observed_fingerprints"] != [] -> ["changed_failure"]
        true -> []
      end

    components = provenance_reasons(receipt["pre_provenance"], receipt["post_provenance"])

    gates =
      if Enum.all?(receipt["gates"], fn {_name, gate} -> gate["status"] == "passed" end),
        do: [],
        else: ["failed_gate"]

    bindings ++ observed ++ components ++ gates
  end

  defp provenance_reasons(pre, post) do
    unchanged = ["configuration", "dependencies", "runtime", "target"]

    cond do
      pre["components"]["code"]["fingerprint"] == post["components"]["code"]["fingerprint"] ->
        ["repair_not_applied"]

      Enum.any?(
        unchanged,
        &(pre["components"][&1]["fingerprint"] != post["components"][&1]["fingerprint"])
      ) ->
        ["target_mismatch"]

      true ->
        []
    end
  end

  @doc "Returns whether cleanup proves release with no resources remaining."
  @spec complete_cleanup?(term()) :: boolean()
  def complete_cleanup?(%{
        "status" => "complete",
        "release" => release,
        "remaining_count" => 0,
        "remaining_fingerprint" => nil
      }),
      do: release in ["complete", "failed"]

  def complete_cleanup?(_), do: false

  defp content(record), do: record |> to_wire_map() |> Map.drop(["id", "integrity"])

  defp valid_integrity?(%{"algorithm" => "sha256", "content_digest" => digest} = value),
    do: map_size(value) == 2 and digest?(digest)

  defp valid_integrity?(_), do: false

  defp valid_identity?(value), do: Ingress.identity?(value)
  defp id?("sha256:" <> digest), do: digest?(digest)
  defp id?(_), do: false

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp digest?(_), do: false

  defp hash(value),
    do: :sha256 |> :crypto.hash(Canonical.encode(value)) |> Base.encode16(case: :lower)

  defp invalid(reason),
    do:
      {:error,
       Error.new(:invalid_verification_record, "verification record is invalid", %{reason: reason})}
end

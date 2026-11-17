defmodule Insider.Sentinel.Verification.Receipt do
  @moduledoc "A strict bounded receipt from one trusted post-repair sandbox body."

  alias Insider.Event.Canonical
  alias Insider.Event.Value
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value, as: ProtocolValue
  alias Insider.Provenance
  alias Insider.Sentinel.ExternalProcess.Receipt, as: ExternalReceipt
  alias Insider.Sentinel.Verification.Ingress

  @schema "insider.verification-receipt/v1"
  @external_schema "insider.verification-receipt/v2"
  @keys [
    "candidate_id",
    "evidence",
    "expected_fingerprint",
    "gates",
    "observation_run_fingerprint",
    "observed_fingerprints",
    "observer",
    "oracle",
    "owner_fingerprint",
    "post_provenance",
    "pre_provenance",
    "regression_id",
    "scenario_id",
    "schema"
  ]
  @gate_names ["resources", "runtime", "static"]
  @option_keys [
    :candidate_id,
    :evidence,
    :expected_fingerprint,
    :gates,
    :observation_run_fingerprint,
    :observed_fingerprints,
    :observer,
    :oracle,
    :owner_fingerprint,
    :post_provenance,
    :pre_provenance,
    :regression_id,
    :scenario_id
  ]
  @maximum_bytes 32_768
  @external_keys Enum.sort(["external_execution" | @keys])
  @external_option_keys Enum.sort([:external_execution | @option_keys])

  @spec new(term()) :: {:ok, map()} | {:error, Error.t()}
  def new(options) do
    with true <- ProtocolValue.bounded_list?(options, 13),
         true <- Keyword.keyword?(options),
         true <- Enum.sort(Keyword.keys(options)) == @option_keys do
      validate(%{
        "schema" => @schema,
        "regression_id" => Keyword.fetch!(options, :regression_id),
        "candidate_id" => Keyword.fetch!(options, :candidate_id),
        "scenario_id" => Keyword.fetch!(options, :scenario_id),
        "expected_fingerprint" => Keyword.fetch!(options, :expected_fingerprint),
        "observer" => Keyword.fetch!(options, :observer),
        "owner_fingerprint" => Keyword.fetch!(options, :owner_fingerprint),
        "observation_run_fingerprint" => Keyword.fetch!(options, :observation_run_fingerprint),
        "pre_provenance" => Keyword.fetch!(options, :pre_provenance),
        "post_provenance" => Keyword.fetch!(options, :post_provenance),
        "observed_fingerprints" => Keyword.fetch!(options, :observed_fingerprints),
        "evidence" => Keyword.fetch!(options, :evidence),
        "oracle" => Keyword.fetch!(options, :oracle),
        "gates" => Keyword.fetch!(options, :gates)
      })
    else
      _other -> invalid(:invalid_options)
    end
  rescue
    _error -> invalid(:construction_failed)
  end

  @doc false
  @spec new_external(term()) :: {:ok, map()} | {:error, Error.t()}
  def new_external(options) do
    with true <- ProtocolValue.bounded_list?(options, 14),
         true <- Keyword.keyword?(options),
         true <- Enum.sort(Keyword.keys(options)) == @external_option_keys,
         external <- Keyword.fetch!(options, :external_execution),
         {:ok, receipt} <- new(Keyword.delete(options, :external_execution)) do
      receipt
      |> Map.put("schema", @external_schema)
      |> Map.put("external_execution", external)
      |> validate()
    else
      _other -> invalid(:invalid_options)
    end
  rescue
    _error -> invalid(:construction_failed)
  end

  @spec validate(term()) :: {:ok, map()} | {:error, Error.t()}
  def validate(%{"schema" => @external_schema} = receipt) do
    with true <- map_size(receipt) == length(@external_keys),
         true <- Enum.sort(Map.keys(receipt)) == @external_keys,
         {:ok, external} <- ExternalReceipt.validate(receipt["external_execution"]),
         {:ok, _v1} <-
           receipt |> Map.delete("external_execution") |> Map.put("schema", @schema) |> validate(),
         true <- external_coherent?(receipt, external),
         true <- byte_size(Canonical.encode(receipt)) <= @maximum_bytes do
      {:ok, receipt}
    else
      _other -> invalid(:invalid_external_receipt)
    end
  rescue
    _error -> invalid(:validation_failed)
  end

  def validate(receipt) when is_map(receipt) and not is_struct(receipt) do
    observed = receipt["observed_fingerprints"]

    with true <- map_size(receipt) == length(@keys) and Enum.sort(Map.keys(receipt)) == @keys,
         true <- receipt["schema"] == @schema,
         true <-
           Enum.all?(
             [
               "regression_id",
               "candidate_id",
               "scenario_id",
               "owner_fingerprint",
               "observation_run_fingerprint"
             ],
             &id?(receipt[&1])
           ),
         true <- digest?(receipt["expected_fingerprint"]),
         true <- identity?(receipt["observer"]),
         {:ok, pre} <- Provenance.decode_map(receipt["pre_provenance"]),
         {:ok, post} <- Provenance.decode_map(receipt["post_provenance"]),
         true <- Value.valid_list?(observed, 16, 2_048) and Enum.all?(observed, &digest?/1),
         true <- observed == Enum.sort(observed) and observed == Enum.uniq(observed),
         true <- evidence?(receipt["evidence"]),
         true <- oracle?(receipt["oracle"]),
         true <- gates?(receipt["gates"], post.components["code"]["fingerprint"]),
         true <- byte_size(Canonical.encode(receipt)) <= @maximum_bytes do
      {:ok,
       %{
         receipt
         | "pre_provenance" => Provenance.to_wire_map(pre),
           "post_provenance" => Provenance.to_wire_map(post)
       }}
    else
      _other -> invalid(:invalid_receipt)
    end
  rescue
    _error -> invalid(:validation_failed)
  end

  def validate(_value), do: invalid(:invalid_receipt)

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(receipt) do
    with {:ok, valid} <- validate(receipt), do: {:ok, Canonical.encode(valid)}
  end

  @spec decode(binary()) :: {:ok, map()} | {:error, Error.t()}
  def decode(value) do
    case Ingress.canonical_decode(value, @maximum_bytes, &decode_map/1) do
      {:ingress_error, :limit_exceeded} -> limit_exceeded()
      {:ingress_error, reason} -> invalid(reason)
      result -> result
    end
  end

  @spec decode_map(term()) :: {:ok, map()} | {:error, Error.t()}
  def decode_map(%{"schema" => schema}) when schema not in [@schema, @external_schema],
    do: unsupported_schema(schema)

  def decode_map(%{"schema" => schema} = receipt) when schema in [@schema, @external_schema],
    do: validate(receipt)

  def decode_map(value) when is_map(value) and not is_struct(value), do: unsupported_schema(nil)
  def decode_map(_value), do: invalid(:invalid_value)

  @spec to_wire_map(map()) :: map()
  def to_wire_map(receipt), do: receipt

  defp evidence?(
         %{
           "armed_before_scenario" => true,
           "complete" => true,
           "dropped" => 0,
           "finalized_after_scenario" => true,
           "gaps" => 0,
           "post_provenance_observed" => true,
           "scenario_status" => "completed",
           "truncated" => false
         } = evidence
       ),
       do: map_size(evidence) == 8

  defp evidence?(_value), do: false

  defp external_coherent?(receipt, external) do
    report = external["report"]

    external["owner_fingerprint"] == receipt["owner_fingerprint"] and
      external["target_fingerprint"] == receipt["pre_provenance"]["fingerprint"] and
      report["scenario_id"] == receipt["scenario_id"] and
      report["expected_fingerprint"] == receipt["expected_fingerprint"] and
      report["observer"] == receipt["observer"] and
      report["observed_fingerprints"] == receipt["observed_fingerprints"] and
      report["scenario_status"] == receipt["evidence"]["scenario_status"] and
      external["status"] == "exited" and external["exit_status"] == 0
  end

  defp oracle?(
         %{"identity" => identity, "receipt_digest" => digest, "status" => "passed"} = oracle
       ),
       do: map_size(oracle) == 3 and identity?(identity) and digest?(digest)

  defp oracle?(_value), do: false

  defp gates?(gates, code_fingerprint) when is_map(gates) and map_size(gates) == 3 do
    Enum.sort(Map.keys(gates)) == @gate_names and
      Enum.all?(gates, fn {_name, gate} -> gate?(gate, code_fingerprint) end)
  end

  defp gates?(_gates, _code), do: false

  defp gate?(
         %{"code_fingerprint" => code, "receipt_digest" => digest, "status" => status} = gate,
         expected
       ),
       do:
         map_size(gate) == 3 and code == expected and digest?(digest) and
           status in ["failed", "passed"]

  defp gate?(_gate, _expected), do: false

  defp identity?(value), do: Ingress.identity?(value)
  defp id?("sha256:" <> digest), do: digest?(digest)
  defp id?(_value), do: false

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp digest?(_value), do: false

  defp invalid(reason),
    do:
      {:error,
       Error.new(:invalid_verification_receipt, "verification receipt is invalid", %{
         reason: reason
       })}

  defp limit_exceeded,
    do:
      {:error,
       Error.new(
         :verification_receipt_limit_exceeded,
         "verification receipt exceeds its static limit"
       )}

  defp unsupported_schema(schema),
    do:
      {:error,
       Error.new(
         :unsupported_verification_receipt_schema,
         "verification receipt schema is unsupported",
         %{schema: ProtocolValue.summary(schema)}
       )}
end

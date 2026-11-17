defmodule Insider.Sentinel.ExternalProcess.Receipt do
  @moduledoc false

  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value
  alias Insider.Sentinel.ExternalProcess.Predicate
  alias Insider.Sentinel.Verification.Ingress

  @schema "insider.external-process-receipt/v1"
  @keys [
    "arm_fingerprint",
    "cleanup",
    "command_fingerprint",
    "exit_status",
    "id",
    "integrity",
    "lease_fingerprint",
    "lease_protocol",
    "machine_output_digest",
    "owner_fingerprint",
    "report",
    "schema",
    "status",
    "target_fingerprint"
  ]
  @maximum_bytes 16_384

  @spec new(map()) :: {:ok, map()} | {:error, Error.t()}
  def new(fields) when is_map(fields) and not is_struct(fields) do
    body = Map.put(fields, "schema", @schema)
    digest = hash(body)

    validate(
      Map.merge(body, %{
        "id" => "sha256:" <> digest,
        "integrity" => %{"algorithm" => "sha256", "content_digest" => digest}
      })
    )
  rescue
    _error -> invalid(:construction_failed)
  end

  def new(_fields), do: invalid(:invalid_fields)

  @spec validate(term()) :: {:ok, map()} | {:error, Error.t()}
  def validate(receipt) when is_map(receipt) and not is_struct(receipt) do
    content = Map.drop(receipt, ["id", "integrity"])
    digest = get_in(receipt, ["integrity", "content_digest"])

    if map_size(receipt) == length(@keys) and Enum.sort(Map.keys(receipt)) == @keys and
         receipt["schema"] == @schema and Predicate.id?(receipt["id"]) and
         receipt["integrity"] == %{"algorithm" => "sha256", "content_digest" => digest} and
         Predicate.digest?(digest) and receipt["id"] == "sha256:" <> digest and
         digest == hash(content) and Predicate.digest?(receipt["command_fingerprint"]) and
         Predicate.digest?(receipt["arm_fingerprint"]) and
         Predicate.digest?(receipt["lease_fingerprint"]) and
         Predicate.digest?(receipt["machine_output_digest"]) and
         Predicate.id?(receipt["owner_fingerprint"]) and
         Predicate.digest?(receipt["target_fingerprint"]) and receipt["status"] == "exited" and
         is_integer(receipt["exit_status"]) and receipt["exit_status"] in 0..255 and
         valid_protocol?(receipt["lease_protocol"]) and
         receipt["cleanup"] == %{"process" => "down"} and
         valid_report?(receipt["report"]) and coherent?(receipt) and
         Value.bounded_data?(receipt, @maximum_bytes) do
      {:ok, receipt}
    else
      invalid(:invalid_receipt)
    end
  rescue
    _error -> invalid(:validation_failed)
  end

  def validate(_receipt), do: invalid(:invalid_receipt)

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(receipt) do
    with {:ok, valid} <- validate(receipt), do: {:ok, Canonical.encode(valid)}
  end

  @spec decode(term()) :: {:ok, map()} | {:error, Error.t()}
  def decode(value) do
    case Ingress.canonical_decode(value, @maximum_bytes, &decode_map/1) do
      {:ingress_error, :limit_exceeded} ->
        {:error,
         Error.new(
           :external_process_receipt_limit_exceeded,
           "external process receipt exceeds its static limit"
         )}

      {:ingress_error, reason} ->
        invalid(reason)

      result ->
        result
    end
  end

  @spec decode_map(term()) :: {:ok, map()} | {:error, Error.t()}
  def decode_map(%{"schema" => schema}) when schema != @schema,
    do:
      {:error,
       Error.new(
         :unsupported_external_process_receipt_schema,
         "external process receipt schema is unsupported",
         %{schema: Value.summary(schema)}
       )}

  def decode_map(%{"schema" => @schema} = receipt), do: validate(receipt)

  def decode_map(value) when is_map(value) and not is_struct(value),
    do: decode_map(%{"schema" => nil})

  def decode_map(_value), do: invalid(:invalid_value)

  defp valid_protocol?(%{"armed" => 1, "finalized" => 3, "scenario" => 2} = protocol),
    do: map_size(protocol) == 3

  defp valid_protocol?(_protocol), do: false

  @doc false
  @spec valid_report?(term()) :: boolean()
  def valid_report?(
        %{
          "expected_fingerprint" => expected,
          "lease_fingerprint" => lease,
          "observed_fingerprints" => observed,
          "observer" => observer,
          "owner_fingerprint" => owner,
          "scenario_id" => scenario_id,
          "scenario_status" => scenario_status,
          "target_fingerprint" => target
        } = report
      ) do
    map_size(report) == 8 and Predicate.digest?(expected) and Predicate.digest?(lease) and
      digest_list?(observed) and
      Predicate.identity?(observer) and Predicate.id?(owner) and Predicate.id?(scenario_id) and
      scenario_status in ["completed", "failed"] and Predicate.digest?(target)
  end

  def valid_report?(_report), do: false

  defp coherent?(receipt),
    do:
      receipt["owner_fingerprint"] == receipt["report"]["owner_fingerprint"] and
        receipt["lease_fingerprint"] == receipt["report"]["lease_fingerprint"] and
        receipt["target_fingerprint"] == receipt["report"]["target_fingerprint"] and
        receipt["status"] == "exited" and
        receipt["machine_output_digest"] == hash(receipt["report"])

  defp digest_list?(values) do
    Value.bounded_list?(values, 16) and Enum.all?(values, &Predicate.digest?/1) and
      values == Enum.sort(Enum.uniq(values))
  end

  defp hash(value),
    do: :crypto.hash(:sha256, Canonical.encode(value)) |> Base.encode16(case: :lower)

  defp invalid(reason),
    do:
      {:error,
       Error.new(:invalid_external_process_receipt, "external process receipt is invalid", %{
         reason: reason
       })}
end

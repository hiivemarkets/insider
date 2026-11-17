defmodule Insider.Finding do
  @moduledoc """
  A bounded detector-neutral finding with statically validated details.

  Detector names remain strings at the trust boundary. Support is selected by
  literal detector/version clauses; external data never selects a module or
  creates an atom.
  """

  alias Insider.Event
  alias Insider.Event.Canonical
  alias Insider.Event.Value
  alias Insider.Detectors.Input
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value, as: ProtocolValue

  @schema "insider.finding/v1"
  @keys [
    "confidence",
    "details",
    "detector",
    "detector_version",
    "evidence_event_ids",
    "fingerprint",
    "occurred_at_us",
    "schema",
    "severity",
    "trigger_event_id"
  ]
  @option_keys [
    :detector,
    :detector_version,
    :occurred_at_us,
    :confidence,
    :severity,
    :trigger_event_id,
    :evidence_event_ids,
    :details
  ]
  @integer_max 9_223_372_036_854_775_807
  @integer_min -9_223_372_036_854_775_808

  @enforce_keys [
    :schema,
    :detector,
    :detector_version,
    :fingerprint,
    :occurred_at_us,
    :confidence,
    :severity,
    :trigger_event_id,
    :evidence_event_ids,
    :details
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) when is_list(options) do
    with true <- exact_options?(options),
         finding <-
           struct!(__MODULE__, Keyword.merge([schema: @schema, fingerprint: ""], options)),
         true <- pre_fingerprint_valid?(finding),
         fingerprint <- fingerprint(finding.detector, finding.detector_version, finding.details),
         %__MODULE__{} = finding <- %{finding | fingerprint: fingerprint},
         {:ok, finding} <- validate(finding) do
      {:ok, finding}
    else
      _error -> invalid()
    end
  rescue
    _error -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def new(_options), do: invalid()

  @spec new!(keyword()) :: t()
  def new!(options) do
    case new(options) do
      {:ok, finding} -> finding
      {:error, _error} -> raise ArgumentError, "invalid finding"
    end
  end

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = finding) do
    expected = struct(__MODULE__)
    wire = to_wire_map(finding)

    if map_size(finding) == map_size(expected) and
         Enum.sort(Map.keys(finding)) == Enum.sort(Map.keys(expected)) and valid_wire?(wire) do
      {:ok, finding}
    else
      invalid()
    end
  rescue
    _error -> invalid()
  end

  def validate(_finding), do: invalid()

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(wire) when is_map(wire) and not is_struct(wire) do
    if valid_wire?(wire) do
      {:ok,
       %__MODULE__{
         schema: wire["schema"],
         detector: wire["detector"],
         detector_version: wire["detector_version"],
         fingerprint: wire["fingerprint"],
         occurred_at_us: wire["occurred_at_us"],
         confidence: wire["confidence"],
         severity: wire["severity"],
         trigger_event_id: wire["trigger_event_id"],
         evidence_event_ids: wire["evidence_event_ids"],
         details: wire["details"]
       }}
    else
      invalid()
    end
  rescue
    _error -> invalid()
  end

  def decode_map(_wire), do: invalid()

  @doc "Returns the canonical digest that binds one exact evidence event to a finding."
  @spec evidence_event_fingerprint(Event.t() | map()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def evidence_event_fingerprint(%Event{} = event),
    do: event |> Event.to_wire_map() |> evidence_event_fingerprint()

  def evidence_event_fingerprint(wire) when is_map(wire) and not is_struct(wire) do
    with {:ok, _event} <- Event.decode_map(wire) do
      {:ok,
       wire
       |> Canonical.encode()
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.encode16(case: :lower)}
    else
      _error -> invalid()
    end
  rescue
    _error -> invalid()
  end

  def evidence_event_fingerprint(_event), do: invalid()

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = finding) do
    %{
      "schema" => finding.schema,
      "detector" => finding.detector,
      "detector_version" => finding.detector_version,
      "fingerprint" => finding.fingerprint,
      "occurred_at_us" => finding.occurred_at_us,
      "confidence" => finding.confidence,
      "severity" => finding.severity,
      "trigger_event_id" => finding.trigger_event_id,
      "evidence_event_ids" => finding.evidence_event_ids,
      "details" => finding.details
    }
  end

  @spec valid_wire?(term()) :: boolean()
  def valid_wire?(wire) when is_map(wire) and not is_struct(wire) do
    exact_keys?(wire, @keys) and wire["schema"] == @schema and
      signed_integer?(wire["occurred_at_us"]) and Input.bounded_id?(wire["trigger_event_id"]) and
      valid_id_list?(wire["evidence_event_ids"]) and
      List.last(wire["evidence_event_ids"]) == wire["trigger_event_id"] and
      Value.valid_map?(wire["details"], 32, 16_384) and detector_valid?(wire) and
      Input.digest?(wire["fingerprint"]) and
      wire["fingerprint"] ==
        fingerprint(wire["detector"], wire["detector_version"], wire["details"]) and
      byte_size(Canonical.encode(wire)) <= 32_768
  rescue
    _error -> false
  end

  def valid_wire?(_wire), do: false

  defp pre_fingerprint_valid?(finding) do
    wire = to_wire_map(finding)

    signed_integer?(wire["occurred_at_us"]) and
      Input.bounded_id?(wire["trigger_event_id"]) and
      valid_id_list?(wire["evidence_event_ids"]) and
      List.last(wire["evidence_event_ids"]) == wire["trigger_event_id"] and
      Value.valid_map?(wire["details"], 32, 16_384) and detector_valid?(wire)
  end

  defp detector_valid?(%{
         "detector" => "restart_recurrence",
         "detector_version" => "1",
         "confidence" => "medium",
         "severity" => "error",
         "evidence_event_ids" => evidence,
         "details" => details
       }) do
    keys = ["count", "identity", "reason_fingerprints", "window_ms"]

    exact_keys?(details, keys) and details["count"] in 2..32 and
      details["count"] == length(evidence) and details["window_ms"] in 1..60_000 and
      restart_identity?(details["identity"]) and
      valid_digest_list?(details["reason_fingerprints"])
  end

  defp detector_valid?(%{
         "detector" => "mailbox_growth",
         "detector_version" => "1",
         "confidence" => "medium",
         "severity" => "warning",
         "evidence_event_ids" => evidence,
         "details" => details
       }) do
    keys = [
      "identity",
      "queue_end",
      "queue_growth",
      "queue_start",
      "reductions_end",
      "reductions_start",
      "sample_count",
      "window_ms"
    ]

    exact_keys?(details, keys) and details["sample_count"] in 3..32 and
      details["sample_count"] == length(evidence) and details["window_ms"] in 1..60_000 and
      mailbox_identity?(details["identity"]) and counters_valid?(details)
  end

  defp detector_valid?(%{
         "detector" => "semantic_invariant",
         "detector_version" => "1",
         "confidence" => "high",
         "severity" => "error",
         "evidence_event_ids" => evidence,
         "details" => %{"identity" => identity} = details
       }),
       do: semantic_evidence_valid?(details, identity, evidence)

  defp detector_valid?(_wire), do: false

  defp semantic_evidence_valid?(details, identity, [_trigger]) when map_size(details) == 1,
    do: semantic_identity?(identity)

  defp semantic_evidence_valid?(
         %{"evidence_event_fingerprints" => fingerprints} = details,
         identity,
         [_, _ | _] = evidence
       )
       when map_size(details) == 2,
       do:
         semantic_identity?(identity) and valid_digest_list?(fingerprints) and
           length(fingerprints) == length(evidence)

  defp semantic_evidence_valid?(_details, _identity, _evidence), do: false

  defp counters_valid?(details) do
    Enum.all?(
      ["queue_start", "queue_end", "reductions_start", "reductions_end"],
      &(is_integer(details[&1]) and details[&1] in 0..@integer_max)
    ) and is_integer(details["queue_growth"]) and details["queue_growth"] in 1..@integer_max and
      details["queue_end"] > details["queue_start"] and
      details["queue_growth"] == details["queue_end"] - details["queue_start"] and
      details["reductions_start"] == details["reductions_end"]
  end

  defp restart_identity?(
         %{
           "boot_id" => boot_id,
           "node" => node,
           "offender_id" => offender_id,
           "supervisor" => supervisor
         } = identity
       )
       when map_size(identity) == 4,
       do:
         Input.bounded_id?(boot_id) and Input.bounded_string?(node, 256) and
           Input.bounded_string?(offender_id, 320) and Input.bounded_string?(supervisor, 320)

  defp restart_identity?(_identity), do: false

  defp mailbox_identity?(
         %{
           "boot_id" => boot_id,
           "node" => node,
           "process_generation" => generation,
           "process_pid" => pid
         } = identity
       )
       when map_size(identity) == 4,
       do:
         Input.bounded_id?(boot_id) and Input.bounded_string?(node, 256) and
           Input.canonical_pid?(pid) and (is_nil(generation) or Input.bounded_id?(generation))

  defp mailbox_identity?(_identity), do: false

  defp semantic_identity?(
         %{
           "contract_fingerprint" => fingerprint,
           "contract_id" => contract_id,
           "contract_version" => version,
           "invariant" => invariant
         } = identity
       )
       when map_size(identity) == 4,
       do:
         contract_fingerprint?(fingerprint) and Input.bounded_id?(contract_id) and
           is_integer(version) and version in 1..1_000_000 and Input.bounded_id?(invariant)

  defp semantic_identity?(_identity), do: false

  defp contract_fingerprint?("sha256:" <> digest), do: Input.digest?(digest)
  defp contract_fingerprint?(_fingerprint), do: false

  defp fingerprint(detector, version, details) do
    identity = if is_map(details), do: Map.get(details, "identity"), else: nil

    %{"detector" => detector, "version" => version, "identity" => identity}
    |> Canonical.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp exact_options?(options) do
    ProtocolValue.bounded_list?(options, length(@option_keys)) and Keyword.keyword?(options) and
      Enum.sort(Keyword.keys(options)) == Enum.sort(@option_keys)
  end

  defp exact_keys?(map, keys),
    do: map_size(map) == length(keys) and Enum.sort(Map.keys(map)) == keys

  defp valid_id_list?(values),
    do:
      ProtocolValue.bounded_list?(values, 32) and values != [] and
        Enum.all?(values, &Input.bounded_id?/1) and Enum.uniq(values) == values

  defp valid_digest_list?(values),
    do:
      ProtocolValue.bounded_list?(values, 32) and Enum.all?(values, &Input.digest?/1) and
        Enum.uniq(values) == values

  defp signed_integer?(value), do: is_integer(value) and value in @integer_min..@integer_max

  defp invalid, do: {:error, Error.new(:invalid_capsule, "finding is invalid")}
end

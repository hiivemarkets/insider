defmodule Insider.Observability.Export do
  @moduledoc """
  A bounded, vendor-neutral projection of a validated incident capsule.

  An export is inert data for a host-owned asynchronous client. It contains no
  event bodies, payloads, artifact references, endpoints, credentials, client
  callbacks, or delivery claims. Constructing or decoding one never performs
  network work and grants no collection or transport authority.
  """

  alias Insider.Event.Canonical
  alias Insider.Incident.Capsule
  alias Insider.Incident.Source
  alias Insider.Observability.Codec
  alias Insider.Protocol.Error
  alias Insider.Protocol.Value

  @schema "insider.observability-export/v1"
  @providers ["datadog", "sentry"]
  @wire_keys [
    "destination_fingerprint",
    "evidence",
    "finding",
    "id",
    "idempotency_key",
    "incident_id",
    "provider",
    "schema"
  ]
  @body_keys @wire_keys -- ["id"]
  @maximum_bytes 4_096
  @maximum_capsule_bytes 1_048_576
  @maximum_events 64
  @maximum_manifest_records 512

  @enforce_keys [
    :schema,
    :id,
    :provider,
    :destination_fingerprint,
    :incident_id,
    :idempotency_key,
    :finding,
    :evidence
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @doc """
  Derives the only fields approved by the v1 observability boundary.

  `destination_fingerprint` is a host-owned opaque SHA-256 identity. It is not
  a URL, DSN, site, project name, credential, or proof of authorization.
  """
  @spec new(Capsule.t(), String.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%Capsule{} = capsule, provider, destination_fingerprint) do
    with {:ok, capsule} <- Capsule.validate(capsule),
         true <- provider in @providers,
         true <- digest?(destination_fingerprint),
         body <- body(capsule, provider, destination_fingerprint),
         export <- from_body(body),
         {:ok, export} <- validate(export) do
      {:ok, export}
    else
      {:error, %Error{}} -> invalid()
      _other -> invalid()
    end
  rescue
    _error -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def new(_capsule, _provider, _destination_fingerprint), do: invalid()

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = export) do
    wire = to_wire_map(export)

    cond do
      not exact_struct?(export) or not valid_wire_shape?(wire) ->
        invalid()

      export.id != content_id(Map.drop(wire, ["id"])) ->
        integrity_failed()

      byte_size(Canonical.encode(wire)) > @maximum_bytes ->
        limit_exceeded()

      true ->
        {:ok, export}
    end
  rescue
    _error -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def validate(_export), do: invalid()

  @doc """
  Re-derives an export from its complete capsule graph and requires exact equality.

  Standalone validation proves only bounded canonical identity, not that an
  export was authored from the referenced capsule. Host integrations must use
  this function immediately before provider mapping.
  """
  @spec validate_against_capsule(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate_against_capsule(%__MODULE__{} = export, %Capsule{} = capsule) do
    with {:ok, export} <- validate(export),
         {:ok, expected} <- new(capsule, export.provider, export.destination_fingerprint),
         true <- export == expected do
      {:ok, export}
    else
      _other -> integrity_failed()
    end
  rescue
    _error -> integrity_failed()
  catch
    _kind, _reason -> integrity_failed()
  end

  def validate_against_capsule(_export, _capsule), do: integrity_failed()

  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(binary),
    do: Codec.decode(binary, @maximum_bytes, &decode_map/1, invalid(), limit_exceeded())

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(wire) when is_map(wire) and not is_struct(wire) do
    cond do
      Map.get(wire, "schema") != @schema ->
        unsupported_schema()

      Enum.sort(Map.keys(wire)) != @wire_keys or map_size(wire) != length(@wire_keys) ->
        invalid()

      true ->
        wire
        |> then(&struct!(__MODULE__, struct_fields(&1)))
        |> validate()
    end
  rescue
    _error -> invalid()
  end

  def decode_map(_wire), do: invalid()

  @spec canonical_binary(term()) :: {:ok, binary()} | {:error, Error.t()}
  def canonical_binary(export),
    do: Codec.encode_validated(export, &validate/1, &to_wire_map/1)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = export) do
    %{
      "schema" => export.schema,
      "id" => export.id,
      "provider" => export.provider,
      "destination_fingerprint" => export.destination_fingerprint,
      "incident_id" => export.incident_id,
      "idempotency_key" => export.idempotency_key,
      "finding" => export.finding,
      "evidence" => export.evidence
    }
  end

  defp body(capsule, provider, destination_fingerprint) do
    %{
      "schema" => @schema,
      "provider" => provider,
      "destination_fingerprint" => destination_fingerprint,
      "incident_id" => capsule.id,
      "idempotency_key" =>
        Canonical.sha256(%{
          "destination_fingerprint" => destination_fingerprint,
          "incident_id" => capsule.id,
          "provider" => provider,
          "schema" => @schema
        }),
      "finding" => %{
        "confidence" => capsule.finding["confidence"],
        "detector" => capsule.finding["detector"],
        "detector_version" => capsule.finding["detector_version"],
        "fingerprint" => capsule.finding["fingerprint"],
        "severity" => capsule.finding["severity"]
      },
      "evidence" => %{
        "completeness" => capsule.snapshot["completeness"],
        "gaps" => capsule.snapshot["gaps"],
        "redaction_manifest_records" => length(capsule.redaction["manifest"]),
        "retained_bytes" => capsule.snapshot["retained_bytes"],
        "retained_events" => capsule.snapshot["retained_count"]
      }
    }
  end

  defp from_body(body) do
    body
    |> Map.put("id", content_id(body))
    |> then(&struct!(__MODULE__, struct_fields(&1)))
  end

  defp struct_fields(wire) do
    [
      schema: wire["schema"],
      id: wire["id"],
      provider: wire["provider"],
      destination_fingerprint: wire["destination_fingerprint"],
      incident_id: wire["incident_id"],
      idempotency_key: wire["idempotency_key"],
      finding: wire["finding"],
      evidence: wire["evidence"]
    ]
  end

  defp valid_wire_shape?(wire) do
    exact_keys?(wire, @wire_keys) and wire["schema"] == @schema and
      wire["provider"] in @providers and digest?(wire["destination_fingerprint"]) and
      content_reference?(wire["incident_id"]) and digest?(wire["idempotency_key"]) and
      content_reference?(wire["id"]) and valid_finding?(wire["finding"]) and
      valid_evidence?(wire["evidence"]) and
      evidence_coherent_with_finding?(wire["evidence"], wire["finding"]) and
      wire["idempotency_key"] == expected_idempotency_key(wire)
  end

  defp valid_finding?(finding) when is_map(finding) and not is_struct(finding) do
    exact_keys?(finding, [
      "confidence",
      "detector",
      "detector_version",
      "fingerprint",
      "severity"
    ]) and valid_finding_vocabulary?(finding) and digest?(finding["fingerprint"])
  end

  defp valid_finding?(_finding), do: false

  defp valid_finding_vocabulary?(%{
         "detector" => "restart_recurrence",
         "detector_version" => "1",
         "confidence" => "medium",
         "severity" => "error"
       }),
       do: true

  defp valid_finding_vocabulary?(%{
         "detector" => "mailbox_growth",
         "detector_version" => "1",
         "confidence" => "medium",
         "severity" => "warning"
       }),
       do: true

  defp valid_finding_vocabulary?(%{
         "detector" => "semantic_invariant",
         "detector_version" => "1",
         "confidence" => "high",
         "severity" => "error"
       }),
       do: true

  defp valid_finding_vocabulary?(_finding), do: false

  defp valid_evidence?(evidence) when is_map(evidence) and not is_struct(evidence) do
    exact_keys?(evidence, [
      "completeness",
      "gaps",
      "redaction_manifest_records",
      "retained_bytes",
      "retained_events"
    ]) and evidence["completeness"] in ["complete", "incomplete"] and
      valid_gaps?(evidence["gaps"]) and Source.coherent_completeness?(evidence) and
      bounded_non_negative_integer?(
        evidence["redaction_manifest_records"],
        @maximum_manifest_records
      ) and bounded_positive_integer?(evidence["retained_bytes"], @maximum_capsule_bytes) and
      bounded_positive_integer?(evidence["retained_events"], @maximum_events) and
      evidence["retained_bytes"] >= evidence["retained_events"]
  end

  defp valid_evidence?(_evidence), do: false

  defp evidence_coherent_with_finding?(evidence, %{"detector" => "restart_recurrence"}),
    do: evidence["retained_events"] >= 2

  defp evidence_coherent_with_finding?(evidence, %{"detector" => "mailbox_growth"}),
    do: evidence["retained_events"] >= 3

  defp evidence_coherent_with_finding?(evidence, %{"detector" => "semantic_invariant"}),
    do: evidence["retained_events"] >= 1

  defp evidence_coherent_with_finding?(_evidence, _finding), do: false

  defp valid_gaps?(gaps) do
    allowed = [
      "dropped_evidence",
      "evicted_evidence",
      "prehistory_unavailable",
      "recovered_after_owner_death"
    ]

    Value.bounded_list?(gaps, 4) and Enum.all?(gaps, &(&1 in allowed)) and
      gaps == Enum.sort(gaps) and gaps == Enum.uniq(gaps)
  end

  defp expected_idempotency_key(wire) do
    Canonical.sha256(%{
      "destination_fingerprint" => wire["destination_fingerprint"],
      "incident_id" => wire["incident_id"],
      "provider" => wire["provider"],
      "schema" => @schema
    })
  end

  defp content_id(body) when map_size(body) == length(@body_keys),
    do: "sha256:" <> Canonical.sha256(body)

  defp exact_struct?(export) do
    expected = struct(__MODULE__)

    map_size(export) == map_size(expected) and
      Map.keys(export) |> Enum.sort() == Map.keys(expected) |> Enum.sort()
  end

  defp exact_keys?(map, keys),
    do: map_size(map) == length(keys) and Enum.sort(Map.keys(map)) == keys

  defp bounded_non_negative_integer?(value, maximum),
    do: is_integer(value) and value in 0..maximum

  defp bounded_positive_integer?(value, maximum),
    do: is_integer(value) and value in 1..maximum

  defp digest?(value), do: is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{64}\z/)
  defp content_reference?("sha256:" <> digest), do: digest?(digest)
  defp content_reference?(_value), do: false

  defp invalid,
    do: {:error, Error.new(:invalid_observability_export, "observability export is invalid")}

  defp integrity_failed,
    do:
      {:error,
       Error.new(
         :observability_export_integrity_failed,
         "observability export identity is invalid"
       )}

  defp limit_exceeded,
    do:
      {:error,
       Error.new(:observability_export_limit_exceeded, "observability export exceeds its bound")}

  defp unsupported_schema,
    do:
      {:error,
       Error.new(
         :unsupported_observability_export_schema,
         "observability export schema is unsupported"
       )}
end

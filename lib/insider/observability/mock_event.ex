defmodule Insider.Observability.MockEvent do
  @moduledoc """
  A canonical, provider-shaped mock event derived from an observability export.

  Mock events are inert local values. `mock` is always `true`, delivery is
  always `not_attempted`, and the handoff metadata assigns any asynchronous
  handling to the host application. This module has no transport operation and
  mapping a value is not evidence that a provider accepted it.
  """

  alias Insider.Event.Canonical
  alias Insider.Incident.Capsule
  alias Insider.Observability.Codec
  alias Insider.Observability.Export
  alias Insider.Protocol.Error

  @schema "insider.observability-mock-event/v1"
  @handoff %{
    "contract" => "insider.mock-host-client/v1",
    "mode" => "asynchronous",
    "owner" => "host_application"
  }
  @providers ["datadog", "sentry"]
  @wire_keys [
    "body",
    "delivery_status",
    "export",
    "handoff",
    "id",
    "idempotency_key",
    "mock",
    "provider",
    "schema"
  ]
  @body_keys @wire_keys -- ["id"]
  @maximum_bytes 8_192

  @enforce_keys [
    :schema,
    :id,
    :mock,
    :delivery_status,
    :provider,
    :idempotency_key,
    :handoff,
    :export,
    :body
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @doc """
  Maps an exact capsule-bound export to a provider-shaped mock value.

  `expected_provider` prevents a provider-specific adapter from accepting an
  export addressed to the other provider.
  """
  @spec new(Export.t(), Capsule.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%Export{} = export, %Capsule{} = capsule, expected_provider)
      when expected_provider in @providers do
    with true <- export.provider == expected_provider,
         {:ok, export} <- Export.validate_against_capsule(export, capsule),
         event <- from_export(export),
         {:ok, event} <- validate(event) do
      {:ok, event}
    else
      _other -> invalid()
    end
  rescue
    _error -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def new(_export, _capsule, _expected_provider), do: invalid()

  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = event) do
    wire = to_wire_map(event)

    with true <- exact_struct?(event),
         true <- exact_keys?(wire, @wire_keys),
         true <- event.schema == @schema,
         true <- event.mock == true,
         true <- event.delivery_status == "not_attempted",
         true <- event.provider in @providers,
         true <- event.handoff == @handoff,
         {:ok, export} <- Export.decode_map(event.export),
         true <- export.provider == event.provider,
         true <- event.idempotency_key == expected_idempotency_key(export),
         true <- event.body == provider_body(export),
         true <- event.id == content_id(Map.drop(wire, ["id"])),
         true <- byte_size(Canonical.encode(wire)) <= @maximum_bytes do
      {:ok, event}
    else
      _other -> invalid()
    end
  rescue
    _error -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def validate(_event), do: invalid()

  @doc """
  Recomputes the entire mapping from the referenced capsule and compares it.
  """
  @spec validate_against_capsule(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate_against_capsule(%__MODULE__{} = event, %Capsule{} = capsule) do
    with {:ok, event} <- validate(event),
         {:ok, export} <- Export.decode_map(event.export),
         {:ok, expected} <- new(export, capsule, event.provider),
         true <- event == expected do
      {:ok, event}
    else
      _other -> integrity_failed()
    end
  rescue
    _error -> integrity_failed()
  catch
    _kind, _reason -> integrity_failed()
  end

  def validate_against_capsule(_event, _capsule), do: integrity_failed()

  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(binary),
    do: Codec.decode(binary, @maximum_bytes, &decode_map/1, invalid(), limit_exceeded())

  @spec decode_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode_map(wire) when is_map(wire) and not is_struct(wire) do
    cond do
      Map.get(wire, "schema") != @schema ->
        unsupported_schema()

      not exact_keys?(wire, @wire_keys) ->
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
  def canonical_binary(event),
    do: Codec.encode_validated(event, &validate/1, &to_wire_map/1)

  @spec to_wire_map(t()) :: map()
  def to_wire_map(%__MODULE__{} = event) do
    %{
      "schema" => event.schema,
      "id" => event.id,
      "mock" => event.mock,
      "delivery_status" => event.delivery_status,
      "provider" => event.provider,
      "idempotency_key" => event.idempotency_key,
      "handoff" => event.handoff,
      "export" => event.export,
      "body" => event.body
    }
  end

  defp from_export(export) do
    export_wire = Export.to_wire_map(export)

    body = %{
      "schema" => @schema,
      "mock" => true,
      "delivery_status" => "not_attempted",
      "provider" => export.provider,
      "idempotency_key" => expected_idempotency_key(export),
      "handoff" => @handoff,
      "export" => export_wire,
      "body" => provider_body(export)
    }

    body
    |> Map.put("id", content_id(body))
    |> then(&struct!(__MODULE__, struct_fields(&1)))
  end

  defp provider_body(%Export{provider: "sentry"} = export) do
    %{
      "event_id" => sentry_event_id(export),
      "extra" => %{
        "incident_id" => export.incident_id,
        "observability_export_id" => export.id,
        "insider" => %{
          "completeness" => export.evidence["completeness"],
          "gaps" => export.evidence["gaps"],
          "redaction_manifest_records" => export.evidence["redaction_manifest_records"],
          "retained_bytes" => export.evidence["retained_bytes"],
          "retained_events" => export.evidence["retained_events"]
        }
      },
      "fingerprint" => [export.finding["fingerprint"]],
      "level" => sentry_level(export.finding["severity"]),
      "logentry" => %{"formatted" => finding_summary(export)},
      "logger" => "insider",
      "platform" => "elixir",
      "tags" => %{
        "insider.confidence" => export.finding["confidence"],
        "insider.detector" => export.finding["detector"],
        "insider.detector_version" => export.finding["detector_version"],
        "insider.evidence_completeness" => export.evidence["completeness"],
        "insider.mock" => "true"
      }
    }
  end

  defp provider_body(%Export{provider: "datadog"} = export) do
    %{
      "data" => %{
        "attributes" => %{
          "aggregation_key" => export.finding["fingerprint"],
          "attributes" => %{
            "custom" => %{
              "confidence" => export.finding["confidence"],
              "detector" => export.finding["detector"],
              "detector_version" => export.finding["detector_version"],
              "evidence_completeness" => export.evidence["completeness"],
              "evidence_gaps" => export.evidence["gaps"],
              "incident_id" => export.incident_id,
              "mock" => true,
              "observability_export_id" => export.id,
              "redaction_manifest_records" => export.evidence["redaction_manifest_records"],
              "retained_bytes" => export.evidence["retained_bytes"],
              "retained_events" => export.evidence["retained_events"]
            },
            "status" => datadog_status(export.finding["severity"])
          },
          "category" => "alert",
          "message" => finding_summary(export),
          "tags" => [
            "insider_confidence:#{export.finding["confidence"]}",
            "insider_detector:#{export.finding["detector"]}",
            "insider_evidence_completeness:#{export.evidence["completeness"]}",
            "insider_mock:true"
          ],
          "title" => "Insider #{export.finding["detector"]} finding"
        },
        "type" => "event"
      }
    }
  end

  defp finding_summary(export) do
    "Insider runtime finding: #{export.finding["detector"]} " <>
      "(#{export.finding["severity"]}, #{export.finding["confidence"]} confidence)"
  end

  # Sentry accepts a 32-character UUIDv4 without hyphens. The version and
  # variant nibbles are fixed while the remaining identity stays deterministic.
  defp sentry_event_id(export) do
    id = String.slice(expected_idempotency_key(export), 0, 32)
    prefix = binary_part(id, 0, 12)
    middle = binary_part(id, 13, 3)
    variant = binary_part(id, 16, 1)
    suffix = binary_part(id, 17, 15)

    prefix <> "4" <> middle <> sentry_variant(variant) <> suffix
  end

  defp sentry_variant(<<nibble>>) when nibble in ?0..?3, do: "8"
  defp sentry_variant(<<nibble>>) when nibble in ?4..?7, do: "9"
  defp sentry_variant(<<nibble>>) when nibble in ?8..?b, do: "a"
  defp sentry_variant(<<_nibble>>), do: "b"

  defp sentry_level("warning"), do: "warning"
  defp sentry_level("error"), do: "error"
  defp datadog_status("warning"), do: "warn"
  defp datadog_status("error"), do: "error"

  defp expected_idempotency_key(export) do
    Canonical.sha256(%{
      "export_id" => export.id,
      "provider" => export.provider,
      "schema" => @schema
    })
  end

  defp content_id(body) when map_size(body) == length(@body_keys),
    do: "sha256:" <> Canonical.sha256(body)

  defp struct_fields(wire) do
    [
      schema: wire["schema"],
      id: wire["id"],
      mock: wire["mock"],
      delivery_status: wire["delivery_status"],
      provider: wire["provider"],
      idempotency_key: wire["idempotency_key"],
      handoff: wire["handoff"],
      export: wire["export"],
      body: wire["body"]
    ]
  end

  defp exact_struct?(event) do
    expected = struct(__MODULE__)

    map_size(event) == map_size(expected) and
      Enum.sort(Map.keys(event)) == Enum.sort(Map.keys(expected))
  end

  defp exact_keys?(map, keys),
    do: map_size(map) == length(keys) and Enum.sort(Map.keys(map)) == keys

  defp invalid,
    do: {:error, Error.new(:invalid_observability_mock_event, "mock event is invalid")}

  defp integrity_failed,
    do:
      {:error,
       Error.new(
         :observability_mock_event_integrity_failed,
         "mock event does not match its capsule"
       )}

  defp limit_exceeded,
    do:
      {:error,
       Error.new(:observability_mock_event_limit_exceeded, "mock event exceeds its bound")}

  defp unsupported_schema,
    do:
      {:error,
       Error.new(
         :unsupported_observability_mock_event_schema,
         "mock event schema is unsupported"
       )}
end

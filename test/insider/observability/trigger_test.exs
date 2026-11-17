defmodule Insider.Observability.TriggerTest do
  use ExUnit.Case, async: true

  alias Insider.Event.Canonical
  alias Insider.Observability.Trigger
  alias Insider.Protocol.Error

  test "freeze and follow-up requests have an exact canonical round trip" do
    for operation <- ["freeze", "follow_up"] do
      trigger = trigger!(operation: operation)
      wire = Trigger.to_wire_map(trigger)

      assert Enum.sort(Map.keys(wire)) == [
               "external_event_fingerprint",
               "external_incident_fingerprint",
               "id",
               "operation",
               "provider",
               "schema"
             ]

      assert wire["schema"] == "insider.observability-trigger/v1"
      assert {:ok, ^trigger} = Trigger.validate(trigger)
      assert {:ok, ^trigger} = Trigger.decode_map(wire)
      assert {:ok, encoded} = Trigger.canonical_binary(trigger)
      assert encoded == Canonical.encode(wire)
      assert {:ok, ^trigger} = Trigger.decode(encoded)
    end
  end

  test "frozen v1 canonical bytes remain compatible" do
    bytes = fixture_bytes("observability_trigger_v1.json")

    assert {:ok, trigger} = Trigger.decode(bytes)
    assert trigger.operation == "follow_up"
    assert trigger.provider == "sentry"
    assert {:ok, ^bytes} = Trigger.canonical_binary(trigger)
  end

  test "content identity is deterministic, content-sensitive, and the idempotency key" do
    first = trigger!()
    duplicate = trigger!()
    changed = trigger!(external_incident_fingerprint: String.duplicate("c", 64))

    assert first == duplicate
    assert first.id == duplicate.id
    assert String.match?(first.id, ~r/\Asha256:[0-9a-f]{64}\z/)
    assert first.id != changed.id
    assert {:ok, first.id} == Trigger.idempotency_key(first)

    assert_invalid(%{first | id: changed.id})
  end

  test "the contract cannot represent policy, authority, execution, or transport controls" do
    wire = trigger!() |> Trigger.to_wire_map()

    for forbidden <- [
          "environment",
          "runtime_policy",
          "authority",
          "target",
          "targets",
          "collection_scope",
          "redaction",
          "callback",
          "endpoint",
          "credential"
        ] do
      assert_invalid(Map.put(wire, forbidden, "attacker-controlled"))
    end

    assert {:error, %Error{code: :invalid_request}} =
             Trigger.new(
               operation: "freeze",
               provider: "sentry",
               external_event_fingerprint: String.duplicate("a", 64),
               external_incident_fingerprint: String.duplicate("b", 64),
               callback: fn -> :network end
             )
  end

  test "provider is bounded and correlation values must be host-produced fingerprints" do
    assert trigger!(provider: String.duplicate("p", 64))
    assert trigger!(external_event_fingerprint: String.duplicate("e", 64))
    assert trigger!(external_incident_fingerprint: String.duplicate("f", 64))

    for options <- [
          [provider: String.duplicate("p", 65)],
          [provider: "Sentry"],
          [provider: "https://vendor.example"],
          [external_event_fingerprint: "sk_live_51JSECRET123"],
          [external_event_fingerprint: String.duplicate("e", 63)],
          [external_event_fingerprint: String.duplicate("E", 64)],
          [external_incident_fingerprint: "incident-123"],
          [external_event_fingerprint: nil],
          [external_incident_fingerprint: nil]
        ] do
      assert {:error, %Error{code: :invalid_request}} = Trigger.new(options(options))
    end
  end

  test "unknown operations, versions, fields, atom keys, and malformed shapes fail closed" do
    wire = trigger!() |> Trigger.to_wire_map()

    for malformed <- [
          Map.put(wire, "operation", "start_session"),
          Map.put(wire, "schema", "insider.observability-trigger/v2"),
          Map.put(wire, "unknown", true),
          Map.put(wire, :provider, "sentry"),
          Map.delete(wire, "provider"),
          Map.put(wire, "external_event_fingerprint", self()),
          [],
          nil
        ] do
      assert {:error, %Error{}} = Trigger.decode_map(malformed)
    end

    assert {:error, %Error{code: :invalid_request}} = Trigger.new(:invalid)
    assert {:error, %Error{code: :invalid_request}} = Trigger.validate(%{})
    assert {:error, %Error{code: :invalid_request}} = Trigger.canonical_binary(%{})
    assert {:error, %Error{code: :invalid_request}} = Trigger.idempotency_key(%{})

    trigger = trigger!()
    assert_invalid(Map.put(trigger, :hidden, true))

    assert {:error, %Error{code: :unsupported_protocol_version}} =
             wire
             |> Map.put("schema", "insider.observability-trigger/v2")
             |> Canonical.encode()
             |> Trigger.decode()
  end

  test "decoding never creates atoms from provider or external identifiers" do
    wire = trigger!() |> Trigger.to_wire_map()
    unknown = "provider_#{System.unique_integer([:positive, :monotonic])}"
    encoded = wire |> Map.put("provider", unknown) |> reidentify() |> Canonical.encode()

    assert {:ok, trigger} = Trigger.decode(encoded)
    assert trigger.provider == unknown
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "noncanonical, malformed, and oversized JSON fail closed" do
    trigger = trigger!()
    wire = Trigger.to_wire_map(trigger)

    assert {:error, %Error{code: :invalid_request}} =
             wire |> Jason.encode!() |> then(&(" " <> &1)) |> Trigger.decode()

    assert {:error, %Error{code: :invalid_request}} = Trigger.decode("not-json")
    assert {:error, %Error{code: :invalid_request}} = Trigger.decode(String.duplicate("x", 1_025))
    assert {:error, %Error{code: :invalid_request}} = Trigger.decode(:not_json)
  end

  defp trigger!(overrides \\ []) do
    assert {:ok, trigger} = Trigger.new(options(overrides))
    trigger
  end

  defp options(overrides) do
    Keyword.merge(
      [
        operation: "freeze",
        provider: "sentry",
        external_event_fingerprint: String.duplicate("a", 64),
        external_incident_fingerprint: String.duplicate("b", 64)
      ],
      overrides
    )
  end

  defp reidentify(wire) do
    {:ok, trigger} =
      Trigger.new(
        operation: wire["operation"],
        provider: wire["provider"],
        external_event_fingerprint: wire["external_event_fingerprint"],
        external_incident_fingerprint: wire["external_incident_fingerprint"]
      )

    Trigger.to_wire_map(trigger)
  end

  defp assert_invalid(value) when is_map(value) and is_struct(value) do
    assert {:error, %Error{code: :invalid_request}} = Trigger.validate(value)
  end

  defp assert_invalid(value) do
    assert {:error, %Error{}} = Trigger.decode_map(value)
  end

  defp fixture_bytes(name) do
    Path.join("test/fixtures", name)
    |> File.read!()
    |> String.trim_trailing("\n")
  end
end

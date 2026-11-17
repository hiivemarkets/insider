defmodule Insider.Observability.MockEventTest do
  use ExUnit.Case, async: true

  alias Insider.Incident.Capsule
  alias Insider.Observability.Datadog
  alias Insider.Observability.Export
  alias Insider.Observability.MockEvent
  alias Insider.Observability.Sentry
  alias Insider.Protocol.Error

  @destination String.duplicate("d", 64)

  test "Sentry produces a realistic canonical mock ingestion event" do
    capsule = capsule!()
    export = export!(capsule, "sentry")
    assert {:ok, event} = Sentry.map(export, capsule)

    assert event.mock == true
    assert event.delivery_status == "not_attempted"
    assert event.provider == "sentry"

    assert event.handoff == %{
             "contract" => "insider.mock-host-client/v1",
             "mode" => "asynchronous",
             "owner" => "host_application"
           }

    assert %{
             "event_id" => event_id,
             "fingerprint" => [fingerprint],
             "level" => "error",
             "logentry" => %{"formatted" => message},
             "logger" => "insider",
             "platform" => "elixir"
           } = event.body

    assert String.match?(event_id, ~r/\A[0-9a-f]{12}4[0-9a-f]{3}[89ab][0-9a-f]{15}\z/)
    assert fingerprint == export.finding["fingerprint"]
    assert message =~ "restart_recurrence"
    assert event.body["tags"]["insider.mock"] == "true"
    assert event.body["extra"]["insider"]["retained_events"] == 3
    assert event.body["extra"]["incident_id"] == capsule.id
    assert_round_trip(event, capsule)
  end

  test "Datadog produces a realistic canonical Events v2 alert request body" do
    capsule = capsule!()
    export = export!(capsule, "datadog")
    assert {:ok, event} = Datadog.map(export, capsule)

    assert %{
             "data" => %{
               "type" => "event",
               "attributes" => %{
                 "aggregation_key" => fingerprint,
                 "attributes" => %{
                   "custom" => custom,
                   "status" => "error"
                 },
                 "category" => "alert",
                 "message" => message,
                 "tags" => tags,
                 "title" => title
               }
             }
           } = event.body

    assert fingerprint == export.finding["fingerprint"]
    assert custom["incident_id"] == capsule.id
    assert custom["mock"] == true
    assert message =~ "restart_recurrence"
    assert title == "Insider restart_recurrence finding"
    assert "insider_mock:true" in tags
    assert_round_trip(event, capsule)
  end

  test "frozen provider fixtures remain exact and capsule-bound" do
    capsule = capsule!()

    for {provider, mapper, fixture} <- [
          {"sentry", &Sentry.map/2, "observability_sentry_mock_event_v1.json"},
          {"datadog", &Datadog.map/2, "observability_datadog_mock_event_v1.json"}
        ] do
      bytes = fixture_bytes(fixture)
      export = export!(capsule, provider)

      assert {:ok, expected} = mapper.(export, capsule)
      assert {:ok, decoded} = MockEvent.decode(bytes)
      assert decoded == expected
      assert {:ok, ^bytes} = MockEvent.canonical_binary(decoded)
      assert {:ok, ^decoded} = MockEvent.validate_against_capsule(decoded, capsule)
    end
  end

  test "provider mappings carry equivalent neutral information" do
    capsule = capsule!()
    sentry = map!(Sentry, export!(capsule, "sentry"), capsule)
    datadog = map!(Datadog, export!(capsule, "datadog"), capsule)

    assert neutral_export(sentry.export) == neutral_export(datadog.export)

    sentry_neutral = %{
      "confidence" => sentry.body["tags"]["insider.confidence"],
      "detector" => sentry.body["tags"]["insider.detector"],
      "evidence_completeness" => sentry.body["extra"]["insider"]["completeness"],
      "incident_id" => sentry.body["extra"]["incident_id"],
      "retained_bytes" => sentry.body["extra"]["insider"]["retained_bytes"],
      "retained_events" => sentry.body["extra"]["insider"]["retained_events"]
    }

    custom = datadog.body["data"]["attributes"]["attributes"]["custom"]

    datadog_neutral =
      Map.take(custom, [
        "confidence",
        "detector",
        "evidence_completeness",
        "incident_id",
        "retained_bytes",
        "retained_events"
      ])

    assert sentry_neutral == datadog_neutral
  end

  test "identity and idempotency are deterministic and content-sensitive" do
    capsule = capsule!()
    export = export!(capsule, "sentry")
    first = map!(Sentry, export, capsule)
    repeated = map!(Sentry, export, capsule)

    assert first == repeated
    assert String.match?(first.id, ~r/\Asha256:[0-9a-f]{64}\z/)
    assert String.match?(first.idempotency_key, ~r/\A[0-9a-f]{64}\z/)

    other_destination = String.duplicate("e", 64)
    assert {:ok, readdressed_export} = Export.new(capsule, "sentry", other_destination)
    readdressed = map!(Sentry, readdressed_export, capsule)

    refute readdressed.id == first.id
    refute readdressed.idempotency_key == first.idempotency_key
    refute readdressed.body["event_id"] == first.body["event_id"]
  end

  test "provider adapters reject exports addressed to the other provider" do
    capsule = capsule!()

    assert {:error, %Error{code: :invalid_observability_mock_event}} =
             Sentry.map(export!(capsule, "datadog"), capsule)

    assert {:error, %Error{code: :invalid_observability_mock_event}} =
             Datadog.map(export!(capsule, "sentry"), capsule)
  end

  test "unknown fields and forged mock, delivery, handoff, body, and identity fail closed" do
    capsule = capsule!()
    event = map!(Sentry, export!(capsule, "sentry"), capsule)
    wire = MockEvent.to_wire_map(event)

    for forged <- [
          Map.put(wire, "mock", false),
          Map.put(wire, "delivery_status", "delivered"),
          put_in(wire, ["handoff", "owner"], "insider"),
          put_in(wire, ["handoff", "mode"], "synchronous"),
          put_in(wire, ["body", "event_id"], String.duplicate("0", 32)),
          put_in(wire, ["body", "extra", "incident_id"], "raw-incident"),
          Map.put(wire, "idempotency_key", String.duplicate("0", 64)),
          Map.put(wire, "id", "sha256:" <> String.duplicate("0", 64)),
          Map.put(wire, "endpoint", "attacker.example"),
          Map.put(wire, :callback, fn -> :send end),
          Map.delete(wire, "body")
        ] do
      assert {:error, %Error{code: :invalid_observability_mock_event}} =
               MockEvent.decode_map(forged)
    end
  end

  test "forged exports and capsules cannot author or validate provider claims" do
    capsule = capsule!()
    export = export!(capsule, "sentry")
    event = map!(Sentry, export, capsule)

    assert {:error, %Error{code: :invalid_observability_mock_event}} =
             Sentry.map(%{export | id: "sha256:" <> String.duplicate("0", 64)}, capsule)

    forged_capsule = %{capsule | id: "sha256:" <> String.duplicate("0", 64)}

    assert {:error, %Error{code: :invalid_observability_mock_event}} =
             Sentry.map(export, forged_capsule)

    assert {:error, %Error{code: :observability_mock_event_integrity_failed}} =
             MockEvent.validate_against_capsule(event, forged_capsule)
  end

  test "raw capsule and secret-capable fields never cross the artifact boundary" do
    capsule_bytes = fixture_bytes("legacy_restart_capsule_v1.json")
    capsule = capsule!()

    for {module, provider} <- [{Sentry, "sentry"}, {Datadog, "datadog"}] do
      event = map!(module, export!(capsule, provider), capsule)
      assert {:ok, encoded} = MockEvent.canonical_binary(event)

      for canary <- [
            "capture-1",
            "export-1",
            "abc123",
            "def456",
            "worker-a",
            "supervisor-a",
            "<0.1.0>",
            "event_chain_head",
            "policy_fingerprint",
            "vm-crash-dump",
            "[REDACTED]"
          ] do
        assert capsule_bytes =~ canary
        refute encoded =~ canary
      end

      for forbidden_key <- [
            "capsule",
            "events",
            "artifacts",
            "authority",
            "provenance",
            "payload",
            "endpoint",
            "credential",
            "callback",
            "dsn",
            "api_key"
          ] do
        refute encoded =~ ~s("#{forbidden_key}")
      end
    end
  end

  test "malformed, noncanonical, unsupported, and oversized input never raises" do
    capsule = capsule!()
    event = map!(Sentry, export!(capsule, "sentry"), capsule)
    wire = MockEvent.to_wire_map(event)

    assert {:error, %Error{code: :unsupported_observability_mock_event_schema}} =
             wire
             |> Map.put("schema", "insider.observability-mock-event/v2")
             |> MockEvent.decode_map()

    assert {:error, %Error{code: :invalid_observability_mock_event}} =
             MockEvent.decode(" " <> Jason.encode!(wire))

    assert {:error, %Error{code: :observability_mock_event_limit_exceeded}} =
             MockEvent.decode(String.duplicate("x", 8_193))

    for malformed <- [nil, [], %{}, self(), fn -> :unsafe end, "not-json"] do
      assert {:error, %Error{}} = MockEvent.decode_map(malformed)
      assert {:error, %Error{}} = MockEvent.validate(malformed)
    end

    assert {:error, %Error{}} = MockEvent.decode(:not_json)
    assert {:error, %Error{}} = MockEvent.decode("not-json")
    assert {:error, %Error{}} = MockEvent.canonical_binary(%{})
    assert {:error, %Error{}} = MockEvent.new(%{}, %{}, "sentry")
    assert {:error, %Error{}} = MockEvent.new(event.export, capsule, "unknown")
  end

  defp assert_round_trip(event, capsule) do
    assert {:ok, ^event} = MockEvent.validate(event)
    assert {:ok, ^event} = MockEvent.validate_against_capsule(event, capsule)
    assert {:ok, encoded} = MockEvent.canonical_binary(event)
    assert byte_size(encoded) <= 8_192
    assert {:ok, ^event} = MockEvent.decode(encoded)
    assert {:ok, ^event} = encoded |> Jason.decode!() |> MockEvent.decode_map()
  end

  defp neutral_export(export) do
    Map.take(export, ["evidence", "finding", "incident_id"])
  end

  defp export!(capsule, provider) do
    assert {:ok, export} = Export.new(capsule, provider, @destination)
    export
  end

  defp map!(module, export, capsule) do
    assert {:ok, event} = module.map(export, capsule)
    event
  end

  defp capsule! do
    assert {:ok, capsule} =
             "legacy_restart_capsule_v1.json"
             |> fixture_bytes()
             |> Capsule.decode()

    capsule
  end

  defp fixture_bytes(name) do
    Path.join("test/fixtures", name)
    |> File.read!()
    |> String.trim_trailing("\n")
  end
end

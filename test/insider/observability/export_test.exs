defmodule Insider.Observability.ExportTest do
  use ExUnit.Case, async: true

  alias Insider.Event.Canonical
  alias Insider.Incident.Capsule
  alias Insider.Observability.Export
  alias Insider.Protocol.Error

  @destination String.duplicate("d", 64)

  test "derives a bounded structural projection from validated redacted evidence" do
    capsule = capsule!()

    for provider <- ["datadog", "sentry"] do
      assert {:ok, export} = Export.new(capsule, provider, @destination)
      assert export.provider == provider
      assert export.incident_id == capsule.id
      assert export.finding["fingerprint"] == capsule.finding["fingerprint"]
      assert export.evidence["completeness"] == capsule.snapshot["completeness"]
      assert export.evidence["gaps"] == capsule.snapshot["gaps"]

      wire = Export.to_wire_map(export)
      refute Map.has_key?(wire, "capsule")
      refute Map.has_key?(wire, "events")
      refute Map.has_key?(wire, "artifacts")
      refute Map.has_key?(wire, "endpoint")
      refute Map.has_key?(wire, "credentials")
      refute inspect(wire) =~ "event_chain_head"

      assert {:ok, canonical} = Export.canonical_binary(export)
      assert byte_size(canonical) <= 4_096
      assert {:ok, ^export} = Export.decode(canonical)
      assert {:ok, ^export} = canonical |> Jason.decode!() |> Export.decode_map()
      assert {:ok, ^export} = Export.validate_against_capsule(export, capsule)
    end
  end

  test "frozen v1 canonical bytes remain compatible and capsule-bound" do
    bytes = fixture_bytes("observability_export_v1.json")
    capsule = capsule!()

    assert {:ok, export} = Export.decode(bytes)
    assert {:ok, ^bytes} = Export.canonical_binary(export)
    assert {:ok, ^export} = Export.validate_against_capsule(export, capsule)
  end

  test "same capsule and destination are idempotent while readdressing changes identity" do
    capsule = capsule!()
    assert {:ok, first} = Export.new(capsule, "sentry", @destination)
    assert {:ok, repeated} = Export.new(capsule, "sentry", @destination)
    assert first == repeated

    assert {:ok, readdressed} =
             Export.new(capsule, "sentry", String.duplicate("e", 64))

    refute readdressed.id == first.id
    refute readdressed.idempotency_key == first.idempotency_key

    assert {:ok, other_provider} = Export.new(capsule, "datadog", @destination)
    refute other_provider.id == first.id
    refute other_provider.idempotency_key == first.idempotency_key
  end

  test "rejects forged evidence claims, identity, destination, and unknown fields" do
    capsule = capsule!()
    assert {:ok, export} = Export.new(capsule, "sentry", @destination)

    for forged <- [
          %{export | id: "sha256:" <> String.duplicate("0", 64)},
          %{export | idempotency_key: String.duplicate("0", 64)},
          %{export | evidence: Map.put(export.evidence, "completeness", "complete")},
          %{export | finding: Map.put(export.finding, "severity", "critical")},
          %{export | destination_fingerprint: String.duplicate("0", 64)}
        ] do
      assert {:error, %Error{}} = Export.validate(forged)
    end

    hidden = export |> Export.to_wire_map() |> Map.put("payload", "secret-canary")
    assert {:error, %Error{code: :invalid_observability_export}} = Export.decode_map(hidden)

    assert {:error, %Error{code: :invalid_observability_export}} =
             Export.new(capsule, "other", @destination)

    assert {:error, %Error{code: :invalid_observability_export}} =
             Export.new(capsule, "sentry", "short")
  end

  test "standalone schema rejects impossible detector and capsule bounds" do
    capsule = capsule!()
    assert {:ok, export} = Export.new(capsule, "sentry", @destination)

    for {path, value} <- [
          {["finding", "confidence"], "high"},
          {["finding", "severity"], "warning"},
          {["evidence", "retained_events"], 0},
          {["evidence", "retained_events"], 1},
          {["evidence", "retained_events"], 65},
          {["evidence", "retained_bytes"], 0},
          {["evidence", "retained_bytes"], 2},
          {["evidence", "retained_bytes"], 1_048_577},
          {["evidence", "redaction_manifest_records"], 513}
        ] do
      forged_body =
        export
        |> Export.to_wire_map()
        |> Map.delete("id")
        |> put_in(path, value)

      wire = Map.put(forged_body, "id", "sha256:" <> Insider.Event.Canonical.sha256(forged_body))
      assert {:error, %Error{code: :invalid_observability_export}} = Export.decode_map(wire)
    end
  end

  test "standalone schema enforces each supported detector's evidence minimum" do
    capsule = capsule!()
    assert {:ok, export} = Export.new(capsule, "sentry", @destination)
    wire = Export.to_wire_map(export)

    mailbox_growth =
      wire
      |> put_in(["finding", "detector"], "mailbox_growth")
      |> put_in(["finding", "confidence"], "medium")
      |> put_in(["finding", "severity"], "warning")
      |> reidentify_export()

    assert {:ok, decoded_mailbox_growth} = Export.decode_map(mailbox_growth)
    assert decoded_mailbox_growth.finding["detector"] == "mailbox_growth"

    mailbox_growth_below_minimum =
      mailbox_growth
      |> put_in(["evidence", "retained_events"], 2)
      |> reidentify_export()

    assert {:error, %Error{code: :invalid_observability_export}} =
             Export.decode_map(mailbox_growth_below_minimum)

    semantic_invariant =
      wire
      |> put_in(["finding", "detector"], "semantic_invariant")
      |> put_in(["finding", "confidence"], "high")
      |> put_in(["finding", "severity"], "error")
      |> put_in(["evidence", "retained_events"], 1)
      |> reidentify_export()

    assert {:ok, decoded_semantic_invariant} = Export.decode_map(semantic_invariant)
    assert decoded_semantic_invariant.finding["detector"] == "semantic_invariant"
  end

  test "standalone schema rejects nested non-maps and raw incident references" do
    capsule = capsule!()
    assert {:ok, export} = Export.new(capsule, "sentry", @destination)
    wire = Export.to_wire_map(export)

    for malformed <- [
          Map.put(wire, "finding", []),
          Map.put(wire, "evidence", []),
          Map.put(wire, "incident_id", "raw-incident-id")
        ] do
      assert {:error, %Error{code: :invalid_observability_export}} =
               malformed |> reidentify_export() |> Export.decode_map()
    end
  end

  test "rejects unsupported, noncanonical, oversized, and arbitrary input without raising" do
    capsule = capsule!()
    assert {:ok, export} = Export.new(capsule, "sentry", @destination)
    wire = Export.to_wire_map(export)

    assert {:error, %Error{code: :unsupported_observability_export_schema}} =
             Export.decode_map(Map.put(wire, "schema", "insider.observability-export/v2"))

    assert {:error, %Error{code: :unsupported_observability_export_schema}} =
             wire
             |> Map.put("schema", "insider.observability-export/v2")
             |> Canonical.encode()
             |> Export.decode()

    assert {:error, %Error{code: :invalid_observability_export}} =
             Export.decode("\n" <> Jason.encode!(wire))

    assert {:error, %Error{code: :invalid_observability_export}} = Export.decode("not-json")
    assert {:error, %Error{code: :invalid_observability_export}} = Export.decode(:not_json)

    assert {:error, %Error{code: :invalid_observability_export}} =
             Export.canonical_binary(%{})

    assert {:error, %Error{code: :observability_export_limit_exceeded}} =
             Export.decode(String.duplicate("x", 4_097))

    for value <- [nil, self(), fn -> :unsafe end, %{}, [], "invalid"] do
      assert {:error, %Error{}} = Export.decode_map(value)
      assert {:error, %Error{}} = Export.validate(value)
    end
  end

  test "invalid or forged capsules cannot author export claims" do
    capsule = capsule!()

    assert {:error, %Error{code: :invalid_observability_export}} =
             Export.new(
               %{capsule | id: "sha256:" <> String.duplicate("0", 64)},
               "sentry",
               @destination
             )

    assert {:error, %Error{code: :invalid_observability_export}} =
             Export.new(%{}, "sentry", @destination)
  end

  test "standalone identity cannot substitute for capsule-bound derivation" do
    capsule = capsule!()
    assert {:ok, export} = Export.new(capsule, "sentry", @destination)

    forged_body =
      export
      |> Export.to_wire_map()
      |> put_in(["evidence", "retained_events"], export.evidence["retained_events"] + 1)
      |> Map.delete("id")

    forged =
      forged_body
      |> Map.put("id", "sha256:" <> Insider.Event.Canonical.sha256(forged_body))
      |> then(fn wire ->
        assert {:ok, decoded} = Export.decode_map(wire)
        decoded
      end)

    assert {:error, %Error{code: :observability_export_integrity_failed}} =
             Export.validate_against_capsule(forged, capsule)

    assert {:error, %Error{code: :observability_export_integrity_failed}} =
             Export.validate_against_capsule(export, %{capsule | id: forged.id})

    assert {:error, %Error{code: :observability_export_integrity_failed}} =
             Export.validate_against_capsule(%{}, capsule)
  end

  defp capsule! do
    bytes = fixture_bytes("legacy_restart_capsule_v1.json")

    assert {:ok, capsule} = Capsule.decode(bytes)
    capsule
  end

  defp reidentify_export(wire) do
    body = Map.delete(wire, "id")
    Map.put(body, "id", "sha256:" <> Canonical.sha256(body))
  end

  defp fixture_bytes(name) do
    Path.join("test/fixtures", name)
    |> File.read!()
    |> String.trim_trailing("\n")
  end
end

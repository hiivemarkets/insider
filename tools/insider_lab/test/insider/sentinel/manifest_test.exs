defmodule Insider.Sentinel.ManifestTest do
  # Atom-count assertions observe VM-global state, so this boundary suite must
  # run after asynchronous tests rather than racing unrelated module loading.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Insider.Event.Canonical
  alias Insider.Finding
  alias Insider.Incident.Capsule
  alias Insider.Protocol.Error
  alias Insider.Provenance
  alias Insider.Sentinel.Manifest

  @digest String.duplicate("a", 64)

  test "builds a deterministic reference-only manifest and round trips canonically" do
    {capsule, capsule_bytes} = legacy_capsule!()
    scenario = available("b")

    assert {:ok, first} = Manifest.new(capsule, scenario)
    assert {:ok, repeated} = Manifest.new(capsule_bytes, scenario)
    assert first == repeated

    assert first.schema == "insider.sentinel-manifest/v1"
    assert first.id == "sha256:" <> first.integrity["content_digest"]

    assert first.capsule == %{
             "schema" => capsule.schema,
             "id" => capsule.id,
             "byte_size" => byte_size(capsule_bytes),
             "canonical_sha256" => sha256(capsule_bytes)
           }

    refute Map.has_key?(first.capsule, "bytes")
    refute inspect(first) =~ capsule_bytes

    assert first.execution_policy == %{
             "cleanup" => "required",
             "purpose" => "confirmation",
             "source_mutation" => "prohibited",
             "target_class" => "disposable"
           }

    assert {:ok, encoded} = Manifest.canonical_binary(first)
    assert byte_size(encoded) <= 65_536
    assert {:ok, ^first} = Manifest.decode(encoded)
    assert {:ok, ^first} = encoded |> Jason.decode!() |> Manifest.decode_map()
    assert {:ok, ^first} = Manifest.validate_with_capsule(first, capsule_bytes)
  end

  test "derives ordered readiness while preserving unavailable and redacted states" do
    {capsule, _bytes} = legacy_capsule!()
    assert {:ok, blocked} = Manifest.new(capsule, unavailable("not_built", "b"))

    assert {:ok,
            %{
              "status" => "blocked",
              "blocked" => [
                %{
                  "fingerprint" => _configuration_fingerprint,
                  "name" => "configuration",
                  "policy_fingerprint" => _policy_fingerprint,
                  "status" => "redacted"
                },
                %{
                  "fingerprint" => _scenario_fingerprint,
                  "name" => "scenario",
                  "reason" => "not_built",
                  "status" => "unavailable"
                }
              ]
            }} = Manifest.readiness(blocked, capsule)

    ready =
      blocked
      |> put_in([Access.key!(:prerequisites), "configuration"], available("c"))
      |> put_in([Access.key!(:prerequisites), "scenario"], available("d"))
      |> resign()

    assert {:error, %Error{code: :sentinel_manifest_integrity_failed}} =
             Manifest.readiness(ready, capsule)

    {ready_capsule, _ready_bytes} = capsule_with_available_configuration(capsule)
    assert {:ok, ready_manifest} = Manifest.new(ready_capsule, available("d"))

    assert {:ok, %{"blocked" => [], "status" => "ready"}} =
             Manifest.readiness(ready_manifest, ready_capsule)
  end

  test "binds capsule id, canonical byte size, full-byte digest, and provenance summaries" do
    {capsule, bytes} = legacy_capsule!()
    assert {:ok, manifest} = Manifest.new(capsule, available("b"))

    {substitute, substitute_bytes} = substitute_capsule(capsule)
    assert {:ok, ^substitute} = Capsule.decode(substitute_bytes)

    assert {:error, %Error{code: :sentinel_manifest_integrity_failed}} =
             Manifest.validate_with_capsule(manifest, substitute_bytes)

    for {field, value} <- [
          {"id", "sha256:" <> String.duplicate("f", 64)},
          {"byte_size", byte_size(bytes) - 1},
          {"canonical_sha256", String.duplicate("f", 64)}
        ] do
      forged = manifest |> put_in([Access.key!(:capsule), field], value) |> resign()
      assert {:ok, ^forged} = Manifest.validate(forged)

      assert {:error, %Error{code: :sentinel_manifest_integrity_failed}} =
               Manifest.validate_with_capsule(forged, bytes)
    end

    forged =
      manifest
      |> put_in(
        [Access.key!(:prerequisites), "code", "fingerprint"],
        String.duplicate("e", 64)
      )
      |> resign()

    assert {:ok, ^forged} = Manifest.validate(forged)

    assert {:error, %Error{code: :sentinel_manifest_integrity_failed}} =
             Manifest.validate_with_capsule(forged, capsule)
  end

  test "rejects manifest tampering, extra fields, and noncanonical encoding" do
    {_capsule, bytes} = legacy_capsule!()
    assert {:ok, manifest} = Manifest.new(bytes, available("b"))

    for {field, forbidden} <- [
          {"purpose", "repair"},
          {"source_mutation", "allowed"},
          {"target_class", "production"},
          {"cleanup", "optional"}
        ] do
      tampered = %{
        manifest
        | execution_policy: Map.put(manifest.execution_policy, field, forbidden)
      }

      assert {:error, %Error{code: :invalid_sentinel_manifest}} =
               tampered |> resign() |> Manifest.validate()
    end

    wire = Manifest.to_wire_map(manifest)

    assert {:error, %Error{code: :invalid_sentinel_manifest}} =
             wire |> Map.put("extra", true) |> Manifest.decode_map()

    assert {:error, %Error{code: :invalid_sentinel_manifest}} =
             wire
             |> Map.update!("capsule", &Map.put(&1, "url", "https://example.invalid"))
             |> Manifest.decode_map()

    assert {:ok, canonical} = Manifest.canonical_binary(manifest)
    noncanonical = Jason.encode!(Manifest.to_wire_map(manifest))

    if noncanonical != canonical do
      assert {:error, %Error{code: :invalid_sentinel_manifest}} = Manifest.decode(noncanonical)
    end
  end

  test "rejects unsupported versions, malformed descriptors, and hostile bounds" do
    {_capsule, bytes} = legacy_capsule!()

    assert {:error, %Error{code: :unsupported_sentinel_manifest_schema}} =
             %{"schema" => "insider.sentinel-manifest/v2"}
             |> Manifest.decode_map()

    for scenario <- [
          %{"status" => "available", "fingerprint" => "short"},
          %{"status" => "unknown", "fingerprint" => @digest},
          %{"status" => "unavailable", "fingerprint" => @digest, "reason" => "secret"},
          Map.put(available("b"), "command", "mix test")
        ] do
      assert {:error, %Error{code: :invalid_sentinel_manifest}} = Manifest.new(bytes, scenario)
    end

    assert {:error, %Error{code: :sentinel_manifest_limit_exceeded}} =
             Manifest.decode(String.duplicate("x", 65_537))

    assert {:error, %Error{code: :invalid_sentinel_manifest}} =
             Manifest.decode_map(%{
               "schema" => "insider.sentinel-manifest/v1",
               "id" => "sha256:" <> @digest,
               "capsule" => %{},
               "prerequisites" => %{},
               "execution_policy" => %{},
               "integrity" => %{"blob" => String.duplicate("x", 65_537)}
             })
  end

  test "all public ingress paths reject malformed and noncanonical inputs with typed errors" do
    {capsule, bytes} = legacy_capsule!()
    assert {:ok, manifest} = Manifest.new(capsule, available("b"))

    for operation <- [
          fn -> Manifest.new(:not_a_capsule, available("b")) end,
          fn -> Manifest.validate(:not_a_manifest) end,
          fn -> Manifest.canonical_binary(:not_a_manifest) end,
          fn -> Manifest.readiness(:not_a_manifest, bytes) end,
          fn -> Manifest.decode(:not_manifest_bytes) end,
          fn -> Manifest.decode("{") end,
          fn -> Manifest.decode_map(:not_a_map) end,
          fn -> Manifest.decode_map(%{"schema" => "insider.sentinel-manifest/v1"}) end
        ] do
      assert {:error, %Error{code: :invalid_sentinel_manifest}} = operation.()
    end

    assert {:error, %Error{}} = Manifest.validate_with_capsule(:not_a_manifest, bytes)
    assert {:error, %Error{}} = Manifest.validate_with_capsule(manifest, :not_a_capsule)

    assert {:error, %Error{code: :invalid_capsule}} =
             Manifest.new(bytes <> "\n", available("b"))
  end

  test "validation remains offline for the frozen legacy capsule compatibility fixture" do
    {capsule, bytes} = legacy_capsule!()
    assert {:ok, manifest} = Manifest.new(capsule, redacted("c", "d"))

    # No recorder, source node, artifact store, filesystem path, or callback is
    # retained in either value used by validation.
    assert {:ok, ^manifest} = Manifest.validate_with_capsule(manifest, bytes)

    assert {:ok,
            %{
              "status" => "blocked",
              "blocked" => [
                %{"name" => "configuration", "status" => "redacted"},
                %{"name" => "scenario", "status" => "redacted"}
              ]
            }} =
             Manifest.readiness(manifest, bytes)
             |> strip_blocker_evidence()
  end

  test "frozen v1 manifest bytes and digest remain compatible" do
    bytes =
      "test/fixtures/sentinel_manifest_v1.json"
      |> File.read!()

    assert {:ok, manifest} = Manifest.decode(bytes)

    assert manifest.integrity["content_digest"] ==
             "facb60dd6120edc80fa8dd59f4fd9660944a312df11810ccfcbe735b61541455"

    assert {:ok, ^bytes} = Manifest.canonical_binary(manifest)

    {_capsule, capsule_bytes} = legacy_capsule!()
    assert {:ok, ^manifest} = Manifest.validate_with_capsule(manifest, capsule_bytes)
  end

  property "external manifest decoders never raise for arbitrary terms" do
    check all(payload <- term()) do
      for result <- [Manifest.decode_map(payload), Manifest.decode(payload)] do
        case result do
          {:ok, %Manifest{}} -> :ok
          {:error, %Error{}} -> :ok
          other -> flunk("unexpected decoder result: #{inspect(other)}")
        end
      end
    end
  end

  test "external schema names do not create atoms" do
    assert {:error, %Error{}} = Manifest.decode_map(%{})
    initial_atoms = :erlang.system_info(:atom_count)

    for unique <- 1..1_000 do
      assert {:error, %Error{code: :unsupported_sentinel_manifest_schema}} =
               Manifest.decode_map(%{"schema" => "attacker.manifest/#{unique}"})
    end

    assert :erlang.system_info(:atom_count) == initial_atoms
  end

  test "invalid diagnostics do not retain large source values" do
    secret = String.duplicate("manifest-secret-canary", 10_000)

    assert {:error, %Error{} = error} = Manifest.decode(secret)
    refute inspect(error) =~ "manifest-secret-canary"
  end

  test "accepts both legacy and current finding envelopes without depending on their shape" do
    {legacy, legacy_bytes} = legacy_capsule!()
    {current, current_bytes} = current_capsule(legacy)

    refute Map.has_key?(legacy.finding, "details")
    assert Map.has_key?(current.finding, "details")

    for {capsule, bytes} <- [{legacy, legacy_bytes}, {current, current_bytes}] do
      assert {:ok, manifest} = Manifest.new(bytes, available("b"))
      assert {:ok, ^manifest} = Manifest.validate_with_capsule(manifest, capsule)
    end
  end

  defp legacy_capsule! do
    bytes =
      "test/fixtures/legacy_restart_capsule_v1.json"
      |> File.read!()
      |> String.trim_trailing("\n")

    assert {:ok, capsule} = Capsule.decode(bytes)
    {capsule, bytes}
  end

  defp available(character),
    do: %{"fingerprint" => String.duplicate(character, 64), "status" => "available"}

  defp unavailable(reason, character),
    do: %{
      "fingerprint" => String.duplicate(character, 64),
      "reason" => reason,
      "status" => "unavailable"
    }

  defp redacted(fingerprint_character, policy_character),
    do: %{
      "fingerprint" => String.duplicate(fingerprint_character, 64),
      "policy_fingerprint" => String.duplicate(policy_character, 64),
      "status" => "redacted"
    }

  defp resign(manifest) do
    content = %{
      "schema" => manifest.schema,
      "capsule" => manifest.capsule,
      "prerequisites" => manifest.prerequisites,
      "execution_policy" => manifest.execution_policy
    }

    digest = content |> Canonical.encode() |> sha256()

    %{
      manifest
      | id: "sha256:" <> digest,
        integrity: %{"algorithm" => "sha256", "content_digest" => digest}
    }
  end

  defp substitute_capsule(capsule) do
    wire =
      capsule
      |> Capsule.to_wire_map()
      |> put_in(["authority", "capture_audit_id"], "capture-substitute")

    substituted = resign_capsule_wire(wire)

    {Capsule.decode_map(substituted) |> elem(1), Canonical.encode(substituted)}
  end

  defp current_capsule(legacy) do
    legacy_finding = legacy.finding

    current_finding =
      Finding.new!(
        detector: legacy_finding["detector"],
        detector_version: legacy_finding["detector_version"],
        occurred_at_us: legacy_finding["occurred_at_us"],
        confidence: legacy_finding["confidence"],
        severity: legacy_finding["severity"],
        trigger_event_id: legacy_finding["trigger_event_id"],
        evidence_event_ids: legacy_finding["evidence_event_ids"],
        details: %{
          "count" => legacy_finding["count"],
          "identity" => legacy_finding["identity"],
          "reason_fingerprints" => legacy_finding["reason_fingerprints"],
          "window_ms" => legacy_finding["window_ms"]
        }
      )

    wire =
      legacy
      |> Capsule.to_wire_map()
      |> Map.put("finding", Finding.to_wire_map(current_finding))
      |> resign_capsule_wire()

    assert {:ok, capsule} = Capsule.decode_map(wire)
    {capsule, Canonical.encode(wire)}
  end

  defp capsule_with_available_configuration(capsule) do
    components = capsule.provenance["components"]

    assert {:ok, provenance} =
             Provenance.new(
               code: provenance_descriptor(components["code"]),
               configuration: {:available, %{}},
               dependencies: provenance_descriptor(components["dependencies"]),
               runtime: provenance_descriptor(components["runtime"]),
               target: provenance_descriptor(components["target"])
             )

    wire =
      capsule
      |> Capsule.to_wire_map()
      |> Map.put("provenance", Provenance.to_wire_map(provenance))
      |> resign_capsule_wire()

    assert {:ok, ready_capsule} = Capsule.decode_map(wire)
    {ready_capsule, Canonical.encode(wire)}
  end

  defp provenance_descriptor(%{"attributes" => attributes, "status" => "available"}),
    do: {:available, attributes}

  defp provenance_descriptor(%{"reason" => reason, "status" => "unavailable"}),
    do: {:unavailable, String.to_existing_atom(reason)}

  defp provenance_descriptor(%{"policy_fingerprint" => fingerprint, "status" => "redacted"}),
    do: {:redacted, fingerprint}

  defp resign_capsule_wire(wire) do
    content_digest = wire |> Map.drop(["id", "integrity"]) |> Canonical.encode() |> sha256()

    wire
    |> Map.put("id", "sha256:" <> content_digest)
    |> put_in(["integrity", "content_digest"], content_digest)
  end

  defp strip_blocker_evidence({:ok, %{"blocked" => blocked} = readiness}) do
    {:ok,
     %{
       readiness
       | "blocked" => Enum.map(blocked, &Map.take(&1, ["name", "status"]))
     }}
  end

  defp sha256(value),
    do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end

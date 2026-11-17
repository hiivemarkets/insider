defmodule Insider.ProvenanceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Insider.Protocol.Error
  alias Insider.Provenance

  @policy_fingerprint String.duplicate("a", 64)

  test "material target differences change target and aggregate fingerprints" do
    left = provenance!(target: {:available, %{"region" => "ca-west", "tier" => "sandbox"}})
    right = provenance!(target: {:available, %{"region" => "us-east", "tier" => "sandbox"}})

    refute component_fingerprint(left, "target") == component_fingerprint(right, "target")
    refute left.fingerprint == right.fingerprint

    for name <- ["code", "configuration", "dependencies", "runtime"] do
      assert component_fingerprint(left, name) == component_fingerprint(right, name)
    end
  end

  test "stable target maps normalize independently of insertion order" do
    left_target = Map.new([{"zone", "a"}, {"machine", %{"word_size" => 8, "arch" => "arm64"}}])

    right_target =
      Map.new([{"machine", Map.new([{"arch", "arm64"}, {"word_size", 8}])}, {"zone", "a"}])

    left = provenance!(target: {:available, left_target})
    right = provenance!(target: {:available, right_target})

    assert left.components["target"] == right.components["target"]
    assert left.fingerprint == right.fingerprint
    assert Provenance.canonical_binary(left) == Provenance.canonical_binary(right)
  end

  test "unavailable and redacted inputs remain explicit and fingerprint differently" do
    unavailable = provenance!(configuration: {:unavailable, :not_built})
    redacted = provenance!(configuration: {:redacted, @policy_fingerprint})

    assert unavailable.components["configuration"]["status"] == "unavailable"
    assert unavailable.components["configuration"]["reason"] == "not_built"
    assert redacted.components["configuration"]["status"] == "redacted"

    assert redacted.components["configuration"]["policy_fingerprint"] ==
             @policy_fingerprint

    refute component_fingerprint(unavailable, "configuration") ==
             component_fingerprint(redacted, "configuration")

    refute unavailable.fingerprint == redacted.fingerprint
  end

  test "capture collects stable BEAM facts without pretending omitted build facts exist" do
    assert {:ok, provenance} = Provenance.capture()
    assert {:ok, repeated} = Provenance.capture()
    assert provenance == repeated

    runtime = provenance.components["runtime"]
    target = provenance.components["target"]

    assert runtime["status"] == "available"
    assert runtime["attributes"]["elixir_version"] == System.version()
    assert runtime["attributes"]["otp_release"] == System.otp_release()
    assert target["status"] == "available"
    assert byte_size(target["attributes"]["architecture"]) > 0
    assert is_integer(target["attributes"]["word_size_bytes"])

    for name <- ["code", "configuration", "dependencies"] do
      assert provenance.components[name]["status"] == "unavailable"
      assert provenance.components[name]["reason"] == "not_provided"
    end
  end

  test "component names domain-separate identical available evidence" do
    attributes = %{"revision" => "same-value"}

    provenance =
      provenance!(
        code: {:available, attributes},
        target: {:available, attributes}
      )

    refute component_fingerprint(provenance, "code") ==
             component_fingerprint(provenance, "target")
  end

  test "capture accepts explicit sanitized build facts but not runtime substitution" do
    assert {:ok, provenance} =
             Provenance.capture(
               code: {:available, %{"commit" => "abc123", "dirty" => false}},
               dependencies: {:available, %{"lock_digest" => String.duplicate("b", 64)}},
               configuration: {:redacted, @policy_fingerprint}
             )

    assert provenance.components["code"]["attributes"]["commit"] == "abc123"
    assert provenance.components["dependencies"]["status"] == "available"
    assert provenance.components["configuration"]["status"] == "redacted"

    assert {:error, %Error{code: :invalid_provenance}} =
             Provenance.capture(runtime: {:available, %{}})
  end

  test "wire form round trips and rejects every integrity mismatch" do
    provenance = provenance!()
    wire = Provenance.to_wire_map(provenance)

    assert {:ok, ^provenance} = Provenance.decode_map(wire)
    assert {:ok, canonical} = Provenance.canonical_binary(provenance)
    assert {:ok, decoded_json} = Jason.decode(canonical)
    assert {:ok, ^provenance} = Provenance.decode_map(decoded_json)

    assert {:error, %Error{code: :unsupported_provenance_schema}} =
             Provenance.decode_map(Map.put(wire, "schema", "insider.provenance/v99"))

    assert {:error, %Error{code: :invalid_provenance}} =
             Provenance.decode_map(Map.put(wire, "fingerprint", String.duplicate("0", 64)))

    target = put_in(wire, ["components", "target", "attributes", "region"], "elsewhere")

    assert {:error, %Error{code: :invalid_provenance}} = Provenance.decode_map(target)

    extra = Map.put(wire, "unexpected", true)
    assert {:error, %Error{code: :invalid_provenance}} = Provenance.decode_map(extra)

    oversized = Map.new(1..1_000, &{"field-#{&1}", &1}) |> Map.put("schema", provenance.schema)
    assert {:error, %Error{code: :invalid_provenance}} = Provenance.decode_map(oversized)
  end

  test "constructors reject missing, duplicate, unsafe, oversized, and forged evidence" do
    options = valid_options()

    assert {:error, %Error{code: :invalid_provenance}} =
             Provenance.new(Keyword.delete(options, :target))

    assert {:error, %Error{code: :invalid_provenance}} =
             Provenance.new(options ++ [target: {:available, %{}}])

    for descriptor <- [
          {:available, %{atom_key: "unsafe"}},
          {:available, %{"pid" => self()}},
          {:available, %{"huge" => String.duplicate("x", 4_097)}},
          {:unavailable, :invented},
          {:redacted, "short"}
        ] do
      assert {:error, %Error{code: :invalid_provenance}} =
               Provenance.new(Keyword.put(options, :code, descriptor))
    end

    provenance = provenance!()
    forged = %{provenance | fingerprint: String.duplicate("f", 64)}
    assert {:error, %Error{code: :invalid_provenance}} = Provenance.validate(forged)

    hidden = Map.put(provenance, :hidden, "field")
    assert {:error, %Error{code: :invalid_provenance}} = Provenance.validate(hidden)

    assert {:error, %Error{code: :invalid_provenance}} = Provenance.new(:not_options)
    assert {:error, %Error{code: :invalid_provenance}} = Provenance.capture(:not_options)
    assert {:error, %Error{code: :invalid_provenance}} = Provenance.validate(%{})
    assert {:error, %Error{code: :invalid_provenance}} = Provenance.decode_map([])
    assert {:error, %Error{code: :invalid_provenance}} = Provenance.canonical_binary(%{})
  end

  test "every unavailability reason round trips and an unknown one is rejected by name" do
    for reason <- [:not_provided, :not_built, :not_supported, :collection_failed] do
      provenance = provenance!(dependencies: {:unavailable, reason})
      wire = Provenance.to_wire_map(provenance)

      assert wire["components"]["dependencies"]["reason"] == Atom.to_string(reason)
      assert {:ok, ^provenance} = Provenance.decode_map(wire)
    end

    wire =
      provenance!(dependencies: {:unavailable, :not_built})
      |> Provenance.to_wire_map()
      |> put_in(["components", "dependencies", "reason"], "forgotten")

    assert {:error,
            %Error{
              code: :invalid_provenance,
              message: "provenance unavailability reason is unknown"
            }} = Provenance.decode_map(wire)
  end

  test "decoding names the component set, component shape, and attribute failures" do
    wire = Provenance.to_wire_map(provenance!())

    for components <- ["components", Map.delete(wire["components"], "target")] do
      assert {:error, %Error{message: "provenance must contain the exact v1 components"}} =
               Provenance.decode_map(Map.put(wire, "components", components))
    end

    assert {:error, %Error{message: "provenance component has an invalid shape"}} =
             Provenance.decode_map(put_in(wire, ["components", "code", "status"], "withheld"))

    # A decoded available component whose attributes are not an object fails
    # as the constructor would, not as a fingerprint mismatch.
    assert {:error, %Error{message: "available provenance attributes are invalid or unbounded"}} =
             Provenance.decode_map(put_in(wire, ["components", "code", "attributes"], "abc123"))
  end

  test "validation rejects a struct whose components are not the exact valid set" do
    provenance = provenance!()

    assert {:error, %Error{message: "provenance contains invalid or inconsistent evidence"}} =
             Provenance.validate(%{provenance | components: []})

    tampered = put_in(provenance.components["code"]["status"], "withheld")

    assert {:error, %Error{message: "provenance contains invalid or inconsistent evidence"}} =
             Provenance.validate(tampered)
  end

  property "canonical fingerprints are stable for equivalent string-key maps" do
    check all(pairs <- list_of({string(:alphanumeric, min_length: 1), integer()}, max_length: 20)) do
      attributes = Map.new(pairs)
      reversed = attributes |> Map.to_list() |> Enum.reverse() |> Map.new()

      left = provenance!(target: {:available, attributes})
      right = provenance!(target: {:available, reversed})

      assert left.fingerprint == right.fingerprint
      assert component_fingerprint(left, "target") == component_fingerprint(right, "target")
    end
  end

  defp provenance!(overrides \\ []) do
    options = Keyword.merge(valid_options(), overrides)
    assert {:ok, provenance} = Provenance.new(options)
    provenance
  end

  defp valid_options do
    [
      code: {:available, %{"commit" => "abc123", "dirty" => false}},
      configuration: {:redacted, @policy_fingerprint},
      dependencies: {:available, %{"lock_digest" => String.duplicate("b", 64)}},
      runtime: {:available, %{"elixir" => "1.18.4", "otp" => "27"}},
      target: {:available, %{"region" => "ca-west", "tier" => "sandbox"}}
    ]
  end

  defp component_fingerprint(provenance, name),
    do: provenance.components[name]["fingerprint"]
end

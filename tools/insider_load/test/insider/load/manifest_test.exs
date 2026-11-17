defmodule Insider.Load.ManifestTest do
  use ExUnit.Case, async: true

  alias Insider.Event.Canonical
  alias Insider.Load.Manifest
  alias Insider.Protocol.Error

  test "round-trips a sorted SHA-256 inventory of every supplied artifact" do
    outputs = %{"samples.ndjson" => "two", "report.json" => "one"}
    assert {:ok, manifest} = Manifest.new(outputs)

    assert Enum.map(manifest.artifacts, & &1["path"]) == ["report.json", "samples.ndjson"]

    assert Enum.find(manifest.artifacts, &(&1["path"] == "report.json")) == %{
             "path" => "report.json",
             "byte_size" => 3,
             "sha256" => Canonical.sha256_binary("one")
           }

    assert {:ok, bytes} = Manifest.canonical_binary(manifest)
    assert {:ok, ^manifest} = Manifest.decode(bytes)
    assert {:ok, ^manifest} = Manifest.validate_with_artifacts(manifest, outputs)
  end

  test "rejects malformed, extra-key, unsupported, and noncanonical encodings" do
    assert {:error, %Error{code: :invalid_request}} = Manifest.decode("not-json")
    assert {:ok, manifest} = Manifest.new(%{"report.json" => "one"})
    wire = Manifest.to_wire_map(manifest)

    assert {:error, %Error{code: :invalid_request}} =
             wire |> Map.put("unexpected", true) |> Manifest.decode_map()

    assert {:error, %Error{code: :invalid_request}} =
             wire |> Map.put("schema", "insider.load-manifest/v2") |> Manifest.decode_map()

    assert {:ok, bytes} = Manifest.canonical_binary(manifest)
    assert {:error, %Error{code: :invalid_request}} = Manifest.decode(" " <> bytes)
  end

  test "detects substituted, missing, and additional output artifacts" do
    outputs = %{"report.json" => "one", "samples.ndjson" => "two"}
    assert {:ok, manifest} = Manifest.new(outputs)

    assert {:error, %Error{code: :invalid_request}} =
             Manifest.validate_with_artifacts(
               manifest,
               Map.put(outputs, "report.json", "changed")
             )

    assert {:error, %Error{code: :invalid_request}} =
             Manifest.validate_with_artifacts(manifest, Map.delete(outputs, "samples.ndjson"))

    assert {:error, %Error{code: :invalid_request}} =
             Manifest.validate_with_artifacts(manifest, Map.put(outputs, "extra.json", "extra"))
  end

  test "rejects unsafe paths, duplicates, self-reference, and oversized ingress" do
    for path <- ["/tmp/report.json", "../report.json", "nested\\report.json", "manifest.json"] do
      assert {:error, %Error{code: :invalid_request}} = Manifest.new([{path, "bytes"}])
    end

    assert {:error, %Error{code: :invalid_request}} =
             Manifest.new([{"report.json", "one"}, {"report.json", "two"}])

    oversized = String.duplicate("x", Manifest.maximum_bytes() + 1)
    assert {:error, %Error{code: :invalid_request}} = Manifest.decode(oversized)
  end

  test "rejects entry and envelope substitution without recomputed identities" do
    assert {:ok, manifest} = Manifest.new(%{"report.json" => "one"})
    wire = Manifest.to_wire_map(manifest)

    substituted = put_in(wire, ["artifacts", Access.at(0), "byte_size"], 4)
    assert {:error, %Error{code: :invalid_request}} = Manifest.decode_map(substituted)

    substituted_id = Map.put(wire, "id", "sha256:" <> String.duplicate("f", 64))
    assert {:error, %Error{code: :invalid_request}} = Manifest.decode_map(substituted_id)
  end
end

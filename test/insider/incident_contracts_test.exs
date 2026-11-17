defmodule Insider.IncidentContractsTest do
  use ExUnit.Case, async: true

  alias Insider.Incident.ArtifactReference
  alias Insider.Incident.ExportPolicy
  alias Insider.Protocol.Error
  alias Insider.Redaction.Policy

  test "artifact references round trip without locations or inline content" do
    assert {:ok, reference} =
             ArtifactReference.new(
               role: "vm-crash-dump",
               media_type: "application/octet-stream",
               byte_size: 4_096,
               sha256: String.duplicate("a", 64)
             )

    wire = ArtifactReference.to_wire_map(reference)
    assert Enum.sort(Map.keys(wire)) == ["byte_size", "media_type", "role", "sha256"]
    refute Map.has_key?(wire, "path")
    refute Map.has_key?(wire, "content")
    assert {:ok, ^reference} = ArtifactReference.decode_map(wire)
  end

  test "artifact references reject malformed digests, inline fields, and forged structs" do
    assert {:error, %Error{code: :invalid_artifact_reference}} =
             ArtifactReference.new(
               role: "dump",
               media_type: "application/octet-stream",
               byte_size: 1,
               sha256: "short"
             )

    {:ok, reference} = artifact()
    wire = ArtifactReference.to_wire_map(reference)

    assert {:error, %Error{code: :invalid_artifact_reference}} =
             ArtifactReference.decode_map(Map.put(wire, "content", "secret"))

    forged = %{reference | byte_size: 0}

    assert {:error, %Error{code: :invalid_artifact_reference}} =
             ArtifactReference.validate(forged)

    for options <- [
          [
            role: "UPPER",
            media_type: "application/octet-stream",
            byte_size: 1,
            sha256: reference.sha256
          ],
          [
            role: "dump",
            media_type: "not-a-media-type",
            byte_size: 1,
            sha256: reference.sha256
          ],
          [
            role: "dump",
            media_type: "application/octet-stream",
            byte_size: 1_099_511_627_777,
            sha256: reference.sha256
          ]
        ] do
      assert {:error, %Error{code: :invalid_artifact_reference}} =
               ArtifactReference.new(options)
    end

    assert {:error, %Error{code: :invalid_artifact_reference}} = ArtifactReference.new(:invalid)

    assert {:error, %Error{code: :invalid_artifact_reference}} =
             ArtifactReference.new(role: "dump")

    assert {:error, %Error{code: :invalid_artifact_reference}} =
             ArtifactReference.decode_map([])

    assert {:error, %Error{code: :invalid_artifact_reference}} =
             ArtifactReference.validate(%{})

    hidden = Map.put(reference, :hidden, true)

    assert {:error, %Error{code: :invalid_artifact_reference}} =
             ArtifactReference.validate(hidden)
  end

  test "export policies require every trusted root classification and resist forgery" do
    redaction_policy = redaction_policy!()
    sensitivities = root_sensitivities()

    assert {:ok, export_policy} = ExportPolicy.new(redaction_policy, sensitivities)
    assert ExportPolicy.valid?(export_policy)
    assert byte_size(export_policy.fingerprint) == 64
    assert export_policy.max_duration_ms == 10_000

    assert {:error, %Error{code: :redaction_failed}} =
             ExportPolicy.new(redaction_policy, Keyword.delete(sensitivities, :event))

    forged = %{
      export_policy
      | sensitivities: Map.put(export_policy.sensitivities, :event, :public)
    }

    refute ExportPolicy.valid?(forged)

    assert {:error, %Error{code: :redaction_failed}} =
             ExportPolicy.new(redaction_policy, sensitivities, max_duration_ms: 30_001)

    assert {:error, %Error{code: :redaction_failed}} =
             ExportPolicy.new(redaction_policy, sensitivities, unknown: true)

    assert {:error, %Error{code: :redaction_failed}} = ExportPolicy.new(%{}, sensitivities)
    refute ExportPolicy.valid?(%{export_policy | sensitivities: :invalid})
    refute ExportPolicy.valid?(Map.put(export_policy, :hidden, true))
    refute ExportPolicy.valid?(%{})
  end

  defp artifact do
    ArtifactReference.new(
      role: "dump",
      media_type: "application/octet-stream",
      byte_size: 1,
      sha256: String.duplicate("b", 64)
    )
  end

  defp redaction_policy! do
    assert {:ok, policy} =
             Policy.new(
               id: "capsule-test",
               maximum_sensitivity: :internal,
               rules: [],
               max_output_bytes: 1_048_576
             )

    policy
  end

  defp root_sensitivities do
    [
      finding: :internal,
      snapshot: :internal,
      event: :internal,
      provenance: :internal,
      authority: :internal,
      artifacts: :internal
    ]
  end
end

defmodule Insider.Sentinel.DraftCreationIdentityTest do
  use ExUnit.Case, async: true

  alias Insider.Event.Canonical
  alias Insider.Protocol.Error
  alias Insider.Sentinel.DraftCreation.DisclosureAuthority
  alias Insider.Sentinel.DraftCreation.DisclosureDecision
  alias Insider.Sentinel.DraftCreation.Identity
  alias Insider.Sentinel.DraftCreation.Provider

  @destination String.duplicate("a", 64)
  @other_destination String.duplicate("b", 64)
  @provider %{
    "destination_fingerprint" => @destination,
    "id" => "test.draft-provider",
    "version" => 1
  }
  @authority %{"id" => "test.disclosure-authority", "version" => 1}
  @decision_reference "policy-decision-123"
  @payload %{
    "byte_size" => 1_024,
    "canonical_sha256" => String.duplicate("c", 64),
    "schema" => "insider.draft-creation-payload/v1"
  }

  test "provider and disclosure-authority identities are exact bounded wire identities" do
    assert Identity.provider?(@provider)
    assert Identity.disclosure_authority?(@authority)
    assert {:ok, @provider} = Identity.validate_provider(@provider)
    assert {:ok, @authority} = Identity.validate_disclosure_authority(@authority)

    refute Identity.provider?(Map.delete(@provider, "destination_fingerprint"))
    refute Identity.provider?(Map.put(@provider, "destination_fingerprint", "not-a-digest"))
    refute Identity.provider?(Map.put(@provider, "unexpected", true))
    refute Identity.provider?(Map.put(@provider, :id, "atom-bearing"))
    refute Identity.provider?(%{@provider | "id" => String.duplicate("a", 129)})
    refute Identity.provider?(%{@provider | "id" => "Uppercase"})
    refute Identity.provider?(%{@provider | "version" => 0})

    refute Identity.disclosure_authority?(Map.put(@authority, "unexpected", true))
    refute Identity.disclosure_authority?(Map.put(@authority, :id, "atom-bearing"))
    refute Identity.disclosure_authority?(%{@authority | "id" => String.duplicate("a", 129)})
    refute Identity.disclosure_authority?(%{@authority | "version" => 1_000_001})

    assert {:error, %Error{code: :invalid_request}} =
             Identity.validate_provider(Map.put(@provider, "unexpected", true))

    assert {:error, %Error{code: :invalid_request}} =
             Identity.validate_disclosure_authority(Map.put(@authority, :id, "atom-bearing"))
  end

  test "canonical disclosure decision round-trips and recomputes from exact authority inputs" do
    assert {:ok, decision} =
             DisclosureDecision.new(@payload, @provider, @authority, @decision_reference)

    assert decision.status == "approved_for_draft_creation"
    assert decision.controls["draft"] == true
    assert decision.controls["review_required"] == true
    assert decision.controls["merge"] == "prohibited"
    assert decision.controls["deploy"] == "prohibited"
    assert decision.trust["hashes"] == "identity_not_authenticity"
    assert decision.trust["standalone_validation"] == "record_identity_only"

    assert {:ok, ^decision} = DisclosureDecision.validate(decision)

    assert {:ok, ^decision} =
             DisclosureDecision.validate_with(
               decision,
               @payload,
               @provider,
               @authority,
               @decision_reference
             )

    assert {:ok, encoded} = DisclosureDecision.canonical_binary(decision)
    assert encoded == Canonical.encode(DisclosureDecision.to_wire_map(decision))
    assert {:ok, ^decision} = DisclosureDecision.decode(encoded)
  end

  test "content identity is not authority authenticity" do
    self_asserted_authority = %{"id" => "untrusted.self-asserted-authority", "version" => 1}

    assert {:ok, self_asserted} =
             DisclosureDecision.new(
               @payload,
               @provider,
               self_asserted_authority,
               "self-asserted-reference"
             )

    # The record is internally canonical, but that alone cannot make its issuer
    # the configured authority for this exact decision.
    assert {:ok, ^self_asserted} = DisclosureDecision.validate(self_asserted)

    assert {:error, %Error{code: :operation_failed}} =
             DisclosureDecision.validate_with(
               self_asserted,
               @payload,
               @provider,
               @authority,
               "self-asserted-reference"
             )
  end

  test "exact recomputation rejects payload, destination, provider, authority, and reference substitutions" do
    {:ok, decision} =
      DisclosureDecision.new(@payload, @provider, @authority, @decision_reference)

    other_payload = %{@payload | "canonical_sha256" => String.duplicate("d", 64)}
    other_destination = %{@provider | "destination_fingerprint" => @other_destination}
    other_provider = %{@provider | "id" => "test.other-draft-provider"}
    other_authority = %{@authority | "id" => "test.other-disclosure-authority"}

    substitutions = [
      [other_payload, @provider, @authority, @decision_reference],
      [@payload, other_destination, @authority, @decision_reference],
      [@payload, other_provider, @authority, @decision_reference],
      [@payload, @provider, other_authority, @decision_reference],
      [@payload, @provider, @authority, "different-policy-decision"]
    ]

    for arguments <- substitutions do
      assert {:error, %Error{code: :operation_failed}} =
               apply(DisclosureDecision, :validate_with, [decision | arguments])
    end
  end

  test "decision construction rejects malformed and out-of-bound authority inputs" do
    invalid_payloads = [
      Map.delete(@payload, "schema"),
      Map.put(@payload, "unexpected", true),
      %{@payload | "byte_size" => 0},
      %{@payload | "byte_size" => 2_097_153},
      %{@payload | "canonical_sha256" => "not-a-digest"},
      %{@payload | "schema" => String.duplicate("s", 129)},
      Map.put(@payload, :schema, "atom-bearing")
    ]

    for payload <- invalid_payloads do
      assert {:error, %Error{code: :invalid_request}} =
               DisclosureDecision.new(payload, @provider, @authority, @decision_reference)
    end

    for reference <- ["", String.duplicate("r", 513), <<255>>] do
      refute DisclosureAuthority.decision_reference?(reference)

      assert {:error, %Error{code: :invalid_request}} =
               DisclosureDecision.new(@payload, @provider, @authority, reference)
    end

    assert DisclosureAuthority.decision_reference?(String.duplicate("r", 512))
  end

  test "strict ingress rejects malformed, noncanonical, oversized, unknown, and atom-bearing data" do
    {:ok, decision} =
      DisclosureDecision.new(@payload, @provider, @authority, @decision_reference)

    {:ok, encoded} = DisclosureDecision.canonical_binary(decision)
    unknown = "hostile_draft_decision_key_that_must_not_become_an_atom"
    refute_existing_atom(unknown)

    assert {:error, %Error{code: :invalid_request}} = DisclosureDecision.decode("{")

    assert {:error, %Error{code: :invalid_request}} =
             DisclosureDecision.decode(encoded <> "\n")

    assert {:error, %Error{code: :invalid_request}} =
             DisclosureDecision.decode(String.duplicate("x", 16_385))

    assert {:error, %Error{code: :invalid_request}} =
             decision
             |> DisclosureDecision.to_wire_map()
             |> Map.put("schema", "insider.draft-creation-disclosure-decision/v2")
             |> DisclosureDecision.decode_map()

    assert {:error, %Error{code: :invalid_request}} =
             decision
             |> DisclosureDecision.to_wire_map()
             |> Map.put(unknown, true)
             |> DisclosureDecision.decode_map()

    refute_existing_atom(unknown)

    assert {:error, %Error{code: :invalid_request}} =
             decision
             |> DisclosureDecision.to_wire_map()
             |> Map.put(:hostile, true)
             |> DisclosureDecision.decode_map()

    assert {:error, %Error{code: :invalid_request}} =
             DisclosureDecision.decode_map(%{"schema" => ["hostile"]})
  end

  test "provider responses accept only bounded round-trippable wire data" do
    assert Provider.response?(%{
             "draft" => true,
             "draft_reference" => "provider-draft-123",
             "outcome" => "created",
             "review_required" => true
           })

    refute Provider.response?(%{"response" => String.duplicate("x", 16_385)})
    refute Provider.response?(%{:atom_key => "not-wire-data"})
    refute Provider.response?(%{"atom_value" => :not_wire_data})
    refute Provider.response?(%{"tuple" => {:not, :wire_data}})
    refute Provider.response?(%URI{scheme: "https", host: "example.invalid"})
    refute Provider.response?(["not", "a", "map"])
    refute Provider.response?(%{"invalid_utf8" => <<255>>})
  end

  defp refute_existing_atom(value),
    do: assert_raise(ArgumentError, fn -> String.to_existing_atom(value) end)
end

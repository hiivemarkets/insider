defmodule Insider.LoadHarness.ProfileTest do
  use ExUnit.Case, async: true

  alias Insider.Event.Canonical
  alias Insider.LoadHarness.Profile

  test "checked-in profiles are canonical, bounded, and round-trip" do
    for name <- ["load", "soak"] do
      bytes = File.read!("config/#{name}.json")
      assert {:ok, profile} = Profile.decode(bytes)
      assert profile.mode == name
      canonical = Canonical.encode(Profile.to_wire_map(profile))
      assert bytes == canonical <> "\n"
      assert profile.canonical_sha256 == Canonical.sha256_binary(canonical)
    end
  end

  test "rejects noncanonical, unknown, oversized, and out-of-bound profiles" do
    wire =
      "config/load.json"
      |> File.read!()
      |> Jason.decode!()

    assert {:error, :invalid_profile} = Profile.decode(Jason.encode!(wire, pretty: true))

    for invalid <- [
          Map.put(wire, "unknown", true),
          Map.put(wire, "rate_per_second", 0),
          Map.put(wire, "overload_ms", 0),
          Map.put(wire, "overload_rate_per_second", wire["rate_per_second"]),
          Map.put(wire, "overload_rate_per_second", 5_001),
          Map.put(wire, "sample_interval_ms", 999),
          Map.put(wire, "max_samples", 513),
          Map.put(wire, "inbox_size", 1_025),
          Map.put(wire, "recorder_bytes", 16 * 1_024 * 1_024 + 1),
          Map.put(wire, "steady_ms", 3_600_000)
        ] do
      assert {:error, :invalid_profile} = Profile.decode(Canonical.encode(invalid))
    end

    assert {:error, :invalid_profile} = Profile.decode(String.duplicate("x", 65_537))
  end
end

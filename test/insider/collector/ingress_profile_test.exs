defmodule Insider.Collector.IngressProfileTest do
  use ExUnit.Case, async: true

  alias Insider.Collector.IngressProfile

  test "development, test, and CI profiles are explicit while staging and production fail closed" do
    for environment <- [:development, :test, :ci] do
      assert {:ok, profile} = IngressProfile.new(environment)
      assert profile.observation_enabled
      assert profile.logger_payload
      assert profile.logger_message_semantics
      refute profile.logger_structural_only
      assert profile.telemetry_projection == "exact_allowlist_required"
      assert IngressProfile.valid?(profile)
    end

    for environment <- [:staging, :production] do
      assert {:ok, profile} = IngressProfile.new(environment)
      refute profile.observation_enabled
      refute profile.logger_payload
      refute profile.logger_message_semantics
      assert profile.logger_structural_only
      assert profile.telemetry_projection == "exact_allowlist_required"
      assert IngressProfile.valid?(profile)
    end
  end

  test "unknown or forged profiles are rejected" do
    assert {:error, :invalid_profile} = IngressProfile.new(:preview)
    assert {:error, :invalid_profile} = IngressProfile.new("production")
    refute IngressProfile.valid?(%{})
  end
end

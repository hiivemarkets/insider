defmodule Insider.Collector.Session.StartupGuardTest do
  use ExUnit.Case, async: true

  alias Insider.Collector.Session.StartupGuard

  test "authorizes only live tokens and revokes them explicitly" do
    guard = StartupGuard.new()
    other_guard = StartupGuard.new()
    token = make_ref()
    now = System.monotonic_time(:millisecond)

    refute StartupGuard.authorized?(guard, token, now)
    assert :ok = StartupGuard.authorize(guard, token, now + 100)
    assert StartupGuard.authorized?(guard, token, now)
    refute StartupGuard.authorized?(other_guard, token, now)
    refute StartupGuard.authorized?(guard, token, now + 100)
    assert :ok = StartupGuard.revoke(guard, token)
    refute StartupGuard.authorized?(guard, token, now)
  end

  test "malformed capabilities fail closed" do
    refute StartupGuard.authorized?(:not_a_guard, make_ref(), 0)
    refute StartupGuard.authorized?(StartupGuard.new(), :not_a_token, 0)
  end
end

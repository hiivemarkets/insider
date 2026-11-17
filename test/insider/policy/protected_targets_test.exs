defmodule Insider.Policy.ProtectedTargetsTest do
  use ExUnit.Case, async: true

  alias Insider.Policy.ProtectedTargets

  test "host declarations are bounded, additive, and cannot be supplied twice" do
    target =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, policy} = ProtectedTargets.new(host_targets: [target])
    assert policy.inventory_version == "otp_elixir_runtime_registry/v1"
    assert policy.otp_major =~ ~r/^\d+$/
    assert "erts_code_purger" in policy.registration_names
    assert "Elixir.Insider.Supervisor" in policy.registration_names
    assert {:protected, %{"class" => "host_declared"}} = ProtectedTargets.classify(policy, target)
    assert {:error, :invalid_policy} = ProtectedTargets.new(host_targets: [target, target])

    assert {:error, :invalid_policy} =
             ProtectedTargets.new(host_targets: [target], host_targets: [])

    assert {:error, :invalid_policy} =
             ProtectedTargets.new(host_targets: List.duplicate(target, 33))

    send(target, :stop)
  end

  test "collector binding derives its own control inventory and a forged omission cannot weaken it" do
    recorder = self()
    assert {:ok, base} = ProtectedTargets.new()
    assert {:ok, bound} = ProtectedTargets.bind_collector(base, recorder)

    assert {:protected, %{"class" => "insider_control_plane"}} =
             ProtectedTargets.classify(bound, self())

    assert Enum.member?(bound.control_targets, self())
    assert Enum.member?(bound.control_targets, recorder)

    insider_supervisor = Process.whereis(Insider.Supervisor)
    assert is_pid(insider_supervisor)

    assert {:protected, %{"class" => "insider_control_plane"}} =
             ProtectedTargets.classify(bound, insider_supervisor)

    assert {:allowed, _evidence} = ProtectedTargets.classify(base, self())
  end

  test "fixed OTP registry targets are protected before inspection" do
    assert {:ok, policy} = ProtectedTargets.new()

    for name <- [
          :logger,
          :erts_code_purger,
          :erl_prim_loader,
          :rex,
          :global_name_server,
          Insider.Supervisor
        ] do
      pid = Process.whereis(name)
      assert is_pid(pid), "#{inspect(name)} must be registered in the BEAM test runtime"
      assert {:protected, %{"class" => "beam_otp"}} = ProtectedTargets.classify(policy, pid)
    end
  end

  test "dead declared pids remain denied while an unrelated dead local pid is not mistaken for control plane" do
    target = spawn(fn -> :ok end)
    monitor = Process.monitor(target)
    assert_receive {:DOWN, ^monitor, :process, ^target, _reason}

    assert {:ok, policy} = ProtectedTargets.new(host_targets: [target])
    assert {:protected, %{"class" => "host_declared"}} = ProtectedTargets.classify(policy, target)

    unrelated = spawn(fn -> :ok end)
    unrelated_monitor = Process.monitor(unrelated)
    assert_receive {:DOWN, ^unrelated_monitor, :process, ^unrelated, _reason}

    assert {:allowed, %{"class" => "none"}} = ProtectedTargets.classify(policy, unrelated)
  end
end

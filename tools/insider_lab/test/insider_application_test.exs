defmodule Insider.ApplicationTest do
  use ExUnit.Case, async: false

  test "start/2 owns a supervised process and it terminates cleanly" do
    supervisor = Process.whereis(Insider.Lab.Supervisor)
    application_reference = Process.monitor(supervisor)

    on_exit(fn ->
      case Application.ensure_all_started(:insider_lab) do
        {:ok, _started} ->
          :ok

        {:error, reason} ->
          raise "failed to restore Insider after lifecycle test: #{inspect(reason)}"
      end
    end)

    assert :ok = Application.stop(:insider_lab)
    assert_receive {:DOWN, ^application_reference, :process, ^supervisor, :shutdown}, 1_000
    refute Process.alive?(supervisor)

    assert {:ok, started_supervisor} = Insider.Lab.Application.start(:normal, [])
    assert Process.whereis(Insider.Lab.Supervisor) == started_supervisor

    Process.unlink(started_supervisor)
    reference = Process.monitor(started_supervisor)
    Process.exit(started_supervisor, :shutdown)

    assert_receive {:DOWN, ^reference, :process, ^started_supervisor, :shutdown}
  end

  test "mutation-oriented execution components are opt-in" do
    assert Insider.Lab.Application.children() == [Insider.Contract.Executor]
    assert [{_, contract, :supervisor, _}] = Supervisor.which_children(Insider.Lab.Supervisor)
    assert contract == Process.whereis(Insider.Contract.Executor)
    refute Process.whereis(Insider.Scenario.Executor)
    refute Process.whereis(Insider.Sentinel.Sandbox.Executor)
  end

  test "scenario configuration starts its execution dependency" do
    assert :ok = Application.stop(:insider_lab)
    Application.put_env(:insider_lab, :components, [:scenario])

    assert Insider.Lab.Application.children() == [
             Insider.Contract.Executor,
             Insider.Scenario.Executor
           ]

    on_exit(fn ->
      Application.stop(:insider_lab)
      Application.delete_env(:insider_lab, :components)
      assert {:ok, _started} = Application.ensure_all_started(:insider_lab)
    end)

    assert {:ok, _started} = Application.ensure_all_started(:insider_lab)
    assert Process.whereis(Insider.Contract.Executor)
    assert Process.whereis(Insider.Scenario.Executor)
    refute Process.whereis(Insider.Sentinel.Sandbox.Executor)
  end

  test "sentinel configuration is explicit and unknown components fail closed" do
    on_exit(fn -> Application.delete_env(:insider_lab, :components) end)

    Application.put_env(:insider_lab, :components, [:sentinel])

    assert Insider.Lab.Application.children() == [
             {Insider.Sentinel.Sandbox.Executor, providers: []}
           ]

    Application.put_env(:insider_lab, :components, [:unknown])

    assert_raise ArgumentError,
                 ~r/unknown Insider Lab component/,
                 &Insider.Lab.Application.children/0
  end
end

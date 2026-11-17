defmodule Insider.Policy.DistributionTargetsTest do
  use ExUnit.Case, async: false

  @required_distribution_registrations [:net_kernel, :net_sup, :auth, :erl_epmd]
  @boot_option_injectors [
    "ERL_EPMD_PORT",
    "ERL_AFLAGS",
    "ERL_ZFLAGS",
    "ERL_FLAGS",
    "ELIXIR_ERL_OPTIONS"
  ]

  test "an isolated named node protects every present distribution-control registration before provider work" do
    port = free_loopback_port!()
    start_epmd!(port)
    on_exit(fn -> stop_epmd!(port) end)
    await_epmd!(port, 20)

    {output, status} = run_isolated_node(port)

    assert status == 0, "isolated named-node assertion failed:\n#{output}"
    assert output =~ "INSIDER_DISTRIBUTION_POLICY_OK"
  end

  test "isolated named node clears an inherited epmd-port override before boot" do
    port = free_loopback_port!()
    start_epmd!(port)
    on_exit(fn -> stop_epmd!(port) end)
    await_epmd!(port, 20)

    {output, status} = run_isolated_node(port, [{"ERL_EPMD_PORT", "61991"}])

    assert status == 0, "ambient epmd-port override was not cleared:\n#{output}"
    assert output =~ "INSIDER_DISTRIBUTION_POLICY_OK"
  end

  defp free_loopback_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp start_epmd!(port) do
    {_output, status} =
      System.cmd("epmd", ["-daemon", "-port", Integer.to_string(port)], stderr_to_stdout: true)

    assert status == 0
  end

  defp run_isolated_node(port, inherited_environment \\ []) do
    node_name = "insider_distribution_#{System.unique_integer([:positive])}"
    code_path_arguments = test_build_code_paths() |> Enum.flat_map(&["-pa", &1])

    arguments =
      ["--sname", node_name, "--erl", "-epmd_port #{port}"] ++
        code_path_arguments ++ ["-e", isolated_node_script(port)]

    task =
      Task.async(fn ->
        System.cmd(
          "elixir",
          arguments,
          env: child_environment(inherited_environment),
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, 10_000) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {"isolated named-node assertion timed out after 10_000ms", 1}
    end
  end

  defp child_environment(inherited_environment) do
    # `System.cmd/3` uses nil to remove an inherited variable; an empty value
    # would still be parsed by Erlang's boot-option injectors.
    [{"MIX_ENV", "test"}] ++ inherited_environment ++ Enum.map(@boot_option_injectors, &{&1, nil})
  end

  defp test_build_code_paths do
    build_path = Mix.Project.build_path() |> Path.expand()

    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&String.starts_with?(&1, build_path))
  end

  defp isolated_node_script(port) do
    expected_epmd_port = port |> Integer.to_string() |> String.to_charlist()
    required_registrations = inspect(@required_distribution_registrations)

    """
    defmodule InsiderDistributionRaisingProvider do
      def process_sample(_pid), do: raise("distribution target provider must not run")
    end

    expected_epmd_port = #{inspect(expected_epmd_port)}
    required_registrations = #{required_registrations}

    {:ok, _started} = Application.ensure_all_started(:insider)
    {:ok, [[^expected_epmd_port]]} = :init.get_argument(:epmd_port)
    {:ok, policy} = Insider.Policy.ProtectedTargets.new()
    {:ok, host_policy} = Insider.Runtime.bind_host_policy([])

    Enum.each(required_registrations, fn name ->
      pid = Process.whereis(name)
      true = is_pid(pid)
      {:protected, %{"class" => "beam_otp"}} =
        Insider.Policy.ProtectedTargets.classify(policy, pid)

      %Insider.Protocol.Result{
        status: :error,
        error: %Insider.Protocol.Error{
          code: :policy_denied,
          details: %{target_protection: %{"class" => "beam_otp"}}
        }
      } =
        Insider.Runtime.describe(
          pid,
          [environment: :test, provider: InsiderDistributionRaisingProvider],
          host_policy
        )
    end)

    IO.puts("INSIDER_DISTRIBUTION_POLICY_OK")
    """
  end

  defp await_epmd!(_port, 0),
    do: flunk("test-owned epmd did not become reachable after bounded startup")

  defp await_epmd!(port, remaining) do
    if epmd_reachable?(port) do
      :ok
    else
      Process.sleep(25)
      await_epmd!(port, remaining - 1)
    end
  end

  defp epmd_reachable?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp stop_epmd!(port) do
    {_output, status} =
      System.cmd("epmd", ["-port", Integer.to_string(port), "-kill"], stderr_to_stdout: true)

    assert status == 0
  end
end

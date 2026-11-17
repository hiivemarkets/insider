defmodule Insider.RuntimeTest do
  use ExUnit.Case, async: true

  alias Insider.Protocol.Error
  alias Insider.Protocol.Result
  alias Insider.Protocol
  alias Insider.Runtime

  @non_timeout_options [environment: :test, probe_timeout_ms: 1_000, cleanup_timeout_ms: 100]

  defmodule BlockingProvider do
    def process_sample(_pid), do: receive(do: (:never -> :ok))
  end

  defmodule ObservableBlockingProvider do
    def process_sample(owner) do
      {:max_heap_size, heap_limit} = Process.info(self(), :max_heap_size)
      send(owner, {:runtime_probe_started, self(), heap_limit})
      receive(do: (:never -> :ok))
    end
  end

  defmodule DelayedProvider do
    def process_sample(_pid) do
      Process.sleep(10)
      {:ok, :complete, %{}, []}
    end
  end

  defmodule RaisingProvider do
    def process_sample(_pid), do: raise("provider failure")
  end

  defmodule MalformedProvider do
    def process_sample(_pid), do: :unexpected
  end

  defmodule OversizedProvider do
    def process_sample(_pid) do
      {:ok, :complete, %{"payload" => String.duplicate("x", 65_536)}, []}
    end
  end

  test "capabilities report the implemented read-only operation and constraints" do
    assert %Result{status: :ok, value: value} = Runtime.capabilities(environment: :test)
    describe = Enum.find(value["operations"], &(&1.operation == "process.describe"))

    assert describe.runtime_available
    assert describe.runtime_isolation == :read_only
    assert describe.policy_disposition == :grant_required
    assert "no_messages_or_process_state" in value["constraints"]
  end

  test "describes bounded scalar process data without messages or process state" do
    send(self(), {:private, "payload"})

    assert %Result{status: :ok, value: value, cleanup: %{status: :complete}} =
             Runtime.describe(self(), @non_timeout_options, host_policy!())

    assert value["schema"] == "insider.process-description/v1"
    assert value["target"]["pid"] == self() |> :erlang.pid_to_list() |> to_string()
    assert value["observer_effect"] == "synchronous_runtime_inspection"
    assert value["metrics"]["message_queue_len"] >= 1
    refute Map.has_key?(value["metrics"], "messages")
    refute Map.has_key?(value["metrics"], "dictionary")
    refute Map.has_key?(value["metrics"], "state")

    assert_receive {:private, "payload"}
  end

  test "rejects invalid environments and non-process targets" do
    assert {:error, %Error{code: :invalid_request}} =
             Runtime.capabilities(environment: :production)

    assert {:error, %Error{code: :invalid_request}} =
             Runtime.describe(:not_a_pid, environment: :test)

    assert {:error, %Error{code: :invalid_request}} =
             Runtime.describe(self(), environment: :test)
  end

  test "denies fixed OTP targets before a caller-selected provider can inspect them" do
    for name <- [:logger, :erts_code_purger, :erl_prim_loader, :rex, :global_name_server] do
      pid = Process.whereis(name)
      assert is_pid(pid), "#{inspect(name)} must be registered in the BEAM test runtime"

      assert %Result{
               status: :error,
               error: %Error{
                 code: :policy_denied,
                 details: %{target_protection: %{"class" => "beam_otp"}}
               }
             } =
               Runtime.describe(
                 pid,
                 [
                   environment: :test,
                   provider: RaisingProvider,
                   probe_timeout_ms: 1_000,
                   cleanup_timeout_ms: 100
                 ],
                 host_policy!()
               )
    end

    assert {:error, %Error{code: :invalid_request}} =
             Runtime.describe(self(), environment: :test, protected_targets: [])
  end

  test "trusted host bindings add protected application targets and decoded request fields cannot replace them" do
    target =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, host_policy} = Runtime.bind_host_policy(host_protected_targets: [target])

    assert %Result{
             status: :error,
             error: %Error{
               code: :policy_denied,
               details: %{target_protection: %{"class" => "host_declared"}}
             }
           } =
             Runtime.describe(
               target,
               Keyword.put(@non_timeout_options, :provider, RaisingProvider),
               host_policy
             )

    assert {:ok, request} =
             Protocol.request("process.describe",
               request_id: "runtime-forged-host-policy",
               environment: :test,
               timeout_ms: 1_000,
               budget: [max_duration_ms: 1_000, max_events: 1, max_bytes: 65_536],
               params: %{
                 "host_protected_targets" => [],
                 "pid" => target |> :erlang.pid_to_list() |> to_string()
               },
               capability: Runtime.observation_capability()
             )

    assert %Result{status: :error, error: %Error{code: :operation_failed}} =
             Runtime.dispatch(
               request,
               [environment: :test, provider: RaisingProvider],
               host_policy
             )

    send(target, :stop)
  end

  test "dispatch rejects malformed targets and forbidden runtime options" do
    assert {:ok, request} =
             Protocol.request("process.describe",
               request_id: "runtime-malformed-target",
               environment: :test,
               timeout_ms: 1_000,
               budget: [max_duration_ms: 1_000, max_events: 1, max_bytes: 65_536],
               params: %{"pid" => "not-a-pid"},
               capability: Runtime.observation_capability()
             )

    assert %Result{status: :error, error: %Error{code: :policy_denied}} =
             Runtime.dispatch(request, environment: :test)

    assert %Result{status: :error, error: %Error{code: :policy_denied}} =
             Runtime.dispatch(request, environment: :production)
  end

  test "contains provider timeouts and reports cleanup" do
    assert %Result{
             status: :timeout,
             cleanup: %{status: :complete},
             uncertainty: [_reason]
           } =
             Runtime.describe(
               self(),
               [
                 environment: :test,
                 provider: BlockingProvider,
                 probe_timeout_ms: 5,
                 cleanup_timeout_ms: 50
               ],
               host_policy!()
             )
  end

  test "normalizes provider exceptions and malformed results" do
    assert %Result{status: :error, error: %Error{code: :operation_failed}} =
             Runtime.describe(
               self(),
               Keyword.put(@non_timeout_options, :provider, RaisingProvider),
               host_policy!()
             )

    assert %Result{status: :error, error: %Error{code: :operation_failed}} =
             Runtime.describe(
               self(),
               Keyword.put(@non_timeout_options, :provider, MalformedProvider),
               host_policy!()
             )
  end

  test "rejects evidence that exceeds the runtime byte bound" do
    assert %Result{status: :error, error: %Error{code: :operation_failed}} =
             Runtime.describe(
               self(),
               Keyword.put(@non_timeout_options, :provider, OversizedProvider),
               host_policy!()
             )
  end

  test "reports an actual Erlang provider lookup for a terminated process" do
    target = spawn(fn -> receive(do: (:stop -> :ok)) end)
    monitor = Process.monitor(target)
    send(target, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^target, :normal}

    assert %Result{status: :error, error: %Error{code: :operation_failed}} =
             Runtime.describe(target, @non_timeout_options, host_policy!())
  end

  test "terminates probe work when the runtime caller dies" do
    owner = self()

    caller =
      spawn(fn ->
        Runtime.describe(
          owner,
          [
            environment: :test,
            provider: ObservableBlockingProvider,
            probe_timeout_ms: 1_000,
            cleanup_timeout_ms: 100
          ],
          host_policy!()
        )
      end)

    assert_receive {:runtime_probe_started, probe, heap_limit}
    assert heap_limit.size == 1_048_576
    assert heap_limit.kill
    monitor = Process.monitor(probe)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^probe, :killed}, 1_000
  end

  test "drains a provider result that races timeout cleanup" do
    assert %Result{status: :timeout, cleanup: %{status: :complete}} =
             Runtime.describe(
               self(),
               [
                 environment: :test,
                 provider: DelayedProvider,
                 probe_timeout_ms: 5,
                 cleanup_timeout_ms: 50
               ],
               host_policy!()
             )

    refute_receive {:runtime_probe_result, _token, _result}
  end

  defp host_policy! do
    {:ok, host_policy} = Runtime.bind_host_policy([])
    host_policy
  end
end

defmodule Insider.Sentinel.SandboxTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Insider.Policy
  alias Insider.Policy.Context
  alias Insider.Policy.Grant
  alias Insider.Protocol.Budget
  alias Insider.Protocol.Effect
  alias Insider.Protocol.Error
  alias Insider.Protocol.Request
  alias Insider.Protocol.Result
  alias Insider.Provenance
  alias Insider.Sentinel.Sandbox
  alias Insider.Sentinel.Sandbox.CleanupOwnership
  alias Insider.Sentinel.Sandbox.Executor
  alias Insider.Sentinel.Sandbox.ProviderCall
  alias Insider.Sentinel.Sandbox.Registry
  alias Insider.Sentinel.Sandbox.Runner
  alias Insider.Sentinel.Sandbox.Target
  alias Insider.TestSupport.SandboxProvider
  alias Insider.TestSupport.SandboxBody

  defmodule HostileCallback do
    def crash, do: raise("callback crash")
    def oversized, do: String.duplicate("x", 65_537)

    def block do
      receive do
        :never -> :ok
      end
    end
  end

  setup do
    test = self()
    Process.register(self(), Insider.TestSupport.SandboxBodyProbe)
    state = start_supervised!({Agent, fn -> %{resources: %{}, targets: %{}, test: test} end})
    Process.register(state, Insider.TestSupport.SandboxProviderState)

    executor =
      start_supervised!(
        {Executor,
         name: nil, providers: [SandboxProvider], bodies: [SandboxBody], max_concurrency: 8}
      )

    on_exit(fn ->
      if Process.whereis(Insider.TestSupport.SandboxProviderState) == state,
        do: Process.unregister(Insider.TestSupport.SandboxProviderState)

      if Process.whereis(Insider.TestSupport.SandboxBodyProbe) == self(),
        do: Process.unregister(Insider.TestSupport.SandboxBodyProbe)
    end)

    %{executor: executor, state: state}
  end

  test "trusted body runs after exact observation and before cleanup", %{
    executor: executor,
    state: state
  } do
    target = target!("success", 71)
    {request, context} = authority!(target, "body-success")

    assert %Result{
             status: :ok,
             value: %{"body_receipt" => %{"outcome" => "completed"}},
             cleanup: %{status: :complete},
             effects: [acquisition, body_effect, cleanup]
           } =
             Executor.run(executor, target,
               request: request,
               context: context,
               body: {SandboxBody, %{"mode" => "success"}}
             )

    assert_receive {:sandbox_body_started, owner, body, "success"}, 5000
    refute Process.alive?(body)
    assert_receive {:sandbox_cleanup, ^owner}, 5000
    assert acquisition.kind == :sandbox_target_acquisition
    assert body_effect.kind == :sandbox_body_execution
    assert body_effect.status == :observed
    assert cleanup.kind == :sandbox_resource_cleanup
    assert Agent.get(state, & &1.resources) == %{}
  end

  test "body error is bounded and terminates before provider cleanup", %{
    executor: executor,
    state: state
  } do
    target = target!("success", 72)
    {request, context} = authority!(target, "body-error")

    assert %Result{
             status: :error,
             value: %{"body_receipt" => %{"outcome" => "failed"}},
             cleanup: %{status: :complete},
             effects: effects
           } =
             Executor.run(executor, target,
               request: request,
               context: context,
               body: {SandboxBody, %{"mode" => "error"}}
             )

    assert_receive {:sandbox_body_started, owner, body, "error"}, 5000
    refute Process.alive?(body)
    assert_receive {:sandbox_cleanup, ^owner}, 5000
    body_effect = Enum.at(effects, 1)
    assert body_effect.details.outcome == :error
    assert body_effect.details.reason == :body_failed
    assert "sha256:" <> digest = body_effect.details.receipt_digest
    assert byte_size(digest) == 64
    assert Agent.get(state, & &1.resources) == %{}
  end

  test "cancellation waits for the body terminal receipt before cleanup", %{
    executor: executor,
    state: state
  } do
    target = target!("success", 73)
    {request, context} = authority!(target, "body-cancel")

    assert {:ok, handle} =
             Executor.start_run(executor, target,
               request: request,
               context: context,
               body: {SandboxBody, %{"mode" => "block"}}
             )

    assert_receive {:sandbox_body_started, owner, body, "block"}, 5000
    assert :ok = Executor.cancel(handle)
    assert_receive {:sandbox_body_cancelled, ^owner, ^body}, 5000
    refute Process.alive?(body)
    assert_receive {:sandbox_cleanup, ^owner}, 5000

    assert %Result{
             status: :cancelled,
             value: %{"body_receipt" => %{"outcome" => "cancelled"}},
             cleanup: %{status: :complete},
             effects: [_acquisition, body_effect, _cleanup]
           } =
             Executor.await(handle, 2_000)

    assert body_effect.details.outcome == :cancelled
    assert "sha256:" <> digest = body_effect.details.receipt_digest
    assert byte_size(digest) == 64
    assert Agent.get(state, & &1.resources) == %{}
  end

  test "a backlogged runner does not receive a fresh relative body stop grace", %{
    executor: executor,
    state: state
  } do
    target = target!("success", 731)
    {request, context} = authority!(target, "body-backlogged-cancel", 900)

    assert {:ok, handle} =
             Executor.start_run(executor, target,
               request: request,
               context: context,
               body: {SandboxBody, %{"mode" => "ignore_cancel"}, 150}
             )

    assert_receive {:sandbox_body_started, owner, body, "ignore_cancel"}, 5000
    body_stop_deadline = :sys.get_state(handle.pid).body_stop_deadline
    :erlang.suspend_process(handle.pid)
    cancel = Task.async(fn -> Executor.cancel(handle, 1_000) end)
    wait_until_after(body_stop_deadline)
    :erlang.resume_process(handle.pid)

    assert {:error, %Error{code: :operation_failed}} = Task.await(cancel, 1_000)

    assert %Result{status: :error, cleanup: %{status: :uncertain}} =
             Executor.await(handle, 1_000)

    body_monitor = Process.monitor(body)
    Process.exit(body, :kill)
    assert_receive {:DOWN, ^body_monitor, :process, ^body, reason}, 5000
    assert reason in [:killed, :noproc]

    resources = Agent.get(state, &Map.fetch!(&1.resources, owner))
    Enum.each(resources, fn resource -> Process.exit(resource.pid, :kill) end)
  end

  test "early cancellation uses only the configured body stop grace", %{
    executor: executor,
    state: state
  } do
    target = target!("success", 733)
    {request, context} = authority!(target, "body-early-cancel")

    assert {:ok, handle} =
             Executor.start_run(executor, target,
               request: request,
               context: context,
               body: {SandboxBody, %{"mode" => "ignore_cancel"}, 150}
             )

    assert_receive {:sandbox_body_started, owner, body, "ignore_cancel"}, 5000
    assert 1 = :erlang.trace(handle.pid, true, [:receive])
    cancel = Task.async(fn -> Executor.cancel(handle, 1_000) end)

    assert_receive {:trace, runner_pid, :receive, {call, _from, {:cancel, token}}}
                   when runner_pid == handle.pid and call == :"$gen_call" and
                          token == handle.token,
                   5000

    assert 1 = :erlang.trace(handle.pid, false, [:receive])
    runner = :sys.get_state(handle.pid)

    assert runner.phase == :stopping
    assert runner.cleanup_timeout_ms == 500

    assert {:error, %Error{code: :operation_failed}} = Task.await(cancel, 1_000)

    body_monitor = Process.monitor(body)
    Process.exit(body, :kill)
    assert_receive {:DOWN, ^body_monitor, :process, ^body, reason}, 5000
    assert reason in [:killed, :noproc]

    resources = Agent.get(state, &Map.fetch!(&1.resources, owner))
    Enum.each(resources, fn resource -> Process.exit(resource.pid, :kill) end)
  end

  test "body stop grace is bounded before any provider effect", %{executor: executor} do
    target = target!("success", 732)
    {request, context} = authority!(target, "body-invalid-stop-grace")

    assert {:error, %Error{code: :sandbox_body_mismatch}} =
             Executor.start_run(executor, target,
               request: request,
               context: context,
               body: {SandboxBody, %{"mode" => "success"}, 5_001}
             )

    refute_received {:sandbox_allocation_intent, _owner, _pid, _mode, 732}
  end

  test "host cleanup budget is bounded and reserved independently from body stop", %{
    executor: executor
  } do
    for {cleanup_timeout_ms, sequence} <- [{500, 734}, {5_000, 735}] do
      target = target!("success", sequence)
      {request, context} = authority!(target, "cleanup-boundary-#{sequence}", 7_000)

      assert %Result{status: :ok, cleanup: %{status: :complete}} =
               Executor.run(executor, target,
                 request: request,
                 context: context,
                 cleanup_timeout_ms: cleanup_timeout_ms,
                 body: {SandboxBody, %{"mode" => "success"}}
               )
    end

    target = target!("success", 736)
    {request, context} = authority!(target, "cleanup-reserves", 5_000)

    assert {:ok, handle} =
             Executor.start_run(executor, target,
               request: request,
               context: context,
               cleanup_timeout_ms: 1_200,
               body: {SandboxBody, %{"mode" => "block"}, 150}
             )

    assert_receive {:sandbox_body_started, _owner, _body, "block"}, 5000
    runner = :sys.get_state(handle.pid)
    assert runner.cleanup_timeout_ms == 1_200
    assert runner.body_deadline == runner.deadline - 1_200 - 150
    assert runner.body_stop_deadline == runner.deadline - 1_200
    assert :ok = Executor.cancel(handle)

    assert %Result{status: :cancelled, cleanup: %{status: :complete}} =
             Executor.await(handle, 2_000)

    for {cleanup_timeout_ms, sequence} <- [{0, 737}, {5_001, 738}, {"500", 739}] do
      target = target!("success", sequence)
      {request, context} = authority!(target, "cleanup-invalid-#{sequence}", 7_000)

      assert {:error, %Error{code: :policy_denied}} =
               Executor.start_run(executor, target,
                 request: request,
                 context: context,
                 cleanup_timeout_ms: cleanup_timeout_ms
               )

      refute_received {:sandbox_allocation_intent, _owner, _pid, _mode, ^sequence}
    end
  end

  test "non-allowlisted and malformed bodies are rejected before acquisition", %{
    executor: executor
  } do
    target = target!("success", 74)
    {request, context} = authority!(target, "body-denied")

    assert {:error, %Error{code: :sandbox_body_mismatch}} =
             Executor.start_run(executor, target,
               request: request,
               context: context,
               body: {HostileCallback, %{}}
             )

    insufficient_events = %{request | budget: %{request.budget | max_events: 2}}

    assert {:error, %Error{code: :policy_denied}} =
             Executor.start_run(executor, target,
               request: insufficient_events,
               context: context,
               body: {SandboxBody, %{"mode" => "success"}}
             )

    refute_receive {:sandbox_acquired, _owner, _worker, _mode, 74}
  end

  test "unacknowledged body cancellation quarantines without racing provider cleanup", %{
    executor: executor,
    state: state
  } do
    target = target!("success", 75)
    {request, context} = authority!(target, "body-unconfirmed")

    assert {:ok, handle} =
             Executor.start_run(executor, target,
               request: request,
               context: context,
               body: {SandboxBody, %{"mode" => "ignore_cancel"}}
             )

    assert_receive {:sandbox_body_started, owner, body, "ignore_cancel"}, 5000

    assert {:error, %Error{code: :operation_failed}} = Executor.cancel(handle)

    assert %Result{
             status: :error,
             cleanup: %{status: :uncertain, release: :not_attempted},
             effects: [_acquisition, body_effect, _cleanup]
           } = Executor.await(handle, 2_000)

    assert body_effect.status == :unknown
    refute_receive {:sandbox_cleanup, ^owner}
    assert {:ok, %{active: 0, quarantined: 1}} = Executor.counts(executor)

    body_monitor = Process.monitor(body)
    Process.exit(body, :kill)
    assert_receive {:DOWN, ^body_monitor, :process, ^body, reason}, 5000
    assert reason in [:killed, :noproc]

    resources = Agent.get(state, &Map.fetch!(&1.resources, owner))
    Enum.each(resources, fn resource -> Process.exit(resource.pid, :kill) end)
  end

  test "abrupt runner death quarantines a surviving body before provider cleanup", %{
    executor: executor,
    state: state
  } do
    target = target!("success", 76)
    {request, context} = authority!(target, "body-runner-death")

    assert {:ok, handle} =
             Executor.start_run(executor, target,
               request: request,
               context: context,
               body: {SandboxBody, %{"mode" => "trap_exit"}}
             )

    assert_receive {:sandbox_body_started, owner, body, "trap_exit"}, 5000
    runner_monitor = Process.monitor(handle.pid)
    Process.exit(handle.pid, :kill)
    assert_receive {:DOWN, ^runner_monitor, :process, _runner, :killed}, 5000
    assert_receive {:sandbox_body_survived_exit, ^owner, ^body}, 5000
    assert Process.alive?(body)
    refute_receive {:sandbox_cleanup, ^owner}
    assert {:ok, %{active: 0, quarantined: 1}} = Executor.counts(executor)

    send(body, :stop)
    body_monitor = Process.monitor(body)
    assert_receive {:DOWN, ^body_monitor, :process, ^body, reason}, 5000
    assert reason in [:kill, :noproc]

    resources = Agent.get(state, &Map.fetch!(&1.resources, owner))
    Enum.each(resources, fn resource -> Process.exit(resource.pid, :kill) end)
  end

  test "executor shutdown stops an active body before provider cleanup", %{state: state} do
    {:ok, executor} =
      Executor.start_link(
        name: nil,
        providers: [SandboxProvider],
        bodies: [SandboxBody],
        max_concurrency: 2
      )

    Process.unlink(executor)

    for index <- [77, 78] do
      target = target!("success", index)
      {request, context} = authority!(target, "body-executor-shutdown-#{index}")

      assert {:ok, _handle} =
               Executor.start_run(executor, target,
                 request: request,
                 context: context,
                 body: {SandboxBody, %{"mode" => "trap_exit"}}
               )
    end

    bodies =
      for _index <- 1..2 do
        assert_receive {:sandbox_body_started, owner, body, "trap_exit"}, 5000
        {owner, body, Process.monitor(body)}
      end

    executor_monitor = Process.monitor(executor)
    Process.exit(executor, :shutdown)

    for {owner, body, body_monitor} <- bodies do
      assert_receive {:DOWN, ^body_monitor, :process, ^body, :killed}, 1_000
      assert_receive {:sandbox_cleanup, ^owner}, 1_000
    end

    assert_receive {:DOWN, ^executor_monitor, :process, ^executor, :shutdown}, 1_000
    assert Agent.get(state, & &1.resources) == %{}
  end

  test "queued observation after the absolute cutoff cannot start a body", %{
    executor: executor,
    state: state
  } do
    target = target!("observe_block", 79)
    {request, context} = authority!(target, "body-queued-deadline", 900)

    assert {:ok, handle} =
             Executor.start_run(executor, target,
               request: request,
               context: context,
               body: {SandboxBody, %{"mode" => "success"}}
             )

    assert_receive {:sandbox_observe_started, owner, observe_worker}, 5000
    cutoff = :sys.get_state(handle.pid).body_deadline
    :ok = :sys.suspend(handle.pid)
    send(observe_worker, :release_sandbox_acquire)
    wait_until_after(cutoff)
    :ok = :sys.resume(handle.pid)

    assert %Result{
             status: :timeout,
             cleanup: %{status: :complete},
             effects: [acquisition, cleanup]
           } = Executor.await(handle, 2_000)

    assert acquisition.kind == :sandbox_target_acquisition
    assert cleanup.kind == :sandbox_resource_cleanup
    refute_receive {:sandbox_body_started, ^owner, _body, _mode}
    assert Agent.get(state, & &1.resources) == %{}
  end

  test "expiration during body registration kills the gated body before cleanup", %{
    executor: executor,
    state: state
  } do
    target = target!("observe_block", 80)
    {request, context} = authority!(target, "body-registration-deadline", 900)

    {Registry, registry, :worker, _modules} =
      List.keyfind(Supervisor.which_children(executor), Registry, 0)

    assert {:ok, handle} =
             Executor.start_run(executor, target,
               request: request,
               context: context,
               body: {SandboxBody, %{"mode" => "success"}}
             )

    assert_receive {:sandbox_observe_started, owner, observe_worker}, 5000
    cutoff = :sys.get_state(handle.pid).body_deadline
    :ok = :sys.suspend(registry)
    send(observe_worker, :release_sandbox_acquire)
    assert_register_active_queued!(registry, owner)
    wait_until_after(cutoff)
    :ok = :sys.resume(registry)

    assert %Result{
             status: :timeout,
             cleanup: %{status: :complete},
             effects: [_acquisition, _cleanup]
           } = Executor.await(handle, 2_000)

    refute_receive {:sandbox_body_started, ^owner, _body, _mode}
    assert Agent.get(state, & &1.resources) == %{}
    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "target is canonical, content addressed, strict, and compatible" do
    target = target!("success")
    assert {:ok, bytes} = Target.canonical_binary(target)
    assert {:ok, ^target} = Target.decode(bytes)
    assert {:ok, ^target} = Target.decode_map(Jason.decode!(bytes))
    assert Target.target_fingerprint(target) == target.provenance["fingerprint"]

    wire = Target.to_wire_map(target)

    assert {:error, %Error{code: :sandbox_target_integrity_failed}} =
             Target.decode_map(put_in(wire, ["provider", "id"], "changed.provider"))

    assert {:error, %Error{code: :invalid_sandbox_target}} =
             Target.decode_map(put_in(wire, ["isolation"], "host"))

    assert {:error, %Error{code: :invalid_sandbox_target}} =
             Target.decode_map(Map.put(wire, "command", "mix test"))

    assert {:error, %Error{code: :unsupported_sandbox_target_schema}} =
             Target.decode_map(Map.put(wire, "schema", "insider.sandbox-target/v2"))

    assert {:error, %Error{code: :invalid_sandbox_target}} =
             bytes |> Jason.decode!() |> Jason.encode!(pretty: true) |> Target.decode()

    assert {:error, %Error{code: :sandbox_target_limit_exceeded}} =
             Target.decode(String.duplicate("x", 65_537))

    fixture = File.read!("test/fixtures/sandbox_target_v1.json")
    assert {:ok, frozen} = Target.decode(fixture)
    assert {:ok, ^fixture} = Target.canonical_binary(frozen)

    assert frozen.id ==
             "sha256:a0d16877972831e33e6cef0f3563c85cc5316e86aab8bb8f13dcc2c347ba72ba"
  end

  property "target map decoding never raises" do
    check all(value <- term()) do
      case Target.decode_map(value) do
        {:ok, %Target{}} -> :ok
        {:error, %Error{}} -> :ok
      end
    end
  end

  test "unknown target schemas never create atoms" do
    Target.decode_map(%{"schema" => "warm-up"})
    before_count = :erlang.system_info(:atom_count)

    for index <- 1..100 do
      assert {:error, %Error{code: :unsupported_sandbox_target_schema}} =
               Target.decode_map(%{"schema" => "hostile-sandbox-schema-#{index}"})
    end

    assert :erlang.system_info(:atom_count) == before_count
  end

  test "provider callbacks are crash-isolated, output-bounded, and deadline-bounded" do
    now = System.monotonic_time(:millisecond)

    assert %{result: {:error, :provider_failed}, termination: {:observed, _reason}} =
             ProviderCall.call(HostileCallback, :crash, [], now + 100)

    assert %{result: {:error, :invalid_output}, termination: {:observed, :normal}} =
             ProviderCall.call(HostileCallback, :oversized, [], now + 100)

    assert %{result: {:error, :provider_timeout}, termination: {:observed, :killed}} =
             ProviderCall.call(
               HostileCallback,
               :block,
               [],
               System.monotonic_time(:millisecond) + 10
             )

    assert %{result: {:error, :provider_deadline_expired}, termination: :not_started} =
             ProviderCall.call(HostileCallback, :crash, [], now - 1)

    cancel_reference = make_ref()

    cancelled =
      Task.async(fn ->
        ProviderCall.call(HostileCallback, :block, [], System.monotonic_time(:millisecond) + 500,
          cancel_reference: cancel_reference
        )
      end)

    send(cancelled.pid, {:cancel_provider_call, cancel_reference})

    assert %{result: {:error, :provider_cancelled}, termination: {:observed, :killed}} =
             Task.await(cancelled)
  end

  test "provider allowlist startup rejects a module without an exact identity" do
    caller = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      result = Registry.start_link(providers: [HostileCallback])
      send(caller, {:invalid_registry_result, result})
    end)

    assert_receive {:invalid_registry_result, {:error, :invalid_sandbox_providers}}, 5000
  end

  test "lease registry rejects unowned cleanup and non-allowlisted providers", %{
    executor: executor
  } do
    {Registry, registry, :worker, _modules} =
      List.keyfind(Supervisor.which_children(executor), Registry, 0)

    target = target!("success")
    deadline = System.monotonic_time(:millisecond) + 1_000

    assert :error = Registry.cleanup(registry, "unknown-owner", deadline, self(), make_ref())
    assert :error = Registry.cleanup_empty(registry, "unknown-owner")

    assert :error =
             Registry.register(
               registry,
               "forged-owner",
               self(),
               HostileCallback,
               target,
               deadline
             )

    send(registry, :unknown_message)
    send(registry, {:DOWN, make_ref(), :process, self(), :unrelated_monitor})
    assert %{active: 0, quarantined: 0} = Registry.counts(registry)
  end

  test "cleanup ownership rejects spoofed callers and survives its job", %{} do
    ownership =
      start_supervised!(%{
        id: :cleanup_ownership,
        start: {CleanupOwnership, :start_link, []},
        restart: :temporary
      })

    key = make_ref()
    provider = spawn(fn -> receive(do: (:stop -> :ok)) end)
    test = self()

    job =
      spawn(fn ->
        receive do
          :register ->
            send(
              test,
              {:ownership_registration, CleanupOwnership.register(ownership, key, provider, 100)}
            )

            receive do
              :finish -> :ok
            end
        end
      end)

    assert :ok = CleanupOwnership.authorize(ownership, key, job, 100)
    assert :error = CleanupOwnership.register(ownership, key, provider, 100)
    send(job, :register)
    assert_receive {:ownership_registration, :ok}, 5000
    assert CleanupOwnership.active(ownership, [key], 100) == {:ok, [provider]}

    job_monitor = Process.monitor(job)
    send(job, :finish)
    assert_receive {:DOWN, ^job_monitor, :process, ^job, :normal}, 5000
    assert CleanupOwnership.active(ownership, [key], 100) == {:ok, [provider]}

    provider_monitor = Process.monitor(provider)
    Process.exit(provider, :kill)
    assert_receive {:DOWN, ^provider_monitor, :process, ^provider, :killed}, 5000
  end

  test "closing cleanup ownership rejects a callback registered after the snapshot" do
    ownership =
      start_supervised!(%{
        id: :closed_cleanup_ownership,
        start: {CleanupOwnership, :start_link, []},
        restart: :temporary
      })

    key = make_ref()

    job =
      spawn(fn ->
        receive do
          :start ->
            ProviderCall.call(
              HostileCallback,
              :block,
              [],
              System.monotonic_time(:millisecond) + 1_000,
              ownership: {ownership, key}
            )
        end
      end)

    job_monitor = Process.monitor(job)
    assert 1 = :erlang.trace(job, true, [:procs])
    assert :ok = CleanupOwnership.authorize(ownership, key, job, 100)
    assert {:ok, []} = CleanupOwnership.close_active(ownership, [key], 100)

    capture_log(fn ->
      send(job, :start)
      assert_receive {:trace, ^job, :spawn, provider, _spawned_function}, 5000
      provider_monitor = Process.monitor(provider)

      assert_receive {:DOWN, ^job_monitor, :process, ^job, {{:badmatch, :error}, _stacktrace}},
                     5000

      assert_receive {:DOWN, ^provider_monitor, :process, ^provider, _reason}, 5000
      refute Process.alive?(provider)
    end)
  end

  test "normal registry shutdown terminates its private cleanup ownership broker" do
    registry =
      start_supervised!(%{
        id: :normal_stop_registry,
        start: {Registry, :start_link, [[providers: [SandboxProvider]]]},
        restart: :temporary
      })

    ownership = :sys.get_state(registry).cleanup_ownership
    registry_monitor = Process.monitor(registry)
    ownership_monitor = Process.monitor(ownership)

    assert :ok = GenServer.stop(registry, :normal, 1_000)
    assert_receive {:DOWN, ^registry_monitor, :process, ^registry, :normal}, 5000
    assert_receive {:DOWN, ^ownership_monitor, :process, ^ownership, :killed}, 5000
  end

  test "normal registry shutdown terminates a callback retained after its job exits" do
    registry =
      start_supervised!(%{
        id: :retained_callback_registry,
        start: {Registry, :start_link, [[providers: [SandboxProvider]]]},
        restart: :temporary
      })

    ownership = :sys.get_state(registry).cleanup_ownership
    key = make_ref()
    provider = spawn(fn -> receive(do: (:stop -> :ok)) end)
    test = self()

    job =
      spawn(fn ->
        receive do
          :register ->
            send(
              test,
              {:retained_registration, CleanupOwnership.register(ownership, key, provider, 100)}
            )
        end
      end)

    job_monitor = Process.monitor(job)
    provider_monitor = Process.monitor(provider)
    assert :ok = CleanupOwnership.authorize(ownership, key, job, 100)
    send(job, :register)
    assert_receive {:retained_registration, :ok}, 5000
    assert_receive {:DOWN, ^job_monitor, :process, ^job, :normal}, 5000
    assert CleanupOwnership.active(ownership, [key], 100) == {:ok, [provider]}

    assert :ok = GenServer.stop(registry, :normal, 1_000)
    assert_receive {:DOWN, ^provider_monitor, :process, ^provider, :killed}, 5000
  end

  test "cleanup ownership calls are bounded and its death stops the registry" do
    registry =
      start_supervised!(%{
        id: :ownership_failure_registry,
        start: {Registry, :start_link, [[providers: [SandboxProvider]]]},
        restart: :temporary
      })

    ownership = :sys.get_state(registry).cleanup_ownership
    assert true = :erlang.suspend_process(ownership)
    assert :error = CleanupOwnership.active(ownership, [], 10)
    assert true = :erlang.resume_process(ownership)

    registry_monitor = Process.monitor(registry)

    log =
      capture_log(fn ->
        Process.exit(ownership, :kill)
        assert_receive {:DOWN, ^registry_monitor, :process, ^registry, reason}, 5000

        assert reason in [
                 {:shutdown, {:cleanup_ownership_down, :killed}},
                 {:shutdown, {:cleanup_ownership_exit, :killed}}
               ]
      end)

    assert log == ""
  end

  test "ownership loss with a quarantined lease warns and recovers the executor", %{
    executor: executor
  } do
    {Registry, registry, :worker, _modules} =
      List.keyfind(Supervisor.which_children(executor), Registry, 0)

    target = target!("intent_trap_cleanup_block", 66)
    {request, context} = authority!(target, "ownership-loss-quarantined")
    {:ok, handle} = Executor.start_run(executor, target, request: request, context: context)

    assert_receive {:sandbox_allocation_intent, owner, provider_worker,
                    "intent_trap_cleanup_block", 66},
                   5000

    provider_worker_monitor = Process.monitor(provider_worker)
    Process.exit(handle.pid, :kill)
    assert_receive {:DOWN, ^provider_worker_monitor, :process, ^provider_worker, _reason}, 5000
    assert_receive {:sandbox_cleanup_started, ^owner, cleanup_provider}, 5000

    on_exit(fn ->
      if Process.alive?(cleanup_provider), do: Process.exit(cleanup_provider, :kill)
    end)

    cleanup_job = :sys.get_state(registry).leases[owner].cleanup_job.pid
    cleanup_job_monitor = Process.monitor(cleanup_job)
    cleanup_provider_monitor = Process.monitor(cleanup_provider)
    assert 1 = :erlang.trace(registry, true, [:receive])
    Process.exit(cleanup_job, :kill)
    assert_receive {:DOWN, ^cleanup_job_monitor, :process, ^cleanup_job, :killed}, 5000

    assert_receive {:trace, ^registry, :receive,
                    {:DOWN, _monitor, :process, ^cleanup_job, :killed}},
                   5000

    assert %{active: 0, quarantined: 1} = Registry.counts(registry)
    assert Process.alive?(cleanup_provider)

    ownership = :sys.get_state(registry).cleanup_ownership
    registry_monitor = Process.monitor(registry)
    assert 1 = :erlang.trace(executor, true, [:receive])

    log =
      capture_log(fn ->
        Process.exit(ownership, :kill)
        assert_receive {:DOWN, ^registry_monitor, :process, ^registry, reason}, 5000

        assert reason in [
                 {:shutdown, {:cleanup_ownership_down, :killed}},
                 {:shutdown, {:cleanup_ownership_exit, :killed}}
               ]

        assert_receive {:trace, ^executor, :receive, {:EXIT, ^registry, ^reason}}, 5000
      end)

    assert log =~ "sandbox cleanup ownership lost; provider termination is unconfirmed"
    refute_receive {:sandbox_cleanup, ^owner}

    {Registry, replacement, :worker, _modules} =
      List.keyfind(Supervisor.which_children(executor), Registry, 0)

    refute replacement == registry
    assert Process.alive?(replacement)
    assert Process.alive?(cleanup_provider)

    Process.exit(cleanup_provider, :kill)
    assert_receive {:DOWN, ^cleanup_provider_monitor, :process, ^cleanup_provider, :killed}, 5000
  end

  test "orderly registry shutdown reclaims a lease without waiting for runner DOWN", %{
    state: state
  } do
    registry =
      start_supervised!(%{
        id: :orderly_shutdown_registry,
        start: {Registry, :start_link, [[providers: [SandboxProvider]]]},
        restart: :temporary
      })

    owner = :crypto.strong_rand_bytes(32)
    target = target!("block", 62)
    resource = spawn(fn -> receive(do: (:stop -> :ok)) end)
    resource_monitor = Process.monitor(resource)

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary({owner, 1}))
      |> Base.encode16(case: :lower)

    Agent.update(state, fn provider_state ->
      provider_state
      |> put_in([:resources, owner], [
        %{id_fingerprint: "sha256:" <> digest, pid: resource}
      ])
      |> put_in([:targets, owner], target.provenance)
    end)

    deadline = System.monotonic_time(:millisecond) + 1_000
    assert :ok = Registry.register(registry, owner, self(), SandboxProvider, target, deadline)
    assert :ok = GenServer.stop(registry, :shutdown)

    assert_receive {:sandbox_cleanup, ^owner}, 5000
    assert_receive {:DOWN, ^resource_monitor, :process, ^resource, :killed}, 5000
    assert Agent.get(state, & &1.resources) == %{}
  end

  test "registry shutdown fans out lease cleanup within one shared deadline", %{state: state} do
    registry =
      start_supervised!(%{
        id: :bounded_shutdown_registry,
        start: {Registry, :start_link, [[providers: [SandboxProvider]]]},
        restart: :temporary
      })

    target = target!("shutdown_cleanup_block", 63)
    owners = for index <- 1..3, do: :crypto.hash(:sha256, "shutdown-owner-#{index}")

    Agent.update(state, fn provider_state ->
      Enum.reduce(owners, provider_state, fn owner, accumulated ->
        accumulated
        |> put_in([:resources, owner], [])
        |> put_in([:targets, owner], target.provenance)
      end)
    end)

    deadline = System.monotonic_time(:millisecond) + 2_000

    for owner <- owners do
      assert :ok = Registry.register(registry, owner, self(), SandboxProvider, target, deadline)
    end

    shutdown = Task.async(fn -> GenServer.stop(registry, :shutdown, 2_000) end)

    started_owners =
      for _index <- owners, into: MapSet.new() do
        assert_receive {:sandbox_cleanup_started, owner, _cleanup_worker}, 5000
        owner
      end

    assert started_owners == MapSet.new(owners)
    assert :ok = Task.await(shutdown, 1_000)
    refute_receive {:sandbox_cleanup, _owner}
  end

  test "runner termination quarantines work when its DOWN cannot be confirmed", %{state: state} do
    registry =
      start_supervised!(%{
        id: :unconfirmed_termination_registry,
        start: {Registry, :start_link, [[providers: [SandboxProvider]]]},
        restart: :temporary
      })

    owner = :crypto.strong_rand_bytes(32)
    target = target!("block", 64)
    worker = spawn(fn -> receive(do: (:stop -> :ok)) end)
    worker_monitor = Process.monitor(worker)
    deadline = System.monotonic_time(:millisecond) + 1_000

    Agent.update(state, &put_in(&1, [:targets, owner], target.provenance))
    assert :ok = Registry.register(registry, owner, self(), SandboxProvider, target, deadline)

    assert :ok =
             Runner.terminate(:shutdown, %{
               active: %{monitor: make_ref(), pid: worker},
               owner_id: owner,
               registry: registry
             })

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 5000
    assert %{active: 0, quarantined: 1} = Registry.counts(registry)
    refute_receive {:sandbox_cleanup, ^owner}
  end

  test "hostile target and handle inputs return typed errors", %{executor: executor} do
    target = target!("success")
    {request, context} = authority!(target)
    provider = %{"id" => "test.sandbox", "version" => 1}

    assert {:error, %Error{code: :invalid_sandbox_target}} = Target.new(%{}, target.provenance)

    assert {:error, %Error{code: :invalid_sandbox_target}} =
             Target.new(%{"id" => :not_text, "version" => 1}, target.provenance)

    assert {:error, %Error{code: :invalid_sandbox_target}} = Target.new(provider, :hostile)
    assert {:error, %Error{code: :unsupported_provenance_schema}} = Target.new(provider, %{})

    {:ok, incomplete_provenance} =
      Provenance.new(
        code: {:unavailable, :not_built},
        configuration: {:available, %{}},
        dependencies: {:available, %{}},
        runtime: {:available, %{}},
        target: {:available, %{}}
      )

    assert {:error, %Error{code: :invalid_sandbox_target}} =
             Target.new(provider, incomplete_provenance)

    assert {:error, %Error{code: :invalid_sandbox_target}} = Target.validate(:hostile)
    assert {:error, %Error{code: :invalid_sandbox_target}} = Target.canonical_binary(:hostile)
    assert {:error, %Error{code: :invalid_sandbox_target}} = Target.decode("not-json")
    assert {:error, %Error{code: :invalid_sandbox_target}} = Target.decode(:hostile)

    malformed = %{target | integrity: %{"algorithm" => "sha256", "content_digest" => "bad"}}
    assert {:error, %Error{code: :invalid_sandbox_target}} = Target.validate(malformed)

    missing_integrity = %{target | integrity: %{}}
    assert {:error, %Error{code: :invalid_sandbox_target}} = Target.validate(missing_integrity)

    assert {:error, %Error{code: :invalid_sandbox_target}} =
             Target.canonical_binary(missing_integrity)

    assert {:error, %Error{code: :policy_denied}} =
             Executor.start_run(executor, target, request: request)

    assert {:error, %Error{code: :invalid_request}} = Executor.await(%{}, -1)
    assert {:error, %Error{code: :invalid_request}} = Executor.cancel(%{}, 0)

    fake_handle = %{pid: self(), token: make_ref()}
    assert {:error, %Error{code: :deadline_exceeded}} = Executor.await(fake_handle, 0)

    dead_runner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    dead_monitor = Process.monitor(dead_runner)
    send(dead_runner, :stop)
    assert_receive {:DOWN, ^dead_monitor, :process, ^dead_runner, :normal}, 5000

    assert {:error, %Error{code: :operation_failed}} =
             Executor.await(%{fake_handle | pid: dead_runner}, 100)

    assert {:error, %Error{code: :operation_failed}} =
             Executor.cancel(%{fake_handle | pid: dead_runner})

    assert {:error, %Error{code: :operation_failed}} = Executor.counts(self())
    assert {:error, %Error{code: :invalid_sandbox_target}} = Executor.run(executor, :bad, [])

    insufficient = %{request | budget: %{request.budget | max_bytes: 65_535}}

    assert {:error, %Error{code: :policy_denied}} =
             Executor.start_run(executor, target, request: insufficient, context: context)

    assert {:error, %Error{code: :policy_denied}} =
             Executor.start_run(executor, target, request: request, context: context, extra: true)
  end

  test "executor rejects invalid fixed-capacity configuration" do
    caller = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      send(caller, {:invalid_executor_result, Executor.start_link(name: nil, max_concurrency: 0)})
    end)

    assert_receive {:invalid_executor_result, {:error, {%ArgumentError{}, _stacktrace}}}, 5000
  end

  test "public sandbox facade delegates run and synchronous cancellation", %{executor: executor} do
    target = target!("success", 20)
    {request, context} = authority!(target, "facade-run")

    assert %Result{status: :ok} =
             Sandbox.run(executor, target, request: request, context: context)

    blocked = target!("block", 21)
    {blocked_request, blocked_context} = authority!(blocked, "facade-cancel")

    assert {:ok, handle} =
             Sandbox.start_run(executor, blocked,
               request: blocked_request,
               context: blocked_context
             )

    assert_receive {:sandbox_acquired, _owner, _worker, "block", 21}, 5000
    assert :ok = Sandbox.cancel(handle)
    assert %Result{status: :cancelled} = Sandbox.await(handle, 2_000)

    second = target!("block", 22)
    {second_request, second_context} = authority!(second, "facade-cancel-timeout")

    assert {:ok, second_handle} =
             Sandbox.start_run(executor, second,
               request: second_request,
               context: second_context
             )

    assert_receive {:sandbox_acquired, _owner, _worker, "block", 22}, 5000
    assert :ok = Sandbox.cancel(second_handle, 1_000)
    assert %Result{status: :cancelled} = Sandbox.await(second_handle, 2_000)
  end

  test "success records independently observed exact provenance and empty inventory", %{
    executor: executor,
    state: state
  } do
    target = target!("success")
    {request, context} = authority!(target)

    assert %Result{
             status: :ok,
             target_fingerprint: fingerprint,
             cleanup: %{status: :complete, remaining_count: 0},
             value: %{"schema" => "insider.sandbox-run/v1"},
             effects: [acquisition, cleanup]
           } = Executor.run(executor, target, request: request, context: context)

    assert fingerprint == target.provenance["fingerprint"]
    assert acquisition.kind == :sandbox_target_acquisition
    assert acquisition.status == :observed
    assert cleanup.kind == :sandbox_resource_cleanup
    assert cleanup.status == :observed
    assert Agent.get(state, & &1.resources) == %{}
    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "concurrent successful leases remain isolated and all clean", %{
    executor: executor,
    state: state
  } do
    runs =
      for index <- 1..4 do
        target = target!("barrier", index)
        {request, context} = authority!(target, "concurrent-#{index}")
        {:ok, handle} = Executor.start_run(executor, target, request: request, context: context)
        {handle, target}
      end

    workers =
      for _index <- 1..4 do
        assert_receive {:sandbox_acquired, owner, worker, "barrier", _unique}, 5000
        {owner, worker}
      end

    assert workers |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 4
    Enum.each(workers, fn {_owner, worker} -> send(worker, :release_sandbox_acquire) end)

    for {handle, target} <- runs do
      assert %Result{status: :ok, target_fingerprint: fingerprint, cleanup: %{status: :complete}} =
               Executor.await(handle, 2_000)

      assert fingerprint == target.provenance["fingerprint"]
    end

    assert Agent.get(state, & &1.resources) == %{}
    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "provider crash after allocation is cleaned by owner", %{executor: executor, state: state} do
    target = target!("crash")
    {request, context} = authority!(target)

    assert %Result{status: :error, cleanup: %{status: :complete}} =
             Executor.run(executor, target, request: request, context: context)

    assert Agent.get(state, & &1.resources) == %{}
    assert_receive {:sandbox_cleanup, _owner}, 5000
  end

  test "timeout and acknowledged cancellation kill acquisition before cleanup", %{
    executor: executor,
    state: state
  } do
    timeout_target = target!("block", 1)
    {timeout_request, timeout_context} = authority!(timeout_target, "timeout", 700)

    {:ok, timeout_handle} =
      Executor.start_run(executor, timeout_target,
        request: timeout_request,
        context: timeout_context
      )

    assert_receive {:sandbox_acquired, _owner, _worker, "block", 1}, 5000

    assert %Result{status: :timeout, cleanup: %{status: :complete}} =
             Executor.await(timeout_handle, 2_000)

    cancel_target = target!("block", 2)
    {cancel_request, cancel_context} = authority!(cancel_target, "cancel", 2_000)

    {:ok, cancel_handle} =
      Executor.start_run(executor, cancel_target,
        request: cancel_request,
        context: cancel_context
      )

    assert_receive {:sandbox_acquired, _owner, _worker, "block", 2}, 5000
    assert :ok = Executor.cancel(cancel_handle)

    assert %Result{status: :cancelled, cleanup: %{status: :complete}, uncertainty: uncertainty} =
             Executor.await(cancel_handle, 2_000)

    assert Enum.any?(uncertainty, &String.contains?(&1, "not rollback"))
    assert Agent.get(state, & &1.resources) == %{}
  end

  test "fingerprint mismatch fails and cleans without claiming the requested target", %{
    executor: executor,
    state: state
  } do
    target = target!("mismatch")
    {request, context} = authority!(target)

    assert %Result{
             status: :error,
             target_fingerprint: observed,
             cleanup: %{status: :complete},
             code_fingerprint: observed_code,
             dependency_fingerprint: observed_dependencies,
             runtime_fingerprint: observed_runtime,
             effects: [acquisition, _cleanup]
           } =
             Executor.run(executor, target, request: request, context: context)

    expected = mismatch_provenance!()
    details = acquisition.details

    assert observed == expected["fingerprint"]
    refute observed == target.provenance["fingerprint"]
    assert details.observed_target_fingerprint == observed
    assert details.requested_target_fingerprint == target.provenance["fingerprint"]
    assert details.observed_code_fingerprint == observed_code
    assert details.observed_dependency_fingerprint == observed_dependencies
    assert details.observed_runtime_fingerprint == observed_runtime

    for {detail, component} <- [
          observed_code_fingerprint: "code",
          observed_configuration_fingerprint: "configuration",
          observed_dependency_fingerprint: "dependencies",
          observed_runtime_fingerprint: "runtime",
          observed_target_component_fingerprint: "target"
        ] do
      assert Map.fetch!(details, detail) ==
               get_in(expected, ["components", component, "fingerprint"])
    end

    assert Agent.get(state, & &1.resources) == %{}
  end

  test "provider acquisition and observation failures remain typed and clean", %{
    executor: executor,
    state: state
  } do
    for {mode, request_id} <- [
          {"acquire_error", "acquire-error"},
          {"observe_error", "observe-error"},
          {"invalid_observation", "invalid-observation"}
        ] do
      target = target!(mode)
      {request, context} = authority!(target, request_id)

      assert %Result{
               status: :error,
               target_fingerprint: nil,
               cleanup: %{status: :complete}
             } = Executor.run(executor, target, request: request, context: context)
    end

    assert Agent.get(state, & &1.resources) == %{}
    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "unexpected runner death is reaped by the executor lease registry", %{
    executor: executor,
    state: state
  } do
    target = target!("block")
    {request, context} = authority!(target, "runner-crash", 2_000)
    {:ok, handle} = Executor.start_run(executor, target, request: request, context: context)
    assert_receive {:sandbox_acquired, _owner, provider_worker, "block", 0}, 5000
    worker_monitor = Process.monitor(provider_worker)

    Process.exit(handle.pid, :kill)

    assert_receive {:DOWN, ^worker_monitor, :process, ^provider_worker, _reason}, 5000
    assert_receive {:sandbox_cleanup, _owner}, 5000
    assert Agent.get(state, & &1.resources) == %{}
  end

  test "unverifiable inventory is quarantined with uncertain cleanup", %{
    executor: executor,
    state: state
  } do
    target = target!("inventory_error")
    {request, context} = authority!(target)

    assert %Result{status: :error, cleanup: %{status: :uncertain}} =
             Executor.run(executor, target, request: request, context: context)

    assert Agent.get(state, & &1.resources) == %{}
    assert {:ok, %{active: 0, quarantined: 1}} = Executor.counts(executor)
  end

  test "raw provider inventory values are rejected and quarantined", %{
    executor: executor,
    state: state
  } do
    target = target!("invalid_inventory")
    {request, context} = authority!(target, "invalid-inventory")

    assert %Result{
             status: :error,
             cleanup: %{status: :uncertain, remaining_fingerprint: nil}
           } = Executor.run(executor, target, request: request, context: context)

    assert Agent.get(state, & &1.resources) == %{}
    assert {:ok, %{active: 0, quarantined: 1}} = Executor.counts(executor)
  end

  test "provider inventory above the fixed resource limit is quarantined", %{
    executor: executor,
    state: state
  } do
    target = target!("too_many_inventory")
    {request, context} = authority!(target, "too-many-inventory")

    assert %Result{
             status: :error,
             cleanup: %{status: :uncertain, remaining_fingerprint: nil}
           } = Executor.run(executor, target, request: request, context: context)

    assert Agent.get(state, & &1.resources) == %{}
    assert {:ok, %{active: 0, quarantined: 1}} = Executor.counts(executor)
  end

  test "malformed resource fingerprints cannot become cleanup proof", %{
    executor: executor,
    state: state
  } do
    target = target!("bad_digest_inventory")
    {request, context} = authority!(target, "bad-digest-inventory")

    assert %Result{status: :error, cleanup: %{status: :uncertain}} =
             Executor.run(executor, target, request: request, context: context)

    assert Agent.get(state, & &1.resources) == %{}
    assert {:ok, %{active: 0, quarantined: 1}} = Executor.counts(executor)
  end

  test "fixed capacity rejects overload without dispatching another provider", %{state: state} do
    executor =
      start_supervised!(
        {Executor, name: nil, providers: [SandboxProvider], max_concurrency: 1},
        id: :single_sandbox_executor
      )

    target = target!("block", 10)
    {request, context} = authority!(target, "capacity-a", 2_000)
    {:ok, handle} = Executor.start_run(executor, target, request: request, context: context)
    assert_receive {:sandbox_acquired, _owner, _worker, "block", 10}, 5000

    second = target!("success", 11)
    {second_request, second_context} = authority!(second, "capacity-b", 2_000)

    assert {:error, %Error{code: :operation_failed, retryable: true}} =
             Executor.start_run(executor, second,
               request: second_request,
               context: second_context
             )

    refute_received {:sandbox_acquired, _, _, "success", 11}
    assert :ok = Executor.cancel(handle)

    assert %Result{status: :cancelled, cleanup: %{status: :complete}} =
             Executor.await(handle, 2_000)

    assert Agent.get(state, & &1.resources) == %{}
  end

  test "policy and provider allowlist failures occur before provider effects", %{
    executor: executor
  } do
    target = target!("success")
    {request, context} = authority!(target)

    assert {:error, %Error{code: :policy_denied}} =
             Executor.start_run(executor, target,
               request: request,
               context: %{context | target_class: :host}
             )

    other = %{target | provider: %{"id" => "other", "version" => 1}}
    other = resign(other)

    assert {:error, %Error{code: :sandbox_provider_mismatch}} =
             Executor.start_run(executor, other,
               request: %{request | params: %{"sandbox_target_id" => other.id}},
               context: context
             )

    refute_received {:sandbox_acquired, _, _, _, _}
  end

  test "empty inventory is proof even when cleanup reports failure", %{
    executor: executor,
    state: state
  } do
    target = target!("cleanup_error")
    {request, context} = authority!(target)

    assert %Result{status: :ok, cleanup: %{status: :complete}, warnings: [warning]} =
             Executor.run(executor, target, request: request, context: context)

    assert warning =~ "inventory was empty"
    assert Agent.get(state, & &1.resources) == %{}
  end

  test "cancellation during cleanup acknowledges the accepted cleanup and keeps proof honest", %{
    executor: executor,
    state: state
  } do
    target = target!("cleanup_block")
    {request, context} = authority!(target, "cancel-during-cleanup", 1_200)
    {:ok, handle} = Executor.start_run(executor, target, request: request, context: context)

    assert_receive {:sandbox_cleanup_started, owner, cleanup_worker}, 5000
    cleanup_monitor = Process.monitor(cleanup_worker)

    assert {:error, %Error{code: :invalid_request}} =
             Executor.cancel(%{handle | token: make_ref()})

    assert :ok = Executor.cancel(handle)
    assert_receive {:DOWN, ^cleanup_monitor, :process, ^cleanup_worker, :killed}, 1_000

    assert %Result{status: :error, cleanup: %{status: :partial, remaining_count: 1}} =
             Executor.await(handle, 2_000)

    [%{pid: resource}] = Agent.get(state, &Map.fetch!(&1.resources, owner))
    Process.exit(resource, :kill)
  end

  test "confirmed leftovers are partial and quarantined rather than forgotten", %{
    executor: executor,
    state: state
  } do
    target = target!("leftover")
    {request, context} = authority!(target)

    assert %Result{
             status: :error,
             cleanup: %{status: :partial, remaining_count: 1},
             uncertainty: [_ | _]
           } = Executor.run(executor, target, request: request, context: context)

    assert map_size(Agent.get(state, & &1.resources)) == 1
    assert {:ok, %{active: 0, quarantined: 1}} = Executor.counts(executor)
  end

  test "maximum inventory is represented by a bounded aggregate, never raw resources", %{
    executor: executor,
    state: state
  } do
    target = target!("max_leftover")
    {request, context} = authority!(target, "maximum-inventory")

    assert %Result{
             status: :error,
             cleanup: %{
               status: :partial,
               remaining_count: 64,
               remaining_fingerprint: "sha256:" <> _digest
             },
             effects: [_acquisition, cleanup_effect]
           } = result = Executor.run(executor, target, request: request, context: context)

    assert Effect.valid?(cleanup_effect)
    assert cleanup_effect.details.remaining_count == 64
    assert cleanup_effect.details.remaining_fingerprint == result.cleanup.remaining_fingerprint
    refute Map.has_key?(cleanup_effect.details, :remaining)

    resources = Agent.get(state, &(&1.resources |> Map.values() |> List.flatten()))
    assert Enum.count_until(resources, 65) == 64
    Enum.each(resources, &Process.exit(&1.pid, :kill))
  end

  test "expired dispatch is rechecked at the acquire boundary without a provider effect", %{
    executor: executor,
    state: state
  } do
    target = target!("success", 30)
    {request, context} = authority!(target, "expired-at-acquire")
    {:ok, decision} = Policy.authorize(request, context)

    {Registry, registry, :worker, _modules} =
      List.keyfind(Supervisor.which_children(executor), Registry, 0)

    token = make_ref()

    {:ok, _runner} =
      Runner.start_link(%{
        caller: self(),
        cleanup_timeout_ms: 500,
        context: context,
        decision: %{decision | dispatch_deadline_monotonic: System.monotonic_time(:millisecond)},
        provider: SandboxProvider,
        registry: registry,
        request: request,
        target: target,
        token: token
      })

    assert_receive {^token,
                    %Result{
                      status: :timeout,
                      cleanup: %{status: :complete, release: :not_required}
                    }},
                   5000

    refute_receive {:sandbox_allocation_intent, _, _, _, _}
    assert Agent.get(state, & &1.resources) == %{}
    assert %{active: 0, quarantined: 0} = Registry.counts(registry)
  end

  test "allocation intent makes abrupt death before spawn independently clean", %{
    executor: executor,
    state: state
  } do
    {Registry, registry, :worker, _modules} =
      List.keyfind(Supervisor.which_children(executor), Registry, 0)

    target = target!("intent_block", 31)
    {request, context} = authority!(target, "intent-crash")
    {:ok, handle} = Executor.start_run(executor, target, request: request, context: context)

    assert_receive {:sandbox_allocation_intent, owner, provider_worker, "intent_block", 31}, 5000
    worker_monitor = Process.monitor(provider_worker)
    Process.exit(handle.pid, :kill)
    assert_receive {:sandbox_cleanup_started, ^owner, cleanup_worker}, 5000

    cleanup_reference = make_ref()

    assert :ok =
             Registry.cleanup(
               registry,
               owner,
               System.monotonic_time(:millisecond) + 1_000,
               self(),
               cleanup_reference
             )

    send(cleanup_worker, :release_sandbox_acquire)
    assert_receive {:DOWN, ^worker_monitor, :process, ^provider_worker, _reason}, 5000
    assert_receive {:sandbox_cleanup, ^cleanup_reference, %{status: :complete}}, 5000
    assert Agent.get(state, & &1.resources) == %{}
    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "unacknowledged worker ownership transfer remains quarantined across later DOWN signals",
       %{
         executor: executor
       } do
    {Registry, registry, :worker, _modules} =
      List.keyfind(Supervisor.which_children(executor), Registry, 0)

    runner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    worker =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    owner = :crypto.strong_rand_bytes(32)
    target = target!("success", 32)
    deadline = System.monotonic_time(:millisecond) + 1_000

    assert :ok = Registry.register(registry, owner, runner, SandboxProvider, target, deadline)

    assert {:ok,
            %{
              status: :uncertain,
              release: :not_attempted,
              remaining_fingerprint: nil
            }} = Registry.quarantine_active(registry, owner, worker)

    assert %{active: 0, quarantined: 1} = Registry.counts(registry)
    assert :error = Registry.cleanup(registry, owner, deadline, self(), make_ref())
    assert :error = Registry.cleanup_empty(registry, owner)
    assert :error = Registry.quarantine_active(registry, owner, worker)

    lease = :sys.get_state(registry).leases[owner]
    send(registry, {:DOWN, lease.monitor, :process, runner, :killed})
    send(registry, {:DOWN, lease.active_worker.monitor, :process, worker, :killed})

    updated = :sys.get_state(registry).leases[owner]
    assert updated.status == :quarantined
    assert updated.runner == nil
    assert updated.active_worker == nil
    assert %{active: 0, quarantined: 1} = Registry.counts(registry)

    Process.exit(runner, :kill)
    Process.exit(worker, :kill)
  end

  test "stop-ack timeout fails cancellation and returns an error result with quarantine", %{
    executor: executor,
    state: provider_state
  } do
    target = target!("block", 33)
    {request, context} = authority!(target, "stop-ack-timeout")
    {:ok, handle} = Executor.start_run(executor, target, request: request, context: context)

    assert_receive {:sandbox_acquired, owner, provider_worker, "block", 33}, 5000
    runner_state = :sys.get_state(handle.pid)
    :ok = :sys.suspend(handle.pid)

    worker_monitor = Process.monitor(provider_worker)
    callback_monitor = Process.monitor(provider_worker)
    stop_reference = make_ref()
    reply_tag = make_ref()

    transition_state = %{
      runner_state
      | active: %{runner_state.active | monitor: callback_monitor},
        cancel_waiters: [{self(), reply_tag}],
        phase: :stopping,
        stop_ack_reference: stop_reference,
        stop_ack_timer: nil,
        terminal: :cancelled
    }

    assert {:stop, :normal, _finished_state} =
             Runner.handle_info({:stop_ack_deadline, stop_reference}, transition_state)

    assert_receive {^reply_tag,
                    {:error,
                     %Error{
                       code: :operation_failed,
                       message: "sandbox worker termination was not confirmed",
                       retryable: false
                     }}},
                   5000

    assert_receive {token,
                    %Result{
                      status: :error,
                      error: %Error{
                        message: "sandbox worker termination was not confirmed"
                      },
                      cleanup: %{status: :uncertain, release: :not_attempted}
                    }},
                   5000

    assert token == handle.token
    assert {:ok, %{active: 0, quarantined: 1}} = Executor.counts(executor)

    Process.exit(handle.pid, :kill)
    assert_receive {:DOWN, ^worker_monitor, :process, ^provider_worker, _reason}, 5000

    resources =
      Agent.get_and_update(provider_state, fn provider ->
        entries = Map.get(provider.resources, owner, [])

        updated = %{
          provider
          | resources: Map.delete(provider.resources, owner),
            targets: Map.delete(provider.targets, owner)
        }

        {entries, updated}
      end)

    Enum.each(resources, fn %{pid: pid} -> Process.exit(pid, :kill) end)
    assert {:ok, %{active: 0, quarantined: 1}} = Executor.counts(executor)
  end

  test "mixed concurrent outcomes terminate workers before cancellation acknowledgement", %{
    executor: executor,
    state: state
  } do
    specifications = [
      {:success, "success", 40, 2_000},
      {:timeout, "block", 41, 700},
      {:crash, "crash", 42, 2_000},
      {:cancel, "cancel_block", 43, 2_000}
    ]

    runs =
      Map.new(specifications, fn {name, mode, unique, duration} ->
        target = target!(mode, unique)
        {request, context} = authority!(target, "mixed-#{name}", duration)
        {:ok, handle} = Executor.start_run(executor, target, request: request, context: context)
        {name, %{handle: handle, target: target}}
      end)

    assert_receive {:sandbox_acquired, _timeout_owner, _timeout_worker, "block", 41}, 5000
    assert_receive {:sandbox_acquired, _cancel_owner, cancel_worker, "cancel_block", 43}, 5000

    cancel_monitor = Process.monitor(cancel_worker)
    cancellation = Task.async(fn -> Executor.cancel(runs.cancel.handle) end)
    assert_receive {:DOWN, ^cancel_monitor, :process, ^cancel_worker, _reason}, 5000
    assert :ok = Task.await(cancellation)

    assert %Result{
             status: :ok,
             cleanup: %{status: :complete},
             target_fingerprint: success_fingerprint
           } = Executor.await(runs.success.handle, 2_000)

    assert success_fingerprint == runs.success.target.provenance["fingerprint"]

    assert %Result{status: :timeout, cleanup: %{status: :complete}, target_fingerprint: nil} =
             Executor.await(runs.timeout.handle, 2_000)

    assert %Result{status: :error, cleanup: %{status: :complete}, target_fingerprint: nil} =
             Executor.await(runs.crash.handle, 2_000)

    assert %Result{status: :cancelled, cleanup: %{status: :complete}, target_fingerprint: nil} =
             Executor.await(runs.cancel.handle, 2_000)

    assert Agent.get(state, & &1.resources) == %{}
    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "caller death cancels active work and reclaims its owner", %{
    executor: executor,
    state: state
  } do
    target = target!("block", 50)
    {request, context} = authority!(target, "caller-death")
    parent = self()

    caller =
      spawn(fn ->
        {:ok, handle} = Executor.start_run(executor, target, request: request, context: context)
        send(parent, {:caller_handle, handle})

        receive do
          :remain_alive -> :ok
        end
      end)

    assert_receive {:caller_handle, handle}, 5000
    assert_receive {:sandbox_acquired, owner, provider_worker, "block", 50}, 5000
    runner_monitor = Process.monitor(handle.pid)
    worker_monitor = Process.monitor(provider_worker)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^worker_monitor, :process, ^provider_worker, _reason}, 5000
    assert_receive {:sandbox_cleanup, ^owner}, 5000
    assert_receive {:DOWN, ^runner_monitor, :process, _pid, :normal}, 5000
    assert Agent.get(state, & &1.resources) == %{}
    assert {:ok, %{active: 0, quarantined: 0}} = Executor.counts(executor)
  end

  test "executor shutdown terminates active runner and provider through cleanup", %{state: state} do
    executor =
      start_supervised!(
        {Executor, name: nil, providers: [SandboxProvider], max_concurrency: 1},
        id: :shutdown_sandbox_executor
      )

    target = target!("shutdown_cleanup_block", 60)
    {request, context} = authority!(target, "executor-shutdown")
    {:ok, handle} = Executor.start_run(executor, target, request: request, context: context)

    assert_receive {:sandbox_acquired, owner, provider_worker, "shutdown_cleanup_block", 60}, 5000
    runner_monitor = Process.monitor(handle.pid)
    worker_monitor = Process.monitor(provider_worker)

    shutdown = Task.async(fn -> Supervisor.stop(executor, :shutdown, 2_000) end)
    assert_receive {:DOWN, ^worker_monitor, :process, ^provider_worker, _reason}, 5000
    assert_receive {:sandbox_cleanup_started, ^owner, cleanup_worker}, 5000
    assert Task.yield(shutdown, 0) == nil

    send(cleanup_worker, :release_sandbox_acquire)

    assert :ok = Task.await(shutdown)
    assert_receive {:sandbox_cleanup, ^owner}, 5000
    assert_receive {:DOWN, ^runner_monitor, :process, _pid, reason}, 5000
    assert reason in [:normal, :shutdown]
    assert Agent.get(state, & &1.resources) == %{}
  end

  test "executor shutdown waits for cleanup already in progress", %{
    executor: executor,
    state: state
  } do
    target = target!("cleanup_block", 61)
    {request, context} = authority!(target, "executor-shutdown-during-cleanup")
    {:ok, handle} = Executor.start_run(executor, target, request: request, context: context)

    assert_receive {:sandbox_cleanup_started, owner, cleanup_worker}, 5000
    runner_monitor = Process.monitor(handle.pid)
    shutdown = Task.async(fn -> Supervisor.stop(executor, :shutdown, 2_000) end)

    assert Task.yield(shutdown, 0) == nil
    send(cleanup_worker, :release_sandbox_acquire)

    assert :ok = Task.await(shutdown)
    assert_receive {:sandbox_cleanup, ^owner}, 5000
    refute_receive {:sandbox_cleanup_started, ^owner, _cleanup_worker}
    assert_receive {:DOWN, ^runner_monitor, :process, _pid, reason}, 5000
    assert reason in [:normal, :shutdown]
    assert Agent.get(state, & &1.resources) == %{}
  end

  test "executor shutdown cancels a blocked cleanup process tree", %{
    executor: executor,
    state: state
  } do
    {Registry, registry, :worker, _modules} =
      List.keyfind(Supervisor.which_children(executor), Registry, 0)

    target = target!("intent_trap_cleanup_block", 65)
    {request, context} = authority!(target, "executor-shutdown-blocked-cleanup")
    {:ok, handle} = Executor.start_run(executor, target, request: request, context: context)

    assert_receive {:sandbox_allocation_intent, owner, provider_worker,
                    "intent_trap_cleanup_block", 65},
                   5000

    provider_worker_monitor = Process.monitor(provider_worker)
    Process.exit(handle.pid, :kill)

    assert_receive {:DOWN, ^provider_worker_monitor, :process, ^provider_worker, _reason}, 5000
    assert_receive {:sandbox_cleanup_started, ^owner, cleanup_provider_worker}, 5000

    cleanup_job = :sys.get_state(registry).leases[owner].cleanup_job.pid
    cleanup_job_monitor = Process.monitor(cleanup_job)
    cleanup_provider_monitor = Process.monitor(cleanup_provider_worker)
    assert true = :erlang.suspend_process(cleanup_job)

    assert :ok = Supervisor.stop(executor, :shutdown, 2_000)
    assert_receive {:DOWN, ^cleanup_job_monitor, :process, ^cleanup_job, :killed}, 5000

    assert_receive {:DOWN, ^cleanup_provider_monitor, :process, ^cleanup_provider_worker,
                    :killed},
                   5000

    refute_receive {:sandbox_cleanup, ^owner}
    assert Map.has_key?(Agent.get(state, & &1.resources), owner)
  end

  defp target!(mode, unique \\ 0) do
    {:ok, provenance} =
      Provenance.new(
        code: {:available, %{"mode" => mode, "unique" => unique}},
        configuration: {:available, %{"config" => "fixture"}},
        dependencies: {:available, %{"lock" => "fixture"}},
        runtime: {:available, %{"otp" => "fixture"}},
        target: {:available, %{"class" => "fixture"}}
      )

    {:ok, target} = Target.new(%{"id" => "test.sandbox", "version" => 1}, provenance)
    target
  end

  defp wait_until_after(deadline) do
    timer =
      Process.send_after(
        self(),
        {:deadline_passed, deadline},
        max(1, deadline - System.monotonic_time(:millisecond) + 1)
      )

    assert_receive {:deadline_passed, ^deadline}, 1_000
    Process.cancel_timer(timer, async: true, info: false)
  end

  defp assert_register_active_queued!(registry, owner) do
    queued =
      Enum.reduce_while(1..10_000, false, fn _attempt, _queued ->
        messages = registry |> Process.info(:messages) |> elem(1)

        if Enum.any?(messages, fn
             {:"$gen_call", _from, {:register_active, ^owner, _pid}} -> true
             _message -> false
           end) do
          {:halt, true}
        else
          :erlang.yield()
          {:cont, false}
        end
      end)

    assert queued == true
  end

  defp mismatch_provenance! do
    {:ok, provenance} =
      Provenance.new(
        code: {:available, %{"mode" => "different"}},
        configuration: {:available, %{"config" => "fixture"}},
        dependencies: {:available, %{"lock" => "fixture"}},
        runtime: {:available, %{"otp" => "fixture"}},
        target: {:available, %{"class" => "fixture"}}
      )

    Provenance.to_wire_map(provenance)
  end

  defp authority!(target, request_id \\ "sandbox-request", duration \\ 2_000) do
    now = System.monotonic_time(:millisecond)
    target_node = %{node: Atom.to_string(node())}
    {:ok, budget} = Budget.new(max_duration_ms: duration, max_events: 10, max_bytes: 65_536)

    {:ok, request} =
      Request.new("verification.run",
        request_id: request_id,
        environment: :test,
        target: target_node,
        timeout_ms: duration,
        budget: Map.from_struct(budget),
        capability: "verification-grant",
        params: %{"sandbox_target_id" => target.id}
      )

    {:ok, grant} =
      Grant.new(
        reference: "verification-grant",
        audit_id: "sandbox-audit",
        scopes: ["verification.execute"],
        target: target_node,
        expires_at_monotonic: now + duration
      )

    {:ok, context} =
      Context.new(
        environment: :test,
        actor: "sandbox-test",
        target_class: :disposable,
        grants: [grant],
        features: %{
          "verification.run" => %{
            available: true,
            provider: "sandbox-test",
            isolation: :session_local
          }
        },
        deployment_limits: Map.from_struct(budget)
      )

    {request, context}
  end

  defp resign(target) do
    content = %{
      "isolation" => target.isolation,
      "provenance" => target.provenance,
      "provider" => target.provider,
      "schema" => target.schema
    }

    digest =
      content
      |> Insider.Event.Canonical.encode()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    %{
      target
      | id: "sha256:" <> digest,
        integrity: %{"algorithm" => "sha256", "content_digest" => digest}
    }
  end
end
